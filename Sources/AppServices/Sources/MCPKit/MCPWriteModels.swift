//
//  MCPWriteModels.swift
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
//  RR-MCP-2 "agents can act": the write surface's models and the seams the
//  running app implements. Core-agnostic, like the read surface — the app
//  adapts these onto RuleCodable/HostCodable and the extension bus.
//
//  Every write goes consent → perform → audit (see MCPBridgeRouter). The
//  consent model is HYBRID: by default the app asks the human to approve
//  each change; a standing grant makes it frictionless; either way every
//  action is logged in the app.
//

import Foundation

// MARK: - Hosts

/// A host filter as the sidebar shows it.
public struct MCPHost: Codable, Equatable, Sendable {
    /// Database id; 0 is never a real host.
    public var id: Int64
    public var host: String
    public var scheme: String
    public var port: Int

    public init(id: Int64, host: String, scheme: String, port: Int) {
        self.id = id
        self.host = host
        self.scheme = scheme
        self.port = port
    }
}

/// What an agent sends to add a host filter.
public struct MCPHostDraft: Codable, Equatable, Sendable {
    public var host: String
    /// "https" (default) or "http".
    public var scheme: String
    /// The app's own form always stores 80 today; agents may set a real one.
    public var port: Int?

    public init(host: String, scheme: String = "https", port: Int? = nil) {
        self.host = host
        self.scheme = scheme
        self.port = port
    }

    private enum CodingKeys: String, CodingKey { case host, scheme, port }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme) ?? "https"
        port = try container.decodeIfPresent(Int.self, forKey: .port)
    }
}

// MARK: - Rules

public enum MCPRuleMode: String, Codable, CaseIterable, Sendable {
    /// Matching requests/responses are extended with the rule's items.
    case extend
    /// Matching requests/responses are replaced by the rule's items.
    case override
    /// Matching requests are answered with a local file.
    case mapLocal = "map_local"
}

public enum MCPMatchType: String, Codable, CaseIterable, Sendable {
    case wildcard
    case regex
}

/// A rule as stored, with resolved names for the agent.
public struct MCPRule: Codable, Equatable, Sendable {
    /// Database id, stable across edits.
    public var id: Int64
    /// The host filter the rule is scoped to (rules always have one).
    public var hostId: Int64
    /// The host filter's name; nil only for a legacy row whose host is gone.
    public var host: String?
    public var enabled: Bool
    public var mode: MCPRuleMode
    public var matchType: MCPMatchType
    /// Pathname + query as matched ("/users?*", "/users/\\d+$" — never a leading `^`).
    public var path: String
    public var method: String
    public var scheme: String
    public var requestHeaders: [String: String]
    /// As stored: 0 keeps the server's status (core 95062d1) — read it
    /// through `RuleResponseDefaults.statusText`, never as a number.
    public var responseStatus: Int
    public var responseHeaders: [String: String]
    public var responseBody: String?
    /// For map_local: the file the rule answers with.
    public var localFilePath: String?

    public init(
        id: Int64,
        hostId: Int64,
        host: String?,
        enabled: Bool,
        mode: MCPRuleMode,
        matchType: MCPMatchType,
        path: String,
        method: String,
        scheme: String,
        requestHeaders: [String: String] = [:],
        responseStatus: Int = 200,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        localFilePath: String? = nil
    ) {
        self.id = id
        self.hostId = hostId
        self.host = host
        self.enabled = enabled
        self.mode = mode
        self.matchType = matchType
        self.path = path
        self.method = method
        self.scheme = scheme
        self.requestHeaders = requestHeaders
        self.responseStatus = responseStatus
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.localFilePath = localFilePath
    }
}

/// The file a map_local rule answers with: inline content the app writes into
/// its own container as a fixture (sandbox-safe), or an absolute path to an
/// existing file. Exactly one of the two.
public struct MCPLocalFile: Codable, Equatable, Sendable {
    public var content: String?
    /// MIME type for inline content; default application/json.
    public var contentType: String?
    public var path: String?

    public init(content: String? = nil, contentType: String? = nil, path: String? = nil) {
        self.content = content
        self.contentType = contentType
        self.path = path
    }
}

/// What an agent sends to create a rule. Defaults mirror the app's form.
public struct MCPRuleDraft: Codable, Equatable, Sendable {
    /// Required: a host filter id from list_hosts.
    public var hostId: Int64?
    public var mode: MCPRuleMode
    public var matchType: MCPMatchType
    public var path: String
    public var method: String
    public var scheme: String
    public var requestHeaders: [String: String]
    /// As stored: 0 keeps the server's status (core 95062d1). Left out, it is
    /// the mode's start (`RuleResponseDefaults.status(forNewRuleIn:)`): an
    /// extend rule keeps the server's — the core's migration turned the
    /// form's untouched Extend rules into keep, and one an agent stored at
    /// 200 would go on answering 200 (F17) — an override answers 200, and a
    /// map_local rule, which does not use it, stores 0.
    public var responseStatus: Int
    public var responseHeaders: [String: String]
    public var responseBody: String?
    public var localFile: MCPLocalFile?
    public var enabled: Bool

    public init(
        hostId: Int64? = nil,
        mode: MCPRuleMode,
        matchType: MCPMatchType = .wildcard,
        path: String,
        method: String = RuleMethod.any,
        scheme: String = "https",
        requestHeaders: [String: String] = [:],
        responseStatus: Int? = nil,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        localFile: MCPLocalFile? = nil,
        enabled: Bool = true
    ) {
        self.hostId = hostId
        self.mode = mode
        self.matchType = matchType
        self.path = path
        self.method = method
        self.scheme = scheme
        self.requestHeaders = requestHeaders
        self.responseStatus = responseStatus ?? RuleResponseDefaults.status(forNewRuleIn: mode).stored
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.localFile = localFile
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case hostId, mode, matchType, path, method, scheme, requestHeaders, responseStatus, responseHeaders, responseBody, localFile, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostId = try c.decodeIfPresent(Int64.self, forKey: .hostId)
        mode = try c.decode(MCPRuleMode.self, forKey: .mode)
        matchType = try c.decodeIfPresent(MCPMatchType.self, forKey: .matchType) ?? .wildcard
        path = try c.decode(String.self, forKey: .path)
        // Omitted = any method (1.1.0): the core honours a rule's method now,
        // so the old "GET" default made an agent's POST mock never match.
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? RuleMethod.any
        scheme = try c.decodeIfPresent(String.self, forKey: .scheme) ?? "https"
        requestHeaders = try c.decodeIfPresent([String: String].self, forKey: .requestHeaders) ?? [:]
        // Omitted = the mode's start: an extend rule keeps the server's
        // status (core 95062d1). Resolved HERE, where the agent's arguments
        // are first decoded: the helper encodes the draft for the bridge, so
        // an omitted status must not travel as a 200.
        responseStatus = try c.decodeIfPresent(Int.self, forKey: .responseStatus)
            ?? RuleResponseDefaults.status(forNewRuleIn: mode).stored
        responseHeaders = try c.decodeIfPresent([String: String].self, forKey: .responseHeaders) ?? [:]
        responseBody = try c.decodeIfPresent(String.self, forKey: .responseBody)
        localFile = try c.decodeIfPresent(MCPLocalFile.self, forKey: .localFile)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// A partial update; only the fields present change.
public struct MCPRulePatch: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var mode: MCPRuleMode?
    public var matchType: MCPMatchType?
    public var path: String?
    public var method: String?
    public var scheme: String?
    public var requestHeaders: [String: String]?
    /// nil keeps the stored status — through a change of mode too, checked
    /// against the mode the rule will have (`MCPWriteValidation`) — except a
    /// map_local rule's, which it does not use: a rule leaving map_local
    /// starts with its new mode's status, as a new rule does. 0 keeps the
    /// server's: extend's, and accepted (unused) on a map_local rule.
    public var responseStatus: Int?
    public var responseHeaders: [String: String]?
    public var responseBody: String?
    public var localFile: MCPLocalFile?

    public init(
        enabled: Bool? = nil,
        mode: MCPRuleMode? = nil,
        matchType: MCPMatchType? = nil,
        path: String? = nil,
        method: String? = nil,
        scheme: String? = nil,
        requestHeaders: [String: String]? = nil,
        responseStatus: Int? = nil,
        responseHeaders: [String: String]? = nil,
        responseBody: String? = nil,
        localFile: MCPLocalFile? = nil
    ) {
        self.enabled = enabled
        self.mode = mode
        self.matchType = matchType
        self.path = path
        self.method = method
        self.scheme = scheme
        self.requestHeaders = requestHeaders
        self.responseStatus = responseStatus
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.localFile = localFile
    }

    public var isEmpty: Bool {
        enabled == nil && mode == nil && matchType == nil && path == nil && method == nil && scheme == nil
            && requestHeaders == nil && responseStatus == nil && responseHeaders == nil && responseBody == nil
            && localFile == nil
    }
}

/// Whether a captured response can become a mock at all (release review,
/// 2026-09-29). A mock is a promise that the app gets THIS response without
/// the server being contacted; three captures cannot keep it:
///
/// * no body — an override without a body is not answered locally: the core
///   FORWARDS the request with its headers replaced (`RuleResponses.
///   localAnswer`), so a 204 DELETE "mock" would still delete;
/// * a body kept only in part (the 16 MB retention cap) — the mock would
///   answer with a silently cut-off copy;
/// * a body still under a coding ReqRes did not undo (compress, an unknown coding) —
///   the copy is the encoded bytes, and the rule drops Content-Encoding, so
///   the app would get compressed bytes labelled identity.
///
/// A `response_body` from the agent replaces the captured one, so none of
/// the three applies then.
public enum MCPMockFromSessionCheck {
    public struct CapturedResponse: Equatable, Sendable {
        public var textBody: String
        public var binaryByteCount: Int
        public var notRetainedBytes: Int64
        public var undecodedEncoding: String?

        public init(textBody: String, binaryByteCount: Int, notRetainedBytes: Int64, undecodedEncoding: String?) {
            self.textBody = textBody
            self.binaryByteCount = binaryByteCount
            self.notRetainedBytes = notRetainedBytes
            self.undecodedEncoding = undecodedEncoding
        }

        public var isEmpty: Bool { textBody.isEmpty && binaryByteCount == 0 }
    }

    /// Why `uid` cannot be mocked in `mode`, or nil.
    public static func refusal(uid: String, mode: MCPRuleMode, responseBody: String?, captured: CapturedResponse) -> String? {
        guard responseBody == nil else { return nil }
        if captured.notRetainedBytes > 0 {
            return "Session \(uid)'s response was kept only in part (\(captured.notRetainedBytes) bytes as sent were not kept), so a mock of it would answer with a cut-off body. Pass response_body with what the mock should answer."
        }
        if let coding = captured.undecodedEncoding, !coding.isEmpty {
            return "Session \(uid)'s response is still \(coding)-encoded (ReqRes does not decode \(coding)), so a mock of it would send compressed bytes the app cannot read. Pass response_body with what the mock should answer."
        }
        if captured.isEmpty {
            switch mode {
            case .override:
                return "Session \(uid)'s response had no body. An override without a body is not answered by ReqRes — it FORWARDS the request to the server with its headers replaced — so it would not be a mock. Pass response_body (the text the app should get), or use create_rule if forwarding is what you want."
            case .mapLocal:
                return "Session \(uid) has no response body to map; use mode override with a response_body."
            case .extend:
                return nil
            }
        }
        return nil
    }
}

/// `mock_from_session`: turn a captured exchange into a rule that replays its
/// response, with optional mutations. The app resolves the session, picks or
/// creates the host filter, and builds the draft.
public struct MCPMockFromSessionRequest: Codable, Equatable, Sendable {
    public var uid: String
    /// override (default: replays inline) or map_local (writes a fixture —
    /// what a binary body needs). `extend` is refused: extending a response
    /// with its own captured headers is not a mock.
    public var mode: MCPRuleMode?
    public var responseStatus: Int?
    public var responseBody: String?
    /// Merged over the captured response headers.
    public var responseHeaders: [String: String]?
    /// Replaces the path derived from the session (a wildcard by default).
    public var path: String?
    public var matchType: MCPMatchType?

    public init(
        uid: String,
        mode: MCPRuleMode? = nil,
        responseStatus: Int? = nil,
        responseBody: String? = nil,
        responseHeaders: [String: String]? = nil,
        path: String? = nil,
        matchType: MCPMatchType? = nil
    ) {
        self.uid = uid
        self.mode = mode
        self.responseStatus = responseStatus
        self.responseBody = responseBody
        self.responseHeaders = responseHeaders
        self.path = path
        self.matchType = matchType
    }
}

// MARK: - Capture

public enum MCPCaptureCommand: String, Codable, CaseIterable, Sendable {
    case start
    case stop
}

public struct MCPCaptureRequest: Codable, Equatable, Sendable {
    public var action: MCPCaptureCommand
    public init(action: MCPCaptureCommand) { self.action = action }
}

/// A dry run of a rule path against a URL. `path` is what `create_rule`
/// stores; the host and scheme come from the URL, because that is how the
/// proxy builds the pattern it compiles.
public struct MCPPatternTestRequest: Codable, Equatable, Sendable {
    public var path: String
    public var url: String
    public var matchType: MCPMatchType

    public init(path: String, url: String, matchType: MCPMatchType = .wildcard) {
        self.path = path
        self.url = url
        self.matchType = matchType
    }

    private enum CodingKeys: String, CodingKey { case path, pattern, url, matchType }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `pattern` is accepted as an alias: it is the word an agent reaches for.
        if let path = try c.decodeIfPresent(String.self, forKey: .path) {
            self.path = path
        } else if let pattern = try c.decodeIfPresent(String.self, forKey: .pattern) {
            self.path = pattern
        } else {
            throw MCPWriteError.invalid("path is required: the rule path to test, e.g. /users?*")
        }
        url = try c.decode(String.self, forKey: .url)
        matchType = try c.decodeIfPresent(MCPMatchType.self, forKey: .matchType) ?? .wildcard
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(url, forKey: .url)
        try c.encode(matchType, forKey: .matchType)
    }
}

public struct MCPPatternTestResult: Codable, Equatable, Sendable {
    public var path: String
    public var url: String
    public var matchType: MCPMatchType
    public var matches: Bool
    /// The string the proxy compiles: `scheme://host` + the path.
    public var proxyPattern: String

    public init(path: String, url: String, matchType: MCPMatchType, matches: Bool, proxyPattern: String) {
        self.path = path
        self.url = url
        self.matchType = matchType
        self.matches = matches
        self.proxyPattern = proxyPattern
    }
}

/// A row this log refers to by id — what a creation made, for the undo that
/// deletes it again.
public enum MCPAuditTarget: Equatable, Sendable {
    case rule(Int64)
    case host(Int64)

    public var id: Int64 {
        switch self {
        case .rule(let id), .host(let id): return id
        }
    }
}

extension MCPAuditTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id }
    private enum Kind: String, Codable { case rule, host }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rule(let id):
            try c.encode(Kind.rule, forKey: .kind)
            try c.encode(id, forKey: .id)
        case .host(let id):
            try c.encode(Kind.host, forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(Int64.self, forKey: .id)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .rule: self = .rule(id)
        case .host: self = .host(id)
        }
    }
}

/// Small envelopes for writes that return no model.
public struct MCPDeleted: Codable, Equatable, Sendable {
    public var id: Int64
    public init(id: Int64) { self.id = id }
}

public struct MCPCleared: Codable, Equatable, Sendable {
    public var cleared: Int
    public init(cleared: Int) { self.cleared = cleared }
}

/// What an agent asks for when it wants a HAR file.
public struct MCPExportRequest: Codable, Equatable, Sendable {
    /// The sessions to write, oldest first in the file regardless of the
    /// order they are listed here — a HAR is read as a timeline.
    public var uids: [String]
    /// A bare file name. ReqRes owns the folder (see
    /// `MCPWriteValidation.exportFilename`).
    public var filename: String

    public init(uids: [String], filename: String) {
        self.uids = uids
        self.filename = filename
    }
}

/// Where the export landed and what made it in.
public struct MCPExportResult: Codable, Equatable, Sendable {
    public var path: String
    public var includedCount: Int
    public var requestedCount: Int
    /// True when the encoder's size cap cut the entry list short.
    public var truncated: Bool
    public var bytes: Int
    /// Stated back to the agent so it never has to assume: the file holds
    /// redacted values, so a credential read out of it is a placeholder.
    public var redacted: Bool
    /// Asked-for sessions left out because they were still in flight (a live
    /// row has no finished response to write). Nil from an app that predates
    /// live rows.
    public var skippedInFlight: Int?

    public init(path: String, includedCount: Int, requestedCount: Int, truncated: Bool, bytes: Int, redacted: Bool,
                skippedInFlight: Int? = nil) {
        self.path = path
        self.includedCount = includedCount
        self.requestedCount = requestedCount
        self.truncated = truncated
        self.bytes = bytes
        self.redacted = redacted
        self.skippedInFlight = skippedInFlight
    }
}

// MARK: - Consent and audit

/// What an agent is asking the app to do — shown to the human verbatim in
/// the approval sheet and kept in the activity log.
public struct MCPAgentAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case addHost = "add_host"
        case removeHost = "remove_host"
        case createRule = "create_rule"
        case updateRule = "update_rule"
        case deleteRule = "delete_rule"
        case mockFromSession = "mock_from_session"
        case startCapture = "start_capture"
        case stopCapture = "stop_capture"
        case clearSessions = "clear_sessions"
        case exportSessions = "export_sessions"
        case saveSession = "save_session"
        case deleteSavedSession = "delete_saved_session"
        case replayRequest = "replay_request"
        case answerPausedRequest = "answer_paused_request"
        /// Add a host to Settings ▸ Capture's exclusion list (protocol PRD
        /// 3.5): ReqRes relays it untouched and records nothing of it.
        case excludeHost = "exclude_host"
    }

    /// How much a change can cost the user if it was not what they meant.
    ///
    /// The approval panel used to look identical for "add a host filter" and
    /// "answer this URL from a file on disk", which asks someone to weigh two
    /// very different things with the same glance. Severity lives here, in the
    /// pure layer, so the panel copy and the agent-facing tool descriptions
    /// cannot drift apart, and so it can be tested without a window.
    public enum Severity: Int, Codable, Comparable, Sendable {
        /// Changes what ReqRes watches or records. Reversible, nothing leaves.
        case routine = 0
        /// Puts captured traffic on disk. Nothing about what ReqRes watches
        /// or what the network sees changes, which is why it is not
        /// "routine": the exchange now outlives the capture run, in the clear,
        /// until someone deletes it, and anything that can read the file can
        /// read it without passing this app's consent or redaction again.
        /// Both `export_sessions` (a HAR the user can move anywhere) and
        /// `save_session` (a row in ReqRes's own store) land here — they
        /// differ in reach, not in kind, and the per-action details say which.
        case exportsData = 1
        /// Changes what the user's own apps receive over the network.
        case rewritesTraffic = 2
        /// Throws something away. Nothing here can be undone yet.
        case destructive = 3
        /// Leaves this Mac. Every other severity describes something ReqRes
        /// does to itself or to the user's own apps; this one sends a real
        /// request to a real server that belongs to someone else, and
        /// whatever that server does on receiving it has already happened by
        /// the time anyone notices. Deliberately the MAXIMUM, and the one
        /// weight `canBeCoveredByStandingGrant` refuses to cover.
        case actsOnThirdParty = 4

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// One line naming the consequence, shown once per approval for the
        /// highest severity in the burst. Written for someone deciding in a
        /// hurry, so it says what happens, not how the feature works.
        public var consequence: String {
            switch self {
            case .routine:
                return "This changes what ReqRes watches. Your traffic is not altered."
            case .exportsData:
                return "This puts captured traffic on disk, where it outlives the capture run and ReqRes no longer decides who reads it."
            case .rewritesTraffic:
                return "Your apps will receive what these rules say, not what the server sent."
            case .destructive:
                return "This removes things from ReqRes. It cannot be undone."
            case .actsOnThirdParty:
                return "This sends a real request over the network to a server that is not yours. Whatever that server does when it receives it happens for real."
            }
        }

        /// Whether the standing grant ("Let agents change rules and hosts
        /// without asking") may answer for an action of this weight.
        ///
        /// That toggle is a statement about THIS app: the user is saying they
        /// are happy for an agent to rearrange ReqRes without being
        /// interrupted. It must not quietly become "and send captured
        /// requests back out to other people's servers" — a setting nobody
        /// read that way when they turned it on. So the rule lives here,
        /// in the pure layer, rather than as an `if` inside the app's consent
        /// queue where it would be invisible and untested.
        public var canBeCoveredByStandingGrant: Bool {
            switch self {
            case .routine, .exportsData, .rewritesTraffic, .destructive:
                return true
            case .actsOnThirdParty:
                return false
            }
        }
    }

    public var kind: Kind
    /// One line, human-readable: "Create an override rule for api.example.com: GET /users?* → 500".
    public var summary: String
    /// Extra lines for the approval sheet (headers, body size, file path…).
    public var details: [String]

    public init(kind: Kind, summary: String, details: [String] = []) {
        self.kind = kind
        self.summary = summary
        self.details = details
    }

    public var severity: Severity { kind.severity }

    /// Whether the standing grant (or "Allow for this session") may answer
    /// for this action instead of the human: its weight must allow it
    /// (`Severity.canBeCoveredByStandingGrant`) AND its kind must
    /// (`Kind.canBeCoveredByStandingGrant`). The consent queue asks this, not
    /// the severity alone.
    public var canBeCoveredByStandingGrant: Bool {
        severity.canBeCoveredByStandingGrant && kind.canBeCoveredByStandingGrant
    }
}

extension MCPAgentAction.Kind {
    /// Kinds the standing grant never answers for, whatever their weight.
    ///
    /// `exclude_host` is the one write that HIDES traffic from the human: an
    /// excluded host is relayed and not recorded, so a prompt-injected agent
    /// holding "change rules and hosts without asking" could make a host's
    /// traffic disappear from the very window that would show what it did.
    /// A rule's effect is visible in the traffic it rewrites; an exclusion's
    /// is an absence. So it is always put in front of the user.
    public var canBeCoveredByStandingGrant: Bool {
        switch self {
        case .excludeHost: return false
        default: return true
        }
    }
}

extension MCPAgentAction.Kind {
    public var severity: MCPAgentAction.Severity {
        switch self {
        case .addHost, .startCapture, .stopCapture:
            return .routine
        // An export leaves as a file and a save becomes a row in ReqRes's
        // own store; both turn an exchange that would have vanished at quit
        // into something that persists in the clear. Nothing on the wire
        // changes, so neither is a traffic rewrite — but neither is routine
        // either, and "your traffic is not altered" would be the one true,
        // useless thing to tell someone approving it.
        case .exportSessions, .saveSession:
            return .exportsData
        // A rule is the whole point of the product and also the sharpest edge:
        // once one exists, the app under test stops seeing the real response.
        case .createRule, .updateRule, .mockFromSession:
            return .rewritesTraffic
        // Removing a host filter takes its rules with it; clearing sessions
        // discards captured traffic that cannot be recaptured.
        // Deleting a saved session destroys something the user deliberately
        // kept, and unlike a captured session it cannot be recaptured by
        // rerunning the traffic — there is no weaker reading of it.
        case .removeHost, .deleteRule, .clearSessions, .deleteSavedSession:
            return .destructive
        // The only one that leaves this Mac. Nothing in ReqRes changes; a
        // request the user's own app made once is made again, by an agent,
        // against a server neither of them controls.
        case .replayRequest:
            return .actsOnThirdParty
        // Answering a held request decides what the user's own app receives:
        // resumed with edits, or answered here with an error the server never
        // sees. It is not `actsOnThirdParty` — the request was already on its
        // way to that server because the user's own app sent it, and the
        // untouched resume is what happens anyway if nobody answers.
        case .answerPausedRequest:
            return .rewritesTraffic
        // Excluding a host changes how its live traffic is handled — passed
        // straight through with the server's own certificate instead of
        // intercepted — and hides it from the human AND the agent from then
        // on. Nothing is deleted and it is undone with one click, so it is
        // not destructive; but it removes traffic from view, which is at
        // least as weighty as a rule (PRD 3.5 names this severity).
        case .excludeHost:
            return .rewritesTraffic
        }
    }

    /// The sentence appended to this tool's description, so an agent knows the
    /// weight of what it is asking for before it asks.
    public var consentNote: String {
        // The one write that is not approved per call, and the reason is the
        // clock: consent may take 45s and a held request is released by the
        // core at 60, so a panel per decision would spend the window the
        // decision has to fit inside. The grant is given once, deliberately,
        // where the human armed the breakpoint.
        if self == .answerPausedRequest {
            return "This one is NOT approved per call — a held request is released after "
                + "60 seconds and an approval could outlast it. The user grants it once in "
                + "Settings → Breakpoints, where it ships switched off; while it is off this "
                + "call fails with consent_denied and the human answers in the ReqRes window "
                + "instead. It rewrites live traffic — an aborted request never reaches the "
                + "server — and every decision is written to the activity log."
        }
        let base = "The user approves this in the ReqRes window unless they have allowed agent changes; if they decline, the call fails with consent_denied."
        if self == .excludeHost {
            return "The user approves this in the ReqRes window EVERY time — even when they have allowed agent changes, because it hides traffic from them; if they decline, the call fails with consent_denied. Like a rule, this one rewrites live traffic — how it is handled, not what it says: ReqRes stops decrypting and recording the host, so neither you nor the user will see its traffic until it is taken off the list in Settings ▸ Capture."
        }
        switch severity {
        case .routine:
            return base
        case .exportsData:
            return base + " This one writes captured traffic to a file, where it outlives the capture run and anything that can read it is no longer governed by ReqRes."
        case .rewritesTraffic:
            return base + " This one rewrites live traffic, so expect it to be read carefully."
        case .destructive:
            return base + " This one destroys state that cannot be restored, so expect it to be refused more often."
        case .actsOnThirdParty:
            return base + " This one sends a real request to a real server, so the user is ALWAYS asked — a standing grant does not cover it — and only idempotent methods are accepted."
        }
    }
}

extension Collection where Element == MCPAgentAction {
    /// The weight a burst is judged by: one panel answers for every action in
    /// it, so it has to speak for the worst thing in the list.
    public var highestSeverity: MCPAgentAction.Severity {
        map(\.severity).max() ?? .routine
    }
}

public enum MCPConsentDecision: Equatable, Sendable {
    case allowed
    case denied(reason: String)
    /// Nobody answered. Distinct from a denial: the agent should tell the
    /// human and may retry, where a denial means stop.
    case timedOut(reason: String)
}

public enum MCPAuditOutcome: String, Codable, Sendable {
    case performed
    case denied
    case timedOut = "timed_out"
    case failed
}

public struct MCPAuditEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var action: MCPAgentAction
    public var outcome: MCPAuditOutcome
    /// The result ("rule #12") or the failure/denial reason.
    public var detail: String?
    /// Set when the human answered after the agent had stopped waiting: the
    /// change was made, but the agent may have been told it failed and retried.
    public var lateDecision: Bool

    /// What the thing looked like BEFORE this entry changed it.
    ///
    /// The log records results ("rule #12"), which is enough to see what
    /// happened and useless for putting it back. Capturing the prior state is
    /// one field now and a data migration once the log has history, so it is
    /// written from the start even though nothing reads it yet. Undo, when it
    /// ships, is itself a write and goes through consent like any other.
    public var previousState: MCPAuditSnapshot?

    /// What this entry CREATED, for the undo that deletes it again. `detail`
    /// already says "rule #12" — in prose, for a human — and reading an id
    /// back out of a sentence is how a log format becomes an API by accident.
    public var created: MCPAuditTarget?

    /// Set once the change has been put back, so the row stops offering an
    /// undo that would now fail (the rule it would restore already exists, or
    /// the one it would delete is gone).
    public var undone: Bool

    /// True when the USER did this from the activity log, not an agent. The
    /// log is read as "what agents did to my app", so an undo appearing in it
    /// unmarked reads as the agent having changed its mind.
    public var byUser: Bool

    /// True for an entry written by a build whose rules MATCH on method
    /// (1.1.0, core C4). An entry without it predates the migration
    /// `host_rules_reqMethod_any_1.1.0`, which rewrote every STORED rule to
    /// any-method but could not reach the snapshots persisted here: their
    /// "GET" is what the old form and MCP default wrote whatever the user
    /// meant, and was never read. Undo maps it to any, so a restored POST
    /// mock matches exactly as it did before (release review, 2026-09-29).
    public var rulesMatchMethod: Bool

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        action: MCPAgentAction,
        outcome: MCPAuditOutcome,
        detail: String? = nil,
        lateDecision: Bool = false,
        previousState: MCPAuditSnapshot? = nil,
        created: MCPAuditTarget? = nil,
        undone: Bool = false,
        byUser: Bool = false,
        rulesMatchMethod: Bool = true
    ) {
        self.id = id
        self.date = date
        self.action = action
        self.outcome = outcome
        self.detail = detail
        self.lateDecision = lateDecision
        self.previousState = previousState
        self.created = created
        self.undone = undone
        self.byUser = byUser
        self.rulesMatchMethod = rulesMatchMethod
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, action, outcome, detail, lateDecision, previousState, created, undone, byUser, rulesMatchMethod
    }

    /// Tolerant of logs written before `lateDecision` or `previousState`
    /// existed, so an upgrade never drops the user's history.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        action = try c.decode(MCPAgentAction.self, forKey: .action)
        outcome = try c.decode(MCPAuditOutcome.self, forKey: .outcome)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        lateDecision = try c.decodeIfPresent(Bool.self, forKey: .lateDecision) ?? false
        previousState = try c.decodeIfPresent(MCPAuditSnapshot.self, forKey: .previousState)
        created = try c.decodeIfPresent(MCPAuditTarget.self, forKey: .created)
        undone = try c.decodeIfPresent(Bool.self, forKey: .undone) ?? false
        byUser = try c.decodeIfPresent(Bool.self, forKey: .byUser) ?? false
        // Absent = written before rules matched on method.
        rulesMatchMethod = try c.decodeIfPresent(Bool.self, forKey: .rulesMatchMethod) ?? false
    }

    /// True when this entry carries enough to be put back — and has not been
    /// already. Creations are reversed by deleting what they made, which needs
    /// the id in `created`; an entry written before that field existed cannot
    /// be undone, which is why it is a field and not a parse of `detail`.
    public var isReversible: Bool {
        guard !undone else { return false }
        switch action.kind {
        case .updateRule, .deleteRule, .removeHost:
            return previousState != nil
        case .excludeHost:
            // Reversed by taking the host it added back OFF the list — not by
            // restoring the whole list, which would undo anything the user
            // changed there since. Only an entry that really added one
            // carries the snapshot (an already-excluded host changes nothing
            // and is never logged as performed).
            guard case .exclusion(let snapshot)? = previousState else { return false }
            return !snapshot.before.contains(snapshot.host)
        case .createRule, .addHost, .mockFromSession:
            return outcome == .performed && created != nil
        case .replayRequest:
            // Nothing in ReqRes changed, and the part that DID change is on
            // someone else's server, where this app has no standing to put
            // anything back. An "undo" here would be a lie.
            return false
        case .answerPausedRequest:
            // By the time anyone reads this row the request has already been
            // sent, or answered without ever being sent. There is no state
            // here to restore — only an exchange that has happened.
            return false
        case .startCapture, .stopCapture, .clearSessions, .exportSessions:
            // Captured traffic that was dropped cannot be recaptured, capture
            // state is a toggle the user can flip themselves, and an export
            // changed nothing in the app to put back — deleting the file it
            // wrote is the user's call, not an undo.
            return false
        case .saveSession, .deleteSavedSession:
            // Saved sessions are undone in the saved-sessions list itself,
            // where the user can see the exchange they are removing — not
            // from the activity log. Undoing a DELETE from here would mean
            // `MCPAuditSnapshot` carrying a whole captured exchange, so the
            // persisted, exportable activity log would become a second copy
            // of captured headers and bodies. One place is already the most
            // that material should live in.
            return false
        }
    }
}

/// The prior state of whatever an agent changed, stored so it can be restored.
///
/// Deliberately a value, not a reference into the store: by the time someone
/// reads the log the rule may have been changed again or deleted, and an undo
/// that resolved state at read time would restore the wrong thing.
public enum MCPAuditSnapshot: Codable, Equatable, Sendable {
    case rule(MCPRule)
    case host(MCPHost)
    /// The exclusion list before an agent added `host` to it.
    case exclusion(MCPExclusionSnapshot)

    private enum CodingKeys: String, CodingKey { case kind, rule, host, exclusion }
    private enum Kind: String, Codable { case rule, host, exclusion }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rule(let value):
            try c.encode(Kind.rule, forKey: .kind)
            try c.encode(value, forKey: .rule)
        case .host(let value):
            try c.encode(Kind.host, forKey: .kind)
            try c.encode(value, forKey: .host)
        case .exclusion(let value):
            try c.encode(Kind.exclusion, forKey: .kind)
            try c.encode(value, forKey: .exclusion)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .rule: self = .rule(try c.decode(MCPRule.self, forKey: .rule))
        case .host: self = .host(try c.decode(MCPHost.self, forKey: .host))
        case .exclusion: self = .exclusion(try c.decode(MCPExclusionSnapshot.self, forKey: .exclusion))
        }
    }

    /// One line for the activity list, so a row can say what it would put back.
    public var summary: String {
        switch self {
        case .rule(let rule):
            let state = rule.enabled ? "enabled" : "disabled"
            return "rule \(rule.id) (\(rule.mode.rawValue), \(state)) \(rule.path)"
        case .host(let host):
            return "host filter \(host.host)"
        case .exclusion(let snapshot):
            return snapshot.before.isEmpty
                ? "no excluded hosts (before \(snapshot.host) was added)"
                : "excluded hosts \(snapshot.before.joined(separator: ", ")) (before \(snapshot.host) was added)"
        }
    }
}

/// What `exclude_host` changed: the entry it added and the list before it.
/// Host names and wildcard patterns only — nothing captured, nothing secret.
public struct MCPExclusionSnapshot: Codable, Equatable, Sendable {
    /// The canonical entry that was added (`api.example.com`, `*.example.com`).
    public var host: String
    public var before: [String]

    public init(host: String, before: [String]) {
        self.host = host
        self.before = before
    }
}

// MARK: - Exclusions (exclude_host)

/// What an agent sends to `exclude_host`.
public struct MCPExcludeHostRequest: Codable, Equatable, Sendable {
    /// A bare hostname or a `*.` wildcard — no scheme, path or port needed.
    public var host: String

    public init(host: String) {
        self.host = host
    }
}

/// What `exclude_host` answers.
public struct MCPExclusionResult: Codable, Equatable, Sendable {
    /// The entry as stored (canonical), or the entry that already covers it.
    public var host: String
    /// True when nothing changed because the host was already excluded — no
    /// approval was asked and nothing was logged.
    public var alreadyExcluded: Bool
    /// The whole list after the call.
    public var excludedHosts: [String]

    public init(host: String, alreadyExcluded: Bool, excludedHosts: [String]) {
        self.host = host
        self.alreadyExcluded = alreadyExcluded
        self.excludedHosts = excludedHosts
    }
}

/// What the app says about a host an agent wants excluded, BEFORE anyone is
/// asked: a bad name must not raise an approval panel, and an already
/// excluded one has nothing to approve.
public enum MCPExclusionCheck: Equatable, Sendable {
    /// Could never exclude anything; the message says what to send instead.
    case invalid(String)
    /// Already covered by `entry` (itself, or a `*.` wildcard above it).
    case alreadyExcluded(entry: String)
    /// Not covered: `entry` is what would be stored.
    case add(entry: String)
}

/// The exclusion list lives in the app (Settings ▸ Capture) and its matching
/// rules in Utils, which this pure layer cannot import — so the app answers
/// both questions.
public protocol MCPExclusionProviding {
    func excludedHosts() throws -> [String]
    func check(_ raw: String) -> MCPExclusionCheck
    /// Adds an entry `check` returned as `.add`, pushes the list to the
    /// extension, and returns the list after.
    func exclude(_ entry: String) throws -> [String]
}

// MARK: - Errors

/// Thrown by the app's write seams; the router maps each case to an HTTP
/// status and a stable error code the agent can act on.
public enum MCPWriteError: Error, Equatable, Sendable {
    /// Bad input (400).
    case invalid(String)
    /// No such rule/host/session (404).
    case notFound(String)
    /// The free tier's limit — same as the app's own form (403 `limit_reached`).
    case limitReached(String)
    /// The write surface is not wired or capture cannot be controlled now (503).
    case unavailable(String)
    /// The operation ran and failed (500).
    case failed(String)

    public var message: String {
        switch self {
        case .invalid(let m), .notFound(let m), .limitReached(let m), .unavailable(let m), .failed(let m):
            return m
        }
    }
}

// MARK: - Seams the app implements

public protocol MCPRuleProviding {
    func rules() throws -> [MCPRule]
    /// The draft is already validated and normalised.
    func createRule(_ draft: MCPRuleDraft) throws -> MCPRule
    func updateRule(id: Int64, patch: MCPRulePatch) throws -> MCPRule
    func deleteRule(id: Int64) throws
    func mockFromSession(_ request: MCPMockFromSessionRequest) throws -> MCPRule
}

public protocol MCPHostProviding {
    func hosts() throws -> [MCPHost]
    func addHost(_ draft: MCPHostDraft) throws -> MCPHost
    func removeHost(id: Int64) throws
}

public protocol MCPCaptureControlling {
    func startCapture() throws
    func stopCapture() throws
    /// Returns how many sessions were dropped.
    func clearSessions() throws -> Int
}

/// The human-in-the-loop gate. Synchronous on purpose: the bridge waits
/// for the answer (the app shows a sheet and times out into a denial).
public protocol MCPWriteConsenting {
    func authorize(_ action: MCPAgentAction) -> MCPConsentDecision
}

public protocol MCPAuditLogging {
    func record(_ entry: MCPAuditEntry)
}

/// All five write seams, handed to the router together.
public struct MCPWriteSeams {
    public var rules: MCPRuleProviding
    public var hosts: MCPHostProviding
    public var capture: MCPCaptureControlling
    public var consent: MCPWriteConsenting
    public var audit: MCPAuditLogging
    /// Optional the way `MCPWriteSeams` itself is optional on the router: a
    /// build that has not wired file egress answers 503 for it and keeps
    /// every other write working, rather than refusing to construct.
    public var exporter: MCPSessionExporting?
    /// Sends replays. Same optionality and for the same reason: a build that
    /// has not wired it answers 503 for that one route.
    public var replay: MCPReplaying?
    /// Held requests and the power to answer them. Optional like the rest:
    /// a build without it answers 503 there and keeps every other write
    /// working.
    public var breakpoints: MCPBreakpointProviding?
    /// The saved-session store, same optionality and for the same reason.
    /// Its READS need no consent, but it lives here rather than beside
    /// `sessions` because it is one store the app either wired or did not,
    /// and splitting it would mean two ways to answer "not in this build".
    public var savedSessions: MCPSavedSessionProviding?
    /// Settings ▸ Capture's exclusion list (`exclude_host`). Optional like the
    /// rest: a build without it answers 503 for that one route.
    public var exclusions: MCPExclusionProviding?

    public init(
        rules: MCPRuleProviding,
        hosts: MCPHostProviding,
        capture: MCPCaptureControlling,
        consent: MCPWriteConsenting,
        audit: MCPAuditLogging,
        exporter: MCPSessionExporting? = nil,
        savedSessions: MCPSavedSessionProviding? = nil,
        replay: MCPReplaying? = nil,
        breakpoints: MCPBreakpointProviding? = nil,
        exclusions: MCPExclusionProviding? = nil
    ) {
        self.rules = rules
        self.hosts = hosts
        self.capture = capture
        self.consent = consent
        self.audit = audit
        self.exporter = exporter
        self.savedSessions = savedSessions
        self.replay = replay
        self.breakpoints = breakpoints
        self.exclusions = exclusions
    }
}

/// Writes an export where the app can put files. The bridge owns the bytes
/// and the consent; this owns only the directory and the write, because the
/// pure layer must not know about the sandbox container.
public protocol MCPSessionExporting {
    /// Returns where the file landed. `filename` has already been validated
    /// by `MCPWriteValidation.exportFilename` — a bare name, no separators,
    /// ending in `.har` — so an implementation appends it to its own
    /// directory and must never treat it as a path.
    func writeExport(_ data: Data, filename: String) throws -> URL
}
