//
//  MCPReplayTests.swift
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
//  Horizon 3, item 17. The safety design IS the feature here, so these tests
//  are mostly about what the route REFUSES, and each one is written so that
//  removing the guard it covers turns it red:
//
//   * a non-idempotent method is refused, by name, for every one of them;
//   * the host cannot be changed, so captured credentials cannot be walked
//     off to a server the agent picked;
//   * the response is redacted on the way out even though the request went
//     out in the clear;
//   * the standing grant does not answer for it;
//   * and an agent is told whether its replay went through the proxy, since
//     that is what decides whether the user's rules applied to it.
//

import XCTest
@testable import MCPKit

/// Records the plan instead of touching the network.
final class StubReplayer: MCPReplaying {
    var received: [MCPReplayPlan] = []
    var response: MCPReplayResponse
    var error: Error?

    init(response: MCPReplayResponse = MCPReplayResponse(statusCode: 200, route: .proxy)) {
        self.response = response
    }

    func replay(_ plan: MCPReplayPlan) throws -> MCPReplayResponse {
        received.append(plan)
        if let error { throw error }
        return response
    }
}

/// Mimics `MCPAgentActivity`'s queue: a standing grant answers for whatever
/// the pure rule says it may answer for, and everything else is put in front
/// of a human. The point of the stub is that it consults
/// `canBeCoveredByStandingGrant` rather than hardcoding a list — the same
/// thing the app does, so this test fails if the rule flips.
final class StandingGrantConsent: MCPWriteConsenting {
    var grantIsOn = true
    /// Actions that reached "the human" instead of being auto-allowed.
    var shownToHuman: [MCPAgentAction] = []
    var humanDecision: MCPConsentDecision = .allowed

    func authorize(_ action: MCPAgentAction) -> MCPConsentDecision {
        if grantIsOn, action.severity.canBeCoveredByStandingGrant {
            return .allowed
        }
        shownToHuman.append(action)
        return humanDecision
    }
}

final class MCPReplayTests: XCTestCase {
    private let token = "test-token"
    private var consent: StubConsent!
    private var audit: StubAudit!
    private var replayer: StubReplayer!

    override func setUp() {
        super.setUp()
        consent = StubConsent()
        audit = StubAudit()
        replayer = StubReplayer()
    }

    // MARK: - Fixtures

    private func captured(
        uid: String = "abc",
        host: String = "api.example.com",
        method: String = "GET",
        url: String? = nil,
        requestHeaders: [String: String] = [
            "Authorization": "Bearer super-secret-token-value",
            "Accept": "application/json",
            "Host": "api.example.com",
            "Content-Length": "0",
        ]
    ) -> MCPSessionDetail {
        var summary = makeSession(uid: uid, host: host, method: method, url: url ?? "https://\(host)/v1/users?limit=10")
        summary.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return MCPSessionDetail(summary: summary, requestHeaders: requestHeaders)
    }

    private func makeRouter(
        _ details: [MCPSessionDetail],
        replayer: MCPReplaying? = nil,
        consent: MCPWriteConsenting? = nil,
        redactor: MCPRedactor = MCPRedactor()
    ) -> MCPBridgeRouter {
        let sessions = StubSessionProvider(
            summaries: details.map(\.summary),
            details: Dictionary(uniqueKeysWithValues: details.map { ($0.summary.uid, $0) })
        )
        return MCPBridgeRouter(
            token: token,
            sessions: sessions,
            status: StubStatusProvider(),
            redactorProvider: { redactor },
            writes: MCPWriteSeams(
                rules: StubRuleProvider(),
                hosts: StubHostProvider(),
                capture: StubCaptureController(),
                consent: consent ?? self.consent,
                audit: audit,
                replay: replayer ?? self.replayer
            )
        )
    }

    private func replay(_ router: MCPBridgeRouter, _ body: [String: Any]) throws -> ParsedResponse {
        var request = makeRequest(method: "POST", target: "/v1/sessions/replay", token: token)
        request.body = try JSONSerialization.data(withJSONObject: body)
        request.headers["content-type"] = "application/json"
        return try XCTUnwrap(parseRawResponse(router.respond(to: request)))
    }

    private func errorMessage(_ response: ParsedResponse) throws -> String {
        let json = try XCTUnwrap(response.json)
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        return try XCTUnwrap(error["message"] as? String)
    }

    // MARK: - Methods

    /// The v1 promise, parameterised over every method that is not replayable.
    /// Each refusal has to NAME the method: an agent told "unsupported" tries
    /// something else, one told "POST is refused" reports it to the user.
    func testEveryNonIdempotentMethodIsRefusedByName() throws {
        for method in ["POST", "PUT", "PATCH", "DELETE", "post", "TRACE", "CONNECT"] {
            let router = makeRouter([captured()])
            let response = try replay(router, ["uid": "abc", "method": method])
            XCTAssertEqual(response.status, 400, "\(method) should be refused")
            let message = try errorMessage(response)
            XCTAssertTrue(message.contains(method.uppercased()), "the refusal must name \(method): \(message)")
            XCTAssertTrue(message.contains("GET, HEAD, OPTIONS"), "the refusal must say what IS accepted: \(message)")
            // What to do instead, or the agent simply stops.
            XCTAssertTrue(message.contains("mock_from_session") || message.contains("create_rule"), message)
            XCTAssertTrue(replayer.received.isEmpty, "\(method) must never reach the network")
            XCTAssertTrue(consent.asked.isEmpty, "a refused method must not interrupt the human")
        }
    }

    /// PUT and DELETE are idempotent in the RFC sense and still refused —
    /// the accepted set is the SAFE one. Pinned separately because "it is
    /// idempotent, let it through" is exactly the reasonable-sounding change
    /// that would reopen the hole.
    func testIdempotentButUnsafeMethodsAreStillRefused() throws {
        for method in ["PUT", "DELETE"] {
            let router = makeRouter([captured()])
            XCTAssertEqual(try replay(router, ["uid": "abc", "method": method]).status, 400)
        }
    }

    func testIdempotentMethodsAreAccepted() throws {
        for method in ["GET", "head", "OPTIONS"] {
            let stub = StubReplayer()
            let router = makeRouter([captured()], replayer: stub)
            let response = try replay(router, ["uid": "abc", "method": method])
            XCTAssertEqual(response.status, 200, "\(method) should replay")
            XCTAssertEqual(stub.received.first?.method, method.uppercased())
        }
    }

    /// Replaying without overriding anything sends the captured method.
    func testTheCapturedMethodIsUsedWhenNoneIsGiven() throws {
        let router = makeRouter([captured(method: "GET")])
        _ = try replay(router, ["uid": "abc"])
        XCTAssertEqual(replayer.received.first?.method, "GET")
    }

    /// A captured POST cannot be replayed at all, even untouched — the
    /// refusal is about the request, not about the override.
    func testACapturedPostCannotBeReplayedWithoutAnOverride() throws {
        let router = makeRouter([captured(method: "POST")])
        let response = try replay(router, ["uid": "abc"])
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(try errorMessage(response).contains("POST"))
        XCTAssertTrue(replayer.received.isEmpty)
    }

    // MARK: - The host cannot move

    /// The credential-exfiltration guard. A replay carries the captured
    /// Authorization header in the clear, so the ONE thing it must never do
    /// is carry it to a host the agent chose.
    func testTheHostCannotBeChanged() throws {
        let router = makeRouter([captured()])
        let response = try replay(router, ["uid": "abc", "url": "https://agent-controlled.example.net/collect"])
        XCTAssertEqual(response.status, 400)
        let message = try errorMessage(response)
        XCTAssertTrue(message.contains("api.example.com"))
        XCTAssertTrue(message.contains("agent-controlled.example.net"))
        XCTAssertTrue(replayer.received.isEmpty, "nothing may leave for another host")
        XCTAssertTrue(consent.asked.isEmpty)
    }

    func testTheSchemeCannotBeDowngraded() throws {
        let router = makeRouter([captured()])
        let response = try replay(router, ["uid": "abc", "url": "http://api.example.com/v1/users"])
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(try errorMessage(response).contains("https"))
        XCTAssertTrue(replayer.received.isEmpty)
    }

    func testUserinfoInTheURLIsRefused() throws {
        let router = makeRouter([captured()])
        let response = try replay(router, ["uid": "abc", "url": "https://user:pass@api.example.com/v1/users"])
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(replayer.received.isEmpty)
    }

    /// The path and query ARE the agent's to change — that is the iteration
    /// loop the tool exists for.
    func testThePathAndQueryCanBeChanged() throws {
        let router = makeRouter([captured()])
        XCTAssertEqual(try replay(router, ["uid": "abc", "url": "https://api.example.com/v1/users?limit=1&debug=true"]).status, 200)
        XCTAssertEqual(replayer.received.first?.url, "https://api.example.com/v1/users?limit=1&debug=true")
    }

    // MARK: - Headers

    /// Overrides reach the wire, and the captured headers ride along — the
    /// replay is the same request plus the agent's edit, not a fresh one.
    func testHeaderOverridesAndCapturedHeadersAreBothCarried() throws {
        let router = makeRouter([captured()])
        XCTAssertEqual(try replay(router, [
            "uid": "abc",
            "headers": ["X-Debug": "1"],
        ]).status, 200)
        let plan = try XCTUnwrap(replayer.received.first)
        XCTAssertEqual(plan.headers["X-Debug"], "1")
        XCTAssertEqual(plan.headers["Authorization"], "Bearer super-secret-token-value", "the captured credential is what makes a replay work")
        XCTAssertEqual(plan.headers["Accept"], "application/json")
    }

    func testRemovedHeadersAreDroppedCaseInsensitively() throws {
        let router = makeRouter([captured()])
        _ = try replay(router, ["uid": "abc", "removeHeaders": ["authorization"]])
        let plan = try XCTUnwrap(replayer.received.first)
        XCTAssertNil(plan.headers["Authorization"])
        XCTAssertEqual(plan.headers["Accept"], "application/json")
    }

    /// An override replaces a captured header whatever its capitalisation.
    /// Two entries differing only in case would both reach URLSession and
    /// whichever it applied last would win, silently.
    func testAnOverrideReplacesACapturedHeaderOfAnotherCase() throws {
        let router = makeRouter([captured(requestHeaders: ["authorization": "Bearer old"])])
        _ = try replay(router, ["uid": "abc", "headers": ["Authorization": "Bearer new"]])
        let plan = try XCTUnwrap(replayer.received.first)
        XCTAssertEqual(plan.headers.filter { $0.key.lowercased() == "authorization" }.count, 1)
        XCTAssertEqual(plan.headers["Authorization"], "Bearer new")
    }

    /// Carrying a captured Host or Content-Length into a new request is how
    /// a replay becomes a malformed one; URLSession owns those.
    func testTransportOwnedHeadersAreNotCarried() throws {
        let router = makeRouter([captured()])
        _ = try replay(router, ["uid": "abc"])
        let plan = try XCTUnwrap(replayer.received.first)
        XCTAssertNil(plan.headers["Host"])
        XCTAssertNil(plan.headers["Content-Length"])
    }

    func testOverridingATransportOwnedHeaderIsRefused() throws {
        let router = makeRouter([captured()])
        let response = try replay(router, ["uid": "abc", "headers": ["Host": "elsewhere.example.com"]])
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(replayer.received.isEmpty)
    }

    func testHeaderValuesWithLineBreaksAreRefused() throws {
        let router = makeRouter([captured()])
        let response = try replay(router, ["uid": "abc", "headers": ["X-Evil": "ok\r\nX-Injected: yes"]])
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(replayer.received.isEmpty)
    }

    // MARK: - Consent

    /// The consent panel has to name the method, the host and the full path.
    /// "An agent wants to replay a request" is a sentence nobody can decide on.
    func testTheConsentActionNamesTheMethodHostAndPath() throws {
        let router = makeRouter([captured()])
        _ = try replay(router, ["uid": "abc"])
        let action = try XCTUnwrap(consent.asked.first)
        XCTAssertEqual(action.kind, .replayRequest)
        XCTAssertEqual(action.severity, .actsOnThirdParty)
        XCTAssertTrue(action.summary.contains("GET"))
        XCTAssertTrue(action.summary.contains("api.example.com"))
        XCTAssertTrue(action.summary.contains("/v1/users?limit=10"))
        XCTAssertTrue(action.summary.lowercased().contains("real server"))
        // The carried credential is the fact that makes this dangerous, so
        // the panel says it rather than counting headers.
        XCTAssertTrue(action.details.contains { $0.contains("Authorization") }, "\(action.details)")
    }

    func testTheConsentActionNamesWhatTheAgentChanged() throws {
        let router = makeRouter([captured()])
        _ = try replay(router, [
            "uid": "abc",
            "method": "HEAD",
            "headers": ["X-Debug": "1"],
            "removeHeaders": ["Accept"],
        ])
        let details = try XCTUnwrap(consent.asked.first?.details)
        XCTAssertTrue(details.contains { $0.contains("GET → HEAD") }, "\(details)")
        // The VALUE, not just the name: "sets a header" hides an agent
        // attaching a bearer token of its own.
        XCTAssertTrue(details.contains { $0.contains("X-Debug: 1") }, "\(details)")
        XCTAssertTrue(details.contains { $0.contains("Header removed: Accept") }, "\(details)")
    }

    func testADeniedReplayNeverReachesTheNetwork() throws {
        consent.decision = .denied(reason: "The user declined.")
        let router = makeRouter([captured()])
        let response = try replay(router, ["uid": "abc"])
        XCTAssertEqual(response.status, 403)
        XCTAssertTrue(replayer.received.isEmpty)
        XCTAssertEqual(audit.entries.first?.outcome, .denied)
    }

    /// The rule that item 17 turns on: "let agents change rules and hosts
    /// without asking" must not silently include "send this request again".
    /// The stub applies the same pure rule the app's consent queue does.
    func testTheStandingGrantDoesNotCoverAReplayButStillCoversARuleChange() throws {
        let grant = StandingGrantConsent()
        let router = makeRouter([captured()], consent: grant)

        // A rule change rides the grant: no human involved.
        var ruleRequest = makeRequest(method: "POST", target: "/v1/rules", token: token)
        ruleRequest.body = try JSONSerialization.data(withJSONObject: [
            "hostId": 1, "mode": "override", "path": "/users?*",
        ])
        ruleRequest.headers["content-type"] = "application/json"
        _ = router.respond(to: ruleRequest)
        XCTAssertTrue(grant.shownToHuman.isEmpty, "a rule change is still covered by the standing grant")

        // The replay is not.
        XCTAssertEqual(try replay(router, ["uid": "abc"]).status, 200)
        XCTAssertEqual(grant.shownToHuman.map(\.kind), [.replayRequest])
    }

    /// And when the human says no to that panel, the grant does not rescue it.
    func testAGrantedSessionStillStopsAtADeclinedReplay() throws {
        let grant = StandingGrantConsent()
        grant.humanDecision = .denied(reason: "The user declined.")
        let router = makeRouter([captured()], consent: grant)
        XCTAssertEqual(try replay(router, ["uid": "abc"]).status, 403)
        XCTAssertTrue(replayer.received.isEmpty)
    }

    // MARK: - Redaction on the way out

    /// The request goes out with real credentials; nothing unredacted comes
    /// back. Fails if anyone returns the seam's response as-is.
    func testTheResponseIsRedactedOnTheWayOut() throws {
        replayer.response = MCPReplayResponse(
            statusCode: 200,
            headers: [
                "Set-Cookie": "session=ABCDEF-super-secret-cookie-value",
                "Content-Type": "application/json",
            ],
            bodyPreview: #"{"access_token":"sk_live_"# + #"abcdef1234567890","ok":true}"#,
            bodyBytes: 52,
            contentType: "application/json",
            durationMs: 12,
            route: .proxy
        )
        let router = makeRouter([captured()])
        let response = try replay(router, ["uid": "abc"])
        XCTAssertEqual(response.status, 200)
        let text = try XCTUnwrap(String(data: response.body, encoding: .utf8))

        XCTAssertFalse(text.contains("ABCDEF-super-secret-cookie-value"), "a Set-Cookie came back in the clear")
        XCTAssertFalse(text.contains("sk_live_" + "abcdef1234567890"), "a token came back in the clear")
        // The request headers are echoed so the agent can see what it sent —
        // masked, like everything else.
        XCTAssertFalse(text.contains("super-secret-token-value"), "the credential that was SENT came back readable")
        XCTAssertTrue(text.contains("redacted"))
        XCTAssertEqual(try XCTUnwrap(response.json)["redacted"] as? Bool, true)
    }

    /// Redaction off is the user's own setting, and the result says so rather
    /// than letting an agent assume it is reading placeholders.
    func testWithRedactionOffTheResultSaysTheValuesAreReal() throws {
        replayer.response = MCPReplayResponse(
            statusCode: 200,
            headers: ["Set-Cookie": "session=plain-value"],
            route: .direct
        )
        let router = makeRouter([captured()], redactor: MCPRedactor(enabled: false))
        let response = try replay(router, ["uid": "abc"])
        let json = try XCTUnwrap(response.json)
        XCTAssertEqual(json["redacted"] as? Bool, false)
    }

    // MARK: - Route reporting

    func testTheRouteTakenIsReportedBack() throws {
        for route in [MCPReplayRoute.proxy, .direct] {
            let stub = StubReplayer(response: MCPReplayResponse(statusCode: 204, route: route))
            let router = makeRouter([captured()], replayer: stub)
            let json = try XCTUnwrap(try replay(router, ["uid": "abc"]).json)
            XCTAssertEqual(json["route"] as? String, route.rawValue)
            XCTAssertEqual(json["replayedFrom"] as? String, "abc")
        }
    }

    /// The single most likely way this tool misleads someone: a replay sent
    /// while capture is stopped bypasses every rule, and an agent that does
    /// not say so reports "your mock is broken".
    func testTheTextOutputExplainsWhatEachRouteMeans() {
        let session = MCPSessionDetail(summary: makeSession(uid: "abc"))
        let direct = MCPTextFormat.replay(MCPReplayResult(session: session, route: .direct, replayedFrom: "abc", redacted: true))
        XCTAssertTrue(direct.contains("DIRECTLY"))
        XCTAssertTrue(direct.contains("No rule applied"))
        XCTAssertTrue(direct.contains("start_capture"))

        let proxied = MCPTextFormat.replay(MCPReplayResult(session: session, route: .proxy, replayedFrom: "abc", redacted: true))
        XCTAssertTrue(proxied.contains("rules applied"))
        XCTAssertTrue(proxied.contains("traffic list"))
        XCTAssertFalse(proxied.contains("DIRECTLY"))
    }

    // MARK: - Audit

    func testAPerformedReplayIsLoggedAndIsNotUndoable() throws {
        replayer.response = MCPReplayResponse(statusCode: 503, route: .proxy)
        let router = makeRouter([captured()])
        XCTAssertEqual(try replay(router, ["uid": "abc"]).status, 200)
        let entry = try XCTUnwrap(audit.entries.first)
        XCTAssertEqual(entry.action.kind, .replayRequest)
        XCTAssertEqual(entry.outcome, .performed)
        XCTAssertEqual(entry.detail, "GET api.example.com → 503 via proxy")
        // Nothing in ReqRes changed, and what did change is on a server this
        // app has no standing to put back.
        XCTAssertFalse(entry.isReversible)
        XCTAssertNil(MCPUndo.plan(for: entry))
        XCTAssertNil(entry.created)
    }

    /// The log is persisted and exportable, so the URL it records must not
    /// carry a captured credential out of the app.
    func testTheLoggedActionIsRedactedEvenThoughThePanelIsNot() throws {
        let detail = captured(url: "https://api.example.com/v1/users?access_token=sk_live_" + "abcdef1234567890")
        let router = makeRouter([detail])
        _ = try replay(router, ["uid": "abc"])
        let logged = try XCTUnwrap(audit.entries.first).action
        XCTAssertFalse(logged.summary.contains("sk_live_" + "abcdef1234567890"), logged.summary)
        // The human deciding still sees the real thing.
        XCTAssertTrue(try XCTUnwrap(consent.asked.first).summary.contains("sk_live_" + "abcdef1234567890"))
    }

    func testAFailedReplayIsLoggedAsFailed() throws {
        replayer.error = MCPWriteError.failed("api.example.com did not answer within 30s.")
        let router = makeRouter([captured()])
        let response = try replay(router, ["uid": "abc"])
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(audit.entries.first?.outcome, .failed)
    }

    // MARK: - Route plumbing

    func testAnUnknownUidIs404() throws {
        let router = makeRouter([captured()])
        let response = try replay(router, ["uid": "not-a-session"])
        XCTAssertEqual(response.status, 404)
        XCTAssertTrue(try errorMessage(response).contains("list_sessions"))
        XCTAssertTrue(consent.asked.isEmpty, "an unknown uid must not interrupt the human")
    }

    func testAMissingUidIs400() throws {
        let router = makeRouter([captured()])
        XCTAssertEqual(try replay(router, ["method": "GET"]).status, 400)
    }

    /// A build that has not wired the seam answers 503 for this one route and
    /// keeps every other write working.
    func testAnUnwiredBuildAnswers503() throws {
        let details = [captured()]
        let router = MCPBridgeRouter(
            token: token,
            sessions: StubSessionProvider(
                summaries: details.map(\.summary),
                details: Dictionary(uniqueKeysWithValues: details.map { ($0.summary.uid, $0) })
            ),
            status: StubStatusProvider(),
            writes: MCPWriteSeams(
                rules: StubRuleProvider(),
                hosts: StubHostProvider(),
                capture: StubCaptureController(),
                consent: consent,
                audit: audit
            )
        )
        XCTAssertEqual(try replay(router, ["uid": "abc"]).status, 503)
        XCTAssertTrue(consent.asked.isEmpty)
    }

    /// A GET on the replay path falls through to the session-detail route
    /// (`/v1/sessions/{uid}`) and 404s as an unknown session, the same way
    /// `/v1/sessions/export` and `/v1/sessions/clear` already do. Pinned so
    /// the behaviour is a decision rather than a surprise: session uids are
    /// UUIDs, so no real session can collide with the word "replay", and the
    /// alternative — special-casing each verb ahead of the detail route — buys
    /// a tidier status code for a request nothing sends.
    ///
    /// What matters is that it is not a SUCCESS: a replay only ever happens
    /// through POST, where consent runs.
    func testAGetOnTheReplayPathNeverReplays() {
        let router = makeRouter([captured()])
        let response = parseRawResponse(router.respond(to: makeRequest(target: "/v1/sessions/replay", token: token)))
        XCTAssertEqual(response?.status, 404)
        XCTAssertTrue(replayer.received.isEmpty)
        XCTAssertTrue(consent.asked.isEmpty)
    }

    // MARK: - The plan, without a router

    func testThePlanRendersTheReplayedExchangeAsASessionDetail() throws {
        let plan = try MCPReplayPlan.make(replaying: captured(), request: MCPReplayRequest(uid: "abc"))
        let response = MCPReplayResponse(
            statusCode: 201,
            headers: ["Content-Type": "application/json"],
            bodyPreview: #"{"ok":true}"#,
            bodyBytes: 11,
            contentType: "application/json",
            durationMs: 42,
            route: .proxy,
            finalURL: "https://api.example.com/v1/users?limit=10&page=2"
        )
        let detail = response.detail(for: plan, now: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(detail.summary.statusCode, 201)
        XCTAssertEqual(detail.summary.durationMs, 42)
        XCTAssertEqual(detail.summary.host, "api.example.com")
        XCTAssertEqual(detail.summary.scheme, "https")
        // Where it ENDED UP, not where it aimed: URLSession follows redirects.
        XCTAssertEqual(detail.summary.url, "https://api.example.com/v1/users?limit=10&page=2")
        XCTAssertEqual(detail.requestHeaders["Authorization"], "Bearer super-secret-token-value")
        XCTAssertEqual(detail.responseBodyPreview, #"{"ok":true}"#)
    }

    func testAnUnparseableCapturedURLIsRefusedRatherThanGuessed() {
        var summary = makeSession(uid: "abc")
        summary.url = ""
        let detail = MCPSessionDetail(summary: summary)
        XCTAssertThrowsError(try MCPReplayPlan.make(replaying: detail, request: MCPReplayRequest(uid: "abc")))
    }

    func testTooManyHeaderEditsAreRefused() {
        let edits = Dictionary(uniqueKeysWithValues: (0...MCPReplayLimits.maxHeaderEdits).map { ("X-\($0)", "v") })
        XCTAssertThrowsError(
            try MCPReplayPlan.make(replaying: captured(), request: MCPReplayRequest(uid: "abc", headers: edits))
        ) { error in
            // Every edit is rendered in the panel a human reads to decide;
            // an unbounded list is how that panel stops being readable.
            XCTAssertEqual((error as? MCPWriteError)?.message.contains("at most"), true)
        }
    }
}

/// The two holes the adversarial review of this feature found, both measured
/// rather than reasoned about. Each test fails against the code as it was.
final class MCPReplaySafetyRegressionTests: XCTestCase {
    private func captured(method: String, url: String = "https://api.example.com/api/delete?id=5") -> MCPSessionDetail {
        MCPSessionDetail(
            summary: MCPSessionSummary(
                uid: "s1",
                host: "api.example.com",
                method: method,
                url: url,
                scheme: "https",
                statusCode: 200
            ),
            requestHeaders: ["Authorization": "Bearer real-token", "Cookie": "session=abc123"]
        )
    }

    /// The review's finding, verbatim: a captured POST was replayable by
    /// asking for `method: "GET"`. The wire method was then safe, but the
    /// endpoint was still one built to change something — and plenty act on
    /// the query string whatever the verb is.
    func testACapturedPostCannotBeReplayedByOverridingTheMethod() {
        for method in ["POST", "PUT", "PATCH", "DELETE", "post"] {
            XCTAssertThrowsError(
                try MCPReplayPlan.make(
                    replaying: captured(method: method),
                    request: MCPReplayRequest(uid: "s1", method: "GET")
                ),
                "a captured \(method) must be refused even as a GET"
            ) { error in
                guard case MCPWriteError.invalid(let message) = error else { return XCTFail("wrong error: \(error)") }
                XCTAssertTrue(message.contains(method.uppercased()), "the refusal must name what was captured: \(message)")
            }
        }
    }

    func testACapturedGetIsStillReplayable() throws {
        let plan = try MCPReplayPlan.make(
            replaying: captured(method: "GET"),
            request: MCPReplayRequest(uid: "s1")
        )

        XCTAssertEqual(plan.method, "GET")
        XCTAssertEqual(plan.host, "api.example.com")
    }

    /// A session with no scheme recorded used to be unreplayable, with an
    /// error blaming the URL. The core writes `host + uri` for those rows.
    func testASchemelessCapturedURLFallsBackToTheSummarysScheme() throws {
        var detail = captured(method: "GET", url: "api.example.com/v1/users")
        detail.summary.scheme = "https"

        let plan = try MCPReplayPlan.make(replaying: detail, request: MCPReplayRequest(uid: "s1"))

        XCTAssertEqual(plan.scheme, "https")
        XCTAssertEqual(plan.host, "api.example.com")
        XCTAssertTrue(plan.url.hasPrefix("https://api.example.com/v1/users"), "got \(plan.url)")
    }
}
