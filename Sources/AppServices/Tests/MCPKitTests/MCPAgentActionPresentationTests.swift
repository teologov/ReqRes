//
//  MCPAgentActionPresentationTests.swift
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
//  This logic used to live only inside MCPApprovalSheet, a SwiftUI view in a
//  target with no test target — so a title, icon or accessibility label
//  regression could only ever be caught by a human looking at the panel.
//  Each test below says what it would have caught back when this reasoning
//  had no test at all.
//

import XCTest
@testable import MCPKit

final class MCPAgentActionPresentationTests: XCTestCase {
    private func action(_ kind: MCPAgentAction.Kind, summary: String = "Do a thing", details: [String] = []) -> MCPAgentAction {
        MCPAgentAction(kind: kind, summary: summary, details: details)
    }

    // MARK: - Title

    /// Would have caught: the singular/plural wording swapped, or a severity
    /// picking up another severity's copy.
    func testTitleForOneActionAtEachSeverity() {
        XCTAssertEqual(
            MCPAgentActionPresentation(actions: [action(.addHost)]).title,
            "An AI agent wants to change ReqRes"
        )
        XCTAssertEqual(
            MCPAgentActionPresentation(actions: [action(.createRule)]).title,
            "An AI agent wants to change what your apps receive"
        )
        XCTAssertEqual(
            MCPAgentActionPresentation(actions: [action(.deleteRule)]).title,
            "An AI agent wants to delete something"
        )
    }

    /// Would have caught: the plural title losing the count, or using the
    /// singular form once there is more than one action.
    func testTitleForSeveralActionsAtEachSeverity() {
        XCTAssertEqual(
            MCPAgentActionPresentation(actions: [action(.addHost), action(.startCapture)]).title,
            "An AI agent wants to make 2 changes"
        )
        XCTAssertEqual(
            MCPAgentActionPresentation(actions: [action(.createRule), action(.updateRule)]).title,
            "An AI agent wants to make 2 changes to what your apps receive"
        )
        XCTAssertEqual(
            MCPAgentActionPresentation(actions: [action(.deleteRule), action(.removeHost)]).title,
            "An AI agent wants to make 2 changes, including deletions"
        )
    }

    /// The rule under direct test: one panel answers for a whole burst, so it
    /// has to be titled by the WORST action, not the first or the last. This
    /// is the exact behaviour the panel's own code comment calls out, and the
    /// one most likely to silently flip in a reorder or a refactor.
    func testMixedBurstIsTitledByItsWorstAction() {
        let leadingRoutine = [action(.addHost), action(.createRule), action(.deleteRule)]
        XCTAssertEqual(
            MCPAgentActionPresentation(actions: leadingRoutine).title,
            "An AI agent wants to make 3 changes, including deletions"
        )

        let leadingDestructive = [action(.deleteRule), action(.addHost), action(.createRule)]
        XCTAssertEqual(
            MCPAgentActionPresentation(actions: leadingDestructive).title,
            "An AI agent wants to make 3 changes, including deletions",
            "titling by the last action instead of the worst would have picked the createRule wording here"
        )

        let routineAndTraffic = [action(.startCapture), action(.mockFromSession)]
        XCTAssertEqual(
            MCPAgentActionPresentation(actions: routineAndTraffic).title,
            "An AI agent wants to make 2 changes to what your apps receive"
        )
    }

    // MARK: - Consequence

    /// Would have caught: two severities sharing a consequence line, which
    /// defeats the point of stating it once per burst.
    func testConsequenceLineDiffersPerSeverity() {
        let lines = [
            MCPAgentActionPresentation(actions: [action(.addHost)]).consequence,
            MCPAgentActionPresentation(actions: [action(.createRule)]).consequence,
            MCPAgentActionPresentation(actions: [action(.deleteRule)]).consequence,
        ]
        XCTAssertEqual(Set(lines).count, 3)
        for line in lines {
            XCTAssertFalse(line.isEmpty)
        }
    }

    /// Would have caught: the consequence line being picked from the first or
    /// last action instead of the burst's worst, same failure mode as the
    /// title.
    func testConsequenceIsJudgedByTheWorstActionToo() {
        let burst = [action(.addHost), action(.deleteRule)]
        XCTAssertEqual(
            MCPAgentActionPresentation(actions: burst).consequence,
            MCPAgentAction.Severity.destructive.consequence
        )
    }

    // MARK: - Symbols

    /// Would have caught: a kind falling through to the wrong glyph (e.g. a
    /// new case silently sharing `createRule`'s symbol) — checked against
    /// every kind that exists today, not a hand-picked subset. The switch
    /// below is exhaustive over `Kind`, so a case added without a line here
    /// fails to compile rather than silently passing untested.
    func testEveryActionKindHasASymbol() {
        for kind in MCPAgentAction.Kind.allCases {
            let symbol = MCPAgentActionPresentation(actions: [action(kind)]).rows.first?.symbolName
            let expected: String
            switch kind {
            case .addHost: expected = "globe.badge.chevron.backward"
            case .removeHost: expected = "globe"
            case .createRule: expected = "arrow.triangle.branch"
            case .updateRule: expected = "pencil"
            case .deleteRule: expected = "trash"
            case .mockFromSession: expected = "arrow.triangle.branch"
            case .startCapture: expected = "record.circle"
            case .stopCapture: expected = "stop.circle"
            case .clearSessions: expected = "trash.slash"
            case .exportSessions: expected = "square.and.arrow.up"
            case .saveSession: expected = "bookmark"
            case .deleteSavedSession: expected = "bookmark.slash"
            case .replayRequest: expected = "paperplane"
            case .answerPausedRequest: expected = "play.pause"
            case .excludeHost: expected = "eye.slash"
            }
            XCTAssertEqual(symbol, expected, "wrong symbol for \(kind)")
        }
        XCTAssertEqual(MCPAgentAction.Kind.allCases.count, 15, "a new kind needs a case added to the switch above")
    }

    /// Each row's icon is tinted by ITS OWN severity, not the burst's worst —
    /// a routine `add_host` sitting next to a delete must stay neutral, or
    /// colour stops meaning anything per-row. Would have caught: tinting
    /// every row by the burst's highest severity instead of its own.
    func testRowTintFollowsItsOwnActionNotTheBurst() {
        let burst = [action(.addHost), action(.deleteRule)]
        let rows = MCPAgentActionPresentation(actions: burst).rows
        XCTAssertEqual(rows[0].tint, .neutral)
        XCTAssertEqual(rows[1].tint, .destructive)
    }

    /// Would have caught: `save_session` inheriting the routine title, which
    /// would tell someone approving it that their traffic is not altered —
    /// true, and beside the point when the question is whether this exchange
    /// should be written to disk.
    func testKeepingASessionIsTitledAsPuttingTrafficOnDisk() {
        let presentation = MCPAgentActionPresentation(actions: [action(.saveSession)])
        XCTAssertEqual(presentation.title, "An AI agent wants to save captured traffic to a file")
        XCTAssertEqual(presentation.tint, .caution)
        XCTAssertEqual(presentation.rows[0].accessibilityLabel.hasPrefix("Writes captured traffic to a file"), true)
    }

    // MARK: - Accessibility

    /// Would have caught: the weight prefix being dropped so colour became
    /// the only signal, or the summary/details being left out so VoiceOver
    /// read nothing about what is actually changing.
    func testAccessibilityLabelNamesTheWeightAndIncludesSummaryAndDetails() {
        let withDetails = action(.deleteRule, summary: "Delete rule #12", details: ["GET /users?*", "api.example.com"])
        let label = MCPAgentActionPresentation(actions: [withDetails]).rows[0].accessibilityLabel

        XCTAssertTrue(label.hasPrefix("Deletes data"))
        XCTAssertTrue(label.contains("Delete rule #12"))
        XCTAssertTrue(label.contains("GET /users?*"))
        XCTAssertTrue(label.contains("api.example.com"))
    }

    /// Would have caught: all three severities collapsing onto one weight
    /// phrase, which is exactly what makes colour the only signal.
    func testAccessibilityWeightNamesEachSeverityDifferently() {
        let labels = [
            MCPAgentActionPresentation(actions: [action(.addHost)]).rows[0].accessibilityLabel,
            MCPAgentActionPresentation(actions: [action(.createRule)]).rows[0].accessibilityLabel,
            MCPAgentActionPresentation(actions: [action(.deleteRule)]).rows[0].accessibilityLabel,
        ]
        XCTAssertTrue(labels[0].hasPrefix("Changes what ReqRes watches"))
        XCTAssertTrue(labels[1].hasPrefix("Rewrites live traffic"))
        XCTAssertTrue(labels[2].hasPrefix("Deletes data"))
    }

    // MARK: - Empty burst

    /// Would have caught: `.max()` on an empty collection crashing instead of
    /// falling back to `.routine`, and a title built from a divide-by-zero-
    /// shaped count check.
    func testEmptyActionListDoesNotCrashAndReadsAsRoutine() {
        let presentation = MCPAgentActionPresentation(actions: [])
        XCTAssertEqual(presentation.title, "An AI agent wants to make 0 changes")
        XCTAssertEqual(presentation.consequence, MCPAgentAction.Severity.routine.consequence)
        XCTAssertEqual(presentation.tint, .neutral)
        XCTAssertTrue(presentation.rows.isEmpty)
    }
}
