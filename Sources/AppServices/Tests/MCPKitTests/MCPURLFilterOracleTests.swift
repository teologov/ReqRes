//
//  MCPURLFilterOracleTests.swift
//  AppServices
//
//  Created by OloApps on 9/29/26.
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

/// `url_contains` must not be an oracle for what redaction hides: a filter
/// for a masked value's prefix matches nothing (release review, 2026-09-29).
final class MCPURLFilterOracleTests: XCTestCase {
    let token = "test-token-abc"
    let secretURL = "https://api.example.com/v1/me?access_token=abc123secret&page=2"

    private func sessions() -> StubSessionProvider {
        StubSessionProvider(summaries: [makeSession(uid: "s1", url: secretURL)])
    }

    private func totalMatched(_ query: String, redactor: MCPRedactor = MCPRedactor()) throws -> Int {
        let router = MCPBridgeRouter(token: token, sessions: sessions(), status: StubStatusProvider(), redactor: redactor)
        let response = router.respond(to: makeRequest(target: "/v1/sessions?url_contains=\(query)", token: token))
        let parsed = try XCTUnwrap(parseRawResponse(response))
        XCTAssertEqual(parsed.status, 200)
        return try XCTUnwrap(parsed.json?["totalMatched"] as? Int)
    }

    func testAPrefixOfAMaskedQueryValueMatchesNothing() throws {
        XCTAssertEqual(try totalMatched("access_token%3Da"), 0)
        XCTAssertEqual(try totalMatched("access_token%3Dabc1"), 0)
        XCTAssertEqual(try totalMatched("abc123"), 0)
    }

    func testWhatTheAgentCanSeeStillMatches() throws {
        XCTAssertEqual(try totalMatched("access_token"), 1)
        XCTAssertEqual(try totalMatched("page%3D2"), 1)
        XCTAssertEqual(try totalMatched("%2Fv1%2Fme"), 1)
    }

    func testAnExceptedHostIsMatchedOnItsRealURL() throws {
        let redactor = MCPRedactor(policy: MCPRedactionPolicy(exceptedHosts: ["api.example.com"]))
        XCTAssertEqual(try totalMatched("abc123", redactor: redactor), 1)
    }

    func testTheDestinationsReportIsFilteredTheSameWay() {
        let filter = MCPSessionFilter(urlContains: "access_token=abc")
        let summaries = [makeSession(uid: "s1", url: secretURL)]
        XCTAssertEqual(MCPDestinationAggregation.report(summaries: summaries, filter: filter, redactor: MCPRedactor()).totalRequests, 0)
    }
}
