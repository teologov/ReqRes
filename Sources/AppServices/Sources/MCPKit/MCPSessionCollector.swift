//
//  MCPSessionCollector.swift
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
//  "Tap Save and tell me everything that fired" — a login is three requests
//  and a page load can be dozens, but `MCPSessionWaiter` only ever answers
//  for one. Paying one blocking round trip per request also risks losing
//  ones that land between calls. This collector accumulates every NEW match
//  from a single wait instead of just the first.
//
//  Same shape as `MCPSessionWaiter` on purpose: an injected clock and fetch
//  closure keep it unit-testable without real sleeping or a live app, and
//  polling stays client-side so the app's bridge is still a plain
//  synchronous request/response server, never a long-lived subscription.
//

import Foundation

public enum MCPSessionCollector {
    /// Why the collector stopped, so an agent can tell "that is everything"
    /// apart from "capture might still be catching up".
    public enum StopReason: String, Equatable, Codable {
        case reachedCount
        case settled
        case timedOut
    }

    public struct Outcome: Equatable {
        /// New matches, oldest first — the order the requests actually fired,
        /// not the order the in-memory store happens to return them in.
        public var sessions: [MCPSessionSummary]
        public var stopReason: StopReason
        public var polls: Int

        public init(sessions: [MCPSessionSummary], stopReason: StopReason, polls: Int) {
            self.sessions = sessions
            self.stopReason = stopReason
            self.polls = polls
        }
    }

    public static let defaultTimeout: TimeInterval = MCPSessionWaiter.defaultTimeout
    public static let defaultPollInterval: TimeInterval = MCPSessionWaiter.defaultPollInterval

    /// How long to wait, after the most recent match, before deciding a burst
    /// is over. Long enough that a page's own follow-on requests (which fire
    /// well under a second apart in practice) don't each restart the clock
    /// past it; short enough that the common "one request, then quiet" case
    /// doesn't sit noticeably longer than a single `wait_for_session` call.
    public static let defaultSettleInterval: TimeInterval = 2

    /// A reasonable guess for "everything one user action produces" without
    /// making the agent guess the exact number up front.
    public static let defaultMaxCount = 20

    /// Hard ceiling on matches returned by one call. Unlike `list_sessions`
    /// this reply is never paginated — the whole burst goes into one tool
    /// result — so the cap has to bound the entire response by itself. A
    /// busy OAuth dance or page load rarely clears a couple dozen requests;
    /// 50 leaves headroom for that while keeping a hung or misdirected agent
    /// from turning one call into an unbounded hold on a bridge connection.
    public static let maxCollectCount = 50

    /// Establishes a baseline exactly like `MCPSessionWaiter.wait` — sessions
    /// present on the first fetch never count as matches — then keeps
    /// polling and accumulating NEW matches until `maxCount` is reached, the
    /// settle window elapses after the last match, or the overall timeout
    /// fires. Whichever happens first wins; `stopReason` says which.
    ///
    /// - Parameters:
    ///   - fetch: returns the current sessions, newest first.
    ///   - watch: every in-flight row plus the named ones, wherever they sit
    ///     (`MCPWatchedRows`) — so a long request pushed past the newest page
    ///     is still collected when it finishes.
    ///   - elapsed: monotonic seconds since the call began.
    ///   - sleep: suspends for the given interval.
    public static func collect(
        filter: MCPSessionFilter,
        includeFailed: Bool = false,
        maxCount: Int = defaultMaxCount,
        timeout: TimeInterval = defaultTimeout,
        settleInterval: TimeInterval = defaultSettleInterval,
        pollInterval: TimeInterval = defaultPollInterval,
        fetch: () async throws -> [MCPSessionSummary],
        watch: MCPWatchedRows.Fetch? = nil,
        elapsed: () -> TimeInterval,
        sleep: (TimeInterval) async throws -> Void
    ) async throws -> Outcome {
        let budget = min(max(timeout, 0), MCPSessionWaiter.maxTimeout)
        let cap = min(max(maxCount, 1), maxCollectCount)
        let settle = max(settleInterval, 0)
        var watched = MCPWatchedRows()

        // A row still in flight at the call is not old news: it has not
        // arrived yet in the sense this tool means (it collects FINISHED
        // requests, as it did before live rows existed).
        let baseline = try await watched.poll(page: fetch, watch: watch)
        var seen = Set(baseline.filter { !$0.isInFlight }.map(\.uid))
        watched.follow(baseline, settled: seen)
        var collected: [MCPSessionSummary] = []
        var lastMatchAt: TimeInterval?
        var polls = 1

        while elapsed() < budget {
            try await sleep(pollInterval)
            let current = try await watched.poll(page: fetch, watch: watch)
            polls += 1
            let now = elapsed()

            // Newest-first from the store, so walk backwards to append
            // matches in the order they were actually captured.
            for session in current.reversed() where !seen.contains(session.uid) && !session.isInFlight {
                seen.insert(session.uid)
                guard MCPSessionWaiter.admits(session, filter: filter, includeFailed: includeFailed) else { continue }
                collected.append(session)
                lastMatchAt = now
                if collected.count >= cap {
                    return Outcome(sessions: collected, stopReason: .reachedCount, polls: polls)
                }
            }
            watched.follow(current, settled: seen)

            if let lastMatchAt, now - lastMatchAt >= settle {
                return Outcome(sessions: collected, stopReason: .settled, polls: polls)
            }
        }

        return Outcome(sessions: collected, stopReason: .timedOut, polls: polls)
    }
}

// MARK: - Text rendering

public extension MCPTextFormat {
    /// Renders a collector outcome the way `waitOutcome` renders a single
    /// match, plus the reason it stopped — a short list should not leave an
    /// agent guessing whether that is everything or capture stalled.
    static func collectOutcome(_ outcome: MCPSessionCollector.Outcome, timeout: TimeInterval, includeFailed: Bool = false) -> String {
        guard !outcome.sessions.isEmpty else {
            var text = "No matching requests arrived within \(Int(timeout))s. Capture may be stopped (call capture_status), the filter may be too narrow, or the action was not performed."
            if !includeFailed { text += " " + failuresSkippedNote }
            return text
        }
        var lines = outcome.sessions.map(row(_:))
        lines.append("")
        let plural = outcome.sessions.count == 1 ? "" : "s"
        lines.append("\(outcome.sessions.count) request\(plural) captured (\(collectorStopReasonText(outcome.stopReason))).")
        return lines.joined(separator: "\n")
    }

    private static func collectorStopReasonText(_ reason: MCPSessionCollector.StopReason) -> String {
        switch reason {
        case .reachedCount: return "reached the requested count"
        case .settled: return "no further request before the settle window closed"
        case .timedOut: return "reached the overall timeout"
        }
    }
}
