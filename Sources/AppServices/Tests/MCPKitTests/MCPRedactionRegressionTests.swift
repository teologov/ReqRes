//
//  MCPRedactionRegressionTests.swift
//  AppServices
//
//  Regression tests for defects found by the 2026-08-26 adversarial review of
//  the bridge. Each test here failed against the previous regex-based redactor.
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

final class MCPRedactionRegressionTests: XCTestCase {
    let redactor = MCPRedactor()

    /// Asserts none of the secrets survive anywhere in the output.
    private func assertHidden(_ output: String, _ secrets: [String], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        for secret in secrets {
            XCTAssertFalse(output.contains(secret), "leaked \"\(secret)\" \(message)\noutput: \(output)", file: file, line: line)
        }
    }

    // MARK: - Form-urlencoded bodies (the biggest hole)

    func testOAuthTokenRefreshFormBodyIsRedacted() {
        let body = "grant_type=refresh_token&client_id=abc&client_secret=s3cr3t-CLIENT&refresh_token=1//0eXYZrefreshTOKEN"
        let output = redactor.redactBody(body)
        assertHidden(output, ["s3cr3t-CLIENT", "1//0eXYZrefreshTOKEN"], "in an OAuth refresh body")
        // Non-sensitive fields stay readable so the request is still debuggable.
        XCTAssertTrue(output.contains("grant_type=refresh_token"))
        XCTAssertTrue(output.contains("client_id=abc"))
    }

    func testLoginFormBodyIsRedacted() {
        let output = redactor.redactBody("username=alice@corp.com&password=Hunter2!&csrf=xyz")
        assertHidden(output, ["Hunter2!"], "in a login form post")
        XCTAssertTrue(output.contains("username=alice@corp.com"))
    }

    func testFormBodyIsDetectedFromContentTypeEvenWhenAmbiguous() {
        let output = redactor.redactBody("token=abc123", contentType: "application/x-www-form-urlencoded; charset=utf-8")
        assertHidden(output, ["abc123"])
    }

    // MARK: - JSON structure, not text

    func testNonStringJSONValuesAreRedacted() {
        let output = redactor.redactBody(#"{"password":12345,"pin":9999}"#)
        assertHidden(output, ["12345", "9999"], "as non-string JSON values")
    }

    func testDeeplyNestedSecretsAreRedacted() {
        let body = #"{"a":{"b":{"c":{"client_secret":"DEEPSECRET"}}}}"#
        assertHidden(redactor.redactBody(body), ["DEEPSECRET"], "at nesting depth 4")
    }

    func testSecretsInsideArraysAreRedacted() {
        let body = #"{"users":[{"name":"a","api_key":"KEY-ONE"},{"name":"b","api_key":"KEY-TWO"}]}"#
        assertHidden(redactor.redactBody(body), ["KEY-ONE", "KEY-TWO"], "inside an array of objects")
    }

    func testEscapedQuoteInValueDoesNotLeakTheTail() {
        // The old regex stopped at the escaped quote and emitted the remainder.
        let body = #"{"password":"pw\"with\"quotes-TAIL"}"#
        assertHidden(redactor.redactBody(body), ["TAIL"], "after an escaped quote")
    }

    func testRedactedJSONRemainsValidJSON() throws {
        let output = redactor.redactBody(#"{"user":"alice","token":"abc","n":[1,2,3]}"#)
        let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        XCTAssertNotNil(parsed, "redacted output must still parse as JSON")
        XCTAssertEqual(parsed?["token"] as? String, MCPRedactor.placeholder)
        XCTAssertEqual(parsed?["user"] as? String, "alice")
    }

    // MARK: - Name matching

    func testVendorPrefixedHeaderNamesAreRecognised() {
        let headers = [
            "X-Refresh-Token-V2": "rt-SECRET",
            "X_Session_Id": "sess-SECRET",
            "My-Client-Secret": "cs-SECRET",
            "Accept": "application/json",
        ]
        let output = redactor.redactHeaders(headers)
        XCTAssertEqual(output["X-Refresh-Token-V2"], MCPRedactor.placeholder)
        XCTAssertEqual(output["X_Session_Id"], MCPRedactor.placeholder)
        XCTAssertEqual(output["My-Client-Secret"], MCPRedactor.placeholder)
        XCTAssertEqual(output["Accept"], "application/json")
    }

    func testBenignNamesAreNotOverRedacted() {
        XCTAssertFalse(MCPRedactor.isSensitiveName("Idempotency-Key"))
        XCTAssertFalse(MCPRedactor.isSensitiveName("Content-Type"))
        XCTAssertTrue(MCPRedactor.isSensitiveName("X-Api-Key"))
    }

    /// 2026-09-29 live run: httpbin's `Access-Control-Allow-Credentials: true`
    /// reached the agent as «redacted» — the name holds "credential", the value
    /// is a CORS flag an agent debugging CORS needs to read.
    func testTheCORSCredentialsFlagIsNotRedacted() {
        XCTAssertFalse(MCPRedactor.isSensitiveName("Access-Control-Allow-Credentials"))
        let output = MCPRedactor().redactHeaders(["Access-Control-Allow-Credentials": "true",
                                                  "X-Credential-Token": "abc123def456"])
        XCTAssertEqual(output["Access-Control-Allow-Credentials"], "true")
        XCTAssertEqual(output["X-Credential-Token"], MCPRedactor.placeholder, "a real credential header is still masked")
    }

    // MARK: - URLs

    func testUserinfoCredentialsAreStripped() {
        let output = redactor.redactURL("https://alice:Hunter2@api.example.com/v1/thing")
        assertHidden(output, ["Hunter2"], "in URL userinfo")
    }

    func testNonSensitiveQueryEncodingIsPreserved() {
        let url = "https://api.example.com/search?q=a%20b%26c&token=SECRET"
        let output = redactor.redactURL(url)
        assertHidden(output, ["SECRET"])
        // The agent must see the URL as actually sent, not a re-encoded variant.
        XCTAssertTrue(output.contains("q=a%20b%26c"), "percent-encoding was rewritten: \(output)")
    }

    // MARK: - Unknown formats fail closed

    func testUnparseableBodyRedactsVendorPrefixedSecrets() {
        let output = redactor.redactBody("<credentials><api>sk_live_" + "abcdef123456789</api></credentials>")
        assertHidden(output, ["sk_live_" + "abcdef123456789"], "in an XML body")
    }

    func testUnparseableBodyRedactsHighEntropyBlobs() {
        let secret = "AbCd3fGh1jKlMn0pQrSt2vWxYz789"
        let output = redactor.redactBody("<t>\(secret)</t>")
        assertHidden(output, [secret], "as a high-entropy run in an unknown format")
    }

    func testShortSecretInXMLElementIsRedactedByName() {
        // Too short for entropy detection — must be caught structurally.
        let output = redactor.redactBody("<credentials><user>alice</user><password>Hunter2</password></credentials>")
        assertHidden(output, ["Hunter2"], "in an XML element named password")
        XCTAssertTrue(output.contains("alice"), "non-sensitive elements must survive")
    }

    func testSensitiveXMLAttributeIsRedacted() {
        let output = redactor.redactBody("<auth apiKey=\"abc123\" mode=\"basic\"/>")
        assertHidden(output, ["abc123"], "in a sensitive XML attribute")
        XCTAssertTrue(output.contains("basic"))
    }

    func testOrdinaryProseIsNotMangled() {
        let prose = "the quick brown fox jumps over the lazy dog repeatedly and often"
        XCTAssertEqual(redactor.redactBody("<p>\(prose)</p>"), "<p>\(prose)</p>")
    }

    // MARK: - Ordering: redact before cap

    func testSecretStraddlingTheCapIsStillRedacted() {
        // Push a secret to sit exactly across the preview boundary.
        let filler = String(repeating: "x", count: MCPLimits.bodyPreviewMaxBytes - 20)
        let body = #"{"filler":"\#(filler)","password":"SUPERSECRET"}"#

        let detail = MCPSessionDetail(
            summary: makeSession(uid: "s1"),
            responseBodyPreview: body
        )
        let sessions = StubSessionProvider(summaries: [makeSession(uid: "s1")], details: ["s1": detail])
        let router = MCPBridgeRouter(token: "tok", sessions: sessions, status: StubStatusProvider())

        let response = router.respond(to: makeRequest(target: "/v1/sessions/s1", token: "tok"))
        let text = String(data: parseRawResponse(response)?.body ?? Data(), encoding: .utf8) ?? ""
        assertHidden(text, ["SUPERSECRET"], "when straddling the preview cap")
    }
}
