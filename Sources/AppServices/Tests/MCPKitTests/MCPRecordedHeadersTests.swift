//
//  MCPRecordedHeadersTests.swift
//  AppServices
//
//  Created by OloApps on 9/28/26.
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

import XCTest
@testable import MCPKit

final class MCPRecordedHeadersTests: XCTestCase {

    /// The core's 1.1.0 shape (SessionHeaderList). The adapter this replaced
    /// read only the object shape and returned `[:]` for it.
    func testThePairArrayShapeReads() {
        let raw = #"[{"Host":"api.test"},{"Content-Type":"application/json"}]"#
        XCTAssertEqual(MCPRecordedHeaders.dictionary(from: raw),
                       ["Host": "api.test", "Content-Type": "application/json"])
    }

    /// Every session saved before 1.1.0 holds the object shape.
    func testTheOldObjectShapeStillReads() {
        let raw = #"{"Host":"api.test","Accept":"*/*"}"#
        XCTAssertEqual(MCPRecordedHeaders.dictionary(from: raw), ["Host": "api.test", "Accept": "*/*"])
    }

    /// Two Set-Cookie lines are both kept, and never comma-joined: a cookie's
    /// own Expires contains a comma.
    func testRepeatedSetCookieIsKeptOnSeparateLines() {
        let raw = #"[{"Set-Cookie":"sid=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT"},{"Content-Length":"2"},{"set-cookie":"theme=dark"}]"#
        let headers = MCPRecordedHeaders.dictionary(from: raw)
        XCTAssertEqual(headers["Set-Cookie"], "sid=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT\ntheme=dark")
        XCTAssertNil(headers["set-cookie"], "names are merged case-insensitively under the first spelling")
        XCTAssertEqual(headers["Content-Length"], "2")
    }

    func testRepeatedCookieAndOtherFieldsCombineTheHTTPWay() {
        let raw = #"[{"Cookie":"a=1"},{"Accept":"text/html"},{"Cookie":"b=2"},{"Accept":"*/*"}]"#
        XCTAssertEqual(MCPRecordedHeaders.dictionary(from: raw), ["Cookie": "a=1; b=2", "Accept": "text/html, */*"])
    }

    /// `mock_from_session` builds a rule from a captured response. A login
    /// response has several Set-Cookie; the display dictionary joins them with
    /// a newline, which rule validation refuses as header injection, so the
    /// mock failed with a 400. A rule carries one value per name.
    func testRuleHeadersFromTwoSetCookiePassRuleValidation() throws {
        let raw = #"[{"Set-Cookie":"sid=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT"},{"Content-Type":"application/json"},{"set-cookie":"theme=dark"},{"Vary":"Accept"},{"Vary":"Origin"}]"#
        let headers = MCPRecordedHeaders.ruleHeaders(from: raw)
        XCTAssertEqual(headers["Set-Cookie"], "theme=dark", "the last Set-Cookie, what the pre-1.1.0 core recorded")
        XCTAssertNil(headers["set-cookie"])
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(headers["Vary"], "Accept, Origin")
        XCTAssertFalse(headers.values.contains { $0.contains("\n") || $0.contains("\r") })
        XCTAssertNoThrow(try MCPWriteValidation.validateHeaders(headers, label: "responseHeaders"))

        // The display dictionary is what used to be copied, and it is refused.
        XCTAssertThrowsError(try MCPWriteValidation.validateHeaders(MCPRecordedHeaders.dictionary(from: raw), label: "responseHeaders"))
    }

    func testRuleHeadersWithoutSetCookieEqualTheDictionary() {
        let raw = #"[{"Cookie":"a=1"},{"Cookie":"b=2"},{"Accept":"*/*"}]"#
        XCTAssertEqual(MCPRecordedHeaders.ruleHeaders(from: raw), MCPRecordedHeaders.dictionary(from: raw))
        XCTAssertEqual(MCPRecordedHeaders.ruleHeaders(from: #"{"Set-Cookie":"only=1"}"#), ["Set-Cookie": "only=1"])
        XCTAssertEqual(MCPRecordedHeaders.ruleHeaders(from: nil), [:])
    }

    func testPairsKeepWireOrder() {
        let raw = #"[{"B":"2"},{"A":"1"},{"B":"3"}]"#
        XCTAssertEqual(MCPRecordedHeaders.pairs(from: raw).map { "\($0.name)=\($0.value)" }, ["B=2", "A=1", "B=3"])
    }

    func testUnreadableInputIsEmpty() {
        for raw: String? in [nil, "", "nope", "[1]", "3", "null"] {
            XCTAssertEqual(MCPRecordedHeaders.dictionary(from: raw), [:], "\(String(describing: raw))")
        }
    }
}
