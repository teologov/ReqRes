//
//  MCPBreakpointTests.swift
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
//  The agent's half of breakpoints. Everything here guards something that
//  happens to a request while a browser tab waits on it, so the bar for
//  "obviously fine" is lower than usual.
//

import XCTest
@testable import MCPKit

// MARK: - Support

final class StubBreakpoints: MCPBreakpointProviding {
    var agentDecisionsEnabled = true
    var armedRuleCount = 2
    var held: [MCPPausedRequest] = []
    var decisions: [MCPBreakpointDecision] = []
    var failure: MCPWriteError?

    func pausedRequests() -> [MCPPausedRequest] { held }

    func decide(_ decision: MCPBreakpointDecision) throws -> MCPBreakpointOutcome {
        decisions.append(decision)
        if let failure { throw failure }
        guard let request = held.first(where: { $0.id == decision.id }) else {
            throw MCPWriteError.notFound("no such held request")
        }
        return MCPBreakpointOutcome(
            id: request.id,
            action: decision.action,
            host: request.host,
            method: request.method,
            url: request.url,
            summary: MCPBreakpointValidation.summary(for: decision, request: request)
        )
    }
}

/// A query token no shape pass can see — no vendor prefix, not a JWT, under
/// the 24 characters the export's entropy pass needs. Only redaction by NAME
/// (`access_token`) catches it, which is what the live leak (F15) needed.
private let shortQuerySecret = "short-secret-42"

private func heldRequest(
    id: String = "held-1",
    host: String = "api.example.com",
    method: String = "POST",
    target: String = "/v1/orders?access_token=\(shortQuerySecret)&page=2",
    headers: [MCPHeaderPair] = [
        MCPHeaderPair(name: "Authorization", value: "Bearer secret-token-value"),
        MCPHeaderPair(name: "Content-Type", value: "application/json"),
    ],
    bodyPreview: String? = #"{"sku":"A-1"}"#,
    bodyByteCount: Int = 13,
    bodyTruncated: Bool = false,
    bodyExpected: Bool? = nil,
    declaredBodyLength: Int? = nil,
    secondsRemaining: Int = 47
) -> MCPPausedRequest {
    MCPPausedRequest(
        id: id,
        host: host,
        method: method,
        url: "https://\(host)\(target)",
        path: target,
        headers: headers,
        bodyPreview: bodyPreview,
        bodyByteCount: bodyByteCount,
        bodyTruncated: bodyTruncated,
        bodyExpected: bodyExpected,
        declaredBodyLength: declaredBodyLength,
        secondsRemaining: secondsRemaining
    )
}

/// A TRACE as the core holds it over HTTP/1.1: no framing header, so no body
/// follows (`bodyExpected == false`).
private func heldTrace() -> MCPPausedRequest {
    heldRequest(method: "TRACE", target: "/v1/orders", headers: [MCPHeaderPair(name: "Accept", value: "*/*")],
                bodyPreview: nil, bodyByteCount: 0, bodyExpected: false)
}

/// A TRACE that arrives with a body of its own (`Content-Length: 5`): the
/// core reads (true, 5), and over HTTP/1.1 refuses to forward it on resume.
private func heldTraceWithABody() -> MCPPausedRequest {
    heldRequest(id: "held-trace-body", method: "TRACE", target: "/v1/orders",
                headers: [MCPHeaderPair(name: "Content-Length", value: "5")],
                bodyPreview: nil, bodyByteCount: 0, bodyExpected: true, declaredBodyLength: 5)
}

// MARK: - Validation

final class MCPBreakpointValidationTests: XCTestCase {
    func testAnAbortCarryingEditsIsRefused() {
        // Editing a request that is never sent is a contradiction, and
        // silently ignoring the edits would let an agent believe it had
        // changed something.
        let decision = MCPBreakpointDecision(
            id: "held-1", action: .abort, setHeaders: ["X-Debug": "1"]
        )
        XCTAssertThrowsError(try MCPBreakpointValidation.validate(decision))
    }

    func testAbortStatusMustBeAnError() throws {
        try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "a", action: .abort, abortStatus: 503)
        )
        // A 200 abort tells the app's own code that something it never did
        // has succeeded — a worse lie than any error code.
        for status in [200, 204, 302, 99, 600] {
            XCTAssertThrowsError(
                try MCPBreakpointValidation.validate(
                    MCPBreakpointDecision(id: "a", action: .abort, abortStatus: status)
                ),
                "\(status) should not be offered as an abort status"
            )
        }
    }

    func testAbortStatusOnAResumeIsRefused() {
        XCTAssertThrowsError(try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "a", action: .resume, abortStatus: 500)
        ))
    }

    /// The guard that matters most on this surface: a header value carrying
    /// CR/LF ends the header block early and the rest is read as another
    /// request. Checked on unicode scalars because Swift folds "\r\n" into ONE
    /// Character, so a Character-level search for "\n" misses it.
    func testARequestSplittingHeaderIsRefused() {
        for value in ["a\r\nGET /admin HTTP/1.1", "a\nb", "a\rb"] {
            XCTAssertThrowsError(try MCPBreakpointValidation.validate(
                MCPBreakpointDecision(id: "a", action: .resume, setHeaders: ["X-Evil": value])
            ), "a value containing \(value.debugDescription) must not be sendable")
        }
        XCTAssertThrowsError(try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "a", action: .resume, setHeaders: ["X-Evil\r\nInjected": "b"])
        ))
    }

    func testAHeaderNameWithAColonOrSpaceIsRefused() {
        XCTAssertThrowsError(try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "a", action: .resume, setHeaders: ["X-Evil: injected": "b"])
        ))
        XCTAssertThrowsError(try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "a", action: .resume, setHeaders: ["X Evil": "b"])
        ))
        XCTAssertThrowsError(try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "a", action: .resume, setHeaders: ["   ": "b"])
        ))
    }

    func testAnOversizedReplacementBodyIsRefused() {
        let body = String(repeating: "x", count: MCPBreakpointValidation.maxBodyBytes + 1)
        XCTAssertThrowsError(try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "a", action: .resume, body: body)
        ))
        XCTAssertNoThrow(try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "a", action: .resume,
                                  body: String(repeating: "x", count: MCPBreakpointValidation.maxBodyBytes))
        ))
    }

    func testAnEmptyIdIsRefusedBeforeAnythingElse() {
        XCTAssertThrowsError(try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "  ", action: .resume)
        ))
    }

    /// A TRACE may not carry a body, and over HTTP/1.1 the core answers one
    /// that has a body 502 instead of forwarding it (core 5efe7aa). The
    /// decision alone cannot know the method; the check runs once the held
    /// request is found — for any `body`, an empty one too.
    func testABodyForATraceIsRefusedOnceTheRequestIsKnown() {
        for body in ["TRACE me", ""] {
            let decision = MCPBreakpointDecision(id: "held-1", action: .resume, body: body)
            XCTAssertNoThrow(try MCPBreakpointValidation.validate(decision), "the decision alone is fine")
            XCTAssertThrowsError(try MCPBreakpointValidation.validate(decision, for: heldTrace())) { error in
                guard case MCPWriteError.invalid(let message) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(message, HeldRequestBody(heldTrace()).replacementRefusalForAgents)
                XCTAssertTrue(message.hasPrefix("A TRACE request may not carry a body, so `body` is refused for one"), message)
                XCTAssertTrue(message.hasSuffix(" Resume it without `body`."), message)
            }
            // A TRACE carrying a body of its own gets the same 502 when it is
            // resumed without one, so it is not told to resume: to abort.
            XCTAssertThrowsError(try MCPBreakpointValidation.validate(decision, for: heldTraceWithABody())) { error in
                guard case MCPWriteError.invalid(let message) = error else { return XCTFail("\(error)") }
                XCTAssertFalse(message.contains("Resume it without `body`"), message)
                XCTAssertTrue(message.hasSuffix(" This one declares a body of its own, so resumed over HTTP/1.1 it gets that 502 too: abort it to answer it here."), message)
            }
        }
        for decision in [
            MCPBreakpointDecision(id: "held-1", action: .resume),
            MCPBreakpointDecision(id: "held-1", action: .resume, setHeaders: ["X-Debug": "1"]),
            MCPBreakpointDecision(id: "held-1", action: .abort),
        ] {
            XCTAssertNoThrow(try MCPBreakpointValidation.validate(decision, for: heldTrace()), "\(decision)")
        }
        XCTAssertNoThrow(try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "held-1", action: .resume, body: "x"), for: heldRequest()
        ), "a POST may be given a body")
    }

    /// An empty patch is not an edit. It matters because the service resumes
    /// a request byte-for-byte when nothing changed, rather than round-tripping
    /// it through this app's idea of how headers are spelled.
    func testAnEmptyPatchIsNotAnEdit() {
        XCTAssertFalse(MCPBreakpointDecision(id: "a", action: .resume).editsAnything)
        XCTAssertFalse(MCPBreakpointDecision(id: "a", action: .resume, setHeaders: [:], removeHeaders: []).editsAnything)
        XCTAssertTrue(MCPBreakpointDecision(id: "a", action: .resume, setHeaders: ["A": "b"]).editsAnything)
        XCTAssertTrue(MCPBreakpointDecision(id: "a", action: .resume, removeHeaders: ["A"]).editsAnything)
        // An empty body IS an edit: "send this with no body" is a real thing
        // to want, and it differs from "send the original".
        XCTAssertTrue(MCPBreakpointDecision(id: "a", action: .resume, body: "").editsAnything)
    }
}

// MARK: - The header patch

final class MCPBreakpointHeaderPatchTests: XCTestCase {
    private let original = [
        MCPHeaderPair(name: "Host", value: "api.example.com"),
        MCPHeaderPair(name: "Authorization", value: "Bearer real"),
        MCPHeaderPair(name: "Cookie", value: "a=1"),
        MCPHeaderPair(name: "Cookie", value: "b=2"),
    ]

    func testSettingReplacesInPlaceAndKeepsEverythingElse() {
        let result = MCPBreakpointValidation.apply(
            setHeaders: ["Authorization": "Bearer edited"], removeHeaders: nil, to: original
        )

        XCTAssertEqual(result.map(\.name), ["Host", "Authorization", "Cookie", "Cookie"],
                       "order is the request's own, and untouched duplicates survive")
        XCTAssertEqual(result[1].value, "Bearer edited")
        XCTAssertEqual(result[2].value, "a=1")
        XCTAssertEqual(result[3].value, "b=2")
    }

    /// HTTP compares header names without case, so an agent setting
    /// "authorization" on a request carrying "Authorization" must replace it
    /// rather than leave the original in place with a second one beside it —
    /// which is the difference between changing a credential and sending two.
    func testNamesAreMatchedWithoutCase() {
        let result = MCPBreakpointValidation.apply(
            setHeaders: ["authorization": "Bearer edited"], removeHeaders: nil, to: original
        )

        XCTAssertEqual(result.filter { $0.name.lowercased() == "authorization" }.count, 1)
        XCTAssertEqual(result.first { $0.name.lowercased() == "authorization" }?.value, "Bearer edited")
    }

    /// "Set Cookie to this" cannot also mean "and keep the other Cookie".
    func testSettingANameThatAppearsTwiceLeavesOne() {
        let result = MCPBreakpointValidation.apply(
            setHeaders: ["Cookie": "session=new"], removeHeaders: nil, to: original
        )

        XCTAssertEqual(result.map(\.name), ["Host", "Authorization", "Cookie"])
        XCTAssertEqual(result.last?.value, "session=new")
    }

    func testRemovingDropsEveryCopyRegardlessOfCase() {
        let result = MCPBreakpointValidation.apply(
            setHeaders: nil, removeHeaders: ["cookie"], to: original
        )

        XCTAssertEqual(result.map(\.name), ["Host", "Authorization"])
    }

    func testAddedHeadersGoOnTheEndInAStableOrder() {
        let result = MCPBreakpointValidation.apply(
            setHeaders: ["X-Trace": "1", "X-Debug": "2", "X-Mode": "3"], removeHeaders: nil, to: original
        )

        // A Swift dictionary has no order; a request whose headers shuffle
        // between runs is one nobody can debug.
        XCTAssertEqual(Array(result.suffix(3)).map(\.name), ["X-Debug", "X-Mode", "X-Trace"])
        XCTAssertEqual(Array(result.prefix(4)), original)
    }

    func testRemovingAndSettingTheSameNameEndsWithItSet() {
        // Ambiguous input, and the useful reading is the one that leaves the
        // request usable rather than silently stripping a header the agent
        // also gave a value for.
        let result = MCPBreakpointValidation.apply(
            setHeaders: ["Authorization": "Bearer edited"], removeHeaders: ["Authorization"], to: original
        )

        XCTAssertEqual(result.first { $0.name == "Authorization" }?.value, "Bearer edited")
    }

    func testAnEmptyPatchChangesNothingAtAll() {
        XCTAssertEqual(
            MCPBreakpointValidation.apply(setHeaders: nil, removeHeaders: nil, to: original),
            original
        )
    }
}

// MARK: - Routing

final class MCPBreakpointRouterTests: XCTestCase {
    private let token = "test-token"
    private var breakpoints: StubBreakpoints!
    private var audit: StubAudit!
    private var consent: StubConsent!

    override func setUp() {
        super.setUp()
        breakpoints = StubBreakpoints()
        audit = StubAudit()
        consent = StubConsent()
    }

    private func makeRouter(redactor: MCPRedactor = MCPRedactor()) -> MCPBridgeRouter {
        MCPBridgeRouter(
            token: token,
            sessions: StubSessionProvider(),
            status: StubStatusProvider(),
            redactor: redactor,
            writes: MCPWriteSeams(
                rules: StubRuleProvider(),
                hosts: StubHostProvider(),
                capture: StubCaptureController(),
                consent: consent,
                audit: audit,
                breakpoints: breakpoints
            )
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

    private func decide(_ router: MCPBridgeRouter, _ object: [String: Any]) throws -> ParsedResponse {
        try send(router, "POST", "/v1/breakpoints/decide", body: try JSONSerialization.data(withJSONObject: object))
    }

    // MARK: Reading

    func testListingHeldRequestsCarriesTheContextAnEmptyListNeeds() throws {
        breakpoints.held = []
        breakpoints.armedRuleCount = 0
        let response = try send(makeRouter(), "GET", "/v1/breakpoints/paused")

        XCTAssertEqual(response.status, 200)
        let page = try JSONDecoder().decode(MCPPausedRequestPage.self, from: response.body)
        XCTAssertTrue(page.requests.isEmpty)
        XCTAssertEqual(page.armedRules, 0, "an empty list has to be able to explain itself")
    }

    /// A held request is live traffic and leaves through the same redactor as
    /// everything else. Nothing about stopping a request makes its
    /// Authorization header safe to hand to a model.
    func testAHeldRequestIsRedactedOnTheWayOut() throws {
        breakpoints.held = [heldRequest()]
        let response = try send(makeRouter(), "GET", "/v1/breakpoints/paused")

        let page = try JSONDecoder().decode(MCPPausedRequestPage.self, from: response.body)
        let authorization = try XCTUnwrap(page.requests.first?.headers.first { $0.name == "Authorization" })
        XCTAssertNotEqual(authorization.value, "Bearer secret-token-value")
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("secret-token-value"))
    }

    // MARK: Deciding

    /// The grant is a setting, not a panel — but a refusal is still recorded,
    /// because "an agent tried to answer a held request while this was off" is
    /// exactly what the activity log exists to show.
    func testWithoutTheGrantADecisionIsRefusedAndLogged() throws {
        breakpoints.agentDecisionsEnabled = false
        breakpoints.held = [heldRequest()]

        let response = try decide(makeRouter(), ["id": "held-1", "action": "resume"])

        XCTAssertEqual(response.status, 403)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("consent_denied"))
        XCTAssertEqual(audit.entries.last?.outcome, .denied)
        XCTAssertTrue(breakpoints.decisions.isEmpty, "nothing may reach the service while the grant is off")
    }

    /// The deliberate exception to "every write asks": a per-call approval can
    /// take 45s and the request is gone at 60.
    func testWithTheGrantTheApprovalPanelIsNeverAsked() throws {
        breakpoints.held = [heldRequest()]

        let response = try decide(makeRouter(), ["id": "held-1", "action": "resume"])

        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(consent.asked.isEmpty, "a breakpoint decision must not wait on a panel")
        XCTAssertEqual(audit.entries.last?.outcome, .performed, "…but it is still audited")
        XCTAssertEqual(audit.entries.last?.action.kind, .answerPausedRequest)
    }

    func testTheAuditRowNamesTheRequestAndWhatWasDoneToIt() throws {
        breakpoints.held = [heldRequest()]

        _ = try decide(makeRouter(), [
            "id": "held-1", "action": "resume", "setHeaders": ["X-Debug": "1"], "removeHeaders": ["Cookie"],
        ])

        let entry = try XCTUnwrap(audit.entries.last)
        let text = ([entry.action.summary] + entry.action.details).joined(separator: " ")
        XCTAssertTrue(text.contains("api.example.com"), "got: \(text)")
        XCTAssertTrue(text.contains("X-Debug"), "the values are what make an edit worth reading: \(text)")
        XCTAssertTrue(text.contains("Cookie"), "got: \(text)")
    }

    /// The normal case after a minute, not an error condition — the request
    /// has already gone to the server untouched.
    func testAnExpiredIdIsA404ThatSaysWhat() throws {
        breakpoints.held = []

        let response = try decide(makeRouter(), ["id": "held-gone", "action": "resume"])

        XCTAssertEqual(response.status, 404)
        let message = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(message.contains("list_paused_requests"), "got: \(message)")
        XCTAssertTrue(breakpoints.decisions.isEmpty)
    }

    func testBadInputIsRefusedBeforeTheServiceSeesIt() throws {
        breakpoints.held = [heldRequest()]

        let response = try decide(makeRouter(), ["id": "held-1", "action": "abort", "abortStatus": 200])

        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(breakpoints.decisions.isEmpty)
    }

    /// A body for a held TRACE is bad input: 400, nothing sent to the
    /// service and nothing recorded — the request stays held, and resumes as
    /// it is when answered without one.
    func testABodyForAHeldTraceIsRefusedBeforeAnythingIsRecorded() throws {
        breakpoints.held = [heldTrace()]

        let response = try decide(makeRouter(), ["id": "held-1", "action": "resume", "body": "hello"])

        XCTAssertEqual(response.status, 400)
        let message = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(message.contains("A TRACE request may not carry a body"), message)
        XCTAssertTrue(breakpoints.decisions.isEmpty)
        XCTAssertTrue(audit.entries.isEmpty, "refused like bad input, before the activity log")

        XCTAssertEqual(try decide(makeRouter(), ["id": "held-1", "action": "resume"]).status, 200)
        XCTAssertEqual(breakpoints.decisions.count, 1)
    }

    /// Content-Length and Transfer-Encoding are ReqRes's to set: a patch
    /// naming either is refused before the service sees it, instead of
    /// accepted, logged as "Headers set — Content-Length: 5" and overridden
    /// by the core.
    func testAPatchNamingFramingIsRefusedBeforeTheServiceSeesIt() throws {
        breakpoints.held = [heldRequest()]

        for decision: [String: Any] in [
            ["id": "held-1", "action": "resume", "setHeaders": ["Content-Length": "5"]],
            ["id": "held-1", "action": "resume", "removeHeaders": ["Transfer-Encoding"], "body": "{}"],
        ] {
            let response = try decide(makeRouter(), decision)
            XCTAssertEqual(response.status, 400, "\(decision)")
            let message = String(decoding: response.body, as: UTF8.self)
            XCTAssertTrue(message.contains("are not yours to set or remove"), message)
        }
        XCTAssertTrue(breakpoints.decisions.isEmpty)
        XCTAssertTrue(audit.entries.isEmpty)
    }

    /// The core's reading of the head (35dd624) reaches the agent through
    /// the redactor and the wire: an HTTP/2 POST without content-length (a
    /// body follows) and an HTTP/1.1 GET (none does) carry the same nothing
    /// in their headers.
    func testTheListingSaysWhatTheCoreReadInTheHead() throws {
        breakpoints.held = [
            heldRequest(id: "held-h2", headers: [MCPHeaderPair(name: "content-type", value: "application/json")],
                        bodyPreview: nil, bodyByteCount: 0, bodyExpected: true),
            heldRequest(id: "held-get", method: "GET", headers: [MCPHeaderPair(name: "Accept", value: "*/*")],
                        bodyPreview: nil, bodyByteCount: 0, bodyExpected: false),
            heldRequest(id: "held-76", headers: [MCPHeaderPair(name: "Content-Length", value: "76")],
                        bodyPreview: nil, bodyByteCount: 0, bodyExpected: true, declaredBodyLength: 76),
        ]
        let response = try send(makeRouter(), "GET", "/v1/breakpoints/paused")
        let page = try JSONDecoder().decode(MCPPausedRequestPage.self, from: response.body)

        XCTAssertEqual(page.requests.map(\.bodyExpected), [true, false, true])
        XCTAssertEqual(page.requests.map(\.declaredBodyLength), [nil, nil, 76])
        let text = MCPTextFormat.pausedRequests(page)
        XCTAssertTrue(text.contains("  body: size not declared (HTTP/2), not shown — resume without `body` to send it unchanged"), text)
        XCTAssertTrue(text.contains("  body: empty (no Content-Length or Transfer-Encoding)"), text)
        XCTAssertTrue(text.contains("  body: 76 bytes (Content-Length), not shown — resume without `body` to send it unchanged"), text)
    }

    /// A held TRACE carrying a body of its own reaches the agent with the
    /// line that says what resuming it does over HTTP/1.1 — never "resume
    /// without `body` to send it unchanged" — and a body for it is refused
    /// with the advice to abort, before anything is recorded.
    func testAHeldTraceWithItsOwnBodyIsNotPromisedToGoUnchanged() throws {
        breakpoints.held = [heldTraceWithABody()]
        let response = try send(makeRouter(), "GET", "/v1/breakpoints/paused")
        let page = try JSONDecoder().decode(MCPPausedRequestPage.self, from: response.body)
        let text = MCPTextFormat.pausedRequests(page)
        XCTAssertTrue(text.contains("  body: 5 bytes (Content-Length), not shown — a TRACE may not carry a body: resumed over HTTP/1.1, "
                                    + "this one is answered 502 by ReqRes instead of being forwarded; abort answers it here"), text)
        XCTAssertFalse(text.contains("to send it unchanged"), text)

        let refused = try decide(makeRouter(), ["id": "held-trace-body", "action": "resume", "body": "x"])
        XCTAssertEqual(refused.status, 400)
        XCTAssertTrue(String(decoding: refused.body, as: UTF8.self).contains("abort it to answer it here"))
        XCTAssertTrue(breakpoints.decisions.isEmpty)
        XCTAssertTrue(audit.entries.isEmpty)
    }

    func testAFailureFromTheServiceIsReportedAndLogged() throws {
        breakpoints.held = [heldRequest()]
        breakpoints.failure = .invalid("that body is the truncated preview")

        let response = try decide(makeRouter(), ["id": "held-1", "action": "resume", "body": "x"])

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(audit.entries.last?.outcome, .failed)
    }

    // MARK: Redaction of the answer (F15)

    /// Resume untouched, abort, resume with an edit: the three sentences the
    /// app writes about a decision, each quoting the held URL.
    private let decisions: [[String: Any]] = [
        ["id": "held-1", "action": "resume"],
        ["id": "held-1", "action": "abort"],
        ["id": "held-1", "action": "resume", "setHeaders": ["X-Debug": "1"]],
    ]

    /// The listing masked the held URL's token and the reply to answering it
    /// did not — measured live on build 51, `?access_token=VERIFYtok3n42`
    /// verbatim in answer_paused_request's reply, right after the agent had
    /// read it redacted.
    func testTheDecisionReplyIsRedactedLikeTheListing() throws {
        for decision in decisions {
            breakpoints.held = [heldRequest()]
            let response = try decide(makeRouter(), decision)

            XCTAssertEqual(response.status, 200, "\(decision)")
            let raw = String(decoding: response.body, as: UTF8.self)
            XCTAssertFalse(raw.contains(shortQuerySecret), "\(decision) leaks the token: \(raw)")
            let outcome = try JSONDecoder().decode(MCPBreakpointOutcome.self, from: response.body)
            XCTAssertEqual(outcome.url, "https://api.example.com/v1/orders?access_token=REDACTED&page=2",
                           "the name is kept and only its value masked; the rest of the query stays")
            XCTAssertTrue(outcome.summary.contains("access_token=REDACTED&page=2"), outcome.summary)
            XCTAssertFalse(MCPTextFormat.decision(outcome).contains(shortQuerySecret), "what the helper prints")
        }
    }

    /// The activity entry kept that sentence as its result line, raw — and
    /// the entry is persisted to UserDefaults and carried into Export…, whose
    /// own pass has no URL step and cannot see a token this short.
    func testTheActivityResultLineIsRedacted() throws {
        for decision in decisions {
            breakpoints.held = [heldRequest()]
            _ = try decide(makeRouter(), decision)

            let entry = try XCTUnwrap(audit.entries.last)
            XCTAssertEqual(entry.outcome, .performed)
            let detail = try XCTUnwrap(entry.detail)
            XCTAssertFalse(detail.contains(shortQuerySecret), "\(decision): \(detail)")
            XCTAssertTrue(detail.contains("access_token=REDACTED"), detail)
        }
        let persisted = String(decoding: try JSONEncoder().encode(audit.entries), as: UTF8.self)
        XCTAssertFalse(persisted.contains(shortQuerySecret), "what MCPAgentActivity writes to UserDefaults")
        for export in [MCPAuditExport.text(audit.entries), MCPAuditExport.json(audit.entries)] {
            XCTAssertFalse(export.content.contains(shortQuerySecret), export.content)
        }
    }

    /// `path` carries the same query string as `url` and was never redacted.
    /// The bundled helper prints only `url`, so the live run did not show
    /// it — but every client reading the bridge JSON got the token.
    func testAHeldRequestsPathIsRedactedToo() throws {
        breakpoints.held = [heldRequest()]
        let response = try send(makeRouter(), "GET", "/v1/breakpoints/paused")

        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains(shortQuerySecret))
        let page = try JSONDecoder().decode(MCPPausedRequestPage.self, from: response.body)
        XCTAssertEqual(page.requests.first?.path, "/v1/orders?access_token=REDACTED&page=2")
        XCTAssertEqual(page.requests.first?.url, "https://api.example.com/v1/orders?access_token=REDACTED&page=2")
    }

    /// A host the user excepted is shown raw to the agent — in the listing,
    /// so in the reply too, or the two would disagree about one request. The
    /// log is not an agent surface: it cannot tell whose line it holds, so it
    /// fails toward more redaction, as `MCPAuditExport` does.
    func testAnExceptedHostKeepsItsValuesInTheReplyButNotInTheLog() throws {
        breakpoints.held = [heldRequest()]
        let router = makeRouter(redactor: MCPRedactor(policy: MCPRedactionPolicy(exceptedHosts: ["api.example.com"])))

        let listing = try send(router, "GET", "/v1/breakpoints/paused")
        XCTAssertTrue(String(decoding: listing.body, as: UTF8.self).contains(shortQuerySecret), "excepted: the listing is raw")
        let reply = try decide(router, ["id": "held-1", "action": "resume"])
        let outcome = try JSONDecoder().decode(MCPBreakpointOutcome.self, from: reply.body)
        XCTAssertTrue(outcome.url.contains(shortQuerySecret), "…and the reply agrees with it")
        XCTAssertTrue(outcome.summary.contains(shortQuerySecret))

        let detail = try XCTUnwrap(audit.entries.last?.detail)
        XCTAssertFalse(detail.contains(shortQuerySecret), detail)
    }

    /// Every result line `performWrite` records goes through the log's
    /// sanitiser, a failure's message included — whatever seam wrote it.
    func testAFailuresMessageIsLoggedRedacted() throws {
        breakpoints.held = [heldRequest()]
        breakpoints.failure = .invalid("https://api.example.com/v1/orders?token=lateSecret7 could not be resumed.")

        let response = try decide(makeRouter(), ["id": "held-1", "action": "resume"])

        XCTAssertEqual(response.status, 400)
        let entry = try XCTUnwrap(audit.entries.last)
        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertFalse(entry.detail?.contains("lateSecret7") ?? true, entry.detail ?? "")
        XCTAssertTrue(entry.detail?.contains("token=REDACTED") ?? false, entry.detail ?? "")
    }

    /// F19: the core reports no body for a held request, so the size an agent
    /// can be told comes from the request's Content-Length — which has to
    /// survive the redactor to reach the listing.
    func testTheListingSaysWhatAHeldBodyDeclaresAfterRedaction() throws {
        breakpoints.held = [heldRequest(
            headers: [
                MCPHeaderPair(name: "Authorization", value: "Bearer secret-token-value"),
                MCPHeaderPair(name: "Content-Type", value: "application/json"),
                MCPHeaderPair(name: "Content-Length", value: "76"),
            ],
            bodyPreview: nil,
            bodyByteCount: 0
        )]
        let response = try send(makeRouter(), "GET", "/v1/breakpoints/paused")
        let page = try JSONDecoder().decode(MCPPausedRequestPage.self, from: response.body)

        let text = MCPTextFormat.pausedRequests(page)
        XCTAssertTrue(text.contains("  body: 76 bytes (Content-Length), not shown — resume without `body` to send it unchanged"), text)
        XCTAssertFalse(text.contains("secret-token-value"))
    }

    /// A build that never wired breakpoints answers 503 here and keeps every
    /// other write working — the same shape as export, replay and saved
    /// sessions.
    func testABuildWithoutBreakpointsSaysSoRatherThanFailing() throws {
        let router = MCPBridgeRouter(
            token: token,
            sessions: StubSessionProvider(),
            status: StubStatusProvider(),
            writes: MCPWriteSeams(
                rules: StubRuleProvider(),
                hosts: StubHostProvider(),
                capture: StubCaptureController(),
                consent: consent,
                audit: audit
            )
        )

        XCTAssertEqual(try send(router, "GET", "/v1/breakpoints/paused").status, 503)
        XCTAssertEqual(try decide(router, ["id": "a", "action": "resume"]).status, 503)
    }
}

// MARK: - What the agent reads

final class MCPBreakpointTextTests: XCTestCase {
    func testNothingHeldAndNothingArmedExplainsWhy() {
        let text = MCPTextFormat.pausedRequests(
            MCPPausedRequestPage(requests: [], armedRules: 0, agentDecisionsEnabled: true)
        )
        // "No requests are held" alone wastes the next turn: the user's
        // question is always why not, and the answer is nearly always this.
        XCTAssertTrue(text.contains("no breakpoint is armed"), "got: \(text)")
        XCTAssertTrue(text.contains("Settings"), "got: \(text)")
    }

    func testNothingHeldWithRulesArmedSaysItIsWaiting() {
        let text = MCPTextFormat.pausedRequests(
            MCPPausedRequestPage(requests: [], armedRules: 3, agentDecisionsEnabled: true)
        )
        XCTAssertTrue(text.contains("3 breakpoint rule"), "got: \(text)")
    }

    func testAHeldRequestShowsItsClockAndItsId() {
        let text = MCPTextFormat.pausedRequests(
            MCPPausedRequestPage(requests: [heldRequest()], armedRules: 1, agentDecisionsEnabled: true)
        )
        XCTAssertTrue(text.contains("held-1"), "got: \(text)")
        XCTAssertTrue(text.contains("47s left"), "the countdown is the thing to act on: \(text)")
    }

    /// Read-only is a state the agent must understand, or it will propose an
    /// action, call the tool, and report a failure the user could have been
    /// told about first.
    func testWithoutTheGrantTheListSaysReadOnly() {
        let text = MCPTextFormat.pausedRequests(
            MCPPausedRequestPage(requests: [heldRequest()], armedRules: 1, agentDecisionsEnabled: false)
        )
        XCTAssertTrue(text.contains("not allowed"), "got: \(text)")
    }

    /// F19: every held request gets a body line. The core holds a request at
    /// its head and sends no preview and a count of 0 — for a POST with a body
    /// as much as for a GET — and the listing printed no body line for it,
    /// which read as "this request has no body".
    func testEveryHeldRequestPrintsABodyLine() {
        let posted = heldRequest(
            headers: [MCPHeaderPair(name: "Content-Type", value: "application/json"),
                      MCPHeaderPair(name: "Content-Length", value: "76")],
            bodyPreview: nil,
            bodyByteCount: 0
        )
        let undeclared = heldRequest(id: "held-2", headers: [], bodyPreview: nil, bodyByteCount: 0)
        let text = MCPTextFormat.pausedRequests(
            MCPPausedRequestPage(requests: [posted, undeclared], armedRules: 1, agentDecisionsEnabled: true)
        )

        XCTAssertTrue(text.contains("  body: 76 bytes (Content-Length), not shown — resume without `body` to send it unchanged"), text)
        XCTAssertTrue(text.contains("  body: not shown; the request has no Content-Length or Transfer-Encoding"), text)
        XCTAssertEqual(text.components(separatedBy: "\n  body").count - 1, 2, "one body line per request: \(text)")
        XCTAssertFalse(text.contains("none)"), text)
    }

    /// An app (or a bridge) older than the core's body fields sends neither
    /// key: the request still decodes, and its body line falls back to the
    /// headers.
    func testAPayloadWithoutTheCoresFieldsStillDecodes() throws {
        let json = #"{"id":"a","host":"h","method":"POST","url":"https://h/","path":"/","headers":[{"name":"Content-Length","value":"76"}],"bodyByteCount":0,"bodyTruncated":false,"secondsRemaining":5}"#
        let request = try JSONDecoder().decode(MCPPausedRequest.self, from: Data(json.utf8))

        XCTAssertNil(request.bodyExpected)
        XCTAssertNil(request.declaredBodyLength)
        let text = MCPTextFormat.pausedRequests(MCPPausedRequestPage(requests: [request], armedRules: 1, agentDecisionsEnabled: true))
        XCTAssertTrue(text.contains("  body: 76 bytes (Content-Length), not shown"), text)
    }

    /// Sending a truncated preview back as the body would drop the rest of the
    /// upload, so the warning travels with the body rather than living in a
    /// tool description nobody re-reads.
    func testATruncatedBodyIsLabelledWhereItIsShown() {
        let text = MCPTextFormat.pausedRequests(
            MCPPausedRequestPage(
                requests: [heldRequest(bodyPreview: "{\"a\":1", bodyByteCount: 90_000, bodyTruncated: true)],
                armedRules: 1,
                agentDecisionsEnabled: true
            )
        )
        XCTAssertTrue(text.contains("TRUNCATED"), "got: \(text)")
    }
}
