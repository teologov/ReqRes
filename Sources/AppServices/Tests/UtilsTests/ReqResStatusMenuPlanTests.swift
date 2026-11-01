//
//  ReqResStatusMenuPlanTests.swift
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
//  Guards the menu bar status item's GLYPH, ARRANGEMENT and WORDING.
//
//  The status item is what a user reads while they are not reading ReqRes,
//  so every defect it can have is a silent one: a glyph that stops
//  distinguishing "capturing" from "idle", a "Resume All" row that quietly
//  never appears while a browser tab hangs on a held request, a menu that
//  still says "Quit ReqRes" when quitting will also stop the capture the
//  user is relying on. None of those fail a build. They fail here.
//

import XCTest
@testable import Utils

final class ReqResStatusMenuPlanTests: XCTestCase {

    // MARK: - Helpers

    private func ids(_ rows: [ReqResStatusMenuRow]) -> [ReqResStatusMenuItem] {
        rows.map(\.id)
    }

    private func row(_ id: ReqResStatusMenuItem, in rows: [ReqResStatusMenuRow]) -> ReqResStatusMenuRow? {
        rows.first { $0.id == id }
    }

    /// Every combination of the flags, so the structural rules below are
    /// asserted against states nobody thought to write down. Delivery (F11)
    /// and the bus are crossed in too — including combinations the app never
    /// produces, because the rules must hold whatever it hands in.
    private var everyState: [ReqResStatusState] {
        var states: [ReqResStatusState] = []
        let deliveries: [CaptureDelivery] = [.notCapturing, .waiting, .reconnecting, .receiving, .notReceiving(.appRelaunched), .anotherCopy]
        for capturing in [false, true] {
            for blocked in [false, true] {
                for transitional in [false, true] {
                    for held in [0, 1, 3] {
                        for agent in [nil, "Claude Code"] as [String?] {
                            for bridge in [false, true] {
                                for delivery in deliveries {
                                    for holdsBus in [true, false] {
                                        states.append(ReqResStatusState(
                                            capturing: capturing,
                                            setupBlocked: blocked,
                                            transitional: transitional,
                                            heldRequestCount: held,
                                            shortestFuseSeconds: held > 0 ? 41 : nil,
                                            activeAgentName: agent,
                                            bridgeEnabled: bridge,
                                            delivery: delivery,
                                            holdsBus: holdsBus))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return states
    }

    /// 14:02:00 UTC on a fixed day. Built from components rather than an
    /// epoch literal so the intent of the number is readable.
    private func fixedDate(hour: Int, minute: Int, day: Int = 13) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: 2020, month: 9, day: day, hour: hour, minute: minute)
        return calendar.date(from: components)!
    }

    // MARK: - Glyph precedence

    /// The precedence is the whole design of the glyph, and the only way to
    /// break it is to reorder four `if`s. A held request is a request hanging
    /// with a 60-second fuse on it — it outranks everything, including a
    /// setup problem that arrived at the same time.
    func testHeldRequestsOutrankASetupProblem() {
        let state = ReqResStatusState(capturing: true, setupBlocked: true, heldRequestCount: 2)
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .waiting)
    }

    /// Capture "working" while setup is blocked is not a state to reassure
    /// anyone about: capture is not actually working.
    func testASetupProblemOutranksCapturing() {
        let state = ReqResStatusState(capturing: true, setupBlocked: true)
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .blocked)
    }

    func testCapturingOutranksIdle() {
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: ReqResStatusState(capturing: true)), .capturing)
    }

    func testTheDefaultStateIsIdle() {
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: ReqResStatusState()), .idle)
    }

    /// A single held request is still a held request. An `> 1` typo here
    /// would hide exactly the case a user is most likely to hit.
    func testOneHeldRequestIsEnoughToShowTheWaitingGlyph() {
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: ReqResStatusState(heldRequestCount: 1)), .waiting)
    }

    /// A negative count can only be a bug upstream; it must not read as
    /// "requests are held" in the menu bar.
    func testANegativeHeldCountIsClampedAndDoesNotShowTheWaitingGlyph() {
        let state = ReqResStatusState(heldRequestCount: -3)
        XCTAssertEqual(state.heldRequestCount, 0)
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .idle)
    }

    // MARK: - Glyph symbols

    /// The drawing code chooses nothing; these names ARE the design. A typo
    /// in an SF Symbol name renders as a blank menu bar item, not a crash.
    func testSymbolNames() {
        XCTAssertEqual(ReqResStatusIcon.waiting.symbolName, "exclamationmark.circle.fill")
        XCTAssertEqual(ReqResStatusIcon.blocked.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(ReqResStatusIcon.capturing.symbolName, "record.circle.fill")
        XCTAssertEqual(ReqResStatusIcon.idle.symbolName, "record.circle")
    }

    /// Two states sharing a glyph would make the status item unreadable for
    /// the one case it exists to report.
    func testEveryStateHasItsOwnSymbol() {
        let names = ReqResStatusIcon.allCases.map(\.symbolName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(where: { $0.isEmpty }))
    }

    // MARK: - The dim is independent of the shape

    /// Connecting must DIM the glyph, never reshape it. A fifth case would
    /// flicker a third silhouette through the menu bar on every start and
    /// stop — motion that reads as a fault during an entirely normal action.
    func testTransitionalNeverChangesTheGlyph() {
        for state in everyState where !state.transitional {
            var moving = state
            moving.transitional = true
            XCTAssertEqual(
                ReqResStatusMenuPlan.icon(for: moving),
                ReqResStatusMenuPlan.icon(for: state),
                "transitional changed the glyph for \(state)")
        }
    }

    /// The other half of the same rule: the dim must follow `transitional`
    /// and nothing else, or a blocked-but-settled state starts fading.
    func testDimFollowsTransitionalAlone() {
        for state in everyState {
            XCTAssertEqual(ReqResStatusMenuPlan.isDimmed(for: state), state.transitional)
        }
    }

    /// Counting the cases is the cheap way to catch someone "fixing" the
    /// above by adding `.connecting` to the enum.
    func testThereAreExactlyFourGlyphs() {
        XCTAssertEqual(ReqResStatusIcon.allCases.count, 4)
    }

    // MARK: - Status line

    func testStatusLineNamesEachState() {
        XCTAssertEqual(ReqResStatusMenuPlan.statusTitle(for: ReqResStatusState()), "Not capturing")
        XCTAssertEqual(
            ReqResStatusMenuPlan.statusTitle(for: ReqResStatusState(capturing: true)),
            "Capturing")
        XCTAssertEqual(
            ReqResStatusMenuPlan.statusTitle(for: ReqResStatusState(setupBlocked: true)),
            "Setup needs attention")
        XCTAssertEqual(
            ReqResStatusMenuPlan.statusTitle(for: ReqResStatusState(heldRequestCount: 2)),
            "2 requests held")
    }

    /// The time is appended, never substituted — a status line that loses the
    /// word "Capturing" as soon as a start time is known is the regression.
    func testStatusLineCarriesThePreFormattedSinceTime() {
        let state = ReqResStatusState(capturing: true)
        XCTAssertEqual(
            ReqResStatusMenuPlan.statusTitle(for: state, capturingSinceText: "14:02"),
            "Capturing — since 14:02")
    }

    /// An empty string must not render as "Capturing — since ".
    func testAnEmptySinceTimeIsTreatedAsNoSinceTime() {
        let state = ReqResStatusState(capturing: true)
        XCTAssertEqual(ReqResStatusMenuPlan.statusTitle(for: state, capturingSinceText: ""), "Capturing")
    }

    /// "Not capturing" during a connect is simply false. The glyph has only
    /// dimming to say this with; the menu has a sentence.
    func testStatusLineSpeaksTheTransitionalStateTheGlyphCannot() {
        let state = ReqResStatusState(transitional: true)
        XCTAssertEqual(ReqResStatusMenuPlan.statusTitle(for: state), "Starting or stopping capture")
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .idle)
    }

    /// `transitional` is one Bool and cannot tell a connect from a
    /// disconnect. Claiming a direction would show "Starting capture…" while
    /// capture is stopping, which is worse than the vaguer truth.
    func testTheTransitionalLineClaimsNoDirection() {
        let stopping = ReqResStatusState(capturing: true, transitional: true)
        let starting = ReqResStatusState(capturing: false, transitional: true)
        XCTAssertEqual(
            ReqResStatusMenuPlan.statusTitle(for: stopping),
            ReqResStatusMenuPlan.statusTitle(for: starting))
    }

    /// Held and blocked still outrank the transitional line, exactly as they
    /// outrank each other in the glyph.
    func testStatusLineRanksHeldAndBlockedAboveTransitional() {
        XCTAssertEqual(
            ReqResStatusMenuPlan.statusTitle(for: ReqResStatusState(transitional: true, heldRequestCount: 1)),
            "1 request held")
        XCTAssertEqual(
            ReqResStatusMenuPlan.statusTitle(for: ReqResStatusState(setupBlocked: true, transitional: true)),
            "Setup needs attention")
    }

    // MARK: - Accessibility

    /// For a VoiceOver user the glyph is not a signal and neither is the dim.
    /// Without these words there is NO way for that user to learn that ReqRes
    /// is currently intercepting their machine's traffic.
    func testAccessibilityLabelSpellsTheStateOut() {
        XCTAssertEqual(
            ReqResStatusMenuPlan.accessibilityLabel(for: ReqResStatusState(capturing: true)),
            "ReqRes: capturing")
        XCTAssertEqual(
            ReqResStatusMenuPlan.accessibilityLabel(for: ReqResStatusState()),
            "ReqRes: not capturing")
        XCTAssertEqual(
            ReqResStatusMenuPlan.accessibilityLabel(for: ReqResStatusState(setupBlocked: true)),
            "ReqRes: setup needs attention")
        XCTAssertEqual(
            ReqResStatusMenuPlan.accessibilityLabel(for: ReqResStatusState(heldRequestCount: 2)),
            "ReqRes: 2 requests held")
    }

    /// The transitional state reaches an assistive user ONLY here — dimming
    /// is invisible to VoiceOver. A label derived from the icon case (the
    /// obvious refactor) would silently drop it.
    func testAccessibilityLabelSpeaksTheTransitionalState() {
        XCTAssertEqual(
            ReqResStatusMenuPlan.accessibilityLabel(for: ReqResStatusState(transitional: true)),
            "ReqRes: starting or stopping capture")
    }

    /// The label follows the same precedence as the glyph, or a screen reader
    /// and the screen describe two different apps.
    func testAccessibilityLabelFollowsTheGlyphPrecedence() {
        let state = ReqResStatusState(capturing: true, setupBlocked: true, heldRequestCount: 1)
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .waiting)
        XCTAssertEqual(ReqResStatusMenuPlan.accessibilityLabel(for: state), "ReqRes: 1 request held")
    }

    /// It takes no formatter on purpose: the label must not be one more thing
    /// that can be wrong about the clock.
    func testAccessibilityLabelNeverMentionsTheSinceTime() {
        let state = ReqResStatusState(capturing: true, capturingSince: fixedDate(hour: 14, minute: 2))
        XCTAssertEqual(ReqResStatusMenuPlan.accessibilityLabel(for: state), "ReqRes: capturing")
    }

    // MARK: - Menu shape

    /// The state is the first thing read and the quit is the last thing
    /// reached; anything else makes the menu a lottery for muscle memory.
    func testTheMenuOpensWithTheStateAndEndsWithQuit() {
        for state in everyState {
            let rows = ReqResStatusMenuPlan.rows(for: state)
            XCTAssertEqual(rows.first?.id, .status)
            XCTAssertEqual(rows.last?.id, .quit)
        }
    }

    /// The capture control sits directly under the state it changes.
    func testTheCaptureToggleFollowsTheStatusLine() {
        for state in everyState {
            XCTAssertEqual(ids(ReqResStatusMenuPlan.rows(for: state))[1], .toggleCapture)
        }
    }

    func testTheCaptureToggleNamesTheActionNotTheState() {
        XCTAssertEqual(
            row(.toggleCapture, in: ReqResStatusMenuPlan.rows(for: ReqResStatusState(capturing: true)))?.title,
            "Stop Capturing")
        XCTAssertEqual(
            row(.toggleCapture, in: ReqResStatusMenuPlan.rows(for: ReqResStatusState()))?.title,
            "Start Capturing")
    }

    /// A second start landing on a half-built tunnel is how the extension
    /// gets wedged in `Connecting` — measured on this machine, and only a
    /// reboot clears it.
    func testTheCaptureToggleIsDisabledWhileTheTunnelIsMoving() {
        let rows = ReqResStatusMenuPlan.rows(for: ReqResStatusState(transitional: true))
        XCTAssertEqual(row(.toggleCapture, in: rows)?.isEnabled, false)
        XCTAssertEqual(row(.toggleCapture, in: ReqResStatusMenuPlan.rows(for: ReqResStatusState()))?.isEnabled, true)
    }

    /// Status text with a target reads as clickable and does nothing when
    /// clicked. AppKit greys out a row without one; this is that rule, kept
    /// where it can be asserted.
    func testInformationalRowsAreNeverClickable() {
        for state in everyState {
            for row in ReqResStatusMenuPlan.rows(for: state) where row.id.isInformational {
                XCTAssertFalse(row.isEnabled, "\(row.id) is text but offers itself as a command")
            }
        }
    }

    /// The other direction, which is the one that strands a user: a command
    /// row that arrives disabled cannot be chosen, and the ONLY row allowed
    /// to do that is the capture toggle mid-transition. Anything else greyed
    /// out is a dead menu item.
    func testEveryCommandRowIsReachableExceptTheToggleMidTransition() {
        for state in everyState {
            for row in ReqResStatusMenuPlan.rows(for: state)
            where !row.isSeparator && !row.id.isInformational {
                let allowedToBeDisabled = row.id == .toggleCapture && state.transitional
                XCTAssertEqual(row.isEnabled, !allowedToBeDisabled, "\(row.id) is unreachable in \(state)")
            }
        }
    }

    // MARK: - Conditional rows

    /// The row and its action are one feature: a count with no way to act on
    /// it leaves the user watching a fuse burn down.
    func testHeldRowsAppearTogetherAndOnlyWhenRequestsAreHeld() {
        let quiet = ids(ReqResStatusMenuPlan.rows(for: ReqResStatusState()))
        XCTAssertFalse(quiet.contains(.heldRequests))
        XCTAssertFalse(quiet.contains(.resumeAll))

        let busy = ids(ReqResStatusMenuPlan.rows(for: ReqResStatusState(heldRequestCount: 2)))
        XCTAssertTrue(busy.contains(.heldRequests))
        XCTAssertEqual(busy[busy.firstIndex(of: .heldRequests)! + 1], .resumeAll)
    }

    /// "Claude Code connected" is the only place the user learns an agent is
    /// driving their proxy without opening the app.
    func testTheAgentRowAppearsOnlyWhenAnAgentIsConnected() {
        let named = ReqResStatusMenuPlan.rows(for: ReqResStatusState(activeAgentName: "Claude Code"))
        XCTAssertEqual(row(.activeAgent, in: named)?.title, "Claude Code connected")
        XCTAssertNil(row(.activeAgent, in: ReqResStatusMenuPlan.rows(for: ReqResStatusState())))
    }

    /// The registry identifies a client by its parent process, which can come
    /// back blank; " connected" is not a menu row.
    func testABlankAgentNameIsNoAgent() {
        let state = ReqResStatusState(activeAgentName: "   ")
        XCTAssertNil(state.activeAgentName)
        XCTAssertNil(row(.activeAgent, in: ReqResStatusMenuPlan.rows(for: state)))
    }

    /// The bridge is a listening port whether or not anything is talking to
    /// it, so the kill switch must be reachable when no agent is connected —
    /// which is exactly when a user who did not expect a bridge goes looking.
    func testTheBridgeKillSwitchDoesNotDependOnAnAgentBeingConnected() {
        let rows = ReqResStatusMenuPlan.rows(for: ReqResStatusState(bridgeEnabled: true))
        XCTAssertNotNil(row(.turnOffBridge, in: rows))
        XCTAssertNil(row(.activeAgent, in: rows))
    }

    func testTheBridgeKillSwitchIsHiddenWhenTheBridgeIsOff() {
        let rows = ReqResStatusMenuPlan.rows(for: ReqResStatusState(activeAgentName: "Claude Code"))
        XCTAssertNil(row(.turnOffBridge, in: rows))
    }

    /// The diagnosis is offered exactly when there is something to diagnose;
    /// offering it always trains users to ignore it.
    func testDiagnoseAppearsOnlyWhenSetupIsBlocked() {
        XCTAssertNotNil(row(.diagnoseSetup, in: ReqResStatusMenuPlan.rows(for: ReqResStatusState(setupBlocked: true))))
        XCTAssertNil(row(.diagnoseSetup, in: ReqResStatusMenuPlan.rows(for: ReqResStatusState())))
    }

    /// It belongs with the problem it solves, next to Open ReqRes, not down
    /// beside Quit.
    func testDiagnoseSitsDirectlyAfterOpenReqRes() {
        let rows = ids(ReqResStatusMenuPlan.rows(for: ReqResStatusState(setupBlocked: true)))
        XCTAssertEqual(rows[rows.firstIndex(of: .openApp)! + 1], .diagnoseSetup)
    }

    // MARK: - Quit

    /// Quitting ReqRes tears down the tunnel. A user quitting "just the
    /// little icon" is also turning off the capture they are relying on, and
    /// the parenthetical is the only warning they get.
    func testQuitSaysItStopsCaptureOnlyWhenItWould() {
        XCTAssertEqual(
            row(.quit, in: ReqResStatusMenuPlan.rows(for: ReqResStatusState(capturing: true)))?.title,
            "Quit ReqRes (stops capture)")
        XCTAssertEqual(
            row(.quit, in: ReqResStatusMenuPlan.rows(for: ReqResStatusState()))?.title,
            "Quit ReqRes")
    }

    /// Setup being blocked does not mean capture is off — the warning must
    /// track the capture flag, not the glyph.
    func testQuitWarnsWhileCapturingEvenWhenAnotherStateOwnsTheGlyph() {
        let state = ReqResStatusState(capturing: true, setupBlocked: true, heldRequestCount: 1)
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .waiting)
        XCTAssertEqual(row(.quit, in: ReqResStatusMenuPlan.rows(for: state))?.title, "Quit ReqRes (stops capture)")
    }

    // MARK: - Capture on, not reaching ReqRes (F11)

    /// After a relaunch while capturing, the tunnel ran on and nothing reached
    /// the app. The menu says so, offers the fix right under the toggle, and
    /// the glyph stops promising that capture is fine.
    func testNotReachingReqResSaysSoAndOffersRestartUnderTheToggle() {
        let state = ReqResStatusState(capturing: true, delivery: .notReceiving(.appRelaunched))
        let rows = ReqResStatusMenuPlan.rows(for: state)
        XCTAssertEqual(ids(rows), [.status, .toggleCapture, .restartCapture, .sectionSeparator, .openApp, .settings, .quit])
        XCTAssertEqual(row(.status, in: rows)?.title, "Capture is on but not reaching ReqRes")
        XCTAssertEqual(row(.toggleCapture, in: rows)?.title, "Stop Capturing")
        XCTAssertEqual(row(.restartCapture, in: rows)?.title, "Restart Capture")
        XCTAssertEqual(row(.restartCapture, in: rows)?.isEnabled, true)
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .blocked)
        XCTAssertEqual(ReqResStatusMenuPlan.accessibilityLabel(for: state), "ReqRes: capture is on but not reaching ReqRes")
        XCTAssertEqual(row(.quit, in: rows)?.title, "Quit ReqRes (stops capture)")
    }

    /// Every reason gets the same line and row; the reason is the pane's.
    func testEveryProblemReadsTheSameInTheMenu() {
        for problem in CaptureDeliveryProblem.allCases {
            let rows = ReqResStatusMenuPlan.rows(for: ReqResStatusState(capturing: true, delivery: .notReceiving(problem)))
            XCTAssertEqual(row(.status, in: rows)?.title, CaptureDeliveryCopy.menuNotReceiving, "\(problem)")
            XCTAssertNotNil(row(.restartCapture, in: rows), "\(problem)")
        }
    }

    /// Restart is offered only while it can help: capture on, not reaching
    /// this app, the tunnel not already moving.
    func testRestartIsOfferedOnlyWhileCapturingAndNotReceiving() {
        for state in everyState {
            let offered = row(.restartCapture, in: ReqResStatusMenuPlan.rows(for: state)) != nil
            let expected = state.capturing && state.delivery.offersRestart && !state.transitional
            XCTAssertEqual(offered, expected, "\(state)")
        }
    }

    /// A verdict about delivery says nothing while capture is off.
    func testDeliveryIsSilentWhileNotCapturing() {
        for delivery in [CaptureDelivery.notReceiving(.appRelaunched), .anotherCopy] {
            let state = ReqResStatusState(capturing: false, delivery: delivery)
            XCTAssertEqual(ReqResStatusMenuPlan.statusTitle(for: state), "Not capturing")
            XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .idle)
        }
    }

    /// Another copy holding the capture is named — only what is known: it
    /// holds the connection, not that it receives — with no Restart (it would
    /// take the capture from that copy), and a Quit that does not claim to
    /// stop it.
    func testAnotherCopyIsNamedWithoutRestartAndItsQuitStopsNothing() {
        let state = ReqResStatusState(capturing: true, delivery: .anotherCopy, holdsBus: false)
        let rows = ReqResStatusMenuPlan.rows(for: state)
        XCTAssertEqual(row(.status, in: rows)?.title, "Another copy of ReqRes holds this capture's connection")
        XCTAssertNil(row(.restartCapture, in: rows))
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .capturing, "capture is on, and the glyph discloses it")
        XCTAssertEqual(ReqResStatusMenuPlan.accessibilityLabel(for: state), "ReqRes: another copy of ReqRes holds this capture's connection")
        XCTAssertEqual(row(.quit, in: rows)?.title, "Quit ReqRes")
    }

    /// The copy that held the bus is gone and this one cannot bind it, with
    /// no other copy running: the capture reaches nobody. Its Quit asks and
    /// stops it, and says so (F11 review — it left the tunnel decrypting for
    /// no one, without a word).
    func testACopyWithoutTheBusAndNoOtherCopySaysItsQuitStopsCapture() {
        let state = ReqResStatusState(capturing: true, delivery: .notReceiving(.notListening), holdsBus: false)
        let rows = ReqResStatusMenuPlan.rows(for: state)
        XCTAssertEqual(row(.quit, in: rows)?.title, "Quit ReqRes (stops capture)")
        XCTAssertEqual(row(.restartCapture, in: rows)?.title, "Restart Capture")
        XCTAssertTrue(state.quitStopsCapture)
    }

    // MARK: - Reconnecting to a capture that outlived the app (build 53)

    /// The relaunched app finds the capture running and its extension
    /// redialing: the line says so, the glyph keeps disclosing capture (it is
    /// on, and nothing is broken), nothing is offered to fix, and Stop still
    /// stops it.
    func testReconnectingSaysSoWithoutAFix() {
        let state = ReqResStatusState(capturing: true, delivery: .reconnecting)
        let rows = ReqResStatusMenuPlan.rows(for: state, capturingSinceText: "14:02")
        XCTAssertEqual(ids(rows), [.status, .toggleCapture, .sectionSeparator, .openApp, .settings, .quit])
        XCTAssertEqual(row(.status, in: rows)?.title, "Reconnecting to the running capture…")
        XCTAssertEqual(row(.toggleCapture, in: rows)?.title, "Stop Capturing")
        XCTAssertEqual(row(.toggleCapture, in: rows)?.isEnabled, true)
        XCTAssertNil(row(.restartCapture, in: rows), "nothing to restart while it reconnects")
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .capturing)
        XCTAssertFalse(ReqResStatusMenuPlan.isDimmed(for: state), "not the tunnel moving")
        XCTAssertEqual(ReqResStatusMenuPlan.accessibilityLabel(for: state), "ReqRes: reconnecting to the running capture")
        XCTAssertEqual(row(.quit, in: rows)?.title, "Quit ReqRes (stops capture)")
    }

    /// Reconnecting says nothing while capture is off, and a held request
    /// still outranks it (the greeting re-announces held requests).
    func testReconnectingYieldsToHeldRequestsAndToCaptureOff() {
        XCTAssertEqual(ReqResStatusMenuPlan.statusTitle(for: ReqResStatusState(capturing: false, delivery: .reconnecting)), "Not capturing")
        let held = ReqResStatusState(capturing: true, heldRequestCount: 2, delivery: .reconnecting)
        XCTAssertEqual(ReqResStatusMenuPlan.statusTitle(for: held), "2 requests held")
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: held), .waiting)
    }

    /// Held requests still outrank everything, the delivery line included.
    func testHeldRequestsStillOutrankNotReaching() {
        let state = ReqResStatusState(capturing: true, heldRequestCount: 1, delivery: .notReceiving(.appRelaunched))
        XCTAssertEqual(ReqResStatusMenuPlan.icon(for: state), .waiting)
        XCTAssertEqual(ReqResStatusMenuPlan.statusTitle(for: state), "1 request held")
    }

    /// The Quit row claims to stop capture exactly when quitting does
    /// (`CaptureControl.stopsCaptureOnQuit`): capturing, and not a copy
    /// without the bus while another copy holds the capture.
    func testQuitClaimsToStopCaptureExactlyWhenTheQuitDoes() {
        for state in everyState {
            let title = row(.quit, in: ReqResStatusMenuPlan.rows(for: state))?.title
            let stops = state.capturing && (state.holdsBus || state.delivery != .anotherCopy)
            XCTAssertEqual(state.quitStopsCapture, stops, "\(state)")
            XCTAssertEqual(title, stops ? "Quit ReqRes (stops capture)" : "Quit ReqRes", "\(state)")
            XCTAssertEqual(state.quitStopsCapture,
                           state.capturing && CaptureControl.stopsCaptureOnQuit(real: .connected, holdsBus: state.holdsBus,
                                                                                anotherCopyRunning: state.delivery == .anotherCopy),
                           "the menu and the quit ask the same rule")
        }
    }

    // MARK: - Separators

    /// Both middle sections are conditional, so the plain assembly produces
    /// two adjacent rules in the app's ORDINARY state — nothing held, no
    /// agent, bridge off. AppKit draws every separator it is handed.
    func testNoDoubledLeadingOrTrailingSeparators() {
        for state in everyState {
            let rows = ReqResStatusMenuPlan.rows(for: state)
            XCTAssertFalse(rows.first?.isSeparator ?? false, "leading separator for \(state)")
            XCTAssertFalse(rows.last?.isSeparator ?? false, "trailing separator for \(state)")
            for (first, second) in zip(rows, rows.dropFirst()) {
                XCTAssertFalse(first.isSeparator && second.isSeparator, "doubled separator for \(state)")
            }
        }
    }

    /// The quiet menu keeps ONE rule between the capture control and the app
    /// section — losing it entirely would run the two sections together.
    func testTheQuietMenuKeepsExactlyOneSeparator() {
        let rows = ids(ReqResStatusMenuPlan.rows(for: ReqResStatusState()))
        XCTAssertEqual(rows, [.status, .toggleCapture, .sectionSeparator, .openApp, .settings, .quit])
    }

    /// The busy menu keeps both, one per section boundary.
    func testABusyMenuKeepsBothSeparators() {
        let state = ReqResStatusState(
            capturing: true,
            heldRequestCount: 2,
            shortestFuseSeconds: 41,
            activeAgentName: "Claude Code",
            bridgeEnabled: true)
        XCTAssertEqual(ids(ReqResStatusMenuPlan.rows(for: state)), [
            .status, .toggleCapture,
            .sectionSeparator,
            .heldRequests, .resumeAll, .activeAgent, .turnOffBridge,
            .appSeparator,
            .openApp, .settings, .quit,
        ])
    }

    /// A separator with a title would render one in AppKit; a titleless
    /// ordinary row renders as an unreadable blank line.
    func testOnlySeparatorsAreTitleless() {
        for state in everyState {
            for row in ReqResStatusMenuPlan.rows(for: state) {
                XCTAssertEqual(row.title.isEmpty, row.isSeparator, "\(row.id) has the wrong title emptiness")
            }
        }
    }

    // MARK: - Fuse

    /// The queue is in arrival order, so the FIRST entry is usually — but not
    /// always — the one with the least time left. "Usually" is what makes
    /// taking it by position a bug that survives testing.
    func testTheShortestFuseIsChosenNotTheFirst() {
        XCTAssertEqual(ReqResStatusMenuPlan.shortestFuse(among: [58, 9, 41]), 9)
        XCTAssertEqual(ReqResStatusMenuPlan.shortestFuse(among: [12]), 12)
        XCTAssertNil(ReqResStatusMenuPlan.shortestFuse(among: []))
    }

    /// A held request whose fuse burns out is resumed by the core WITHOUT
    /// asking. The number shown is how long the user has before the decision
    /// is made for them, so it must read as a deadline, not a duration.
    func testFuseWording() {
        XCTAssertEqual(ReqResStatusMenuPlan.fuseText(seconds: 41), "41s left")
        XCTAssertEqual(ReqResStatusMenuPlan.fuseText(seconds: 1), "1s left")
        XCTAssertEqual(ReqResStatusMenuPlan.fuseText(seconds: 65), "1m 5s left")
        XCTAssertEqual(ReqResStatusMenuPlan.fuseText(seconds: 120), "2m left")
    }

    /// Zero is not "0s left" — the fuse has burned and the core is about to
    /// resume the request on its own. That is the difference between "hurry"
    /// and "too late", and a clock that has gone backwards must not render a
    /// negative one.
    func testAnExpiredFuseSaysSoInsteadOfCountingPastZero() {
        XCTAssertEqual(ReqResStatusMenuPlan.fuseText(seconds: 0), "resuming now")
        XCTAssertEqual(ReqResStatusMenuPlan.fuseText(seconds: -4), "resuming now")
    }

    /// "1 requests held" is the classic. It is also the most-seen case.
    func testHeldCountIsPluralised() {
        XCTAssertEqual(ReqResStatusMenuPlan.heldCountText(1), "1 request held")
        XCTAssertEqual(ReqResStatusMenuPlan.heldCountText(2), "2 requests held")
        XCTAssertEqual(ReqResStatusMenuPlan.heldCountText(0), "0 requests held")
    }

    func testTheHeldRowCarriesTheCountAndTheShortestFuse() {
        let state = ReqResStatusState(heldRequestCount: 2, shortestFuseSeconds: 41)
        XCTAssertEqual(row(.heldRequests, in: ReqResStatusMenuPlan.rows(for: state))?.title,
                       "2 requests held — 41s left")
    }

    /// No fuse known is not a fuse of zero: showing "resuming now" for an
    /// unknown deadline would panic the user for nothing.
    func testTheHeldRowOmitsTheFuseWhenNoneIsKnown() {
        let state = ReqResStatusState(heldRequestCount: 1)
        XCTAssertEqual(row(.heldRequests, in: ReqResStatusMenuPlan.rows(for: state))?.title, "1 request held")
    }

    // MARK: - Time

    /// The bug this repo has already paid for, in
    /// `SavedSessionSummary.relativeAge`: a function that politely takes a
    /// date and then asks the SYSTEM what today is, so its tests pass only on
    /// the day they were written. Nothing here may consult the clock — proven
    /// by formatting a date from 2020 and getting the time it names.
    func testSinceTimeComesFromTheInjectedFormatterAndNotTheSystemClock() {
        let formatter = ReqResStatusMenuPlan.sinceFormatter(
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(ReqResStatusMenuPlan.sinceText(for: fixedDate(hour: 14, minute: 2), formatter: formatter), "14:02")
    }

    /// The same clock time on a different DAY must render identically. A
    /// "today"/"yesterday" branch — the shape of the original bug — would
    /// make these two differ, and only after midnight.
    func testTheSinceTimeHasNoTodayOrYesterdayBranch() {
        let formatter = ReqResStatusMenuPlan.sinceFormatter(
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(identifier: "UTC")!)
        let today = ReqResStatusMenuPlan.sinceText(for: fixedDate(hour: 9, minute: 5, day: 13), formatter: formatter)
        let otherDay = ReqResStatusMenuPlan.sinceText(for: fixedDate(hour: 9, minute: 5, day: 12), formatter: formatter)
        XCTAssertEqual(today, otherDay)
    }

    /// The formatter really is injected — a hardcoded one inside the plan
    /// would render the same string for both of these.
    func testTheInjectedTimeZoneIsHonoured() {
        let utc = ReqResStatusMenuPlan.sinceFormatter(
            locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        let berlin = ReqResStatusMenuPlan.sinceFormatter(
            locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "Europe/Berlin")!)
        let moment = fixedDate(hour: 14, minute: 2)
        XCTAssertEqual(ReqResStatusMenuPlan.sinceText(for: moment, formatter: utc), "14:02")
        XCTAssertEqual(ReqResStatusMenuPlan.sinceText(for: moment, formatter: berlin), "16:02")
    }

    /// No start time is no string — not "since (null)".
    func testNoStartTimeYieldsNoSinceText() {
        let formatter = ReqResStatusMenuPlan.sinceFormatter()
        XCTAssertNil(ReqResStatusMenuPlan.sinceText(for: nil, formatter: formatter))
    }

    /// End to end, the way the app will call it.
    func testTheStatusLineBuiltFromAFormattedDate() {
        let formatter = ReqResStatusMenuPlan.sinceFormatter(
            locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        let state = ReqResStatusState(capturing: true, capturingSince: fixedDate(hour: 14, minute: 2))
        let rows = ReqResStatusMenuPlan.rows(
            for: state,
            capturingSinceText: ReqResStatusMenuPlan.sinceText(for: state.capturingSince, formatter: formatter))
        XCTAssertEqual(row(.status, in: rows)?.title, "Capturing — since 14:02")
    }

    // MARK: - Identifiers

    /// A collision silently drops one of the colliding rows wherever these
    /// are used as a lookup key — the same failure mode the toolbar's
    /// identifiers have.
    func testIdentifiersAreUniqueAndNamespaced() {
        let identifiers = ReqResStatusMenuItem.allCases.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        for identifier in identifiers {
            XCTAssertTrue(identifier.hasPrefix("com.oloapps.ReqRes.statusMenu."))
        }
    }

    /// Identity, not prose: a row appears at most once in a menu, so a
    /// duplicate means the assembly ran a section twice.
    func testNoRowIsBuiltTwiceInOneMenu() {
        for state in everyState {
            let identifiers = ids(ReqResStatusMenuPlan.rows(for: state))
            XCTAssertEqual(Set(identifiers).count, identifiers.count, "duplicate row for \(state)")
        }
    }

    /// Every case must be reachable from some state, or it is a row the
    /// user can never see and the wiring for it is dead code.
    func testEveryDeclaredRowIsReachable() {
        var seen = Set<ReqResStatusMenuItem>()
        for state in everyState {
            seen.formUnion(ids(ReqResStatusMenuPlan.rows(for: state)))
        }
        XCTAssertEqual(seen, Set(ReqResStatusMenuItem.allCases))
    }
}
