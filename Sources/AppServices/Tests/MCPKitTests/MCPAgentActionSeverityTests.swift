//
//  MCPAgentActionSeverityTests.swift
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

final class MCPAgentActionSeverityTests: XCTestCase {
    /// Every kind has to land somewhere deliberate. A new tool added without a
    /// severity would otherwise inherit whatever the switch's last case was.
    func testEveryKindIsClassified() {
        for kind in MCPAgentAction.Kind.allCases {
            switch kind.severity {
            case .routine, .exportsData, .rewritesTraffic, .destructive, .actsOnThirdParty:
                continue
            }
        }
        XCTAssertEqual(MCPAgentAction.Kind.allCases.count, 15)
    }

    /// Answering a held request decides what the user's own app receives, so
    /// it ranks with a rule. It is deliberately NOT `actsOnThirdParty`: the
    /// request was already on its way to that server because the user's app
    /// sent it, and resuming it untouched is what happens anyway if nobody
    /// answers — the opposite of a replay, which creates a request that would
    /// not otherwise exist.
    func testAnsweringAHeldRequestRanksWithARule() {
        XCTAssertEqual(MCPAgentAction.Kind.answerPausedRequest.severity, .rewritesTraffic)
        XCTAssertLessThan(MCPAgentAction.Kind.answerPausedRequest.severity,
                          MCPAgentAction.Kind.replayRequest.severity)
    }

    /// The one write not approved per call, and its description has to say so
    /// — an agent reading "the user approves this in the ReqRes window" would
    /// tell the user to expect a panel that never appears.
    func testTheBreakpointNoteSaysItIsGrantedInAdvance() {
        let note = MCPAgentAction.Kind.answerPausedRequest.consentNote
        XCTAssertTrue(note.contains("NOT approved per call"), "got: \(note)")
        XCTAssertTrue(note.contains("Settings → Breakpoints"), "got: \(note)")
        XCTAssertFalse(note.contains("The user approves this in the ReqRes window"),
                       "it must not inherit the per-call wording")
    }

    func testRulesAreTreatedAsTrafficRewrites() {
        XCTAssertEqual(MCPAgentAction.Kind.createRule.severity, .rewritesTraffic)
        XCTAssertEqual(MCPAgentAction.Kind.updateRule.severity, .rewritesTraffic)
        XCTAssertEqual(MCPAgentAction.Kind.mockFromSession.severity, .rewritesTraffic)
    }

    /// Removing a host takes its rules with it, and cleared sessions cannot be
    /// recaptured, so both rank with an outright delete.
    func testThingsThatThrowStateAwayAreDestructive() {
        XCTAssertEqual(MCPAgentAction.Kind.deleteRule.severity, .destructive)
        XCTAssertEqual(MCPAgentAction.Kind.removeHost.severity, .destructive)
        XCTAssertEqual(MCPAgentAction.Kind.clearSessions.severity, .destructive)
    }

    /// Keeping a session is not "routine": the exchange stops being something
    /// that vanishes at quit and becomes a row on disk, in the clear. It is not
    /// a traffic rewrite either — nothing on the wire changes — which is why it
    /// shares `export_sessions`'s severity rather than getting its own.
    func testKeepingTrafficRanksWithExportingIt() {
        XCTAssertEqual(MCPAgentAction.Kind.saveSession.severity, .exportsData)
        XCTAssertEqual(MCPAgentAction.Kind.saveSession.severity, MCPAgentAction.Kind.exportSessions.severity)
        XCTAssertGreaterThan(MCPAgentAction.Kind.saveSession.severity, .routine)
        XCTAssertLessThan(MCPAgentAction.Kind.saveSession.severity, .rewritesTraffic)
    }

    /// A saved session was kept on purpose and the traffic behind it cannot be
    /// recaptured, so deleting one ranks with deleting a rule.
    func testDeletingASavedSessionIsDestructive() {
        XCTAssertEqual(MCPAgentAction.Kind.deleteSavedSession.severity, .destructive)
    }

    func testReplayingIsNotRoutineAndSaysWhy() {
        XCTAssertEqual(MCPAgentAction.Kind.replayRequest.severity, .actsOnThirdParty)
        let note = MCPAgentAction.Kind.replayRequest.consentNote
        XCTAssertTrue(note.contains("sends a real request"))
        XCTAssertTrue(note.contains("standing grant does not cover it"))
        XCTAssertTrue(note.contains("idempotent"))
    }

    func testWatchingIsRoutine() {
        XCTAssertEqual(MCPAgentAction.Kind.addHost.severity, .routine)
        XCTAssertEqual(MCPAgentAction.Kind.startCapture.severity, .routine)
        XCTAssertEqual(MCPAgentAction.Kind.stopCapture.severity, .routine)
    }

    /// One panel answers for a whole burst, so it must speak for the worst
    /// thing in it rather than the first.
    func testABurstIsJudgedByItsWorstAction() {
        let burst = [
            MCPAgentAction(kind: .addHost, summary: "Add api.example.com"),
            MCPAgentAction(kind: .deleteRule, summary: "Delete rule 3"),
            MCPAgentAction(kind: .createRule, summary: "Create a rule"),
        ]
        XCTAssertEqual(burst.highestSeverity, .destructive)

        let softer = [
            MCPAgentAction(kind: .addHost, summary: "Add api.example.com"),
            MCPAgentAction(kind: .createRule, summary: "Create a rule"),
        ]
        XCTAssertEqual(softer.highestSeverity, .rewritesTraffic)

        XCTAssertEqual([MCPAgentAction]().highestSeverity, .routine)
    }

    func testSeverityOrders() {
        XCTAssertLessThan(MCPAgentAction.Severity.routine, .rewritesTraffic)
        XCTAssertLessThan(MCPAgentAction.Severity.rewritesTraffic, .destructive)
        XCTAssertLessThan(MCPAgentAction.Severity.destructive, .actsOnThirdParty)
    }

    /// Replaying a request is the only thing on this surface whose effect is
    /// on a machine the user does not own, and the panel is titled by the
    /// burst's highest severity — so a future case added ABOVE it would
    /// silently retitle every burst containing a replay. Pinned rather than
    /// assumed.
    func testActingOnAThirdPartyIsTheHighestSeverityThereIs() {
        XCTAssertEqual(MCPAgentAction.Kind.replayRequest.severity, .actsOnThirdParty)
        for kind in MCPAgentAction.Kind.allCases {
            XCTAssertLessThanOrEqual(kind.severity, .actsOnThirdParty, "\(kind) outranks acting on someone else's server")
        }
        XCTAssertEqual(
            [MCPAgentAction(kind: .deleteRule, summary: "d"), MCPAgentAction(kind: .replayRequest, summary: "r")].highestSeverity,
            .actsOnThirdParty
        )
    }

    /// The point of the whole severity split, for this case: "let agents
    /// change rules and hosts without asking" is a statement about ReqRes,
    /// and must not become permission to send captured requests back out.
    func testOnlyActingOnAThirdPartyEscapesTheStandingGrant() {
        XCTAssertFalse(MCPAgentAction.Severity.actsOnThirdParty.canBeCoveredByStandingGrant)
        for severity in [MCPAgentAction.Severity.routine, .exportsData, .rewritesTraffic, .destructive] {
            XCTAssertTrue(severity.canBeCoveredByStandingGrant, "\(severity) should still be covered by the standing grant")
        }
        XCTAssertFalse(MCPAgentAction.Kind.replayRequest.severity.canBeCoveredByStandingGrant)
        XCTAssertTrue(MCPAgentAction.Kind.createRule.severity.canBeCoveredByStandingGrant)
    }

    /// The consequence line is what someone reads when they are deciding in a
    /// hurry, so each one has to say something different and concrete.
    func testEachSeverityNamesADifferentConsequence() {
        let lines = [
            MCPAgentAction.Severity.routine.consequence,
            MCPAgentAction.Severity.exportsData.consequence,
            MCPAgentAction.Severity.rewritesTraffic.consequence,
            MCPAgentAction.Severity.destructive.consequence,
            MCPAgentAction.Severity.actsOnThirdParty.consequence,
        ]
        XCTAssertEqual(Set(lines).count, 5)
        for line in lines {
            XCTAssertFalse(line.isEmpty)
            XCTAssertTrue(line.hasSuffix("."))
        }
        XCTAssertTrue(
            MCPAgentAction.Severity.destructive.consequence.contains("cannot be undone")
        )
        // Someone approving a replay in a hurry has to learn the one thing
        // that separates it from everything else on the panel: it leaves.
        let thirdParty = MCPAgentAction.Severity.actsOnThirdParty.consequence
        XCTAssertTrue(thirdParty.lowercased().contains("real request"))
        XCTAssertTrue(thirdParty.lowercased().contains("server"))
        // save_session and export_sessions share this line, and a saved
        // session is stored UNMASKED — so the shared sentence must not promise
        // masking. (The export route says so in its own per-action details.)
        let exportsData = MCPAgentAction.Severity.exportsData.consequence
        XCTAssertTrue(exportsData.contains("on disk"))
        XCTAssertFalse(exportsData.lowercased().contains("masked"))
    }

    /// The agent-facing note has to warn where the panel warns, or the two
    /// surfaces tell different stories about the same call.
    func testConsentNotesEscalateWithSeverity() {
        XCTAssertFalse(MCPAgentAction.Kind.addHost.consentNote.contains("rewrites live traffic"))
        XCTAssertTrue(MCPAgentAction.Kind.createRule.consentNote.contains("rewrites live traffic"))
        XCTAssertTrue(MCPAgentAction.Kind.deleteRule.consentNote.contains("cannot be restored"))

        for kind in MCPAgentAction.Kind.allCases {
            XCTAssertTrue(kind.consentNote.contains("consent_denied"))
        }
    }
}
