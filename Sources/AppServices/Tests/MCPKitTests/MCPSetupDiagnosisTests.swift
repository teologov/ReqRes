//
//  MCPSetupDiagnosisTests.swift
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
//  Roadmap item 6. The value of this tool is entirely in WHICH failure it
//  names: every broken setup has several checks failing at once, and pointing
//  at the last one sends the agent and the user chasing a symptom.
//

import XCTest
@testable import MCPKit

final class MCPSetupDiagnosisTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func facts(
        capture: Bool = true,
        vpn: String = "connected",
        extensionStatus: String = "ready",
        caInstalled: Bool? = true,
        caTrusted: Bool? = true,
        sessions: Int = 5,
        inApplications: Bool? = true,
        listening: Bool? = true,
        used: Int? = 0,
        limit: Int? = 10,
        licensed: Bool? = false,
        lastSessionAt: Date? = nil,
        attribution: Bool? = nil,
        tableLoaded: Bool? = nil,
        placeable: Int? = nil,
        withoutAddress: Int? = nil
    ) -> MCPSetupFacts {
        MCPSetupFacts(
            status: MCPBridgeStatus(
                captureActive: capture,
                vpnStatus: vpn,
                extensionStatus: extensionStatus,
                caCertificateInstalled: caInstalled,
                caCertificateTrusted: caTrusted,
                sessionCount: sessions,
                appVersion: "1.0.5"
            ),
            runningFromApplications: inApplications,
            proxyPort: 8034,
            proxyPortListening: listening,
            freeInspectionsUsed: used,
            freeInspectionsLimit: limit,
            licensed: licensed,
            lastSessionAt: lastSessionAt ?? now,
            processAttribution: attribution,
            destinationTableLoaded: tableLoaded,
            destinationsPlaceable: placeable,
            destinationsWithoutAddress: withoutAddress,
            now: now
        )
    }

    private func check(_ report: MCPSetupReport, _ id: String) -> MCPSetupCheck? {
        report.checks.first { $0.id == id }
    }

    // MARK: - Healthy

    func testAWorkingSetupSaysSoAndBlocksOnNothing() {
        let report = MCPSetupDiagnosis.report(facts())

        XCTAssertTrue(report.capturing)
        XCTAssertNil(report.blockingCheckId)
        XCTAssertEqual(report.verdict, "Capture is running and set up correctly.")
        XCTAssertTrue(report.checks.allSatisfy { $0.state == .ok })
    }

    func testNothingBrokenButStoppedPointsAtStartCapture() {
        let report = MCPSetupDiagnosis.report(facts(capture: false, vpn: "disconnected", sessions: 0))

        XCTAssertFalse(report.capturing)
        XCTAssertEqual(report.blockingCheckId, "tunnel")
        XCTAssertEqual(check(report, "tunnel")?.fix, "Call start_capture.")
    }

    // MARK: - The order is the whole point

    /// An app outside /Applications cannot activate its extension, which
    /// cannot start a tunnel. Naming the tunnel would be true and useless.
    func testTheCauseIsReportedNotTheSymptom() {
        let report = MCPSetupDiagnosis.report(facts(
            capture: false, vpn: "disconnected", extensionStatus: "notInstalled",
            caInstalled: false, sessions: 0, inApplications: false, listening: nil
        ))

        XCTAssertEqual(report.blockingCheckId, "location")
        XCTAssertTrue(report.verdict.contains("/Applications"))
        XCTAssertEqual(check(report, "extension")?.state, .problem, "still reported, just not blamed")
    }

    /// Once the extension is running, where the app sits stops mattering — a
    /// dev build launched from DerivedData with an approved extension is not
    /// broken, and saying so would send someone to move a working app.
    func testLocationIsNotHeldAgainstAnAlreadyRunningExtension() {
        let report = MCPSetupDiagnosis.report(facts(inApplications: false))

        XCTAssertEqual(check(report, "location")?.state, .ok)
        XCTAssertNil(report.blockingCheckId)
    }

    func testEachExtensionStateGetsItsOwnInstruction() {
        for (status, needle) in [
            ("extensionDisabled", "ⓘ"),
            ("configurationMissing", "VPN configuration"),
            ("needsRestart", "restart the Mac"),
            ("notInstalled", "capture button"),
        ] {
            let report = MCPSetupDiagnosis.report(facts(extensionStatus: status))
            let check = check(report, "extension")
            XCTAssertEqual(check?.state, .problem, "\(status)")
            XCTAssertTrue(check?.fix?.contains(needle) == true, "\(status) should tell the user about \(needle): \(check?.fix ?? "-")")
        }
    }

    // MARK: - The pair that used to disagree

    /// NetworkExtension was once told the tunnel had started when the proxy
    /// had failed to bind, so macOS and the app both showed connected with
    /// nothing behind them. The diagnosis has to be able to say that.
    func testAConnectedTunnelWithADeadPortIsAProblem() {
        let report = MCPSetupDiagnosis.report(facts(sessions: 0, listening: false))

        XCTAssertEqual(report.blockingCheckId, "proxy")
        XCTAssertTrue(report.verdict.contains("8034"))
        XCTAssertFalse(report.capturing)
    }

    func testThePortIsNotCheckedWhileCaptureIsOff() {
        let report = MCPSetupDiagnosis.report(facts(capture: false, vpn: "disconnected", listening: false))

        XCTAssertNil(check(report, "proxy"), "a port that nothing should be listening on is not a finding")
    }

    // MARK: - Certificates

    /// HTTPS without trust still captures — that is what makes it confusing,
    /// and why it is a warning that explains rather than a hard failure.
    func testAnUntrustedCertificateWarnsWithoutBlocking() {
        let report = MCPSetupDiagnosis.report(facts(caTrusted: false))

        XCTAssertNil(report.blockingCheckId)
        XCTAssertEqual(check(report, "certificate_trusted")?.state, .warning)
        XCTAssertTrue(report.verdict.contains("not trusted"))
    }

    func testAMissingCertificateDoesNotAlsoComplainAboutTrust() {
        let report = MCPSetupDiagnosis.report(facts(caInstalled: false, caTrusted: nil))

        XCTAssertEqual(check(report, "certificate_installed")?.state, .warning)
        XCTAssertNil(check(report, "certificate_trusted"))
    }

    // MARK: - The free tier, which looks exactly like a bug

    func testExhaustedFreeInspectionsAreExplained() {
        let report = MCPSetupDiagnosis.report(facts(used: 10, limit: 10))

        let check = check(report, "free_limit")
        XCTAssertEqual(check?.state, .warning)
        // What the cap really gates: the window's detail pane. Capture and
        // agent reads go on (release review, 2026-09-29 — it used to say
        // "new HTTPS requests are no longer inspected").
        XCTAssertFalse(check?.detail.contains("no longer inspected") == true)
        XCTAssertTrue(check?.detail.contains("will not open more HTTPS request details") == true, check?.detail ?? "")
        XCTAssertTrue(check?.detail.contains("agent reads") == true)
        XCTAssertTrue(check?.fix?.contains("relaunch") == true)
    }

    /// Without the CA, or with it untrusted, HTTPS is RELAYED — one
    /// kind=relay row per connection, no requests at all — not "captured
    /// without readable bodies" (release review, 2026-09-29).
    func testTheCertificateChecksDescribeRelayRows() {
        let missing = check(MCPSetupDiagnosis.report(facts(caInstalled: false)), "certificate_installed")
        XCTAssertTrue(missing?.detail.contains("relay") == true, missing?.detail ?? "")
        XCTAssertFalse(missing?.detail.contains("bodies cannot be read") == true)
        XCTAssertFalse(missing?.fix?.contains("window that opens") == true)

        let untrusted = check(MCPSetupDiagnosis.report(facts(caTrusted: false)), "certificate_trusted")
        XCTAssertTrue(untrusted?.detail.contains("relay") == true, untrusted?.detail ?? "")
        XCTAssertFalse(untrusted?.detail.contains("captured without readable bodies") == true)
    }

    func testALicensedUserIsNotToldAboutALimitTheyDoNotHave() {
        let report = MCPSetupDiagnosis.report(facts(used: 99, limit: 10, licensed: true))

        XCTAssertNil(check(report, "free_limit"))
    }

    // MARK: - Traffic

    func testCapturingWithNothingRecordedAsksForARequest() {
        let report = MCPSetupDiagnosis.report(facts(sessions: 0))

        XCTAssertEqual(check(report, "traffic")?.state, .warning)
        XCTAssertTrue(report.verdict.contains("nothing has been recorded"))
    }

    func testAQuietPeriodIsMentionedButIsNotAFailure() {
        let quiet = now.addingTimeInterval(-MCPSetupDiagnosis.quietPeriod - 60)
        let report = MCPSetupDiagnosis.report(facts(lastSessionAt: quiet))

        let check = check(report, "traffic")
        XCTAssertEqual(check?.state, .ok)
        XCTAssertTrue(check?.detail.contains("minutes ago") == true)
    }

    // MARK: - Which clients are captured at all

    /// A tool that ignores the system proxy is not captured and nothing is
    /// broken — so the note is informational, never a failure, and it is
    /// LAST: every causal check above it comes first. It is present whatever
    /// the state, because "why do I not see my traffic" is asked in every one
    /// of them.
    func testProxyAwareClientsNoteIsAlwaysLastAndNeverAFailure() {
        for (label, facts) in [
            ("healthy", facts()),
            ("stopped", facts(capture: false, vpn: "disconnected", sessions: 0)),
            ("broken", facts(capture: false, vpn: "disconnected", extensionStatus: "notInstalled", caInstalled: false, sessions: 0, inApplications: false, listening: nil)),
            ("unknowns", facts(caInstalled: nil, caTrusted: nil, inApplications: nil, listening: nil)),
        ] {
            let report = MCPSetupDiagnosis.report(facts)
            let last = report.checks.last
            XCTAssertEqual(last?.id, "proxy_aware_clients", "\(label): the note must be the last check")
            XCTAssertEqual(last?.state, .ok, "\(label): the note is informational")
            XCTAssertNil(last?.fix, "\(label): nothing is broken, so there is nothing to fix")
            XCTAssertEqual(report.checks.filter { $0.id == "proxy_aware_clients" }.count, 1, "\(label)")
        }
    }

    /// The answer has to name the client that made it necessary and the tool
    /// that fixes it, or an agent reading it still does not know what to do.
    func testProxyAwareClientsNoteNamesBothClassesAndTheTool() {
        let note = check(MCPSetupDiagnosis.report(facts()), "proxy_aware_clients")
        let detail = note?.detail ?? ""
        for needle in ["Safari", "curl", "node", "Claude Code", "Docker", "capture_environment"] {
            XCTAssertTrue(detail.contains(needle), "the note should mention \(needle): \(detail)")
        }
        // Same lists as capture_environment prints, from the same constants.
        XCTAssertTrue(detail.contains(MCPCaptureEnvironment.systemProxyClients))
        XCTAssertTrue(detail.contains(MCPCaptureEnvironment.environmentOnlyClients))
    }

    /// Being informational, it must not change any verdict or block anything.
    func testProxyAwareClientsNoteDoesNotChangeTheVerdict() {
        XCTAssertEqual(MCPSetupDiagnosis.report(facts()).verdict, "Capture is running and set up correctly.")
        XCTAssertEqual(MCPSetupDiagnosis.report(facts(capture: false, vpn: "disconnected", sessions: 0)).blockingCheckId, "tunnel")
    }

    /// The proxy-aware note stays last even when the attribution check is
    /// emitted in every state it can be.
    func testProxyAwareClientsNoteIsStillLastWithTheAttributionCheck() {
        for attribution in [true, false] {
            let report = MCPSetupDiagnosis.report(facts(attribution: attribution))
            XCTAssertEqual(report.checks.last?.id, "proxy_aware_clients")
            XCTAssertEqual(report.checks.dropLast().last?.id, "attribution", "attribution sits right before the note")
        }
    }

    /// …and still last with the destinations check in every state IT can be
    /// (destination-map UX spec §8.5): the order is attribution →
    /// destinations → the note.
    func testProxyAwareClientsNoteIsStillLastWithTheDestinationsCheck() {
        for (label, facts) in [
            ("ok", facts(sessions: 40, attribution: true, tableLoaded: true, placeable: 30, withoutAddress: 2)),
            ("no table", facts(sessions: 40, attribution: true, tableLoaded: false)),
            ("no addresses", facts(sessions: 40, attribution: false, tableLoaded: true, placeable: 0, withoutAddress: 40)),
            ("unknown", facts(sessions: 40, attribution: true, tableLoaded: nil)),
        ] {
            let report = MCPSetupDiagnosis.report(facts)
            let ids = report.checks.map(\.id)
            XCTAssertEqual(ids.last, "proxy_aware_clients", label)
            XCTAssertEqual(ids.dropLast().last, "destinations", "\(label): destinations sits right before the note")
            XCTAssertEqual(ids.dropLast(2).last, "attribution", "\(label): attribution sits right before destinations")
        }
    }

    // MARK: - Process attribution (UX spec §9.1)

    /// The healthy state: the extension read the socket table against its own
    /// socket and it matched. Reported, never a fix.
    func testAttributionAvailableIsOk() {
        let report = MCPSetupDiagnosis.report(facts(attribution: true))
        let check = check(report, "attribution")

        XCTAssertEqual(check?.title, "Process attribution")
        XCTAssertEqual(check?.state, .ok)
        XCTAssertEqual(check?.detail, "ReqRes can tell which app opened each connection.")
        XCTAssertNil(check?.fix)
        XCTAssertEqual(report.verdict, "Capture is running and set up correctly.", "an ok check leaves the verdict alone")
    }

    /// The degraded state (the App column is hidden, every session reads
    /// Unknown): a warning that names the consequence for an agent — its
    /// `app`/`pid` filters match nothing — and says capture is unaffected.
    /// Never a problem: nothing is broken.
    func testAttributionUnavailableIsAWarningNotAProblem() {
        let report = MCPSetupDiagnosis.report(facts(attribution: false))
        let check = check(report, "attribution")

        XCTAssertEqual(check?.state, .warning)
        XCTAssertEqual(
            check?.detail,
            "ReqRes could not read the socket table on this Mac, so it cannot tell which app opened a connection. The App column is hidden and every request reads Unknown to an agent; capture itself is unaffected."
        )
        XCTAssertNil(check?.fix, "nothing a human can do about it — it is reported, not prescribed")
        XCTAssertNil(report.blockingCheckId)
        XCTAssertTrue(report.capturing, "capture is on regardless")
    }

    /// Unreported — at launch and while the tunnel is stopped — is omitted,
    /// not shown as unknown: the extension calibrates once per tunnel start,
    /// and "not yet" is the first second of every capture, not a finding.
    func testAttributionUnreportedIsOmitted() {
        XCTAssertNil(check(MCPSetupDiagnosis.report(facts(attribution: nil)), "attribution"))
        XCTAssertNil(check(MCPSetupDiagnosis.report(facts()), "attribution"))
    }

    /// Only while capture is on: with the tunnel stopped there is no socket
    /// table being read, whatever the last report said.
    func testAttributionIsNotReportedWhileCaptureIsOff() {
        for attribution in [true, false] {
            let report = MCPSetupDiagnosis.report(facts(capture: false, vpn: "disconnected", sessions: 0, attribution: attribution))
            XCTAssertNil(check(report, "attribution"), "attribution=\(attribution)")
        }
    }

    /// It sits after the causal checks (everything that can break capture)
    /// and before the informational note, and is never `.problem` or
    /// `.unknown` in any state.
    func testAttributionIsPlacedAfterTrafficAndIsNeverAProblem() {
        for attribution in [true, false] {
            let report = MCPSetupDiagnosis.report(facts(attribution: attribution))
            let ids = report.checks.map(\.id)
            let trafficIndex = ids.firstIndex(of: "traffic")!
            let attributionIndex = ids.firstIndex(of: "attribution")!
            let noteIndex = ids.firstIndex(of: "proxy_aware_clients")!
            XCTAssertLessThan(trafficIndex, attributionIndex)
            XCTAssertLessThan(attributionIndex, noteIndex)
            let state = check(report, "attribution")?.state
            XCTAssertTrue(state == .ok || state == .warning, "\(String(describing: state))")
        }
    }

    /// The facts travel as JSON between the app and the helper; an older
    /// app that does not send the field decodes as unreported.
    func testProcessAttributionIsOptionalOnTheWire() throws {
        var facts = facts(attribution: false)
        let data = try JSONEncoder().encode(facts)
        XCTAssertEqual(try JSONDecoder().decode(MCPSetupFacts.self, from: data).processAttribution, false)

        facts.processAttribution = nil
        let stripped = try JSONEncoder().encode(facts)
        XCTAssertNil(try JSONDecoder().decode(MCPSetupFacts.self, from: stripped).processAttribution)
    }

    // MARK: - Unknowns

    /// A check that could not run is never reported as one that passed.
    func testUnknownsAreNeverReportedAsOk() {
        let report = MCPSetupDiagnosis.report(facts(caInstalled: nil, caTrusted: nil, inApplications: nil, listening: nil))

        XCTAssertEqual(check(report, "location")?.state, .unknown)
        XCTAssertEqual(check(report, "proxy")?.state, .unknown)
        XCTAssertEqual(check(report, "certificate_installed")?.state, .unknown)
        XCTAssertNil(report.blockingCheckId)
        XCTAssertTrue(report.verdict.contains("could not be made"))
    }

    /// The default seam implementation knows only what capture_status knows,
    /// so everything else has to come back unknown rather than assumed.
    func testTheDefaultSeamReportsWhatItCannotSeeAsUnknown() {
        let facts = StubStatusProvider().setupFacts()

        XCTAssertNil(facts.runningFromApplications)
        XCTAssertNil(facts.proxyPortListening)
        XCTAssertNil(facts.freeInspectionsUsed)
        XCTAssertEqual(facts.proxyPort, MCPLimits.proxyPort)
    }

    // MARK: - Rendering

    func testTheRenderedTextLeadsWithTheVerdictAndCarriesTheFixes() {
        let text = MCPTextFormat.diagnosis(MCPSetupDiagnosis.report(facts(extensionStatus: "extensionDisabled")))
        let lines = text.components(separatedBy: "\n")

        XCTAssertTrue(lines[0].contains("switched off"), "an agent that reads only the first line must still be right")
        XCTAssertTrue(text.contains("FAIL Network extension"))
        XCTAssertTrue(text.contains("→ Ask the user"))
    }

    // MARK: - Destinations (destination-map UX spec §8.5)

    func testDestinationsResolvingIsOkAndNamesTheCounts() {
        let check = check(MCPSetupDiagnosis.report(facts(sessions: 40, tableLoaded: true, placeable: 30, withoutAddress: 2)), "destinations")
        XCTAssertEqual(check?.title, "Destinations")
        XCTAssertEqual(check?.state, .ok)
        XCTAssertEqual(check?.detail, "Destinations resolve on this Mac: 30 of 40 requests placed in a country; the rest are local or unknown.")
        XCTAssertNil(check?.fix)
    }

    func testAMissingTableIsAWarningThatSaysReinstall() {
        let check = check(MCPSetupDiagnosis.report(facts(sessions: 40, tableLoaded: false)), "destinations")
        XCTAssertEqual(check?.state, .warning)
        XCTAssertEqual(check?.detail, "The bundled country table could not be loaded, so every destination reads Unknown. Capture is unaffected.")
        XCTAssertEqual(check?.fix, "Reinstall ReqRes.")
    }

    /// Every request without an address is the old extension still running
    /// — the one Unknown-everywhere cause a restart fixes.
    func testNoAddressesAtAllIsAWarningThatBlamesTheOldExtension() {
        let check = check(MCPSetupDiagnosis.report(facts(sessions: 40, tableLoaded: true, placeable: 0, withoutAddress: 40)), "destinations")
        XCTAssertEqual(check?.state, .warning)
        XCTAssertEqual(check?.detail, "Captured requests carry no server address, so nothing can be placed on the map — the running extension predates this feature.")
        XCTAssertEqual(check?.fix, "Stop and start capture; if that does not change it, restart the Mac so macOS swaps in the new extension.")
    }

    /// Some addresses missing is the mixed state a mid-capture swap leaves;
    /// it is not the old extension and not a warning.
    func testSomeAddressesMissingIsStillOk() {
        let check = check(MCPSetupDiagnosis.report(facts(sessions: 40, tableLoaded: true, placeable: 5, withoutAddress: 39)), "destinations")
        XCTAssertEqual(check?.state, .ok)
        XCTAssertEqual(check?.detail, "Destinations resolve on this Mac: 5 of 40 requests placed in a country; the rest are local or unknown.")
    }

    /// A check that could not run is never reported as one that passed.
    func testDestinationsIsUnknownWhenTheFactsAreMissing() {
        XCTAssertEqual(check(MCPSetupDiagnosis.report(facts(sessions: 40)), "destinations")?.state, .unknown)
        XCTAssertEqual(check(MCPSetupDiagnosis.report(facts(sessions: 40, tableLoaded: true)), "destinations")?.state, .unknown)
        XCTAssertEqual(check(MCPSetupDiagnosis.report(facts(sessions: 40, tableLoaded: true, placeable: 3)), "destinations")?.state, .unknown)
    }

    /// Only while capture is on and there is enough traffic to say something
    /// about: a handful of requests that all happen to be local is not a
    /// finding.
    func testDestinationsIsOmittedWhileCaptureIsOffOrWithTooFewSessions() {
        XCTAssertNil(check(MCPSetupDiagnosis.report(facts(capture: false, vpn: "disconnected", sessions: 40, tableLoaded: false)), "destinations"))
        XCTAssertNil(check(MCPSetupDiagnosis.report(facts(sessions: 19, tableLoaded: false)), "destinations"))
        XCTAssertNotNil(check(MCPSetupDiagnosis.report(facts(sessions: 20, tableLoaded: false)), "destinations"))
        XCTAssertEqual(MCPSetupDiagnosis.destinationsMinimumSessions, 20)
    }

    /// Never a problem and never blocking: capture is unaffected either way.
    func testDestinationsIsNeverAProblemAndNeverBlocks() {
        for (label, facts) in [
            ("no table", facts(sessions: 40, tableLoaded: false)),
            ("no addresses", facts(sessions: 40, tableLoaded: true, placeable: 0, withoutAddress: 40)),
            ("unknown", facts(sessions: 40)),
        ] {
            let report = MCPSetupDiagnosis.report(facts)
            XCTAssertNotEqual(check(report, "destinations")?.state, .problem, label)
            XCTAssertNil(report.blockingCheckId, label)
        }
    }

    /// The facts travel as JSON between the app and the helper; an older app
    /// that does not send the fields decodes as unreported.
    func testDestinationFactsAreOptionalOnTheWire() throws {
        var facts = facts(sessions: 40, tableLoaded: true, placeable: 30, withoutAddress: 2)
        let decoded = try JSONDecoder().decode(MCPSetupFacts.self, from: try JSONEncoder().encode(facts))
        XCTAssertEqual(decoded.destinationTableLoaded, true)
        XCTAssertEqual(decoded.destinationsPlaceable, 30)
        XCTAssertEqual(decoded.destinationsWithoutAddress, 2)

        facts.destinationTableLoaded = nil
        facts.destinationsPlaceable = nil
        facts.destinationsWithoutAddress = nil
        let stripped = try JSONDecoder().decode(MCPSetupFacts.self, from: try JSONEncoder().encode(facts))
        XCTAssertNil(stripped.destinationTableLoaded)
        XCTAssertNil(stripped.destinationsPlaceable)
        XCTAssertNil(stripped.destinationsWithoutAddress)
    }
}
