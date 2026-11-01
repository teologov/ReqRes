//
//  ProtocolSupportTests.swift
//  AppServices
//
//  Created by OloApps on 9/29/26.
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
//  Pins the ONE protocol table (protocol-engine doc §S10) and its three
//  renderings: Help ▸ Supported Protocols, diagnose_setup's
//  `supported_protocols` check and SKILL.md's generated block. An entry that
//  one rendering drops, or a SKILL.md edited by hand away from the table, is a
//  failing test here — the failure prints the block to paste.
//
//  Also pins the Help claims that CAN be checked from the package (the
//  HelpPatternExample idea): the proxy address the Help and the table quote is
//  the one the environment lines export, the NO_PROXY hosts Help names are the
//  block's, and the numbers in the table are the engine's.
//

import XCTest
@testable import MCPKit

final class ProtocolSupportTests: XCTestCase {

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/MCPKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AppServices
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private func entry(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> ProtocolSupportEntry {
        try XCTUnwrap(ProtocolSupport.all.first { $0.id == id }, "no entry \(id)", file: file, line: line)
    }

    // MARK: - The table

    func testEntriesAreUniqueAndComplete() {
        let entries = ProtocolSupport.all
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "ids are unique")
        XCTAssertEqual(Set(entries.map(\.name)).count, entries.count, "names are unique")
        for entry in entries {
            XCTAssertNotNil(entry.id.range(of: #"^[a-z0-9]+(_[a-z0-9]+)*$"#, options: .regularExpression), "\(entry.id) is snake_case")
            for (label, text) in [("whatYouSee", entry.whatYouSee), ("whatToDo", entry.whatToDo)] {
                XCTAssertFalse(text.isEmpty, "\(entry.id).\(label)")
                XCTAssertTrue(text.hasSuffix("."), "\(entry.id).\(label) is a sentence: \(text)")
                XCTAssertFalse(text.contains("\n"), "\(entry.id).\(label) is one paragraph (SKILL.md renders it as one bullet)")
            }
        }
    }

    /// Every situation the release names, with the status the
    /// embedded core earns it — a later change of status is a decision, and
    /// this test is where it shows up.
    func testEveryNamedSituationIsThereWithItsStatus() throws {
        let expected: [String: ProtocolSupportEntry.Status] = [
            "https": .supported,
            "https_untrusted": .relayed,
            "http": .supported,
            "http2": .beta,
            "websocket": .supported,
            "streams": .supported,
            "grpc_web": .supported,
            "grpc": .beta,
            "http3": .notCaptured,
            "other_tcp": .relayed,
            "excluded": .notCaptured,
            "proxy_ignored": .notCaptured,
            // Remembered and passed through since 2026-09-29 (learned pins).
            "pinned": .relayed,
            // Hosts on macOS's own pinning list (live-run F5): relayed and
            // recorded as "SSL pinned by macOS", never intercepted.
            "macos_pinned": .relayed,
            "mtls": .notCaptured,
        ]
        XCTAssertEqual(Set(ProtocolSupport.all.map(\.id)), Set(expected.keys), "an entry was added or removed — add it here with its status")
        for (id, status) in expected {
            XCTAssertEqual(try entry(id).status, status, id)
        }
    }

    /// Status is a word AND a symbol, never colour alone, and the four are
    /// told apart by both.
    func testEveryStatusHasItsOwnWordAndSymbol() {
        let statuses = ProtocolSupportEntry.Status.allCases
        XCTAssertEqual(Set(statuses.map(ProtocolSupport.statusLabel)).count, statuses.count)
        XCTAssertEqual(Set(statuses.map(ProtocolSupport.statusSymbol)).count, statuses.count)
        XCTAssertEqual(ProtocolSupport.statusLabel(.beta), "Beta, off by default")
        XCTAssertEqual(ProtocolSupportEntry.Status.notCaptured.rawValue, "not_captured", "the token agents read")
    }

    // MARK: - What the entries say, pinned to the code that makes it true

    /// Help ▸ Command-Line Tools says the proxy address is http:// even for
    /// HTTPS and that an https:// proxy URL does not work. The address the
    /// table and Help quote must BE the one the environment block exports.
    func testTheProxyAddressIsTheOneTheEnvironmentLinesExport() throws {
        let lines = CaptureEnvironmentLines(proxyPort: MCPLimits.proxyPort)
        XCTAssertEqual(ProtocolSupport.proxyURL(), lines.proxyURL)
        XCTAssertEqual(ProtocolSupport.proxyURL(), "http://127.0.0.1:\(MCPLimits.proxyPort)")
        XCTAssertTrue(lines.lines.contains { $0.hasPrefix("export HTTPS_PROXY=\(ProtocolSupport.proxyURL())") },
                      "HTTPS traffic is sent to an http:// proxy address")
        for id in ["proxy_ignored", "grpc"] {
            XCTAssertTrue(try entry(id).whatToDo.contains(ProtocolSupport.proxyURL()), id)
        }
        XCTAssertTrue(try entry("proxy_ignored").whatToDo.contains("an https:// proxy URL does not work"))
    }

    /// Help and the plain-HTTP entry say the lines leave localhost,
    /// 127.0.0.1 and ::1 out of the proxy, and that `unset NO_PROXY no_proxy`
    /// undoes it — true only while the block sets both spellings to that list.
    func testTheLocalhostBypassHelpDescribesIsTheBlocks() throws {
        XCTAssertEqual(CaptureEnvironmentLines.noProxyHosts, "localhost,127.0.0.1,::1")
        let lines = CaptureEnvironmentLines(proxyPort: MCPLimits.proxyPort).lines
        XCTAssertTrue(lines.contains { $0.hasPrefix("export NO_PROXY=\(CaptureEnvironmentLines.noProxyHosts)") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("export no_proxy=\(CaptureEnvironmentLines.noProxyHosts)") })
        let plain = try entry("http").whatToDo
        XCTAssertTrue(plain.contains("localhost, 127.0.0.1 and ::1"), plain)
        XCTAssertTrue(plain.contains("unset NO_PROXY no_proxy"), plain)

        let help = try source("../UI/Views/Help/HelpContent.swift")
        XCTAssertTrue(help.contains("localhost, 127.0.0.1 and ::1 out of the proxy (NO_PROXY)"), "Help's command-line topic names the bypass")
        XCTAssertTrue(help.contains("unset NO_PROXY no_proxy"))
        // The configured port since 2026-09-29 (Settings ▸ Capture ▸ Proxy port).
        XCTAssertTrue(help.contains("\\(ProtocolSupport.proxyURL(port: CaptureProxyPort.configured))"), "Help quotes the address from the table, not typed out")
    }

    /// The engine's numbers, never typed: D6's idle limits and the WebSocket
    /// retention (D10).
    func testTheNumbersAreTheEnginesAndTheLogs() throws {
        let websocket = try entry("websocket").whatYouSee
        XCTAssertTrue(websocket.contains("first \(SocketMessageLog.headCapacity) "), websocket)
        XCTAssertTrue(websocket.contains("last 2,000 "), websocket)
        XCTAssertEqual(SocketMessageLog.tailCapacity, 2_000, "the sentence above prints it with a comma")
        XCTAssertTrue(websocket.contains(CaptureEngineFacts.duration(CaptureEngineFacts.idleRelay)), websocket)
        XCTAssertTrue(try entry("streams").whatYouSee.contains(CaptureEngineFacts.duration(CaptureEngineFacts.idleWhileInFlight)))
        XCTAssertTrue(try entry("other_tcp").whatYouSee.contains(CaptureEngineFacts.duration(CaptureEngineFacts.idleBetweenExchanges)))
    }

    /// The HTTP/2 entries speak the setting's own words (doc §S9).
    func testTheHTTP2EntriesUseTheSettingsWords() throws {
        let http2 = try entry("http2")
        XCTAssertTrue(http2.whatYouSee.contains(HTTP2CaptureCopy.toggleTitle))
        XCTAssertTrue(http2.whatYouSee.contains(HTTP2CaptureCopy.mockedHostsNote))
        XCTAssertTrue(http2.whatToDo.contains(HTTP2CaptureCopy.toggleTitle))
        XCTAssertTrue(try entry("grpc").whatToDo.contains(HTTP2CaptureCopy.toggleTitle))
    }

    /// What the PRD's pre-fix table said and the 1.1.0 core no longer does
    /// must not come back through this table.
    func testNoPreFixClaimSurvives() {
        let everything = ProtocolSupport.all.map { "\($0.whatYouSee) \($0.whatToDo)" }.joined(separator: " ")
        for stale in ["port 80 only", "X-Req-Res-Server", "0.65", "never multiplexed", "recorded empty", "hangs"] {
            XCTAssertFalse(everything.contains(stale), "stale claim: \(stale)")
        }
    }

    // MARK: - Rendering 1: Help

    func testHelpRendersEveryEntryWithAWordAndASymbol() {
        let rows = ProtocolSupport.helpRows
        XCTAssertEqual(rows.map(\.id), ProtocolSupport.all.map(\.id), "one row per entry, in table order")
        for (row, entry) in zip(rows, ProtocolSupport.all) {
            XCTAssertEqual(row.title, entry.name)
            XCTAssertEqual(row.statusLabel, ProtocolSupport.statusLabel(entry.status))
            XCTAssertEqual(row.statusSymbol, ProtocolSupport.statusSymbol(entry.status))
            XCTAssertEqual(row.whatYouSee, "\(ProtocolSupport.seeLabel) \(entry.whatYouSee)")
            XCTAssertEqual(row.whatToDo, "\(ProtocolSupport.doLabel) \(entry.whatToDo)")
            XCTAssertTrue(row.accessibilityLabel.contains(row.statusLabel), "VoiceOver hears the status word")
        }
    }

    /// The Help topic exists and draws `helpRows` — the app target has no test
    /// target, so this reads the source the way `MCPToolSurfaceTests` reads the
    /// server's.
    func testTheHelpTopicDrawsTheRows() throws {
        let help = try source("../UI/Views/Help/HelpContent.swift")
        XCTAssertTrue(help.contains("case .protocols: return ProtocolSupport.helpTitle"), "the topic is titled from the table")
        XCTAssertTrue(help.contains("case .protocols: protocolsTopic"), "the topic is in helpContent(for:)")
        XCTAssertTrue(help.contains("ForEach(ProtocolSupport.helpRows)"), "the topic draws every row")
        XCTAssertTrue(help.contains("helpParagraph(row.whatYouSee)") && help.contains("helpParagraph(row.whatToDo)"))
        XCTAssertTrue(help.contains("Text(row.statusLabel)") && help.contains("Image(systemName: row.statusSymbol)"),
                      "the status is a word and a symbol")
        XCTAssertEqual(ProtocolSupport.helpTitle, "Supported Protocols")
    }

    // MARK: - Rendering 2: diagnose_setup

    private func facts(capture: Bool = true, vpn: String = "connected", extensionStatus: String = "ready") -> MCPSetupFacts {
        var status = StubStatusProvider().status
        status.captureActive = capture
        status.vpnStatus = vpn
        status.extensionStatus = extensionStatus
        return MCPSetupFacts(status: status, runningFromApplications: true, proxyPort: MCPLimits.proxyPort, proxyPortListening: capture)
    }

    /// Every state carries every entry's name and status token; a state with
    /// no blocking check carries the full prose, a blocking one the short
    /// form (~2K tokens of informational text beside the one check the agent
    /// must act on).
    func testDiagnosisRendersEveryEntryInEveryState() throws {
        var sawBlocking = false, sawClear = false
        for (label, facts) in [
            ("healthy", facts()),
            ("stopped", facts(capture: false, vpn: "disconnected")),
            ("no extension", facts(capture: false, vpn: "disconnected", extensionStatus: "notInstalled")),
        ] {
            let report = MCPSetupDiagnosis.report(facts)
            let check = try XCTUnwrap(report.checks.first { $0.id == ProtocolSupport.diagnosisCheckId }, label)
            XCTAssertEqual(check.state, .ok, "\(label): informational")
            XCTAssertNil(check.fix, label)
            XCTAssertEqual(check.title, ProtocolSupport.diagnosisTitle)
            XCTAssertNotEqual(report.blockingCheckId, ProtocolSupport.diagnosisCheckId)
            let blocking = report.blockingCheckId != nil
            if blocking { sawBlocking = true } else { sawClear = true }
            for entry in ProtocolSupport.all {
                XCTAssertTrue(check.detail.contains(blocking ? ProtocolSupport.indexLine(entry) : ProtocolSupport.agentLine(entry)), "\(label): \(entry.id) missing from diagnose_setup")
                XCTAssertTrue(check.detail.contains("[\(entry.status.rawValue)]"), "\(label): \(entry.id)'s status token")
                XCTAssertEqual(check.detail.contains(ProtocolSupport.agentLine(entry)), !blocking,
                               "\(label): full prose only when nothing blocks (\(entry.id))")
            }
            XCTAssertEqual(report.checks.last?.id, "proxy_aware_clients", "\(label): the proxy-aware note stays last")
        }
        XCTAssertTrue(sawBlocking && sawClear, "the three states cover both forms")
    }

    /// The short form is a fraction of the full one and says why it is short.
    func testABlockingReportCarriesOnlyTheShortList() throws {
        let brokenFacts = facts(capture: false, vpn: "disconnected", extensionStatus: "notInstalled")
        let broken = MCPSetupDiagnosis.report(brokenFacts)
        XCTAssertNotNil(broken.blockingCheckId)
        let short = try XCTUnwrap(broken.checks.first { $0.id == ProtocolSupport.diagnosisCheckId }).detail
        let full = ProtocolSupport.diagnosisCheck().detail
        XCTAssertTrue(short.hasPrefix(ProtocolSupport.diagnosisIndexIntro), short)
        XCTAssertLessThan(short.count, 1_500, short)
        XCTAssertGreaterThan(full.count, 5_000)
        XCTAssertEqual(short, ProtocolSupport.diagnosisCheck(compact: true, state: ProtocolSupportState(facts: brokenFacts)).detail)
        XCTAssertFalse(broken.verdict.contains(ProtocolSupport.diagnosisIndexIntro), "never the verdict")
    }

    // MARK: - Review fixes (doc §S10)

    /// The core needs a second bare hang-up within 30 s before it counts one
    /// (core TLSClientRejections) — an alert counts at once — and since the
    /// learned pins (2026-09-29) a counted refusal is remembered and the app's
    /// later connections to that domain pass through, marked SSL pinned.
    func testThePinnedEntrySaysWhatCountsAndThatItIsRemembered() throws {
        XCTAssertEqual(CaptureEngineFacts.tlsRefusalWindow, 30, "mirrors core TLSClientRejections.window")
        let text = try entry("pinned").whatYouSee
        XCTAssertTrue(text.contains("a bare hang-up only when it repeats within \(CaptureEngineFacts.duration(CaptureEngineFacts.tlsRefusalWindow))"), text)
        XCTAssertTrue(text.contains("An alert counts at once"), text)
        XCTAssertTrue(text.contains("marked SSL pinned by the app"), text)
        XCTAssertFalse(text.contains("Each refusal is a failed row"), text)
    }

    /// Plain http:// to an excluded host still goes through the plain-HTTP
    /// front (URI to origin-form, hop-by-hop headers stripped); only HTTPS is
    /// passed through untouched.
    func testTheExcludedEntryDoesNotCallPlainHTTPUnchanged() throws {
        let text = try entry("excluded").whatYouSee
        XCTAssertFalse(text.contains("not changed"), text)
        XCTAssertTrue(text.contains("HTTPS to it is passed straight through untouched"), text)
        XCTAssertTrue(text.contains("Plain http:// to it is forwarded as any proxy forwards it (hop-by-hop headers removed)"), text)
        XCTAssertTrue(FailureRowCopy.exclusionScope.contains("hop-by-hop headers removed"))
        XCTAssertTrue(FailureRowCopy.exclusionScope.contains("from the next one"))
    }

    /// `relayed` covers tcp relays (SSH, a database), which the certificate
    /// has nothing to do with, so its word must not say "decrypted" either.
    func testTheRelayedStatusNeverBlamesDecryption() throws {
        XCTAssertEqual(ProtocolSupport.statusLabel(.relayed), "Relayed, not read")
        XCTAssertFalse(ProtocolSupport.agentLine(try entry("other_tcp")).contains("decrypted"))
        XCTAssertFalse(ProtocolSupport.skillSection.contains("never decrypted"))
        XCTAssertTrue(ProtocolSupport.skillSection.contains("`relayed` (one row per connection; what it carries is never read)"))
    }

    func testTheDiagnosisCheckNeverChangesTheVerdict() {
        XCTAssertEqual(MCPSetupDiagnosis.report(facts()).verdict, "Capture is running and set up correctly.")
    }

    /// An agent reads it through the same text formatter as every check.
    func testTheAgentsTextCarriesTheList() {
        let text = MCPTextFormat.diagnosis(MCPSetupDiagnosis.report(facts()))
        XCTAssertTrue(text.contains("ok   \(ProtocolSupport.diagnosisTitle): \(ProtocolSupport.diagnosisIntro)"), text)
        XCTAssertTrue(text.contains("  - HTTP/3 (QUIC) — not captured [not_captured]."), text)
    }

    // MARK: - Rendering 2b: capture_status (doc §S13)

    private func status(caInstalled: Bool? = true, caTrusted: Bool? = true, http2: Bool? = false) -> MCPBridgeStatus {
        var status = StubStatusProvider().status
        status.caCertificateInstalled = caInstalled
        status.caCertificateTrusted = caTrusted
        status.http2CaptureEnabled = http2
        return status
    }

    /// The two states that change its text: the certificate (decrypting or
    /// not) and the HTTP/2 setting (on or off) — every entry's short line is
    /// there in each, and the four state-dependent entries say what this Mac
    /// makes of them.
    func testCaptureStatusListsEveryEntryInEveryState() throws {
        let states: [(String, MCPBridgeStatus)] = [
            ("decrypting, h2 off", status()),
            ("decrypting, h2 on", status(http2: true)),
            ("no CA", status(caInstalled: false, caTrusted: nil)),
            ("installed, untrusted", status(caTrusted: false)),
        ]
        var texts: [String: String] = [:]
        for (label, status) in states {
            let text = MCPTextFormat.status(status, listingProtocols: true)
            texts[label] = text
            XCTAssertTrue(text.contains(ProtocolSupport.statusIntro), label)
            for entry in ProtocolSupport.all {
                XCTAssertTrue(text.contains("  - " + ProtocolSupport.indexLine(entry)), "\(label): \(entry.id) missing from capture_status")
                XCTAssertFalse(text.contains(entry.whatYouSee), "\(label): \(entry.id)'s prose belongs to diagnose_setup, not the polled status")
            }
        }
        let https = try entry("https"), untrusted = try entry("https_untrusted"), h2 = try entry("http2"), grpc = try entry("grpc")
        func line(_ entry: ProtocolSupportEntry, _ label: String) -> String? {
            texts[label]?.components(separatedBy: "\n").first { $0.hasPrefix("  - " + ProtocolSupport.indexLine(entry)) }
        }
        XCTAssertEqual(line(h2, "decrypting, h2 off"), "  - HTTP/2 [beta] — HTTP/2 capture is off (the default)")
        XCTAssertEqual(line(h2, "decrypting, h2 on"), "  - HTTP/2 [beta] — HTTP/2 capture is on")
        XCTAssertNotEqual(line(grpc, "decrypting, h2 off"), line(grpc, "decrypting, h2 on"))
        XCTAssertEqual(line(https, "decrypting, h2 off"), "  - HTTPS (HTTP/1.1) [supported] — in effect: the ReqRes CA is installed and trusted")
        XCTAssertEqual(line(untrusted, "decrypting, h2 off"), "  - " + ProtocolSupport.indexLine(untrusted), "no note once the CA decrypts")
        for label in ["no CA", "installed, untrusted"] {
            XCTAssertTrue(line(https, label)?.contains("not yet") == true, label)
            XCTAssertEqual(line(untrusted, label), "  - " + ProtocolSupport.indexLine(untrusted) + " — in effect on this Mac now", label)
        }
        // The note names the step the human is missing, and never contradicts
        // the "ReqRes CA installed: yes" line above it (S13 review).
        XCTAssertEqual(line(https, "no CA"), "  - HTTPS (HTTP/1.1) [supported] — not yet: the ReqRes CA is not installed, so HTTPS is relayed")
        XCTAssertEqual(line(https, "installed, untrusted"), "  - HTTPS (HTTP/1.1) [supported] — not yet: the ReqRes CA is installed but not trusted, so HTTPS is relayed")
        XCTAssertEqual(ProtocolSupport.stateNote(https, state: ProtocolSupportState(httpsDecrypted: false, http2CaptureEnabled: nil)),
                       "not yet: the ReqRes CA is not installed and trusted, so HTTPS is relayed", "unknown install state names both steps")
    }

    /// The status line above the list says what the engine does since core
    /// C7/C8 — a relayed connection, no requests — like the certificate
    /// checks do, never the pre-C7 "bodies stay encrypted" (S13 review).
    func testTheCertificateStatusLinesSayRelayed() {
        let noCA = MCPTextFormat.status(status(caInstalled: false, caTrusted: nil), listingProtocols: true)
        let untrustedCA = MCPTextFormat.status(status(caTrusted: false), listingProtocols: true)
        let trustedCA = MCPTextFormat.status(status(), listingProtocols: true)
        for text in [noCA, untrustedCA, trustedCA] {
            XCTAssertFalse(text.contains("bodies stay encrypted"))
        }
        XCTAssertTrue(noCA.contains("ReqRes CA installed: no — each HTTPS connection is relayed (one kind=relay row per connection, no requests) until it is installed and trusted"))
        XCTAssertFalse(noCA.contains("ReqRes CA trusted:"), "no trust line for a certificate that is not there")
        XCTAssertTrue(untrustedCA.contains("ReqRes CA installed: yes\nReqRes CA trusted: no — each HTTPS connection is relayed (one kind=relay row per connection, no requests) until it is trusted"))
        XCTAssertFalse(trustedCA.contains("ReqRes CA trusted:"), "trusted is the normal state and says nothing")
        XCTAssertFalse(MCPTextFormat.status(status(caTrusted: nil)).contains("ReqRes CA trusted:"), "unknown trust is not reported as untrusted")
    }

    /// Could not tell ⇒ no note, never a guess (the diagnosis's `.unknown`).
    func testAnUnreadableStateAddsNoNote() {
        let text = MCPTextFormat.status(status(caInstalled: nil, caTrusted: nil, http2: nil), listingProtocols: true)
        for entry in ProtocolSupport.all {
            XCTAssertTrue(text.contains("  - " + ProtocolSupport.indexLine(entry) + "\n") || text.hasSuffix("  - " + ProtocolSupport.indexLine(entry)), entry.id)
        }
        XCTAssertEqual(ProtocolSupport.state(for: status(caInstalled: true, caTrusted: nil)).httpsDecrypted, nil)
    }

    /// Reuse, never re-derive: the notes come from the facts diagnose_setup
    /// reads, through its own certificate checks, so a blocked diagnose_setup
    /// and capture_status print the same short lines for the same Mac.
    func testCaptureStatusAndABlockedDiagnosisPrintTheSameLines() throws {
        for (installed, trusted) in [(true, true), (true, false), (false, nil), (nil, nil)] as [(Bool?, Bool?)] {
            for http2 in [true, false] as [Bool?] {
                var current = status(caInstalled: installed, caTrusted: trusted, http2: http2)
                current.captureActive = false
                current.vpnStatus = "disconnected"
                current.extensionStatus = "notInstalled"
                let report = MCPSetupDiagnosis.report(MCPSetupFacts(status: current, runningFromApplications: true, proxyPort: MCPLimits.proxyPort))
                XCTAssertNotNil(report.blockingCheckId)
                let short = try XCTUnwrap(report.checks.first { $0.id == ProtocolSupport.diagnosisCheckId }).detail
                let listed = ProtocolSupport.statusLines(state: ProtocolSupport.state(for: current)).map { "  - " + $0.text }
                XCTAssertEqual(short, ([ProtocolSupport.diagnosisIndexIntro] + listed).joined(separator: "\n"), "\(String(describing: installed))/\(String(describing: trusted))/\(String(describing: http2))")
                let http2Check = report.checks.first { $0.id == "http2_capture" }
                XCTAssertEqual(http2Check?.detail, HTTP2CaptureCopy.diagnosisDetail(enabled: http2 ?? false), "the setting on the status reaches the http2_capture check")
                let caReady = ProtocolSupport.state(for: current).httpsDecrypted
                let certificateStates = report.checks.filter { $0.id == "certificate_installed" || $0.id == "certificate_trusted" }.map(\.state)
                XCTAssertFalse(certificateStates.isEmpty)
                switch caReady {
                case true?: XCTAssertTrue(certificateStates.allSatisfy { $0 == .ok })
                case false?: XCTAssertTrue(certificateStates.contains(.warning))
                case nil: XCTAssertTrue(certificateStates.contains(.unknown))
                }
                let installedCheck = report.checks.first { $0.id == "certificate_installed" }?.state
                XCTAssertEqual(ProtocolSupport.state(for: current).caInstalled, installedCheck == .ok ? true : installedCheck == .unknown ? nil : false,
                               "caInstalled is read from the certificate_installed check")
            }
        }
    }

    /// The bridge sends the list structured, filled on /v1/status only.
    func testTheStatusRouteCarriesTheStructuredList() throws {
        let provider = StubStatusProvider(status: status(caTrusted: false, http2: true))
        let router = MCPBridgeRouter(token: "tok", sessions: StubSessionProvider(), status: provider)
        let parsed = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/status", token: "tok"))))
        XCTAssertEqual(parsed.status, 200)
        let decoded = try JSONDecoder().decode(MCPBridgeStatus.self, from: parsed.body)
        let lines = try XCTUnwrap(decoded.protocols)
        XCTAssertEqual(lines.map(\.id), ProtocolSupport.all.map(\.id))
        XCTAssertEqual(lines.map(\.status), ProtocolSupport.all.map(\.status.rawValue))
        XCTAssertEqual(lines, ProtocolSupport.statusLines(state: ProtocolSupportState(httpsDecrypted: false, http2CaptureEnabled: true, caInstalled: true)))
        XCTAssertEqual(decoded.http2CaptureEnabled, true)
        XCTAssertEqual(MCPTextFormat.status(decoded, listingProtocols: true), MCPTextFormat.status(provider.status, listingProtocols: true),
                       "the text from the bridge's list and from the helper's own table are the same bytes")
        XCTAssertNil(provider.status.protocols, "the provider's status is not where the list comes from")
    }

    /// start_capture and stop_capture print the status alone; capture_status
    /// adds the list — and stays small, because it is called often.
    func testTheListIsCaptureStatusOnlyAndSmall() throws {
        let plain = MCPTextFormat.status(status())
        XCTAssertFalse(plain.contains(ProtocolSupport.statusIntro))
        for current in [status(), status(caInstalled: false, caTrusted: nil)] {
            let listed = MCPTextFormat.status(current, listingProtocols: true)
            XCTAssertTrue(listed.hasPrefix(MCPTextFormat.status(current)))
            let added = listed.count - MCPTextFormat.status(current).count
            XCTAssertLessThan(added, 1_400, "capture_status's list: \(added) characters")
        }
        let server = try source("Sources/reqres-mcp/ReqResMCPServer.swift")
        XCTAssertTrue(server.contains("MCPTextFormat.status(try await client.status(), listingProtocols: true)"), "capture_status prints the list")
        XCTAssertTrue(server.contains("MCPTextFormat.status(try await client.capture(.start)))"), "start_capture does not")
        XCTAssertTrue(server.contains("MCPTextFormat.status(try await client.capture(.stop)))"), "stop_capture does not")
    }

    /// The tool text and SKILL.md say the list is there.
    func testCaptureStatusDescriptionAndSkillSayItListsProtocols() throws {
        let server = try source("Sources/reqres-mcp/ReqResMCPServer.swift")
        let description = try XCTUnwrap(server.components(separatedBy: "\n").first { $0.contains("description: \"Readiness snapshot of ReqRes") })
        XCTAssertTrue(description.contains("what each protocol does"), description)
        for token in ProtocolSupportEntry.Status.allCases.map(\.rawValue) {
            XCTAssertTrue(description.contains(token), "description names \(token)")
        }
        let skill = try source("Sources/reqres-mcp/SKILL.md")
        XCTAssertTrue(skill.contains("It also lists what each protocol does"), "SKILL.md's Start here")
        XCTAssertTrue(ProtocolSupport.skillSection.contains("`capture_status` lists every entry"))
    }

    // MARK: - Rendering 3: SKILL.md

    func testSkillCarriesTheGeneratedBlockVerbatim() throws {
        let skill = try source("Sources/reqres-mcp/SKILL.md")
        XCTAssertTrue(
            skill.contains(ProtocolSupport.skillSection),
            "SKILL.md's Supported protocols block differs from ProtocolSupport — replace everything between the markers with:\n\n\(ProtocolSupport.skillSection)\n"
        )
        XCTAssertEqual(skill.components(separatedBy: ProtocolSupport.skillBeginMarker).count, 2, "one block, not two")
        for entry in ProtocolSupport.all {
            XCTAssertTrue(skill.contains("- **\(entry.name)** — `\(entry.status.rawValue)`."), entry.id)
        }
        XCTAssertTrue(skill.contains("## Supported protocols"), "the block sits under its own heading")
    }

    /// create_rule's path example used to be `^/users/\\d+$` — the anchored
    /// form the core can NEVER match, because it puts scheme://host in front
    /// of the pattern (protocol PRD §0.2, `:256`). The examples the tool now
    /// gives must pass the bridge's own validation and match what they say.
    func testCreateRulesPathExamplesAreOnesTheProxyMatches() throws {
        let server = try source("Sources/reqres-mcp/ReqResMCPServer.swift")
        XCTAssertFalse(server.contains("^/users"), "an anchored example cannot match")
        XCTAssertTrue(server.contains(#"e.g. /users?* (wildcard) or /users/\\d+$ (regex"#))
        let regex = #"/users/\d+$"#
        XCTAssertEqual(try MCPWriteValidation.normalizedPath(regex, matchType: .regex), regex)
        XCTAssertTrue(OverridePattern.matches(url: "https://api.example.com/users/42", path: regex, isRegex: true))
        XCTAssertFalse(OverridePattern.matches(url: "https://api.example.com/users/42/orders", path: regex, isRegex: true))
        XCTAssertFalse(OverridePattern.matches(url: "https://api.example.com/users/42", path: "^" + regex, isRegex: true),
                       "the old example, for the record")
        XCTAssertTrue(OverridePattern.matches(url: "http://localhost:3000/users?page=2", path: "/users?*", isRegex: false))
    }

    /// The server's diagnose_setup description tells the agent the list is
    /// there, so it knows to read it before calling a protocol broken.
    func testTheDiagnoseToolDescriptionPointsAtTheCheck() throws {
        let server = try source("Sources/reqres-mcp/ReqResMCPServer.swift")
        XCTAssertTrue(server.contains("supported_protocols"), "diagnose_setup's description names the check")
    }
}

/// A relay row whose scheme is `tcp` (core C5/C7: the app spoke neither HTTP
/// nor TLS through the proxy) is relayed whatever the certificate's state, so
/// every sentence that blamed the certificate was false for it (doc §S10).
final class TCPRelayCopyTests: XCTestCase {

    private func relay(scheme: String) -> MCPSessionSummary {
        MCPSessionSummary(
            uid: "r1", host: "db.internal:5432", method: "CONNECT", url: "tcp://db.internal:5432",
            scheme: scheme, statusCode: nil, durationMs: 1_200, requestBodySize: 300, responseBodySize: 900,
            kind: .relay
        )
    }

    func testATCPRelayIsNeverBlamedOnTheCertificate() {
        for text in [
            RecordedExchangeCopy.relayExplanation(scheme: "tcp"),
            RecordedExchangeCopy.relayRemedy(scheme: "tcp"),
            RecordedExchangeCopy.relayCellHelp(scheme: "TCP"),
            RecordedExchangeCopy.relayTitle(scheme: "tcp"),
            RecordedExchangeCopy.relayRowWord(scheme: "tcp"),
        ] {
            XCTAssertFalse(text.lowercased().contains("certificate"), text)
            XCTAssertFalse(text.contains("decrypted"), text)
        }
        XCTAssertEqual(RecordedExchangeCopy.relayTitle(scheme: "tcp"), "Not HTTP")
        XCTAssertEqual(RecordedExchangeCopy.relayRowWord(scheme: "tcp"), "not HTTP")
    }

    func testATLSRelayKeepsTheCertificateSentences() {
        XCTAssertEqual(RecordedExchangeCopy.relayExplanation(scheme: "https"), RecordedExchangeCopy.relayExplanation)
        XCTAssertEqual(RecordedExchangeCopy.relayRemedy(scheme: "https"), RecordedExchangeCopy.relayRemedy)
        XCTAssertEqual(RecordedExchangeCopy.relayCellHelp(scheme: "https"), RecordedExchangeCopy.relayCellHelp)
        XCTAssertEqual(RecordedExchangeCopy.relayTitle(scheme: "https"), RecordedExchangeCopy.relayTitle)
        XCTAssertEqual(RecordedExchangeCopy.relayRowWord(scheme: "https"), "not decrypted")
        XCTAssertEqual(RecordedExchangeCopy.relayExplanation(scheme: nil), RecordedExchangeCopy.relayExplanationAnyScheme)
    }

    func testTheAgentsRowDetailAndHARFollowTheScheme() throws {
        let row = MCPTextFormat.row(relay(scheme: "tcp"))
        XCTAssertTrue(row.contains("(not HTTP)"), row)
        XCTAssertFalse(row.contains("not decrypted"), row)
        XCTAssertTrue(MCPTextFormat.row(relay(scheme: "https")).contains("(not decrypted)"))

        let detail = MCPTextFormat.detail(MCPSessionDetail(summary: relay(scheme: "tcp")))
        XCTAssertTrue(detail.contains(RecordedExchangeCopy.tcpRelayExplanation), detail)
        XCTAssertFalse(detail.contains(RecordedExchangeCopy.relayExplanation), detail)

        let result = MCPHARExport.encode(sessions: [MCPSessionDetail(summary: relay(scheme: "tcp"))], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let entry = try XCTUnwrap(((json["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["comment"] as? String, RecordedExchangeCopy.tcpRelayExplanation)
    }

    /// The bridge's 404s for a relay do not know the scheme, so they say
    /// either reason rather than the wrong one.
    func testTheSchemelessSentenceNamesBothReasons() {
        let text = RecordedExchangeCopy.relayExplanationAnyScheme
        XCTAssertTrue(text.contains("not decrypted"), text)
        XCTAssertTrue(text.contains("neither HTTP nor TLS"), text)
    }

    // MARK: - The proxy port (2026-09-29)

    /// The helper renders what the APP says the port is: capture_status's
    /// Proxy line, capture_environment's lines, diagnose_setup's facts.
    func testTheHelperUsesTheStatusPort() {
        let moved = MCPBridgeStatus(captureActive: true, vpnStatus: "connected", extensionStatus: "ready", proxyPort: 9034)
        XCTAssertEqual(moved.effectiveProxyPort, 9034)
        XCTAssertTrue(MCPTextFormat.status(moved).contains("Proxy: 127.0.0.1:9034"), MCPTextFormat.status(moved))
        XCTAssertTrue(MCPCaptureEnvironment.render(status: moved).contains("http://127.0.0.1:9034"))
        XCTAssertFalse(MCPCaptureEnvironment.render(status: moved).contains(":8034"))

        let older = MCPBridgeStatus(captureActive: true, vpnStatus: "connected", extensionStatus: "ready")
        XCTAssertEqual(older.effectiveProxyPort, 8034, "an app that predates the setting used 8034")
        XCTAssertTrue(MCPTextFormat.status(older).contains("Proxy: 127.0.0.1:8034"))
    }

    /// zstd is decoded since 2026-09-29 (core: facebook/zstd): the table says
    /// so, and no longer that it is kept as sent.
    func testTheTableSaysZstdIsDecoded() throws {
        let https = try XCTUnwrap(ProtocolSupport.all.first { $0.id == "https" }).whatYouSee
        XCTAssertTrue(https.contains("gzip, deflate, brotli and zstd"), https)
        XCTAssertFalse(https.contains("zstd is kept as sent"), https)
    }
}
