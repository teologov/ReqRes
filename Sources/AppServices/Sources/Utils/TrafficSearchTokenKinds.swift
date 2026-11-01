//
//  TrafficSearchTokenKinds.swift
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
//  The value types behind the `status:`, `path:` and `app:` search tokens.
//
//  These were written beside a parallel copy of the whole token stack, because
//  `TrafficSearchFilter` was being edited elsewhere at the time and could not
//  be touched. The token kinds now live in `TrafficSearchFilter` itself, which
//  is the only place a prefix is parsed, so what survives here is what that
//  file needs: turning a status query into something matchable, pulling the
//  path out of a URL, and deciding whether a process name satisfies `app:`.
//

import Foundation

// MARK: - Status match

/// A parsed `status:` query: one exact code, a class such as `5xx`, or an
/// explicit range such as `400-499`.
///
/// `MCPSessionFilter` (MCPKit) already parses "exact or `xx` class" for the
/// MCP `status` filter — this mirrors that check (`hasSuffix("xx")`,
/// `count == 3`, `first?.wholeNumberValue`) so the two surfaces agree on what
/// "5xx" means, and adds the range form the toolbar search needs on top.
public enum TrafficSearchStatusMatch: Hashable, Sendable {
    case exact(Int)
    case range(ClosedRange<Int>)

    /// A status code is one of IANA's five classes; anything outside this
    /// is rejected rather than accepted as a code nothing can ever return.
    private static let validCodes = 100...599

    /// What a committed chip shows back. A hundreds-aligned, 100-wide range
    /// (whether the user typed `5xx` or the equivalent `500-599`) prints as
    /// `5xx`, since the two mean the same set of codes; any other range
    /// prints as the bounds the user typed.
    public var displayText: String {
        switch self {
        case .exact(let code):
            return String(code)
        case .range(let range):
            if range.count == 100, range.lowerBound % 100 == 0 {
                return "\(range.lowerBound / 100)xx"
            }
            return "\(range.lowerBound)-\(range.upperBound)"
        }
    }

    /// Parses `404`, `5xx` / `5XX`, or `400-499`.
    ///
    /// Returns nil for anything else — a typo'd code, digits outside
    /// 100...599, a backwards range — on purpose. `status:` has no
    /// autocomplete forcing a valid shape the way `host:` chips do, so a
    /// mistyped query here is the common case, and a token that always
    /// evaluates false is indistinguishable from "nothing happened", the one
    /// failure mode a search field must not have. The contract for a nil
    /// result is: the caller falls back to matching the whole raw token text
    /// (`status:banana`) as ordinary free text, exactly as
    /// `TrafficSearchTokenKind.parse` already falls back to free text for
    /// anything that isn't `host:`.
    public static func parse(_ raw: String) -> TrafficSearchStatusMatch? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if let code = Int(text) {
            guard validCodes.contains(code) else { return nil }
            return .exact(code)
        }

        let lowered = text.lowercased()
        if lowered.count == 3, lowered.hasSuffix("xx"),
           let leadingDigit = lowered.first?.wholeNumberValue,
           (1...5).contains(leadingDigit) {
            let base = leadingDigit * 100
            return .range(base...(base + 99))
        }

        let bounds = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if bounds.count == 2,
           let lower = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
           let upper = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
           lower <= upper,
           validCodes.contains(lower), validCodes.contains(upper) {
            return .range(lower...upper)
        }

        return nil
    }

    public func matches(_ code: Int) -> Bool {
        switch self {
        case .exact(let value): return value == code
        case .range(let range): return range.contains(code)
        }
    }
}

// MARK: - Path extraction

public enum TrafficSearchPath {
    /// The path component of a captured URL, e.g. `/v1/users` out of
    /// `https://api.example.com/v1/users?id=1` — deliberately excluding the
    /// host and the query, so `path:` cannot be satisfied by a host-shaped
    /// or query-shaped needle. That overlap already belongs to `host:` and
    /// to free text, which already substring-matches the whole URL.
    ///
    /// `URLComponents(string:)` succeeding with an empty `path` (a bare
    /// `https://api.example.com`) is a real, empty path, not a parse
    /// failure — it must NOT fall back to the raw URL, or `path:` would
    /// start matching on the host again for exactly the requests this
    /// function exists to exclude that from. Only an unparseable string
    /// (not a URL at all) falls back to the raw text, so a malformed
    /// capture stays searchable rather than being silently excluded from
    /// every `path:` query.
    public static func extract(from url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }
        return components.path
    }
}

// MARK: - App match

/// The rule behind the `app:` token: does the process that opened a
/// session's connection satisfy what the user typed?
///
/// Both `TrafficSearchToken.matches` and `TrafficSearchFilter.matches` call
/// this, so the single-token statement and the filter cannot disagree.
public enum TrafficSearchAppMatch {
    /// What the traffic table shows for a session whose process could not be
    /// named — attribution is per connection and can fail (a system process
    /// such as nsurlsessiond, a socket already closed, a kernel table that
    /// would not parse). It is a first-class value in the UI, so `app:unknown`
    /// must be able to select it.
    public static let unknown = "Unknown"

    /// Case-insensitive SUBSTRING on the process name: `app:claude` finds
    /// "Claude" (the desktop app) and "claude" (the CLI) alike. Exact
    /// would be wrong here because the name is whatever the executable is
    /// called, which the user is not looking at, and Chromium-style helper
    /// processes carry the parent's name inside theirs.
    ///
    /// A session with NO name (nil or blank) matches exactly one query — the
    /// word "unknown", in any case, the label the table prints for it — and
    /// nothing else. Not a substring there: `app:no` or `app:own` selecting
    /// every unattributed session would be a surprise, and the label is a
    /// placeholder the user reads, not a name the process has.
    ///
    /// A blank query matches nothing rather than everything; the token and
    /// the filter both refuse to commit one, so this only guards a filter
    /// built by hand.
    public static func matches(_ wanted: String, appName: String?) -> Bool {
        let needle = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        guard let name = appName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return needle == unknown.lowercased()
        }
        return name.lowercased().contains(needle)
    }
}

// MARK: - Country match

/// The rule behind the `country:` token (destination-map UX spec §5.2): does
/// a session's destination satisfy what the user typed?
///
/// The vocabulary is MCPKit's `TrafficDestination.token` — `US` for a
/// country, `local` / `mac` / `unknown` for the three classes — spelled here
/// a second time because Utils cannot import MCPKit (it would drag Sentry and
/// Sparkle into the sandboxed helper). `UtilsTests` pins the two spellings
/// equal, the way it pins `TrafficSearchAppMatch.unknown` to the App column's
/// label.
public enum TrafficSearchCountryMatch {
    public static let local = "local"
    public static let mac = "mac"
    public static let unknown = "unknown"

    /// What a chip shows for each class token; a code shows itself and the
    /// chip view upgrades it to the localised name.
    public static let localDisplayName = "Local Network"
    public static let macDisplayName = "This Mac"
    public static let unknownDisplayName = "Unknown"

    /// Exactly two ASCII letters → upper-cased; `local` / `mac` / `unknown`
    /// case-insensitively → lower-cased; anything else → nil, which the token
    /// parser turns into free text (the `status:banana` contract). Country
    /// NAMES are resolved BEFORE this by the field model (spec §5.3) — a
    /// name is never a token, so `country:Germany` typed straight in stays
    /// free text rather than a chip that can never match.
    public static func normalize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.count == 2, text.allSatisfy({ $0.isASCII && $0.isLetter }) {
            return text.uppercased()
        }
        switch text.lowercased() {
        case local: return local
        case mac: return mac
        case unknown: return unknown
        default: return nil
        }
    }

    /// `"US"` for a code, `"This Mac"` / `"Local Network"` / `"Unknown"` for
    /// the classes; an unnormalised value is shown as typed.
    public static func displayName(forToken token: String) -> String {
        switch normalize(token) {
        case mac?: return macDisplayName
        case local?: return localDisplayName
        case unknown?: return unknownDisplayName
        case let code?: return code
        case nil: return token
        }
    }

    /// Exact on the normalised token. A nil `country` — the caller did not
    /// resolve the session — satisfies NO token, `unknown` included: the
    /// resolver says `unknown` when it could not place an address, and that
    /// is a different fact from the filter never having been asked. A
    /// `wanted` that is not a token matches nothing either; the token and the
    /// filter both refuse to commit one, so this only guards a filter built
    /// by hand.
    public static func matches(_ wanted: String, country: String?) -> Bool {
        guard let wantedToken = normalize(wanted), let country, let actual = normalize(country) else { return false }
        return wantedToken == actual
    }
}

// MARK: - Outcome match

/// The rule behind the `outcome:` token (protocol PRD 3.4): how a session
/// ended — `completed`, `failed`, `aborted` or `timed_out`.
///
/// Spelled here a second time for the reason `TrafficSearchCountryMatch` is:
/// Utils cannot import MCPKit, whose `MCPSessionOutcome.token` is the same
/// vocabulary. `UtilsTests` pins the two equal.
public enum TrafficSearchOutcomeMatch {
    public static let completed = "completed"
    public static let failed = "failed"
    public static let aborted = "aborted"
    public static let timedOut = "timed_out"

    /// In the order the completion panel offers them: the failures first,
    /// because nobody types `outcome:` to find what worked.
    public static let all = [failed, aborted, timedOut, completed]

    /// Case-insensitive, with `_`/`-` ignored, so `timedout`, `timed-out`,
    /// `timedOut` and `timeout` are one token; anything else → nil (free text,
    /// the `status:banana` contract).
    public static func normalize(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch key {
        case "completed", "complete": return completed
        case "failed", "failure": return failed
        case "aborted": return aborted
        case "timedout", "timeout": return timedOut
        default: return nil
        }
    }

    /// What a chip shows: "Failed", "Aborted", "Timed out", "Completed".
    public static func displayName(forToken token: String) -> String {
        switch normalize(token) {
        case failed?: return "Failed"
        case aborted?: return "Aborted"
        case timedOut?: return "Timed out"
        case completed?: return "Completed"
        default: return token
        }
    }

    /// `outcome` is the session's token; nil means an older core that
    /// records only completed exchanges, so it reads as `completed`. (Unlike
    /// `country`, nil is not "nobody asked": every row HAS an outcome.)
    public static func matches(_ wanted: String, outcome: String?) -> Bool {
        guard let wantedToken = normalize(wanted) else { return false }
        let actual = outcome.flatMap(normalize) ?? completed
        return wantedToken == actual
    }
}

// MARK: - gRPC status match

/// The rule behind the `grpc:` token (protocol-engine doc §S8): the RPC's
/// own status on a gRPC-Web, Connect or native gRPC row — `grpc:error`
/// (anything but OK), `grpc:ok`, `grpc:NOT_FOUND`, `grpc:5`.
///
/// Spelled here a second time for the reason `TrafficSearchOutcomeMatch` is:
/// Utils cannot import MCPKit, whose `RPCStatusCode` / `RPCStatusMatch` are
/// the same vocabulary. `UtilsTests` pins the two equal.
public enum TrafficSearchGRPCMatch {
    public static let error = "error"
    /// Index = code.
    public static let names = [
        "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND",
        "ALREADY_EXISTS", "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION",
        "ABORTED", "OUT_OF_RANGE", "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS",
        "UNAUTHENTICATED",
    ]

    /// What the completion panel offers: any error first (what people look
    /// for), then OK, then the error codes most often seen, then the rest.
    public static let suggestions: [String] = {
        let common = ["NOT_FOUND", "UNAVAILABLE", "PERMISSION_DENIED", "UNAUTHENTICATED", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "INTERNAL"]
        let rest = names.dropFirst().filter { !common.contains($0) }
        return [error, "OK"] + common + rest
    }()

    /// `error` (also `errors`, `failed`), `OK`, a code name in either
    /// spelling (`not_found`, `NotFound`, Connect's `canceled`) upper-cased,
    /// or a non-negative number — a known one as its name (`5` → `NOT_FOUND`),
    /// any other as digits. Nil otherwise (free text, the `status:banana`
    /// contract).
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        switch key {
        case "error", "errors", "failed", "!ok", "notok": return error
        case "canceled": return names[1]
        default: break
        }
        if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(trimmed), number >= 0 {
            return number < names.count ? names[number] : String(number)
        }
        return names.first { $0.lowercased().replacingOccurrences(of: "_", with: "") == key }
    }

    /// The status code a normalised token names; nil for `error`.
    public static func code(forToken token: String) -> Int? {
        if let index = names.firstIndex(of: token) { return index }
        return Int(token)
    }

    /// What a chip shows: "gRPC error", "gRPC NOT_FOUND".
    public static func displayName(forToken token: String) -> String {
        "gRPC " + (normalize(token) ?? token)
    }

    /// `grpcStatus` is the row's RPC status, nil for a row that is not an
    /// RPC (or whose status was not recorded) — which matches nothing, not
    /// even `error`.
    public static func matches(_ wanted: String, grpcStatus: Int?) -> Bool {
        guard let grpcStatus, let token = normalize(wanted) else { return false }
        if token == error { return grpcStatus != 0 }
        return code(forToken: token) == grpcStatus
    }
}

// MARK: - Protocol match

/// The rule behind the `proto:` token (protocol-engine doc §S9): what a row
/// spoke — `proto:h1` (HTTP/1.x), `proto:h2` (HTTP/2, since the user turned
/// it on), `proto:ws` (a WebSocket after its upgrade), `proto:relay` (a
/// connection relayed without being decrypted).
///
/// Spelled here a second time for the reason `TrafficSearchGRPCMatch` is:
/// Utils cannot import MCPKit, whose `SessionProtocol` is the same
/// vocabulary. `UtilsTests` pins the two equal, spelling for spelling.
public enum TrafficSearchProtocolMatch {
    /// The four tokens, in the order the completion panel offers them.
    public static let all = ["h2", "h1", "ws", "relay"]

    /// The token for a spelling people type — the token itself, `http1`,
    /// `http/1.1`, `1.1`, `http2`, `http/2`, `2`, `websocket`, `tcp` — or nil
    /// (free text, the `status:banana` contract).
    public static func normalize(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "h1", "http1", "http/1", "http/1.1", "http/1.0", "1", "1.1", "1.0", "http1.1": return "h1"
        case "h2", "http2", "http/2", "http/2.0", "2", "2.0": return "h2"
        case "ws", "wss", "websocket", "websockets": return "ws"
        case "relay", "tcp", "relayed": return "relay"
        default: return nil
        }
    }

    /// What a chip shows: "HTTP/2", "HTTP/1.x", "WebSocket", "Relay".
    public static func displayName(forToken token: String) -> String {
        switch normalize(token) {
        case "h1": return "HTTP/1.x"
        case "h2": return "HTTP/2"
        case "ws": return "WebSocket"
        case "relay": return "Relay"
        default: return token
        }
    }

    /// `proto` is the row's token (`h1` / `h2` / `ws` / `relay`), nil when it
    /// recorded no protocol — which matches nothing.
    public static func matches(_ wanted: String, proto: String?) -> Bool {
        guard let proto, let wantedToken = normalize(wanted) else { return false }
        return normalize(proto) == wantedToken
    }
}
