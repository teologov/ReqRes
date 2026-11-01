//
//  CaptureTunnelStateTests.swift
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
//  F11 (2026-09-30): after the app died while capturing, the relaunched app
//  showed capture off, its Start stopped the running capture, and its Quit
//  neither asked nor stopped. These pin the three decisions behind that —
//  and, after the review, a start never sent twice and Restart Capture's
//  steps.
//

import NetworkExtension
import XCTest
@testable import Utils

final class CaptureTunnelStateTests: XCTestCase {

    // MARK: - The mirror

    /// The app maps NEVPNStatus both ways through `rawValue`; a value that
    /// drifted would silently turn one status into another.
    func testEveryCaseIsNEVPNStatusByRawValue() {
        let pairs: [(CaptureTunnelState, NEVPNStatus)] = [
            (.invalid, .invalid),
            (.disconnected, .disconnected),
            (.connecting, .connecting),
            (.connected, .connected),
            (.reasserting, .reasserting),
            (.disconnecting, .disconnecting),
        ]
        XCTAssertEqual(pairs.count, CaptureTunnelState.allCases.count, "a case with no NEVPNStatus twin")
        for (state, status) in pairs {
            XCTAssertEqual(state.rawValue, status.rawValue, "\(state)")
        }
    }

    // MARK: - What a status read at launch is shown as

    /// Only `.invalid` changes, and only to `.disconnected` — the button stays
    /// a usable Start. Above all, `.connected` is shown as `.connected`: the
    /// launch check used to write `.disconnected` whatever it found.
    func testOnlyInvalidIsShownDifferently() {
        let expected: [CaptureTunnelState: CaptureTunnelState] = [
            .invalid: .disconnected,
            .disconnected: .disconnected,
            .connecting: .connecting,
            .connected: .connected,
            .reasserting: .reasserting,
            .disconnecting: .disconnecting,
        ]
        for state in CaptureTunnelState.allCases {
            XCTAssertEqual(state.displayed, expected[state], "\(state)")
        }
    }

    func testDownAndMoving() {
        let table: [(CaptureTunnelState, down: Bool, moving: Bool)] = [
            (.invalid, true, false),
            (.disconnected, true, false),
            (.connecting, false, true),
            (.connected, false, false),
            (.reasserting, false, true),
            (.disconnecting, false, true),
        ]
        for (state, down, moving) in table {
            XCTAssertEqual(state.isDown, down, "\(state).isDown")
            XCTAssertEqual(state.isMoving, moving, "\(state).isMoving")
        }
    }

    // MARK: - Start, stop, or neither

    /// The button's meaning is what the user SAW: off means start, anything
    /// else means stop.
    func testTheToggleMeansWhatTheUserSaw() {
        for shown in CaptureTunnelState.allCases {
            XCTAssertEqual(CaptureIntent.toggle(shown: shown), shown.isDown ? .start : .stop, "\(shown)")
        }
    }

    /// The whole table. A start only starts a tunnel that is down; a stop
    /// only stops one that is up; everything else corrects the display.
    func testTheActionForEveryIntentAndRealStatus() {
        let expected: [(CaptureIntent, CaptureTunnelState, CaptureControlAction)] = [
            (.start, .invalid, .start),
            (.start, .disconnected, .start),
            (.start, .connecting, .showRealStatus),
            (.start, .connected, .showRealStatus),
            (.start, .reasserting, .showRealStatus),
            (.start, .disconnecting, .showRealStatus),
            (.stop, .invalid, .showRealStatus),
            (.stop, .disconnected, .showRealStatus),
            (.stop, .connecting, .stop),
            (.stop, .connected, .stop),
            (.stop, .reasserting, .stop),
            (.stop, .disconnecting, .showRealStatus),
        ]
        XCTAssertEqual(expected.count, 2 * CaptureTunnelState.allCases.count)
        for (intent, real, action) in expected {
            XCTAssertEqual(CaptureControl.action(for: intent, real: real), action, "\(intent) with the tunnel \(real)")
        }
    }

    /// F11 itself: a relaunched app showed capture off while it ran, and its
    /// Start went to a toggle that read the real status and STOPPED it.
    func testAStartShownOverARunningCaptureNeverStopsIt() {
        let intent = CaptureIntent.toggle(shown: .disconnected)
        XCTAssertEqual(intent, .start)
        for real in CaptureTunnelState.allCases {
            XCTAssertNotEqual(CaptureControl.action(for: intent, real: real), .stop, "a Start stopped a tunnel that was \(real)")
        }
    }

    /// The mirror image: a Stop never starts anything.
    func testAStopNeverStarts() {
        for real in CaptureTunnelState.allCases {
            XCTAssertNotEqual(CaptureControl.action(for: .stop, real: real), .start, "a Stop started a tunnel that was \(real)")
        }
    }

    /// A restart waits for the tunnel to read down, then asks for a START —
    /// which the display (still "connected" until its notification lands)
    /// must not turn into a stop, as the toggle it used to call could.
    func testARestartsStartIsAStartWhateverTheDisplaySays() {
        XCTAssertEqual(CaptureControl.action(for: .start, real: .disconnected), .start)
        XCTAssertEqual(CaptureIntent.toggle(shown: .connected), .stop, "why the restart cannot use the toggle")
    }

    // MARK: - A start on its way

    /// Two requests made against the same "off" display — two quick clicks,
    /// or a click racing Restart Capture's own start — both found the tunnel
    /// reading down, and both sent a start (F11 review). A start on its way
    /// is never sent twice; a stop still stops the tunnel it started.
    func testAStartOnItsWayIsNeverSentTwice() {
        for real in CaptureTunnelState.allCases {
            let start = CaptureControl.action(for: .start, real: real, startInFlight: true)
            let stop = CaptureControl.action(for: .stop, real: real, startInFlight: true)
            if real.isDown {
                XCTAssertEqual(start, .startAlreadySent, "\(real): a second start into a starting tunnel")
                XCTAssertEqual(stop, .stop, "\(real): the tunnel is on its way up, and a stop stops it")
            } else {
                // Once the system reports it, the ordinary rule answers.
                XCTAssertEqual(start, CaptureControl.action(for: .start, real: real), "\(real)")
                XCTAssertEqual(stop, CaptureControl.action(for: .stop, real: real), "\(real)")
            }
            XCTAssertNotEqual(start, .start, "\(real): a start was sent twice")
        }
    }

    /// Without a start on its way, nothing changes.
    func testNoStartOnItsWayLeavesTheRuleAlone() {
        for intent in [CaptureIntent.start, .stop] {
            for real in CaptureTunnelState.allCases {
                XCTAssertEqual(CaptureControl.action(for: intent, real: real, startInFlight: false),
                               CaptureControl.action(for: intent, real: real), "\(intent) \(real)")
                XCTAssertNotEqual(CaptureControl.action(for: intent, real: real), .startAlreadySent)
            }
        }
    }

    /// On its way for at most the window: a start the system never reports
    /// must not block the next click for good.
    func testAStartCountsAsOnItsWayForAtMostTheWindow() {
        let sent = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let window = CaptureControl.startInFlightWindow
        XCTAssertEqual(window, 5)
        XCTAssertFalse(CaptureControl.startInFlight(sentAt: nil, now: sent))
        XCTAssertTrue(CaptureControl.startInFlight(sentAt: sent, now: sent))
        XCTAssertTrue(CaptureControl.startInFlight(sentAt: sent, now: sent.addingTimeInterval(window - 0.001)))
        XCTAssertFalse(CaptureControl.startInFlight(sentAt: sent, now: sent.addingTimeInterval(window)))
        XCTAssertFalse(CaptureControl.startInFlight(sentAt: sent, now: sent.addingTimeInterval(-1)), "a clock that went back is not a start on its way")
    }

    // MARK: - Restart Capture

    /// Every look: a request made since stands; a tunnel reading down gets
    /// the start; one seen going down and then up again was started by
    /// someone else; otherwise wait, and give up after the timeout.
    func testTheRestartStepForEveryLook() {
        let timeout = CaptureRestart.stopTimeout
        for tunnel in CaptureTunnelState.allCases {
            for sawStopping in [false, true] {
                for requested in [false, true] {
                    for elapsed in [0, timeout - 0.001, timeout, timeout * 3] {
                        let got = CaptureRestart.step(tunnel: tunnel, sawStopping: sawStopping, requestedSince: requested, elapsed: elapsed)
                        let expected: CaptureRestartStep
                        if requested {
                            expected = .standDown
                        } else if tunnel.isDown {
                            expected = .start
                        } else if sawStopping && tunnel != .disconnecting {
                            expected = .standDown
                        } else {
                            expected = elapsed >= timeout ? .giveUp : .wait
                        }
                        XCTAssertEqual(got, expected, "\(tunnel) sawStopping=\(sawStopping) requested=\(requested) elapsed=\(elapsed)")
                    }
                }
            }
        }
    }

    /// The agent's stop_capture (or a click) made while the restart waited:
    /// the restart used to start capture again regardless.
    func testARestartNeverStartsOverARequestMadeMeanwhile() {
        for tunnel in CaptureTunnelState.allCases {
            XCTAssertEqual(CaptureRestart.step(tunnel: tunnel, sawStopping: true, requestedSince: true, elapsed: 1), .standDown, "\(tunnel)")
        }
    }

    /// A tunnel someone else started while the restart waited used to hold
    /// "Restarting Capture…" for the full 10 s and end in a false log line.
    func testARestartThatSeesTheTunnelBackUpStandsDownAtOnce() {
        XCTAssertEqual(CaptureRestart.step(tunnel: .disconnecting, sawStopping: false, requestedSince: false, elapsed: 0.25), .wait)
        XCTAssertEqual(CaptureRestart.step(tunnel: .disconnecting, sawStopping: true, requestedSince: false, elapsed: 0.5), .wait)
        XCTAssertEqual(CaptureRestart.step(tunnel: .connecting, sawStopping: true, requestedSince: false, elapsed: 0.75), .standDown)
        XCTAssertEqual(CaptureRestart.step(tunnel: .connected, sawStopping: false, requestedSince: false, elapsed: 0.25), .wait,
                       "before the stop takes effect, connected is the old run")
    }

    func testTheRestartWaitsTenSecondsForItsStop() {
        XCTAssertEqual(CaptureRestart.stopTimeout, 10)
        XCTAssertEqual(CaptureRestart.lookInterval, 0.25)
        XCTAssertEqual(CaptureRestart.step(tunnel: .connected, sawStopping: false, requestedSince: false, elapsed: 9.99), .wait)
        XCTAssertEqual(CaptureRestart.step(tunnel: .connected, sawStopping: false, requestedSince: false, elapsed: 10), .giveUp)
    }

    // MARK: - Quit

    /// The whole rule: a tunnel that is not plainly off (a half-built one
    /// included) is stopped by the copy holding the bus, and by a copy
    /// without it only while no other copy runs — never by a second copy
    /// while the first holds the capture.
    func testTheQuitRuleForEveryCase() {
        for real in CaptureTunnelState.allCases {
            for holdsBus in [false, true] {
                for anotherCopy in [false, true] {
                    let expected = !real.isDown && (holdsBus || !anotherCopy)
                    XCTAssertEqual(CaptureControl.stopsCaptureOnQuit(real: real, holdsBus: holdsBus, anotherCopyRunning: anotherCopy),
                                   expected, "\(real) holdsBus=\(holdsBus) anotherCopy=\(anotherCopy)")
                }
            }
        }
    }

    /// A second copy — a Debug build beside the installed app — must not
    /// stop the capture the first one holds.
    func testQuitNeverStopsTheCaptureAnotherCopyHolds() {
        for real in CaptureTunnelState.allCases {
            XCTAssertFalse(CaptureControl.stopsCaptureOnQuit(real: real, holdsBus: false, anotherCopyRunning: true),
                           "\(real): a copy without the bus stopped another copy's capture")
        }
    }

    /// The copy that held the bus is gone (Xcode's Stop on the Debug build),
    /// and the one left cannot bind it: the tunnel delivers to nobody, and a
    /// quit that neither asked nor stopped left it decrypting every request
    /// on the Mac for no one (F11 review).
    func testQuitStopsACaptureNobodyReceives() {
        XCTAssertTrue(CaptureControl.stopsCaptureOnQuit(real: .connected, holdsBus: false, anotherCopyRunning: false))
    }

    /// The relaunch case: the display said off, the tunnel ran — the quit
    /// must still ask, because it reads the tunnel, not the display.
    func testQuitAsksForACaptureThatOutlivedTheLastApp() {
        XCTAssertTrue(CaptureControl.stopsCaptureOnQuit(real: .connected, holdsBus: true, anotherCopyRunning: false))
        XCTAssertTrue(CaptureControl.stopsCaptureOnQuit(real: .connecting, holdsBus: true, anotherCopyRunning: false), "a quit mid-connect leaves the half-built tunnel that wedges the extension")
    }
}
