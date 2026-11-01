//
//  MCPBridgeRouterTests.swift
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

final class MCPBridgeRouterTests: XCTestCase {
    let token = "test-token-abc"

    private func makeRouter(
        sessions: StubSessionProvider = StubSessionProvider(),
        status: StubStatusProvider = StubStatusProvider(),
        redactor: MCPRedactor = MCPRedactor()
    ) -> MCPBridgeRouter {
        MCPBridgeRouter(token: token, sessions: sessions, status: status, redactor: redactor)
    }

    // MARK: - Security baseline

    func testHealthIsUnauthenticated() throws {
        let router = makeRouter()
        let response = router.respond(to: makeRequest(target: "/v1/health"))
        let parsed = try XCTUnwrap(parseRawResponse(response))
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.json?["ok"] as? Bool, true)
    }

    func testMissingTokenIsUnauthorized() throws {
        let router = makeRouter()
        let response = router.respond(to: makeRequest(target: "/v1/status"))
        let parsed = try XCTUnwrap(parseRawResponse(response))
        XCTAssertEqual(parsed.status, 401)
        XCTAssertEqual(parsed.headers["www-authenticate"], "Bearer")
    }

    func testWrongTokenIsUnauthorized() throws {
        let router = makeRouter()
        let response = router.respond(to: makeRequest(target: "/v1/status", token: "nope"))
        XCTAssertEqual(parseRawResponse(response)?.status, 401)
    }

    func testCorrectTokenReachesStatus() throws {
        let router = makeRouter()
        let response = router.respond(to: makeRequest(target: "/v1/status", token: token))
        let parsed = try XCTUnwrap(parseRawResponse(response))
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.json?["extensionStatus"] as? String, "ready")
        XCTAssertEqual(parsed.json?["captureActive"] as? Bool, true)
    }

    func testNonLoopbackHostIsForbidden() throws {
        let router = makeRouter()
        let response = router.respond(to: makeRequest(target: "/v1/status", token: token, host: "evil.example.com"))
        let parsed = try XCTUnwrap(parseRawResponse(response))
        XCTAssertEqual(parsed.status, 403)
        XCTAssertEqual((parsed.json?["error"] as? [String: Any])?["code"] as? String, "forbidden_host")
    }

    func testBrowserCrossOriginIsForbidden() throws {
        let router = makeRouter()
        let response = router.respond(to: makeRequest(target: "/v1/health", origin: "https://evil.example.com"))
        XCTAssertEqual(parseRawResponse(response)?.status, 403)
    }

    func testLoopbackOriginIsAllowed() throws {
        let router = makeRouter()
        let response = router.respond(to: makeRequest(target: "/v1/health", origin: "http://localhost:3000"))
        XCTAssertEqual(parseRawResponse(response)?.status, 200)
    }

    func testConstantTimeEqualsRejectsLengthMismatch() {
        XCTAssertFalse(MCPBridgeRouter.constantTimeEquals("abc", "abcd"))
        XCTAssertTrue(MCPBridgeRouter.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(MCPBridgeRouter.constantTimeEquals("abc", "abd"))
    }

    // MARK: - The client's pid is recorded only after the bearer check (UX spec §8.1)

    private func identifiedRequest(target: String, token: String?, identity: String) -> MCPHTTPRequest {
        var headers: [String: String] = ["host": "127.0.0.1", MCPClientRegistry.headerName: identity]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return MCPHTTPRequest(method: "GET", target: target, headers: headers)
    }

    func testAnAuthenticatedClientsPidIsRecorded() throws {
        let registry = MCPClientRegistry()
        let router = MCPBridgeRouter(token: token, sessions: StubSessionProvider(), status: StubStatusProvider(), clients: registry)
        let response = router.respond(to: identifiedRequest(
            target: "/v1/status", token: token, identity: "name=claude; id=55; version=1.0; ppid=9437"
        ))

        XCTAssertEqual(parseRawResponse(response)?.status, 200)
        let client = try XCTUnwrap(registry.activeClients().first)
        XCTAssertEqual(client.name, "claude")
        XCTAssertEqual(client.processID, 9437)
    }

    /// Anything that can reach the port could otherwise put a pid of its
    /// choosing beside the user's traffic: an unauthenticated request is
    /// answered 401 and leaves no trace in the registry.
    func testAnImpostorsPidIsNeverRecorded() {
        let registry = MCPClientRegistry()
        let router = MCPBridgeRouter(token: token, sessions: StubSessionProvider(), status: StubStatusProvider(), clients: registry)

        for wrong in [nil, "nope"] {
            let response = router.respond(to: identifiedRequest(
                target: "/v1/status", token: wrong, identity: "name=Evil; id=1; ppid=9437"
            ))
            XCTAssertEqual(parseRawResponse(response)?.status, 401)
        }
        XCTAssertTrue(registry.activeClients().isEmpty)
    }

    // MARK: - A filter that cannot be applied is refused, not dropped

    /// `?pid=curl` is a typo for `?app=curl`. Answering it with every session
    /// would read as "no sessions from curl" to the agent that asked; the
    /// stdio helper already refuses this, and so does the bridge.
    func testANonNumericPidIsA400() throws {
        let router = makeRouter(sessions: StubSessionProvider(summaries: [makeSession(uid: "a", pid: 9437)]))
        let response = router.respond(to: makeRequest(target: "/v1/sessions?pid=curl", token: token))
        let parsed = try XCTUnwrap(parseRawResponse(response))

        XCTAssertEqual(parsed.status, 400)
        let error = parsed.json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "bad_request")
        let message = error?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("'pid' must be an integer"), message)
        XCTAssertTrue(message.contains("curl"), "the message echoes what was sent")
    }

    func testANumericPidFiltersThePage() throws {
        let router = makeRouter(sessions: StubSessionProvider(summaries: [
            makeSession(uid: "a", pid: 9437),
            makeSession(uid: "b", pid: 1),
            makeSession(uid: "c", pid: nil),
        ]))
        let response = router.respond(to: makeRequest(target: "/v1/sessions?pid=9437", token: token))
        let parsed = try XCTUnwrap(parseRawResponse(response))

        XCTAssertEqual(parsed.status, 200)
        let sessions = try XCTUnwrap(parsed.json?["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.map { $0["uid"] as? String }, ["a"])
    }

    // MARK: - Session endpoints

    func testListSessionsReturnsNewestFirstAndRedacts() throws {
        let sessions = StubSessionProvider(summaries: [
            makeSession(uid: "s1", url: "https://api.example.com/a?token=leak1"),
            makeSession(uid: "s2", url: "https://api.example.com/b?token=leak2"),
        ])
        let router = makeRouter(sessions: sessions)
        let response = router.respond(to: makeRequest(target: "/v1/sessions", token: token))
        let parsed = try XCTUnwrap(parseRawResponse(response))
        XCTAssertEqual(parsed.status, 200)
        let list = parsed.json?["sessions"] as? [[String: Any]]
        XCTAssertEqual(list?.first?["uid"] as? String, "s2")
        let bodyString = String(data: parsed.body, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyString.contains("leak1"))
        XCTAssertFalse(bodyString.contains("leak2"))
    }

    func testListSessionsAppliesFilters() throws {
        let sessions = StubSessionProvider(summaries: [
            makeSession(uid: "s1", host: "api.example.com", statusCode: 200),
            makeSession(uid: "s2", host: "cdn.example.com", statusCode: 500),
        ])
        let router = makeRouter(sessions: sessions)
        let response = router.respond(to: makeRequest(target: "/v1/sessions?host=cdn&status=5xx", token: token))
        let parsed = try XCTUnwrap(parseRawResponse(response))
        let list = parsed.json?["sessions"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?["uid"] as? String, "s2")
    }

    /// The attribution filters end to end: query string in, one process's
    /// sessions out, and the rows carry the fields the agent filtered on.
    func testListSessionsFiltersByAppAndPidFromTheQueryString() throws {
        let sessions = StubSessionProvider(summaries: [
            makeSession(uid: "s1", app: "claude", pid: 9437),
            makeSession(uid: "s2", app: "claude", pid: 9767),
            makeSession(uid: "s3", app: "Safari", pid: 501),
            makeSession(uid: "s4"),
        ])
        let router = makeRouter(sessions: sessions)

        let byApp = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/sessions?app=CLAUDE", token: token))))
        XCTAssertEqual((byApp.json?["sessions"] as? [[String: Any]])?.map { $0["uid"] as? String }, ["s2", "s1"])

        let byPid = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/sessions?pid=9767", token: token))))
        let rows = byPid.json?["sessions"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?["uid"] as? String, "s2")
        XCTAssertEqual(rows?.first?["app"] as? String, "claude")
        XCTAssertEqual(rows?.first?["pid"] as? Int, 9767)
    }

    func testGetSessionReturnsDetailWithCappedBody() throws {
        let bigBody = String(repeating: "x", count: MCPLimits.bodyPreviewMaxBytes + 500)
        let detail = MCPSessionDetail(
            summary: makeSession(uid: "s1"),
            responseBodyPreview: bigBody
        )
        let sessions = StubSessionProvider(
            summaries: [makeSession(uid: "s1")],
            details: ["s1": detail]
        )
        let router = makeRouter(sessions: sessions)
        let response = router.respond(to: makeRequest(target: "/v1/sessions/s1", token: token))
        let parsed = try XCTUnwrap(parseRawResponse(response))
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.json?["responseBodyTruncated"] as? Bool, true)
        let preview = parsed.json?["responseBodyPreview"] as? String
        XCTAssertTrue(preview?.hasSuffix(MCPLimits.truncationMarker) ?? false)
    }

    func testGetUnknownSessionIs404() throws {
        let router = makeRouter()
        let response = router.respond(to: makeRequest(target: "/v1/sessions/ghost", token: token))
        XCTAssertEqual(parseRawResponse(response)?.status, 404)
    }

    func testUnknownPathIs404() throws {
        let router = makeRouter()
        let response = router.respond(to: makeRequest(target: "/v1/nope", token: token))
        XCTAssertEqual(parseRawResponse(response)?.status, 404)
    }

    func testNonGetMethodIs405() throws {
        let router = makeRouter()
        let response = router.respond(to: makeRequest(method: "POST", target: "/v1/status", token: token))
        XCTAssertEqual(parseRawResponse(response)?.status, 405)
    }

    // MARK: - /v1/destinations (destination-map UX spec §8.3)

    func testDestinationsRequiresTheToken() {
        let router = makeRouter()
        XCTAssertEqual(parseRawResponse(router.respond(to: makeRequest(target: "/v1/destinations")))?.status, 401)
    }

    /// Read-only, no consent: the matching sessions grouped by destination,
    /// Unknown last, with the three report keys and nothing about the user's
    /// own location.
    func testDestinationsAggregatesTheSessionsAndCarriesNoOrigin() throws {
        let sessions = StubSessionProvider(summaries: [
            makeSession(uid: "s1", host: "api.stripe.com", app: "claude", country: "US"),
            makeSession(uid: "s2", host: "api.stripe.com", app: "claude", country: "US"),
            makeSession(uid: "s3", host: "api.myshop.dev", app: "Brave Browser", country: "DE"),
            makeSession(uid: "s4", host: "localhost", app: "node", country: "mac"),
            makeSession(uid: "s5", host: "10.0.0.5", app: nil, country: nil),
        ])
        let router = makeRouter(sessions: sessions)
        let parsed = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/destinations", token: token))))

        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(Set((parsed.json ?? [:]).keys), ["totalRequests", "destinations", "note", "neverConnected"])
        XCTAssertEqual(parsed.json?["totalRequests"] as? Int, 5)
        let rows = try XCTUnwrap(parsed.json?["destinations"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["country"] as? String }, ["US", "DE", "mac", "unknown"])
        XCTAssertEqual(rows.first?["requests"] as? Int, 2)
        XCTAssertEqual(rows.first?["name"] as? String, "United States")
        XCTAssertEqual((rows.first?["topHosts"] as? [[String: Any]])?.first?["name"] as? String, "api.stripe.com")
        XCTAssertTrue((parsed.json?["note"] as? String)?.contains("DB-IP") == true)
        XCTAssertFalse((String(data: parsed.body, encoding: .utf8) ?? "").lowercased().contains("origin"))
    }

    func testDestinationsAppliesTheSessionFilters() throws {
        let sessions = StubSessionProvider(summaries: [
            makeSession(uid: "s1", app: "claude", country: "US"),
            makeSession(uid: "s2", app: "claude", country: "DE"),
            makeSession(uid: "s3", app: "Safari", country: "JP"),
        ])
        let router = makeRouter(sessions: sessions)
        let parsed = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/destinations?app=claude", token: token))))
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.json?["totalRequests"] as? Int, 2)
        let rows = try XCTUnwrap(parsed.json?["destinations"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["country"] as? String }), ["US", "DE"])
    }

    /// A country NAME is refused with the message that says what to send —
    /// the `pid=curl` rule, at the same status.
    func testDestinationsRefusesACountryNameWithA400() throws {
        let router = makeRouter(sessions: StubSessionProvider(summaries: [makeSession(uid: "s1", country: "DE")]))
        let parsed = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/destinations?country=Germany", token: token))))
        XCTAssertEqual(parsed.status, 400)
        let error = parsed.json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "bad_request")
        let message = error?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("'country' must be a two-letter ISO code"), message)
        XCTAssertTrue(message.contains("Germany"), "the message echoes what was sent")
    }

    /// The same filter on /v1/sessions: applied there too, refused there too,
    /// and the rows carry the token the agent filtered on.
    func testSessionsFilterByCountryAndRefuseANameToo() throws {
        let router = makeRouter(sessions: StubSessionProvider(summaries: [
            makeSession(uid: "s1", country: "DE"), makeSession(uid: "s2", country: "US"), makeSession(uid: "s3", country: nil),
        ]))
        let byCode = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/sessions?country=de", token: token))))
        let rows = byCode.json?["sessions"] as? [[String: Any]]
        XCTAssertEqual(rows?.map { $0["uid"] as? String }, ["s1"])
        XCTAssertEqual(rows?.first?["country"] as? String, "DE")

        let unknown = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/sessions?country=unknown", token: token))))
        let unplaced = unknown.json?["sessions"] as? [[String: Any]]
        XCTAssertEqual(unplaced?.map { $0["uid"] as? String }, ["s3"])
        XCTAssertNil(unplaced?.first?["country"], "an Unknown row omits the field rather than carrying a fourth word")

        XCTAssertEqual(parseRawResponse(router.respond(to: makeRequest(target: "/v1/sessions?country=Germany", token: token)))?.status, 400)
    }
}
