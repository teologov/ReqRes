//
//  MCPRedactorPolicyWiringTests.swift
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
//  PRD item 11: MCPRedactionPolicy existed and was tested on its own, but
//  MCPRedactor never asked it anything, so an excepted host had zero effect
//  on the traffic an agent actually received. Every test below constructs
//  `MCPRedactor(policy:)`, an initializer argument that does not exist on
//  the previous MCPRedactor — they cannot even compile against the old
//  behaviour, let alone pass, which is the point: this file pins the WIRING,
//  not the policy's own matching rules (MCPRedactionPolicyTests owns those).
//

import XCTest
@testable import MCPKit

final class MCPRedactorPolicyWiringTests: XCTestCase {

    private func rule(host: String?, hostId: Int64 = 1) -> MCPRule {
        MCPRule(
            id: 1,
            hostId: hostId,
            host: host,
            enabled: true,
            mode: .extend,
            matchType: .wildcard,
            path: "/a",
            method: "GET",
            scheme: "https",
            requestHeaders: ["Authorization": "Bearer secret-value"],
            responseHeaders: ["Set-Cookie": "sid=abc123"]
        )
    }

    // MARK: - The default stays redact-everything

    func testPlainInitStillRedactsEveryHost() {
        // Every call site in the tree today builds `MCPRedactor()` with no
        // policy argument at all. If adding the parameter had changed what
        // that call produces, this is the test that would catch it.
        let redactor = MCPRedactor()
        let summary = makeSession(uid: "s1", host: "anything.example.com", url: "https://anything.example.com/x?token=abc123")
        XCTAssertFalse(redactor.redactSummary(summary).url.contains("abc123"))

        let redacted = redactor.redactRule(rule(host: "anything.example.com"))
        XCTAssertEqual(redacted.requestHeaders["Authorization"], MCPRedactor.placeholder)
        XCTAssertEqual(redacted.responseHeaders["Set-Cookie"], MCPRedactor.placeholder)
    }

    func testMasterSwitchOffOutranksThePolicy() {
        // `enabled: false` must still mean "never redact" even with a policy
        // attached — the exception mechanism sits ABOVE the master switch,
        // never beside it, so turning redaction off can't be undone by
        // whatever the policy would otherwise have decided.
        let redactor = MCPRedactor(enabled: false, policy: .redactAll)
        let summary = makeSession(uid: "s1", host: "example.com", url: "https://example.com/x?token=abc123")
        XCTAssertTrue(redactor.redactSummary(summary).url.contains("abc123"))
    }

    // MARK: - Excepted vs. near-miss hosts

    func testExceptedHostSessionPassesThroughUnredacted() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["staging.example.com"])
        let redactor = MCPRedactor(policy: policy)
        let summary = makeSession(uid: "s1", host: "staging.example.com", url: "https://staging.example.com/x?token=abc123")
        XCTAssertEqual(redactor.redactSummary(summary).url, summary.url)
    }

    func testNearMissHostSessionStillRedacts() {
        // "notstaging.example.com" merely CONTAINS the excepted name; the
        // policy compares whole normalized hosts, not substrings.
        let policy = MCPRedactionPolicy(exceptedHosts: ["staging.example.com"])
        let redactor = MCPRedactor(policy: policy)
        let summary = makeSession(uid: "s1", host: "notstaging.example.com", url: "https://notstaging.example.com/x?token=abc123")
        XCTAssertFalse(redactor.redactSummary(summary).url.contains("abc123"))
    }

    func testExceptedHostRulePassesThroughUnredacted() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["cdn.example.com"])
        let redactor = MCPRedactor(policy: policy)
        let redacted = redactor.redactRule(rule(host: "cdn.example.com"))
        XCTAssertEqual(redacted.requestHeaders["Authorization"], "Bearer secret-value")
        XCTAssertEqual(redacted.responseHeaders["Set-Cookie"], "sid=abc123")
    }

    func testNearMissHostRuleStillRedacts() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["cdn.example.com"])
        let redactor = MCPRedactor(policy: policy)
        let redacted = redactor.redactRule(rule(host: "other.example.com"))
        XCTAssertEqual(redacted.requestHeaders["Authorization"], MCPRedactor.placeholder)
        XCTAssertEqual(redacted.responseHeaders["Set-Cookie"], MCPRedactor.placeholder)
    }

    // MARK: - Where the host cannot be determined, redact

    func testBlankHostSessionRedactsEvenAgainstABroadException() {
        // A wildcard exception wide enough to match almost any real host
        // must still miss a session whose host is blank: "we don't know
        // whose traffic this is" is never allowed to read as a match, no
        // matter how permissive the exception list is.
        let policy = MCPRedactionPolicy(exceptedHosts: ["*.example.com", "example.com"])
        let redactor = MCPRedactor(policy: policy)
        let summary = makeSession(uid: "s1", host: "", url: "https://unknown/x?token=abc123")
        XCTAssertFalse(redactor.redactSummary(summary).url.contains("abc123"))
    }

    func testRuleWithNoHostRedactsEvenWhenAnotherHostIsExcepted() {
        // `host` is nil for a legacy rule row whose host filter is gone —
        // exactly the "cannot be determined" case, so it must redact even
        // though some OTHER, real host is on the exception list.
        let policy = MCPRedactionPolicy(exceptedHosts: ["cdn.example.com"])
        let redactor = MCPRedactor(policy: policy)
        let redacted = redactor.redactRule(rule(host: nil))
        XCTAssertEqual(redacted.requestHeaders["Authorization"], MCPRedactor.placeholder)
        XCTAssertEqual(redacted.responseHeaders["Set-Cookie"], MCPRedactor.placeholder)
    }

    // MARK: - An exception must not leak across records

    func testExceptionForOneSessionDoesNotDisableRedactionForAnotherInTheSameBatch() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["trusted.example.com"])
        let redactor = MCPRedactor(policy: policy)
        let trusted = makeSession(uid: "s1", host: "trusted.example.com", url: "https://trusted.example.com/x?token=abc123")
        let untrusted = makeSession(uid: "s2", host: "other.example.com", url: "https://other.example.com/x?token=def456")

        // One `map` over the same redactor instance — a leak would show up
        // as state bleeding from the first call into the second.
        let redacted = [trusted, untrusted].map(redactor.redactSummary)

        XCTAssertTrue(redacted[0].url.contains("abc123"), "the excepted host's own session must stay unredacted")
        XCTAssertFalse(redacted[1].url.contains("def456"), "a different host in the same batch must still be redacted")
    }

    func testExceptedDetailKeepsCurlWhileANonExceptedDetailInTheSameRunLosesIt() {
        // `redactDetail` drops `curl` as part of redacting a record; an
        // excepted host is not redacted at all, so its cURL string must
        // survive — checked against a second, non-excepted detail built and
        // redacted through the SAME redactor right after, so a shared-state
        // leak would flip either assertion.
        let policy = MCPRedactionPolicy(exceptedHosts: ["trusted.example.com"])
        let redactor = MCPRedactor(policy: policy)

        let trustedDetail = MCPSessionDetail(
            summary: makeSession(uid: "s1", host: "trusted.example.com"),
            curl: "curl https://trusted.example.com/x"
        )
        let otherDetail = MCPSessionDetail(
            summary: makeSession(uid: "s2", host: "other.example.com"),
            curl: "curl https://other.example.com/x"
        )

        XCTAssertNotNil(redactor.redactDetail(trustedDetail).curl)
        XCTAssertNil(redactor.redactDetail(otherDetail).curl)
    }
}

/// Excepting a host turns off MASKING. It must not also turn off the only
/// length bound a rule body has: nothing upstream caps one — `mock_from_session`
/// copies a whole captured response and `MCPWriteValidation` has no size limit
/// for it — so without this, excepting a host made `list_rules` and the
/// activity export able to return a response of any size at all.
final class MCPRedactorBodyCapTests: XCTestCase {
    private func rule(host: String, body: String) -> MCPRule {
        MCPRule(
            id: 1,
            hostId: 1,
            host: host,
            enabled: true,
            mode: .override,
            matchType: .wildcard,
            path: "/a",
            method: "GET",
            scheme: "https",
            responseStatus: 200,
            responseBody: body
        )
    }

    private var oversizedBody: String {
        String(repeating: "a", count: MCPLimits.bodyPreviewMaxBytes * 3)
    }

    func testAnExceptedHostIsUnmaskedButStillCapped() throws {
        let policy = try XCTUnwrap(MCPRedactionPolicy.redactAll.addingException("api.example.com"))
        let redactor = MCPRedactor(policy: policy)

        let result = redactor.redactRule(rule(host: "api.example.com", body: oversizedBody))
        let body = try XCTUnwrap(result.responseBody)

        XCTAssertLessThan(body.utf8.count, oversizedBody.utf8.count, "the cap applies to an excepted host too")
    }

    func testARedactedHostIsStillCapped() throws {
        let result = MCPRedactor().redactRule(rule(host: "api.example.com", body: oversizedBody))
        let body = try XCTUnwrap(result.responseBody)

        XCTAssertLessThan(body.utf8.count, oversizedBody.utf8.count)
    }

    /// A short body is passed through untouched — the cap must not rewrite
    /// what it does not need to.
    func testAnExceptedHostsShortBodySurvivesVerbatim() throws {
        let policy = try XCTUnwrap(MCPRedactionPolicy.redactAll.addingException("api.example.com"))
        let body = #"{"token":"secret-value"}"#

        let result = MCPRedactor(policy: policy).redactRule(rule(host: "api.example.com", body: body))

        XCTAssertEqual(result.responseBody, body)
    }
}
