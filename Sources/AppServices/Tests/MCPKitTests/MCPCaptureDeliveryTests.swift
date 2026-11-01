//
//  MCPCaptureDeliveryTests.swift
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
//  F11 (2026-09-30): after ReqRes was relaunched while capturing,
//  capture_status said "running" and every list came back empty — an agent
//  could not tell that from "nothing has happened yet". capture_status and
//  diagnose_setup now carry whether what capture records reaches the app.
//

import XCTest
@testable import MCPKit

final class MCPCaptureDeliveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// The app's sentence for a capture that outlived it and did not
    /// reconnect (Utils `CaptureDeliveryCopy.reason`, build 53).
    private let relaunched = "Capture kept running while ReqRes was closed, and its extension has not reconnected to ReqRes."

    private func status(capture: Bool = true, vpn: String = "connected", sessions: Int = 0,
                        delivery: MCPCaptureDelivery?) -> MCPBridgeStatus {
        MCPBridgeStatus(captureActive: capture, vpnStatus: vpn, extensionStatus: "ready",
                        caCertificateInstalled: true, caCertificateTrusted: true,
                        sessionCount: sessions, appVersion: "1.1.0", delivery: delivery)
    }

    private func report(_ status: MCPBridgeStatus, listening: Bool? = true) -> MCPSetupReport {
        MCPSetupDiagnosis.report(MCPSetupFacts(
            status: status, runningFromApplications: true, proxyPort: 8034, proxyPortListening: listening,
            freeInspectionsUsed: 0, freeInspectionsLimit: 10, licensed: false, lastSessionAt: now, now: now))
    }

    private var notReceiving: MCPCaptureDelivery {
        MCPCaptureDelivery(state: .notReceiving, reason: relaunched, restartable: true)
    }

    // MARK: - The check

    func testEveryStateHasItsCheck() {
        let table: [(MCPCaptureDelivery.State, MCPSetupCheck.State)] = [
            (.receiving, .ok),
            (.waiting, .warning),
            (.reconnecting, .warning),
            (.notReceiving, .problem),
            (.otherCopy, .problem),
            (.notCapturing, .unknown),
        ]
        XCTAssertEqual(table.count, MCPCaptureDelivery.State.allCases.count)
        for (state, expected) in table {
            let check = MCPCaptureDelivery(state: state, restartable: state == .notReceiving).check()
            XCTAssertEqual(check.id, "delivery")
            XCTAssertEqual(check.state, expected, "\(state)")
        }
    }

    /// Not receiving blocks, names the reason the app gave, and asks the
    /// user for Restart Capture — or the agent restarts it itself, with
    /// consent.
    func testNotReceivingBlocksWithTheReasonAndTheRestart() {
        let report = report(status(delivery: notReceiving))
        XCTAssertEqual(report.blockingCheckId, "delivery")
        XCTAssertFalse(report.capturing, "capture is on, but nothing is being captured for anyone")
        let check = report.checks.first { $0.id == "delivery" }
        XCTAssertTrue(check?.detail.contains("isn't receiving") == true, check?.detail ?? "")
        XCTAssertTrue(check?.detail.contains(relaunched) == true)
        XCTAssertTrue(check?.fix?.contains("Restart Capture") == true)
        XCTAssertTrue(check?.fix?.contains("stop_capture") == true)
        XCTAssertTrue(report.verdict.contains("isn't receiving"), "the first line is the one an agent acts on: \(report.verdict)")
    }

    /// Another copy receiving it: blocks this copy, and never offers a
    /// restart that would take the capture from the window receiving it.
    func testAnotherCopyBlocksWithoutARestart() {
        let report = report(status(delivery: MCPCaptureDelivery(state: .otherCopy, restartable: false)))
        let check = report.checks.first { $0.id == "delivery" }
        XCTAssertEqual(report.blockingCheckId, "delivery")
        XCTAssertTrue(check?.detail.contains("Another copy of ReqRes") == true)
        XCTAssertFalse(check?.fix?.contains("Restart Capture") == true)
        XCTAssertFalse(check?.fix?.contains("stop_capture") == true)
    }

    /// A not-receiving verdict the app says a restart cannot fix gets no
    /// restart fix.
    func testNoRestartFixUnlessRestartable() {
        XCTAssertNil(MCPCaptureDelivery(state: .notReceiving, reason: relaunched, restartable: false).check().fix)
    }

    func testReceivingKeepsAWorkingSetupWorking() {
        let report = report(status(sessions: 5, delivery: MCPCaptureDelivery(state: .receiving)))
        XCTAssertNil(report.blockingCheckId)
        XCTAssertTrue(report.capturing)
        XCTAssertEqual(report.verdict, "Capture is running and set up correctly.")
    }

    /// Unknown while capture is off — and the stopped tunnel stays the cause.
    func testUnknownWhileNotCapturing() {
        let report = report(status(capture: false, vpn: "disconnected", delivery: MCPCaptureDelivery(state: .notCapturing)), listening: nil)
        XCTAssertEqual(report.checks.first { $0.id == "delivery" }?.state, .unknown)
        XCTAssertEqual(report.blockingCheckId, "tunnel")
    }

    /// An app that predates the fact says nothing about it, rather than
    /// "could not tell" on every report.
    func testOmittedWhenTheAppDidNotSay() {
        XCTAssertNil(report(status(delivery: nil)).checks.first { $0.id == "delivery" })
    }

    // MARK: - The order

    /// Causal: the proxy decrypts, then the extension has to deliver to the
    /// app — so delivery sits right after the proxy check, before anything
    /// about certificates, and a dead proxy port is still blamed first.
    func testDeliveryComesRightAfterTheProxy() {
        let ids = report(status(delivery: notReceiving)).checks.map(\.id)
        XCTAssertEqual(Array(ids.prefix(6)), ["location", "extension", "tunnel", "proxy", "delivery", "certificate_installed"])
        XCTAssertEqual(ids.last, "proxy_aware_clients")

        let deadPort = report(status(delivery: notReceiving), listening: false)
        XCTAssertEqual(deadPort.blockingCheckId, "proxy", "the cause, not the symptom")
    }

    /// While capture is off there is no proxy check; delivery follows the
    /// tunnel directly.
    func testDeliveryFollowsTheTunnelWhenThereIsNoProxyCheck() {
        let ids = report(status(capture: false, vpn: "disconnected", delivery: MCPCaptureDelivery(state: .notCapturing)), listening: nil).checks.map(\.id)
        XCTAssertEqual(Array(ids.prefix(4)), ["location", "extension", "tunnel", "delivery"])
    }

    // MARK: - capture_status

    func testTheStatusSaysWhetherCaptureReachesReqRes() {
        let broken = MCPTextFormat.status(status(delivery: notReceiving))
        XCTAssertTrue(broken.contains("Capture: running (tunnel: connected)"))
        XCTAssertTrue(broken.contains("Delivery: NOT reaching ReqRes"), broken)
        XCTAssertTrue(broken.contains(relaunched))
        XCTAssertTrue(broken.contains("Restart Capture"))

        let lines = broken.components(separatedBy: "\n")
        let count = lines.firstIndex { $0.hasPrefix("Sessions captured this run:") }
        let delivery = lines.firstIndex { $0.hasPrefix("Delivery:") }
        XCTAssertEqual(delivery, count.map { $0 + 1 }, "right under the count it explains")

        XCTAssertTrue(MCPTextFormat.status(status(delivery: MCPCaptureDelivery(state: .receiving))).contains("Delivery: requests reach ReqRes"))
        XCTAssertTrue(MCPTextFormat.status(status(delivery: MCPCaptureDelivery(state: .otherCopy))).contains("another copy of ReqRes"))
        XCTAssertFalse(MCPTextFormat.status(status(delivery: MCPCaptureDelivery(state: .otherCopy))).contains("Restart Capture"))
    }

    /// Off, or from an app that predates the fact: no line — the status is
    /// polled, and every line costs the agent.
    func testNoDeliveryLineWhileOffOrUnknown() {
        XCTAssertFalse(MCPTextFormat.status(status(capture: false, vpn: "disconnected", delivery: MCPCaptureDelivery(state: .notCapturing))).contains("Delivery:"))
        XCTAssertFalse(MCPTextFormat.status(status(delivery: nil)).contains("Delivery:"))
    }

    // MARK: - Reconnecting and reattached (build 53)

    /// A capture that outlived the app is reconnecting: a moment's warning,
    /// never the blocking check, and the line says what arrives when it has.
    func testReconnectingIsAWarningThatSaysWhatArrives() {
        let delivery = MCPCaptureDelivery(state: .reconnecting)
        let check = delivery.check()
        XCTAssertEqual(check.state, .warning)
        XCTAssertNil(check.fix, "nothing to do but wait")
        XCTAssertTrue(check.detail.contains("reconnecting to ReqRes"), check.detail)
        XCTAssertTrue(check.detail.contains("arrives"), check.detail)
        let report = report(status(delivery: delivery))
        XCTAssertNil(report.blockingCheckId)
        XCTAssertTrue(report.capturing)
        let line = MCPTextFormat.status(status(delivery: delivery))
        XCTAssertTrue(line.contains("Delivery: reconnecting to the running capture"), line)
        XCTAssertTrue(line.contains("list_sessions"), "what it means for the agent: \(line)")
    }

    /// After a reattach the agent hears what the extension delivered and what
    /// it could not keep — rows it will not find in list_sessions.
    func testAReattachIsSaidWithItsCounts() {
        let delivered = MCPCaptureDelivery(state: .receiving, capturedWhileDetached: 40, droppedRows: 12)
        XCTAssertEqual(delivered.check().state, .ok)
        XCTAssertTrue(delivered.check().detail.contains("delivered 40 requests captured while ReqRes wasn't receiving it; 12 earlier ones were not kept."),
                      delivered.check().detail)
        let line = delivered.statusLine ?? ""
        // Mid-line after the dash, naming what reconnected (review: "— It
        // reconnected…", capitalised, with nothing for "It" to refer to).
        XCTAssertEqual(line, "Delivery: requests reach ReqRes — the extension reconnected and delivered 40 requests captured while ReqRes wasn't receiving it; 12 earlier ones were not kept.")

        XCTAssertEqual(MCPCaptureDelivery(state: .receiving, capturedWhileDetached: 1, droppedRows: 0).reattachSentence,
                       "The extension reconnected and delivered 1 request captured while ReqRes wasn't receiving it.")
        XCTAssertEqual(MCPCaptureDelivery(state: .receiving, capturedWhileDetached: 0, droppedRows: 1).reattachSentence,
                       "The extension reconnected after capturing while ReqRes wasn't receiving it; 1 request captured then was not kept.")
        // Grouped like the app's other counts.
        XCTAssertEqual(MCPCaptureDelivery(state: .receiving, capturedWhileDetached: 512, droppedRows: 25000).reattachSentence,
                       "The extension reconnected and delivered 512 requests captured while ReqRes wasn't receiving it; 25,000 earlier ones were not kept.")
        XCTAssertEqual(MCPCaptureDelivery(state: .receiving, capturedWhileDetached: 0, droppedRows: 2048).reattachSentence,
                       "The extension reconnected after capturing while ReqRes wasn't receiving it; 2,048 requests captured then were not kept.")
        XCTAssertNil(MCPCaptureDelivery(state: .receiving, capturedWhileDetached: 0, droppedRows: 0).reattachSentence)
        XCTAssertNil(MCPCaptureDelivery(state: .receiving).reattachSentence)
        XCTAssertEqual(MCPCaptureDelivery(state: .receiving).statusLine, "Delivery: requests reach ReqRes", "a plain start says what it said")
    }

    /// The person reads the reconnect too (Diagnose Setup…, the tooltip):
    /// none of the agent's words.
    func testTheReconnectSpeaksToNeitherParty() {
        let report = report(status(delivery: MCPCaptureDelivery(state: .reconnecting)))
        let check = try? XCTUnwrap(report.checks.first { $0.id == "delivery" })
        for word in agentWords {
            XCTAssertFalse(check?.detail.contains(word) == true, "“\(word)” in: \(check?.detail ?? "")")
        }
    }

    // MARK: - The wire

    func testTheFactRoundTripsAndOlderStatusesStillDecode() throws {
        let original = status(delivery: notReceiving)
        let decoded = try JSONDecoder().decode(MCPBridgeStatus.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.delivery?.state, .notReceiving)

        let reattached = status(delivery: MCPCaptureDelivery(state: .receiving, capturedWhileDetached: 4, droppedRows: 2))
        XCTAssertEqual(try JSONDecoder().decode(MCPBridgeStatus.self, from: JSONEncoder().encode(reattached)), reattached)
        let reconnecting = status(delivery: MCPCaptureDelivery(state: .reconnecting))
        let wire = String(decoding: try JSONEncoder().encode(reconnecting), as: UTF8.self)
        XCTAssertTrue(wire.contains("\"reconnecting\""), wire)
        // A delivery fact from build 52 has neither count.
        let earlier = try JSONDecoder().decode(MCPCaptureDelivery.self, from: Data(#"{"state":"receiving","restartable":false}"#.utf8))
        XCTAssertNil(earlier.capturedWhileDetached)
        XCTAssertNil(earlier.droppedRows)

        let json = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        XCTAssertTrue(json.contains("\"not_receiving\""), "the wire spelling: \(json)")

        let older = #"{"captureActive":true,"vpnStatus":"connected","extensionStatus":"ready","sessionCount":0,"appVersion":"","bridgeVersion":2}"#
        XCTAssertNil(try JSONDecoder().decode(MCPBridgeStatus.self, from: Data(older.utf8)).delivery)
    }

    /// A state a later app adds must not cost the whole status.
    func testAStateFromALaterAppReadsAsNotCapturing() throws {
        let later = #"{"state":"rerouted","restartable":false}"#
        let decoded = try JSONDecoder().decode(MCPCaptureDelivery.self, from: Data(later.utf8))
        XCTAssertEqual(decoded.state, .notCapturing)
        XCTAssertEqual(decoded.check().state, .unknown, "could not tell — never a false ok")
    }

    // MARK: - What a person reads (F11 review)

    /// Words that belong to the agent: its tools, and "the user" it relays to.
    private let agentWords = ["stop_capture", "start_capture", "list_sessions", "call ", "Call ", "the user", "Ask ", "you are connected"]

    /// Capture ▸ Diagnose Setup… and the menu bar item's tooltip used to show
    /// the agent's script — "…or call stop_capture and then start_capture",
    /// "Ask the user which copy…", "…reaches the traffic list or you."
    func testThePersonNeverReadsTheAgentsScript() throws {
        for delivery in [notReceiving, MCPCaptureDelivery(state: .otherCopy, restartable: false)] {
            let report = report(status(delivery: delivery))
            let check = try XCTUnwrap(report.checks.first { $0.id == "delivery" })
            let human = try XCTUnwrap(MCPSetupDiagnosis.humanFixText(for: check))
            let tooltip = MCPSetupDiagnosis.humanVerdict(report)
            for text in [human, tooltip, check.detail] {
                for word in agentWords {
                    XCTAssertFalse(text.contains(word), "\(delivery.state): “\(word)” in: \(text)")
                }
                XCTAssertFalse(text.contains(" you.") || text.contains(" you ") || text.contains(" you,"), "\(delivery.state): speaks to the agent: \(text)")
            }
            XCTAssertTrue(tooltip.hasPrefix(check.detail), "the tooltip is the verdict's sentence: \(tooltip)")
        }
        XCTAssertTrue(MCPCaptureDelivery.humanRestartFix.contains("Restart Capture"))
        XCTAssertTrue(MCPCaptureDelivery.humanOtherCopyFix.contains("quitting it stops its capture"))
    }

    /// The agent keeps its own script: its tools, and the consequence for it.
    func testTheAgentStillGetsItsScript() throws {
        let check = notReceiving.check()
        let fix = try XCTUnwrap(check.fix)
        XCTAssertTrue(fix.contains("stop_capture") && fix.contains("start_capture"), fix)
        XCTAssertTrue(fix.contains("list_sessions"), "the consequence for the agent is in its fix: \(fix)")
        XCTAssertNotEqual(MCPSetupDiagnosis.humanFixText(for: check), fix)
        XCTAssertNil(MCPSetupDiagnosis.humanFix(for: MCPCaptureDelivery(state: .notReceiving, reason: relaunched, restartable: false).check()),
                     "nothing to do, nothing to say")
    }

    /// start_capture and stop_capture are routine: the user's standing grant
    /// can answer them with no panel. The fix and SKILL.md used to promise
    /// "(the user approves each)".
    func testTheRestartFixPromisesNoApprovalTheGrantCanSkip() throws {
        let coverable = [MCPAgentAction.Kind.startCapture, .stopCapture]
            .map { MCPAgentAction(kind: $0, summary: "").canBeCoveredByStandingGrant }
        XCTAssertEqual(coverable, [true, true], "if this changes, the wording below may be allowed to promise a panel again")
        XCTAssertFalse(MCPCaptureDelivery.restartFix.contains("approves each"), MCPCaptureDelivery.restartFix)
        XCTAssertTrue(MCPCaptureDelivery.restartFix.contains("unless they allowed agent changes without asking"), MCPCaptureDelivery.restartFix)

        let skill = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/reqres-mcp/SKILL.md"), encoding: .utf8)
        XCTAssertFalse(skill.contains("(the user approves each)"))
        XCTAssertTrue(skill.contains("unless they allowed agent\nchanges without asking") || skill.contains("unless they allowed agent changes without asking"))
        XCTAssertFalse(skill.contains("every list stays empty"), "rows from before stay listed")
    }

    /// Build 53 (core 95062d1): a capture that outlived the app reattaches —
    /// the extension redials and delivers the newest of what it kept — and
    /// ReqRes restarts one that cannot, once. The tool texts, SKILL.md and
    /// Help said only that capture "can be on while nothing arrives" after a
    /// relaunch, which build 52 made true and this build does not.
    func testTheReattachIsDescribedWhereAnAgentAndAPersonMeetIt() throws {
        let appServices = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skill = try String(contentsOf: appServices.appendingPathComponent("Sources/reqres-mcp/SKILL.md"), encoding: .utf8)
        let server = try String(contentsOf: appServices.appendingPathComponent("Sources/reqres-mcp/ReqResMCPServer.swift"), encoding: .utf8)
        let help = try String(contentsOf: appServices.appendingPathComponent("../UI/Views/Help/HelpContent.swift"), encoding: .utf8)
        let flatSkill = skill.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        XCTAssertFalse(flatSkill.contains("capture can be running while nothing arrives — after ReqRes was relaunched while capturing, for one"))
        XCTAssertTrue(flatSkill.contains("After ReqRes was relaunched while capturing it reads `reconnecting` for a few seconds: the extension reconnects by itself and delivers the most recent of what it captured meanwhile"))
        XCTAssertTrue(flatSkill.contains("ReqRes restarts it once by itself — not a capture ReqRes itself just started that never connected, and not after the user or you asked for a start or a stop."))

        XCTAssertFalse(server.contains("capture can be on while nothing arrives, e.g. after ReqRes was relaunched while capturing"))
        XCTAssertTrue(server.contains("(Delivery — reconnecting for a few seconds after ReqRes was relaunched while capturing, while the extension reconnects and delivers what it captured meanwhile; capture can also be on while nothing arrives, until it is started again from ReqRes)"))
        XCTAssertFalse(server.contains("delivery to ReqRes (capture on but nothing reaching the app, and why)"))
        XCTAssertTrue(server.contains("delivery to ReqRes (reconnecting after a relaunch, or capture on with nothing reaching the app, and why)"))

        XCTAssertTrue(help.contains("If ReqRes quits unexpectedly while capturing, capture keeps running. Open ReqRes again: it reconnects, usually within a few seconds,"))
        XCTAssertTrue(help.contains(#"if “\(CaptureDeliveryCopy.notReceivingTitle)” stays, click \(CaptureDeliveryCopy.restartButton) there."#),
                      "the notice and its button are quoted from the pane's own copy")
        XCTAssertTrue(help.contains("Quitting ReqRes normally still asks first, and stops capture."))
    }

    /// Right under a session count that can be anything: rows from before
    /// stay listed, so the line speaks of NEW sessions (F11 review — it read
    /// "list_sessions stays empty" under "Sessions captured this run: 240").
    func testTheStatusLineSpeaksOfNewSessions() {
        let broken = MCPTextFormat.status(status(sessions: 240, delivery: notReceiving))
        XCTAssertTrue(broken.contains("Sessions captured this run: 240"))
        XCTAssertFalse(broken.contains("stays empty"), broken)
        XCTAssertTrue(broken.contains("no new session reaches list_sessions"), broken)
        let other = MCPTextFormat.status(status(sessions: 240, delivery: MCPCaptureDelivery(state: .otherCopy)))
        XCTAssertFalse(other.contains("lists nothing"), other)
        XCTAssertTrue(other.contains("no new session reaches this copy"), other)
    }

    /// Another copy holding the connection is what is known; that it
    /// receives the capture is not, and nothing says so.
    func testAnotherCopyIsNotSaidToReceiveTheCapture() {
        let check = MCPCaptureDelivery(state: .otherCopy).check()
        let line = MCPCaptureDelivery(state: .otherCopy).statusLine ?? ""
        for text in [check.detail, check.fix ?? "", line, MCPCaptureDelivery.humanOtherCopyFix] {
            XCTAssertFalse(text.contains("is receiving this capture"), text)
            XCTAssertFalse(text.contains("lists nothing"), text)
        }
        XCTAssertTrue(check.detail.contains("holds this capture's connection"), check.detail)
    }

    /// "Waiting" is the first moments of a start the app sent, and the
    /// seconds before ReqRes restarts a capture whose extension cannot
    /// reconnect by itself (started outside ReqRes, long before) — "Capture
    /// has just started" was false then. A relaunch's are "reconnecting".
    func testWaitingDoesNotClaimCaptureJustStarted() {
        let check = MCPCaptureDelivery(state: .waiting).check()
        XCTAssertFalse(check.detail.contains("just started"), check.detail)
        XCTAssertTrue(check.detail.contains("has not connected to ReqRes yet"), check.detail)
    }

    /// Diagnose Setup… offers Restart Capture when, and only when, the first
    /// problem is one it fixes.
    func testDiagnoseOffersRestartOnlyWhenItIsTheFix() {
        XCTAssertTrue(MCPCaptureDelivery.offersRestart(in: report(status(delivery: notReceiving))))
        XCTAssertFalse(MCPCaptureDelivery.offersRestart(in: report(status(delivery: MCPCaptureDelivery(state: .notReceiving, reason: relaunched, restartable: false)))))
        XCTAssertFalse(MCPCaptureDelivery.offersRestart(in: report(status(delivery: MCPCaptureDelivery(state: .otherCopy)))),
                       "never to take the capture from the copy holding it")
        XCTAssertFalse(MCPCaptureDelivery.offersRestart(in: report(status(delivery: notReceiving), listening: false)),
                       "a dead proxy port is the problem to fix first")
        XCTAssertFalse(MCPCaptureDelivery.offersRestart(in: report(status(delivery: MCPCaptureDelivery(state: .receiving)))))
    }

    /// The re-voicing every other check gets, now shared by the alert and the
    /// tooltip: the opening "Ask the user to" goes, "Call start_capture."
    /// becomes the keys a person presses, anything else is left alone.
    func testTheAgentWordingIsReVoicedForAPerson() {
        XCTAssertEqual(MCPSetupDiagnosis.humanVoiced("Ask the user to quit and reopen ReqRes."), "Quit and reopen ReqRes.")
        XCTAssertEqual(MCPSetupDiagnosis.humanVoiced("Tell the user to wait."), "Wait.")
        XCTAssertEqual(MCPSetupDiagnosis.humanVoiced("Call start_capture."), "Start capturing — ⌘⇧C, or Capture ▸ Start Capturing.")
        XCTAssertEqual(MCPSetupDiagnosis.humanVoiced("Nothing is broken, but capture is stopped. Call start_capture."),
                       "Nothing is broken, but capture is stopped. Start capturing — ⌘⇧C, or Capture ▸ Start Capturing.")
        XCTAssertEqual(MCPSetupDiagnosis.humanVoiced("Reinstall ReqRes."), "Reinstall ReqRes.")

        // The tooltip for a stopped capture, which used to end "Call start_capture.".
        let stopped = report(status(capture: false, vpn: "disconnected", delivery: MCPCaptureDelivery(state: .notCapturing)), listening: nil)
        XCTAssertEqual(stopped.blockingCheckId, "tunnel")
        XCTAssertFalse(MCPSetupDiagnosis.humanVerdict(stopped).contains("start_capture"), MCPSetupDiagnosis.humanVerdict(stopped))
    }
}
