//
//  MCPAuditExport.swift
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
//  PRD item 12: getting the agent activity log OUT of the app for someone's
//  own review. MCPAuditEntry.previousState deliberately keeps a changed
//  rule's REAL header values and body — restoring a redaction placeholder
//  would write the mask into live traffic — and that is fine as long as the
//  snapshot never leaves the app (see the comment at its call site in
//  MCPBridgeRouter). An export is exactly the snapshot leaving the app, so
//  this file redacts on the way out instead of trusting that whoever built
//  the log already did. That "upstream already handled it" assumption, in
//  the same shape, is what once let mock_from_session hand an agent a login
//  response's Set-Cookie verbatim. Every field below — the snapshot's rule
//  headers and body, and the approval-sheet summary/detail strings, which
//  quote header values and body previews of their own — goes through
//  MCPRedactor here, independently of whatever ran before this file saw it.
//
//  Pure, like MCPHARExport: no disk access, no consent. The caller owns the
//  file path and the write, and the copy shown to the human before either.
//

import Foundation

/// Turns the agent activity log into a plain-text or JSON file for a human to
/// read outside the app.
public enum MCPAuditExport {

    /// A snapshot's own body is already bounded — `redact(_:with:)` runs it
    /// through `MCPRedactor.redactRule`, which caps the response body the
    /// same way the write surface always has. What nothing else bounds is
    /// how many entries the log holds by the time someone exports it, so
    /// entry count is the axis this file guards.
    public static let defaultMaxEntries = 500

    public struct Result: Equatable {
        public let content: String
        /// True when `maxEntries` cut the log short. The content already
        /// says so in its header; this mirrors that so a caller can react
        /// (e.g. warn before writing the file) without re-parsing its own
        /// output.
        public let truncated: Bool
        /// Entries actually written, for the same reason.
        public let includedCount: Int
        /// Entries the caller handed in, before any truncation.
        public let totalCount: Int
        /// Whether the redactor that produced this content was switched on.
        /// Exported so a reader of `Result` never has to trust its own
        /// memory of what it passed in — the one fact this whole file exists
        /// to protect is worth stating twice.
        public let redacted: Bool

        public init(content: String, truncated: Bool, includedCount: Int, totalCount: Int, redacted: Bool) {
            self.content = content
            self.truncated = truncated
            self.includedCount = includedCount
            self.totalCount = totalCount
            self.redacted = redacted
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Plain text

    /// A human-readable rendering, newest information last (like a log file),
    /// meant to be opened and read top to bottom.
    public static func text(
        _ entries: [MCPAuditEntry],
        redactor: MCPRedactor = MCPRedactor(),
        exportedAt: Date = Date(),
        maxEntries: Int = defaultMaxEntries
    ) -> Result {
        let capped = orderedAndCapped(entries, maxEntries: maxEntries)
        let redactedEntries = capped.kept.map { redact($0, with: redactor) }

        var lines = textHeader(
            exportedAt: exportedAt,
            includedCount: redactedEntries.count,
            totalCount: capped.total,
            truncated: capped.truncated,
            maxEntries: maxEntries
        )
        for entry in redactedEntries {
            lines.append("")
            lines.append(contentsOf: textBlock(for: entry))
        }
        return Result(
            content: lines.joined(separator: "\n"),
            truncated: capped.truncated,
            includedCount: redactedEntries.count,
            totalCount: capped.total,
            redacted: redactor.enabled
        )
    }

    private static func textHeader(
        exportedAt: Date,
        includedCount: Int,
        totalCount: Int,
        truncated: Bool,
        maxEntries: Int
    ) -> [String] {
        var lines = [
            "# ReqRes agent activity log export",
            "# Exported \(isoFormatter.string(from: exportedAt))",
            "# Values are redacted: header, body and token-shaped material below has been",
            "# replaced with \(MCPRedactor.placeholder) or REDACTED. This is not a complete",
            "# record of what agents actually sent or received — read it as a shape of what",
            "# happened, not as the exact values.",
        ]
        lines.append(
            truncated
                ? "# \(includedCount) of \(totalCount) entries included (cap of \(maxEntries); oldest dropped first)."
                : "# \(totalCount) \(totalCount == 1 ? "entry" : "entries")."
        )
        return lines
    }

    private static func textBlock(for entry: MCPAuditEntry) -> [String] {
        var lines = [
            "[\(isoFormatter.string(from: entry.date))] \(entry.action.kind.rawValue) — \(entry.outcome.rawValue)"
                + (entry.lateDecision ? " (late decision)" : ""),
            "  \(entry.action.summary)",
        ]
        for detail in entry.action.details {
            lines.append("  - \(detail)")
        }
        if let detail = entry.detail {
            lines.append("  Result: \(detail)")
        }
        if let previousState = entry.previousState {
            lines.append(contentsOf: previousStateLines(previousState).map { "  \($0)" })
        }
        return lines
    }

    /// Renders enough of a snapshot to actually review, not just its one-line
    /// `summary` — a header a rule was extending with would otherwise never
    /// appear in the text export at all, redacted or not, which would make
    /// the redaction on this path untestable and the export useless for the
    /// one thing snapshots are for.
    private static func previousStateLines(_ snapshot: MCPAuditSnapshot) -> [String] {
        switch snapshot {
        case .host, .exclusion:
            // Host/scheme/port and exclusion patterns carry nothing secret;
            // the one-line summary is the whole story.
            return ["Previous state: \(snapshot.summary)"]
        case .rule(let rule):
            var lines = ["Previous state: \(snapshot.summary)"]
            if !rule.requestHeaders.isEmpty {
                lines.append("  Request headers: " + headerList(rule.requestHeaders))
            }
            if !rule.responseHeaders.isEmpty {
                lines.append("  Response headers: " + headerList(rule.responseHeaders))
            }
            if let body = rule.responseBody, !body.isEmpty {
                lines.append("  Response body: \(body)")
            }
            return lines
        }
    }

    /// Sorted by key so two exports of the same rule are byte-identical
    /// regardless of Dictionary's per-process randomized iteration order.
    private static func headerList(_ headers: [String: String]) -> String {
        headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "; ")
    }

    // MARK: - JSON

    /// The envelope's field names ARE the machine-readable contract, so they
    /// stay stable even though nothing outside this file reads them today.
    private struct Envelope: Encodable {
        let format: String
        let exportedAt: Date
        let redacted: Bool
        let includedCount: Int
        let totalCount: Int
        let truncated: Bool
        let entries: [MCPAuditEntry]
    }

    private static let envelopeFormat = "com.oloapps.reqres.agent-activity-export.v1"

    /// A machine-readable rendering of the same redacted entries `text`
    /// produces, from the same capping and ordering, so the two forms can
    /// never disagree about which entries were kept or what was left in them.
    public static func json(
        _ entries: [MCPAuditEntry],
        redactor: MCPRedactor = MCPRedactor(),
        exportedAt: Date = Date(),
        maxEntries: Int = defaultMaxEntries
    ) -> Result {
        let capped = orderedAndCapped(entries, maxEntries: maxEntries)
        let redactedEntries = capped.kept.map { redact($0, with: redactor) }
        let envelope = Envelope(
            format: envelopeFormat,
            exportedAt: exportedAt,
            redacted: redactor.enabled,
            includedCount: redactedEntries.count,
            totalCount: capped.total,
            truncated: capped.truncated,
            entries: redactedEntries
        )

        guard let content = encode(envelope) else {
            // Only reached if a fully-assembled envelope fails to encode,
            // which nothing above should produce; degrade to an honest,
            // valid, empty export rather than silently dropping the
            // caller's data or crashing on a force-unwrap.
            let empty = Envelope(
                format: envelopeFormat, exportedAt: exportedAt, redacted: redactor.enabled,
                includedCount: 0, totalCount: capped.total, truncated: capped.truncated, entries: []
            )
            return Result(
                content: encode(empty) ?? "{}",
                truncated: capped.truncated, includedCount: 0, totalCount: capped.total, redacted: redactor.enabled
            )
        }
        return Result(
            content: content,
            truncated: capped.truncated,
            includedCount: redactedEntries.count,
            totalCount: capped.total,
            redacted: redactor.enabled
        )
    }

    private static func encode(_ envelope: Envelope) -> String? {
        let encoder = JSONEncoder()
        // .sortedKeys covers the headers dictionaries nested inside
        // `entries` too — the same Dictionary-ordering problem `text`'s
        // `headerList` sorts by hand, solved once here for every nested
        // keyed container instead of key by key.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Redaction

    /// The one path both output forms go through, so text and JSON cannot
    /// silently redact different things — the whole point of this file is
    /// that there is exactly one answer to "did this leak."
    private static func redact(_ entry: MCPAuditEntry, with redactor: MCPRedactor) -> MCPAuditEntry {
        var copy = entry
        copy.action = MCPAgentAction(
            kind: entry.action.kind,
            summary: redactFreeText(entry.action.summary, with: redactor),
            details: entry.action.details.map { redactFreeText($0, with: redactor) }
        )
        copy.detail = entry.detail.map { redactFreeText($0, with: redactor) }
        if let previousState = entry.previousState, case .rule(let rule) = previousState {
            copy.previousState = .rule(redactor.redactRule(rule))
        }
        // .host carries no secret material (host/scheme/port); nil stays nil.
        return copy
    }

    /// `MCPRedactor.redactRule` skips a named host under `MCPRedactionPolicy`
    /// — a per-HOST exception, which these free-text fields have no clean
    /// host to check against (an approval-sheet line is prose, not a
    /// captured record). Gating on the master switch only, and never the
    /// exception list, fails toward MORE redaction for a case this file
    /// cannot pin down — the same rule `MCPRedactionPolicy` states for
    /// itself when it cannot identify a host.
    ///
    /// A credential in a URL's query or in a rule path's (`?access_token=…`,
    /// which a rule's summary quotes with no scheme in front) is masked by its
    /// parameter's NAME before anything else: a short token has no shape the
    /// passes below could see. The log masks these when an entry is recorded
    /// and loaded; this file does not trust that, as its header says.
    private static func redactFreeText(_ text: String, with redactor: MCPRedactor) -> String {
        guard redactor.enabled else { return text }
        let queries = MCPRedactor.redactQueryPairs(in: redactor.redactURLs(in: text))
        return redactor.redactFreeText(redactNamedValues(in: queries), aggressive: true)
    }

    /// `MCPRedactor.redactFreeText` works on SHAPE — JWTs, vendor prefixes,
    /// long high-entropy runs — because prose carries no field names. These
    /// strings are not quite prose: the consent layer builds them as
    /// "Name: value" segments joined by " · " (`MCPBridgeRouter.describeHeaders`),
    /// deliberately showing values so the human can see what a rule would
    /// inject. That is right on screen and wrong in a file, and a short
    /// credential ("Cookie: sid=42") has no shape to detect, so the name is
    /// used here — the one signal this format does carry.
    ///
    /// This parses OUR OWN rendering, which is the difference between it and
    /// the rule the redactor otherwise follows (never regex a serialized
    /// format you did not write). A value containing the separator would
    /// split into segments that no longer look like "name: value"; those
    /// continuation segments are redacted too rather than partially leaked.
    static func redactNamedValues(in text: String) -> String {
        guard text.contains(": ") else { return text }
        var continuing = false
        let segments = text.components(separatedBy: " · ").map { segment -> String in
            if let redacted = redactingFromSensitiveName(in: segment) {
                // The value ran to the end of the segment, so anything that
                // follows may still be part of it.
                continuing = true
                return redacted
            }
            if continuing {
                // A segment that opens its own "Name: value" pair ends the
                // previous value; anything else is still inside it.
                if startsANewPair(segment) {
                    continuing = false
                    return segment
                }
                return MCPRedactor.placeholder
            }
            return segment
        }
        return segments.joined(separator: " · ")
    }

    /// Everything from the first credential-shaped name's colon to the end of
    /// the segment, replaced. Nil when the segment names no such field.
    ///
    /// Every ": " is considered, not just the first: the consent layer writes
    /// lines like "Headers set: Set-Cookie: sid=42", where the first colon
    /// belongs to the prose prefix and the second to the header that matters.
    private static func redactingFromSensitiveName(in segment: String) -> String? {
        var searchStart = segment.startIndex
        while let colon = segment.range(of: ": ", range: searchStart..<segment.endIndex) {
            let before = segment[segment.startIndex..<colon.lowerBound]
            // The name is the last whitespace-delimited token before the
            // colon — "Sets request headers — Authorization" names
            // Authorization, and "Response body (12 bytes)" names nothing.
            if let name = before.split(whereSeparator: \.isWhitespace).last,
               MCPRedactor.isSensitiveName(String(name)) {
                return segment[segment.startIndex..<colon.upperBound] + MCPRedactor.placeholder
            }
            searchStart = colon.upperBound
        }
        return nil
    }

    /// True for "Name: value" — a header name carries no whitespace, which is
    /// what tells a new pair apart from the continuation of a value that
    /// happened to contain the segment separator.
    private static func startsANewPair(_ segment: String) -> Bool {
        guard let colon = segment.range(of: ": ") else { return false }
        let name = segment[segment.startIndex..<colon.lowerBound]
        return !name.isEmpty && !name.contains(where: { $0.isWhitespace })
    }

    // MARK: - Capping and ordering

    private struct Capped {
        let kept: [MCPAuditEntry]
        let truncated: Bool
        let total: Int
    }

    /// Sorts oldest first — tie-broken by id, for entries sharing an instant
    /// — so two exports of the same log are byte-identical regardless of
    /// what order the caller's storage happens to hand entries back in, the
    /// same concern `MCPHARExport.headerArray` sorts headers for.
    ///
    /// When the log is over budget, the OLDEST entries are the ones dropped:
    /// an agent's most recent actions are what someone reviewing the log is
    /// most likely to still care about, and are the ones still fresh enough
    /// to act on.
    private static func orderedAndCapped(_ entries: [MCPAuditEntry], maxEntries: Int) -> Capped {
        let ordered = entries.sorted {
            $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString
        }
        let cap = max(maxEntries, 0)
        guard ordered.count > cap else {
            return Capped(kept: ordered, truncated: false, total: ordered.count)
        }
        return Capped(kept: Array(ordered.suffix(cap)), truncated: true, total: ordered.count)
    }
}
