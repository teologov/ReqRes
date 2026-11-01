//
//  MCPSessionWaiterTests.swift
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

/// The waiter takes injected time and fetch, so these run instantly and
/// deterministically — no real sleeping, no live app.
final class MCPSessionWaiterTests: XCTestCase {
    /// Drives a scripted sequence of fetch results and a virtual clock.
    private final class Fixture {
        var pages: [[MCPSessionSummary]]
        var now: TimeInterval = 0
        private(set) var sleeps: [TimeInterval] = []
        private var index = 0

        init(pages: [[MCPSessionSummary]]) {
            self.pages = pages
        }

        func fetch() async throws -> [MCPSessionSummary] {
            defer { index += 1 }
            return pages[min(index, pages.count - 1)]
        }

        func sleep(_ interval: TimeInterval) async throws {
            sleeps.append(interval)
            now += interval
        }

        func elapsed() -> TimeInterval { now }
    }

    func testReturnsANewMatchingSession() async throws {
        // Baseline holds s1; s2 arrives on the next poll.
        let fixture = Fixture(pages: [
            [makeSession(uid: "s1", host: "api.example.com")],
            [makeSession(uid: "s2", host: "api.example.com"), makeSession(uid: "s1", host: "api.example.com")],
        ])
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(host: "api.example.com"),
            timeout: 10,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertEqual(outcome.session?.uid, "s2")
        XCTAssertFalse(outcome.timedOut)
    }

    func testIgnoresSessionsPresentAtTheBaseline() async throws {
        // s1 already matches, but it is not NEW — the waiter must keep waiting.
        let existing = [makeSession(uid: "s1", host: "api.example.com")]
        let fixture = Fixture(pages: [existing, existing, existing])
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(host: "api.example.com"),
            timeout: 2,
            pollInterval: 1,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertNil(outcome.session)
        XCTAssertTrue(outcome.timedOut)
    }

    func testSkipsNewSessionsThatDoNotMatchTheFilter() async throws {
        let fixture = Fixture(pages: [
            [],
            [makeSession(uid: "noise", host: "cdn.example.com")],
            [makeSession(uid: "target", host: "api.example.com"), makeSession(uid: "noise", host: "cdn.example.com")],
        ])
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(host: "api.example.com"),
            timeout: 10,
            pollInterval: 1,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertEqual(outcome.session?.uid, "target")
    }

    func testReturnsEarliestMatchWhenABurstArrivesTogether() async throws {
        // Fetch is newest-first; "first" and "second" both arrive in one poll.
        let fixture = Fixture(pages: [
            [],
            [makeSession(uid: "second", host: "api.example.com"), makeSession(uid: "first", host: "api.example.com")],
        ])
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(host: "api.example.com"),
            timeout: 10,
            pollInterval: 1,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        // The one the user triggered first is the useful answer.
        XCTAssertEqual(outcome.session?.uid, "first")
    }

    func testTimesOutWhenNothingArrives() async throws {
        let fixture = Fixture(pages: [[]])
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(),
            timeout: 3,
            pollInterval: 1,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertNil(outcome.session)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertGreaterThan(outcome.polls, 1)
    }

    func testTimeoutIsClampedToTheMaximum() async throws {
        let fixture = Fixture(pages: [[]])
        _ = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(),
            timeout: 10_000,
            pollInterval: 100,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertLessThanOrEqual(fixture.now, MCPSessionWaiter.maxTimeout + 100)
    }

    func testZeroTimeoutStillEstablishesBaselineWithoutSleeping() async throws {
        let fixture = Fixture(pages: [[makeSession(uid: "s1")]])
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(),
            timeout: 0,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(fixture.sleeps.count, 0)
    }

    func testWaitOutcomeTextGuidesTheAgent() {
        let found = MCPSessionWaiter.Outcome(session: makeSession(uid: "s9"), timedOut: false, polls: 3)
        XCTAssertTrue(MCPTextFormat.waitOutcome(found, timeout: 30).contains("uid=s9"))

        let missed = MCPSessionWaiter.Outcome(session: nil, timedOut: true, polls: 40)
        let text = MCPTextFormat.waitOutcome(missed, timeout: 30)
        XCTAssertTrue(text.contains("30s"))
        XCTAssertTrue(text.contains("capture_status"))
    }
}
