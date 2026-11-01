//
//  BreakpointRequestDraft.swift
//  ReqRes
//
//  Created by OloApps on 21.09.2026.
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
//  What the panel is about to send back for one held request: the headers and
//  body as the user has them now, next to the ones the core handed over.
//
//  It is a plain value with no AppKit and no SwiftUI on purpose — every rule
//  below decides whether a real request is altered mid-flight, and those rules
//  should be readable (and testable) without
//  standing a window up.
//
//  Three of them are the reason this type exists at all:
//
//   * `bodyEdit`. The core holds a request at its HEAD and reports no body —
//     no preview and a count of 0, for a POST carrying `Content-Length: 76`
//     as much as for a GET (F19). This draft used to read 0 == 0 as "the
//     whole body, and it is empty", call it complete and let it be edited, so
//     typing into what looked like an empty body replaced one nobody had
//     seen. The original body is now read-only whatever the core sends, and
//     what is said about it comes from `HeldRequestBody` (MCPKit, tested),
//     from the core's own reading of the head (`bodyExpected`,
//     `declaredBodyLength`) when it sends one. Replacing it is an explicit
//     act (`startReplacingBody()`), from an EMPTY editor unless the core
//     reported the whole body, and `bodyPayload()` stays nil — "send the
//     original, whole" — until the user has typed something. A TRACE, which
//     may not carry a body, is never given one (`HeldBodyEdit.canReplace`).
//
//   * The framing headers. Content-Length and Transfer-Encoding are the
//     core's to set (core 5efe7aa): it sends the app's own with the app's own
//     body whatever the edited headers say, and frames a replacement body
//     itself. A value typed for either would never reach the server while
//     the button said "Resume with Changes", so the editor shows them locked
//     and `headerProblem` refuses a row that would set one
//     (`HeldRequestFraming`, MCPKit, tested).
//
//   * `headerFormat`. Three wire shapes exist in this codebase and the reader
//     (`HeldRequestHeaders`, MCPKit, tested) accepts all of them, because a
//     shape it cannot read is a request the user cannot answer. It does NOT
//     decide how the decision goes back: `GlueHandler.headersFromJSON` reads
//     one shape only, and a re-encoding it cannot parse fails silently — the
//     core keeps the original headers while the panel's button says "Resume
//     with Changes". `editedHeaders()` is the single way out of this type for
//     that reason.
//

import Foundation
import MCPKit
import XReqResCore

/// The wire shape of `PausedRequestCodable.headers`: a JSON object (what
/// `SessionCodable.reqHeaders` held before the 1.1.0 core), an array of
/// single-pair objects (what the core sends here), or the rules' entry array —
/// or unreadable. Read by `HeldRequestHeaders` (MCPKit), which says why each
/// is accepted.
typealias BreakpointHeaderFormat = HeldRequestHeaders.Format

struct BreakpointRequestDraft {
    let request: PausedRequestCodable
    let headerFormat: BreakpointHeaderFormat
    /// The headers exactly as decoded. `headers` starts as a copy of this, so
    /// the two share `HeaderEntry.id`s and a row can be matched to its
    /// original to show WHAT changed.
    let originalHeaders: [HeaderEntry]

    var headers: [HeaderEntry]
    /// The original body as far as ReqRes can describe it, and the
    /// replacement if the user chose to write one.
    var bodyEdit: HeldBodyEdit

    init(request: PausedRequestCodable) {
        self.request = request
        // One reading of the headers for both tabs: the Headers tab edits
        // these, and the Body tab says what they declared as they ARRIVED —
        // an edit to Content-Length in the header editor does not change
        // what the held body is.
        let decoded = HeldRequestHeaders.decode(request.headers)
        self.headerFormat = decoded.format
        let entries = decoded.entries.map { HeaderEntry(key: $0.name, value: $0.value, isEnabled: $0.isEnabled) }
        self.originalHeaders = entries
        self.headers = entries

        // The method too: a TRACE is offered no replacement, and one that
        // carries a body of its own is answered 502 over HTTP/1.1 when
        // resumed — the Body tab says so (`HeldRequestBody.resumeOutcome`).
        self.bodyEdit = HeldBodyEdit(HeldRequestBody(
            method: request.method,
            preview: request.bodyPreview,
            byteCount: request.bodyByteCount,
            previewIsPrefix: BreakpointService.isBodyTruncated(request),
            decodedHeaders: decoded,
            bodyExpected: request.bodyExpected,
            declaredBodyLength: request.declaredBodyLength
        ))
    }

    // MARK: - What the user may touch

    var headersEditable: Bool { headerFormat != .unreadable }

    var headersChanged: Bool { Self.comparable(originalHeaders) != Self.comparable(headers) }
    var bodyChanged: Bool { bodyEdit.isChanged }
    var isEdited: Bool { headersChanged || bodyChanged }

    /// Opens the replacement editor. The original stays what Resume sends
    /// until something is typed there. Does nothing for a request that may
    /// not carry a body (a TRACE), which is never offered one.
    mutating func startReplacingBody() { bodyEdit.startReplacing() }

    /// Closes the replacement editor and forgets what was typed.
    mutating func keepOriginalBody() { bodyEdit.keepOriginal() }

    /// True for a header row the editor shows but does not let anyone edit
    /// or remove: a Content-Length or Transfer-Encoding the request arrived
    /// with (`HeldRequestFraming`).
    func isLocked(_ entry: HeaderEntry) -> Bool {
        Self.isLocked(entry, among: originalHeaders)
    }

    static func isLocked(_ entry: HeaderEntry, among original: [HeaderEntry]) -> Bool {
        guard let arrived = original.first(where: { $0.id == entry.id }) else { return false }
        return HeldRequestFraming.isFramingHeader(arrived.key)
    }

    /// The line under the header editor about Content-Length and
    /// Transfer-Encoding: what goes up in their place, with the replacement
    /// body if one is being sent. Nil when there is nothing to say.
    var framingNote: String? {
        HeldRequestFraming.note(
            arrived: originalHeaders.filter(\.isEnabled).map { MCPHeaderPair(name: $0.key, value: $0.value) },
            replacementBody: bodyPayload()
        )
    }

    // MARK: - What goes back to the core

    /// The headers to send back, or nil for "leave the request's headers
    /// alone" — which is what the core does with a nil in
    /// `BreakpointDecisionCodable`. Sending the re-encoded original instead
    /// would be a needless rewrite of a live request, and it would reorder
    /// headers for no reason.
    ///
    /// Disabled rows are dropped here: unticking a row in the editor is how a
    /// header is removed from the request, and it counts as an edit because
    /// `headersChanged` compares `isEnabled` too.
    ///
    /// This is the ONE place a draft becomes headers. An earlier version also
    /// had an `encodedHeaders()` that re-encoded into whichever wire shape the
    /// request arrived in — and the panel never used it, which is the only
    /// reason it never bit: `GlueHandler.headersFromJSON` parses
    /// `[[String: String]]` and nothing else, so an entry-array or object-map
    /// re-encoding decodes to nil and the core silently keeps the ORIGINAL
    /// headers. The user would have watched "Resume with Changes" send their
    /// edits nowhere. One codec, one shape, and `BreakpointService.headersJSON`
    /// is where it lives.
    func editedHeaders() -> [BreakpointHeader]? {
        guard headersEditable, headersChanged else { return nil }
        return Self.normalized(headers)
            .filter(\.isEnabled)
            .map { BreakpointHeader(name: $0.key, value: $0.value) }
    }

    /// nil means "send the original body". See the note on `bodyEdit`: only
    /// a replacement the user opened and typed into ever becomes a payload.
    func bodyPayload() -> String? {
        bodyEdit.payload
    }

    mutating func revert() {
        headers = originalHeaders
        bodyEdit.keepOriginal()
    }

    // MARK: - Validation

    /// The reason this draft must not be sent, phrased for the person holding
    /// up a request, or nil when it is fine.
    ///
    /// The CR/LF check is the important one and is the same guard
    /// `MCPWriteValidation` applies to rule headers: a value carrying a line
    /// break ends the header block early and lets whatever follows be read as
    /// more request. It is checked on UNICODE SCALARS because Swift folds
    /// "\r\n" into a single Character, so a `contains("\n")` over Characters
    /// misses exactly the sequence that matters.
    var headerProblem: String? {
        guard headersEditable else { return nil }
        let entries = Self.normalized(headers)

        for entry in entries {
            if Self.containsLineBreak(entry.key) || Self.containsLineBreak(entry.value) {
                return "“\(entry.key)” contains a line break. A header value with a carriage return or newline in it would end the request's header block early and let the rest be read as more request."
            }
            if entry.key.contains(":") || entry.key.rangeOfCharacter(from: .whitespaces) != nil {
                return "“\(entry.key)” is not a usable header name — no colons and no spaces."
            }
            // Content-Length and Transfer-Encoding are the core's to set: a
            // row that would set one (added, renamed to one, changed) is
            // refused rather than sent and silently overridden.
            let arrived = originalHeaders.first { $0.id == entry.id }.map { MCPHeaderPair(name: $0.key, value: $0.value) }
            if let refusal = HeldRequestFraming.refusal(name: entry.key, value: entry.value, arrived: arrived) {
                return refusal
            }
        }

        // Duplicate names are deliberately NOT a problem. They are legal on
        // the wire (Cookie, Set-Cookie, Accept) and the decision goes back as
        // an ordered pair array, so both survive. This used to refuse them
        // because the draft re-encoded object-map headers back into a JSON
        // object, which keeps one of a pair and drops the other without
        // saying so — that encoder is gone.
        return nil
    }

    var canResume: Bool { headerProblem == nil }

    // MARK: - Display

    /// The path and query exactly as the request carries them.
    ///
    /// Sliced by hand rather than through `URL`: `URL.path` percent-DECODES,
    /// and everything downstream of here — the core's matcher included —
    /// compares the raw URI, percent-encoding and all. Showing a decoded path
    /// would mean the panel and the proxy disagree about what this request is.
    var pathAndQuery: String { Self.pathAndQuery(from: request.uri) }

    var displayURL: String { "\(request.scheme.lowercased())://\(request.host)\(pathAndQuery)" }

    static func pathAndQuery(from uri: String) -> String {
        if let schemeSeparator = uri.range(of: "://") {
            let afterScheme = uri[schemeSeparator.upperBound...]
            guard let firstSlash = afterScheme.firstIndex(of: "/") else { return "/" }
            return String(afterScheme[firstSlash...])
        }
        if uri.isEmpty { return "/" }
        return uri.hasPrefix("/") ? uri : "/" + uri
    }

    /// The short label a queue pill shows: enough to tell two held requests
    /// apart at a glance without the pill growing to the width of a URL.
    static func shortLabel(for request: PausedRequestCodable) -> String {
        let path = pathAndQuery(from: request.uri)
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let lastComponent = withoutQuery.split(separator: "/").last.map(String.init)
        guard let lastComponent, !lastComponent.isEmpty else { return request.host }
        return lastComponent
    }

    // MARK: - Helpers

    /// Rows with an empty name are the editor's blank "add a header" line, not
    /// a header — they never reach the wire and never count as an edit.
    private static func normalized(_ entries: [HeaderEntry]) -> [HeaderEntry] {
        entries.compactMap { entry in
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return HeaderEntry(id: entry.id, key: key, value: entry.value, isEnabled: entry.isEnabled)
        }
    }

    private static func comparable(_ entries: [HeaderEntry]) -> [String] {
        normalized(entries).map { "\($0.key)\u{0}\($0.value)\u{0}\($0.isEnabled)" }
    }

    private static func containsLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }
    }
}
