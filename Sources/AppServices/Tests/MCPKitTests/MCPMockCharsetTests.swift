//
//  MCPMockCharsetTests.swift
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
//  R2-1: mock_from_session re-sent a capture's DECODED text as UTF-8 under the
//  capture's own Content-Type, so a windows-1252 page came back as mojibake.
//  Each case follows the bytes the whole way: the capture's bytes, the row's
//  text (decoded as the core decodes them), the bytes the mock sends (that
//  text as UTF-8), and what an app reads when it takes the stored label at
//  its word.
//

import XCTest
@testable import MCPKit

final class MCPMockCharsetTests: XCTestCase {
    /// What an app reads: the bytes the core sends for a rule's text — its
    /// UTF-8 — in the charset the label names (the IANA name resolved the way
    /// the core's own reader resolves one). Nil when the label names none.
    private func read(_ text: String, labelled contentType: String) -> String? {
        guard let name = MCPMockCharset.charset(in: contentType) else { return nil }
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String(data: Data(text.utf8), encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
    }

    /// The capture's bytes as the row holds them: decoded text.
    private func row(_ bytes: Data, decodedAs encoding: String.Encoding) throws -> String {
        try XCTUnwrap(String(data: bytes, encoding: encoding))
    }

    // MARK: - A charset that is not UTF-8 is corrected

    func testLatin1() throws {
        let captured = "text/html; charset=ISO-8859-1"
        let text = try row(try XCTUnwrap("<p>café crème</p>".data(using: .isoLatin1)), decodedAs: .isoLatin1)

        XCTAssertEqual(read(text, labelled: captured), "<p>cafÃ© crÃ¨me</p>", "the defect: UTF-8 bytes under a Latin-1 label")
        let stored = MCPMockCharset.contentType(captured)
        XCTAssertEqual(stored, "text/html; charset=utf-8")
        XCTAssertEqual(read(text, labelled: stored), text)
    }

    func testWindows1252KeepsTheValueAsWritten() throws {
        let captured = "text/plain;charset=windows-1252"
        let text = try row(try XCTUnwrap("“Quoted” — 5 €".data(using: .windowsCP1252)), decodedAs: .windowsCP1252)

        XCTAssertNotEqual(read(text, labelled: captured), text)
        let stored = MCPMockCharset.contentType(captured)
        XCTAssertEqual(stored, "text/plain;charset=utf-8", "only the charset's value changes; the spacing stays as written")
        XCTAssertEqual(read(text, labelled: stored), text)
    }

    /// A byte-order mark names UTF-16 in the capture, and Foundation drops it
    /// while decoding — so neither the text nor the bytes the mock sends say
    /// UTF-16 any more. Only the label can say what they are.
    func testUTF16WithAByteOrderMark() throws {
        let captured = "text/plain; charset=UTF-16"
        let bytes = Data([0xFF, 0xFE]) + (try XCTUnwrap("héllo wörld".data(using: .utf16LittleEndian)))
        let text = try row(bytes, decodedAs: .utf16)
        XCTAssertEqual(text, "héllo wörld")
        XCTAssertFalse(text.unicodeScalars.contains("\u{FEFF}"), "the mark did not survive decoding")

        XCTAssertNotEqual(read(text, labelled: captured), text)
        let stored = MCPMockCharset.contentType(captured)
        XCTAssertEqual(stored, "text/plain; charset=utf-8")
        XCTAssertEqual(read(text, labelled: stored), text)
    }

    func testUTF16WithoutAByteOrderMarkQuoted() throws {
        let captured = #"application/xml; charset="utf-16le""#
        let text = try row(try XCTUnwrap(#"<a b="ü"/>"#.data(using: .utf16LittleEndian)), decodedAs: .utf16LittleEndian)

        XCTAssertNotEqual(read(text, labelled: captured), text)
        let stored = MCPMockCharset.contentType(captured)
        XCTAssertEqual(stored, "application/xml; charset=utf-8")
        XCTAssertEqual(read(text, labelled: stored), text)
    }

    /// A charset on a type ReqRes judges by its bytes still names the bytes
    /// once it is there, so it is made true too.
    func testACharsetOnAnyTypeIsMadeTrue() {
        XCTAssertEqual(MCPMockCharset.contentType("application/octet-stream; charset=iso-8859-1"),
                       "application/octet-stream; charset=utf-8")
        XCTAssertEqual(MCPMockCharset.contentType("text/html; Charset=x-unknown-name"), "text/html; Charset=utf-8")
    }

    // MARK: - No charset

    /// Unlabelled HTML, XML and scripts are read in something other than
    /// UTF-8 unless the bytes say otherwise — and a mark that said so did not
    /// survive the row (a UTF-8 one is dropped as well).
    func testNoCharsetOnTextXMLOrScriptSaysUTF8() throws {
        let text = try row(Data([0xEF, 0xBB, 0xBF]) + Data("naïve".utf8), decodedAs: .utf8)
        XCTAssertEqual(text, "naïve", "Foundation drops a UTF-8 mark too")

        XCTAssertEqual(MCPMockCharset.contentType("text/html"), "text/html; charset=utf-8")
        XCTAssertEqual(read(text, labelled: MCPMockCharset.contentType("text/html")), text)
        XCTAssertEqual(MCPMockCharset.contentType("TEXT/CSS"), "TEXT/CSS; charset=utf-8")
        XCTAssertEqual(MCPMockCharset.contentType("application/javascript"), "application/javascript; charset=utf-8")
        XCTAssertEqual(MCPMockCharset.contentType("application/xml"), "application/xml; charset=utf-8")
        XCTAssertEqual(MCPMockCharset.contentType("image/svg+xml"), "image/svg+xml; charset=utf-8")
        XCTAssertEqual(MCPMockCharset.contentType("text/html; "), "text/html; charset=utf-8", "no empty parameter left behind")
        XCTAssertEqual(MCPMockCharset.contentType("text/html;"), "text/html; charset=utf-8")
    }

    /// JSON is UTF-8 by definition, and a type judged by its bytes was UTF-8
    /// already when the row holds it as text: nothing to say.
    func testNoCharsetOnJSONOrAByteJudgedTypeIsLeftAlone() {
        for value in ["application/json", "application/problem+json", "application/octet-stream",
                      "application/x-www-form-urlencoded", "image/png", "", "nonsense"] {
            XCTAssertEqual(MCPMockCharset.contentType(value), value)
        }
    }

    // MARK: - A UTF-8 label is left exactly as it is

    func testAJSONWithCharsetUTF8IsUnchanged() {
        for value in ["application/json; charset=utf-8", #"application/json;charset="UTF-8""#,
                      "text/html; charset=utf8"] {
            XCTAssertEqual(MCPMockCharset.contentType(value), value)
        }
        // Not a spelling readers know: corrected rather than trusted.
        XCTAssertEqual(MCPMockCharset.contentType("text/plain; charset=UTF_8"), "text/plain; charset=utf-8")
    }

    // MARK: - The rest of the value

    func testOtherParametersAreKeptInPlace() {
        XCTAssertEqual(MCPMockCharset.contentType("text/plain; format=flowed; charset=iso-8859-1; delsp=yes"),
                       "text/plain; format=flowed; charset=utf-8; delsp=yes")
        // A `;` inside a quoted value is not a parameter boundary.
        XCTAssertEqual(MCPMockCharset.contentType(#"text/plain; title="a;charset=b"; charset=latin1"#),
                       #"text/plain; title="a;charset=b"; charset=utf-8"#)
        XCTAssertEqual(MCPMockCharset.charset(in: #"text/plain; title="a;charset=b"; charset=latin1"#), "latin1")
    }

    // MARK: - Which copied headers

    private let copied = [
        "content-type": "text/html; charset=windows-1252",
        "Cache-Control": "no-store",
        "Set-Cookie": "a=1",
    ]

    /// The row's text, or the agent's: either is sent as UTF-8. The header
    /// keeps its own name (HTTP/2 writes it lowercase) and nothing else moves.
    func testATextBodyRelabelsTheCopiedContentTypeOnly() {
        for (agentBody, capturedText) in [(nil, "<p>café</p>"), ("{\"ok\":true}", "<p>café</p>"), ("x", "")] as [(String?, String)] {
            let headers = MCPMockCharset.headers(copied, agentBody: agentBody, capturedText: capturedText)
            XCTAssertEqual(headers["content-type"], "text/html; charset=utf-8", "\(String(describing: agentBody))")
            XCTAssertEqual(headers["Cache-Control"], "no-store")
            XCTAssertEqual(headers["Set-Cookie"], "a=1")
            XCTAssertEqual(headers.count, copied.count)
        }
    }

    /// Nothing of the body is sent as text: a binary capture is replayed from
    /// its own bytes, and an Override with an empty body forwards the
    /// server's own response under these headers. The capture's label still
    /// describes those bytes.
    func testNoTextBodyKeepsTheCapturesLabel() {
        XCTAssertEqual(MCPMockCharset.headers(copied, agentBody: nil, capturedText: ""), copied)
        XCTAssertEqual(MCPMockCharset.headers(copied, agentBody: "", capturedText: "<p>café</p>"), copied)
    }

    func testNoContentTypeIsNotInvented() {
        let headers = ["X-Trace": "1"]
        XCTAssertEqual(MCPMockCharset.headers(headers, agentBody: nil, capturedText: "hello"), headers)
    }
}
