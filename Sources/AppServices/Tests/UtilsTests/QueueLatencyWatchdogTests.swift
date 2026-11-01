//
//  QueueLatencyWatchdogTests.swift
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

import XCTest
@testable import Utils

final class QueueLatencyWatchdogTests: XCTestCase {
    /// The deadlock the first shape had: `stop()` called from a block on the
    /// measured queue while a ping is queued behind that block.
    func testStopFromTheMeasuredQueueWithAPingOutstandingReturnsAtOnce() {
        let target = DispatchQueue(label: "measured")
        let watchdog = QueueLatencyWatchdog(target: target, interval: 0.005)
        watchdog.start()
        Thread.sleep(forTimeInterval: 0.05)
        let returned = expectation(description: "stop returned")
        target.async {
            // Hold the queue so the watchdog's next ping is queued behind us.
            Thread.sleep(forTimeInterval: 0.05)
            let start = Date()
            let report = watchdog.stop()
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
            XCTAssertGreaterThan(report.samples, 0)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 2)
    }

    func testTheReportSummarisesTheSamples() {
        let target = DispatchQueue(label: "measured-2")
        let watchdog = QueueLatencyWatchdog(target: target, interval: 0.002)
        watchdog.start()
        Thread.sleep(forTimeInterval: 0.1)
        let report = watchdog.stop()
        XCTAssertGreaterThan(report.samples, 5)
        XCTAssertLessThanOrEqual(report.median, report.worst)
        XCTAssertEqual(report.over250ms, 0)
    }
}
