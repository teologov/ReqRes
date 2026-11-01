//
//  MCPTextFormatTests.swift
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

final class MCPTextFormatTests: XCTestCase {
    func testStatusExplainsIncompleteSetup() {
        let status = MCPBridgeStatus(
            captureActive: false,
            vpnStatus: "disconnected",
            extensionStatus: "extensionDisabled",
            caCertificateInstalled: false,
            sessionCount: 0,
            appVersion: "1.0.5"
        )
        let text = MCPTextFormat.status(status)
        XCTAssertTrue(text.contains("Capture: stopped"))
        XCTAssertTrue(text.contains("Setup is incomplete"))
        XCTAssertTrue(text.contains("Login Items & Extensions"))
    }

    func testReadyStatusOmitsRemediation() {
        let status = MCPBridgeStatus(
            captureActive: true,
            vpnStatus: "connected",
            extensionStatus: "ready",
            caCertificateInstalled: true,
            sessionCount: 12
        )
        let text = MCPTextFormat.status(status)
        XCTAssertTrue(text.contains("Capture: running"))
        XCTAssertFalse(text.contains("Setup is incomplete"))
    }

    /// 2026-09-29 live run: `start_capture` answered "Capture: stopped (tunnel:
    /// connecting)" — the tunnel was on its way up, which read as a failure.
    func testATunnelInTransitionIsStartingOrStoppingNotStopped() {
        XCTAssertEqual(MCPTextFormat.captureWord(captureActive: false, vpnStatus: "connecting"), "starting")
        XCTAssertEqual(MCPTextFormat.captureWord(captureActive: false, vpnStatus: "reasserting"), "starting")
        XCTAssertEqual(MCPTextFormat.captureWord(captureActive: false, vpnStatus: "disconnecting"), "stopping")
        XCTAssertEqual(MCPTextFormat.captureWord(captureActive: false, vpnStatus: "disconnected"), "stopped")
        XCTAssertEqual(MCPTextFormat.captureWord(captureActive: true, vpnStatus: "connected"), "running")
        let status = MCPBridgeStatus(captureActive: false, vpnStatus: "connecting", extensionStatus: "ready",
                                     caCertificateInstalled: true, sessionCount: 0)
        XCTAssertTrue(MCPTextFormat.status(status).hasPrefix("Capture: starting (tunnel: connecting)"))
    }

    func testRemediationCoversEveryOnboardingState() {
        for state in ["notInstalled", "extensionDisabled", "configurationMissing", "needsRestart"] {
            let advice = MCPTextFormat.remediation(for: state)
            XCTAssertFalse(advice.isEmpty, "missing remediation for \(state)")
            XCTAssertNotEqual(advice, MCPTextFormat.remediation(for: "unknown-state"), "\(state) fell through to the default")
        }
    }

    func testEmptyPageTellsTheAgentWhereToLook() {
        let page = MCPSessionPage(sessions: [], nextCursor: nil, totalMatched: 0, note: nil)
        let text = MCPTextFormat.page(page)
        XCTAssertTrue(text.contains("capture_status"))
    }

    func testPageIncludesCountsAndNote() {
        let page = MCPSessionPage(
            sessions: [makeSession(uid: "s2"), makeSession(uid: "s1")],
            nextCursor: "s1",
            totalMatched: 10,
            note: "8 more matching sessions — pass cursor=s1"
        )
        let text = MCPTextFormat.page(page)
        XCTAssertTrue(text.contains("2 of 10 matching sessions."))
        XCTAssertTrue(text.contains("8 more matching sessions"))
        XCTAssertTrue(text.contains("uid=s2"))
    }

    func testRowIsOneCompactLine() {
        let session = MCPSessionSummary(
            uid: "s1",
            host: "api.example.com",
            method: "post",
            url: "https://api.example.com/v1/login",
            scheme: "https",
            statusCode: 500,
            durationMs: 128.6
        )
        let row = MCPTextFormat.row(session)
        XCTAssertFalse(row.contains("\n"))
        XCTAssertTrue(row.hasPrefix("500  POST  https://api.example.com/v1/login"))
        XCTAssertTrue(row.contains("129ms"))
        XCTAssertTrue(row.contains("uid=s1"))
        // Unattributed: the row says nothing about the origin rather than
        // stamping "unknown" on every row of a list.
        XCTAssertFalse(row.contains("app="))
        XCTAssertFalse(row.contains("pid="))
    }

    /// Attribution is per connection and the name alone does not separate
    /// several instances of one tool, so the row shows both when it has them.
    func testRowCarriesTheOriginWhenAttributed() {
        let both = MCPTextFormat.row(makeSession(uid: "s1", app: "curl", pid: 123))
        XCTAssertTrue(both.contains("app=curl pid=123"), both)
        XCTAssertFalse(both.contains("\n"))

        let nameOnly = MCPTextFormat.row(makeSession(uid: "s2", app: "Safari"))
        XCTAssertTrue(nameOnly.contains("app=Safari"), nameOnly)
        XCTAssertFalse(nameOnly.contains("pid="), nameOnly)

        // A pid with no name still identifies the process; it is not dropped
        // because the friendlier half is missing.
        let pidOnly = MCPTextFormat.row(makeSession(uid: "s3", pid: 9437))
        XCTAssertTrue(pidOnly.contains("pid=9437"), pidOnly)
        XCTAssertFalse(pidOnly.contains("app="), pidOnly)
    }

    func testDetailNamesTheOriginOnlyWhenAttributed() {
        let attributed = MCPTextFormat.detail(MCPSessionDetail(summary: makeSession(uid: "s1", app: "claude", pid: 9437)))
        XCTAssertTrue(attributed.contains("Origin: app=claude pid=9437"), attributed)

        let unattributed = MCPTextFormat.detail(MCPSessionDetail(summary: makeSession(uid: "s2")))
        XCTAssertFalse(unattributed.contains("Origin:"), unattributed)
    }

    func testDetailMarksTruncatedBodies() {
        let detail = MCPSessionDetail(
            summary: makeSession(uid: "s1"),
            requestHeaders: ["Accept": "application/json"],
            responseBodyPreview: "{\"a\":1}",
            responseBodyTruncated: true
        )
        let text = MCPTextFormat.detail(detail)
        XCTAssertTrue(text.contains("Request headers:"))
        XCTAssertTrue(text.contains("Response body:"))
        XCTAssertTrue(text.contains("(truncated"))
        // Sections with no content are omitted rather than printed empty.
        XCTAssertFalse(text.contains("Request body:"))
    }

    // MARK: - Destinations (destination-map UX spec §8.1, §8.3)

    /// The row appends `country=US` after the origin and before the uid when
    /// the summary carries a token; nothing when it is nil — an unplaceable
    /// row says nothing rather than stamping a fourth word on every one.
    func testRowCarriesTheCountryTokenWhenSetAndNotWhenNil() {
        let placed = MCPTextFormat.row(makeSession(uid: "s1", app: "curl", pid: 123, country: "US"))
        XCTAssertTrue(placed.contains("app=curl pid=123  country=US  uid=s1"), placed)
        XCTAssertFalse(placed.contains("\n"))

        let unplaced = MCPTextFormat.row(makeSession(uid: "s2", app: "curl", pid: 123))
        XCTAssertFalse(unplaced.contains("country="), unplaced)

        let classToken = MCPTextFormat.row(makeSession(uid: "s3", country: "mac"))
        XCTAssertTrue(classToken.contains("country=mac  uid=s3"), classToken)
    }

    func testDetailPrintsTheServerAddressWithItsCountry() {
        let placed = MCPTextFormat.detail(MCPSessionDetail(summary: makeSession(uid: "s1", country: "DE"), serverAddress: "104.18.32.7"))
        XCTAssertTrue(placed.contains("Server: 104.18.32.7 (Germany)"), placed)

        let bare = MCPTextFormat.detail(MCPSessionDetail(summary: makeSession(uid: "s2"), serverAddress: "8.8.8.8"))
        XCTAssertEqual(bare.components(separatedBy: "\n").first { $0.hasPrefix("Server:") }, "Server: 8.8.8.8", "no country, no annotation")

        let mac = MCPTextFormat.detail(MCPSessionDetail(summary: makeSession(uid: "s3", country: "mac"), serverAddress: "127.0.0.1"))
        XCTAssertTrue(mac.contains("Server: 127.0.0.1 (This Mac)"), mac)

        let none = MCPTextFormat.detail(MCPSessionDetail(summary: makeSession(uid: "s4", country: "DE")))
        XCTAssertFalse(none.contains("Server:"), "the address is the fact; without it there is no line")
    }

    private func destinationsReport() -> MCPDestinationsReport {
        MCPDestinationsReport(
            totalRequests: 3_812,
            destinations: [
                MCPDestinationSummary(
                    country: "US", name: "United States", requests: 1_204, bytes: 38_200_000, hostCount: 14, appCount: 3,
                    topHosts: [.init(name: "api.stripe.com", requests: 900), .init(name: "cdn.myshop.dev", requests: 204), .init(name: "api.anthropic.com", requests: 100)],
                    topApps: [.init(name: "Brave Browser", requests: 1_000), .init(name: "claude", requests: 204)]
                ),
                MCPDestinationSummary(
                    country: "DE", name: "Germany", requests: 88, bytes: 1_100_000, hostCount: 2, appCount: 1,
                    topHosts: [.init(name: "api.myshop.dev", requests: 88)], topApps: [.init(name: "claude", requests: 88)]
                ),
                MCPDestinationSummary(
                    country: "mac", name: "This Mac", requests: 412, bytes: 2_000_000, hostCount: 1, appCount: 1,
                    topHosts: [.init(name: "localhost", requests: 412)], topApps: [.init(name: "node", requests: 412)]
                ),
                MCPDestinationSummary(
                    country: "unknown", name: "Unknown", requests: 12, bytes: 40_000, hostCount: 1, appCount: 1,
                    topHosts: [.init(name: "10.0.0.5", requests: 12)], topApps: [.init(name: "Unknown", requests: 12)]
                ),
            ],
            note: MCPDestinationAggregation.note
        )
    }

    /// The shape in spec §8.3: a heading that echoes the filter, one aligned
    /// row per destination (the Unknown row carrying its reason instead of
    /// hosts), and a last line that says how to drill in — ending with the
    /// CDN sentence and the credit.
    func testDestinationsReadsAsATableWithTheDrillInLine() {
        let text = MCPTextFormat.destinations(destinationsReport(), filterDescription: "app=claude")
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 6, text)
        XCTAssertEqual(lines[0], "Where 3,812 captured requests went (country level, offline lookup; app=claude):")

        XCTAssertTrue(lines[1].hasPrefix("US "), lines[1])
        for needle in ["United States", "1,204 requests", "38.2 MB", "14 hosts", "3 apps"] {
            XCTAssertTrue(lines[1].contains(needle), "\(needle) missing from \(lines[1])")
        }
        XCTAssertTrue(lines[1].hasSuffix("top: api.stripe.com 900, cdn.myshop.dev 204, api.anthropic.com 100"), lines[1])

        XCTAssertTrue(lines[2].hasPrefix("DE "), lines[2])
        XCTAssertTrue(lines[2].contains("1 app"), lines[2])
        XCTAssertFalse(lines[2].contains("1 apps"), "singular")
        XCTAssertTrue(lines[3].hasPrefix("mac "), lines[3])

        XCTAssertTrue(lines[4].hasPrefix("unknown"), lines[4])
        XCTAssertTrue(lines[4].hasSuffix("— \(DestinationCopy.agentUnknownNote)"), lines[4])
        XCTAssertFalse(lines[4].contains("10.0.0.5"), "the Unknown row carries its reason, not a host list")

        XCTAssertTrue(lines[5].hasPrefix("Filter list_sessions or wait_for_session with country=US (or local, mac, unknown) for the requests behind a row; pass country=DE here for its full host and app lists. "), lines[5])
        XCTAssertTrue(lines[5].contains(DestinationCopy.whatACountryMeans))
        XCTAssertTrue(lines[5].hasSuffix(MCPDestinationAggregation.note))
        XCTAssertTrue(lines[5].hasSuffix("IP Geolocation by DB-IP."))
    }

    func testDestinationsHeadingWithoutAFilter() {
        let text = MCPTextFormat.destinations(destinationsReport())
        XCTAssertTrue(text.hasPrefix("Where 3,812 captured requests went (country level, offline lookup):\n"), text)
    }

    /// An agent reads the rows as a table, so the trailing column starts at
    /// one offset on every row — the Unknown row's dash included.
    func testDestinationsColumnsAlignAcrossRows() {
        let text = MCPTextFormat.destinations(destinationsReport())
        let rows = Array(text.components(separatedBy: "\n").dropFirst().dropLast())
        XCTAssertEqual(rows.count, 4)
        let topColumns = rows.compactMap { row in row.range(of: "top: ").map { row.distance(from: row.startIndex, to: $0.lowerBound) } }
        XCTAssertEqual(topColumns.count, 3)
        XCTAssertEqual(Set(topColumns).count, 1, "the top: column must align: \(topColumns)")
        let dash = rows.last.flatMap { row in row.range(of: "— ").map { row.distance(from: row.startIndex, to: $0.lowerBound) } }
        XCTAssertEqual(dash, topColumns.first, "the Unknown row's note sits in the same column")
    }

    func testDestinationsForOneCountryPrintsItsFullLists() {
        let row = MCPDestinationSummary(
            country: "DE", name: "Germany", requests: 88, bytes: 1_100_000, hostCount: 2, appCount: 1,
            topHosts: [.init(name: "api.myshop.dev", requests: 60), .init(name: "cdn.myshop.dev", requests: 28)],
            topApps: [.init(name: "claude", requests: 88)]
        )
        let report = MCPDestinationsReport(totalRequests: 88, destinations: [row], note: MCPDestinationAggregation.note)
        let text = MCPTextFormat.destinations(report, filterDescription: "app=claude, country=DE")
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5, text)
        XCTAssertEqual(lines[0], "Where 88 captured requests went (country level, offline lookup; app=claude, country=DE):")
        XCTAssertEqual(lines[1], "DE  Germany  88 requests  1.1 MB  2 hosts  1 app")
        XCTAssertEqual(lines[2], "Hosts: api.myshop.dev 60, cdn.myshop.dev 28")
        XCTAssertEqual(lines[3], "Apps: claude 88")
        XCTAssertTrue(lines[4].hasPrefix("Filter list_sessions or wait_for_session with country=DE for the requests behind these. "), lines[4])
        XCTAssertTrue(lines[4].hasSuffix(MCPDestinationAggregation.note))
    }

    /// One row is not the same as one destination asked for: a report that
    /// happens to have one row (all traffic went to one country) keeps the
    /// table shape, and a `country=` inside another value does not switch it.
    func testDestinationsSwitchesToDetailOnlyForACountryFilterComponent() {
        let row = destinationsReport().destinations[1]
        let report = MCPDestinationsReport(totalRequests: 88, destinations: [row], note: MCPDestinationAggregation.note)
        XCTAssertFalse(MCPTextFormat.destinations(report).contains("Hosts: "))
        XCTAssertFalse(MCPTextFormat.destinations(report, filterDescription: "url_contains=country=DE").contains("Hosts: "))
        XCTAssertTrue(MCPTextFormat.destinations(report, filterDescription: "country=DE").contains("Hosts: "))
        XCTAssertTrue(MCPTextFormat.describesOneCountry("host=a, country=DE"))
        XCTAssertFalse(MCPTextFormat.describesOneCountry("host=country=DE"))
        XCTAssertFalse(MCPTextFormat.describesOneCountry(nil))
    }

    func testDestinationsWithNothingMatchingPointsAtCaptureStatus() {
        let empty = MCPDestinationsReport(totalRequests: 0, destinations: [], note: MCPDestinationAggregation.note)
        let filtered = MCPTextFormat.destinations(empty, filterDescription: "app=claude")
        XCTAssertTrue(filtered.hasPrefix("No captured requests match app=claude."), filtered)
        XCTAssertTrue(filtered.contains("capture_status"))
        XCTAssertFalse(filtered.contains("Where "))
        XCTAssertTrue(MCPTextFormat.destinations(empty).hasPrefix("No captured requests match."))
    }
}
