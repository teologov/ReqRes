//
//  CaptureReattachTests.swift
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
//  Build 53 (core 95062d1): a capture that outlived the app reattaches to the
//  relaunched one — the extension redials, delivers what it kept, and reports
//  it in one status_update. The app's side of that is `CaptureReattach`, a
//  pure machine; these tests drive it through every state and every input,
//  and through these cases: a late "connected", a refusal from
//  before this launch, two copies of the app, a request during the
//  reconnect, and the one automatic restart — and through what its review
//  found: an attachment that drops at once, a late "down" after a start, a
//  request made while capture is off, a reconnection too quick for a look,
//  and notes that outlived what they were about.
//

import XCTest
@testable import Utils

final class CaptureReattachTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let grace = CaptureReattach.grace

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func facts(_ tunnel: CaptureTunnelState?, bus: Bool = true, auth: Bool = false,
                       refusal: CaptureBusRefusal? = nil, refusedAt: Date? = nil,
                       otherCopy: Bool = false, startInFlight: Bool = false) -> CaptureReattachFacts {
        CaptureReattachFacts(tunnel: tunnel, holdsBus: bus, extensionAuthenticated: auth,
                             refusal: refusal, refusalDate: refusedAt, anotherCopyRunning: otherCopy,
                             startInFlight: startInFlight)
    }

    /// A machine launched at t0 whose update reset has returned.
    private func machine(upAtLaunch: Bool = false) -> CaptureReattach {
        var machine = CaptureReattach(launchedAt: t0)
        machine.extensionSwapFinished()
        if upAtLaunch { machine.tunnelWasUpAtLaunch() }
        return machine
    }

    private let report = CaptureReattachReport(droppedRows: 12, droppedMessages: 20, proxyPort: 8036,
                                               runStartedAt: Date(timeIntervalSince1970: 1_790_000_000))

    // MARK: - Every state × every input

    /// The five states, each reached the way the app reaches it.
    private enum Start: CaseIterable {
        case notCapturing, reconnecting, attached, notReaching, otherCopyHoldsBus
    }

    /// The machine in `start`, and when it last looked.
    private func reach(_ start: Start) -> (machine: CaptureReattach, lastLook: Date) {
        var m = machine(upAtLaunch: true)
        switch start {
        case .notCapturing:
            _ = m.look(facts(.disconnected), now: at(0))
        case .reconnecting:
            _ = m.look(facts(.connected), now: at(0))
        case .attached:
            _ = m.look(facts(.connected, auth: true), now: at(0))
        case .notReaching:
            // A person asked for something during the reconnect, so the
            // grace ends in "not reaching" without a restart under way.
            _ = m.look(facts(.connected), now: at(0))
            m.userRequested(tunnel: .connected)
            _ = m.look(facts(.connected), now: at(grace))
            return (m, at(grace))
        case .otherCopyHoldsBus:
            _ = m.look(facts(.connected, bus: false, otherCopy: true), now: at(0))
        }
        return (m, at(0))
    }

    private enum Input: CaseIterable {
        case down, connecting, connectedNoExtension, connectedAfterGrace, helloAuthenticated,
             noBusOtherCopy, noBusNoCopy, reattachReported, personRequest, startSent
    }

    private struct Outcome: Equatable {
        var state: StateKind
        var restarts: Bool
        var retriesBus: Bool
        var adopts: Bool
    }

    private enum StateKind: Equatable {
        case notCapturing, reconnecting, attached, notReaching, otherCopyHoldsBus

        init(_ state: CaptureReattach.State) {
            switch state {
            case .notCapturing: self = .notCapturing
            case .reconnecting: self = .reconnecting
            case .attached: self = .attached
            case .notReaching: self = .notReaching
            case .otherCopyHoldsBus: self = .otherCopyHoldsBus
            }
        }
    }

    /// `input`, a second after the machine's last look.
    private func apply(_ input: Input, to machine: inout CaptureReattach, after lastLook: Date) -> Outcome {
        let actions: [CaptureReattach.Action]
        let later = lastLook.addingTimeInterval(1)
        switch input {
        case .down: actions = machine.look(facts(.disconnected), now: later)
        case .connecting: actions = machine.look(facts(.connecting), now: later)
        case .connectedNoExtension: actions = machine.look(facts(.connected), now: later)
        case .connectedAfterGrace:
            _ = machine.look(facts(.connected), now: later)
            actions = machine.look(facts(.connected), now: later.addingTimeInterval(grace))
        case .helloAuthenticated: actions = machine.look(facts(.connected, auth: true), now: later)
        case .noBusOtherCopy: actions = machine.look(facts(.connected, bus: false, otherCopy: true), now: later)
        case .noBusNoCopy: actions = machine.look(facts(.connected, bus: false), now: later)
        case .reattachReported: actions = machine.reattachReported(report, capturedWhileDetached: 40, tunnel: .connected, now: later)
        case .personRequest:
            // Made against the tunnel the state was reached with.
            machine.userRequested(tunnel: machine.state == .notCapturing ? .disconnected : .connected)
            actions = []
        case .startSent:
            machine.startSent(at: later)
            actions = []
        }
        return Outcome(
            state: StateKind(machine.state),
            restarts: actions.contains { if case .restartCapture = $0 { return true }; return false },
            retriesBus: actions.contains(.retryBusBind),
            adopts: actions.contains { if case .adoptRunningCapture = $0 { return true }; return false }
        )
    }

    /// 5 states × 10 inputs, each with the state it lands in and what it does.
    func testEveryStateAgainstEveryInput() {
        typealias Row = (Start, Input, StateKind, restarts: Bool, retriesBus: Bool, adopts: Bool)
        let table: [Row] = [
            // From not capturing (the tunnel seen down).
            (.notCapturing, .down, .notCapturing, false, false, false),
            (.notCapturing, .connecting, .notCapturing, false, false, false),
            (.notCapturing, .connectedNoExtension, .reconnecting, false, false, false),
            // Seen down, then up without this process's start: started
            // elsewhere, not reaching after the grace — restarted once.
            (.notCapturing, .connectedAfterGrace, .notReaching, true, false, false),
            (.notCapturing, .helloAuthenticated, .attached, false, false, false),
            (.notCapturing, .noBusOtherCopy, .otherCopyHoldsBus, false, true, false),
            (.notCapturing, .noBusNoCopy, .notReaching, false, true, false),
            (.notCapturing, .reattachReported, .notCapturing, false, false, true),
            (.notCapturing, .personRequest, .notCapturing, false, false, false),
            (.notCapturing, .startSent, .notCapturing, false, false, false),
            // From reconnecting (a capture that outlived the last app).
            (.reconnecting, .down, .notCapturing, false, false, false),
            (.reconnecting, .connecting, .notCapturing, false, false, false),
            (.reconnecting, .connectedNoExtension, .reconnecting, false, false, false),
            (.reconnecting, .connectedAfterGrace, .notReaching, true, false, false),
            (.reconnecting, .helloAuthenticated, .attached, false, false, false),
            (.reconnecting, .noBusOtherCopy, .otherCopyHoldsBus, false, true, false),
            (.reconnecting, .noBusNoCopy, .notReaching, false, true, false),
            (.reconnecting, .reattachReported, .reconnecting, false, false, true),
            (.reconnecting, .personRequest, .reconnecting, false, false, false),
            (.reconnecting, .startSent, .reconnecting, false, false, false),
            // From attached.
            (.attached, .down, .notCapturing, false, false, false),
            (.attached, .connecting, .notCapturing, false, false, false),
            (.attached, .connectedNoExtension, .reconnecting, false, false, false),
            // Its connection closed and it did not come back: restarted once.
            (.attached, .connectedAfterGrace, .notReaching, true, false, false),
            (.attached, .helloAuthenticated, .attached, false, false, false),
            (.attached, .noBusOtherCopy, .otherCopyHoldsBus, false, true, false),
            (.attached, .noBusNoCopy, .notReaching, false, true, false),
            (.attached, .reattachReported, .attached, false, false, true),
            (.attached, .personRequest, .attached, false, false, false),
            (.attached, .startSent, .attached, false, false, false),
            // From not reaching, with a person's request standing.
            (.notReaching, .down, .notCapturing, false, false, false),
            (.notReaching, .connecting, .notCapturing, false, false, false),
            (.notReaching, .connectedNoExtension, .notReaching, false, false, false),
            (.notReaching, .connectedAfterGrace, .notReaching, false, false, false),
            (.notReaching, .helloAuthenticated, .attached, false, false, false),
            (.notReaching, .noBusOtherCopy, .otherCopyHoldsBus, false, true, false),
            (.notReaching, .noBusNoCopy, .notReaching, false, true, false),
            (.notReaching, .reattachReported, .notReaching, false, false, true),
            (.notReaching, .personRequest, .notReaching, false, false, false),
            (.notReaching, .startSent, .notReaching, false, false, false),
            // From another copy holding the bus.
            (.otherCopyHoldsBus, .down, .notCapturing, false, false, false),
            (.otherCopyHoldsBus, .connecting, .notCapturing, false, false, false),
            (.otherCopyHoldsBus, .connectedNoExtension, .reconnecting, false, false, false),
            (.otherCopyHoldsBus, .connectedAfterGrace, .notReaching, true, false, false),
            (.otherCopyHoldsBus, .helloAuthenticated, .attached, false, false, false),
            // The retry is paced: a look a second after the last try is not due.
            (.otherCopyHoldsBus, .noBusOtherCopy, .otherCopyHoldsBus, false, false, false),
            (.otherCopyHoldsBus, .noBusNoCopy, .notReaching, false, false, false),
            (.otherCopyHoldsBus, .reattachReported, .otherCopyHoldsBus, false, false, true),
            (.otherCopyHoldsBus, .personRequest, .otherCopyHoldsBus, false, false, false),
            (.otherCopyHoldsBus, .startSent, .otherCopyHoldsBus, false, false, false),
        ]
        XCTAssertEqual(table.count, Start.allCases.count * Input.allCases.count)
        var covered = Set<String>()
        for (start, input, expected, restarts, retries, adopts) in table {
            var (machine, lastLook) = reach(start)
            let got = apply(input, to: &machine, after: lastLook)
            XCTAssertEqual(got, Outcome(state: expected, restarts: restarts, retriesBus: retries, adopts: adopts),
                           "\(start) + \(input)")
            covered.insert("\(start)/\(input)")
        }
        XCTAssertEqual(covered.count, table.count, "a pair listed twice")
    }

    /// Each state is reached the way the table says it is.
    func testTheStatesAreReachedAsDescribed() {
        XCTAssertEqual(reach(.notCapturing).machine.state, .notCapturing)
        XCTAssertEqual(reach(.reconnecting).machine.state, .reconnecting(since: t0))
        XCTAssertEqual(reach(.attached).machine.state, .attached(capturedWhileClosed: 0, droppedRows: 0))
        XCTAssertEqual(reach(.notReaching).machine.state, .notReaching(.appRelaunched))
        XCTAssertEqual(reach(.otherCopyHoldsBus).machine.state, .otherCopyHoldsBus)
    }

    // MARK: - The relaunch, end to end

    /// The case: the app relaunched while capture ran, the extension
    /// redials, delivers what it kept, and the table fills — no restart.
    func testARelaunchReattachesWithoutARestart() throws {
        var m = machine(upAtLaunch: true)
        XCTAssertEqual(m.look(facts(nil), now: at(0)), [], "nothing is decided before the status is known")
        XCTAssertEqual(m.state, .notCapturing)
        XCTAssertEqual(m.look(facts(.connected), now: at(0.1)), [])
        XCTAssertEqual(m.state, .reconnecting(since: at(0.1)))
        XCTAssertEqual(m.delivery, .reconnecting)
        XCTAssertEqual(m.look(facts(.connected), now: at(2)), [])
        // The hello: attached.
        XCTAssertEqual(m.look(facts(.connected, auth: true), now: at(2.2)), [])
        XCTAssertEqual(m.delivery, .receiving)
        // The status_update after the backlog: 40 requests, 12 not kept.
        XCTAssertEqual(m.reattachReported(report, capturedWhileDetached: 40, tunnel: .connected, now: at(2.3)),
                       [.adoptRunningCapture(proxyPort: 8036, startedAt: report.runStartedAt)])
        XCTAssertEqual(m.state, .attached(capturedWhileClosed: 40, droppedRows: 12))
        XCTAssertEqual(m.notice, .reattached(capturedWhileDetached: 40, droppedRows: 12, appWasClosed: true))
        XCTAssertEqual(try XCTUnwrap(m.notice).text(busPort: 50001),
                       "40 requests were captured while ReqRes was closed; 12 earlier ones were not kept.")
        // Later looks keep the counts.
        XCTAssertEqual(m.look(facts(.connected, auth: true), now: at(30)), [])
        XCTAssertEqual(m.state, .attached(capturedWhileClosed: 40, droppedRows: 12))
    }

    /// A reattach that carried nothing and lost nothing has nothing to say,
    /// and still adopts the running capture's port and start.
    func testAnEmptyReattachSaysNothing() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected, auth: true), now: at(0))
        let empty = CaptureReattachReport(proxyPort: 8034)
        XCTAssertEqual(m.reattachReported(empty, capturedWhileDetached: 0, tunnel: .connected, now: at(0.1)),
                       [.adoptRunningCapture(proxyPort: 8034, startedAt: nil)])
        XCTAssertNil(m.notice)
    }

    // MARK: - A late "connected"

    /// The redial can win the race with the launch read: the reattach is
    /// reported before the app has heard the tunnel's status at all. It waits
    /// for the status, and is honoured once the tunnel reads connected.
    func testAReattachBeforeTheStatusIsKnownWaitsForALateConnected() {
        var m = machine(upAtLaunch: true)
        XCTAssertEqual(m.reattachReported(report, capturedWhileDetached: 5, tunnel: nil, now: at(0)), [])
        XCTAssertNil(m.notice, "not honoured before the tunnel reads connected")
        XCTAssertEqual(m.look(facts(nil, auth: true), now: at(0)), [], "still unknown: still waiting")
        XCTAssertNil(m.notice)
        XCTAssertEqual(m.look(facts(.connected, auth: true), now: at(0.5)),
                       [.adoptRunningCapture(proxyPort: 8036, startedAt: report.runStartedAt)])
        XCTAssertEqual(m.state, .attached(capturedWhileClosed: 5, droppedRows: 12))
        XCTAssertEqual(m.notice, .reattached(capturedWhileDetached: 5, droppedRows: 12, appWasClosed: true))
    }

    /// While the tunnel is still moving the report waits too; a tunnel that
    /// turns out down (or stopping) drops it — honoured only while connected.
    func testAReattachIsHonouredOnlyWhileConnected() {
        for moving in [CaptureTunnelState.connecting, .reasserting] {
            var m = machine(upAtLaunch: true)
            XCTAssertEqual(m.reattachReported(report, capturedWhileDetached: 5, tunnel: moving, now: at(0)), [], "\(moving)")
            XCTAssertNil(m.notice)
            XCTAssertEqual(m.look(facts(.connected, auth: true), now: at(1)).count, 1, "\(moving) then connected")
            XCTAssertNotNil(m.notice)
        }
        for down in [CaptureTunnelState.disconnected, .invalid, .disconnecting] {
            var m = machine(upAtLaunch: true)
            XCTAssertEqual(m.reattachReported(report, capturedWhileDetached: 5, tunnel: down, now: at(0)), [], "\(down)")
            XCTAssertEqual(m.look(facts(.connected, auth: true), now: at(1)), [], "\(down): dropped")
            XCTAssertNil(m.notice)
        }
        // Unknown, then seen down: dropped, not honoured by a later run.
        var m = machine(upAtLaunch: true)
        _ = m.reattachReported(report, capturedWhileDetached: 5, tunnel: nil, now: at(0))
        _ = m.look(facts(.disconnected), now: at(1))
        XCTAssertEqual(m.look(facts(.connected, auth: true), now: at(2)), [])
        XCTAssertNil(m.notice)
        // Unknown, then stopping: dropped.
        var stopping = machine(upAtLaunch: true)
        _ = stopping.reattachReported(report, capturedWhileDetached: 5, tunnel: nil, now: at(0))
        _ = stopping.look(facts(.disconnecting), now: at(1))
        XCTAssertEqual(stopping.look(facts(.connected, auth: true), now: at(2)), [])
        XCTAssertNil(stopping.notice)
    }

    // MARK: - A refusal from before this launch

    /// The refusal only ever picks words — and one dated before the run it
    /// would explain is not that run's: a capture that predates this launch
    /// is "relaunched", not "started outside ReqRes", whatever was refused
    /// before.
    func testARefusalFromBeforeThisLaunchIsNotTheReason() {
        var m = machine(upAtLaunch: true)
        let stale = t0.addingTimeInterval(-10)
        _ = m.look(facts(.connected, refusal: .noCredential, refusedAt: stale), now: at(0))
        XCTAssertEqual(m.look(facts(.connected, refusal: .noCredential, refusedAt: stale), now: at(grace)),
                       [.restartCapture(.appRelaunched)])
        XCTAssertEqual(m.state, .notReaching(.appRelaunched))

        var fresh = machine(upAtLaunch: true)
        _ = fresh.look(facts(.connected, refusal: .noCredential, refusedAt: at(1)), now: at(0))
        XCTAssertEqual(fresh.look(facts(.connected, refusal: .noCredential, refusedAt: at(1)), now: at(grace)),
                       [.restartCapture(.startedOutsideReqRes)])
    }

    /// A refusal from before the tunnel was last seen down belongs to the
    /// run that ended; one from while an extension was attached is not about
    /// its loss. Both with reasons that would change the words — `noHello`
    /// reads as `.connectionLost` either way, so it pinned nothing (review).
    func testARefusalFromAnEarlierRunOrFromWhileAttachedIsStale() {
        var m = machine()
        _ = m.look(facts(.disconnected), now: at(10))
        _ = m.look(facts(.connected, refusal: .badProof, refusedAt: at(5)), now: at(11))
        _ = m.look(facts(.connected, refusal: .badProof, refusedAt: at(5)), now: at(11 + grace))
        XCTAssertEqual(m.state, .notReaching(.unexplained), "refused at +5, the run seen down at +10")

        // Any local process can be refused while the extension is attached;
        // the extension's later loss is not "started outside ReqRes".
        for refusal in [CaptureBusRefusal.noCredential, .badProof] {
            var lost = machine(upAtLaunch: true)
            _ = lost.look(facts(.connected, auth: true), now: at(0))
            _ = lost.look(facts(.connected, refusal: refusal, refusedAt: at(3)), now: at(5))
            let actions = lost.look(facts(.connected, refusal: refusal, refusedAt: at(3)), now: at(5 + grace))
            XCTAssertEqual(lost.state, .notReaching(.connectionLost), "\(refusal), refused at +3 while attached")
            XCTAssertEqual(actions, [.restartCapture(.connectionLost)], "\(refusal)")
        }
        // …while one after the loss is about it.
        var after = machine(upAtLaunch: true)
        _ = after.look(facts(.connected, auth: true), now: at(0))
        _ = after.look(facts(.connected), now: at(5))
        _ = after.look(facts(.connected, refusal: .noCredential, refusedAt: at(6)), now: at(7))
        _ = after.look(facts(.connected, refusal: .noCredential, refusedAt: at(6)), now: at(5 + grace))
        XCTAssertEqual(after.state, .notReaching(.startedOutsideReqRes))
    }

    /// A refusal with no date reads as current.
    func testAnUndatedRefusalCounts() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected, refusal: .unboundHello), now: at(0))
        _ = m.look(facts(.connected, refusal: .unboundHello), now: at(grace))
        XCTAssertEqual(m.state, .notReaching(.earlierExtension))
    }

    // MARK: - Two copies of the app

    /// The copy without the bus never restarts, however long it looks; it
    /// tries the bus again every 5 s, and when the other copy is gone it is
    /// the one the extension finds.
    func testTwoCopiesNeverRestartAndTheSecondTakesOverWhenTheFirstIsGone() {
        var m = machine(upAtLaunch: true)
        var retries: [TimeInterval] = []
        for second in 0...20 {
            let actions = m.look(facts(.connected, bus: false, otherCopy: true), now: at(TimeInterval(second)))
            XCTAssertFalse(actions.contains { if case .restartCapture = $0 { return true }; return false }, "\(second) s")
            if actions.contains(.retryBusBind) { retries.append(TimeInterval(second)) }
            XCTAssertEqual(m.state, .otherCopyHoldsBus)
            XCTAssertEqual(m.delivery, .anotherCopy)
        }
        XCTAssertEqual(retries, [0, 5, 10, 15, 20], "every \(CaptureReattach.busRetryInterval) s")
        // The other copy quit or crashed and the retry got the bus.
        XCTAssertEqual(m.look(facts(.connected), now: at(21)), [])
        XCTAssertEqual(m.state, .reconnecting(since: at(21)))
        XCTAssertEqual(m.look(facts(.connected, auth: true), now: at(22)), [])
        XCTAssertEqual(m.delivery, .receiving)
    }

    /// Without the bus and no other copy: nothing can arrive, said at once,
    /// with no grace — and no restart from here either.
    func testNoBusIsDecidedAtOnceAndNeverRestarted() {
        var m = machine(upAtLaunch: true)
        XCTAssertEqual(m.look(facts(.connected, bus: false), now: at(0)), [.retryBusBind])
        XCTAssertEqual(m.state, .notReaching(.notListening))
        XCTAssertEqual(m.look(facts(.connected, bus: false), now: at(60)), [.retryBusBind])
        XCTAssertEqual(m.automaticRestart, .available)
    }

    /// Authentication is per bus: without one it means nothing.
    func testAnAuthenticatedExtensionWithoutTheBusIsNotThisCopys() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected, bus: false, auth: true, otherCopy: true), now: at(0))
        XCTAssertEqual(m.state, .otherCopyHoldsBus)
    }

    // MARK: - A request during the reconnect

    /// A person or an agent asked for a start or a stop while it reconnected:
    /// what they asked for stands, and ReqRes does not restart capture by
    /// itself in this stretch — F11's notice and Restart Capture remain.
    func testARequestDuringTheReconnectStandsTheRestartDown() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        m.userRequested(tunnel: .connected)
        XCTAssertEqual(m.look(facts(.connected), now: at(grace)), [])
        XCTAssertEqual(m.state, .notReaching(.appRelaunched))
        XCTAssertEqual(m.delivery, .notReceiving(.appRelaunched))
        XCTAssertTrue(m.delivery.offersRestart, "the person's Restart Capture is still offered")
        XCTAssertFalse(m.mayRestartAutomatically)
    }

    /// An attachment that lasted ends the stretch: a request made before it
    /// no longer stands a later loss down.
    func testAnAttachmentEndsWhatWasAskedForBefore() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        m.userRequested(tunnel: .connected)
        _ = m.look(facts(.connected, auth: true), now: at(1))
        XCTAssertTrue(m.requestedThisStretch, "not yet: an attachment has to last")
        _ = m.look(facts(.connected, auth: true), now: at(1 + CaptureReattach.stableAttachment))
        XCTAssertFalse(m.requestedThisStretch)
        _ = m.look(facts(.connected), now: at(10))
        XCTAssertEqual(m.look(facts(.connected), now: at(10 + grace)), [.restartCapture(.connectionLost)])
    }

    // MARK: - The one automatic restart

    /// Once per stretch: the restart's own stop and start do not end it, and
    /// a restarted run that does not attach is left to F11's notice.
    func testOnlyOneAutomaticRestartPerStretch() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        XCTAssertEqual(m.look(facts(.connected), now: at(grace)), [.restartCapture(.appRelaunched)])
        XCTAssertEqual(m.automaticRestart, .inFlight(.appRelaunched))
        XCTAssertEqual(m.look(facts(.connected), now: at(grace + 1)), [], "asked for once")
        // The restart's stop.
        XCTAssertEqual(m.look(facts(.disconnecting), now: at(8)), [])
        XCTAssertEqual(m.look(facts(.disconnected), now: at(9)), [])
        XCTAssertEqual(m.automaticRestart, .inFlight(.appRelaunched), "its own stop does not end the stretch")
        // Its start.
        m.startSent(at: at(9.1))
        m.automaticRestartFinished(.startSent)
        XCTAssertEqual(m.automaticRestart, .used)
        XCTAssertNil(m.notice, "said once the restarted capture is up, not when its start is sent")
        XCTAssertEqual(m.restartTriedThisStretch, .restarted)
        _ = m.look(facts(.connecting), now: at(9.2))
        _ = m.look(facts(.connected), now: at(10))
        XCTAssertEqual(m.notice, .restartedAutomatically(.appRelaunched))
        // An earlier build's extension, still running: refused again.
        XCTAssertEqual(m.look(facts(.connected, refusal: .unboundHello, refusedAt: at(10.1)), now: at(10 + grace)), [])
        XCTAssertEqual(m.state, .notReaching(.earlierExtension))
        XCTAssertEqual(m.delivery, .notReceiving(.earlierExtension), "F11's notice and Restart Capture remain")
        XCTAssertEqual(m.look(facts(.connected, refusal: .unboundHello, refusedAt: at(10.1)), now: at(60)), [])
    }

    /// The restart helped: an attachment that lasted ends the stretch, and a
    /// later loss may be restarted again.
    func testARestartThatHelpedFreesTheNextOne() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        _ = m.look(facts(.connected), now: at(grace))
        _ = m.look(facts(.disconnected), now: at(7))
        m.startSent(at: at(7.5))
        m.automaticRestartFinished(.startSent)
        _ = m.look(facts(.connected, auth: true), now: at(8))
        XCTAssertEqual(m.automaticRestart, .used, "an attachment has to last before it frees the next restart")
        _ = m.look(facts(.connected, auth: true), now: at(8 + CaptureReattach.stableAttachment))
        XCTAssertEqual(m.automaticRestart, .available)
        XCTAssertNil(m.restartTriedThisStretch, "the stretch it was about is over")
        XCTAssertEqual(m.notice, .restartedAutomatically(.appRelaunched), "the note stays until dismissed")
        _ = m.look(facts(.connected), now: at(100))
        XCTAssertEqual(m.look(facts(.connected), now: at(100 + grace)), [.restartCapture(.connectionLost)])
    }

    /// How the restart ended is said only when it is news: a start sent, or a
    /// failure. A stand-down (someone asked for something) or nothing left to
    /// restart says nothing.
    func testHowTheRestartEndedIsSaidOnlyWhenItIsNews() {
        let outcomes: [(CaptureRestartOutcome, CaptureReattachNotice?)] = [
            // A start sent is said once the capture is up (below).
            (.startSent, nil),
            (.failed(.didNotStop), .automaticRestartFailed(.didNotStop)),
            (.failed(.startRefused("configuration disabled")), .automaticRestartFailed(.startRefused("configuration disabled"))),
            (.stoodDown, nil),
            (.nothingToRestart, nil),
            (.notSent, nil),
            (.noLongerNeeded, nil),
        ]
        for (outcome, expected) in outcomes {
            var m = machine(upAtLaunch: true)
            _ = m.look(facts(.connected), now: at(0))
            _ = m.look(facts(.connected), now: at(grace))
            m.automaticRestartFinished(outcome)
            XCTAssertEqual(m.notice, expected, "\(outcome)")
            XCTAssertEqual(m.automaticRestart, .used, "\(outcome)")
        }
        var sent = machine(upAtLaunch: true)
        _ = sent.look(facts(.connected), now: at(0))
        _ = sent.look(facts(.connected), now: at(grace))
        sent.startSent(at: at(7))
        sent.automaticRestartFinished(.startSent)
        _ = sent.look(facts(.connected), now: at(8))
        XCTAssertEqual(sent.notice, .restartedAutomatically(.appRelaunched))
        // A finish with no restart under way changes nothing.
        var idle = machine()
        idle.automaticRestartFinished(.startSent)
        XCTAssertNil(idle.notice)
        XCTAssertEqual(idle.automaticRestart, .available)
    }

    /// A run this process started that never attached is not restarted: a
    /// restart would only repeat it (an earlier build's extension refuses the
    /// same way).
    func testAStartFromHereIsNeverRestartedBeforeItAttached() {
        var m = machine()
        _ = m.look(facts(.disconnected), now: at(0))
        m.startSent(at: at(1))
        _ = m.look(facts(.connecting), now: at(1.1))
        _ = m.look(facts(.connected), now: at(2))
        XCTAssertEqual(m.delivery, .waiting, "the first moments of a start, not a reconnection")
        XCTAssertEqual(m.look(facts(.connected, refusal: .unboundHello, refusedAt: at(1.5)), now: at(2 + grace)), [])
        XCTAssertEqual(m.state, .notReaching(.earlierExtension))
    }

    /// …but once it has attached, a lost connection is restarted like any.
    func testAStartFromHereThatAttachedAndLostItIsRestarted() {
        var m = machine()
        m.startSent(at: at(0))
        _ = m.look(facts(.connected, auth: true), now: at(1))
        _ = m.look(facts(.connected), now: at(50))
        XCTAssertEqual(m.delivery, .reconnecting)
        XCTAssertEqual(m.look(facts(.connected), now: at(50 + grace)), [.restartCapture(.connectionLost)])
    }

    /// Never before the update's extension swap has returned: the old
    /// extension may be being replaced. Once it has, the next look restarts.
    func testNoRestartBeforeTheExtensionSwapReturned() {
        var m = CaptureReattach(launchedAt: t0)
        m.tunnelWasUpAtLaunch()
        _ = m.look(facts(.connected), now: at(0))
        XCTAssertEqual(m.look(facts(.connected), now: at(grace)), [])
        XCTAssertEqual(m.look(facts(.connected), now: at(30)), [])
        XCTAssertEqual(m.state, .notReaching(.appRelaunched))
        m.extensionSwapFinished()
        XCTAssertEqual(m.look(facts(.connected), now: at(31)), [.restartCapture(.appRelaunched)])
    }

    /// The decision never reads the refusal: with any reason, or none, the
    /// same stretch is restarted the same way — only the words differ.
    func testTheRestartNeverDependsOnTheRefusal() {
        for refusal in [nil] + CaptureBusRefusal.allCases.map(Optional.some) {
            var m = machine(upAtLaunch: true)
            _ = m.look(facts(.connected, refusal: refusal, refusedAt: at(1)), now: at(0))
            let actions = m.look(facts(.connected, refusal: refusal, refusedAt: at(1)), now: at(grace))
            XCTAssertEqual(actions.count, 1, "\(String(describing: refusal))")
            guard case .restartCapture(let problem)? = actions.first else {
                return XCTFail("\(String(describing: refusal)): \(actions)")
            }
            XCTAssertEqual(problem, CaptureReattach.problem(refusal: refusal, origin: .predatesProcess, attachedEarlierThisRun: false))
        }
    }

    // MARK: - The grace and the clock

    func testTheGraceIsSixSecondsAndTheRetryFive() {
        XCTAssertEqual(CaptureReattach.grace, 6, "3x the extension's 2 s redial cap")
        XCTAssertEqual(CaptureReattach.busRetryInterval, 5)
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        _ = m.look(facts(.connected), now: at(5.99))
        XCTAssertEqual(m.state, .reconnecting(since: t0))
        _ = m.look(facts(.connected), now: at(6))
        XCTAssertEqual(m.state, .notReaching(.appRelaunched))
    }

    /// Only a connected tunnel owes rows; starting, stopping and reasserting
    /// reset the clock.
    func testOnlyAConnectedTunnelIsTimed() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        _ = m.look(facts(.reasserting), now: at(4))
        XCTAssertEqual(m.state, .notCapturing)
        XCTAssertNil(m.unattachedSince)
        _ = m.look(facts(.connected), now: at(8))
        XCTAssertEqual(m.state, .reconnecting(since: at(8)), "a new grace")
    }

    // MARK: - What the surfaces are told

    /// "Reconnecting" is said for a capture this process did not just start;
    /// a start of its own in its first moments is "waiting", as F11 had it.
    func testReconnectingIsSaidOnlyForACaptureThisAppDidNotJustStart() {
        var relaunched = machine(upAtLaunch: true)
        _ = relaunched.look(facts(.connected), now: at(0))
        XCTAssertEqual(relaunched.delivery, .reconnecting)

        var elsewhere = machine()
        _ = elsewhere.look(facts(.disconnected), now: at(0))
        _ = elsewhere.look(facts(.connected), now: at(1))
        XCTAssertEqual(elsewhere.origin, .startedElsewhere)
        XCTAssertEqual(elsewhere.delivery, .reconnecting)

        var here = machine()
        here.startSent(at: at(0))
        _ = here.look(facts(.connected), now: at(1))
        XCTAssertEqual(here.delivery, .waiting)
    }

    /// The display verdict for every state.
    func testTheVerdictForEveryState() {
        XCTAssertEqual(reach(.notCapturing).machine.delivery, .notCapturing)
        XCTAssertEqual(reach(.reconnecting).machine.delivery, .reconnecting)
        XCTAssertEqual(reach(.attached).machine.delivery, .receiving)
        XCTAssertEqual(reach(.notReaching).machine.delivery, .notReceiving(.appRelaunched))
        XCTAssertEqual(reach(.otherCopyHoldsBus).machine.delivery, .anotherCopy)
    }

    /// The wording of a reattach follows where the run was while no app
    /// received it: the app was closed, or this process watched the
    /// connection close.
    func testTheReattachSaysWhetherTheAppWasClosed() {
        var m = machine()
        m.startSent(at: at(0))
        _ = m.look(facts(.connected, auth: true), now: at(1))
        _ = m.look(facts(.connected), now: at(20))
        _ = m.look(facts(.connected, auth: true), now: at(21))
        _ = m.reattachReported(report, capturedWhileDetached: 1, tunnel: .connected, now: at(21.1))
        XCTAssertEqual(m.notice, .reattached(capturedWhileDetached: 1, droppedRows: 12, appWasClosed: false))
    }

    /// A start someone else asked for makes the notes about the last run
    /// stale; the automatic restart's own start keeps its note's place.
    func testANewStartClearsTheNoteAndDismissClearsIt() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected, auth: true), now: at(0))
        _ = m.reattachReported(report, capturedWhileDetached: 3, tunnel: .connected, now: at(0.1))
        XCTAssertNotNil(m.notice)
        m.dismissNotice()
        XCTAssertNil(m.notice)
        _ = m.reattachReported(report, capturedWhileDetached: 3, tunnel: .connected, now: at(0.2))
        XCTAssertNotNil(m.notice)
        m.startSent(at: at(6))
        XCTAssertNil(m.notice)
    }

    // MARK: - Why

    /// `unboundHello` is a fact; a refused proof is the next best evidence;
    /// then a lost connection, the relaunch, and what is left.
    func testTheExplanationForEveryRefusalOriginAndHistory() {
        let origins: [CaptureRunOrigin] = [.none, .predatesProcess, .startedHere, .startedElsewhere]
        for refusal in [nil] + CaptureBusRefusal.allCases.map(Optional.some) {
            for origin in origins {
                for attached in [false, true] {
                    let got = CaptureReattach.problem(refusal: refusal, origin: origin, attachedEarlierThisRun: attached)
                    let expected: CaptureDeliveryProblem
                    switch refusal {
                    case .unboundHello?: expected = .earlierExtension
                    case .noCredential?: expected = .startedOutsideReqRes
                    case .badProof?: expected = .otherInstall
                    default:
                        if attached { expected = .connectionLost }
                        else if origin == .predatesProcess { expected = .appRelaunched }
                        else { expected = refusal == nil ? .unexplained : .silentConnection }
                    }
                    XCTAssertEqual(got, expected, "\(String(describing: refusal)) \(origin) attached=\(attached)")
                }
            }
        }
    }

    /// F11 named an earlier build from `noHello`, which the core now
    /// documents as forgeable and not proof of an old extension: only
    /// `unboundHello` names a version.
    func testOnlyAnUnboundHelloNamesAnEarlierBuild() {
        for refusal in CaptureBusRefusal.allCases {
            let problem = CaptureReattach.problem(refusal: refusal, origin: .startedElsewhere, attachedEarlierThisRun: false)
            XCTAssertEqual(problem == .earlierExtension, refusal == .unboundHello, "\(refusal)")
        }
    }

    // MARK: - The backlog's tally

    func testTheTallyCountsDistinctRequestsBetweenTheHelloAndTheStatusUpdate() {
        var tally = CaptureReattachTally()
        tally.row("before")
        XCTAssertEqual(tally.statusUpdate(), 0, "no window open: rows before the hello are not a backlog")
        tally.extensionProvedItself()
        tally.row("a")
        tally.row("b")
        tally.row("a") // a live row's start, then its final row
        XCTAssertTrue(tally.isOpen)
        XCTAssertEqual(tally.statusUpdate(), 2)
        XCTAssertFalse(tally.isOpen)
        tally.row("c")
        XCTAssertEqual(tally.statusUpdate(), 0, "closed by the status_update")
    }

    func testANewHelloStartsANewWindowAndTheWindowIsBounded() {
        var tally = CaptureReattachTally()
        tally.extensionProvedItself()
        tally.row("old")
        tally.extensionProvedItself()
        tally.row("new")
        XCTAssertEqual(tally.statusUpdate(), 1)
        tally.extensionProvedItself()
        for index in 0..<(CaptureReattachTally.maxRows + 100) { tally.row("\(index)") }
        XCTAssertEqual(tally.statusUpdate(), CaptureReattachTally.maxRows)
    }

    // MARK: - Reading the report

    private func frame(_ payload: String, action: String = "status_update") -> Data {
        Data(#"{"action":"\#(action)","payload":\#(payload)}"#.utf8)
    }

    /// The core's own frame, as `ClientBusMessage<BusReattachStatus>` writes
    /// it (pretty-printed, slashes unescaped).
    func testTheCoresFrameReads() throws {
        let data = frame("""
        {
          "status" : "reattached",
          "reattached" : true,
          "droppedRows" : 12,
          "droppedMessages" : 20,
          "proxyPort" : 8036,
          "runStartedAt" : 1790000000.5
        }
        """)
        let read = try XCTUnwrap(CaptureReattachReport.from(statusUpdateFrame: data))
        XCTAssertEqual(read, CaptureReattachReport(droppedRows: 12, droppedMessages: 20, proxyPort: 8036,
                                                    runStartedAt: Date(timeIntervalSince1970: 1_790_000_000.5)))
    }

    /// Lenient with every key but the marker: a key left out reads as its
    /// default instead of costing the report.
    func testMissingKeysReadAsTheirDefaults() throws {
        let minimal = try XCTUnwrap(CaptureReattachReport.from(statusUpdateFrame: frame(#"{"status":"reattached"}"#)))
        XCTAssertEqual(minimal, CaptureReattachReport())
        let flagOnly = try XCTUnwrap(CaptureReattachReport.from(statusUpdateFrame: frame(#"{"reattached":true,"droppedRows":3}"#)))
        XCTAssertEqual(flagOnly.droppedRows, 3)
        let noPort = try XCTUnwrap(CaptureReattachReport.from(statusUpdateFrame: frame(#"{"status":"reattached","reattached":true,"droppedRows":1,"droppedMessages":2}"#)))
        XCTAssertNil(noPort.proxyPort)
        XCTAssertNil(noPort.runStartedAt)
        XCTAssertEqual(noPort.droppedMessages, 2)
    }

    /// Values that are not what they say read as their defaults.
    func testWrongValuesReadAsDefaults() throws {
        let odd = try XCTUnwrap(CaptureReattachReport.from(statusUpdateFrame: frame(
            #"{"status":"reattached","droppedRows":"many","droppedMessages":-4,"proxyPort":70000,"runStartedAt":0}"#)))
        XCTAssertEqual(odd, CaptureReattachReport())
        let fractionalPort = try XCTUnwrap(CaptureReattachReport.from(statusUpdateFrame: frame(#"{"status":"reattached","proxyPort":8034.5}"#)))
        XCTAssertNil(fractionalPort.proxyPort)
        let booleanCount = try XCTUnwrap(CaptureReattachReport.from(statusUpdateFrame: frame(#"{"status":"reattached","droppedRows":true}"#)))
        XCTAssertEqual(booleanCount.droppedRows, 0, "a boolean is not a count")
    }

    /// Anything that is not a reattach is nil: a start's status_update, an
    /// explicit "not reattached", another action, junk.
    func testOnlyAReattachIsRead() {
        XCTAssertNil(CaptureReattachReport.from(statusUpdateFrame: frame(#"{"status":"connected"}"#)))
        XCTAssertNil(CaptureReattachReport.from(statusUpdateFrame: frame(#"{"status":"reattached","reattached":false}"#)))
        XCTAssertNil(CaptureReattachReport.from(statusUpdateFrame: frame(#"{"reattached":false}"#)))
        XCTAssertNil(CaptureReattachReport.from(statusUpdateFrame: frame(#"{}"#)))
        XCTAssertNil(CaptureReattachReport.from(statusUpdateFrame: frame(#"{"status":"reattached"}"#, action: "send_session")))
        XCTAssertNil(CaptureReattachReport.from(statusUpdateFrame: Data("not json".utf8)))
        XCTAssertNil(CaptureReattachReport.from(statusUpdateFrame: Data(#"{"action":"status_update"}"#.utf8)))
        XCTAssertNil(CaptureReattachReport.from(statusUpdateFrame: Data(#"["status_update"]"#.utf8)))
    }

    /// The names are the core's (`BusReattachStatus.statusValue`,
    /// `ClientBusAction.statusUpdate`); the app checks them against the
    /// embedded core at launch (`AppController.reattachReaderDrift`).
    func testTheNamesAreTheCores() {
        XCTAssertEqual(CaptureReattachReport.statusValue, "reattached")
        XCTAssertEqual(CaptureReattachReport.action, "status_update")
    }

    // MARK: - Review of build 53: an attachment that drops at once

    /// The restarted capture's extension attaches, the app pushes its state,
    /// and the extension drops the connection at once (a push it cannot read
    /// — a Map Local file past its frame limit — the core counts that like a
    /// refusal and slows its redial). Re-arming on that attachment restarted
    /// capture every ~8 s for as long as it went on; it is the same stretch,
    /// and ReqRes restarts once.
    func testAnAttachmentThatDropsAtOnceDoesNotFreeASecondRestart() {
        var m = machine(upAtLaunch: true)
        var now: TimeInterval = 0
        var restarts = 0
        func isRestart(_ action: CaptureReattach.Action) -> Bool {
            if case .restartCapture = action { return true }
            return false
        }
        _ = m.look(facts(.connected), now: at(now))
        for _ in 0..<10 {
            now += grace
            if m.look(facts(.connected), now: at(now)).contains(where: isRestart) {
                restarts += 1
                now += 0.5; _ = m.look(facts(.disconnected), now: at(now))
                now += 0.1; m.startSent(at: at(now)); m.automaticRestartFinished(.startSent)
                now += 0.1; _ = m.look(facts(.connecting), now: at(now))
            }
            // Up, the extension proves itself, the push goes out, it drops.
            now += 0.3; _ = m.look(facts(.connected), now: at(now))
            m.extensionSaidHello(at: at(now + 0.1))
            now += 0.5; _ = m.look(facts(.connected, auth: true), now: at(now))
            now += 1; _ = m.look(facts(.connected), now: at(now))
        }
        now += grace
        XCTAssertFalse(m.look(facts(.connected), now: at(now)).contains(where: isRestart))
        XCTAssertEqual(restarts, 1, "one automatic restart per stretch")
        XCTAssertEqual(m.automaticRestart, .used)
        XCTAssertEqual(m.delivery, .notReceiving(.connectionLost), "F11's notice and Restart Capture are what remains")
    }

    /// The table the review asked for: a restart, an attachment that drops
    /// within a second, the grace — no second restart; an attachment that
    /// lasts, then a loss — a restart again.
    func testOnlyALastingAttachmentEndsTheStretch() {
        func restartedThenAttached(for seconds: TimeInterval) -> [CaptureReattach.Action] {
            var m = machine(upAtLaunch: true)
            _ = m.look(facts(.connected), now: at(0))
            _ = m.look(facts(.connected), now: at(grace))
            _ = m.look(facts(.disconnected), now: at(7))
            m.startSent(at: at(7.1))
            m.automaticRestartFinished(.startSent)
            _ = m.look(facts(.connected), now: at(8))
            m.extensionSaidHello(at: at(8.2))
            var t = 8.2
            while t <= 8.2 + seconds {
                _ = m.look(facts(.connected, auth: true), now: at(t))
                t += 1
            }
            _ = m.look(facts(.connected), now: at(t))
            return m.look(facts(.connected), now: at(t + grace))
        }
        XCTAssertEqual(restartedThenAttached(for: 0.5), [], "dropped within a second: the same stretch")
        XCTAssertEqual(restartedThenAttached(for: 3), [], "under the core's 4 s")
        XCTAssertEqual(restartedThenAttached(for: 10), [.restartCapture(.connectionLost)], "stayed: a new stretch")
        XCTAssertEqual(CaptureReattach.stableAttachment, 4, "the core's BusTimings.stableAttachment")
    }

    /// An attachment is measured from its own hello: a reconnection between
    /// two looks starts the clock again, though every look saw "attached".
    func testALastingAttachmentIsMeasuredFromItsLatestHello() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        m.userRequested(tunnel: .connected)
        m.extensionSaidHello(at: at(1))
        _ = m.look(facts(.connected, auth: true), now: at(1))
        _ = m.look(facts(.connected, auth: true), now: at(3))
        m.extensionSaidHello(at: at(3.5)) // dropped and back between two looks
        _ = m.look(facts(.connected, auth: true), now: at(5))
        XCTAssertTrue(m.requestedThisStretch, "1.5 s since the latest hello")
        _ = m.look(facts(.connected, auth: true), now: at(7.5))
        XCTAssertFalse(m.requestedThisStretch, "4 s since it")
    }

    // MARK: - Review of build 53: a late "down" after a start

    /// The automatic restart's start is sent; the stop's "down" is read only
    /// after it (the display already said connecting). That is not the end
    /// of the restarted run: no second restart of a run that cannot attach.
    func testALateDownAfterTheRestartsStartDoesNotEndItsRun() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        _ = m.look(facts(.connected), now: at(grace))
        _ = m.look(facts(.disconnecting), now: at(6.5))
        _ = m.look(facts(.disconnected), now: at(7))
        m.startSent(at: at(7.1))
        m.automaticRestartFinished(.startSent)
        _ = m.look(facts(.connecting), now: at(7.2))
        XCTAssertEqual(m.look(facts(.disconnected, startInFlight: true), now: at(7.3)), [], "the stop's, read late")
        XCTAssertEqual(m.origin, .startedHere)
        XCTAssertEqual(m.automaticRestart, .used)
        XCTAssertNil(m.notice, "and not \"did not start\": the start is still on its way")
        _ = m.look(facts(.connecting), now: at(7.4))
        _ = m.look(facts(.connected, refusal: .unboundHello, refusedAt: at(7.6)), now: at(8))
        XCTAssertEqual(m.look(facts(.connected, refusal: .unboundHello, refusedAt: at(7.6)), now: at(14.5)), [],
                       "an earlier build's extension refused again: F11's notice, not a second restart")
        XCTAssertEqual(m.delivery, .notReceiving(.earlierExtension))
    }

    /// A person's Stop and then Start; the stop's "down" read after the start
    /// was sent. ReqRes must not restart, on its own, the run that person
    /// just started.
    func testALateDownAfterAPersonsStartDoesNotEndTheirRun() {
        var m = machine()
        m.startSent(at: at(0))
        _ = m.look(facts(.connected, auth: true), now: at(1))
        m.userRequested(tunnel: .connected) // Stop
        _ = m.look(facts(.disconnected), now: at(10))
        m.userRequested(tunnel: .disconnected) // Start
        m.startSent(at: at(11))
        _ = m.look(facts(.connecting), now: at(11.1)) // the display's own "connecting"
        _ = m.look(facts(.disconnected, startInFlight: true), now: at(11.2))
        _ = m.look(facts(.connecting), now: at(11.3))
        _ = m.look(facts(.connected), now: at(12))
        XCTAssertEqual(m.look(facts(.connected), now: at(18.5)), [])
        XCTAssertEqual(m.origin, .startedHere)
        XCTAssertEqual(m.state, .notReaching(.unexplained))
    }

    /// Once the system has reported the start moving (no start in flight), a
    /// "down" is the run's real end.
    func testADownOnceTheStartWasReportedEndsTheRun() {
        var m = machine()
        m.startSent(at: at(0))
        _ = m.look(facts(.connecting), now: at(0.2))
        _ = m.look(facts(.disconnected), now: at(1))
        XCTAssertEqual(m.origin, .none)
        _ = m.look(facts(.connected), now: at(30))
        XCTAssertEqual(m.origin, .startedElsewhere, "the next run is not this process's")
    }

    // MARK: - Review of build 53: a request while capture is off

    /// A click that started nothing (a busy-port question cancelled, setup
    /// not finished) while capture was off is about no later run: a capture
    /// started from System Settings afterwards is still restarted once.
    func testARequestWhileCaptureIsOffStandsNoLaterRunDown() {
        for tunnel in [CaptureTunnelState?.none, .disconnected, .invalid] {
            var m = machine()
            _ = m.look(facts(.disconnected), now: at(0))
            m.userRequested(tunnel: tunnel)
            XCTAssertFalse(m.requestedThisStretch, "\(String(describing: tunnel))")
            _ = m.look(facts(.connecting), now: at(30))
            _ = m.look(facts(.connected, refusal: .noCredential, refusedAt: at(30.5)), now: at(31))
            XCTAssertEqual(m.look(facts(.connected, refusal: .noCredential, refusedAt: at(30.5)), now: at(37.5)),
                           [.restartCapture(.startedOutsideReqRes)], "\(String(describing: tunnel))")
        }
        // While it runs, or is on its way on or off, a request stands.
        for tunnel in [CaptureTunnelState.connecting, .connected, .reasserting, .disconnecting] {
            var m = machine(upAtLaunch: true)
            m.userRequested(tunnel: tunnel)
            XCTAssertTrue(m.requestedThisStretch, "\(tunnel)")
        }
    }

    // MARK: - Review of build 53: a reconnection too quick for a look

    /// The extension's connection closed and the core redialed within a
    /// quarter of a second, between two looks: the second hello says so, and
    /// the reattach is not "captured while ReqRes was closed".
    func testASecondHelloIsAReconnectionEvenBetweenLooks() throws {
        var m = machine()
        m.startSent(at: at(0))
        m.extensionSaidHello(at: at(0.5))
        _ = m.look(facts(.connected, auth: true), now: at(1))
        XCTAssertFalse(m.detachedThisRun)
        m.extensionSaidHello(at: at(1.6))
        _ = m.look(facts(.connected, auth: true), now: at(2))
        XCTAssertTrue(m.detachedThisRun)
        _ = m.reattachReported(CaptureReattachReport(), capturedWhileDetached: 3, tunnel: .connected, now: at(2.1))
        XCTAssertEqual(try XCTUnwrap(m.notice).text(busPort: 50001),
                       "3 requests were captured while the extension was reconnecting to ReqRes.")
    }

    /// A look can see the extension attached before its hello reaches the
    /// main thread (the core marks it authenticated first): that first hello
    /// is still the first, not a reconnection.
    func testAHelloAfterTheLookThatSawItIsNotAReconnection() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected, auth: true), now: at(0))
        m.extensionSaidHello(at: at(0.05))
        XCTAssertFalse(m.detachedThisRun)
        _ = m.reattachReported(report, capturedWhileDetached: 4, tunnel: .connected, now: at(0.1))
        XCTAssertEqual(m.notice, .reattached(capturedWhileDetached: 4, droppedRows: 12, appWasClosed: true))
    }

    /// A new run counts its hellos afresh — one that ended (the next comes
    /// up from anywhere), and one this process starts without a "down" seen
    /// in between (its stop read late).
    func testEachRunCountsItsOwnHellos() {
        var ended = machine()
        ended.startSent(at: at(0))
        ended.extensionSaidHello(at: at(0.5))
        _ = ended.look(facts(.disconnected), now: at(10))
        _ = ended.look(facts(.connected), now: at(11))
        ended.extensionSaidHello(at: at(11.5))
        XCTAssertFalse(ended.detachedThisRun, "the first hello of a run that came up elsewhere")

        var restarted = machine()
        restarted.startSent(at: at(0))
        restarted.extensionSaidHello(at: at(0.5))
        _ = restarted.look(facts(.connected, auth: true), now: at(1))
        restarted.startSent(at: at(11)) // no "down" seen in between
        restarted.extensionSaidHello(at: at(11.5))
        XCTAssertFalse(restarted.detachedThisRun, "the first hello of this process's new start")
    }

    /// A reattach reported while the tunnel reads connected, before any look
    /// has seen this run come up: the look that follows must not take its
    /// note for the last run's.
    func testAReattachBeforeTheRunsFirstLookKeepsItsNote() {
        var m = machine()
        _ = m.look(facts(.disconnected), now: at(0))
        m.extensionSaidHello(at: at(5))
        _ = m.reattachReported(report, capturedWhileDetached: 7, tunnel: .connected, now: at(5.1))
        XCTAssertEqual(m.notice, .reattached(capturedWhileDetached: 7, droppedRows: 12, appWasClosed: true))
        _ = m.look(facts(.connected, auth: true), now: at(5.2))
        XCTAssertEqual(m.notice, .reattached(capturedWhileDetached: 7, droppedRows: 12, appWasClosed: true))
        XCTAssertEqual(m.origin, .startedElsewhere)
    }

    // MARK: - Review of build 53: notes that outlived what they were about

    /// The restarted capture never came up: the note does not say ReqRes
    /// restarted capture, it says it did not start again — and it stays,
    /// since it says why capture is off.
    func testARestartWhoseCaptureNeverCameUpSaysSo() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        _ = m.look(facts(.connected), now: at(grace))
        _ = m.look(facts(.disconnected), now: at(7))
        m.startSent(at: at(7.1))
        m.automaticRestartFinished(.startSent)
        _ = m.look(facts(.connecting), now: at(7.2))
        _ = m.look(facts(.disconnected), now: at(9))
        XCTAssertEqual(m.state, .notCapturing)
        XCTAssertEqual(m.notice, .automaticRestartDidNotStart)
        XCTAssertTrue(m.notice?.isProblem == true)
        _ = m.look(facts(.disconnected), now: at(20))
        XCTAssertEqual(m.notice, .automaticRestartDidNotStart, "later looks at a stopped capture keep it")
        // The next capture, from anywhere, makes it history.
        _ = m.look(facts(.connected), now: at(60))
        XCTAssertNil(m.notice)
    }

    /// …unless someone stopped it while it came up: that is why.
    func testARestartedCaptureSomeoneStoppedIsNotSaidToHaveFailed() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        _ = m.look(facts(.connected), now: at(grace))
        _ = m.look(facts(.disconnected), now: at(7))
        m.startSent(at: at(7.1))
        m.automaticRestartFinished(.startSent)
        _ = m.look(facts(.connecting), now: at(7.2))
        m.userRequested(tunnel: .connecting) // Stop
        _ = m.look(facts(.disconnected), now: at(8))
        XCTAssertNil(m.notice)
    }

    /// The notes about a capture go when it stops, unless they say why it
    /// is off; those stay until the next capture starts (F13's class).
    func testTheNotesGoWithTheirCaptureUnlessTheySayWhyItIsOff() {
        // A reattach's.
        var reattached = machine(upAtLaunch: true)
        _ = reattached.look(facts(.connected, auth: true), now: at(0))
        _ = reattached.reattachReported(CaptureReattachReport(droppedRows: 25000), capturedWhileDetached: 512,
                                        tunnel: .connected, now: at(0.1))
        XCTAssertNotNil(reattached.notice)
        _ = reattached.look(facts(.disconnected), now: at(20))
        XCTAssertNil(reattached.notice, "about the capture that stopped")

        // A failed restart that left capture running goes with it; one that
        // says why capture is off stays.
        let table: [(CaptureRestartFailure, staysWhenStopped: Bool)] = [
            (.channelUnavailable(anotherCopyRunning: true), false),
            (.configurationUnreadable("the system did not answer"), false),
            (.didNotStop, true),
            (.startRefused("configuration disabled"), true),
        ]
        for (failure, stays) in table {
            var m = machine(upAtLaunch: true)
            _ = m.look(facts(.connected), now: at(0))
            _ = m.look(facts(.connected), now: at(grace))
            m.automaticRestartFinished(.failed(failure))
            _ = m.look(facts(.disconnected), now: at(20))
            XCTAssertEqual(m.notice != nil, stays, "\(failure)")
            XCTAssertEqual(CaptureReattachNotice.automaticRestartFailed(failure).outlivesTheRun, stays, "\(failure)")
            m.startSent(at: at(30))
            XCTAssertNil(m.notice, "\(failure): a new start makes it history")
        }
        XCTAssertTrue(CaptureReattachNotice.automaticRestartDidNotStart.outlivesTheRun)
        XCTAssertFalse(CaptureReattachNotice.restartedAutomatically(.appRelaunched).outlivesTheRun)
        XCTAssertFalse(CaptureReattachNotice.reattached(capturedWhileDetached: 1, droppedRows: 0, appWasClosed: true).outlivesTheRun)
    }

    /// A failed restart that left capture running is said under F11's
    /// notice while it applies (`restartTriedThisStretch`), and its note goes
    /// once an extension has stayed attached — it used to surface only then,
    /// saying to try Restart Capture "again" (review).
    func testAFailedRestartIsSaidWhileItAppliesAndGoesWhenTheStretchEnds() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        _ = m.look(facts(.connected), now: at(grace))
        m.automaticRestartFinished(.failed(.configurationUnreadable("the system did not answer")))
        XCTAssertEqual(m.delivery, .notReceiving(.appRelaunched))
        XCTAssertEqual(m.restartTriedThisStretch, .failed(.configurationUnreadable("the system did not answer")))
        m.extensionSaidHello(at: at(10))
        _ = m.look(facts(.connected, auth: true), now: at(10))
        XCTAssertNotNil(m.notice, "a second in: not over yet")
        _ = m.look(facts(.connected, auth: true), now: at(14))
        XCTAssertNil(m.notice)
        XCTAssertNil(m.restartTriedThisStretch)
    }

    /// What the restart tried is the stretch's: set when it ends, gone with
    /// the stretch, the run, or a start someone else sends.
    func testWhatTheRestartTriedBelongsToItsStretch() {
        var m = machine(upAtLaunch: true)
        XCTAssertNil(m.restartTriedThisStretch)
        _ = m.look(facts(.connected), now: at(0))
        _ = m.look(facts(.connected), now: at(grace))
        m.startSent(at: at(7))
        m.automaticRestartFinished(.startSent)
        XCTAssertEqual(m.restartTriedThisStretch, .restarted, "its own start keeps it")
        _ = m.look(facts(.connected), now: at(8))
        _ = m.look(facts(.connected), now: at(8 + grace))
        XCTAssertEqual(m.delivery, .notReceiving(.unexplained))
        XCTAssertEqual(m.restartTriedThisStretch, .restarted, "said under F11's notice")
        m.startSent(at: at(30))
        XCTAssertNil(m.restartTriedThisStretch, "a start someone else sent")
        var stopped = machine(upAtLaunch: true)
        _ = stopped.look(facts(.connected), now: at(0))
        _ = stopped.look(facts(.connected), now: at(grace))
        stopped.automaticRestartFinished(.failed(.didNotStop))
        _ = stopped.look(facts(.disconnected), now: at(30))
        XCTAssertNil(stopped.restartTriedThisStretch, "the run ended")
    }

    /// An extension reattached in the hop before the restart's stop: nothing
    /// was restarted, nothing is said.
    func testARestartTheReattachMadeNeedlessSaysNothing() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected), now: at(0))
        _ = m.look(facts(.connected), now: at(grace))
        m.automaticRestartFinished(.noLongerNeeded)
        XCTAssertNil(m.notice)
        XCTAssertNil(m.restartTriedThisStretch)
        XCTAssertEqual(m.automaticRestart, .used)
    }

    // MARK: - Review of build 53: "reconnecting" only when it will

    /// A capture whose extension was refused within the stretch for a reason
    /// no redial gets past — started without the key, or an earlier build's —
    /// is not "reconnecting by itself": it is waiting for ReqRes to restart it.
    /// A relaunch, a lost connection and a takeover are reconnecting.
    func testOnlyACaptureThatCanReconnectIsSaidToReconnect() {
        for refusal in [CaptureBusRefusal.noCredential, .unboundHello] {
            var m = machine()
            _ = m.look(facts(.disconnected), now: at(0))
            _ = m.look(facts(.connected, refusal: refusal, refusedAt: at(0.5)), now: at(1))
            XCTAssertEqual(m.origin, .startedElsewhere)
            XCTAssertEqual(m.delivery, .waiting, "\(refusal)")
        }
        for refusal in [CaptureBusRefusal.noHello, .badProof, .timedOut] {
            var m = machine()
            _ = m.look(facts(.disconnected), now: at(0))
            _ = m.look(facts(.connected, refusal: refusal, refusedAt: at(0.5)), now: at(1))
            XCTAssertEqual(m.delivery, .reconnecting, "\(refusal): anyone can produce it")
        }
        // A refusal from before the stretch does not count.
        var relaunched = machine(upAtLaunch: true)
        _ = relaunched.look(facts(.connected, refusal: .noCredential, refusedAt: t0.addingTimeInterval(-5)), now: at(0))
        XCTAssertEqual(relaunched.delivery, .reconnecting)
        // Another copy quit, and this one took the bus over.
        var takeover = machine(upAtLaunch: true)
        _ = takeover.look(facts(.connected, bus: false, otherCopy: true), now: at(0))
        _ = takeover.look(facts(.connected), now: at(5))
        XCTAssertEqual(takeover.delivery, .reconnecting)
    }

    // MARK: - Review of build 53: the agent's counts are news only for a while

    func testTheReattachCountsReachTheBridgeForFiveMinutes() {
        var m = machine(upAtLaunch: true)
        _ = m.look(facts(.connected, auth: true), now: at(0))
        XCTAssertNil(m.reattachCounts(at: at(0)), "no reattach yet")
        _ = m.reattachReported(report, capturedWhileDetached: 40, tunnel: .connected, now: at(1))
        XCTAssertEqual(m.reattachCounts(at: at(2)), CaptureReattachCounts(captured: 40, droppedRows: 12))
        XCTAssertEqual(m.reattachCounts(at: at(1 + 299)), CaptureReattachCounts(captured: 40, droppedRows: 12))
        XCTAssertNil(m.reattachCounts(at: at(1 + 300)), "an hour later is not news")
        XCTAssertEqual(CaptureReattach.reattachReportWindow, 300)
        // An empty reattach has nothing to report.
        var empty = machine(upAtLaunch: true)
        _ = empty.look(facts(.connected, auth: true), now: at(0))
        _ = empty.reattachReported(CaptureReattachReport(), capturedWhileDetached: 0, tunnel: .connected, now: at(1))
        XCTAssertNil(empty.reattachCounts(at: at(2)))
    }
}
