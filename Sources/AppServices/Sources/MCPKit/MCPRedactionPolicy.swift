//
//  MCPRedactionPolicy.swift
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
//  Whether a given host's traffic should skip MCPRedactor. Redaction itself
//  is a single on/off switch today (MCPRedactor.enabled); this type adds a
//  per-host exception on top of it so a user debugging a staging API they
//  know holds no real secrets is not forced to read placeholders, without
//  making that exception the default for anyone else's traffic.
//
//  An exception is a loaded gun, so every path here is written to fail
//  toward MORE redaction, never less: an empty or unparseable host redacts,
//  a host that merely resembles an excepted one redacts, and a policy this
//  process cannot even decode redacts everything rather than nothing.
//

import Foundation

/// Per-host override of the default-on redaction, plus the master switch.
///
/// `shouldRedact(host:)` is the only entry point call sites need; the rest of
/// the type exists to make that one decision persistable and auditable.
public struct MCPRedactionPolicy: Equatable, Sendable {
    /// The master switch. Off means nothing is ever redacted, exceptions
    /// included — kept separate from `exceptedHosts` so a future "just show
    /// me everything" toggle does not have to be modelled as excepting every
    /// host the user has ever seen.
    public var isEnabled: Bool

    /// Hosts the user has explicitly excepted from redaction, stored exactly
    /// as entered (a settings UI shows these back verbatim). Matching against
    /// a captured host normalizes both sides at compare time, so the stored
    /// form never has to be canonicalized on write.
    ///
    /// An entry may be a bare host ("api.example.com") or a leading wildcard
    /// ("*.staging.example.com") that excepts every subdomain but not the
    /// bare domain itself — the same shape a TLS wildcard certificate covers,
    /// chosen so it cannot be misread as "this domain and everything under
    /// it" when the user meant only the subdomains they actually run.
    public var exceptedHosts: [String]

    /// The safe fallback: redact everyone, except no one. Used whenever a
    /// stored policy cannot be trusted (see `decoding(_:using:)`).
    public static let redactAll = MCPRedactionPolicy(isEnabled: true, exceptedHosts: [])

    public init(isEnabled: Bool = true, exceptedHosts: [String] = []) {
        self.isEnabled = isEnabled
        self.exceptedHosts = exceptedHosts
    }

    /// True when a session captured against `host` should have `MCPRedactor`
    /// applied to it. `host` is whatever the capture layer recorded — untrimmed,
    /// possibly cased, possibly carrying a port — because callers should not
    /// each have to normalize before asking.
    public func shouldRedact(host: String?) -> Bool {
        guard isEnabled else { return false }
        guard let normalizedHost = Self.normalize(host) else { return true }
        return !isExcepted(normalizedHost)
    }

    private func isExcepted(_ normalizedHost: String) -> Bool {
        exceptedHosts.contains { entry in
            // A malformed stored entry (blank, stray whitespace) matches
            // nothing rather than being coerced into something that does —
            // a bad row in the exception list must not turn into "except all".
            guard let normalizedEntry = Self.normalize(entry) else { return false }
            return Self.matches(pattern: normalizedEntry, host: normalizedHost)
        }
    }

    /// `pattern` and `host` are both already normalized (lowercased, no
    /// trailing dot, no port) by the time this runs.
    static func matches(pattern: String, host: String) -> Bool {
        guard pattern.hasPrefix("*.") else { return host == pattern }
        let suffix = String(pattern.dropFirst(2))
        // "*." alone would make every non-empty host a subdomain of "".
        guard !suffix.isEmpty else { return false }
        // The leading dot is load-bearing: without it "*.example.com" would
        // match "evil-example.com" by plain string-suffix, excepting a
        // domain the user never listed just because it ends the same way.
        return host.hasSuffix("." + suffix)
    }

    // MARK: - Host normalization

    /// Lowercases, trims one trailing dot (FQDN notation) and an optional
    /// `:port`, and rejects anything left that could not plausibly be a host.
    /// Returns nil — "redact" is the caller's job on nil — for anything that
    /// is empty, unparseable, or carries whitespace mid-string.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("[") {
            // A bracketed IPv6 literal, optionally with a port: "[::1]:8080".
            // Without the brackets the address's own colons make "strip the
            // last :NNNN" ambiguous, so an unbracketed multi-colon host below
            // is left alone rather than guessed at.
            guard let closeBracket = value.firstIndex(of: "]") else { return nil }
            value = String(value[value.index(after: value.startIndex)..<closeBracket])
        } else if let portColon = singlePortColon(in: value) {
            value = String(value[..<portColon])
        }

        if value.hasSuffix(".") {
            value.removeLast()
        }

        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
        return value
    }

    /// A colon only counts as a port separator when everything after it is a
    /// non-empty run of digits — a bare (unbracketed) IPv6 address has
    /// several colons, and the text after its first one is never all-digit,
    /// so this naturally leaves such addresses untouched without having to
    /// count colons separately.
    private static func singlePortColon(in value: String) -> String.Index? {
        guard let firstColon = value.firstIndex(of: ":") else { return nil }
        let afterColon = value[value.index(after: firstColon)...]
        guard !afterColon.isEmpty, afterColon.allSatisfy(\.isNumber) else { return nil }
        return firstColon
    }

    // MARK: - Editing (settings UI)

    /// What to store for text the user typed into the exception field, or nil
    /// when that text could never except anything.
    ///
    /// Rejecting an inert entry is the whole point: `matches(pattern:host:)`
    /// compares a non-wildcard pattern for equality, so "api.*.example.com"
    /// or a bare "*" would sit in the list looking like an exception while
    /// never firing — and the user would conclude redaction is broken rather
    /// than that their entry is. The only wildcard this type implements is a
    /// single leading "*.".
    public static func canonicalEntry(_ raw: String) -> String? {
        guard let normalized = normalize(raw) else { return nil }
        if normalized.hasPrefix("*.") {
            let suffix = String(normalized.dropFirst(2))
            guard !suffix.isEmpty, !suffix.contains("*") else { return nil }
            return normalized
        }
        guard !normalized.contains("*") else { return nil }
        return normalized
    }

    /// This policy with `raw` excepted, or nil when the entry is unusable or
    /// already covered. Returning nil rather than a silently unchanged policy
    /// lets the UI say which of the two happened instead of appearing to
    /// ignore the button.
    public func addingException(_ raw: String) -> MCPRedactionPolicy? {
        guard let entry = Self.canonicalEntry(raw) else { return nil }
        guard !exceptedHosts.contains(where: { Self.canonicalEntry($0) == entry }) else { return nil }
        var copy = self
        copy.exceptedHosts.append(entry)
        return copy
    }

    /// Removes every stored spelling of `raw`, so a list that somehow holds
    /// both "API.example.com" and "api.example.com." cannot leave one behind
    /// still excepting traffic after the user removed what they saw.
    public func removingException(_ raw: String) -> MCPRedactionPolicy {
        let target = Self.canonicalEntry(raw)
        var copy = self
        copy.exceptedHosts.removeAll { entry in
            entry == raw || (target != nil && Self.canonicalEntry(entry) == target)
        }
        return copy
    }

    // MARK: - Audit

    /// One line for a settings UI or an audit log entry:
    /// "Redaction is on for every host.", "Redaction is off globally.", or
    /// "Redaction is off for 2 hosts: a, b".
    public var auditDescription: String {
        guard isEnabled else { return "Redaction is off globally." }
        guard !exceptedHosts.isEmpty else { return "Redaction is on for every host." }
        let noun = exceptedHosts.count == 1 ? "host" : "hosts"
        return "Redaction is off for \(exceptedHosts.count) \(noun): \(exceptedHosts.joined(separator: ", "))"
    }
}

// MARK: - Codable

extension MCPRedactionPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case exceptedHosts
    }

    /// Each field decodes on its own behind `try?`: a stored blob missing a
    /// key (an older app version, a hand-edited defaults file) or carrying
    /// the wrong type for one degrades that field to its safe default instead
    /// of losing the whole policy to a thrown error a caller might otherwise
    /// turn into "treat as unset, so redact nothing". `decode`, not
    /// `decodeIfPresent`, on purpose: `try?` around `decodeIfPresent`'s own
    /// `Bool?` result produces `Bool??`, which cannot `??` against a plain
    /// `true` — `decode`'s non-optional result keeps this to one Optional.
    /// Unknown keys are ignored, which is `Codable`'s standard behaviour and
    /// needs nothing extra here.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
        exceptedHosts = (try? container.decode([String].self, forKey: .exceptedHosts)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(exceptedHosts, forKey: .exceptedHosts)
    }

    /// The safe way to load a persisted policy. `Data` that is not a JSON
    /// object at all (truncated, the wrong shape, garbage) cannot reach even
    /// the tolerant field-by-field decoding above — `container(keyedBy:)`
    /// itself throws — so this is the one place that failure is caught and
    /// turned into `redactAll` instead of propagating into a call site that
    /// might otherwise fall back to "no policy means don't redact".
    public static func decoding(_ data: Data, using decoder: JSONDecoder = JSONDecoder()) -> MCPRedactionPolicy {
        (try? decoder.decode(MCPRedactionPolicy.self, from: data)) ?? .redactAll
    }
}
