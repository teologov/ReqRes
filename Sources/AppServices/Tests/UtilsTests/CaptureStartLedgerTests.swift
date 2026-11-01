//
//  CaptureStartLedgerTests.swift
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
//  Build 53 review: whether a proxy an overtaken start made may be closed is
//  the extension PROCESS's question — closing ends the core's process-wide
//  search for the app — not one provider object's.
//

import XCTest
@testable import Utils

final class CaptureStartLedgerTests: XCTestCase {
    /// Only while no start has begun since — whichever provider began it.
    func testOnlyTheLatestStartMayCloseWhatItMade() {
        let ledger = CaptureStartLedger()
        let first = ledger.begin()
        var closed: [String] = []
        XCTAssertTrue(ledger.ifNoStartSince(first) { closed.append("first") })
        let second = ledger.begin() // a later session's provider
        XCTAssertFalse(ledger.ifNoStartSince(first) { closed.append("first, late") })
        XCTAssertTrue(ledger.ifNoStartSince(second) { closed.append("second") })
        XCTAssertEqual(closed, ["first", "second"])
        XCTAssertNotEqual(first, second)
    }

    /// Starts on many threads: every number is handed out once.
    func testEveryStartGetsItsOwnNumber() {
        let ledger = CaptureStartLedger()
        let lock = NSLock()
        var numbers: [UInt64] = []
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let number = ledger.begin()
            lock.lock(); numbers.append(number); lock.unlock()
        }
        XCTAssertEqual(Set(numbers).count, 200)
        XCTAssertTrue(ledger.ifNoStartSince(numbers.max() ?? 0) {})
    }

    /// The extension's providers share one.
    func testTheProcessHasOne() {
        XCTAssertTrue(CaptureStartLedger.process === CaptureStartLedger.process)
    }
}
