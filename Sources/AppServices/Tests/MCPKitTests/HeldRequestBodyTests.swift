//
//  HeldRequestBodyTests.swift
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
//  F19: what the Paused Requests panel and list_paused_requests say about a
//  held request's body, and when a replacement is sent. The core holds a
//  request at its head and reports no body — `bodyPreview: nil`,
//  `bodyByteCount: 0` for every request (GlueHandler.holdForBreakpoint) — and
//  the panel read that as a complete, empty body: "Body (none)" beside
//  `Content-Length: 76`, and an empty editor whose text replaced the real body.
//
//  Since core 35dd624 the payload also carries the core's reading of the head:
//  `bodyExpected` and `declaredBodyLength` (`GlueHandler.heldBodyFraming`).
//  The labels follow it, and fall back to the headers when it says nothing.
//

import XCTest
@testable import MCPKit

/// What the core sends today (35dd624+) for every held request: no preview, a
/// count of 0, and its reading of the head.
private func coreHeld(_ headers: [MCPHeaderPair]?, expected: Bool?, length: Int?, method: String = "POST") -> HeldRequestBody {
    HeldRequestBody(method: method, preview: nil, byteCount: 0, previewIsPrefix: false, headers: headers,
                    bodyExpected: expected, declaredBodyLength: length)
}

/// The same with nothing from the core about the body: an extension older
/// than the fields — or a head that cannot say (an HTTP/2 GET without
/// content-length), for which the core sends nil too.
private func headersOnly(_ headers: [MCPHeaderPair]?, method: String = "POST") -> HeldRequestBody {
    coreHeld(headers, expected: nil, length: nil, method: method)
}

private func header(_ name: String, _ value: String) -> MCPHeaderPair {
    MCPHeaderPair(name: name, value: value)
}

private let json = [header("Content-Type", "application/json")]

final class HeldRequestBodyTests: XCTestCase {
    // MARK: - The labels, from the core's reading of the head

    /// One row per shape the core's `heldBodyFraming` produces, plus an
    /// extension older than the fields — and the words the panel and the
    /// agent get for each. "Empty body" exactly when no body follows, under
    /// an empty frame rather than the eye struck through that says "hidden".
    func testTheLabelsFollowTheCoresReadingOfTheHead() {
        let unchanged = " — resume without `body` to send it unchanged"
        struct Row {
            let line: UInt
            let expected: Bool?
            let length: Int?
            let headers: [MCPHeaderPair]?
            let declared: HeldRequestBody.Declared
            let tab: String
            let headline: String
            let agent: String
            var method: String = "POST"
        }
        let rows: [Row] = [
            // HTTP/1.1 POST with a body.
            Row(line: #line, expected: true, length: 76, headers: json + [header("Content-Length", "76")],
                declared: .length(76), tab: "Body (76 bytes, not shown)", headline: "Body not shown",
                agent: "body: 76 bytes (Content-Length), not shown" + unchanged),
            // Content-Length: 0, either protocol.
            Row(line: #line, expected: false, length: 0, headers: [header("Content-Length", "0")],
                declared: .empty, tab: "Body (empty)", headline: "Empty body",
                agent: "body: empty (Content-Length: 0)"),
            // HTTP/1.1 with neither header: a GET, or a POST that sends none.
            Row(line: #line, expected: false, length: nil, headers: [header("Accept", "*/*")],
                declared: .noBody, tab: "Body (empty)", headline: "Empty body",
                agent: "body: empty (no Content-Length or Transfer-Encoding)"),
            // HTTP/1.1 chunked upload; Transfer-Encoding outranks a length.
            Row(line: #line, expected: true, length: nil, headers: [header("Transfer-Encoding", "chunked")],
                declared: .chunked(transferEncoding: "chunked"), tab: "Body (not shown)", headline: "Body not shown",
                agent: "body: sent in chunks (Transfer-Encoding: chunked), size unknown, not shown" + unchanged),
            Row(line: #line, expected: true, length: nil,
                headers: [header("Transfer-Encoding", "chunked"), header("Content-Length", "76")],
                declared: .chunked(transferEncoding: "chunked"), tab: "Body (not shown)", headline: "Body not shown",
                agent: "body: sent in chunks (Transfer-Encoding: chunked), size unknown, not shown" + unchanged),
            // HTTP/2 POST without content-length: a body follows, unsized.
            Row(line: #line, expected: true, length: nil, headers: [header("content-type", "application/json")],
                declared: .unsized, tab: "Body (not shown)", headline: "Body not shown",
                agent: "body: size not declared (HTTP/2), not shown" + unchanged),
            // HTTP/2 POST with content-length.
            Row(line: #line, expected: true, length: 76, headers: [header("content-length", "76")],
                declared: .length(76), tab: "Body (76 bytes, not shown)", headline: "Body not shown",
                agent: "body: 76 bytes (Content-Length), not shown" + unchanged),
            // HTTP/2 GET without content-length: the head cannot say.
            Row(line: #line, expected: nil, length: nil, headers: [header("accept", "*/*")],
                declared: .undeclared, tab: "Body (not shown)", headline: "Body not shown",
                agent: "body: not shown; the request has no Content-Length or Transfer-Encoding (no body over HTTP/1.1, "
                    + "though over HTTP/2 one can follow) — resume without `body` to send the request unchanged",
                method: "GET"),
            // A Content-Length that is not one number: the core says nil.
            Row(line: #line, expected: nil, length: nil, headers: [header("Content-Length", "abc")],
                declared: .unreadableLength, tab: "Body (not shown)", headline: "Body not shown",
                agent: "body: size unknown (its Content-Length is not one number), not shown" + unchanged),
            // An extension older than the fields: the headers, as before.
            Row(line: #line, expected: nil, length: nil, headers: [header("Content-Length", "76")],
                declared: .length(76), tab: "Body (76 bytes, not shown)", headline: "Body not shown",
                agent: "body: 76 bytes (Content-Length), not shown" + unchanged),
            Row(line: #line, expected: nil, length: nil, headers: [header("Content-Length", "0")],
                declared: .empty, tab: "Body (empty)", headline: "Empty body",
                agent: "body: empty (Content-Length: 0)"),
            Row(line: #line, expected: nil, length: nil, headers: [header("Transfer-Encoding", "chunked")],
                declared: .chunked(transferEncoding: "chunked"), tab: "Body (not shown)", headline: "Body not shown",
                agent: "body: sent in chunks (Transfer-Encoding: chunked), size unknown, not shown" + unchanged),
            // A length only the core states (headers redacted or reordered): its length wins.
            Row(line: #line, expected: true, length: 2048, headers: [],
                declared: .length(2048), tab: "Body (2 KB, not shown)", headline: "Body not shown",
                agent: "body: 2048 bytes (Content-Length), not shown" + unchanged),
        ]
        for row in rows {
            let body = coreHeld(row.headers, expected: row.expected, length: row.length, method: row.method)
            XCTAssertEqual(body.declared, row.declared, line: row.line)
            XCTAssertEqual(body.tabTitle, row.tab, line: row.line)
            XCTAssertEqual(body.headline, row.headline, line: row.line)
            XCTAssertEqual(body.headlineSymbol, row.headline == "Empty body" ? "square.dashed" : "eye.slash", line: row.line)
            XCTAssertEqual(body.agentLines, [row.agent], line: row.line)
            XCTAssertEqual(body.shown, .nothing, line: row.line)
            XCTAssertEqual(body.resumeOutcome, .unchanged, "only a TRACE is refused on the way out", line: row.line)
            XCTAssertEqual(body.replacementSeed, "", "a replacement never starts from a body nobody has seen", line: row.line)
            XCTAssertFalse(body.tabTitle.contains("none"), line: row.line)
        }
    }

    /// "Empty body" is every held HTTP/1.1 GET since core 35dd624: its
    /// symbol may not be the eye struck through, which says a body is there
    /// and hidden. A body not shown keeps it; a shown one is a document.
    func testTheHeadlineSymbolSaysWhetherThereIsABody() {
        let get = coreHeld([header("Accept", "*/*")], expected: false, length: nil, method: "GET")
        XCTAssertEqual(get.headline, "Empty body")
        XCTAssertEqual(get.headlineSymbol, "square.dashed")
        XCTAssertEqual(coreHeld([header("Content-Length", "0")], expected: false, length: 0).headlineSymbol, "square.dashed")

        for hidden in [coreHeld(json + [header("Content-Length", "76")], expected: true, length: 76),
                       coreHeld(json, expected: true, length: nil),
                       coreHeld([header("Transfer-Encoding", "chunked")], expected: true, length: nil),
                       headersOnly(json), headersOnly(nil),
                       HeldRequestBody(method: "POST", preview: nil, byteCount: 2048, previewIsPrefix: false, headers: [],
                                       bodyExpected: false, declaredBodyLength: nil)] {
            XCTAssertEqual(hidden.headline, "Body not shown")
            XCTAssertEqual(hidden.headlineSymbol, "eye.slash", "\(hidden.declared)")
        }

        let whole = HeldRequestBody(method: "POST", preview: "{}", byteCount: 2, previewIsPrefix: false, headers: json,
                                    bodyExpected: true, declaredBodyLength: 2)
        XCTAssertEqual(whole.headlineSymbol, "doc.plaintext")
    }

    /// The core errs toward "a body follows" and so does the reading: headers
    /// that declare a body are never read as none, whatever the flag says.
    func testHeadersDeclaringABodyAreNeverReadAsNone() {
        XCTAssertEqual(coreHeld([header("Content-Length", "76")], expected: false, length: nil).declared, .length(76))
        XCTAssertEqual(coreHeld([header("Transfer-Encoding", "chunked")], expected: false, length: nil).declared,
                       .chunked(transferEncoding: "chunked"))
        // A flag saying a body follows over a Content-Length of 0: unsized, not empty.
        XCTAssertEqual(coreHeld([header("Content-Length", "0")], expected: true, length: nil).declared, .unsized)
        // Headers that could not be read, with the core's word: its word.
        XCTAssertEqual(coreHeld(nil, expected: false, length: nil).declared, .noBody)
        XCTAssertEqual(coreHeld(nil, expected: true, length: nil).declared, .unsized)
        XCTAssertEqual(coreHeld(nil, expected: false, length: 0).declared, .empty)
    }

    /// A screenshot of build 50, on today's core: "Body (none)" in
    /// the tab beside `Content-Length: 76` in Headers.
    func testTheCoresPayloadForAPostWithABodyIsNotShownNotNone() {
        let body = coreHeld(json + [header("Content-Length", "76")], expected: true, length: 76)

        XCTAssertEqual(body.tabTitle, "Body (76 bytes, not shown)")
        XCTAssertEqual(body.headline, "Body not shown")
        XCTAssertTrue(body.note.contains("Content-Length: 76"), body.note)
        XCTAssertTrue(body.note.hasSuffix("Resume sends it unchanged."), body.note)
    }

    /// No body follows: said as such, and nothing to lose by resuming.
    func testARequestWithNoBodyReadsEmpty() {
        let none = coreHeld([], expected: false, length: nil)
        XCTAssertEqual(none.note, "This request has no body: it declares neither a Content-Length nor a Transfer-Encoding. Resume sends it as it is.")

        let zero = coreHeld([header("Content-Length", "0")], expected: false, length: 0)
        XCTAssertEqual(zero.note, "This request declares an empty body (Content-Length: 0). Resume sends it as it is.")
    }

    /// An HTTP/2 POST needs no content-length: a body follows, unsized — the
    /// core says so, where the headers alone could not tell it from a GET.
    func testAnHTTP2PostWithoutALengthIsABodyNotShown() {
        let body = coreHeld(json, expected: true, length: nil)

        XCTAssertEqual(body.declared, .unsized)
        XCTAssertTrue(body.note.hasPrefix("This request has a body whose size it does not declare in advance"), body.note)
        XCTAssertTrue(body.note.hasSuffix("Resume sends it unchanged."), body.note)
    }

    // MARK: - When the core says nothing: the headers

    /// HTTP/2 needs no content-length and forbids Transfer-Encoding, so a
    /// request that declares nothing may still have a body when the core
    /// cannot say. (An earlier reading said "(none)" whenever there was no
    /// Content-Length.)
    func testARequestThatDeclaresNothingIsNotShownEither() {
        let body = headersOnly(json)

        XCTAssertEqual(body.declared, .undeclared)
        XCTAssertEqual(body.tabTitle, "Body (not shown)")
        XCTAssertTrue(body.note.contains("over HTTP/2 a body can still follow"), body.note)
        XCTAssertEqual(body.headline, "Body not shown")
    }

    /// With nothing from the core, no header set reads "(none)", and none of
    /// them offers the absent body as something to start a replacement from.
    func testNoPayloadReadsAsNone() {
        let headerSets: [[MCPHeaderPair]?] = [
            nil, [], json,
            [header("Content-Length", "76")], [header("content-length", "76")],
            [header("Content-Length", "0")], [header("Transfer-Encoding", "chunked")],
            [header("Content-Length", "abc")], [header("te", "trailers")],
        ]
        for headers in headerSets {
            for expected in [nil, true, false] as [Bool?] {
                for preview in [nil, ""] as [String?] {
                    let body = HeldRequestBody(method: "POST", preview: preview, byteCount: 0, previewIsPrefix: false, headers: headers,
                                               bodyExpected: expected, declaredBodyLength: nil)
                    XCTAssertFalse(body.tabTitle.contains("none"), "\(String(describing: headers)): \(body.tabTitle)")
                    XCTAssertFalse(body.note.contains("arrived with no body"), "\(String(describing: headers)): \(body.note)")
                    XCTAssertEqual(body.shown, .nothing, "an empty preview is not an empty body")
                    XCTAssertEqual(body.replacementSeed, "")
                }
            }
        }
    }

    func testContentLengthIsReadWithoutCaseAsHTTP2SendsIt() {
        XCTAssertEqual(headersOnly([header("content-length", "1024")]).declared, .length(1024))
        XCTAssertEqual(headersOnly([header(" Content-Length ", " 12 ")]).declared, .length(12))
    }

    /// A chunked body's size is not known in advance; Transfer-Encoding
    /// outranks a Content-Length beside it, as it does on the wire.
    func testTransferEncodingMeansChunkedWhateverTheLength() {
        let body = headersOnly([header("Transfer-Encoding", "chunked"), header("Content-Length", "76")])

        XCTAssertEqual(body.declared, .chunked(transferEncoding: "chunked"))
        XCTAssertEqual(body.tabTitle, "Body (not shown)")
        XCTAssertTrue(body.note.contains("in chunks (Transfer-Encoding: chunked)"), body.note)
    }

    /// `TE: trailers` (every gRPC request) is a different header.
    func testTheTEHeaderIsNotTransferEncoding() {
        XCTAssertEqual(headersOnly([header("TE", "trailers")]).declared, .undeclared)
    }

    /// A length the request states twice, identically, is still one length;
    /// anything else is a request whose size nobody can state.
    func testALengthMustBeOneNumber() {
        XCTAssertEqual(headersOnly([header("Content-Length", "76, 76")]).declared, .length(76))
        XCTAssertEqual(headersOnly([header("Content-Length", "76"), header("content-length", "076")]).declared, .length(76))
        for value in ["abc", "76, 80", "-1", "", "7 6", "76,", "+76", "٧٦"] {
            XCTAssertEqual(headersOnly([header("Content-Length", value)]).declared, .unreadableLength, "“\(value)”")
        }
        XCTAssertEqual(headersOnly([header("Content-Length", "76"), header("Content-Length", "80")]).declared, .unreadableLength)
        XCTAssertEqual(headersOnly([header("Content-Length", "abc")]).tabTitle, "Body (not shown)")
    }

    /// The headers were not JSON and the core said nothing: nothing can be
    /// said about the body.
    func testUnreadableHeadersSayNothingAboutTheBody() {
        let body = headersOnly(nil)

        XCTAssertEqual(body.declared, .unknown)
        XCTAssertEqual(body.tabTitle, "Body (not shown)")
        XCTAssertTrue(body.note.contains("could not read this request's headers"), body.note)
    }

    // MARK: - A core that reports bodies

    func testAWholeReportedBodyIsShownAndSeedsTheReplacement() {
        let text = #"{"sku":"A-1"}"#
        let body = HeldRequestBody(method: "POST", preview: text, byteCount: text.utf8.count, previewIsPrefix: false, headers: json,
                                   bodyExpected: true, declaredBodyLength: text.utf8.count)

        XCTAssertEqual(body.shown, .whole(text))
        XCTAssertEqual(body.tabTitle, "Body (13 bytes)")
        XCTAssertEqual(body.replacementSeed, text)
        XCTAssertEqual(body.note, "This is the request's whole body. Resume sends it unchanged.")
    }

    /// A prefix is shown, and a replacement never starts from it: sent back
    /// as "the body", it would cut the rest of the upload off.
    func testAPrefixIsShownButNeverSeedsTheReplacement() {
        let body = HeldRequestBody(method: "POST", preview: "{\"a\":1", byteCount: 90_000, previewIsPrefix: true, headers: json,
                                   bodyExpected: true, declaredBodyLength: nil)

        XCTAssertEqual(body.shown, .prefix("{\"a\":1"))
        XCTAssertEqual(body.tabTitle, "Body (87.9 KB, partly shown)")
        XCTAssertEqual(body.replacementSeed, "")
        XCTAssertTrue(body.note.contains("first 6 bytes of this 87.9 KB body"), body.note)
    }

    /// A size with no text: the reported size wins over the declared one.
    func testAReportedSizeWithoutTextIsNotShown() {
        let body = HeldRequestBody(method: "POST", preview: nil, byteCount: 2048, previewIsPrefix: false, headers: [header("Content-Length", "76")],
                                   bodyExpected: true, declaredBodyLength: 76)

        XCTAssertEqual(body.tabTitle, "Body (2 KB, not shown)")
        XCTAssertEqual(body.agentLines, ["body: 2048 bytes, not shown — resume without `body` to send it unchanged"])
    }

    func testSizesAreExactWhileCountable() {
        XCTAssertEqual(HeldRequestBody.size(1), "1 byte")
        XCTAssertEqual(HeldRequestBody.size(76), "76 bytes")
        XCTAssertEqual(HeldRequestBody.size(1023), "1023 bytes")
        XCTAssertEqual(HeldRequestBody.size(2048), "2 KB")
        XCTAssertEqual(HeldRequestBody.size(5 * 1024 * 1024), "5 MB")
    }

    // MARK: - What the agent reads

    /// Exactly one label line per request, whatever the state — a request
    /// printed without one read as a request with no body.
    func testTheAgentAlwaysGetsABodyLine() {
        for expected in [nil, true, false] as [Bool?] {
            for headers in [nil, [], json, [header("Content-Length", "x")], [header("Content-Length", "0")]] as [[MCPHeaderPair]?] {
                XCTAssertEqual(coreHeld(headers, expected: expected, length: nil).agentLines.count, 1,
                               "\(String(describing: expected)) \(String(describing: headers))")
            }
        }
    }

    func testAShownBodyKeepsTheLinesAnAgentAlreadyKnows() {
        let whole = HeldRequestBody(method: "POST", preview: "{}", byteCount: 2, previewIsPrefix: false, headers: json,
                                    bodyExpected: true, declaredBodyLength: 2)
        XCTAssertEqual(whole.agentLines, ["body (2 bytes):", "{}"])
        let prefix = HeldRequestBody(method: "POST", preview: "{\"a\":1", byteCount: 90_000, previewIsPrefix: true, headers: json,
                                     bodyExpected: true, declaredBodyLength: nil)
        XCTAssertEqual(prefix.agentLines, ["body (90000 bytes, TRUNCATED — do not send this back as the new body):", "{\"a\":1"])
    }

    // MARK: - A request that may not carry a body

    /// The core compares the method exactly (`head.method == .TRACE`); so
    /// does the refusal. A lowercase "trace" is another method to NIO, and
    /// the core forwards its body.
    func testOnlyATraceIsRefusedABody() {
        XCTAssertEqual(HeldRequestBody.replacementRefusal(method: "TRACE"), HeldRequestBody.traceNote)
        for method in ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD", "QUERY", "trace", "TRACE-ME"] {
            XCTAssertNil(HeldRequestBody.replacementRefusal(method: method), method)
            let held = coreHeld([header("Content-Length", "5")], expected: true, length: 5, method: method)
            XCTAssertNil(held.replacementRefusalForAgents, method)
            XCTAssertEqual(held.resumeOutcome, .unchanged, method)
        }
        XCTAssertTrue(HeldRequestBody.traceNote.contains("502"))
        let bodiless = coreHeld([header("Accept", "*/*")], expected: false, length: nil, method: "TRACE")
        XCTAssertEqual(bodiless.replacementRefusalForAgents,
                       "A TRACE request may not carry a body, so `body` is refused for one: over HTTP/1.1 ReqRes answers a TRACE with a body 502 instead of forwarding it. Resume it without `body`.")
    }

    /// A TRACE that arrives with a body of its own is not "sent unchanged":
    /// over HTTP/1.1 the core refuses to forward it (core 5efe7aa,
    /// `UpstreamRequestValidator.declaresAnUnframedBody` — any Transfer-
    /// Encoding, or a Content-Length other than 0) and answers the app 502
    /// with a failed row. The panel's note, the agent's body line and the
    /// agent's refusal say so; a TRACE with no body still resumes unchanged.
    func testATraceCarryingABodyIsNotPromisedToGoUnchanged() {
        let panel502 = "A TRACE may not carry a body: resumed over HTTP/1.1, this one is answered 502 by ReqRes instead of being forwarded. Abort answers it here."
        let agent502 = " — a TRACE may not carry a body: resumed over HTTP/1.1, this one is answered 502 by ReqRes instead of being forwarded; abort answers it here"
        let abortInstead = " This one declares a body of its own, so resumed over HTTP/1.1 it gets that 502 too: abort it to answer it here."
        struct Row {
            let line: UInt
            let held: HeldRequestBody
            let outcome: HeldRequestBody.ResumeOutcome
            let agent: String
        }
        let rows: [Row] = [
            // HTTP/1.1, Content-Length: 5 — the core reads (true, 5).
            Row(line: #line, held: coreHeld([header("Content-Length", "5")], expected: true, length: 5, method: "TRACE"),
                outcome: .answered502OverHTTP1, agent: "body: 5 bytes (Content-Length), not shown" + agent502),
            // Transfer-Encoding: chunked — only HTTP/1 sends one.
            Row(line: #line, held: coreHeld([header("Transfer-Encoding", "chunked")], expected: true, length: nil, method: "TRACE"),
                outcome: .answered502OverHTTP1,
                agent: "body: sent in chunks (Transfer-Encoding: chunked), size unknown, not shown" + agent502),
            // A Content-Length that is not one number: the validator refuses any value but 0.
            Row(line: #line, held: coreHeld([header("Content-Length", "abc")], expected: nil, length: nil, method: "TRACE"),
                outcome: .answered502OverHTTP1,
                agent: "body: size unknown (its Content-Length is not one number), not shown" + agent502),
            // The headers alone, from an extension older than the fields.
            Row(line: #line, held: headersOnly([header("Content-Length", "5")], method: "TRACE"),
                outcome: .answered502OverHTTP1, agent: "body: 5 bytes (Content-Length), not shown" + agent502),
            // A size a core reported, with nothing else said about the body:
            // the size alone is a body.
            Row(line: #line, held: HeldRequestBody(method: "TRACE", preview: nil, byteCount: 5, previewIsPrefix: false, headers: [],
                                                   bodyExpected: nil, declaredBodyLength: nil),
                outcome: .answered502OverHTTP1, agent: "body: 5 bytes, not shown" + agent502),
        ]
        for row in rows {
            XCTAssertEqual(row.held.resumeOutcome, row.outcome, line: row.line)
            XCTAssertTrue(row.held.note.hasSuffix(panel502), row.held.note, line: row.line)
            XCTAssertFalse(row.held.note.contains("Resume sends"), row.held.note, line: row.line)
            XCTAssertEqual(row.held.agentLines, [row.agent], line: row.line)
            XCTAssertTrue(row.held.replacementRefusalForAgents?.hasSuffix(abortInstead) ?? false,
                          row.held.replacementRefusalForAgents ?? "nil", line: row.line)
            let edit = HeldBodyEdit(row.held)
            XCTAssertFalse(edit.canReplace, line: row.line)
            XCTAssertEqual(edit.note, row.held.note, line: row.line)
        }

        // No body of its own: Content-Length: 0, neither header over HTTP/1.1,
        // or an HTTP/2 TRACE without content-length (never refused there).
        for bodiless in [coreHeld([header("Content-Length", "0")], expected: false, length: 0, method: "TRACE"),
                         coreHeld([header("Accept", "*/*")], expected: false, length: nil, method: "TRACE"),
                         coreHeld([header("accept", "*/*")], expected: nil, length: nil, method: "TRACE")] {
            XCTAssertEqual(bodiless.resumeOutcome, .unchanged, "\(bodiless.declared)")
            XCTAssertFalse(bodiless.note.contains("502"), bodiless.note)
            XCTAssertFalse(bodiless.agentLines.joined().contains("502"), bodiless.agentLines.joined())
            XCTAssertTrue(bodiless.replacementRefusalForAgents?.hasSuffix(" Resume it without `body`.") ?? false)
        }

        // Headers ReqRes could not read: if a body follows, the same 502.
        let unread = headersOnly(nil, method: "TRACE")
        XCTAssertEqual(unread.resumeOutcome, .answered502OverHTTP1IfItHasABody)
        XCTAssertEqual(unread.note, "ReqRes could not read this request's headers, so it cannot tell whether a body follows. "
                       + "A TRACE may not carry a body: if this one has one, resumed over HTTP/1.1 it is answered 502 by ReqRes instead of being forwarded. Abort answers it here.")
        XCTAssertEqual(unread.agentLines, ["body: not shown; the request's headers could not be read — a TRACE may not carry a body: "
                                           + "if this one has one, resumed over HTTP/1.1 it is answered 502 by ReqRes instead of being forwarded; abort answers it here"])
        XCTAssertTrue(unread.replacementRefusalForAgents?.hasSuffix(" If this one has a body of its own, resumed over HTTP/1.1 it gets that 502 too: abort it to answer it here.") ?? false)
        XCTAssertEqual(headersOnly(nil).note, "ReqRes could not read this request's headers, so it cannot tell whether a body follows. Resume sends the request unchanged.")

        // A body a core showed, whole or in part, with nothing else said
        // about it: the text alone is a body, and still the 502.
        let whole = HeldRequestBody(method: "TRACE", preview: "hello", byteCount: 0, previewIsPrefix: false, headers: [],
                                    bodyExpected: nil, declaredBodyLength: nil)
        XCTAssertEqual(whole.resumeOutcome, .answered502OverHTTP1)
        XCTAssertEqual(whole.note, "This is the request's whole body. " + panel502)
        let prefix = HeldRequestBody(method: "TRACE", preview: "he", byteCount: 0, previewIsPrefix: true, headers: [],
                                     bodyExpected: nil, declaredBodyLength: nil)
        XCTAssertEqual(prefix.resumeOutcome, .answered502OverHTTP1)
        XCTAssertEqual(prefix.note, "ReqRes shows only the first 2 bytes of this body. " + panel502)
        // The same shapes on a POST keep their own sentences.
        XCTAssertEqual(HeldRequestBody(method: "POST", preview: "hello", byteCount: 0, previewIsPrefix: false, headers: [],
                                       bodyExpected: nil, declaredBodyLength: nil).note,
                       "This is the request's whole body. Resume sends it unchanged.")
    }

    /// The panel's footer says what Resume does: sends the request on —
    /// unchanged, or with the user's edits — except a TRACE carrying a body of
    /// its own, which over HTTP/1.1 ReqRes answers 502 whatever was edited.
    func testThePanelFooterSaysWhatResumeDoes() {
        let posted = coreHeld(json + [header("Content-Length", "76")], expected: true, length: 76)
        XCTAssertEqual(posted.resumeFooter(host: "api.example.com", edited: false), "Resume sends it on to api.example.com unchanged.")
        XCTAssertEqual(posted.resumeFooter(host: "api.example.com", edited: true), "Resume sends it on to api.example.com with your changes.")

        let bodilessTrace = coreHeld([header("Accept", "*/*")], expected: false, length: nil, method: "TRACE")
        XCTAssertEqual(bodilessTrace.resumeFooter(host: "h", edited: false), "Resume sends it on to h unchanged.")

        let trace = coreHeld([header("Content-Length", "5")], expected: true, length: 5, method: "TRACE")
        for edited in [false, true] {
            XCTAssertEqual(trace.resumeFooter(host: "h", edited: edited),
                           "This TRACE carries a body, so resumed over HTTP/1.1 it is answered 502 by ReqRes instead of being sent on to h.")
        }
        XCTAssertEqual(headersOnly(nil, method: "TRACE").resumeFooter(host: "h", edited: false),
                       "If this TRACE carries a body, resumed over HTTP/1.1 it is answered 502 by ReqRes instead of being sent on to h.")
    }

    /// `HeldRequestBody(_:)` reads an agent's held request field for field —
    /// the listing and the check on answer_paused_request both build it so.
    func testAnAgentsHeldRequestIsReadFieldForField() {
        let request = MCPPausedRequest(id: "a", host: "h", method: "TRACE", url: "https://h/", path: "/",
                                       headers: [MCPHeaderPair(name: "Content-Length", value: "5")],
                                       bodyPreview: "he", bodyByteCount: 5, bodyTruncated: true,
                                       bodyExpected: true, declaredBodyLength: 5, secondsRemaining: 9)
        XCTAssertEqual(HeldRequestBody(request),
                       HeldRequestBody(method: "TRACE", preview: "he", byteCount: 5, previewIsPrefix: true,
                                       headers: [MCPHeaderPair(name: "Content-Length", value: "5")],
                                       bodyExpected: true, declaredBodyLength: 5))
        let get = MCPPausedRequest(id: "b", host: "h", method: "GET", url: "https://h/", path: "/", headers: [],
                                   bodyExpected: false, secondsRemaining: 9)
        XCTAssertEqual(HeldRequestBody(get).declared, .noBody)
        XCTAssertEqual(HeldRequestBody(get).method, "GET")
        XCTAssertEqual(HeldRequestBody(get).shown, .nothing)
    }
}

// MARK: - The replacement

final class HeldBodyEditTests: XCTestCase {
    private let posted = coreHeld(json + [header("Content-Length", "76")], expected: true, length: 76)

    /// The bug itself: the draft counted 0 == 0 as "the whole body" and the
    /// panel offered it for editing. Nothing about the body may reach the core
    /// until the user asks for a replacement.
    func testTheOriginalIsSentUntilAReplacementIsAskedFor() {
        var edit = HeldBodyEdit(posted)

        XCTAssertFalse(edit.isReplacing)
        XCTAssertNil(edit.payload)
        edit.text = "typed while nothing was open"
        XCTAssertNil(edit.payload, "text that is not a replacement never becomes one")
        XCTAssertFalse(edit.isChanged)
        XCTAssertEqual(edit.tabTitle, "Body (76 bytes, not shown)")
        XCTAssertEqual(edit.note, posted.note)
    }

    /// The replacement starts EMPTY — and an empty editor is not an empty
    /// body: it cannot be told apart from "not yet", so it sends the original.
    func testAnEmptyReplacementSendsTheOriginal() {
        var edit = HeldBodyEdit(posted)
        edit.startReplacing()

        XCTAssertTrue(edit.isReplacing)
        XCTAssertEqual(edit.text, "")
        XCTAssertNil(edit.payload)
        XCTAssertEqual(edit.note, "Type the body to send instead. Until you type something, Resume sends the original body unchanged.")

        edit.text = #"{"sku":"B-2"}"#
        XCTAssertEqual(edit.payload, #"{"sku":"B-2"}"#)
        XCTAssertTrue(edit.isChanged)
        XCTAssertEqual(edit.tabTitle, "Body (replaced)")
        XCTAssertTrue(edit.note.contains("in place of the original body, which ReqRes has not shown you"), edit.note)
        XCTAssertTrue(edit.note.contains("(13 bytes)"), edit.note)

        edit.text = ""
        XCTAssertNil(edit.payload, "clearing what was typed goes back to the original")
    }

    func testKeepingTheOriginalForgetsTheReplacement() {
        var edit = HeldBodyEdit(posted)
        edit.startReplacing()
        edit.text = "x"
        edit.keepOriginal()

        XCTAssertFalse(edit.isReplacing)
        XCTAssertNil(edit.payload)
        XCTAssertEqual(edit.text, "")

        edit.startReplacing()
        XCTAssertEqual(edit.text, "", "opening it again starts over")
    }

    /// A body the core reported whole starts the editor from itself; there,
    /// clearing it is a deliberate edit and sends an empty body.
    func testAWholeBodyIsEditedFromItself() {
        let text = #"{"sku":"A-1"}"#
        var edit = HeldBodyEdit(HeldRequestBody(method: "POST", preview: text, byteCount: text.utf8.count, previewIsPrefix: false, headers: json,
                                                bodyExpected: true, declaredBodyLength: text.utf8.count))
        edit.startReplacing()

        XCTAssertEqual(edit.text, text)
        XCTAssertNil(edit.payload, "unchanged is the original")
        XCTAssertEqual(edit.note, "Edit the body to change it. As it stands, Resume sends the original unchanged.")
        edit.text = #"{"sku":"A-2"}"#
        XCTAssertEqual(edit.payload, #"{"sku":"A-2"}"#)
        XCTAssertEqual(edit.note, "Resume sends this body (13 bytes) in place of the original. ReqRes sets its Content-Length to match.")
        edit.text = ""
        XCTAssertEqual(edit.payload, "")
    }

    func testAPrefixIsNeverTheReplacementsStart() {
        var edit = HeldBodyEdit(HeldRequestBody(method: "POST", preview: "{\"a\":1", byteCount: 90_000, previewIsPrefix: true, headers: json,
                                                bodyExpected: true, declaredBodyLength: nil))
        edit.startReplacing()

        XCTAssertEqual(edit.text, "")
        XCTAssertNil(edit.payload)
        edit.text = "{}"
        XCTAssertTrue(edit.note.contains("in place of the whole original body"), edit.note)
    }

    /// A request with no body — a declared empty one, or none following —
    /// can be given one: it goes as the request's body.
    func testTypingIntoARequestWithNoBodyGivesItOne() {
        for held in [coreHeld([header("Content-Length", "0")], expected: false, length: 0, method: "GET"),
                     coreHeld([], expected: false, length: nil, method: "GET"),
                     headersOnly([header("Content-Length", "0")], method: "GET")] {
            var edit = HeldBodyEdit(held)
            edit.startReplacing()
            edit.text = "a=1"

            XCTAssertEqual(edit.payload, "a=1")
            XCTAssertEqual(edit.note, "Resume sends what you typed (3 bytes) as the request's body. ReqRes sets its Content-Length to match.")
        }
    }

    // MARK: - The rest of the original (core 35dd624)

    /// Build 52's notes said the rest of an original still arriving "can still
    /// reach the server after yours" — true of core 5de31eb, which forwarded
    /// it behind the replacement. Core 35dd624 drains it: nothing of the
    /// original goes. A replacement over a body that may still be arriving
    /// says so; one over a body that is all there — reported whole, or none —
    /// has nothing more to say.
    func testAReplacementSaysNoneOfTheOriginalGoes() {
        var unseen = HeldBodyEdit(posted)
        unseen.startReplacing()
        unseen.text = "{}"
        XCTAssertEqual(unseen.note, "Resume sends what you typed (2 bytes) in place of the original body, which ReqRes has not shown you. "
                       + "ReqRes sets its Content-Length to match. "
                       + "With a replacement, none of the original goes to the server: what has arrived of it, and whatever the app still sends, is read and dropped.")
        XCTAssertTrue(unseen.note.hasSuffix(HeldRequestBody.originalDroppedNote))

        for held in [coreHeld([header("Transfer-Encoding", "chunked")], expected: true, length: nil),
                     coreHeld(json, expected: true, length: nil),
                     headersOnly(json)] {
            var edit = HeldBodyEdit(held)
            edit.startReplacing()
            edit.text = "{}"
            XCTAssertTrue(edit.note.hasSuffix(HeldRequestBody.originalDroppedNote), edit.note)
        }

        var prefix = HeldBodyEdit(HeldRequestBody(method: "POST", preview: "{\"a\":1", byteCount: 90_000, previewIsPrefix: true, headers: json,
                                                  bodyExpected: true, declaredBodyLength: nil))
        prefix.startReplacing()
        prefix.text = "{}"
        XCTAssertTrue(prefix.note.hasSuffix(HeldRequestBody.originalDroppedNote), prefix.note)

        let text = #"{"sku":"A-1"}"#
        var whole = HeldBodyEdit(HeldRequestBody(method: "POST", preview: text, byteCount: text.utf8.count, previewIsPrefix: false, headers: json,
                                                 bodyExpected: true, declaredBodyLength: text.utf8.count))
        whole.startReplacing()
        whole.text = "{}"
        XCTAssertFalse(whole.note.contains(HeldRequestBody.originalDroppedNote), "a body reported whole has arrived: \(whole.note)")

        var untouched = HeldBodyEdit(posted)
        untouched.startReplacing()
        XCTAssertFalse(untouched.note.contains(HeldRequestBody.originalDroppedNote), "nothing typed, nothing replaced: \(untouched.note)")
    }

    /// No note may promise the old behaviour back: the rest of an upload
    /// reaching the server after a replacement.
    func testNoNoteSaysTheRestCanStillFollow() {
        let shapes: [HeldRequestBody] = [
            posted,
            coreHeld([header("Transfer-Encoding", "chunked")], expected: true, length: nil),
            coreHeld(json, expected: true, length: nil),
            coreHeld([], expected: false, length: nil),
            headersOnly(json),
            headersOnly(nil),
            HeldRequestBody(method: "POST", preview: "{\"a\":1", byteCount: 90_000, previewIsPrefix: true, headers: json,
                            bodyExpected: true, declaredBodyLength: nil),
        ]
        for held in shapes {
            var edit = HeldBodyEdit(held)
            var notes = [edit.note]
            edit.startReplacing()
            notes.append(edit.note)
            edit.text = "replacement"
            notes.append(edit.note)
            for note in notes {
                XCTAssertFalse(note.contains("can still reach the server"), note)
                XCTAssertFalse(note.contains("after yours"), note)
                XCTAssertFalse(note.contains("The core sets Content-Length"), note)
            }
        }
        XCTAssertTrue(HeldRequestBody.originalDroppedNote.hasPrefix("With a replacement, none of the original goes to the server"))
    }

    /// The sentence about the dropped original states its own condition: Help
    /// and the agent texts print it right after "until you type something,
    /// the original goes" / "without body, the original goes on unchanged",
    /// where an unconditional "None of the original goes to the server" read
    /// as the opposite of the sentence before it (review of b280cf2).
    func testTheDroppedOriginalSentenceSaysWhenItApplies() {
        let note = HeldRequestBody.originalDroppedNote
        XCTAssertTrue(note.hasPrefix("With a replacement, "), note)
        XCTAssertFalse(note.hasPrefix("None of the original"), note)
        // The unconditional clause is nowhere in it on its own.
        XCTAssertEqual(note.components(separatedBy: "none of the original goes to the server").count - 1, 1)
        XCTAssertFalse(note.contains("None of the original"), note)
    }

    // MARK: - A TRACE (core 5efe7aa)

    /// A TRACE may not carry a body, and over HTTP/1.1 the core answers one
    /// with a body 502 instead of forwarding it — so the panel never offers
    /// one: no editor opens, and nothing typed becomes a payload.
    func testATraceIsNeverGivenABody() {
        for held in [coreHeld([], expected: false, length: nil, method: "TRACE"), headersOnly([], method: "TRACE"),
                     coreHeld(json + [header("Content-Length", "76")], expected: true, length: 76, method: "TRACE")] {
            var edit = HeldBodyEdit(held)

            XCTAssertFalse(edit.canReplace)
            XCTAssertEqual(edit.replacementRefusal, HeldRequestBody.traceNote)
            edit.startReplacing()
            XCTAssertFalse(edit.isReplacing, "Replace Body… opens nothing for a TRACE")
            edit.text = "a body"
            XCTAssertFalse(edit.isChanged)
            XCTAssertNil(edit.payload)
            XCTAssertEqual(edit.tabTitle, held.tabTitle)
            XCTAssertEqual(edit.note, held.note)
        }

        let post = HeldBodyEdit(posted)
        XCTAssertTrue(post.canReplace)
        XCTAssertNil(post.replacementRefusal)
    }
}
