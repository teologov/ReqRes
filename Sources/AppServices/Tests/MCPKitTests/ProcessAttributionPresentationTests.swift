//
//  ProcessAttributionPresentationTests.swift
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
//  The App column's accessibility value and agent tooltip line (UX spec
//  §2.3/§2.4), the rule that marks a captured process as an agent's (§8.2),
//  and what "Show its traffic" resolves to for one client (§8.3).
//

import XCTest
@testable import MCPKit

final class ProcessAttributionPresentationTests: XCTestCase {
    private let bravePath = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/140.1.83.109/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"

    private let safari = ProcessIdentity(name: "Safari", pid: 40213, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari")
    private let claude = ProcessIdentity(name: "claude", pid: 9437, executablePath: "/usr/local/bin/claude")
    private let unknown = ProcessIdentity(name: nil, pid: nil, executablePath: nil)
    private var brave: ProcessIdentity {
        ProcessIdentity(name: "Brave Browser Helper", pid: 4127, executablePath: bravePath)
    }
    private var cursorHelper: ProcessIdentity {
        ProcessIdentity(name: "Cursor Helper", pid: 5150, executablePath: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper")
    }

    private func client(_ name: String, pid: Int?, id: String = "1") -> MCPClient {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return MCPClient(id: id, name: name, processID: pid, firstSeen: now, lastSeen: now)
    }

    // MARK: - Accessibility value (§2.4)

    func testAccessibilityValueNamesTheAppAndItsProcess() {
        XCTAssertEqual(safari.accessibilityValue(), "Safari, process 40213")
    }

    func testAccessibilityValueDemotesAHelperWithVia() {
        XCTAssertEqual(brave.accessibilityValue(), "Brave Browser, via Brave Browser Helper, process 4127")
    }

    func testAccessibilityValueOfAnUnattributedRowIsTheOneWord() {
        XCTAssertEqual(unknown.accessibilityValue(), ProcessIdentity.unknownLabel)
        XCTAssertEqual(unknown.accessibilityValue(agentName: "Claude Code"), ProcessIdentity.unknownLabel,
                       "an unknown row cannot be an agent's; the suffix must not invent one")
    }

    func testAccessibilityValueAppendsTheConnectedAgent() {
        XCTAssertEqual(claude.accessibilityValue(agentName: "Claude Code"),
                       "claude, process 9437, from the connected agent Claude Code")
    }

    func testAccessibilityValueWithoutAPidHasNoProcessClause() {
        let named = ProcessIdentity(name: "curl", pid: nil, executablePath: nil)
        XCTAssertEqual(named.accessibilityValue(), "curl")
    }

    // MARK: - Agent tooltip (§2.3)

    func testAgentTooltipPrependsOneLineAndKeepsTheRest() {
        let plain = claude.tooltip
        XCTAssertEqual(claude.tooltip(agentName: "Claude Code"),
                       "Claude Code — the agent connected to ReqRes\n" + plain)
        XCTAssertEqual(claude.tooltip(agentName: nil), plain)
    }

    func testUnavailableTooltipIsTheSpecsSentence() {
        XCTAssertEqual(ProcessIdentity.unavailableTooltip,
                       "ReqRes cannot tell which process opens connections on this Mac right now — the socket table could not be read. Capture ▸ Diagnose Setup… has the details.")
    }

    // MARK: - Which rows are an agent's (§8.2)

    func testACommandLineAgentIsMatchedByItsExactPid() {
        let agents = MCPAgentAttribution(clients: [client("Claude Code", pid: 9437)])

        XCTAssertEqual(agents.processIDs, [9437])
        XCTAssertEqual(agents.agentName(for: claude), "Claude Code")
        XCTAssertNil(agents.agentName(for: ProcessIdentity(name: "claude", pid: 9767, executablePath: "/usr/local/bin/claude")),
                     "a second claude process is not the connected one")
    }

    func testAGUIAgentIsMatchedByNameOnlyWhenTheIdentityIsBundled() {
        let agents = MCPAgentAttribution(clients: [client("Cursor", pid: 5000)])

        XCTAssertEqual(agents.namesByDisplayName, ["cursor": "Cursor"])
        XCTAssertEqual(agents.agentName(for: cursorHelper), "Cursor", "helper pids inside Cursor.app are Cursor's traffic")

        let bareExecutable = ProcessIdentity(name: "cursor", pid: 77, executablePath: "/usr/local/bin/cursor")
        XCTAssertNil(agents.agentName(for: bareExecutable), "a bare executable named like a client is not that client")
    }

    func testTheNameMatchIsCaseInsensitive() {
        let agents = MCPAgentAttribution(clients: [client("cursor", pid: nil)])
        XCTAssertEqual(agents.agentName(for: cursorHelper), "cursor")
    }

    func testUnrelatedProcessesAndUnknownRowsAreNeverAnAgents() {
        let agents = MCPAgentAttribution(clients: [client("Claude Code", pid: 9437), client("Cursor", pid: 5000, id: "2")])

        XCTAssertNil(agents.agentName(for: safari))
        XCTAssertNil(agents.agentName(for: brave))
        XCTAssertNil(agents.agentName(for: unknown))
    }

    func testNoClientsMeansNoAgentRows() {
        XCTAssertTrue(MCPAgentAttribution.none.isEmpty)
        XCTAssertNil(MCPAgentAttribution.none.agentName(for: claude))
        XCTAssertEqual(MCPAgentAttribution(clients: []), .none)
    }

    func testAClientWithoutAPidStillMatchesByName() {
        let agents = MCPAgentAttribution(clients: [client("Cursor", pid: nil)])
        XCTAssertTrue(agents.processIDs.isEmpty)
        XCTAssertEqual(agents.agentName(for: cursorHelper), "Cursor")
    }

    // MARK: - "Show its traffic" (§8.3)

    func testShowItsTrafficPrefersThePidWhenCaptured() {
        let link = MCPAgentTrafficLink.resolve(
            client: client("Claude Code", pid: 9437),
            hasCapturedPid: { $0 == 9437 },
            hasCapturedApp: { _ in true }
        )
        XCTAssertEqual(link, .pid(9437))
    }

    func testShowItsTrafficFallsBackToTheAppName() {
        let link = MCPAgentTrafficLink.resolve(
            client: client("Cursor", pid: 5000),
            hasCapturedPid: { _ in false },
            hasCapturedApp: { $0 == "Cursor" }
        )
        XCTAssertEqual(link, .app("Cursor"))
    }

    func testShowItsTrafficIsDisabledWithTheSettingsHintWhenNothingWasCaptured() {
        let link = MCPAgentTrafficLink.resolve(
            client: client("Claude Code", pid: 9437),
            hasCapturedPid: { _ in false },
            hasCapturedApp: { _ in false }
        )
        XCTAssertEqual(link, .unavailable(hint: "No captured requests from Claude Code yet. A command-line agent needs the environment in Settings ▸ Capture."))
    }

    func testAClientWithoutAPidNeverAsksTheIndexForOne() {
        var askedPid = false
        let link = MCPAgentTrafficLink.resolve(
            client: client("Cursor", pid: nil),
            hasCapturedPid: { _ in askedPid = true; return true },
            hasCapturedApp: { _ in false }
        )
        XCTAssertFalse(askedPid)
        if case .unavailable = link {} else { XCTFail("expected .unavailable, got \(link)") }
    }

    func testTheButtonTitleIsTheSpecs() {
        XCTAssertEqual(MCPAgentTrafficLink.title, "Show its traffic")
    }
}
