//
//  MCPBridgeRouterRedactorProviderTests.swift
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
//  The redaction policy is a live setting, and the only way to apply a change
//  to a router built at launch used to be restarting the bridge — which
//  rotates the token and disconnects every client. These pin that the router
//  asks for its redactor per request, and that a caller which passes a plain
//  redactor still gets exactly the old fixed behaviour.
//

import XCTest
@testable import MCPKit

final class MCPBridgeRouterRedactorProviderTests: XCTestCase {
    private let token = "test-token"

    private func sessionWithASecretInTheURL() -> StubSessionProvider {
        StubSessionProvider(summaries: [
            makeSession(uid: "s1", url: "https://api.example.com/v1/x?token=supersecretvalue"),
        ])
    }

    private func listSessions(_ router: MCPBridgeRouter) throws -> String {
        let response = try XCTUnwrap(parseRawResponse(
            router.respond(to: makeRequest(method: "GET", target: "/v1/sessions", token: token))
        ))
        XCTAssertEqual(response.status, 200)
        return String(decoding: response.body, as: UTF8.self)
    }

    func testTheProviderIsConsultedOnEveryRequest() throws {
        var policy = MCPRedactionPolicy.redactAll
        let router = MCPBridgeRouter(
            token: token,
            sessions: sessionWithASecretInTheURL(),
            status: StubStatusProvider(),
            redactorProvider: { MCPRedactor(enabled: policy.isEnabled, policy: policy) }
        )

        XCTAssertFalse(try listSessions(router).contains("supersecretvalue"))

        // The user excepts the host in Settings. No restart, no new router.
        policy = try XCTUnwrap(policy.addingException("api.example.com"))
        XCTAssertTrue(try listSessions(router).contains("supersecretvalue"),
                      "an exception added after the router was built must apply to the next request")

        // …and changes their mind, which must take effect just as immediately.
        policy = policy.removingException("api.example.com")
        XCTAssertFalse(try listSessions(router).contains("supersecretvalue"))
    }

    /// Every existing call site passes `redactor:` and nothing else; that must
    /// keep meaning "this exact redactor, forever".
    func testAFixedRedactorStillWorksAndStillRedacts() throws {
        let router = MCPBridgeRouter(
            token: token,
            sessions: sessionWithASecretInTheURL(),
            status: StubStatusProvider()
        )

        XCTAssertFalse(try listSessions(router).contains("supersecretvalue"))
    }

    /// Passing both is a mistake, but a silent one would be the dangerous
    /// kind: the provider is the live source, so it has to be the one that
    /// wins rather than the fixed snapshot.
    func testTheProviderOutranksAFixedRedactor() throws {
        let policy = try XCTUnwrap(MCPRedactionPolicy.redactAll.addingException("api.example.com"))
        let router = MCPBridgeRouter(
            token: token,
            sessions: sessionWithASecretInTheURL(),
            status: StubStatusProvider(),
            redactor: MCPRedactor(),
            redactorProvider: { MCPRedactor(policy: policy) }
        )

        XCTAssertTrue(try listSessions(router).contains("supersecretvalue"))
    }
}
