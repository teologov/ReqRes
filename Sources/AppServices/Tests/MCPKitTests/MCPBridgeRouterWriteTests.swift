//
//  MCPBridgeRouterWriteTests.swift
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

import XCTest
@testable import MCPKit

final class MCPBridgeRouterWriteTests: XCTestCase {
    let token = "write-token"

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

    private func makeRouter(writes: Bool = true, session: MCPSessionSummary? = nil) -> MCPBridgeRouter {
        let sessions = StubSessionProvider()
        if let session {
            sessions.summaries = [session]
            sessions.details = [session.uid: MCPSessionDetail(summary: session)]
        }
        return MCPBridgeRouter(
            token: token,
            sessions: sessions,
            status: StubStatusProvider(),
            writes: writes ? MCPWriteSeams(rules: rules, hosts: hosts, capture: capture, consent: consent, audit: audit) : nil
        )
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func send(_ router: MCPBridgeRouter, _ method: String, _ target: String, body: Data? = nil, token: String? = nil) throws -> ParsedResponse {
        var request = makeRequest(method: method, target: target, token: token ?? self.token)
        if let body {
            request.body = body
            request.headers["content-type"] = "application/json"
        }
        return try XCTUnwrap(parseRawResponse(router.respond(to: request)))
    }

    // MARK: - Wiring

    func testWithoutWriteSeamsEveryWriteIs503AndReadsStillWork() throws {
        let router = makeRouter(writes: false)
        let rulesResponse = try send(router, "GET", "/v1/rules")
        XCTAssertEqual(rulesResponse.status, 503)
        let create = try send(router, "POST", "/v1/rules", body: json(["hostId": 7, "mode": "override", "path": "/x"]))
        XCTAssertEqual(create.status, 503)
        XCTAssertEqual(try send(router, "GET", "/v1/status").status, 200)
    }

    func testWritesRequireTheToken() throws {
        let router = makeRouter()
        XCTAssertEqual(try send(router, "POST", "/v1/rules", body: json(["hostId": 7, "mode": "override", "path": "/x"]), token: "wrong").status, 401)
        XCTAssertTrue(audit.entries.isEmpty, "an unauthenticated call never reaches consent or the log")
    }

    // MARK: - Consent and audit

    func testDeniedConsentBlocksTheWriteAndIsLogged() throws {
        consent.decision = .denied(reason: "The user declined.")
        let router = makeRouter()
        let response = try send(router, "POST", "/v1/rules", body: json(["hostId": 7, "mode": "override", "path": "/users?*", "responseStatus": 500]))
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual((response.json?["error"] as? [String: Any])?["code"] as? String, "consent_denied")
        XCTAssertTrue(rules.created.isEmpty, "nothing was performed")
        XCTAssertEqual(audit.entries.count, 1)
        XCTAssertEqual(audit.entries.first?.outcome, .denied)
        XCTAssertEqual(audit.entries.first?.action.kind, .createRule)
        XCTAssertEqual(consent.asked.first?.kind, .createRule)
        XCTAssertTrue(consent.asked.first?.summary.contains("500") ?? false, "the human sees what the rule does: \(consent.asked.first?.summary ?? "")")
    }

    func testAllowedWriteIsPerformedThenLoggedWithItsResult() throws {
        let router = makeRouter()
        let response = try send(router, "POST", "/v1/rules", body: json(["mode": "override", "path": "users?*", "hostId": 7, "responseStatus": 418]))
        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(response.json?["id"] as? Int, 1)
        XCTAssertEqual(response.json?["path"] as? String, "/users?*", "stored normalised, as the form would")
        XCTAssertEqual(rules.created.first?.hostId, 7)
        XCTAssertEqual(audit.entries.map(\.outcome), [.performed])
        XCTAssertTrue(audit.entries.first?.detail?.contains("#1") ?? false)
    }

    func testInvalidInputIs400AndNeverReachesConsent() throws {
        let router = makeRouter()
        let response = try send(router, "POST", "/v1/rules", body: json(["hostId": 7, "mode": "override", "path": "/x", "method": "FETCH"]))
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertTrue(audit.entries.isEmpty)
        let malformed = try send(router, "POST", "/v1/rules", body: Data("not json".utf8))
        XCTAssertEqual(malformed.status, 400)
        let missingMode = try send(router, "POST", "/v1/rules", body: json(["path": "/x"]))
        XCTAssertEqual(missingMode.status, 400)
        XCTAssertTrue(((missingMode.json?["error"] as? [String: Any])?["message"] as? String)?.contains("mode") ?? false)
    }

    func testSeamErrorsMapToStatusesAndAreLoggedAsFailures() throws {
        let router = makeRouter()
        rules.createError = .limitReached("The free version includes one override.")
        let limited = try send(router, "POST", "/v1/rules", body: json(["hostId": 7, "mode": "override", "path": "/x"]))
        XCTAssertEqual(limited.status, 403)
        XCTAssertEqual((limited.json?["error"] as? [String: Any])?["code"] as? String, "limit_reached")

        rules.createError = .failed("db")
        XCTAssertEqual(try send(router, "POST", "/v1/rules", body: json(["hostId": 7, "mode": "override", "path": "/x"])).status, 500)

        rules.createError = .unavailable("core busy")
        XCTAssertEqual(try send(router, "POST", "/v1/rules", body: json(["hostId": 7, "mode": "override", "path": "/x"])).status, 503)

        XCTAssertEqual(audit.entries.map(\.outcome), [.failed, .failed, .failed])
    }

    // MARK: - Rules

    func testListRulesFiltersByHost() throws {
        rules.stored = [
            MCPRule(id: 1, hostId: 3, host: "cdn.example.com", enabled: true, mode: .extend, matchType: .wildcard, path: "/a", method: "GET", scheme: "https"),
            MCPRule(id: 2, hostId: 7, host: "api.example.com", enabled: true, mode: .override, matchType: .wildcard, path: "/b", method: "GET", scheme: "https"),
        ]
        let router = makeRouter()
        let all = try send(router, "GET", "/v1/rules")
        XCTAssertEqual((all.json?["rules"] as? [[String: Any]])?.count, 2)
        let host7 = try send(router, "GET", "/v1/rules?host_id=7")
        XCTAssertEqual((host7.json?["rules"] as? [[String: Any]])?.map { $0["id"] as? Int }, [2])
    }

    func testUpdateAndDeleteRule() throws {
        rules.stored = [MCPRule(id: 3, hostId: 7, host: "api.example.com", enabled: true, mode: .override, matchType: .wildcard, path: "/a", method: "GET", scheme: "https")]
        let router = makeRouter()
        let updated = try send(router, "PATCH", "/v1/rules/3", body: json(["enabled": false, "responseStatus": 404]))
        XCTAssertEqual(updated.status, 200)
        XCTAssertEqual(updated.json?["enabled"] as? Bool, false)
        XCTAssertEqual(updated.json?["responseStatus"] as? Int, 404)
        XCTAssertEqual(consent.asked.last?.kind, .updateRule)

        XCTAssertEqual(try send(router, "PATCH", "/v1/rules/3", body: json([:])).status, 400, "an empty patch is rejected")
        XCTAssertEqual(try send(router, "PATCH", "/v1/rules/99", body: json(["enabled": true])).status, 404)
        XCTAssertEqual(try send(router, "PATCH", "/v1/rules/abc", body: json(["enabled": true])).status, 400)

        let deleted = try send(router, "DELETE", "/v1/rules/3")
        XCTAssertEqual(deleted.status, 200)
        XCTAssertEqual(deleted.json?["id"] as? Int, 3)
        XCTAssertTrue(rules.stored.isEmpty)
        XCTAssertEqual(try send(router, "DELETE", "/v1/rules/3").status, 404)
    }

    func testMockFromSessionGoesThroughConsentWithTheSessionNamed() throws {
        let router = makeRouter()
        let response = try send(router, "POST", "/v1/rules/from-session", body: json(["uid": "s1", "responseStatus": 500]))
        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(consent.asked.first?.kind, .mockFromSession)
        XCTAssertTrue(consent.asked.first?.summary.contains("s1") ?? false)
        XCTAssertEqual(rules.mocked.first?.uid, "s1")
        XCTAssertEqual(try send(router, "POST", "/v1/rules/from-session", body: json(["responseStatus": 500])).status, 400)
        rules.mockError = .notFound("no such session")
        XCTAssertEqual(try send(router, "POST", "/v1/rules/from-session", body: json(["uid": "ghost"])).status, 404)
    }

    // MARK: - Hosts

    func testHostsListAddRemove() throws {
        let router = makeRouter()
        XCTAssertEqual((try send(router, "GET", "/v1/hosts").json?["hosts"] as? [[String: Any]])?.count, 0)
        let added = try send(router, "POST", "/v1/hosts", body: json(["host": "API.Example.com"]))
        XCTAssertEqual(added.status, 201)
        XCTAssertEqual(added.json?["host"] as? String, "api.example.com")
        XCTAssertEqual(added.json?["scheme"] as? String, "https")
        XCTAssertEqual(consent.asked.last?.kind, .addHost)
        XCTAssertEqual(try send(router, "POST", "/v1/hosts", body: json(["host": "http://x"])).status, 400)

        hosts.addError = .limitReached("The free version includes two host filters.")
        XCTAssertEqual(try send(router, "POST", "/v1/hosts", body: json(["host": "b.com"])).status, 403)

        XCTAssertEqual(try send(router, "DELETE", "/v1/hosts/1").status, 200)
        XCTAssertEqual(consent.asked.last?.kind, .removeHost)
        XCTAssertEqual(try send(router, "DELETE", "/v1/hosts/1").status, 404)
    }

    // MARK: - Capture

    func testCaptureStartStopAndClear() throws {
        let router = makeRouter()
        let start = try send(router, "POST", "/v1/capture", body: json(["action": "start"]))
        XCTAssertEqual(start.status, 200)
        XCTAssertEqual(capture.commands, [.start])
        XCTAssertEqual(consent.asked.last?.kind, .startCapture)
        XCTAssertEqual(try send(router, "POST", "/v1/capture", body: json(["action": "stop"])).status, 200)
        XCTAssertEqual(consent.asked.last?.kind, .stopCapture)
        XCTAssertEqual(try send(router, "POST", "/v1/capture", body: json(["action": "pause"])).status, 400)

        capture.sessionsToClear = 12
        let cleared = try send(router, "POST", "/v1/sessions/clear")
        XCTAssertEqual(cleared.status, 200)
        XCTAssertEqual(cleared.json?["cleared"] as? Int, 12)
        XCTAssertEqual(consent.asked.last?.kind, .clearSessions)
    }

    /// A timeout is not a denial: the agent is told nobody answered (and may
    /// retry), and the log distinguishes the two.
    func testConsentTimeoutIsItsOwnOutcome() throws {
        consent.decision = .timedOut(reason: "Nobody answered the ReqRes approval panel within 45 seconds.")
        let response = try send(makeRouter(), "POST", "/v1/rules", body: json(["hostId": 7, "mode": "override", "path": "/x"]))
        XCTAssertEqual(response.status, 408)
        XCTAssertEqual((response.json?["error"] as? [String: Any])?["code"] as? String, "consent_timeout")
        XCTAssertEqual(audit.entries.map(\.outcome), [.timedOut])
        XCTAssertTrue(rules.created.isEmpty)
    }

    /// The client must pass the code through — the tool descriptions promise it.
    func testTheAgentSeesTheErrorCodeNotJustTheMessage() throws {
        let denied = MCPHTTPResponse.error(status: 403, code: "consent_denied", message: "Not allowed: The user declined.")
        let body = try XCTUnwrap(parseRawResponse(denied)).body
        XCTAssertThrowsError(try MCPBridgeClient.decode(MCPRule.self, data: body, status: 403)) { error in
            guard case .badResponse(_, let message)? = error as? MCPBridgeClient.ClientError else { return XCTFail("expected badResponse") }
            XCTAssertTrue(message.contains("consent_denied"), message)
            XCTAssertTrue(message.contains("Do not retry"), message)
        }
        let timedOut = MCPHTTPResponse.error(status: 408, code: "consent_timeout", message: "Nobody answered.")
        let timeoutBody = try XCTUnwrap(parseRawResponse(timedOut)).body
        XCTAssertThrowsError(try MCPBridgeClient.decode(MCPRule.self, data: timeoutBody, status: 408)) { error in
            guard case .badResponse(_, let message)? = error as? MCPBridgeClient.ClientError else { return XCTFail("expected badResponse") }
            XCTAssertTrue(message.contains("consent_timeout"), message)
        }
    }

    // MARK: - Redaction on the write surface

    /// The read surface redacts credential-shaped values; rules carry the same
    /// material (mock_from_session copies a captured response verbatim, and a
    /// human's extend rule may hold a real token), so the write surface must
    /// redact too — while STORING the real value.
    func testRuleResponsesAreRedactedButTheStoredRuleKeepsTheRealValue() throws {
        let router = makeRouter()
        let body = json([
            "hostId": 7, "mode": "override", "path": "/login",
            "responseHeaders": ["Set-Cookie": "session=s3cr3t-value", "Content-Type": "application/json"],
            "responseBody": #"{"access_token":"eyJhbGciOiJIUzI1NiJ9.payloadpayload.signature","user":"ada"}"#,
        ])
        let created = try send(router, "POST", "/v1/rules", body: body)
        XCTAssertEqual(created.status, 201)
        let text = String(data: created.body, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("s3cr3t-value"), "Set-Cookie leaked: \(text)")
        XCTAssertFalse(text.contains("eyJhbGciOiJIUzI1NiJ9"), "JWT leaked: \(text)")
        XCTAssertTrue(text.contains("ada"), "non-sensitive data still reaches the agent")
        XCTAssertEqual(rules.created.first?.responseHeaders["Set-Cookie"], "session=s3cr3t-value",
                       "the rule STORED is the real one — redaction is egress-only")
    }

    func testListRulesRedactsHumanEnteredCredentials() throws {
        rules.stored = [MCPRule(
            id: 1, hostId: 7, host: "api.example.com", enabled: true, mode: .extend, matchType: .wildcard,
            path: "/*", method: "GET", scheme: "https",
            requestHeaders: ["Authorization": "Bearer prod-token-abc"], responseStatus: 200
        )]
        let response = try send(makeRouter(), "GET", "/v1/rules")
        let text = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("prod-token-abc"), text)
        XCTAssertTrue(text.contains("Authorization"), "the agent still sees WHICH header is set")
    }

    func testMockFromSessionResultIsRedacted() throws {
        rules.mockResponseHeaders = ["Set-Cookie": "session=from-capture"]
        rules.mockResponseBody = #"{"refresh_token":"rt-live-9999999999"}"#
        let response = try send(makeRouter(), "POST", "/v1/rules/from-session", body: json(["uid": "s1"]))
        let text = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertEqual(response.status, 201)
        XCTAssertFalse(text.contains("from-capture"), text)
        XCTAssertFalse(text.contains("rt-live-9999999999"), text)
    }

    // MARK: - What the human is shown

    /// Header NAMES are not enough: the gate exists for a prompt-injected
    /// agent, and the payload is what makes a rule dangerous.
    func testConsentDetailsShowHeaderValuesAndFlagCredentialShapedNames() throws {
        consent.decision = .denied(reason: "no")
        _ = try send(makeRouter(), "POST", "/v1/rules", body: json([
            "hostId": 7, "mode": "extend", "path": "/*",
            "requestHeaders": ["Authorization": "Bearer attacker-token"],
            "responseBody": "<script>alert(1)</script>",
        ]))
        let details = consent.asked.first?.details.joined(separator: "\n") ?? ""
        XCTAssertTrue(details.contains("Bearer attacker-token"), details)
        XCTAssertTrue(details.contains("⚠️"), "a credential-shaped header name is flagged: \(details)")
        XCTAssertTrue(details.contains("<script>"), "the body the rule will serve is shown: \(details)")
    }

    func testUpdateConsentDetailsShowTheNewValues() throws {
        rules.stored = [MCPRule(id: 3, hostId: 7, host: "api.example.com", enabled: true, mode: .override, matchType: .wildcard, path: "/a", method: "GET", scheme: "https")]
        _ = try send(makeRouter(), "PATCH", "/v1/rules/3", body: json(["requestHeaders": ["Cookie": "session=attacker"]]))
        let details = consent.asked.first?.details.joined(separator: "\n") ?? ""
        XCTAssertTrue(details.contains("session=attacker"), details)
        XCTAssertTrue(details.contains("⚠️"), details)
    }

    /// The mock summary named only a UUID; the human could not tell what was
    /// being replaced, nor that a host filter would appear.
    func testMockConsentNamesTheSessionAndTheHostFilterSideEffect() throws {
        let router = makeRouter(session: makeSession(uid: "s1", host: "api.example.com", method: "POST", url: "https://api.example.com/checkout?token=abc123secret"))
        _ = try send(router, "POST", "/v1/rules/from-session", body: json(["uid": "s1", "responseStatus": 500]))
        let action = try XCTUnwrap(consent.asked.first)
        XCTAssertTrue(action.summary.contains("api.example.com"), action.summary)
        XCTAssertTrue(action.summary.contains("POST"), action.summary)
        let details = action.details.joined(separator: "\n")
        XCTAssertTrue(details.contains("/checkout"), details)
        XCTAssertFalse(details.contains("abc123secret"), "the URL shown to the human is redacted too: \(details)")
        XCTAssertTrue(details.contains("Adds a host filter"), details)
        XCTAssertTrue(details.contains("500"), details)
    }

    func testMockRejectsExtendAndValidatesBeforeAsking() throws {
        let router = makeRouter()
        XCTAssertEqual(try send(router, "POST", "/v1/rules/from-session", body: json(["uid": "s1", "mode": "extend"])).status, 400)
        XCTAssertEqual(try send(router, "POST", "/v1/rules/from-session", body: json(["uid": "s1", "path": "^/x", "matchType": "regex"])).status, 400)
        XCTAssertTrue(consent.asked.isEmpty, "a request that cannot succeed never interrupts the human")
    }

    func testRemovingAnUnknownHostIs404WithoutAskingTheHuman() throws {
        XCTAssertEqual(try send(makeRouter(), "DELETE", "/v1/hosts/999").status, 404)
        XCTAssertTrue(consent.asked.isEmpty)
    }

    func testRemovingAHostSaysHowManyRulesGoWithIt() throws {
        hosts.stored = [MCPHost(id: 4, host: "api.example.com", scheme: "https", port: 443)]
        rules.stored = [
            MCPRule(id: 1, hostId: 4, host: "api.example.com", enabled: true, mode: .override, matchType: .wildcard, path: "/a", method: "GET", scheme: "https"),
            MCPRule(id: 2, hostId: 4, host: "api.example.com", enabled: true, mode: .override, matchType: .wildcard, path: "/b", method: "GET", scheme: "https"),
        ]
        _ = try send(makeRouter(), "DELETE", "/v1/hosts/4")
        XCTAssertTrue(consent.asked.first?.details.first?.contains("2 rules") ?? false, "\(consent.asked.first?.details ?? [])")
    }

    // MARK: - Pattern test

    func testPatternTestIsPureNeedsNoConsentAndShowsWhatTheProxyCompiles() throws {
        let router = makeRouter()
        let response = try send(router, "POST", "/v1/patterns/test", body: json(["path": "/users?*", "url": "https://api.example.com/users?id=1"]))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json?["matches"] as? Bool, true)
        XCTAssertEqual(response.json?["proxyPattern"] as? String, "https://api.example.com/users?*")
        // `pattern` stays an accepted alias for the argument name an agent reaches for.
        let alias = try send(router, "POST", "/v1/patterns/test", body: json(["pattern": "/orders*", "url": "https://api.example.com/users"]))
        XCTAssertEqual(alias.json?["matches"] as? Bool, false)
        // A regex is tested the way the proxy runs it (unanchored, after the host).
        let regex = try send(router, "POST", "/v1/patterns/test", body: json(["path": "/users/\\d+$", "url": "https://a.com/users/42", "matchType": "regex"]))
        XCTAssertEqual(regex.json?["matches"] as? Bool, true)
        // The same validation create_rule applies: a dead pattern is refused here too.
        let caret = try send(router, "POST", "/v1/patterns/test", body: json(["path": "^/users$", "url": "https://a.com/users", "matchType": "regex"]))
        XCTAssertEqual(caret.status, 400)
        let noURL = try send(router, "POST", "/v1/patterns/test", body: json(["path": "/x", "url": "/not-a-url"]))
        XCTAssertEqual(noURL.status, 400)
        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertTrue(audit.entries.isEmpty)
    }

    func testUnknownWritePathAndMethodStillFail() throws {
        let router = makeRouter()
        XCTAssertEqual(try send(router, "POST", "/v1/nope", body: json([:])).status, 404)
        XCTAssertEqual(try send(router, "PUT", "/v1/rules/1", body: json([:])).status, 405)
        XCTAssertEqual(try send(router, "POST", "/v1/status").status, 405)
    }
}
