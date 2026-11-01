//
//  MCPBridgeClientDiffAndCollectTests.swift
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
//  `MCPBridgeClientTests` never drives a real URLSession round trip — every
//  test there calls `MCPBridgeClient.decode` directly on raw bytes, so there
//  is no existing HTTP-transport stub to copy. What IS already there is the
//  seam the class was built with: `MCPBridgeClient.init(handshake:session:…)`
//  accepts any `URLSession`. This file uses that seam, not a second one: a
//  `URLProtocol` registered on a private `URLSessionConfiguration` handed to
//  that same initializer.
//
//  `diffSessions` fetches both sides with `async let` so the two GETs overlap
//  instead of doubling an agent's wait. That overlap is NOT asserted here: a
//  barrier-based test was written first and removed, because a probe showed
//  two plainly concurrent requests never reach this URLProtocol stub at the
//  same time. URLSession serialises the protocol callbacks, so the barrier
//  measured the harness and failed however the client was written. What is
//  asserted is that both sides are fetched and diffed.
//
//  `waitForSessions`'s ordering/exclusion/settle/cap behaviour already has
//  exhaustive, instant, clock-injected coverage in
//  `MCPSessionCollectorTests` — what these tests check is the WIRING: that
//  the client really calls `/v1/sessions` and feeds its real JSON response
//  into that algorithm. `waitForSessions` has no pollInterval override, so
//  settling for real costs real time here (`MCPSessionWaiter.
//  defaultPollInterval`, 0.75s per poll) — deliberate, not a leftover from a
//  slow implementation; timeouts below are kept just long enough for one or
//  two real polls.
//

import Dispatch
import Foundation
import XCTest
@testable import MCPKit

final class MCPBridgeClientDiffAndCollectTests: XCTestCase {
    private let handshake = MCPHandshake(port: 8123, token: "tok-123")

    override func tearDown() {
        // Belt-and-braces: every test also clears this itself, but a failure
        // partway through a test must not leak a stale handler into the next one.
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - diffSessions: both sides are fetched

    /// `diffSessions` must request BOTH sessions and diff them, not fetch one
    /// and compare it against itself. Would fail if a refactor dropped one
    /// side, which is easy to do when the two fetches look almost identical.
    ///
    /// What this deliberately does NOT assert is that the two fetches overlap.
    /// The implementation uses `async let` for both, because two round trips
    /// back to back doubled the latency of what an agent experiences as one
    /// question. A barrier-based test for that was written first and removed:
    /// a probe proved that two plainly concurrent `session.data(from:)` calls
    /// never reach this URLProtocol stub at the same time, because URLSession
    /// serialises the protocol callbacks. The barrier was therefore measuring
    /// the harness and failed no matter how the client was written.
    func testDiffSessionsFetchesBothSidesAndDiffsThem() async throws {
        let detailA = MCPSessionDetail(summary: makeSession(uid: "s1", statusCode: 200))
        let detailB = MCPSessionDetail(summary: makeSession(uid: "s2", statusCode: 500))
        let bodyA = try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, detailA))).body
        let bodyB = try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, detailB))).body

        let requested = Locked<[String]>([])
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requested.mutate { $0.append(path) }
            switch path {
            case "/v1/sessions/s1": return (200, bodyA)
            case "/v1/sessions/s2": return (200, bodyB)
            default: throw StubURLProtocol.StubFailure()
            }
        }
        defer { StubURLProtocol.handler = nil }

        let client = MCPBridgeClient(handshake: handshake, session: StubURLProtocol.makeStubbedSession())
        let diff = try await client.diffSessions("s1", "s2")

        XCTAssertEqual(diff.uidA, "s1")
        XCTAssertEqual(diff.uidB, "s2")
        XCTAssertEqual(
            Set(requested.value),
            ["/v1/sessions/s1", "/v1/sessions/s2"],
            "both sides must be fetched"
        )
        XCTAssertEqual(diff.statusCode?.before, 200)
        XCTAssertEqual(diff.statusCode?.after, 500)
    }

    // MARK: - diffSessions: failure propagation

    func testDiffSessionsPropagatesATransportFailureFromEitherSide() async throws {
        // A `try?` on either side (returning a placeholder instead of
        // re-throwing) would let this return a "half diff" — e.g. s1 diffed
        // against an empty stand-in for s2 — which reads as real evidence of
        // a change instead of "the comparison could not be made". Checked
        // with EACH side failing in turn, since a fix that only propagates
        // the first `async let`'s error and swallows the second would still
        // pass a test that only ever failed one specific side.
        let detailA = MCPSessionDetail(summary: makeSession(uid: "s1"))
        let detailB = MCPSessionDetail(summary: makeSession(uid: "s2"))
        let bodyA = try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, detailA))).body
        let bodyB = try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, detailB))).body

        for failingUID in ["s1", "s2"] {
            StubURLProtocol.handler = { request in
                switch request.url?.path {
                case "/v1/sessions/\(failingUID)": throw StubURLProtocol.StubFailure()
                case "/v1/sessions/s1": return (200, bodyA)
                case "/v1/sessions/s2": return (200, bodyB)
                default: throw StubURLProtocol.StubFailure()
                }
            }
            defer { StubURLProtocol.handler = nil }

            let client = MCPBridgeClient(handshake: handshake, session: StubURLProtocol.makeStubbedSession())
            do {
                _ = try await client.diffSessions("s1", "s2")
                XCTFail("expected diffSessions to throw when \(failingUID) fails")
            } catch is MCPBridgeClient.ClientError {
                // Expected: the failing side's transport error surfaces as a
                // thrown ClientError rather than being absorbed into a diff.
            }
        }
    }

    // MARK: - waitForSessions: wiring onto the real /v1/sessions endpoint

    func testWaitForSessionsReturnsNewMatchesInCapturedOrderOverHTTP() async throws {
        let stub = SessionsPageStub(pages: [
            [],
            [makeSession(uid: "c"), makeSession(uid: "b"), makeSession(uid: "a")],
        ])
        let queries = QueryRecorder()

        StubURLProtocol.handler = { request in
            if request.url?.path == "/v1/sessions/watched" { return try emptyWatchedPage() }
            guard request.url?.path == "/v1/sessions" else { throw StubURLProtocol.StubFailure() }
            queries.record(request.url?.query ?? "")
            let page = MCPSessionPage(sessions: stub.nextPage(), nextCursor: nil, totalMatched: 0, note: nil)
            return (200, try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, page))).body)
        }
        defer { StubURLProtocol.handler = nil }

        let client = MCPBridgeClient(handshake: handshake, session: StubURLProtocol.makeStubbedSession())
        let outcome = try await client.waitForSessions(filter: MCPSessionFilter(), timeout: 5, settleInterval: 0.2)

        // Store order is newest-first ("c" first); the requests actually
        // fired a, then b, then c, and that is the order an agent needs back.
        XCTAssertEqual(outcome.sessions.map(\.uid), ["a", "b", "c"])
        XCTAssertEqual(outcome.stopReason, .settled)
        XCTAssertTrue(
            queries.all.allSatisfy { $0.contains("limit=\(MCPLimits.maxPageSize)") },
            "expected every poll to ask for the max page size, got \(queries.all)"
        )
    }

    func testWaitForSessionFollowsARowTheNewestPageNoLongerHoldsOverHTTP() async throws {
        // The newest page never shows the stream (later traffic pushed it
        // out); only the watched read does — first in flight, then, once the
        // wait names it, finished in place.
        var inFlight = makeSession(uid: "stream", statusCode: nil)
        inFlight.live = MCPLiveState(phase: .streaming, responseBytes: 10)
        let finished = makeSession(uid: "stream")
        let watchedQueries = Locked<[String]>([])

        StubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sessions":
                let page = MCPSessionPage(sessions: [makeSession(uid: "newer")], nextCursor: nil, totalMatched: 1, note: nil)
                return (200, try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, page))).body)
            case "/v1/sessions/watched":
                let query = request.url?.query ?? ""
                watchedQueries.mutate { $0.append(query) }
                let row = watchedQueries.value.count >= 3 && query.contains("stream") ? finished : inFlight
                let page = MCPSessionPage(sessions: [row], nextCursor: nil, totalMatched: 1, note: nil)
                return (200, try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, page))).body)
            default:
                throw StubURLProtocol.StubFailure()
            }
        }
        defer { StubURLProtocol.handler = nil }

        let client = MCPBridgeClient(handshake: handshake, session: StubURLProtocol.makeStubbedSession())
        let outcome = try await client.waitForSession(filter: MCPSessionFilter(urlContains: "/resource/stream"), timeout: 5)
        XCTAssertEqual(outcome.session?.uid, "stream")
        XCTAssertEqual(outcome.session?.isInFlight, false)
        XCTAssertTrue(watchedQueries.value.dropFirst().allSatisfy { $0.contains("uids=stream") },
                      "every poll after the baseline names the row it follows, got \(watchedQueries.value)")
    }

    func testWaitForSessionsExcludesSessionsThatExistedBeforeTheCallOverHTTP() async throws {
        // The match is already present on the very first (baseline) fetch —
        // if the client fed that fetch's results into the match set instead
        // of using it only to seed "already seen", a session left over from
        // an earlier repro would satisfy a wait it has nothing to do with.
        let existing = [makeSession(uid: "old", host: "api.example.com")]
        let stub = SessionsPageStub(pages: [existing, existing, existing])

        StubURLProtocol.handler = { request in
            if request.url?.path == "/v1/sessions/watched" { return try emptyWatchedPage() }
            guard request.url?.path == "/v1/sessions" else { throw StubURLProtocol.StubFailure() }
            let page = MCPSessionPage(sessions: stub.nextPage(), nextCursor: nil, totalMatched: 0, note: nil)
            return (200, try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, page))).body)
        }
        defer { StubURLProtocol.handler = nil }

        let client = MCPBridgeClient(handshake: handshake, session: StubURLProtocol.makeStubbedSession())
        let outcome = try await client.waitForSessions(
            filter: MCPSessionFilter(host: "api.example.com"),
            timeout: 1,
            settleInterval: 0.2
        )

        XCTAssertTrue(outcome.sessions.isEmpty)
        XCTAssertEqual(outcome.stopReason, .timedOut)
    }

    func testWaitForSessionsRespectsTheCountCapOverHTTP() async throws {
        // Three matches land on one poll; a cap of two must cut the third,
        // not just report more than it promised.
        let stub = SessionsPageStub(pages: [
            [],
            [makeSession(uid: "c"), makeSession(uid: "b"), makeSession(uid: "a")],
        ])

        StubURLProtocol.handler = { request in
            if request.url?.path == "/v1/sessions/watched" { return try emptyWatchedPage() }
            guard request.url?.path == "/v1/sessions" else { throw StubURLProtocol.StubFailure() }
            let page = MCPSessionPage(sessions: stub.nextPage(), nextCursor: nil, totalMatched: 0, note: nil)
            return (200, try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, page))).body)
        }
        defer { StubURLProtocol.handler = nil }

        let client = MCPBridgeClient(handshake: handshake, session: StubURLProtocol.makeStubbedSession())
        let outcome = try await client.waitForSessions(
            filter: MCPSessionFilter(),
            maxCount: 2,
            timeout: 5,
            settleInterval: 5
        )

        XCTAssertEqual(outcome.sessions.map(\.uid), ["a", "b"])
        XCTAssertEqual(outcome.stopReason, .reachedCount)
    }

    // MARK: - destinations: the wiring

    /// `list_destinations` is `GET /v1/destinations` with `list_sessions`'
    /// query string and no paging; the report comes back decoded. The
    /// aggregation itself is covered in `MCPDestinationAggregationTests`.
    func testDestinationsCallsTheRouteWithTheSessionFilters() async throws {
        let report = MCPDestinationsReport(
            totalRequests: 2,
            destinations: [
                MCPDestinationSummary(
                    country: "US", name: "United States", requests: 2, bytes: 100, hostCount: 1, appCount: 1,
                    topHosts: [MCPCountedName(name: "api.stripe.com", requests: 2)],
                    topApps: [MCPCountedName(name: "claude", requests: 2)]
                ),
            ],
            note: MCPDestinationAggregation.note
        )
        let body = try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, report))).body
        let requested = Locked<[URL]>([])
        StubURLProtocol.handler = { request in
            if let url = request.url { requested.mutate { $0.append(url) } }
            return (200, body)
        }
        defer { StubURLProtocol.handler = nil }

        let client = MCPBridgeClient(handshake: handshake, session: StubURLProtocol.makeStubbedSession())
        let result = try await client.destinations(filter: MCPSessionFilter(app: "claude", country: "US"))

        XCTAssertEqual(result, report)
        let url = try XCTUnwrap(requested.value.first)
        XCTAssertEqual(url.path, "/v1/destinations")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(byName["app"], "claude")
        XCTAssertEqual(byName["country"], "US")
        XCTAssertNil(byName["limit"], "the report is one page by construction")
        XCTAssertNil(byName["cursor"])
    }
}

// MARK: - Test doubles

/// `/v1/sessions/watched` with nothing in flight: what these fixtures'
/// bridge would answer to the waiters' second read per poll.
private func emptyWatchedPage() throws -> (Int, Data) {
    let page = MCPSessionPage(sessions: [], nextCursor: nil, totalMatched: 0, note: nil)
    return (200, try XCTUnwrap(parseRawResponse(MCPHTTPResponse.json(status: 200, page))).body)
}

/// A tiny thread-safe box: the URLProtocol stub's handler runs off the test
/// thread, so recording what it saw needs a lock rather than a bare array.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}


/// Serves canned pages to repeated GETs on `/v1/sessions`: one page per call,
/// then the last page forever — the same "one burst, then quiet" shape
/// `MCPSessionCollectorTests`' `Fixture` uses, but reached over a real HTTP
/// round trip. Accessed from whichever thread `URLProtocol` drives the stub
/// on, hence the lock.
private final class SessionsPageStub {
    private let lock = NSLock()
    private let pages: [[MCPSessionSummary]]
    private var index = 0

    init(pages: [[MCPSessionSummary]]) {
        self.pages = pages
    }

    func nextPage() -> [MCPSessionSummary] {
        lock.lock()
        defer { lock.unlock() }
        let page = pages[min(index, pages.count - 1)]
        index += 1
        return page
    }
}

/// Records each poll's raw query string for a post-hoc assertion, guarded for
/// the same reason as `SessionsPageStub` above.
private final class QueryRecorder {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Minimal `URLProtocol` stub. Registered only on the private
/// `URLSessionConfiguration` each test builds via `makeStubbedSession()` —
/// never globally — so it can never intercept traffic from an unrelated test.
private final class StubURLProtocol: URLProtocol {
    struct StubFailure: Error {}

    /// Set per test, cleared by that test's `defer` and by `tearDown`.
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: StubFailure())
            return
        }
        do {
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
