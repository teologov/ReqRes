//
//  HeldRequestBody.swift
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
//  What can be said about the body of a request held at a breakpoint (F19,
//  the shell's half for 1.1.0).
//
//  The core holds a request as soon as its HEAD arrives, and the one message
//  that describes it to the app (`breakpoint_hit`) is built right there: every
//  held request arrives with no preview and a byte count of 0, a JSON POST
//  carrying `Content-Length: 76` included. The Paused Requests panel printed
//  "Body (none)" beside that Content-Length, and because 0 == 0 it took the
//  absent body for a complete, empty one and offered it for editing — typing
//  there replaced a body nobody had seen. `list_paused_requests` printed no
//  body line at all.
//
//  So "0 bytes, no preview" means NOTHING here, and never "no body". What the
//  panel and the agent are told comes from the request's head instead. Since
//  core 35dd624 the core says it: `bodyExpected` (false — no body follows;
//  true — one follows, not in the payload; nil — the head cannot say, as for
//  an HTTP/2 GET without content-length, or an extension older than the field)
//  and `declaredBodyLength` (its Content-Length). When the core says nothing,
//  the request's own framing headers are read as before: a Content-Length, a
//  Transfer-Encoding saying a body follows in chunks, or neither — which over
//  HTTP/2 still allows a body, so even then the answer is "not shown", not
//  "none". The original body is read-only. Replacing it is an act of its own
//  (`HeldBodyEdit`): the editor starts EMPTY (from the body itself only when a
//  core reports all of it), until something is typed Resume sends the
//  original, and a TRACE — which may not carry a body — is never offered one.
//
//  The method travels with the body for that one method: a TRACE that
//  arrives with a body of its own is not "sent unchanged" by Resume — over
//  HTTP/1.1 the core answers it 502 instead of forwarding it (core 5efe7aa,
//  `UpstreamRequestValidator.declaresAnUnframedBody`) — so its note and its
//  agent line say so (`resumeOutcome`).
//
//  Pure on purpose, like the rest of MCPKit: the panel's draft (Sources/UI,
//  which has no test target) and `MCPTextFormat` both read these words, and a
//  sentence decided in one place cannot disagree with itself.
//

import Foundation

/// What ReqRes knows about a held request's body, and how to say it.
public struct HeldRequestBody: Equatable, Sendable {
    /// What the request's head says about its body: the core's reading when
    /// it sends one (`bodyExpected`, `declaredBodyLength`), the request's own
    /// framing headers otherwise.
    public enum Declared: Equatable, Sendable {
        /// `Content-Length: N`, N > 0.
        case length(Int)
        /// `Content-Length: 0` — the request says it has no body.
        case empty
        /// No body follows, and the request declares neither header: the
        /// core's `bodyExpected == false` for an HTTP/1 request with no
        /// Content-Length and no Transfer-Encoding (RFC 9112 §6.3 — such a
        /// request has no body).
        case noBody
        /// A `Transfer-Encoding` (chunked): a body follows in pieces, its
        /// size not known in advance. It outranks a Content-Length, as it does
        /// on the wire.
        case chunked(transferEncoding: String)
        /// A body follows, with no size declared and not in chunks: the core's
        /// `bodyExpected == true` for an HTTP/2 request whose method carries
        /// one (a POST, say) sent without content-length.
        case unsized
        /// Neither header, and the core did not say — an extension older than
        /// its fields, or a head that cannot say (an HTTP/2 GET, HEAD, DELETE,
        /// CONNECT or TRACE without content-length). Over HTTP/1.1 that means
        /// no body; over HTTP/2 a body can follow without either, so nothing
        /// is promised.
        case undeclared
        /// A Content-Length that is not one number — or several that disagree.
        case unreadableLength
        /// The headers themselves could not be read.
        case unknown
    }

    /// What the core handed over of the body itself.
    public enum Shown: Equatable, Sendable {
        /// Nothing: every core so far (no preview, a count of 0).
        case nothing
        /// All of it.
        case whole(String)
        /// Its first part only.
        case prefix(String)
    }

    /// What Resume, with no replacement body, does with the request.
    public enum ResumeOutcome: Equatable, Sendable {
        /// It goes on as the app sent it.
        case unchanged
        /// A TRACE carrying a body of its own: over HTTP/1.1 the core answers
        /// it 502 and records a failed row instead of forwarding it.
        case answered502OverHTTP1
        /// A TRACE whose headers could not be read: the 502 above if it has a
        /// body, sent on unchanged if it has none.
        case answered502OverHTTP1IfItHasABody
    }

    /// The held request's method, as the core sends it (`HTTPMethod.rawValue`).
    public let method: String
    public let declared: Declared
    public let shown: Shown
    /// The size the core reported, or nil when it reported none. A count of
    /// 0 is "none": it is what the core sends for a body it has not read.
    public let reportedByteCount: Int?

    /// - Parameters:
    ///   - method: the held request's method, as the core sends it.
    ///   - preview: the body text the core sent (`bodyPreview`).
    ///   - byteCount: the size the core sent (`bodyByteCount`).
    ///   - previewIsPrefix: true when `preview` is only the head of the body —
    ///     the panel works it out from the counts, the bridge carries it as
    ///     `bodyTruncated` (a redacted preview's length says nothing).
    ///   - headers: the request's headers, or nil when they could not be read.
    ///   - bodyExpected: the core's `PausedRequestCodable.bodyExpected` —
    ///     false: no body follows; true: one follows; nil: not said.
    ///   - declaredBodyLength: the core's `declaredBodyLength`, the head's
    ///     Content-Length, or nil.
    public init(method: String, preview: String?, byteCount: Int, previewIsPrefix: Bool, headers: [MCPHeaderPair]?,
                bodyExpected: Bool?, declaredBodyLength: Int?) {
        self.method = method
        self.declared = Self.declared(from: headers, bodyExpected: bodyExpected, declaredBodyLength: declaredBodyLength)
        self.reportedByteCount = byteCount > 0 ? byteCount : nil
        if let preview, !preview.isEmpty {
            self.shown = previewIsPrefix ? .prefix(preview) : .whole(preview)
        } else {
            // An empty preview is not "an empty body": nothing distinguishes
            // it from a body the core never read, so it is read as nothing.
            self.shown = .nothing
        }
    }

    /// A held request as an agent reads it — `list_paused_requests`, and the
    /// check on `answer_paused_request` — from the bridge's (redacted) copy.
    public init(_ request: MCPPausedRequest) {
        self.init(method: request.method, preview: request.bodyPreview, byteCount: request.bodyByteCount,
                  previewIsPrefix: request.bodyTruncated, headers: request.headers,
                  bodyExpected: request.bodyExpected, declaredBodyLength: request.declaredBodyLength)
    }

    // MARK: - Reading the request's framing

    /// What the head declares. The core's reading wins when it sends one —
    /// it read the head as the app sent it, and it knows what the shell
    /// cannot: whether the request came over HTTP/1 (where a request with
    /// neither header has no body) or HTTP/2 (where a POST needs neither).
    /// With nothing from the core (`bodyExpected == nil`), the headers are
    /// read as before (`declared(from:)`).
    ///
    /// Errs toward a body, as the core does: a size the head states is that
    /// size whatever the flag says, and headers that declare a body are never
    /// read as none.
    static func declared(from headers: [MCPHeaderPair]?, bodyExpected: Bool?, declaredBodyLength: Int?) -> Declared {
        let read = declared(from: headers)
        guard let bodyExpected else { return read }
        if let length = declaredBodyLength, length > 0 { return .length(length) }
        switch read {
        case .length, .chunked:
            // The core never says "no body" for a request with body bytes;
            // headers declaring one are believed over a flag that disagrees.
            return read
        default:
            break
        }
        if bodyExpected { return .unsized }
        return declaredBodyLength == 0 || read == .empty ? .empty : .noBody
    }

    /// What the headers declare. Names are matched without case (HTTP/2
    /// sends them lowercase); `TE` is a different header and never counts.
    static func declared(from headers: [MCPHeaderPair]?) -> Declared {
        guard let headers else { return .unknown }
        func values(_ name: String) -> [String] {
            headers
                .filter { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name }
                .map { $0.value.trimmingCharacters(in: .whitespaces) }
        }
        let transferEncodings = values("transfer-encoding")
        if !transferEncodings.isEmpty {
            return .chunked(transferEncoding: transferEncodings.filter { !$0.isEmpty }.joined(separator: ", "))
        }
        let lengths = values("content-length")
        guard !lengths.isEmpty else { return .undeclared }
        // One number, possibly repeated — as a list in one header or across
        // several, which a recipient may accept when every copy agrees.
        let parts = lengths.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let numbers = parts.map { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard let first = numbers.first ?? nil, numbers.allSatisfy({ $0 == first }) else { return .unreadableLength }
        return first == 0 ? .empty : .length(first)
    }

    /// True when the request has no body to show or to lose: it declares an
    /// empty one, or (the core says) none follows.
    var declaresNoBody: Bool {
        guard reportedByteCount == nil else { return false }
        return declared == .empty || declared == .noBody
    }

    /// What Resume does with the request when no replacement is sent: it goes
    /// on unchanged — except a TRACE carrying a body of its own, which over
    /// HTTP/1.1 the core refuses to forward (core 5efe7aa): NIO's encoder
    /// frames a TRACE as having no body, so its bytes would reach the origin
    /// raw, read as another request. ReqRes answers it 502 with a failed row.
    /// Over HTTP/2 a body is framed by its DATA frames and nothing is refused.
    public var resumeOutcome: ResumeOutcome {
        guard Self.mayNotCarryABody(method: method) else { return .unchanged }
        if reportedByteCount != nil { return .answered502OverHTTP1 }
        if case .nothing = shown {} else { return .answered502OverHTTP1 }
        switch declared {
        case .length, .chunked, .unsized, .unreadableLength:
            return .answered502OverHTTP1
        case .unknown:
            return .answered502OverHTTP1IfItHasABody
        case .empty, .noBody, .undeclared:
            // No body over HTTP/1.1 (Content-Length: 0, or neither header);
            // `.undeclared` over HTTP/2 is never refused.
            return .unchanged
        }
    }

    // MARK: - The panel

    /// The Body tab's title. Never "(none)": the core does not report the
    /// body when it holds the request, so the most this can say is what the
    /// request declares — "empty" when it has none.
    public var tabTitle: String {
        switch shown {
        case .whole(let text):
            return "Body (\(Self.size(reportedByteCount ?? text.utf8.count)))"
        case .prefix:
            guard let total = reportedByteCount ?? declaredLength else { return "Body (partly shown)" }
            return "Body (\(Self.size(total)), partly shown)"
        case .nothing:
            if let reportedByteCount { return "Body (\(Self.size(reportedByteCount)), not shown)" }
            switch declared {
            case .length(let length): return "Body (\(Self.size(length)), not shown)"
            case .empty, .noBody: return "Body (empty)"
            case .chunked, .unsized, .undeclared, .unreadableLength, .unknown: return "Body (not shown)"
            }
        }
    }

    /// The line over `note` where a body would be: "Body not shown" unless
    /// the request has none.
    public var headline: String {
        switch shown {
        case .whole: return "Body"
        case .prefix: return "Body, partly shown"
        case .nothing: return declaresNoBody ? "Empty body" : "Body not shown"
        }
    }

    /// The SF Symbol beside `headline`. An eye struck through says "there is
    /// a body, and it is hidden", which is false of a request that has none:
    /// "Empty body" — every held HTTP/1.1 GET since core 35dd624 — gets an
    /// empty frame instead.
    public var headlineSymbol: String {
        switch shown {
        case .whole, .prefix: return "doc.plaintext"
        case .nothing: return declaresNoBody ? "square.dashed" : "eye.slash"
        }
    }

    /// The sentence under the body while nothing replaces it.
    public var note: String {
        switch shown {
        case .whole:
            return "This is the request's whole body. " + resumeSentence
        case .prefix(let text):
            let total = (reportedByteCount ?? declaredLength).map { " of this \(Self.size($0)) body" } ?? " of this body"
            let shownPart = "ReqRes shows only the first \(Self.size(text.utf8.count))\(total). "
            guard resumeOutcome == .unchanged else { return shownPart + resumeSentence }
            return shownPart + "Resume sends the original, whole. "
                + "A replacement starts empty, never from this part: sending a part back would cut the rest off."
        case .nothing:
            if let reportedByteCount {
                return "ReqRes holds this \(Self.size(reportedByteCount)) body but does not show it here. " + resumeSentence
            }
            switch declared {
            case .length(let length):
                return "This request declares a body of \(Self.size(length)) (Content-Length: \(length)). " + heldAtTheHead
            case .empty:
                return "This request declares an empty body (Content-Length: 0). Resume sends it as it is."
            case .noBody:
                return "This request has no body: it declares neither a Content-Length nor a Transfer-Encoding. Resume sends it as it is."
            case .chunked(let encoding):
                return "This request sends its body in chunks (\(Self.transferEncodingLabel(encoding))), so its size is not known in advance. "
                    + heldAtTheHead
            case .unsized:
                return "This request has a body whose size it does not declare in advance (over HTTP/2 a request needs no Content-Length). "
                    + heldAtTheHead
            case .undeclared:
                return "This request has no Content-Length or Transfer-Encoding. Over HTTP/1.1 that means it has no body; "
                    + "over HTTP/2 a body can still follow, and ReqRes would not show it. Resume sends the request unchanged."
            case .unreadableLength:
                return "This request's Content-Length is not one number, so ReqRes cannot tell the body's size. "
                    + heldAtTheHead
            case .unknown:
                let resume = resumeOutcome == .unchanged ? "Resume sends the request unchanged." : resumeSentence
                return "ReqRes could not read this request's headers, so it cannot tell whether a body follows. " + resume
            }
        }
    }

    /// The panel's footer sentence about Resume: it sends the request on to
    /// `host`, unchanged or with the user's edits — except a TRACE carrying a
    /// body of its own, which over HTTP/1.1 ReqRes answers 502 whatever was
    /// edited (no edit takes the body away: Content-Length and
    /// Transfer-Encoding are locked, and the app's own framing goes up with
    /// the app's own body).
    public func resumeFooter(host: String, edited: Bool) -> String {
        switch resumeOutcome {
        case .unchanged:
            return edited ? "Resume sends it on to \(host) with your changes." : "Resume sends it on to \(host) unchanged."
        case .answered502OverHTTP1:
            return "This TRACE carries a body, so resumed over HTTP/1.1 it is answered 502 by ReqRes instead of being sent on to \(host)."
        case .answered502OverHTTP1IfItHasABody:
            return "If this TRACE carries a body, resumed over HTTP/1.1 it is answered 502 by ReqRes instead of being sent on to \(host)."
        }
    }

    /// Where the replacement editor starts: the body itself when the core
    /// reported all of it, and otherwise nothing — never a part (sending a
    /// prefix back as "the body" drops the rest of the upload).
    public var replacementSeed: String {
        if case .whole(let text) = shown { return text }
        return ""
    }

    // MARK: - The agent

    /// `list_paused_requests`' body line — printed for every held request,
    /// because a request with no line reads as a request with no body. The
    /// first line is the label; a shown body follows it as the second.
    public var agentLines: [String] {
        let size = reportedByteCount.map(String.init)
        switch shown {
        case .whole(let text):
            return ["body (\(size ?? String(text.utf8.count)) bytes):", text]
        case .prefix(let text):
            return ["body (\(size.map { "\($0) bytes, " } ?? "")TRUNCATED — do not send this back as the new body):", text]
        case .nothing:
            let onResume: String
            switch resumeOutcome {
            case .unchanged: onResume = " — resume without `body` to send it unchanged"
            case .answered502OverHTTP1: onResume = " — " + Self.traceAnswered502ForAgents
            case .answered502OverHTTP1IfItHasABody: onResume = " — " + Self.traceAnswered502IfItHasABodyForAgents
            }
            if let size { return ["body: \(size) bytes, not shown" + onResume] }
            switch declared {
            case .length(let length):
                return ["body: \(length) bytes (Content-Length), not shown" + onResume]
            case .empty:
                return ["body: empty (Content-Length: 0)"]
            case .noBody:
                return ["body: empty (no Content-Length or Transfer-Encoding)"]
            case .chunked(let encoding):
                return ["body: sent in chunks (\(Self.transferEncodingLabel(encoding))), size unknown, not shown" + onResume]
            case .unsized:
                return ["body: size not declared (HTTP/2), not shown" + onResume]
            case .undeclared:
                return ["body: not shown; the request has no Content-Length or Transfer-Encoding (no body over HTTP/1.1, "
                        + "though over HTTP/2 one can follow) — resume without `body` to send the request unchanged"]
            case .unreadableLength:
                return ["body: size unknown (its Content-Length is not one number), not shown" + onResume]
            case .unknown:
                let resume = resumeOutcome == .unchanged ? " — resume without `body` to send the request unchanged" : onResume
                return ["body: not shown; the request's headers could not be read" + resume]
            }
        }
    }

    /// The agent's 400 for a `body` on this request, or nil when it may be
    /// given one. Only a TRACE is refused (`replacementRefusal(method:)`), and
    /// what to do instead depends on the TRACE: one with no body of its own
    /// resumes without `body`; one carrying a body is answered the same 502
    /// over HTTP/1.1 when resumed, so it is told to abort instead.
    public var replacementRefusalForAgents: String? {
        guard Self.mayNotCarryABody(method: method) else { return nil }
        let refused = "A TRACE request may not carry a body, so `body` is refused for one: "
            + "over HTTP/1.1 ReqRes answers a TRACE with a body 502 instead of forwarding it."
        switch resumeOutcome {
        case .unchanged:
            return refused + " Resume it without `body`."
        case .answered502OverHTTP1:
            return refused + " This one declares a body of its own, so resumed over HTTP/1.1 it gets that 502 too: abort it to answer it here."
        case .answered502OverHTTP1IfItHasABody:
            return refused + " If this one has a body of its own, resumed over HTTP/1.1 it gets that 502 too: abort it to answer it here."
        }
    }

    // MARK: - What a replacement does to the original

    /// What becomes of the original body once a replacement is sent (core
    /// 35dd624): none of it reaches the server. The parts that arrived while
    /// the request was held are dropped with the hold, and whatever the app
    /// still sends of it — a large or streamed upload, one waiting for
    /// `100 Continue` — is read and discarded until the request ends, over
    /// HTTP/1.1 and HTTP/2 alike, as the rest of an aborted request is.
    /// Before it, those late parts went upstream behind the replacement, where
    /// an HTTP/1.1 server read them as another request.
    ///
    /// The sentence states its own condition. Help and the agent texts print
    /// it beside "without a replacement, the original goes", and an
    /// unconditional "None of the original goes to the server" there read as
    /// the opposite of the sentence before it.
    ///
    /// One sentence for the panel's note, `answer_paused_request`, SKILL.md
    /// and Help, so the four cannot come to disagree.
    public static let originalDroppedNote =
        "With a replacement, none of the original goes to the server: what has arrived of it, and whatever the app still sends, is read and dropped."

    // MARK: - A request that may not carry a body

    /// True for the one method that may not carry a body: TRACE (RFC 9110
    /// §9.3.8). The method as the core sends it (`HTTPMethod.rawValue`),
    /// compared as the core compares it (`head.method == .TRACE`): exactly.
    static func mayNotCarryABody(method: String) -> Bool {
        method == "TRACE"
    }

    /// Why a request held with `method` cannot be given a replacement body,
    /// or nil when it can. Only a TRACE: RFC 9110 §9.3.8 forbids content in
    /// one, and since core 5efe7aa an HTTP/1 TRACE carrying a body — the
    /// app's own or a replacement — ends in ReqRes's 502 and a failed row
    /// instead of reaching the server (NIO's encoder frames a TRACE as having
    /// no body and would put the bytes on the wire raw). The panel cannot
    /// tell HTTP/1 from HTTP/2 for a held request, so a TRACE is never offered
    /// a body at all.
    public static func replacementRefusal(method: String) -> String? {
        mayNotCarryABody(method: method) ? traceNote : nil
    }

    /// The panel's words, where Replace Body… would be.
    public static let traceNote =
        "A TRACE request may not carry a body, so this one cannot be given one here: over HTTP/1.1 ReqRes answers a TRACE with a body 502 instead of forwarding it."

    /// The panel's words for what Resume does with a TRACE carrying a body of
    /// its own (`ResumeOutcome.answered502OverHTTP1`).
    public static let traceAnswered502 =
        "A TRACE may not carry a body: resumed over HTTP/1.1, this one is answered 502 by ReqRes instead of being forwarded. Abort answers it here."

    /// The same, for a TRACE whose headers could not be read.
    public static let traceAnswered502IfItHasABody =
        "A TRACE may not carry a body: if this one has one, resumed over HTTP/1.1 it is answered 502 by ReqRes instead of being forwarded. Abort answers it here."

    /// `traceAnswered502` in an agent's body line.
    static let traceAnswered502ForAgents =
        "a TRACE may not carry a body: resumed over HTTP/1.1, this one is answered 502 by ReqRes instead of being forwarded; abort answers it here"

    /// `traceAnswered502IfItHasABody` in an agent's body line.
    static let traceAnswered502IfItHasABodyForAgents =
        "a TRACE may not carry a body: if this one has one, resumed over HTTP/1.1 it is answered 502 by ReqRes instead of being forwarded; abort answers it here"

    // MARK: - Helpers

    var declaredLength: Int? {
        if case .length(let length) = declared { return length }
        return nil
    }

    /// What Resume does, said the same way wherever it applies.
    private var resumeSentence: String {
        switch resumeOutcome {
        case .unchanged: return "Resume sends it unchanged."
        case .answered502OverHTTP1: return Self.traceAnswered502
        case .answered502OverHTTP1IfItHasABody: return Self.traceAnswered502IfItHasABody
        }
    }

    /// Why the body is not on screen, and what Resume does with it.
    private var heldAtTheHead: String {
        "A request stops here as soon as its headers arrive, and ReqRes does not show its body. " + resumeSentence
    }

    private static func transferEncodingLabel(_ encoding: String) -> String {
        encoding.isEmpty ? "Transfer-Encoding" : "Transfer-Encoding: \(encoding)"
    }

    /// "1 byte", "76 bytes", then 1024-based "2 KB" / "5.3 MB" — exact while
    /// a person can still count it, and locale-independent either way.
    static func size(_ bytes: Int) -> String {
        if bytes == 1 { return "1 byte" }
        if bytes < 1024 { return "\(max(0, bytes)) bytes" }
        return RecordedExchangeCopy.binaryBytes(Int64(bytes))
    }
}

/// The body half of what the Paused Requests panel is about to send: the
/// original, or a replacement the user chose to write.
///
/// The one rule this type exists for: nothing replaces the original body
/// unless the user asked for a replacement AND wrote something different from
/// where the editor started. Opening the editor and typing nothing — or
/// clearing what was typed — sends the original, because an empty editor
/// cannot be told apart from "not yet". (An agent's explicit `body: ""` is
/// different: it says what it means.) And a request that may not carry a body
/// (a TRACE) is never given one: the editor does not open.
public struct HeldBodyEdit: Equatable, Sendable {
    public let held: HeldRequestBody
    /// Why this request's body cannot be replaced, or nil when it can
    /// (`HeldRequestBody.replacementRefusal(method:)`, from `held.method`).
    public let replacementRefusal: String?
    /// True while the replacement editor is open.
    public private(set) var isReplacing = false
    /// The replacement. Read only while `isReplacing`.
    public var text: String

    public init(_ held: HeldRequestBody) {
        self.held = held
        self.replacementRefusal = HeldRequestBody.replacementRefusal(method: held.method)
        self.text = held.replacementSeed
    }

    /// False for a request that may not carry a body: Replace Body… is not
    /// offered, and nothing typed becomes one.
    public var canReplace: Bool { replacementRefusal == nil }

    /// Opens the editor, from `replacementSeed` — unless the request may not
    /// carry a body.
    public mutating func startReplacing() {
        guard canReplace else { return }
        isReplacing = true
        text = held.replacementSeed
    }

    /// Closes the editor and forgets what was typed: Resume sends the original.
    public mutating func keepOriginal() {
        isReplacing = false
        text = held.replacementSeed
    }

    /// True when Resume would send something other than the original body.
    public var isChanged: Bool { canReplace && isReplacing && text != held.replacementSeed }

    /// What goes back to the core: nil means "the original, untouched".
    public var payload: String? { isChanged ? text : nil }

    /// The Body tab's title — the replacement's, once there is one.
    public var tabTitle: String { isChanged ? "Body (replaced)" : held.tabTitle }

    /// The sentence under the body, or under the editor while it is open.
    public var note: String {
        guard isReplacing else { return held.note }
        let typed = HeldRequestBody.size(text.utf8.count)
        switch held.shown {
        case .whole:
            return isChanged
                ? "Resume sends this body (\(typed)) in place of the original. ReqRes sets its Content-Length to match."
                : "Edit the body to change it. As it stands, Resume sends the original unchanged."
        case .prefix:
            return isChanged
                ? "Resume sends what you typed (\(typed)) in place of the whole original body. ReqRes sets its Content-Length to match. "
                    + HeldRequestBody.originalDroppedNote
                : "Type the body to send instead. Until you type something, Resume sends the original body unchanged."
        case .nothing:
            guard isChanged else {
                return "Type the body to send instead. Until you type something, Resume sends the original body unchanged."
            }
            if held.declaresNoBody {
                return "Resume sends what you typed (\(typed)) as the request's body. ReqRes sets its Content-Length to match."
            }
            return "Resume sends what you typed (\(typed)) in place of the original body, which ReqRes has not shown you. "
                + "ReqRes sets its Content-Length to match. " + HeldRequestBody.originalDroppedNote
        }
    }
}
