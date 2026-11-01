//
//  BreakpointRuleEntry.swift
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
//  What Settings ▸ Breakpoints' Add accepts, and the note it leaves under the
//  form when it refuses.
//
//  The note — "That rule is already in the list." and its two siblings — was
//  stored text that only a Host edit or a later successful Add cleared: change
//  the path or the methods, or remove from the list the very rule the note
//  was about, and it stayed, describing nothing on screen. It now belongs to
//  the submission it was written for, as Settings ▸ Capture's exclusion note
//  does (`ExcludedHostList.refusalNote`): `BreakpointRuleForm` forgets the
//  refusal at the first edit of ANY of its three fields, and the note is
//  derived on every render from that refusal and the rules as they are now,
//  so removing the rule a note named takes the note away.
//
//  The canonical forms moved here from `BreakpointService` (Sources/UI, no
//  test target) so the service's Add and this note decide "the same rule"
//  with one function. The core's `BreakpointRule.matches` stays the authority
//  on what a stored rule holds; this mirrors it for the form.
//

import Foundation

/// A breakpoint rule as plain values: the core's `BreakpointRule` without
/// `enabled`, which this package cannot import.
public struct BreakpointRuleSpec: Equatable, Sendable {
    public var host: String
    public var pathContains: String?
    public var methods: [String]

    public init(host: String, pathContains: String? = nil, methods: [String] = []) {
        self.host = host
        self.pathContains = pathContains
        self.methods = methods
    }
}

public enum BreakpointRuleEntry {
    // MARK: - Reading the Host field

    /// The Host field's text read the way a pasted URL reads: an optional
    /// `scheme://`, then the authority up to the first `/`, `?` or `#`, then
    /// the path and query. A fragment is dropped (it never reaches a server),
    /// and a lone "/" is no path (every request's path contains it), so
    /// `https://api.example.com` and `api.example.com/` are just the host.
    /// Case is kept: the path is quoted back to the user.
    static func split(_ raw: String) -> (authority: Substring, pathAndQuery: Substring?) {
        var rest = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        // Only a real scheme counts: a "://" further on (`?next=https://…`)
        // is part of the query.
        if let separator = rest.range(of: "://"), isScheme(rest[..<separator.lowerBound]) {
            rest = rest[separator.upperBound...]
        }
        guard let end = rest.firstIndex(where: { "/?#".contains($0) }) else { return (rest, nil) }
        var tail = rest[end...]
        if let fragment = tail.firstIndex(of: "#") { tail = tail[..<fragment] }
        return (rest[..<end], tail.isEmpty || tail == "/" ? nil : tail)
    }

    /// The path and query after the host in a pasted URL — what belongs in
    /// "Path contains" — or nil when the text carries none.
    public static func pastedPath(_ raw: String) -> String? {
        split(raw).pathAndQuery.map(String.init)
    }

    // MARK: - Canonical forms

    /// What to store for a host the user typed, or nil when it could never
    /// match. Same vocabulary as the capture exclusion list — exact, or `*.`
    /// for subdomains but not the bare domain — with one deliberate
    /// difference: a dotless host is allowed here, because `localhost` is the
    /// single most likely thing a developer wants to break on.
    ///
    /// The core compares a request's Host with the stored text after the
    /// same trimming, lowercasing and numeric-port and trailing-dot removal
    /// (`BreakpointRule.matches`), so text a Host cannot hold — "?", "#",
    /// ",", "\", a port that is not a number, an empty label — is refused
    /// here rather than stored as a rule that never fires.
    public static func canonicalHost(_ raw: String) -> String? {
        // Tolerate a pasted URL: take the authority and drop the rest.
        var value = split(raw).authority.lowercased()
        if let at = value.lastIndex(of: "@") { value = String(value[value.index(after: at)...]) }
        // A bracketed IPv6 address: the core compares it as written, port
        // included (its normaliser looks for a port after the FIRST ":"), so
        // it is stored as written.
        if value.hasPrefix("[") { return isBracketedAddress(value) ? value : nil }
        // A numeric port goes, as the core drops it from the request's Host.
        // Any other text after a ":" stays — and is refused below, since no
        // request's Host carries it.
        if let colon = value.firstIndex(of: ":"),
           value[value.index(after: colon)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
            value = String(value[..<colon])
        }
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("*.") {
            let suffix = value.dropFirst(2)
            guard suffix.contains("."), isHostName(suffix) else { return nil }
            return value
        }
        return isHostName(Substring(value)) ? value : nil
    }

    /// Labels of letters, digits, "-" and "_" between single dots: what a
    /// request's Host can hold. A "*" anywhere but a leading "*." is not a
    /// wildcard to the core but part of a name no request carries, and an
    /// empty label (".example.com", "api..example.com") matches nothing.
    private static func isHostName(_ name: Substring) -> Bool {
        name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    /// `[::1]`, `[2001:db8::1]:8443`.
    private static func isBracketedAddress(_ value: String) -> Bool {
        guard let close = value.firstIndex(of: "]") else { return false }
        let address = value[value.index(after: value.startIndex)..<close]
        let port = value[value.index(after: close)...]
        guard address.contains(":"), address.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return false }
        return port.isEmpty || (port.count > 1 && port.first == ":" && port.dropFirst().allSatisfy { $0.isASCII && $0.isNumber })
    }

    /// `https`, `wss`, `git+ssh` — RFC 3986's shape: a letter, then letters,
    /// digits, "+", "-" and ".".
    private static func isScheme(_ text: Substring) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }

    /// Empty and whitespace-only are the same thing as "any path": storing `""`
    /// would be a substring every URI contains, which reads as a filter while
    /// filtering nothing.
    public static func canonicalPath(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Uppercased and de-duplicated; the core compares methods as they arrive
    /// on the wire, where they are uppercase.
    public static func canonicalMethods(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// True when two rules hold exactly the same requests — the way the core
    /// matches them: the same host, the same path text without case (it is
    /// matched case-insensitively), the same methods in any order.
    public static func holdsTheSameRequests(_ a: BreakpointRuleSpec, _ b: BreakpointRuleSpec) -> Bool {
        guard let host = canonicalHost(a.host), host == canonicalHost(b.host) else { return false }
        return canonicalPath(a.pathContains)?.lowercased() == canonicalPath(b.pathContains)?.lowercased()
            && Set(canonicalMethods(a.methods)) == Set(canonicalMethods(b.methods))
    }

    // MARK: - Refusing

    /// Why Add refuses a rule.
    public enum Refusal: Equatable, Sendable {
        /// A path or query after the host — a URL pasted into the host field,
        /// whose path the user meant to match on (`pastedPath`).
        case hostHasPath
        /// No request's host could ever equal it (blank included).
        case cannotMatch
        /// A rule in the list already holds exactly these requests.
        case alreadyInList
    }

    /// Why Add would refuse this rule against `existing` now, or nil when it
    /// would add it. The one decision the service's Add and the form's note
    /// both make.
    public static func refusal(
        host raw: String,
        pathContains: String?,
        methods: [String],
        existing: [BreakpointRuleSpec]
    ) -> Refusal? {
        // Named before the host is read, which would quietly keep the host of
        // a pasted URL and drop the path the user meant to match on. A path
        // typed on its own ("/orders") is caught here too: read as a host it
        // is none, and "cannot match" would not say where it belongs.
        if pastedPath(raw) != nil { return .hostHasPath }
        guard let host = canonicalHost(raw) else { return .cannotMatch }
        let candidate = BreakpointRuleSpec(host: host, pathContains: pathContains, methods: methods)
        return existing.contains { holdsTheSameRequests($0, candidate) } ? .alreadyInList : nil
    }

    /// The sentence under the form for a refusal of `raw`.
    public static func message(for refusal: Refusal, host raw: String) -> String {
        switch refusal {
        case .hostHasPath:
            // Quoted rather than "from the first “/”": in a pasted
            // `https://…` the first "/" is the scheme's.
            return "Enter the host on its own — “\(pastedPath(raw) ?? "/")” belongs in “Path contains”."
        case .cannotMatch:
            let shown = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return "ReqRes cannot match “\(shown)”. Use a host like api.example.com or localhost, or *.example.com for its subdomains."
        case .alreadyInList:
            return "That rule is already in the list."
        }
    }
}

/// Settings ▸ Breakpoints' Add form: the three fields and what Add last
/// refused in them, kept together so the rule that ties them lives in one
/// place — a refusal belongs to one submission, and the first edit of any
/// field forgets it. Retyping the refused text does not bring the note back;
/// pressing Add does, if the reason still holds.
public struct BreakpointRuleForm: Equatable, Sendable {
    /// What Add was pressed on.
    public struct Submission: Equatable, Sendable {
        public var host: String
        public var path: String
        public var methods: Set<String>
    }

    public var host: String = "" {
        didSet { if host != oldValue { refused = nil } }
    }

    public var path: String = "" {
        didSet { if path != oldValue { refused = nil } }
    }

    /// The methods ticked in the menu; empty means any method.
    public var methods: Set<String> = [] {
        didSet { if methods != oldValue { refused = nil } }
    }

    /// What Add refused, until a field changes.
    public private(set) var refused: Submission?

    public init() {}

    /// Whether Add has anything to submit — a blank host is never submitted.
    public var canSubmit: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The path as Add passes it on: trimmed, nil for "any path".
    public var pathContains: String? {
        BreakpointRuleEntry.canonicalPath(path)
    }

    /// Add was pressed, and the rule was added (`accepted`) or refused.
    public mutating func submitted(accepted: Bool) {
        if accepted {
            host = ""
            path = ""
            methods = []
            refused = nil
        } else {
            refused = Submission(host: host, path: path, methods: methods)
        }
    }

    /// The note under the form, or nil: shown only while the fields still hold
    /// exactly what Add refused, and only while the reason still holds for
    /// `existing` — the rules as they are now.
    public func note(existing: [BreakpointRuleSpec]) -> String? {
        guard let refused, refused == Submission(host: host, path: path, methods: methods),
              let refusal = BreakpointRuleEntry.refusal(
                  host: refused.host,
                  pathContains: BreakpointRuleEntry.canonicalPath(refused.path),
                  methods: Array(refused.methods),
                  existing: existing
              ) else { return nil }
        return BreakpointRuleEntry.message(for: refusal, host: refused.host)
    }
}
