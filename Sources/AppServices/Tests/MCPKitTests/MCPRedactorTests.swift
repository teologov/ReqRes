//
//  MCPRedactorTests.swift
//  AppServices
//
//  Created by OloApps on 8/26/26.
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

final class MCPRedactorTests: XCTestCase {
    let redactor = MCPRedactor()

    func testSensitiveHeadersAreRedactedCaseInsensitively() {
        let headers = [
            "Authorization": "Bearer secret-token-value",
            "COOKIE": "session=abc123",
            "X-Api-Key": "k-123",
            "Content-Type": "application/json",
        ]
        let redacted = redactor.redactHeaders(headers)
        XCTAssertEqual(redacted["Authorization"], MCPRedactor.placeholder)
        XCTAssertEqual(redacted["COOKIE"], MCPRedactor.placeholder)
        XCTAssertEqual(redacted["X-Api-Key"], MCPRedactor.placeholder)
        XCTAssertEqual(redacted["Content-Type"], "application/json")
    }

    func testJWTShapedValuesAreRedactedInNonSensitiveHeaders() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let redacted = redactor.redactHeaders(["X-Debug-Info": "token=\(jwt)"])
        XCTAssertEqual(redacted["X-Debug-Info"], "token=\(MCPRedactor.placeholder)")
    }

    func testSensitiveQueryParametersAreRedacted() {
        let url = "https://api.example.com/v1/items?limit=10&access_token=abc123&sig=xyz"
        let redacted = redactor.redactURL(url)
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("xyz"))
        XCTAssertTrue(redacted.contains("limit=10"))
    }

    func testBodyPreviewRedactsSensitiveJSONKeys() {
        let body = #"{"user":"alice","password":"hunter2","nested":{"api_key": "k-999"}}"#
        let redacted = redactor.redactBodyPreview(body)
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains("k-999"))
        XCTAssertTrue(redacted.contains("alice"))
    }

    func testDisabledRedactorPassesThrough() {
        let off = MCPRedactor(enabled: false)
        let headers = ["Authorization": "Bearer secret"]
        XCTAssertEqual(off.redactHeaders(headers), headers)
        let url = "https://x.example/?token=abc"
        XCTAssertEqual(off.redactURL(url), url)
    }

    func testDetailRedactionDropsCurlAndCoversBothSides() {
        let detail = MCPSessionDetail(
            summary: makeSession(uid: "s1", url: "https://api.example.com/login?token=tok123"),
            requestHeaders: ["Authorization": "Bearer abc"],
            responseHeaders: ["Set-Cookie": "sid=1"],
            requestBodyPreview: #"{"password":"pw"}"#,
            responseBodyPreview: #"{"token":"tk"}"#,
            curl: "curl -H 'Authorization: Bearer abc' https://api.example.com/login?token=tok123"
        )
        let redacted = redactor.redactDetail(detail)
        XCTAssertNil(redacted.curl)
        XCTAssertEqual(redacted.requestHeaders["Authorization"], MCPRedactor.placeholder)
        XCTAssertEqual(redacted.responseHeaders["Set-Cookie"], MCPRedactor.placeholder)
        XCTAssertFalse(redacted.summary.url.contains("tok123"))
        XCTAssertFalse(redacted.requestBodyPreview?.contains("pw") ?? true)
        XCTAssertFalse(redacted.responseBodyPreview?.contains("tk") ?? true)
    }

    /// A country token and a server address are not captured credentials
    /// (destination-map UX spec §8.1): both pass through, on a summary and
    /// on a detail, while everything beside them is still redacted.
    func testCountryAndServerAddressPassThroughRedaction() {
        let summary = makeSession(uid: "s1", url: "https://api.example.com/login?token=tok123", country: "DE")
        let redactedSummary = redactor.redactSummary(summary)
        XCTAssertEqual(redactedSummary.country, "DE")
        XCTAssertFalse(redactedSummary.url.contains("tok123"), "everything else is still redacted")

        let detail = MCPSessionDetail(
            summary: summary,
            requestHeaders: ["Authorization": "Bearer abc"],
            serverAddress: "104.18.32.7"
        )
        let redactedDetail = redactor.redactDetail(detail)
        XCTAssertEqual(redactedDetail.serverAddress, "104.18.32.7")
        XCTAssertEqual(redactedDetail.summary.country, "DE")
        XCTAssertEqual(redactedDetail.requestHeaders["Authorization"], MCPRedactor.placeholder)
    }
}
