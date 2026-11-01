//
//  ExcludedHostList.swift
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
//  Roadmap item 14: hosts whose HTTPS connections ReqRes relays instead of
//  intercepting.
//
//  Why this exists at all: interception re-signs every response with the
//  ReqRes CA, and some traffic must not be re-signed by anyone. `codesign`
//  fetches a secure timestamp from Apple over HTTPS and correctly refuses the
//  re-signed answer — it surfaces as "A timestamp was expected but was not
//  found" on some unrelated framework, with nothing pointing at the proxy
//  (measured 2026-09-06; it cost four failed builds before anyone suspected
//  capture). Anything that pins certificates behaves the same way.
//
//  The matching rules live here, tested, and the core's `MitmService`
//  implements the same ones against the live connection — it cannot import
//  this module (the framework's dependencies are hidden behind its ABI), so
//  these tests are what pin the semantics for both.
//
//  `builtIn` (pay-once PRD A16) is the one exception to "the user decides":
//  ReqRes's own license server. The engine excludes it in code, whatever
//  list the app pushes (core `MitmService.isExcluded`, pay-once C2), so the
//  entries here are DISPLAY and EDITING rules only: the pane shows them as
//  fixed rows, and nothing the user or an agent types can add or remove
//  them. This module keeps its own copy because it cannot import the core.
//

import Foundation

/// The hosts excluded from interception, in the order the user entered them.
public struct ExcludedHostList: Equatable, Sendable, Codable {
    /// ReqRes's own license server, always excluded (pay-once PRD A16). The
    /// engine relays it in code — never decrypted, rewritten, held or
    /// recorded — so no rule or capture can touch the app's license check,
    /// and no capture holds a license key or a Mac's serial number. Shown in
    /// Settings as fixed rows, never stored in `hosts`, and never removable:
    /// `excludes(_:)` always matches them, `adding(_:)` refuses anything they
    /// cover as already excluded, and decoding drops a stored copy.
    /// `*.` covers subdomains only, so both entries are needed.
    public static let builtIn = ["reqresapp.com", "*.reqresapp.com"]

    /// Why the `builtIn` rows are there, for the Settings row beside them.
    public static let builtInReason = "ReqRes's license server: never intercepted"

    /// The entries Apple's own software needs. Present by default because
    /// the failures they prevent are silent, expensive and point at the wrong
    /// thing. Visible and removable in Settings rather than hidden in the
    /// engine, so nobody has to wonder why a host is missing from their
    /// capture. (Unlike `builtIn`, which is visible but fixed.)
    ///
    /// - `timestamp.apple.com`: every developer running a debugging proxy on
    ///   macOS eventually signs something, and codesign refuses a re-signed
    ///   timestamp with an error naming an unrelated framework.
    /// - `*.ls.apple.com`: Apple Maps. The Destinations window's map is
    ///   MapKit, whose tiles are fetched by Apple's `geod` daemon from
    ///   `gspe19-ssl`, `gsp-ssl`, `gspe35-ssl`, `configuration.ls.apple.com`
    ///   and their siblings (measured 2026-09-25: every connection the daemon
    ///   opened for a map view was under this domain — WITHOUT capture
    ///   running). Excluded so the map keeps working while capture is on.
    ///   UNVERIFIED, stated nowhere user-facing: that geod's fetches go
    ///   through the NE proxy at all, and that Apple pins those servers'
    ///   certificates (which would make an intercepted fetch fail and the
    ///   map go blank).
    public static let recommended = ["timestamp.apple.com", "*.ls.apple.com"]

    /// Why a recommended entry is there, for the Settings row beside it. Nil
    /// for anything the user added.
    public static func recommendedReason(for entry: String) -> String? {
        switch canonicalEntry(entry) {
        case "timestamp.apple.com": return "keeps codesign working"
        case "*.ls.apple.com": return "Apple Maps tiles for the Destinations window"
        default: return nil
        }
    }

    /// The recommended entries this list does not cover — for an install
    /// whose stored list predates one of them. A user who REMOVED an entry
    /// is not second-guessed: the pane offers these once, as a button.
    public var missingRecommended: [String] {
        Self.recommended.filter { entry in !hosts.contains { Self.canonicalEntry($0) == entry } }
    }

    /// The user's entries, in the order entered. Never holds an entry that
    /// `builtIn` covers: those are dropped here and on decoding.
    public private(set) var hosts: [String]

    public init(hosts: [String] = recommended) {
        self.hosts = hosts.filter { Self.builtInEntry(covering: $0) == nil }
    }

    private enum CodingKeys: String, CodingKey { case hosts }

    /// The stored shape is unchanged (`{"hosts": [...]}`); a stored copy of a
    /// built-in entry (typed by hand into a build before A16) is dropped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(hosts: try container.decode([String].self, forKey: .hosts))
    }

    /// Every entry in force, the built-in ones first: what an agent is told
    /// is excluded.
    public var allEntries: [String] { Self.builtIn + hosts }

    /// True when `host`'s traffic should be relayed untouched.
    ///
    /// Fails toward INTERCEPTING: an entry that cannot be parsed excludes
    /// nothing. A broken row must never turn into "stop capturing anything",
    /// which is the failure a user would take longest to notice.
    public func excludes(_ host: String?) -> Bool {
        guard let normalizedHost = Self.normalized(host) else { return false }
        return allEntries.contains { entry in
            guard let pattern = Self.normalized(entry) else { return false }
            return Self.matches(pattern: pattern, host: normalizedHost)
        }
    }

    /// `*.` covers subdomains but NOT the bare domain — the shape a TLS
    /// wildcard certificate covers, so it cannot be misread as "this domain
    /// and everything under it".
    static func matches(pattern: String, host: String) -> Bool {
        guard pattern.hasPrefix("*.") else { return host == pattern }
        let suffix = String(pattern.dropFirst(2))
        // The leading dot is load-bearing: a plain suffix match would let
        // "*.example.com" cover "evil-example.com".
        return !suffix.isEmpty && host.hasSuffix("." + suffix)
    }

    /// Lowercased, trimmed, one trailing FQDN dot and a `:port` removed. Nil
    /// for anything that could not be a host.
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if let colon = value.firstIndex(of: ":") {
            let afterColon = value[value.index(after: colon)...]
            if !afterColon.isEmpty, afterColon.allSatisfy(\.isNumber) {
                value = String(value[..<colon])
            }
        }
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
        return value
    }

    // MARK: - Editing

    /// What to store for text the user typed, or nil when it could never
    /// exclude anything. Rejected rather than repaired: an entry that sits in
    /// the list doing nothing is indistinguishable, to the user, from the
    /// feature being broken.
    public static func canonicalEntry(_ raw: String) -> String? {
        guard let normalized = normalized(raw) else { return nil }
        if normalized.hasPrefix("*.") {
            let suffix = String(normalized.dropFirst(2))
            guard !suffix.isEmpty, !suffix.contains("*"), suffix.contains(".") else { return nil }
            return normalized
        }
        guard !normalized.contains("*"), normalized.contains(".") else { return nil }
        return normalized
    }

    /// The `builtIn` entry that already covers `raw`, or nil. A plain host is
    /// covered when a built-in entry matches it; a `*.` entry when it names
    /// reqresapp.com's own subdomains or a subdomain's (everything under it
    /// is already relayed). Nil for text that could never match, and for
    /// look-alikes such as evil-reqresapp.com.
    public static func builtInEntry(covering raw: String) -> String? {
        guard let entry = canonicalEntry(raw) else { return nil }
        guard entry.hasPrefix("*.") else {
            return builtIn.first { matches(pattern: $0, host: entry) }
        }
        let domain = String(entry.dropFirst(2))
        return builtIn.first { $0.hasPrefix("*.") && ($0 == entry || matches(pattern: $0, host: domain)) }
    }

    /// The entry that already covers `raw` — a built-in one, another spelling
    /// of a listed one, or a listed `*.` wildcard above a plain host — or nil
    /// when adding it would change something. `exclude_host` asks this before
    /// anyone is asked to approve.
    public func coveringEntry(for raw: String) -> String? {
        guard let entry = Self.canonicalEntry(raw) else { return nil }
        if let builtIn = Self.builtInEntry(covering: entry) { return builtIn }
        if let same = hosts.first(where: { Self.canonicalEntry($0) == entry }) { return same }
        guard !entry.hasPrefix("*.") else { return nil }
        return hosts.first { listed in
            guard let pattern = Self.normalized(listed) else { return false }
            return Self.matches(pattern: pattern, host: entry)
        }
    }

    /// Adds `raw`, or returns nil when it is unusable or already covered. A
    /// host the built-in entries cover is always "already covered".
    public func adding(_ raw: String) -> ExcludedHostList? {
        guard let entry = Self.canonicalEntry(raw) else { return nil }
        guard Self.builtInEntry(covering: entry) == nil else { return nil }
        guard !hosts.contains(where: { Self.canonicalEntry($0) == entry }) else { return nil }
        var copy = self
        copy.hosts.append(entry)
        return copy
    }

    /// Removes every stored spelling of `raw`, so a list holding both
    /// "API.example.com" and "api.example.com." cannot leave one behind still
    /// excluding traffic the user thinks they put back under capture. The
    /// `builtIn` entries are not in `hosts`, so removing one changes nothing:
    /// it stays excluded.
    public func removing(_ raw: String) -> ExcludedHostList {
        let target = Self.canonicalEntry(raw)
        var copy = self
        copy.hosts.removeAll { $0 == raw || (target != nil && Self.canonicalEntry($0) == target) }
        return copy
    }

    /// Why `adding(_:)` refuses a text.
    public enum Refusal: Equatable, Sendable {
        /// It could never exclude anything (`canonicalEntry` is nil).
        case unmatchable
        /// The list already holds it, in this spelling or another.
        case alreadyExcluded
    }

    /// Why `raw` cannot be added to this list, or nil when it can.
    public func refusal(toAdd raw: String) -> Refusal? {
        guard Self.canonicalEntry(raw) != nil else { return .unmatchable }
        return adding(raw) == nil ? .alreadyExcluded : nil
    }

    /// The note under Settings ▸ Capture's Pass through field (F13): why Add
    /// refused `submitted`, only for as long as that is still the answer. It
    /// was stored text that only a later successful Add cleared, so "“x” is
    /// already excluded." stayed after the user removed x from the list and
    /// emptied the field. Derived instead, on every render: nil once the field
    /// no longer holds exactly the refused text, and re-checked against this
    /// list — the list as it is now — so removing the host takes the note away.
    public func refusalNote(submitted: String?, current: String) -> String? {
        guard let submitted, submitted == current, let refusal = refusal(toAdd: submitted) else { return nil }
        let shown = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        switch refusal {
        case .unmatchable:
            return "ReqRes cannot match “\(shown)”. Use a host like api.example.com, or *.example.com for its subdomains."
        case .alreadyExcluded:
            if Self.builtInEntry(covering: submitted) != nil {
                return "“\(shown)” is already excluded: ReqRes's license server is never intercepted."
            }
            return "“\(shown)” is already excluded."
        }
    }

    /// One line for a settings caption or a log.
    public var summary: String {
        switch hosts.count {
        case 0: return "Every host but ReqRes's license server is intercepted."
        case 1: return "1 host is relayed without interception: \(hosts[0])"
        default: return "\(hosts.count) hosts are relayed without interception: \(hosts.joined(separator: ", "))"
        }
    }
}
