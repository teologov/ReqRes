//
//  HeldRequestHeadersTests.swift
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
//  The Paused Requests panel's one reading of a held request's headers — for
//  the Headers tab, and for what the Body tab says they declare. The F19
//  review found nothing checked the second use: the panel could hand the Body
//  tab no headers at all and print "Body (not shown)" beside the request's own
//  `Content-Length: 76` with every test passing. These start from the text the
//  core sends and end at the words on the tab.
//

import XCTest
@testable import MCPKit

final class HeldRequestHeadersTests: XCTestCase {
    /// `GlueHandler.headersJSON` for the screenshot's request: a JSON POST.
    private let corePayload = #"[{"Host":"api.example.com"},{"Content-Type":"application/json"},{"Content-Length":"76"}]"#

    /// The headers alone, as an extension older than the core's body fields
    /// sent them: no preview, a count of 0, nothing about the body.
    private func panelBody(_ headers: String) -> HeldRequestBody {
        panelBody(headers, expected: nil, length: nil)
    }

    /// The headers with the core's reading of the head (35dd624+).
    private func panelBody(_ headers: String, expected: Bool?, length: Int?) -> HeldRequestBody {
        HeldRequestBody(method: "POST", preview: nil, byteCount: 0, previewIsPrefix: false,
                        decodedHeaders: HeldRequestHeaders.decode(headers), bodyExpected: expected, declaredBodyLength: length)
    }

    // MARK: - From the wire to the Body tab

    /// The panel's reading keeps the request's method: a TRACE carrying a
    /// body of its own is answered 502 over HTTP/1.1 when resumed, and its
    /// Body tab says so instead of "Resume sends it unchanged".
    func testThePanelsReadingKeepsTheMethod() {
        let trace = HeldRequestBody(method: "TRACE", preview: nil, byteCount: 0, previewIsPrefix: false,
                                    decodedHeaders: HeldRequestHeaders.decode(#"[{"Content-Length":"5"}]"#),
                                    bodyExpected: true, declaredBodyLength: 5)
        XCTAssertEqual(trace.method, "TRACE")
        XCTAssertEqual(trace.resumeOutcome, .answered502OverHTTP1)
        XCTAssertTrue(trace.note.hasSuffix(HeldRequestBody.traceAnswered502), trace.note)
        XCTAssertFalse(HeldBodyEdit(trace).canReplace)
    }

    /// The screenshot's case, end to end: the core's text for a POST with a
    /// body gives the Body tab its size from the request's own Content-Length
    /// — with the core's fields, and from the headers alone.
    func testTheCoresPayloadGivesTheBodyTabItsSize() {
        for body in [panelBody(corePayload, expected: true, length: 76), panelBody(corePayload)] {
            XCTAssertEqual(body.declared, .length(76))
            XCTAssertEqual(body.tabTitle, "Body (76 bytes, not shown)")
            XCTAssertEqual(body.agentLines, ["body: 76 bytes (Content-Length), not shown — resume without `body` to send it unchanged"])
        }
    }

    /// What the headers alone cannot tell apart, the core's fields do: an
    /// HTTP/1.1 GET (no body follows) and an HTTP/2 POST without
    /// content-length (one does), both with no framing header in the text.
    func testTheCoresFieldsTellApartWhatTheHeadersCannot() {
        let get = #"[{"Host":"api.example.com"},{"Accept":"*/*"}]"#
        let h2Post = #"[{"content-type":"application/json"},{"accept":"*/*"}]"#

        XCTAssertEqual(panelBody(get).declared, .undeclared)
        XCTAssertEqual(panelBody(h2Post).declared, .undeclared)

        XCTAssertEqual(panelBody(get, expected: false, length: nil).tabTitle, "Body (empty)")
        XCTAssertEqual(panelBody(get, expected: false, length: nil).headline, "Empty body")
        XCTAssertEqual(panelBody(h2Post, expected: true, length: nil).tabTitle, "Body (not shown)")
        XCTAssertEqual(panelBody(h2Post, expected: true, length: nil).declared, .unsized)
    }

    /// The same reading gives the Headers tab its rows — in the order the
    /// core sent them, so the two tabs describe one request.
    func testTheHeadersTabGetsTheSameHeadersInWireOrder() {
        let decoded = HeldRequestHeaders.decode(corePayload)

        XCTAssertEqual(decoded.format, .pairArray)
        XCTAssertEqual(decoded.entries.map(\.name), ["Host", "Content-Type", "Content-Length"])
        XCTAssertEqual(decoded.entries.map(\.value), ["api.example.com", "application/json", "76"])
        XCTAssertTrue(decoded.entries.allSatisfy(\.isEnabled))
        XCTAssertEqual(decoded.arrived, [
            MCPHeaderPair(name: "Host", value: "api.example.com"),
            MCPHeaderPair(name: "Content-Type", value: "application/json"),
            MCPHeaderPair(name: "Content-Length", value: "76"),
        ])
    }

    /// Text that is not JSON: the Headers tab cannot edit it, and the Body tab
    /// says the headers could not be read — not that there are none.
    func testUnreadableHeadersAreNotNoHeaders() {
        for raw in ["Content-Length: 76", "{", "123", #"["Content-Length"]"#, #"[{"a":"1"},"b"]"#] {
            let decoded = HeldRequestHeaders.decode(raw)
            XCTAssertEqual(decoded.format, .unreadable, raw)
            XCTAssertTrue(decoded.entries.isEmpty, raw)
            XCTAssertNil(decoded.arrived, raw)
            XCTAssertEqual(panelBody(raw).declared, .unknown, raw)
            XCTAssertTrue(panelBody(raw).note.contains("could not read this request's headers"), raw)
        }
    }

    /// No text is no headers, and the editor stays open for adding one.
    func testNoTextIsNoHeaders() {
        for raw in ["", "  \n"] {
            let decoded = HeldRequestHeaders.decode(raw)
            XCTAssertEqual(decoded.format, .objectMap, "an editable shape, not a locked one")
            XCTAssertEqual(decoded.arrived, [])
            XCTAssertEqual(panelBody(raw).declared, .undeclared)
        }
    }

    // MARK: - The three shapes

    /// `reqHeaders` before the 1.1.0 core: sorted without case, for a list read
    /// under a countdown.
    func testAnObjectMapIsReadInNameOrder() {
        let decoded = HeldRequestHeaders.decode(#"{"x-trace":"1","Content-Length":"12","accept":"*/*"}"#)

        XCTAssertEqual(decoded.format, .objectMap)
        XCTAssertEqual(decoded.entries.map(\.name), ["accept", "Content-Length", "x-trace"])
        XCTAssertEqual(panelBody(#"{"Content-Length":"12"}"#).tabTitle, "Body (12 bytes, not shown)")
    }

    /// The rules' shape: a switched-off row is shown, but it is not a header
    /// on the wire, so it declares nothing about the body.
    func testAnEntryArrayKeepsItsSwitchedOffRowsOutOfTheWire() {
        let raw = #"[{"key":"Content-Length","value":"76","isEnabled":false},{"key":"Transfer-Encoding","value":"chunked"}]"#
        let decoded = HeldRequestHeaders.decode(raw)

        XCTAssertEqual(decoded.format, .entryArray)
        XCTAssertEqual(decoded.entries, [
            HeldRequestHeaders.Entry(name: "Content-Length", value: "76", isEnabled: false),
            HeldRequestHeaders.Entry(name: "Transfer-Encoding", value: "chunked"),
        ])
        XCTAssertEqual(decoded.arrived, [MCPHeaderPair(name: "Transfer-Encoding", value: "chunked")])
        XCTAssertEqual(panelBody(raw).declared, .chunked(transferEncoding: "chunked"))
    }

    /// An empty array stays an array — `{}` would hand the core a shape it
    /// never sent.
    func testAnEmptyArrayStaysAPairArray() {
        let decoded = HeldRequestHeaders.decode("[]")
        XCTAssertEqual(decoded.format, .pairArray)
        XCTAssertEqual(decoded.arrived, [])
    }

    /// Numbers are read as the text they stand for; several pairs in one
    /// object (never from the core) are read in name order, so two reads agree.
    func testValuesAndCrowdedObjectsReadTheSameEveryTime() {
        let decoded = HeldRequestHeaders.decode(#"[{"Content-Length":76},{"b":"2","a":"1"}]"#)

        XCTAssertEqual(decoded.format, .pairArray)
        XCTAssertEqual(decoded.entries.map(\.name), ["Content-Length", "a", "b"])
        XCTAssertEqual(decoded.entries.first?.value, "76")
        XCTAssertEqual(panelBody(#"[{"Content-Length":76}]"#).declared, .length(76))
    }
}
