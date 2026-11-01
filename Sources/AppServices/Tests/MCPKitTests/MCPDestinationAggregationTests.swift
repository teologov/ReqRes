//
//  MCPDestinationAggregationTests.swift
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
//  `list_destinations` (destination-map UX spec §8.3): the report is pure
//  aggregation over session summaries with `list_sessions`' filter applied,
//  so "where does claude send data" is one call — and the user's own
//  location is never in it.
//

import XCTest
@testable import MCPKit

final class MCPDestinationAggregationTests: XCTestCase {
    private func session(
        _ uid: String,
        host: String = "api.example.com",
        country: String? = "US",
        app: String? = "claude",
        requestBytes: Int? = 100,
        responseBytes: Int? = 900
    ) -> MCPSessionSummary {
        var summary = makeSession(uid: uid, host: host, app: app, country: country)
        summary.requestBodySize = requestBytes
        summary.responseBodySize = responseBytes
        return summary
    }

    private func report(_ summaries: [MCPSessionSummary], filter: MCPSessionFilter = MCPSessionFilter()) -> MCPDestinationsReport {
        MCPDestinationAggregation.report(summaries: summaries, filter: filter)
    }

    // MARK: - Counting and ordering

    func testRequestsAreGroupedByDestinationAndCounted() {
        let sessions = [
            session("a", country: "US"), session("b", country: "US"), session("c", country: "US"),
            session("d", country: "DE"),
            session("e", country: "mac"),
        ]
        let result = report(sessions)
        XCTAssertEqual(result.totalRequests, 5)
        XCTAssertEqual(result.destinations.map(\.country), ["US", "DE", "mac"])
        XCTAssertEqual(result.destinations.map(\.requests), [3, 1, 1])
    }

    func testUnknownIsLastWhateverItsCount() {
        let sessions = [
            session("a", country: nil), session("b", country: nil), session("c", country: nil),
            session("d", country: "DE"),
        ]
        let result = report(sessions)
        XCTAssertEqual(result.destinations.map(\.country), ["DE", "unknown"])
        XCTAssertEqual(result.destinations.last?.requests, 3)
        XCTAssertEqual(result.destinations.last?.name, "Unknown")
    }

    /// The adapter omits the token for Unknown; a token that is not a token
    /// (a bug upstream, or an older app) reads Unknown too, never a crash.
    func testANilOrUnparseableCountryIsUnknown() {
        let result = report([session("a", country: nil), session("b", country: "Germany"), session("c", country: "")])
        XCTAssertEqual(result.destinations.map(\.country), ["unknown"])
        XCTAssertEqual(result.destinations.first?.requests, 3)
    }

    func testTokensAreNormalisedOnTheWayIn() {
        let result = report([session("a", country: "us"), session("b", country: "US"), session("c", country: "MAC")])
        XCTAssertEqual(result.destinations.map(\.country), ["US", "mac"])
        XCTAssertEqual(result.destinations.first?.requests, 2)
    }

    // MARK: - Names

    /// English regardless of the Mac's language: an agent's context may be
    /// anywhere, and the class labels are the app's own Title Case words.
    func testNamesAreEnglishCountryNamesOrTheClassLabels() {
        let result = report([
            session("a", country: "DE"), session("b", country: "mac"), session("c", country: "local"), session("d", country: nil),
        ])
        // Equal counts tie-break on the token (`local` < `mac`); Unknown last regardless.
        XCTAssertEqual(result.destinations.map(\.name), ["Germany", "Local Network", "This Mac", "Unknown"])
    }

    // MARK: - Bytes, hosts, apps

    func testBytesAreRequestPlusResponseSizes() {
        let result = report([
            session("a", requestBytes: 100, responseBytes: 900),
            session("b", requestBytes: nil, responseBytes: 5_000),
            session("c", requestBytes: -1, responseBytes: nil),
        ])
        XCTAssertEqual(result.destinations.first?.bytes, 6_000, "nil and negative sizes count as 0")
    }

    func testHostAndAppCountsAreDistinctNames() {
        let result = report([
            session("a", host: "api.stripe.com", app: "claude"),
            session("b", host: "api.stripe.com", app: "claude"),
            session("c", host: "cdn.myshop.dev", app: "Brave Browser"),
            session("d", host: "cdn.myshop.dev", app: nil),
        ])
        let row = try! XCTUnwrap(result.destinations.first)
        XCTAssertEqual(row.hostCount, 2)
        XCTAssertEqual(row.appCount, 3, "the unattributed bucket is a bucket of its own")
    }

    func testTheListCarriesTheTopThreeHostsAndAppsBusiestFirst() {
        var sessions: [MCPSessionSummary] = []
        for (host, count) in [("h1", 5), ("h2", 4), ("h3", 3), ("h4", 2), ("h5", 1)] {
            for i in 0..<count { sessions.append(session("\(host)-\(i)", host: host, app: "app-\(host)")) }
        }
        let row = try! XCTUnwrap(report(sessions).destinations.first)
        XCTAssertEqual(row.topHosts.map(\.name), ["h1", "h2", "h3"])
        XCTAssertEqual(row.topHosts.map(\.requests), [5, 4, 3])
        XCTAssertEqual(row.topApps.map(\.name), ["app-h1", "app-h2", "app-h3"])
        XCTAssertEqual(row.hostCount, 5, "the count is not capped, only the list is")
    }

    /// `country=` asks about ONE destination, so that row carries its fuller
    /// lists (20 hosts, 10 apps) instead of the top three.
    func testACountryFilterWidensTheListsForThatDestination() {
        var sessions: [MCPSessionSummary] = []
        for i in 0..<25 { sessions.append(session("s\(i)", host: "host-\(i)", country: "DE", app: "app-\(i % 12)")) }
        sessions.append(session("us", host: "other", country: "US"))

        let result = report(sessions, filter: MCPSessionFilter(country: "de"))
        XCTAssertEqual(result.destinations.map(\.country), ["DE"], "the filter narrows to the one destination")
        XCTAssertEqual(result.totalRequests, 25)
        let row = try! XCTUnwrap(result.destinations.first)
        XCTAssertEqual(row.topHosts.count, MCPDestinationAggregation.detailHostLimit)
        XCTAssertEqual(row.topApps.count, MCPDestinationAggregation.detailAppLimit)
        XCTAssertEqual(row.hostCount, 25)
        XCTAssertEqual(row.appCount, 12)
    }

    func testTheUnattributedAppBucketIsNamedUnknownAndSortsLast() {
        let result = report([
            session("a", app: nil), session("b", app: nil), session("c", app: nil),
            session("d", app: "claude"),
        ])
        let row = try! XCTUnwrap(result.destinations.first)
        XCTAssertEqual(row.topApps.map(\.name), ["claude", ProcessIdentity.unknownLabel])
        XCTAssertEqual(row.topApps.map(\.requests), [1, 3])
    }

    // MARK: - The filter

    /// `app=claude` answers "where does this tool send data" — the same
    /// filter `list_sessions` applies, applied before grouping.
    func testTheSessionFilterIsAppliedBeforeGrouping() {
        let sessions = [
            session("a", country: "US", app: "claude"),
            session("b", country: "DE", app: "claude"),
            session("c", country: "US", app: "Safari"),
            session("d", country: "JP", app: nil),
        ]
        let result = report(sessions, filter: MCPSessionFilter(app: "claude"))
        XCTAssertEqual(result.totalRequests, 2)
        XCTAssertEqual(result.destinations.map(\.country), ["DE", "US"], "ties break on the token")
        XCTAssertEqual(result.destinations.map(\.requests), [1, 1])
    }

    func testAFilterThatMatchesNothingGivesAnEmptyReport() {
        let result = report([session("a")], filter: MCPSessionFilter(host: "nowhere"))
        XCTAssertEqual(result.totalRequests, 0)
        XCTAssertTrue(result.destinations.isEmpty)
        XCTAssertFalse(result.note.isEmpty, "the note is still there — the agent should still know what a country means")
    }

    // MARK: - What the report says about itself, and what it never says

    func testTheNoteIsTheCDNSentenceAndTheCredit() {
        let result = report([session("a")])
        XCTAssertEqual(result.note, "\(DestinationCopy.whatACountryMeans) \(DestinationCopy.agentAttribution)")
        XCTAssertTrue(result.note.contains("a CDN answers from a nearby edge"))
        XCTAssertTrue(result.note.contains("DB-IP"))
    }

    /// The user's own location is derived from their time zone and drawn
    /// only in the app's window (spec §0, §11). No field of the report, at
    /// any level, carries it — pinned by walking the encoded JSON keys.
    func testTheReportNeverCarriesTheOrigin() throws {
        let result = report([session("a", country: "US"), session("b", country: nil)])
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["totalRequests", "destinations", "note", "neverConnected"])
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["origin", "timezone", "time_zone", "you", "location"] {
            XCTAssertFalse(text.contains("\"\(forbidden)\""), "the report must not carry a '\(forbidden)' field")
        }
        XCTAssertFalse(Mirror(reflecting: result).children.contains { $0.label?.lowercased().contains("origin") == true })
    }

    func testTheReportRoundTripsThroughJSON() throws {
        let original = report([session("a", host: "api.stripe.com"), session("b", country: nil, app: nil)])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(MCPDestinationsReport.self, from: data), original)
    }
}
