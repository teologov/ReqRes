//
//  TrafficSearchFilter.swift
//  ReqRes
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
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
//  The traffic search filter as pure data: committed tokens plus free text,
//  the matching rule, and the host and app suggestions. Lives in `Utils` so a
//  plain `swift test` covers it — no AppKit, no closed core. The toolbar's
//  field (Sources/UI/Views/Search) only edits this and observes it.
//

import Foundation

// MARK: - Tokens

/// A token committed into the traffic search field as a chip.
///
/// One case per `TrafficSearchTokenKind`. `app` is the process that opened
/// the connection — the attribution the core records per session — and the
/// one kind whose value can be the table's "Unknown" placeholder. `pid` is
/// that process's id, for following ONE instance of a tool when several run
/// (three `claude` processes on one Mac is ordinary).
public enum TrafficSearchToken: Identifiable, Hashable, Sendable {
    case host(String)
    case method(String)
    case status(TrafficSearchStatusMatch)
    case path(String)
    case app(String)
    case pid(Int)
    /// Where the request went (destination-map UX spec §5.2): the value is
    /// the NORMALISED token — an upper-cased two-letter code, or `local` /
    /// `mac` / `unknown` — never a country name.
    case country(String)
    /// How the request ended (protocol PRD 3.4): the NORMALISED token —
    /// `failed`, `aborted`, `timed_out` or `completed`.
    case outcome(String)
    /// The RPC's own status (protocol-engine doc §S8): the NORMALISED token —
    /// `error`, or a code name (`OK`, `NOT_FOUND`), or digits for a code
    /// outside the table.
    case grpc(String)
    /// What the row spoke (protocol-engine doc §S9): the NORMALISED token —
    /// `h1`, `h2`, `ws` or `relay`.
    case proto(String)

    public var id: String {
        switch self {
        case .host(let host): return "host-\(host.lowercased())"
        case .method(let method): return "method-\(method.lowercased())"
        case .status(let match): return "status-\(match.displayText)"
        case .path(let path): return "path-\(path.lowercased())"
        case .app(let app): return "app-\(app.lowercased())"
        case .pid(let pid): return "pid-\(pid)"
        case .country(let token): return "country-\(token.lowercased())"
        case .outcome(let token): return "outcome-\(token.lowercased())"
        case .grpc(let token): return "grpc-\(token.lowercased())"
        case .proto(let token): return "proto-\(token.lowercased())"
        }
    }

    /// What the chip shows. A pid is always written `pid 9437` (UX spec §1):
    /// a bare number beside a name reads as a count. A country chip shows the
    /// code here; the chip view upgrades it to the localised name (spec §5.3),
    /// which Utils cannot do without a locale it should not own.
    public var displayName: String {
        switch self {
        case .host(let host): return host
        case .method(let method): return method.uppercased()
        case .status(let match): return match.displayText
        case .path(let path): return path
        case .app(let app): return app
        case .pid(let pid): return "pid \(pid)"
        case .country(let token): return TrafficSearchCountryMatch.displayName(forToken: token)
        case .outcome(let token): return TrafficSearchOutcomeMatch.displayName(forToken: token)
        case .grpc(let token): return TrafficSearchGRPCMatch.displayName(forToken: token)
        case .proto(let token): return TrafficSearchProtocolMatch.displayName(forToken: token)
        }
    }

    public var kind: TrafficSearchTokenKind {
        switch self {
        case .host: return .host
        case .method: return .method
        case .status: return .status
        case .path: return .path
        case .app: return .app
        case .pid: return .pid
        case .country: return .country
        case .outcome: return .outcome
        case .grpc: return .grpc
        case .proto: return .proto
        }
    }

    /// Turns a parsed prefix and its query into a committed token.
    ///
    /// Returns nil when the query cannot make a usable token, and the caller's
    /// contract for nil is to search the whole raw text (`status:banana`) as
    /// ordinary free text. A token that can never match is indistinguishable
    /// from "nothing happened", which is the one failure a search field must
    /// not have.
    public static func parse(kind: TrafficSearchTokenKind, query: String) -> TrafficSearchToken? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        switch kind {
        case .host: return .host(trimmed)
        case .method: return .method(trimmed)
        case .path: return .path(trimmed)
        case .app: return .app(trimmed)
        case .status: return TrafficSearchStatusMatch.parse(trimmed).map { .status($0) }
        case .pid: return parsePid(trimmed).map { .pid($0) }
        case .country: return TrafficSearchCountryMatch.normalize(trimmed).map { .country($0) }
        case .outcome: return TrafficSearchOutcomeMatch.normalize(trimmed).map { .outcome($0) }
        case .grpc: return TrafficSearchGRPCMatch.normalize(trimmed).map { .grpc($0) }
        case .proto: return TrafficSearchProtocolMatch.normalize(trimmed).map { .proto($0) }
        }
    }

    /// Digits only. `Int("+5")` and `Int("-5")` parse, and neither is a
    /// process id; `pid:curl` is a typo for `app:curl` and falls back to free
    /// text like every other unusable query, rather than becoming a chip that
    /// silently matches nothing.
    /// Digits only, and positive: pid 0 is the kernel and never opens a
    /// connection, so `pid:0` stays free text like `pid:abc` does.
    private static func parsePid(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let pid = Int(text), pid > 0 else { return nil }
        return pid
    }

    /// Whether one token matches a session on its own.
    ///
    /// `TrafficSearchFilter` evaluates its tokens by kind rather than calling
    /// this in a loop, because tokens of one kind are OR-ed while the kinds are
    /// AND-ed, and a flat loop cannot express that. This exists so a single
    /// token's semantics can be stated and tested without building a filter
    /// around it.
    ///
    /// `app` is the name of the process that opened the connection, or nil
    /// when attribution has none — `TrafficSearchAppMatch` is how the two are
    /// told apart. `pid` is that process's id; a session without one never
    /// satisfies a pid token. `country` is the session's destination token
    /// (`US` / `local` / `mac` / `unknown`), nil when the caller did not
    /// resolve it — and nil never satisfies a country token. All three
    /// default to nil HERE, at the single-token level, so a token's semantics
    /// can be stated without an attribution in hand — the filter's `matches`
    /// has no such defaults (errata 6).
    public func matches(host: String, url: String, method: String, status: String?, app: String? = nil, pid: Int? = nil, country: String? = nil, outcome: String? = nil,
                        grpcStatus: Int? = nil, proto: String? = nil) -> Bool {
        switch self {
        case .host(let wanted):
            return wanted.caseInsensitiveCompare(host) == .orderedSame
        case .method(let wanted):
            return wanted.caseInsensitiveCompare(method) == .orderedSame
        case .status(let match):
            guard let status, let code = Int(status.trimmingCharacters(in: .whitespaces)) else {
                return false
            }
            return match.matches(code)
        case .path(let needle):
            return TrafficSearchPath.extract(from: url).localizedCaseInsensitiveContains(needle)
        case .app(let wanted):
            return TrafficSearchAppMatch.matches(wanted, appName: app)
        case .pid(let wanted):
            return pid == wanted
        case .country(let wanted):
            return TrafficSearchCountryMatch.matches(wanted, country: country)
        case .outcome(let wanted):
            return TrafficSearchOutcomeMatch.matches(wanted, outcome: outcome)
        case .grpc(let wanted):
            return TrafficSearchGRPCMatch.matches(wanted, grpcStatus: grpcStatus)
        case .proto(let wanted):
            return TrafficSearchProtocolMatch.matches(wanted, proto: proto)
        }
    }
}

/// The kinds of token the field understands, each typed as `<kind>:`.
public enum TrafficSearchTokenKind: String, CaseIterable, Sendable {
    case host
    case method
    case status
    case path
    /// The process that opened the connection: `app:claude`.
    case app
    /// One process by id: `pid:9437`. `allCases` drives prefix parsing, and
    /// a test pins the order so an insertion cannot shadow an earlier prefix.
    case pid
    /// Where the request went: `country:US`, `country:local`, `country:mac`,
    /// `country:unknown` (destination-map UX spec §5.2). Appended LAST, by
    /// the same rule as `pid` before it.
    case country
    /// How the request ended: `outcome:failed`, `outcome:aborted`,
    /// `outcome:timed_out`, `outcome:completed` (protocol PRD 3.4). Appended
    /// LAST, by the rule `pid` and `country` followed.
    case outcome
    /// The RPC's own status: `grpc:error`, `grpc:ok`, `grpc:NOT_FOUND`,
    /// `grpc:5` (protocol-engine doc §S8). Appended LAST, by the same rule.
    case grpc
    /// What the row spoke: `proto:h1`, `proto:h2`, `proto:ws`, `proto:relay`
    /// (protocol-engine doc §S9). Appended LAST, by the same rule.
    case proto

    /// What the completion panel offers once someone has typed the prefix.
    /// Hosts, apps, pids and countries come from the traffic itself, so they
    /// are supplied separately (`TrafficSearchSuggestions.hosts` / `.apps`,
    /// the pid candidates the session index keeps, and the destination
    /// index's rows); these are fixed vocabularies.
    public var staticSuggestions: [String] {
        switch self {
        case .host: return []
        case .method: return ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
        case .status: return ["2xx", "3xx", "4xx", "5xx"]
        case .path: return []
        case .app: return []
        case .pid: return []
        case .country: return []
        case .outcome: return TrafficSearchOutcomeMatch.all
        case .grpc: return TrafficSearchGRPCMatch.suggestions
        case .proto: return TrafficSearchProtocolMatch.all
        }
    }

    /// What the user types to start a token of this kind: `host:`.
    public var prefix: String { rawValue + ":" }

    /// The kind whose prefix the typed text starts with (case-insensitive,
    /// leading whitespace ignored) and the query after it, or nil for free
    /// text.
    public static func parse(_ text: String) -> (kind: TrafficSearchTokenKind, query: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        for kind in allCases where lowered.hasPrefix(kind.prefix) {
            let query = String(trimmed.dropFirst(kind.prefix.count)).trimmingCharacters(in: .whitespaces)
            return (kind, query)
        }
        return nil
    }
}

// MARK: - Filter

/// Committed tokens plus free text.
public struct TrafficSearchFilter: Equatable, Sendable {
    public var freeText: String
    /// Committed hosts, in the order they were added; compared case-insensitively.
    public var hosts: [String]
    /// Committed methods, compared case-insensitively.
    public var methods: [String]
    /// Committed status matches: an exact code, a class such as 5xx, or a range.
    public var statuses: [TrafficSearchStatusMatch]
    /// Committed path fragments, matched against the URL's path only.
    public var paths: [String]
    /// Committed app fragments, matched as case-insensitive substrings of the
    /// process name; `Unknown` selects the sessions that have none.
    public var apps: [String]
    /// Committed process ids, matched exactly; a session with no pid matches
    /// none of them.
    public var pids: [Int]
    /// Committed destination tokens (`US`, `local`, `mac`, `unknown`),
    /// OR-ed among themselves; a session whose destination was not resolved
    /// (nil) matches none of them.
    public var countries: [String]
    /// Committed outcome tokens (`failed`, `aborted`, `timed_out`,
    /// `completed`), OR-ed among themselves.
    public var outcomes: [String]
    /// Committed gRPC status tokens (`error`, `OK`, `NOT_FOUND`, …), OR-ed
    /// among themselves; a row with no RPC status matches none.
    public var grpcStatuses: [String]
    /// Committed protocol tokens (`h1`, `h2`, `ws`, `relay`), OR-ed among
    /// themselves; a row with no recorded protocol matches none.
    public var protocols: [String]

    public init(
        freeText: String = "",
        hosts: [String] = [],
        methods: [String] = [],
        statuses: [TrafficSearchStatusMatch] = [],
        paths: [String] = [],
        apps: [String] = [],
        pids: [Int] = [],
        countries: [String] = [],
        outcomes: [String] = [],
        grpcStatuses: [String] = [],
        protocols: [String] = []
    ) {
        self.freeText = freeText
        self.hosts = hosts
        self.methods = methods
        self.statuses = statuses
        self.paths = paths
        self.apps = apps
        self.pids = pids
        self.countries = countries
        self.outcomes = outcomes
        self.grpcStatuses = grpcStatuses
        self.protocols = protocols
    }

    public var trimmedFreeText: String {
        freeText.trimmingCharacters(in: .whitespaces)
    }

    /// No criteria at all — every session passes.
    public var isEmpty: Bool {
        trimmedFreeText.isEmpty && !hasTokens
    }

    public var hasTokens: Bool {
        !hosts.isEmpty || !methods.isEmpty || !statuses.isEmpty || !paths.isEmpty || !apps.isEmpty || !pids.isEmpty || !countries.isEmpty || !outcomes.isEmpty
            || !grpcStatuses.isEmpty || !protocols.isEmpty
    }

    /// The committed tokens, as the chips render them, in a stable order so
    /// the chip row does not reshuffle when an unrelated token is added.
    public var tokens: [TrafficSearchToken] {
        hosts.map { .host($0) }
            + methods.map { .method($0) }
            + statuses.map { .status($0) }
            + paths.map { .path($0) }
            + apps.map { .app($0) }
            + pids.map { .pid($0) }
            + countries.map { .country($0) }
            + outcomes.map { .outcome($0) }
            + grpcStatuses.map { .grpc($0) }
            + protocols.map { .proto($0) }
    }

    /// Adds a token; a host already committed (in any case) is not added twice.
    public mutating func addToken(_ token: TrafficSearchToken) {
        switch token {
        case .host(let host):
            let trimmed = host.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !containsHost(trimmed) else { return }
            hosts.append(trimmed)
        case .method(let method):
            let trimmed = method.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !methods.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            else { return }
            methods.append(trimmed)
        case .status(let match):
            guard !statuses.contains(match) else { return }
            statuses.append(match)
        case .path(let path):
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !paths.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            else { return }
            paths.append(trimmed)
        case .app(let app):
            let trimmed = app.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !containsApp(trimmed) else { return }
            apps.append(trimmed)
        case .pid(let pid):
            guard !pids.contains(pid) else { return }
            pids.append(pid)
        case .country(let token):
            // Normalised on the way in, so `.country("us")` and
            // `.country("US")` are one chip, and a value that is not a
            // token at all (a name, a typo) is refused rather than kept as a
            // chip that can never match.
            guard let normalized = TrafficSearchCountryMatch.normalize(token), !containsCountry(normalized) else { return }
            countries.append(normalized)
        case .outcome(let token):
            guard let normalized = TrafficSearchOutcomeMatch.normalize(token), !outcomes.contains(normalized) else { return }
            outcomes.append(normalized)
        case .grpc(let token):
            guard let normalized = TrafficSearchGRPCMatch.normalize(token), !grpcStatuses.contains(normalized) else { return }
            grpcStatuses.append(normalized)
        case .proto(let token):
            guard let normalized = TrafficSearchProtocolMatch.normalize(token), !protocols.contains(normalized) else { return }
            protocols.append(normalized)
        }
    }

    public mutating func removeToken(_ token: TrafficSearchToken) {
        switch token {
        case .host(let host):
            hosts.removeAll { $0.caseInsensitiveCompare(host) == .orderedSame }
        case .method(let method):
            methods.removeAll { $0.caseInsensitiveCompare(method) == .orderedSame }
        case .status(let match):
            statuses.removeAll { $0 == match }
        case .path(let path):
            paths.removeAll { $0.caseInsensitiveCompare(path) == .orderedSame }
        case .app(let app):
            apps.removeAll { $0.caseInsensitiveCompare(app) == .orderedSame }
        case .pid(let pid):
            pids.removeAll { $0 == pid }
        case .country(let token):
            countries.removeAll { $0.caseInsensitiveCompare(token) == .orderedSame }
        case .outcome(let token):
            let normalized = TrafficSearchOutcomeMatch.normalize(token) ?? token
            outcomes.removeAll { $0 == normalized }
        case .grpc(let token):
            let normalized = TrafficSearchGRPCMatch.normalize(token) ?? token
            grpcStatuses.removeAll { $0 == normalized }
        case .proto(let token):
            let normalized = TrafficSearchProtocolMatch.normalize(token) ?? token
            protocols.removeAll { $0 == normalized }
        }
    }

    public mutating func clear() {
        freeText = ""
        hosts = []
        methods = []
        statuses = []
        paths = []
        apps = []
        pids = []
        countries = []
        outcomes = []
        grpcStatuses = []
        protocols = []
    }

    public func containsHost(_ host: String) -> Bool {
        hosts.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// Whether an app fragment is already a chip (in any case) — the same
    /// exact test `containsHost` makes, so the panel can exclude committed
    /// apps from its suggestions.
    public func containsApp(_ app: String) -> Bool {
        apps.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
    }

    /// Whether a process id is already a chip, so the panel and the context
    /// menu can skip offering one that is committed.
    public func containsPid(_ pid: Int) -> Bool {
        pids.contains(pid)
    }

    /// Whether a destination token is already a chip (in any case), so the
    /// panel and the map's context items can skip offering one that is.
    public func containsCountry(_ token: String) -> Bool {
        countries.contains { $0.caseInsensitiveCompare(token) == .orderedSame }
    }

    /// Whether a captured session passes the filter.
    ///
    /// Host tokens are OR-ed among themselves (a session has one host) and
    /// AND-ed with the free text, which matches as a case-insensitive
    /// substring of the URL, the method, the status or the host — the same
    /// fields the plain search always matched.
    ///
    /// `app` is the process that opened the connection (nil, or blank, when
    /// attribution has no name for it) and `pid` its id; `country` is the
    /// destination token the caller resolved for the session (`US` / `local`
    /// / `mac` / `unknown`), nil when it did not resolve one. Only `app:`,
    /// `pid:` and `country:` tokens read them; the free text does not, so
    /// attribution and resolution change nothing for a filter without one.
    /// None has a default, on purpose (UX spec errata 6): a call site that
    /// forgets to pass the attribution would otherwise compile and silently
    /// make every `app:` chip select nothing but Unknown — and every
    /// `country:` chip select nothing at all.
    ///
    /// `outcome` is the session's outcome token (`failed`, …), nil for a row
    /// an older core wrote — which reads as `completed`. No default either,
    /// for the same reason: a call site that forgot it would make every
    /// `outcome:failed` chip select nothing.
    ///
    /// `grpcStatus` is the row's RPC status (nil for a row that is not an
    /// RPC, or whose status was not recorded). No default, for the same
    /// reason: a call site that forgot it would make every `grpc:` chip
    /// select nothing.
    ///
    /// `proto` is the row's protocol token (`h1` / `h2` / `ws` / `relay`),
    /// nil when it recorded none. No default, for the same reason.
    public func matches(host: String, url: String, method: String, status: String?, app: String?, pid: Int?, country: String?, outcome: String?,
                        grpcStatus: Int?, proto: String?) -> Bool {
        // Tokens of one kind are OR-ed (a session has exactly one host, one
        // method, one status), and the kinds are AND-ed with each other and
        // with the free text. Narrowing is what a second token is for.
        if !hosts.isEmpty, !containsHost(host) {
            return false
        }
        if !methods.isEmpty,
           !methods.contains(where: { $0.caseInsensitiveCompare(method) == .orderedSame }) {
            return false
        }
        if !statuses.isEmpty {
            // A session with no status yet (still in flight, or it failed
            // before a response) cannot satisfy a status token, and saying so
            // is better than showing it and leaving the user to wonder.
            guard let status, let code = Int(status.trimmingCharacters(in: .whitespaces)) else {
                return false
            }
            guard statuses.contains(where: { $0.matches(code) }) else { return false }
        }
        if !paths.isEmpty {
            // Matched against the path alone: including the host here would
            // duplicate `host:` and make `path:api` match every request to
            // api.example.com.
            let path = TrafficSearchPath.extract(from: url).lowercased()
            guard paths.contains(where: { path.contains($0.lowercased()) }) else { return false }
        }
        if !apps.isEmpty {
            // A session the core could not attribute has no name, and the
            // only token that selects it is the table's own word for that
            // state, `Unknown` — see `TrafficSearchAppMatch`.
            guard apps.contains(where: { TrafficSearchAppMatch.matches($0, appName: app) }) else { return false }
        }
        if !pids.isEmpty {
            // Exact, and a session with no pid satisfies none: there is no
            // "unknown pid" the way there is an Unknown app, because a pid
            // chip is only ever committed from a row or a suggestion that
            // had one.
            guard let pid, pids.contains(pid) else { return false }
        }
        if !countries.isEmpty {
            // Exact on the token. A nil country means the caller did not
            // resolve one, and nothing selects that — not even `unknown`,
            // which is the resolver's own verdict ("could not place"), a
            // different fact from "nobody asked".
            guard countries.contains(where: { TrafficSearchCountryMatch.matches($0, country: country) }) else { return false }
        }
        if !outcomes.isEmpty {
            guard outcomes.contains(where: { TrafficSearchOutcomeMatch.matches($0, outcome: outcome) }) else { return false }
        }
        if !grpcStatuses.isEmpty {
            guard grpcStatuses.contains(where: { TrafficSearchGRPCMatch.matches($0, grpcStatus: grpcStatus) }) else { return false }
        }
        if !protocols.isEmpty {
            guard protocols.contains(where: { TrafficSearchProtocolMatch.matches($0, proto: proto) }) else { return false }
        }
        let needle = trimmedFreeText.lowercased()
        guard !needle.isEmpty else { return true }
        return url.lowercased().contains(needle)
            || method.lowercased().contains(needle)
            || (status?.lowercased().contains(needle) ?? false)
            || host.lowercased().contains(needle)
    }
}

// MARK: - Suggestions

public enum TrafficSearchSuggestions {
    /// Host suggestions for the text typed after `host:`.
    ///
    /// Hosts whose name STARTS with the query come first, then hosts that
    /// merely contain it; each group keeps the candidates' own order (the
    /// caller passes them most-relevant first). Hosts already committed are
    /// excluded, duplicates collapse (case-insensitively), and at most `limit`
    /// are returned. An empty query returns the leading candidates.
    public static func hosts(
        matching query: String,
        in candidates: [String],
        excluding committed: [String],
        limit: Int = 10
    ) -> [String] {
        ranked(matching: query, in: candidates, excluding: committed, limit: limit)
    }

    /// App suggestions for the text typed after `app:` — the same ranking as
    /// `hosts`, over a separate list so the caller decides what an app
    /// candidate is (the process names seen in traffic, busiest first, plus
    /// `TrafficSearchAppMatch.unknown` when any session has none). Apps
    /// already committed are excluded exactly, not by substring: a `claude`
    /// chip does not hide `claude-code` from the panel.
    public static func apps(
        matching query: String,
        in candidates: [String],
        excluding committed: [String],
        limit: Int = 10
    ) -> [String] {
        ranked(matching: query, in: candidates, excluding: committed, limit: limit)
    }

    /// One ranking for both panels, so they cannot drift: prefix matches,
    /// then substring matches, each in candidate order; committed and
    /// duplicate candidates dropped case-insensitively; `limit` applied last.
    private static func ranked(
        matching query: String,
        in candidates: [String],
        excluding committed: [String],
        limit: Int
    ) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        var prefixMatches: [String] = []
        var substringMatches: [String] = []
        for candidate in candidates {
            let key = candidate.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            guard !committed.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) else { continue }
            if needle.isEmpty || key.hasPrefix(needle) {
                seen.insert(key)
                prefixMatches.append(candidate)
            } else if key.contains(needle) {
                seen.insert(key)
                substringMatches.append(candidate)
            }
        }
        return Array((prefixMatches + substringMatches).prefix(max(0, limit)))
    }
}
