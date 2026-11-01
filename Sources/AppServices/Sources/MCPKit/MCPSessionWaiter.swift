//
//  MCPSessionWaiter.swift
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

import Foundation

/// "Watch traffic while I reproduce the bug" — the primitive no incumbent
/// proxy exposes to agents. Polling lives client-side so the app's bridge
/// stays a simple synchronous request/response server.
///
/// Time and fetching are injected so the whole thing is unit-testable without
/// real sleeping or a live app.
public enum MCPSessionWaiter {
    public struct Outcome: Equatable {
        /// The first NEW session matching the filter, if one arrived in time.
        public var session: MCPSessionSummary?
        public var timedOut: Bool
        public var polls: Int

        public init(session: MCPSessionSummary?, timedOut: Bool, polls: Int) {
            self.session = session
            self.timedOut = timedOut
            self.polls = polls
        }
    }

    public static let defaultTimeout: TimeInterval = 30
    public static let maxTimeout: TimeInterval = 300
    public static let defaultPollInterval: TimeInterval = 0.75

    /// Establishes a baseline of what is already captured, then waits for a
    /// session that is BOTH new and matching — so a pre-existing match from an
    /// earlier reproduction never satisfies the wait.
    ///
    /// "New" means it reached `until` after the wait began. A request that was
    /// already in flight when the call came (a live row, protocol PRD 4a.1)
    /// and gets its headers, first message or end afterwards is new at that
    /// stage — exactly as a request finishing after the call always counted
    /// before live rows existed.
    ///
    /// - Parameters:
    ///   - until: how far the request must get; `.complete` (the default) is
    ///     the behaviour from before live rows.
    ///   - fetch: returns the current sessions, newest first (the newest
    ///     page — `MCPLimits.maxPageSize` rows in production).
    ///   - watch: returns every in-flight row plus the rows named, wherever
    ///     they sit in the list (`MCPWatchedRows`). Nil in tests that keep
    ///     every row inside `fetch`.
    ///   - elapsed: monotonic seconds since the wait began.
    ///   - sleep: suspends for the given interval.
    public static func wait(
        filter: MCPSessionFilter,
        includeFailed: Bool = false,
        until stage: MCPWaitStage = .complete,
        timeout: TimeInterval = defaultTimeout,
        pollInterval: TimeInterval = defaultPollInterval,
        fetch: () async throws -> [MCPSessionSummary],
        watch: MCPWatchedRows.Fetch? = nil,
        elapsed: () -> TimeInterval,
        sleep: (TimeInterval) async throws -> Void
    ) async throws -> Outcome {
        let budget = min(max(timeout, 0), maxTimeout)
        var watched = MCPWatchedRows()

        // Only what had ALREADY reached the stage is old news; an in-flight
        // row short of it stays eligible.
        let baseline = try await watched.poll(page: fetch, watch: watch)
        var seen = Set(baseline.filter { $0.hasReached(stage) }.map(\.uid))
        watched.follow(baseline, settled: seen)
        var polls = 1

        while elapsed() < budget {
            try await sleep(pollInterval)
            let current = try await watched.poll(page: fetch, watch: watch)
            polls += 1

            // Newest-first, so walk backwards to return the EARLIEST new match:
            // during a burst that is the request the user actually triggered first.
            for session in current.reversed() where !seen.contains(session.uid) && session.hasReached(stage) {
                if admits(session, filter: filter, includeFailed: includeFailed) {
                    return Outcome(session: session, timedOut: false, polls: polls)
                }
                // A finished row never changes again; an in-flight one may
                // still come to match (its status arrives with its head).
                if !session.isInFlight { seen.insert(session.uid) }
            }
            watched.follow(current, settled: seen)
        }

        return Outcome(session: nil, timedOut: true, polls: polls)
    }

    /// Whether a wait may resolve on `session` (protocol PRD 3.4, decision D8).
    ///
    /// A failed, aborted or timed-out row is a match only when the agent
    /// asked for one — `include_failed`, or an `outcome` filter naming a
    /// failure. Otherwise the wait skips it and keeps waiting: an agent that
    /// says "tell me when the login request lands" means the one that
    /// completed, and a browser cancels speculative requests constantly, so
    /// resolving on the first cancelled row would hand back noise and stop
    /// watching before the real request arrived.
    public static func admits(_ session: MCPSessionSummary, filter: MCPSessionFilter, includeFailed: Bool) -> Bool {
        guard filter.matches(session) else { return false }
        // A live row that ended without its final row (capture stopped, or
        // its end was lost) did not complete: a failure for this purpose.
        if session.endedWithoutFinal { return includeFailed }
        guard session.effectiveOutcome.isFailure else { return true }
        return includeFailed || (filter.wantedOutcome?.isFailure ?? false)
    }

    /// Wall-clock helpers for production use.
    public static func monotonicElapsed(from start: Date = Date()) -> () -> TimeInterval {
        { Date().timeIntervalSince(start) }
    }

    public static func taskSleep(_ interval: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(interval, 0) * 1_000_000_000))
    }
}

/// The rows a wait follows BY ID rather than by position.
///
/// A live row's final replaces it IN PLACE, under the id it was announced
/// with (protocol-engine doc §S6) — it no longer arrives at the top of the
/// list when it finishes. The waiters read the newest page only
/// (`MCPLimits.maxPageSize`), so a 60-second LLM stream announced while the
/// user kept browsing would be pushed past that page by newer rows and finish
/// where no poll looks: `wait_for_session until=complete` timed out on a
/// request that completed. So every poll also asks the bridge for every
/// in-flight row (wherever it sits) and for the rows this wait is already
/// following, and a followed row stops being followed only once it has
/// finished and been judged, or has left the store.
public struct MCPWatchedRows {
    /// `GET /v1/sessions/watched?uids=…`: every in-flight row plus the named
    /// ones that still exist, newest first.
    public typealias Fetch = (Set<String>) async throws -> [MCPSessionSummary]

    /// How many rows one wait follows at most. The ids travel in a query
    /// string (37 bytes each) under the bridge's 16 KB header limit; the
    /// oldest is let go first.
    public static let capacity = 200

    public private(set) var uids: Set<String> = []
    private var order: [String] = []

    public init() {}

    /// One poll: the newest page, merged with the watched rows when the
    /// caller can fetch them.
    public mutating func poll(page: () async throws -> [MCPSessionSummary], watch: Fetch?) async throws -> [MCPSessionSummary] {
        let rows = try await page()
        guard let watch else { return rows }
        return Self.merge(page: rows, watched: try await watch(uids))
    }

    /// The page with the watched rows folded in, newest first. A row in both
    /// takes the watched copy (fetched second, so it is the later state); a
    /// watched row the page does not hold sits beyond it, so it goes after.
    public static func merge(page: [MCPSessionSummary], watched: [MCPSessionSummary]) -> [MCPSessionSummary] {
        guard !watched.isEmpty else { return page }
        var byID: [String: MCPSessionSummary] = [:]
        for row in watched { byID[row.uid] = row }
        var merged = page.map { byID.removeValue(forKey: $0.uid) ?? $0 }
        merged.append(contentsOf: watched.filter { byID[$0.uid] != nil })
        return merged
    }

    /// Follows every in-flight row the wait has not settled; lets go of a row
    /// that finished (the caller has judged it by now), was settled, or is no
    /// longer in the store at all (evicted, deleted, cleared).
    public mutating func follow(_ observed: [MCPSessionSummary], settled: Set<String>) {
        var present: Set<String> = []
        for row in observed {
            present.insert(row.uid)
            if row.isInFlight && !settled.contains(row.uid) {
                if uids.insert(row.uid).inserted { order.append(row.uid) }
            } else {
                uids.remove(row.uid)
            }
        }
        uids.formIntersection(present)
        order.removeAll { !uids.contains($0) }
        while order.count > Self.capacity {
            uids.remove(order.removeFirst())
        }
    }
}
