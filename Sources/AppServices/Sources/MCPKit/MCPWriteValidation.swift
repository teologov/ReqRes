//
//  MCPWriteValidation.swift
//  AppServices
//
//  Copyright © 2026 Andrey Teologov. All rights reserved.
//
//  Licensed under the Functional Source License, Version 1.1 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://fsl.software/
//
//  This software is licensed under the Functional Source License, Version 1.1,
//  with Apache License, Version 2.0 as the Future License. The Licensed Work
//  will become available under Apache-2.0 two years from the date this
//  software is first publicly distributed.
//
//  See LICENSE.md in the repository root for full license text.
//
//  Validation for agent writes. The rules mirror the app's own forms so a
//  rule an agent creates is indistinguishable from one made by hand — the
//  path is normalised through the same `OverridePattern.storedPath`.
//

import Foundation

public enum MCPWriteValidation {
    /// The methods a rule can be LIMITED to (the core's RequestMethodOption).
    /// A rule can also match any method: "" — see `RuleMethod`.
    public static let methods = RuleMethod.specific
    public static let schemes = ["http", "https"]
    /// Inline map_local content travels in one bridge request; the parser's
    /// body cap (1 MiB) is the real ceiling, this leaves room for the JSON.
    public static let maxInlineFileBytes = 900 * 1024
    /// Agent-supplied strings end up in the approval panel and the persisted
    /// activity log; they are bounded so neither can be flooded.
    public static let maxPathLength = 512
    public static let maxFilePathLength = 1024
    public static let maxHeaderValueLength = 2048
    /// A HAR export's filename. Short enough to stay readable in the
    /// approval panel and in Finder, long enough to describe a flow.
    public static let maxExportFilenameLength = 80
    public static let exportFileExtension = "har"


    // MARK: - Exports

    /// The name a HAR export is written under, normalised, or a thrown
    /// `MCPWriteError.invalid` explaining what to send instead.
    ///
    /// The agent names the FILE; it never gets to say where. Everything that
    /// could turn a name into a path — separators, `..`, a leading dot, a
    /// null, anything non-ASCII — is rejected rather than sanitised, because
    /// a silently rewritten name means the agent is told one path and the
    /// user has another, and because the one thing this validator exists to
    /// prevent is an export escaping the directory the app chose for it.
    public static func exportFilename(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPWriteError.invalid("filename is required: a name like \"login-flow.\(exportFileExtension)\".")
        }
        guard trimmed.count <= maxExportFilenameLength else {
            throw MCPWriteError.invalid("filename is limited to \(maxExportFilenameLength) characters.")
        }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains(":") else {
            throw MCPWriteError.invalid("filename must be a bare file name — ReqRes chooses the folder. Send \"login-flow.\(exportFileExtension)\", not a path.")
        }
        guard !trimmed.contains(".."), !trimmed.hasPrefix(".") else {
            throw MCPWriteError.invalid("filename must not start with a dot or contain \"..\".")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- ")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw MCPWriteError.invalid("filename may use letters, digits, spaces, dots, dashes and underscores only.")
        }
        let suffix = ".\(exportFileExtension)"
        return trimmed.lowercased().hasSuffix(suffix) ? trimmed : trimmed + suffix
    }

    // MARK: - Rules

    /// Returns the draft normalised (method upper-cased, scheme lower-cased,
    /// path stored as the app stores it) or throws `.invalid`.
    public static func validate(_ draft: MCPRuleDraft) throws -> MCPRuleDraft {
        var normalized = draft
        normalized.method = try validatedMethod(draft.method)
        normalized.scheme = try validatedScheme(draft.scheme)
        normalized.path = try normalizedPath(draft.path, matchType: draft.matchType)
        try validateStatus(draft.responseStatus, mode: draft.mode)
        try validateHeaders(draft.requestHeaders, label: "requestHeaders")
        try validateHeaders(draft.responseHeaders, label: "responseHeaders")
        // The store keys rules to a host row ("All traffic" is virtual and has
        // none), so every rule needs a real host filter.
        guard let hostId = draft.hostId, hostId > 0 else {
            throw MCPWriteError.invalid("hostId is required: a host id from list_hosts (add_host creates one, mock_from_session picks one for you). Rules always apply to one host filter.")
        }
        switch draft.mode {
        case .mapLocal:
            guard let file = draft.localFile else {
                throw MCPWriteError.invalid("A map_local rule needs localFile: either inline content (with contentType) or an absolute path.")
            }
            normalized.localFile = try validatedLocalFile(file)
            if draft.responseBody != nil {
                throw MCPWriteError.invalid("A map_local rule answers with its file; leave responseBody out.")
            }
        case .extend, .override:
            if draft.localFile != nil {
                throw MCPWriteError.invalid("localFile only applies to map_local rules; use responseBody for \(draft.mode.rawValue).")
            }
        }
        return normalized
    }

    /// A NEW rule, from `create_rule`: `validate(_:)`, then the two things
    /// only an agent's new rule needs.
    ///
    /// - Its path must not hold a redaction mask — what list_rules or a
    ///   session read shows in place of a credential (`refuseRedactionMarker`).
    /// - Its response headers are the ones the override form gives a new
    ///   rule in that mode: an Override that names no Content-Type gets the
    ///   form's JSON one, Extend and Map Local get none (F17 —
    ///   `RuleResponseDefaults.headers(forNewRule:mode:)`).
    ///
    /// Not what `mock_from_session` calls: its headers are the capture's,
    /// Content-Type or not, and its path is derived from the captured URL.
    public static func validateNewRule(_ draft: MCPRuleDraft) throws -> MCPRuleDraft {
        var normalized = try validate(draft)
        try refuseRedactionMarker(inPath: normalized.path, matchType: normalized.matchType) {
            "Write the real value, or \($0)."
        }
        normalized.responseHeaders = RuleResponseDefaults.headers(forNewRule: normalized.responseHeaders, mode: normalized.mode)
        return normalized
    }

    /// Refuses a rule path that holds a redaction mask.
    ///
    /// Rules are shown to agents with a credential in their path masked —
    /// `?access_token=REDACTED` (`MCPRedactor.redactRule`), like a session's
    /// URL. Stored as sent, such a path matches the word REDACTED, never the
    /// request whose credential it hid: a rule that silently never fires.
    ///
    /// `advice` is the route's own way out, handed what stands for any value
    /// where the mask stands (`maskReplacement`) — in the syntax of the
    /// rule's `matchType`: a wildcard's `*` is a quantifier in a regex, where
    /// `?access_token=*` would never match a token.
    public static func refuseRedactionMarker(
        inPath path: String, matchType: MCPMatchType, advice: (_ replacement: String) -> String
    ) throws {
        guard let marker = MCPRedactor.redactionMarker(in: path) else { return }
        throw MCPWriteError.invalid("path holds \(marker): what ReqRes shows in place of a credential, not the credential — a rule with it would match that text and never the real request. \(advice(maskReplacement(for: marker, matchType: matchType)))")
    }

    /// "a wildcard in its place (access_token=*)": what matches any value
    /// where `marker` stands, written as a `matchType` path writes it. A
    /// query mask keeps its parameter, as written in the path; the shape mask
    /// (`«redacted»`, a JWT or key in a segment or a value) is replaced alone.
    static func maskReplacement(for marker: String, matchType: MCPMatchType) -> String {
        let parameter = marker == MCPRedactor.placeholder ? nil : marker.components(separatedBy: "=").first
        switch (matchType, parameter) {
        case (.wildcard, let name?): return "a wildcard in its place (\(name)=*)"
        case (.regex, let name?): return "a pattern in its place (\(name)=[^&]*)"
        case (.wildcard, nil): return "a wildcard in its place (*)"
        case (.regex, nil): return "a pattern in its place ([^/?&]+)"
        }
    }

    /// Validates the fields a patch carries; `matchType` is needed to
    /// normalise a new `path`, so pass the rule's current one when the patch
    /// does not change it.
    ///
    /// `shownPath` is the rule's path as agents are shown it
    /// (`MCPRedactor.redactRule`), credentials masked. A patch whose path is
    /// exactly that — an agent sending the rule back as it read it — keeps
    /// the STORED path: the mask never overwrites the value it hid. A path
    /// that holds a mask but is not the one shown (the agent edited around
    /// it) is refused: which value the mask should stand for is not knowable.
    ///
    /// `currentStatus` is the rule's stored status. A patch that sends none
    /// keeps it — through a change of mode too — so a change to override is
    /// checked against it: an extend rule that keeps the server's status
    /// cannot become an override without one (`validateStatus`).
    ///
    /// Except a map_local rule's: the core never uses it and agents are never
    /// shown it (list_rules prints the file), so it is not a status the rule
    /// HAS. A map_local rule made extend or override without a status starts
    /// with the new mode's, as a new rule in that mode does and as the
    /// override form gives it (`RuleResponseDefaults.status(forNewRuleIn:)`):
    /// an override answers 200, an extend rule keeps the server's. Kept, the
    /// outcome hung on a value nobody can read: a map_local rule stored at 0
    /// (what the form and create_rule store now) was refused the change to
    /// override as "this rule keeps the server's status", one stored at 200
    /// (what every earlier form stored) was let through — and made extend,
    /// answered every response it matched with 200 (F17). The patch returned
    /// carries the status, so the approval panel shows it.
    public static func validate(
        _ patch: MCPRulePatch,
        currentMode: MCPRuleMode,
        currentMatchType: MCPMatchType,
        currentPath: String,
        shownPath: String? = nil,
        currentStatus: Int? = nil
    ) throws -> MCPRulePatch {
        guard !patch.isEmpty else {
            throw MCPWriteError.invalid("The patch changes nothing — include at least one field.")
        }
        var normalized = patch
        if let method = patch.method { normalized.method = try validatedMethod(method) }
        if let scheme = patch.scheme { normalized.scheme = try validatedScheme(scheme) }
        let matchType = patch.matchType ?? currentMatchType
        // The path as shown, when something in it WAS masked; a path shown as
        // stored is an ordinary value, sent back or not.
        let masked = shownPath.flatMap { $0 != currentPath ? $0 : nil }
        if let path = patch.path {
            normalized.path = nil
            // As shown, or as it normalises (an agent dropping the leading
            // slash): the stored path is kept. Both sides normalised, because
            // the shape mask is not ASCII — `«redacted»` in a wildcard path
            // normalises to `%C2%ABredacted%C2%BB`, never to the text shown.
            if path.trimmingCharacters(in: .whitespaces) != masked {
                let stored = try normalizedPath(path, matchType: matchType)
                let maskedStored = masked.flatMap { try? normalizedPath($0, matchType: matchType) }
                if stored != masked, stored != maskedStored {
                    try refuseRedactionMarker(inPath: stored, matchType: matchType) {
                        "Leave path out to keep the stored one, or write the real value, or \($0)."
                    }
                    normalized.path = stored
                }
            }
        }
        if normalized.path == nil, patch.matchType != nil, patch.matchType != currentMatchType {
            // Switching a wildcard rule to regex leaves "/users?*" to be
            // compiled as a regex; make the agent supply one.
            do {
                normalized.path = try normalizedPath(currentPath, matchType: matchType)
            } catch MCPWriteError.invalid(let message) {
                // The refusal quotes the STORED path, which the agent was
                // shown masked: it gets the masked one back.
                throw MCPWriteError.invalid(masked.map { message.replacingOccurrences(of: currentPath, with: $0) } ?? message)
            }
        }
        // The same mode/payload rules the draft enforces, against the mode the
        // rule will HAVE after the patch.
        let mode = patch.mode ?? currentMode
        if let status = patch.responseStatus {
            try validateStatus(status, mode: mode, route: .update(changingMode: mode != currentMode))
        } else if mode != currentMode, currentMode == .mapLocal {
            normalized.responseStatus = RuleResponseDefaults.status(forNewRuleIn: mode).stored
        } else if let currentStatus, mode != currentMode {
            try validateKeptStatus(currentStatus, becoming: mode)
        }
        if let headers = patch.requestHeaders { try validateHeaders(headers, label: "requestHeaders") }
        if let headers = patch.responseHeaders { try validateHeaders(headers, label: "responseHeaders") }
        if let file = patch.localFile {
            guard mode == .mapLocal else {
                throw MCPWriteError.invalid("localFile only applies to map_local rules; set mode to map_local in the same call, or use responseBody.")
            }
            normalized.localFile = try validatedLocalFile(file)
        }
        if patch.responseBody != nil, mode == .mapLocal {
            throw MCPWriteError.invalid("A map_local rule answers with its file; leave responseBody out.")
        }
        if patch.mode == .mapLocal, patch.localFile == nil, currentMode != .mapLocal {
            throw MCPWriteError.invalid("Switching a rule to map_local needs localFile (inline content or a path).")
        }
        // A patch that was only the path, sent back as shown, changes nothing.
        guard !normalized.isEmpty else {
            throw MCPWriteError.invalid("The patch changes nothing: its path is the rule's own, as list_rules shows it with a credential masked as \(MCPRedactor.urlPlaceholder), and the stored path is kept. Include a field to change.")
        }
        return normalized
    }

    // MARK: - Hosts

    public static func validate(_ draft: MCPHostDraft) throws -> MCPHostDraft {
        var normalized = draft
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidHostname(host) else {
            throw MCPWriteError.invalid("'\(draft.host)' is not a hostname. Use the bare host such as api.example.com — no scheme, port or path.")
        }
        normalized.host = host
        normalized.scheme = try validatedScheme(draft.scheme)
        if let port = draft.port {
            guard (1...65535).contains(port) else {
                throw MCPWriteError.invalid("port must be between 1 and 65535.")
            }
        }
        return normalized
    }

    /// The app's Add Host rule, exactly (`String.isValidHostname`): letters,
    /// digits, hyphens and dots; at least one dot; no leading/trailing dot or
    /// hyphen; labels 1–63 characters; a TLD of at least two. Kept identical
    /// so the bridge cannot create a host filter the sidebar form rejects.
    public static func isValidHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              !host.hasPrefix("-"), !host.hasSuffix("-"), !host.contains("..") else { return false }
        let labels = host.split(separator: ".")
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return false }
        return (labels.last?.count ?? 0) >= 2
    }

    // MARK: - Pieces

    /// Any method ("", "*" or "any") is stored as `RuleMethod.any` — the
    /// core honours a rule's method since 1.1.0, and "" is what it reads as
    /// "any" (every pre-1.1.0 rule was migrated to it).
    static func validatedMethod(_ method: String) throws -> String {
        if RuleMethod.isAny(method) { return RuleMethod.any }
        let upper = method.trimmingCharacters(in: .whitespaces).uppercased()
        guard methods.contains(upper) else {
            throw MCPWriteError.invalid("method must be any (omit it, or send \"\" or \"any\") or one of \(methods.joined(separator: ", ")).")
        }
        return upper
    }

    static func validatedScheme(_ scheme: String) throws -> String {
        let lower = scheme.trimmingCharacters(in: .whitespaces).lowercased()
        guard schemes.contains(lower) else {
            throw MCPWriteError.invalid("scheme must be http or https.")
        }
        return lower
    }

    public static func normalizedPath(_ path: String, matchType: MCPMatchType) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MCPWriteError.invalid("path is required: the pathname and query to match, e.g. /users?* (wildcard) or /users/\\d+$ (regex).")
        }
        guard trimmed.utf8.count <= maxPathLength else {
            throw MCPWriteError.invalid("path is limited to \(maxPathLength) characters.")
        }
        guard !hasLineBreak(trimmed) else {
            throw MCPWriteError.invalid("path cannot contain a line break.")
        }
        // The proxy matches `scheme://host + path`, so a host written into the
        // path is matched twice and the rule can never fire.
        if !trimmed.hasPrefix("/"), !trimmed.hasPrefix("^"),
           let firstSegment = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first,
           firstSegment.contains("."), !firstSegment.contains("*") {
            throw MCPWriteError.invalid("path is the pathname and query only — the host comes from host_id. Write \(trimmed.drop(while: { $0 != "/" }).isEmpty ? "/" : String(trimmed.drop(while: { $0 != "/" }))) instead of \(trimmed).")
        }
        if matchType == .regex {
            do { _ = try NSRegularExpression(pattern: trimmed) } catch {
                throw MCPWriteError.invalid("path is not a valid regular expression: \(trimmed)")
            }
            // The core compiles `scheme://host + path` and SEARCHES for it, so
            // a leading ^ would have to anchor mid-string: the rule could
            // never match. (Verified against XReqResCore's matchRule.)
            if trimmed.hasPrefix("^") {
                let suggestion = String(trimmed.dropFirst())
                throw MCPWriteError.invalid("A regex path must not start with ^: the proxy anchors the pattern after the host, so it would never match. Write \(suggestion.isEmpty ? "/…" : suggestion) instead.")
            }
            // The pattern is appended straight after the host, so it has to
            // begin at the path ("users/\\d+" would compile as "…example.comusers…").
            guard trimmed.hasPrefix("/") else {
                throw MCPWriteError.invalid("A regex path must start with /: the proxy appends it directly after the host. Write /\(trimmed) instead.")
            }
        }
        return OverridePattern.storedPath(trimmed, isRegex: matchType == .regex)
    }

    /// The tool a status is checked for. A refusal says what leaving the
    /// status out does, and that is each tool's own — the create_rule
    /// sentences ("200 when you leave it out") are false of the other two.
    enum StatusRoute: Equatable, Sendable {
        /// create_rule: left out, the mode's start — an extend rule keeps
        /// the server's status, an override answers 200
        /// (`RuleResponseDefaults.status(forNewRuleIn:)`).
        case create
        /// update_rule: left out, the rule's current status is kept. Said only
        /// when the patch changes no mode: through a change of mode a kept
        /// status can still be refused (`validateKeptStatus`), and a
        /// map_local rule's is not kept at all.
        case update(changingMode: Bool)
        /// mock_from_session: left out, the captured status is replayed —
        /// `replays`, when it is one a mock can answer with (nil: none is
        /// said). A mock answers instead of the server, so it has no server
        /// status to keep, and the route takes no extend rule.
        case mock(replays: Int?)
    }

    /// A rule's status, checked against the mode the rule will have (core
    /// 95062d1, F17). Only a final status, 200…599, is one the core answers
    /// with: it reads anything else as "keep the server's" where the request
    /// is forwarded and as 200 where ReqRes answers itself — and a 1xx used
    /// to crash the extension (build 52 accepted 100…599).
    /// - extend: 200–599, or 0 to keep the server's status (its default);
    /// - override: 200–599 — it answers with its own (200 by default), and
    ///   keeping the server's is extend's (`RuleResponseDefaults`);
    /// - map_local: not used — its file answers 200 and a missing one
    ///   forwards the server's response unchanged — so 0 or 200–599 is
    ///   accepted and nothing else.
    /// A refusal names what leaving the status out does on `route`.
    static func validateStatus(_ status: Int, mode: MCPRuleMode, route: StatusRoute = .create) throws {
        if RuleResponseDefaults.answeringStatuses.contains(status) { return }
        if status == RuleResponseDefaults.keepServerStatus, RuleResponseDefaults.canKeepServerStatus(mode) { return }
        let keep = status == RuleResponseDefaults.keepServerStatus
        let finalStatus = "responseStatus must be a final HTTP status, 200–599"
        switch (mode, route) {
        case (.mapLocal, _):
            throw MCPWriteError.invalid("A map_local rule does not use responseStatus — its file answers 200, and a missing file forwards the server's response unchanged — so leave it out.")
        case (.extend, .create):
            throw MCPWriteError.invalid("\(finalStatus), or 0 to keep the server's status — what an extend rule does when you leave it out.")
        case (.override, .create) where keep:
            throw MCPWriteError.invalid("An override answers with its own status, so responseStatus must be 200–599 (200 when you leave it out). To keep the server's status, use mode extend.")
        case (.override, .create):
            throw MCPWriteError.invalid("\(finalStatus) (an override answers 200 when you leave it out).")
        case (.extend, .update(let changingMode)):
            throw MCPWriteError.invalid("\(finalStatus), or 0 to keep the server's status\(changingMode ? "" : "; leave it out to keep the rule's current status").")
        case (.override, .update(let changingMode)) where keep:
            throw MCPWriteError.invalid("An override answers with its own status, so responseStatus must be 200–599\(changingMode ? "" : ", or left out to keep the rule's current status"). Only an extend rule keeps the server's status (mode extend, responseStatus 0).")
        case (.override, .update(let changingMode)):
            throw MCPWriteError.invalid("\(finalStatus)\(changingMode ? "" : "; leave it out to keep the rule's current status").")
        case (_, .mock(let replays)) where keep:
            throw MCPWriteError.invalid("A mock answers instead of the server, so it has no server status to keep: \(finalStatus)\(Self.replaying(replays)).")
        case (_, .mock(let replays)):
            throw MCPWriteError.invalid("\(finalStatus)\(Self.replaying(replays)).")
        }
    }

    /// "; leave it out to replay the captured 404", or nothing when the
    /// capture has no status a mock can answer with.
    private static func replaying(_ replays: Int?) -> String {
        replays.map { "; leave it out to replay the captured \($0)" } ?? ""
    }

    /// A mock that names no status answers with the captured one — which
    /// must then be one it can answer with. `captured` is the session's
    /// status (nil when it has none: the mock answers 200). A WebSocket's
    /// 101, say, is refused here, BEFORE anyone is asked: let through, the
    /// rule's validation refused it after the human had approved the mock,
    /// as a status the agent never sent. A map_local mock uses no status.
    static func validateReplayedStatus(_ captured: Int?, uid: String, mode: MCPRuleMode) throws {
        guard mode != .mapLocal, let captured, !RuleResponseDefaults.answeringStatuses.contains(captured) else { return }
        throw MCPWriteError.invalid("Session \(uid)'s captured status, \(captured), is not one a mock can answer with: a mock answers with a final status, 200–599. Pass response_status: the status the mock should answer with.")
    }

    /// A status a patch keeps through a change of mode, checked against the
    /// mode it is kept on: only an override needs one it can answer with —
    /// an extend rule keeps the server's for anything else, as the core does,
    /// and a map_local rule uses none. Never a map_local rule's own status:
    /// that one is not kept (`validate(_:currentMode:…)`).
    static func validateKeptStatus(_ stored: Int, becoming mode: MCPRuleMode) throws {
        guard mode == .override, !RuleResponseDefaults.answeringStatuses.contains(stored) else { return }
        let what = stored == RuleResponseDefaults.keepServerStatus
            ? "This rule keeps the server's status, which an override cannot: it answers with its own."
            : "This rule's stored status, \(stored), is not one an override answers with."
        throw MCPWriteError.invalid("\(what) Send responseStatus (200–599) with the mode change.")
    }

    /// Swift folds "\r\n" into ONE Character, so `contains("\n")` misses the
    /// classic CRLF injection — the scalars are what the wire sees.
    static func hasLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    static func validateHeaders(_ headers: [String: String], label: String) throws {
        for key in headers.keys {
            let trimmed = key.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains(":"), !hasLineBreak(trimmed), trimmed.utf8.count <= 256 else {
                throw MCPWriteError.invalid("\(label) contains an invalid header name '\(key)'.")
            }
        }
        for value in headers.values {
            guard !hasLineBreak(value) else {
                throw MCPWriteError.invalid("\(label) contains a header value with a line break.")
            }
            guard value.utf8.count <= maxHeaderValueLength else {
                throw MCPWriteError.invalid("\(label) contains a header value longer than \(maxHeaderValueLength) characters.")
            }
        }
    }

    static func validatedLocalFile(_ file: MCPLocalFile) throws -> MCPLocalFile {
        switch (file.content, file.path) {
        case (nil, nil):
            throw MCPWriteError.invalid("localFile needs either inline content or an absolute path.")
        case (.some, .some):
            throw MCPWriteError.invalid("localFile takes inline content OR a path, not both.")
        case (.some(let content), nil):
            guard content.utf8.count <= maxInlineFileBytes else {
                throw MCPWriteError.invalid("Inline content is limited to \(maxInlineFileBytes / 1024) KB; save larger fixtures to a file and pass its path.")
            }
            var normalized = file
            normalized.contentType = (file.contentType?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "application/json"
            return normalized
        case (nil, .some(let path)):
            guard path.hasPrefix("/") else {
                throw MCPWriteError.invalid("localFile.path must be an absolute path.")
            }
            guard path.utf8.count <= maxFilePathLength, !hasLineBreak(path) else {
                throw MCPWriteError.invalid("localFile.path is malformed.")
            }
            return file
        }
    }
}
