//
//  MCPBridgeRouterAuditSnapshotTests.swift
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
//  The audit snapshot is only worth anything if the ROUTER records it. The
//  model's own tests prove it round-trips; these prove it is actually captured
//  on the paths that change or destroy something, with the values an undo
//  would need rather than the redacted ones an agent sees.
//

import XCTest
@testable import MCPKit

final class MCPBridgeRouterAuditSnapshotTests: XCTestCase {
    private let token = "test-token"
    private var rules: StubRuleProvider!
    private var hosts: StubHostProvider!
    private var capture: StubCaptureController!
    private var consent: StubConsent!
    private var audit: StubAudit!

    override func setUp() {
        super.setUp()
        rules = StubRuleProvider()
        hosts = StubHostProvider()
        capture = StubCaptureController()
        consent = StubConsent()
        audit = StubAudit()
    }

    private func makeRouter() -> MCPBridgeRouter {
        MCPBridgeRouter(
            token: token,
            sessions: StubSessionProvider(),
            status: StubStatusProvider(),
            writes: MCPWriteSeams(rules: rules, hosts: hosts, capture: capture, consent: consent, audit: audit)
        )
    }

    private func send(_ router: MCPBridgeRouter, _ method: String, _ target: String, body: Data? = nil) throws -> ParsedResponse {
        var request = makeRequest(method: method, target: target, token: token)
        if let body {
            request.body = body
            request.headers["content-type"] = "application/json"
        }
        return try XCTUnwrap(parseRawResponse(router.respond(to: request)))
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func existingRule(id: Int64 = 3, enabled: Bool = true) -> MCPRule {
        MCPRule(
            id: id,
            hostId: 7,
            host: "api.example.com",
            enabled: enabled,
            mode: .override,
            matchType: .wildcard,
            path: "/v1/users?*",
            method: "GET",
            scheme: "https",
            responseStatus: 200,
            responseHeaders: ["Set-Cookie": "session=abcdef123456"],
            responseBody: #"{"token":"secret-value"}"#
        )
    }

    /// Would have caught the original state of this code, where the log
    /// recorded only the result ("rule #3") and there was nothing to put back.
    func testUpdatingARuleRecordsWhatItLookedLikeBefore() throws {
        rules.stored = [existingRule(enabled: true)]
        let router = makeRouter()

        _ = try send(router, "PATCH", "/v1/rules/3", body: json(["enabled": false]))

        let entry = try XCTUnwrap(audit.entries.last)
        XCTAssertEqual(entry.outcome, .performed)
        guard case .rule(let snapshot)? = entry.previousState else {
            return XCTFail("an update must record the rule it replaced")
        }
        XCTAssertTrue(snapshot.enabled, "the snapshot is the state BEFORE the patch")
        XCTAssertTrue(entry.isReversible)
    }

    func testDeletingARuleRecordsTheWholeRule() throws {
        rules.stored = [existingRule()]
        let router = makeRouter()

        _ = try send(router, "DELETE", "/v1/rules/3")

        let entry = try XCTUnwrap(audit.entries.last)
        guard case .rule(let snapshot)? = entry.previousState else {
            return XCTFail("a delete must record the rule it removed")
        }
        XCTAssertEqual(snapshot.id, 3)
        XCTAssertEqual(snapshot.path, "/v1/users?*")
        XCTAssertTrue(entry.isReversible)
    }

    func testRemovingAHostRecordsIt() throws {
        hosts.stored = [MCPHost(id: 1, host: "api.example.com", scheme: "https", port: 443)]
        let router = makeRouter()

        _ = try send(router, "DELETE", "/v1/hosts/1")

        let entry = try XCTUnwrap(audit.entries.last)
        guard case .host(let snapshot)? = entry.previousState else {
            return XCTFail("removing a host must record it")
        }
        XCTAssertEqual(snapshot.host, "api.example.com")
    }

    /// The snapshot has to hold the rule's REAL values. The copy that goes back
    /// to the agent is redacted, and restoring a redacted rule would write the
    /// placeholder into live traffic as if it were a real header.
    func testTheSnapshotKeepsRealValuesNotTheRedactedOnesSentToTheAgent() throws {
        rules.stored = [existingRule()]
        let router = makeRouter()

        let response = try send(router, "DELETE", "/v1/rules/3")
        XCTAssertEqual(response.status, 200)

        let entry = try XCTUnwrap(audit.entries.last)
        guard case .rule(let snapshot)? = entry.previousState else {
            return XCTFail("expected a rule snapshot")
        }
        XCTAssertEqual(snapshot.responseHeaders["Set-Cookie"], "session=abcdef123456")
        XCTAssertEqual(snapshot.responseBody, #"{"token":"secret-value"}"#)
    }

    /// A refusal changed nothing, so recording a "previous" state would invite
    /// an undo that restores something the user never lost.
    func testADeniedWriteRecordsNoSnapshot() throws {
        rules.stored = [existingRule()]
        consent.decision = .denied(reason: "not now")
        let router = makeRouter()

        _ = try send(router, "DELETE", "/v1/rules/3")

        let entry = try XCTUnwrap(audit.entries.last)
        XCTAssertEqual(entry.outcome, .denied)
        XCTAssertNil(entry.previousState)
        XCTAssertFalse(entry.isReversible)
    }

    /// Creations have nothing to snapshot: they are reversed by deleting what
    /// they made, using the id the outcome already records.
    func testCreatingARuleRecordsNoSnapshotButIsStillReversible() throws {
        hosts.stored = [MCPHost(id: 7, host: "api.example.com", scheme: "https", port: 443)]
        let router = makeRouter()

        let created = try send(router, "POST", "/v1/rules", body: json([
            "hostId": 7,
            "mode": "override",
            "matchType": "wildcard",
            "path": "/v1/users?*",
            "responseStatus": 500,
        ]))
        XCTAssertEqual(created.status, 201)

        let entry = try XCTUnwrap(audit.entries.last)
        XCTAssertNil(entry.previousState)
        XCTAssertTrue(entry.isReversible, "reversed by deleting the rule it created")
    }
}

/// Undoing a creation means deleting the row it made, so the log has to know
/// which row that is. It used to say only "rule #12" in a prose `detail`
/// field, and reading an id back out of a sentence is how a log message
/// becomes an API by accident.
final class MCPBridgeRouterCreatedTargetTests: XCTestCase {
    private let token = "test-token"
    private var rules: StubRuleProvider!
    private var hosts: StubHostProvider!
    private var audit: StubAudit!
    private var consent: StubConsent!

    override func setUp() {
        super.setUp()
        rules = StubRuleProvider()
        hosts = StubHostProvider()
        audit = StubAudit()
        consent = StubConsent()
    }

    private func makeRouter() -> MCPBridgeRouter {
        MCPBridgeRouter(
            token: token,
            sessions: StubSessionProvider(),
            status: StubStatusProvider(),
            writes: MCPWriteSeams(
                rules: rules,
                hosts: hosts,
                capture: StubCaptureController(),
                consent: consent,
                audit: audit
            )
        )
    }

    private func post(_ router: MCPBridgeRouter, _ target: String, _ object: [String: Any]) throws -> ParsedResponse {
        var request = makeRequest(method: "POST", target: target, token: token)
        request.body = try JSONSerialization.data(withJSONObject: object)
        request.headers["content-type"] = "application/json"
        return try XCTUnwrap(parseRawResponse(router.respond(to: request)))
    }

    func testCreatingARuleRecordsTheRowItMade() throws {
        hosts.stored = [MCPHost(id: 7, host: "api.example.com", scheme: "https", port: 443)]
        let router = makeRouter()

        let response = try post(router, "/v1/rules", [
            "hostId": 7, "mode": "override", "matchType": "wildcard", "path": "/v1/users?*", "responseStatus": 500,
        ])
        XCTAssertEqual(response.status, 201)

        let created = try JSONDecoder().decode(MCPRule.self, from: response.body)
        let entry = try XCTUnwrap(audit.entries.last)
        XCTAssertEqual(entry.created, .rule(created.id), "the log must name the rule the agent just made")
        XCTAssertTrue(entry.isReversible)
        XCTAssertEqual(MCPUndo.plan(for: entry), .deleteRule(id: created.id))
    }

    func testAddingAHostRecordsTheRowItMade() throws {
        let router = makeRouter()

        let response = try post(router, "/v1/hosts", ["host": "api.example.com"])
        XCTAssertEqual(response.status, 201)

        let created = try JSONDecoder().decode(MCPHost.self, from: response.body)
        XCTAssertEqual(audit.entries.last?.created, .host(created.id))
    }

    /// A refusal made nothing, so there is nothing to point at.
    func testADeniedCreationRecordsNothingCreated() throws {
        hosts.stored = [MCPHost(id: 7, host: "api.example.com", scheme: "https", port: 443)]
        consent.decision = .denied(reason: "no")
        let router = makeRouter()

        _ = try post(router, "/v1/rules", [
            "hostId": 7, "mode": "override", "matchType": "wildcard", "path": "/v1/users?*", "responseStatus": 500,
        ])

        let entry = try XCTUnwrap(audit.entries.last)
        XCTAssertNil(entry.created)
        XCTAssertNil(MCPUndo.plan(for: entry))
    }
}
