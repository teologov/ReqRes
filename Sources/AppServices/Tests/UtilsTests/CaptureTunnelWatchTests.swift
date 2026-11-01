//
//  CaptureTunnelWatchTests.swift
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
@testable import Utils

final class CaptureTunnelWatchTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: A start that never connected

    /// The shape of the extension refusing a start: connecting, then down.
    func testAStartThatNeverConnectedIsReportedOnce() {
        var watch = CaptureTunnelWatch()
        watch.observe(.down, at: t0)
        watch.startRequested()
        XCTAssertFalse(watch.observe(.connecting, at: t0))
        XCTAssertFalse(watch.observe(.disconnecting, at: t0))
        XCTAssertTrue(watch.observe(.down, at: t0))
        XCTAssertFalse(watch.observe(.down, at: t0), "once per start")
    }

    func testAStartThatConnectedIsNotReported() {
        var watch = CaptureTunnelWatch()
        watch.startRequested()
        watch.observe(.connecting, at: t0)
        watch.observe(.connected, at: t0)
        watch.observe(.disconnecting, at: t0)
        XCTAssertFalse(watch.observe(.down, at: t0), "a capture that ran and stopped")
    }

    func testAStartTheAppStoppedIsNotReported() {
        var watch = CaptureTunnelWatch()
        watch.startRequested()
        watch.observe(.connecting, at: t0)
        watch.stopRequested()
        watch.observe(.disconnecting, at: t0)
        XCTAssertFalse(watch.observe(.down, at: t0))
    }

    /// A `.down` queued from the stop before must not read as this start failing.
    func testALateNotificationFromTheStopBeforeIsNotThisStartFailing() {
        var watch = CaptureTunnelWatch()
        watch.observe(.connected, at: t0)
        watch.startRequested()
        XCTAssertFalse(watch.observe(.down, at: t0))
        watch.observe(.connecting, at: t0)
        XCTAssertTrue(watch.observe(.down, at: t0), "this start, seen connecting, then down")
    }

    /// Started from System Settings, say: nothing the app asked for.
    func testAStartTheAppDidNotAskForIsNotReported() {
        var watch = CaptureTunnelWatch()
        watch.observe(.connecting, at: t0)
        XCTAssertFalse(watch.observe(.down, at: t0))
    }

    func testANewStartIsWatchedAfresh() {
        var watch = CaptureTunnelWatch()
        watch.startRequested()
        watch.observe(.connecting, at: t0)
        XCTAssertTrue(watch.observe(.down, at: t0))
        watch.startRequested()
        watch.observe(.connecting, at: t0)
        watch.observe(.connected, at: t0)
        XCTAssertFalse(watch.observe(.down, at: t0))
    }

    // MARK: When the tunnel stopped

    func testTheStopIsWhenTheTunnelWentDown() {
        var watch = CaptureTunnelWatch()
        watch.observe(.connected, at: t0)
        watch.observe(.disconnecting, at: t0.addingTimeInterval(1))
        watch.observe(.down, at: t0.addingTimeInterval(2))
        XCTAssertEqual(watch.stoppedAt, t0.addingTimeInterval(2))
        XCTAssertTrue(watch.stoppedRecently(now: t0.addingTimeInterval(3.9)))
        XCTAssertFalse(watch.stoppedRecently(now: t0.addingTimeInterval(4)), "the window is ProxyPortAvailability.settlingWindow")
        XCTAssertFalse(watch.stoppedRecently(now: t0.addingTimeInterval(18)), "the live F10 start came 16 s after its stop")
        watch.observe(.down, at: t0.addingTimeInterval(30))
        XCTAssertEqual(watch.stoppedAt, t0.addingTimeInterval(2), "a repeated down is not another stop")
    }

    func testTheFirstStatusAfterLaunchIsNotAStop() {
        var watch = CaptureTunnelWatch()
        watch.observe(.down, at: t0)
        XCTAssertNil(watch.stoppedAt)
        XCTAssertFalse(watch.stoppedRecently(now: t0))
        XCTAssertFalse(CaptureTunnelWatch().stoppedRecently(now: t0), "nothing seen at all")
    }

    /// The manager reads disconnected before its notification arrives — the
    /// CA replacement's restart polls it and starts at once.
    func testATunnelLastSeenUpIsStillStopping() {
        var watch = CaptureTunnelWatch()
        watch.observe(.connected, at: t0)
        XCTAssertTrue(watch.stoppedRecently(now: t0.addingTimeInterval(3600)))
        watch.observe(.disconnecting, at: t0)
        XCTAssertTrue(watch.stoppedRecently(now: t0.addingTimeInterval(3600)))
    }

    func testAStartThatFailedIsAStopToo() {
        var watch = CaptureTunnelWatch()
        watch.observe(.down, at: t0)
        watch.startRequested()
        watch.observe(.connecting, at: t0.addingTimeInterval(1))
        watch.observe(.down, at: t0.addingTimeInterval(2))
        XCTAssertEqual(watch.stoppedAt, t0.addingTimeInterval(2), "its listener may have bound before the start failed")
    }
}
