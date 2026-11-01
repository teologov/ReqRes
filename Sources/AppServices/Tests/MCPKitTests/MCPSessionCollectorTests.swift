//
//  MCPSessionCollectorTests.swift
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

/// Injected time and fetch, same as `MCPSessionWaiterTests` — these run
/// instantly and deterministically, no real sleeping, no live app.
final class MCPSessionCollectorTests: XCTestCase {
    /// Drives a scripted sequence of fetch results and a virtual clock. Once
    /// `pages` is exhausted, the last page repeats — a fixture can express
    /// "one burst, then quiet forever" without listing every empty poll.
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

    func testTimesOutWhenNothingMatchesWithinTheTimeout() async throws {
        let fixture = Fixture(pages: [[]])
        let outcome = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(),
            maxCount: 5,
            timeout: 3,
            settleInterval: 2,
            pollInterval: 1,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertTrue(outcome.sessions.isEmpty)
        XCTAssertEqual(outcome.stopReason, .timedOut)
        XCTAssertGreaterThan(outcome.polls, 1)
    }

    func testStopsAtTheSettleWindowAfterOneMatch() async throws {
        // s1 arrives on the first poll; every poll after that repeats the
        // same page (fixture clamps), so nothing NEW ever follows it.
        let fixture = Fixture(pages: [
            [],
            [makeSession(uid: "s1", host: "api.example.com")],
        ])
        let outcome = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(host: "api.example.com"),
            maxCount: 10,
            timeout: 10,
            settleInterval: 2,
            pollInterval: 1,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertEqual(outcome.sessions.map(\.uid), ["s1"])
        XCTAssertEqual(outcome.stopReason, .settled)
        // t=1 (match) -> t=2 (1s since match, keep going) -> t=3 (2s, settle).
        XCTAssertEqual(fixture.now, 3)
    }

    func testStopsWhenTheCountCapIsReached() async throws {
        // Three matches land in one poll; a cap of 2 must cut the third,
        // not just report more than it promised.
        let fixture = Fixture(pages: [
            [],
            [makeSession(uid: "c"), makeSession(uid: "b"), makeSession(uid: "a")],
        ])
        let outcome = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(),
            maxCount: 2,
            timeout: 10,
            settleInterval: 5,
            pollInterval: 1,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertEqual(outcome.sessions.map(\.uid), ["a", "b"])
        XCTAssertEqual(outcome.stopReason, .reachedCount)
    }

    func testReturnsBurstMatchesInCapturedOrder() async throws {
        // Fetch is newest-first ("c" is the newest); the requests actually
        // fired a, then b, then c, and the outcome must read that way.
        let fixture = Fixture(pages: [
            [],
            [makeSession(uid: "c"), makeSession(uid: "b"), makeSession(uid: "a")],
        ])
        let outcome = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(),
            maxCount: 10,
            timeout: 10,
            settleInterval: 2,
            pollInterval: 1,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertEqual(outcome.sessions.map(\.uid), ["a", "b", "c"])
        XCTAssertEqual(outcome.stopReason, .settled)
    }

    func testExcludesSessionsPresentAtTheBaseline() async throws {
        // The match is already there on the very first fetch, so it is not
        // NEW — a repro that reuses an old connection must not satisfy this.
        let existing = [makeSession(uid: "old", host: "api.example.com")]
        let fixture = Fixture(pages: [existing, existing, existing])
        let outcome = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(host: "api.example.com"),
            maxCount: 10,
            timeout: 2,
            settleInterval: 1,
            pollInterval: 1,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertTrue(outcome.sessions.isEmpty)
        XCTAssertEqual(outcome.stopReason, .timedOut)
    }

    func testStopReasonDistinguishesAllThreeExitPaths() async throws {
        let timedOutFixture = Fixture(pages: [[]])
        let timedOut = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(),
            maxCount: 5,
            timeout: 2,
            settleInterval: 1,
            pollInterval: 1,
            fetch: timedOutFixture.fetch,
            elapsed: timedOutFixture.elapsed,
            sleep: timedOutFixture.sleep
        )
        XCTAssertEqual(timedOut.stopReason, .timedOut)

        let settledFixture = Fixture(pages: [[], [makeSession(uid: "s1")]])
        let settled = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(),
            maxCount: 5,
            timeout: 10,
            settleInterval: 1,
            pollInterval: 1,
            fetch: settledFixture.fetch,
            elapsed: settledFixture.elapsed,
            sleep: settledFixture.sleep
        )
        XCTAssertEqual(settled.stopReason, .settled)

        let cappedFixture = Fixture(pages: [[], [makeSession(uid: "s2"), makeSession(uid: "s1")]])
        let capped = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(),
            maxCount: 1,
            timeout: 10,
            settleInterval: 1,
            pollInterval: 1,
            fetch: cappedFixture.fetch,
            elapsed: cappedFixture.elapsed,
            sleep: cappedFixture.sleep
        )
        XCTAssertEqual(capped.stopReason, .reachedCount)
    }

    func testHardCapClampsARequestForMoreThanTheMaximum() async throws {
        let sessions = (0..<(MCPSessionCollector.maxCollectCount + 20)).map { makeSession(uid: "s\($0)") }
        let fixture = Fixture(pages: [[], sessions])
        let outcome = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(),
            maxCount: 10_000,
            timeout: 10,
            settleInterval: 1,
            pollInterval: 1,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertEqual(outcome.sessions.count, MCPSessionCollector.maxCollectCount)
        XCTAssertEqual(outcome.stopReason, .reachedCount)
    }

    func testTimeoutIsClampedToTheMaximum() async throws {
        let fixture = Fixture(pages: [[]])
        _ = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(),
            maxCount: 5,
            timeout: 10_000,
            settleInterval: 1,
            pollInterval: 100,
            fetch: fixture.fetch,
            elapsed: fixture.elapsed,
            sleep: fixture.sleep
        )
        XCTAssertLessThanOrEqual(fixture.now, MCPSessionWaiter.maxTimeout + 100)
    }

    func testCollectOutcomeTextGuidesTheAgent() {
        let found = MCPSessionCollector.Outcome(
            sessions: [makeSession(uid: "s9")],
            stopReason: .settled,
            polls: 4
        )
        let text = MCPTextFormat.collectOutcome(found, timeout: 30)
        XCTAssertTrue(text.contains("uid=s9"))
        XCTAssertTrue(text.contains("settle window"))

        let empty = MCPSessionCollector.Outcome(sessions: [], stopReason: .timedOut, polls: 40)
        let emptyText = MCPTextFormat.collectOutcome(empty, timeout: 30)
        XCTAssertTrue(emptyText.contains("30s"))
        XCTAssertTrue(emptyText.contains("capture_status"))
    }
}
