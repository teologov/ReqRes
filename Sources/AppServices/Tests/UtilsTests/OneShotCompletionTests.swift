//
//  OneShotCompletionTests.swift
//  ReqRes
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
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

final class OneShotCompletionTests: XCTestCase {

    func testFirstFireRunsAndLaterOnesDoNot() {
        let gate = OneShotCompletion()
        var runs: [String] = []
        XCTAssertFalse(gate.isCompleted)
        XCTAssertTrue(gate.fire { runs.append("found") })
        XCTAssertFalse(gate.fire { runs.append("finished") })
        XCTAssertFalse(gate.fire { runs.append("failed") })
        XCTAssertEqual(runs, ["found"])
        XCTAssertTrue(gate.isCompleted)
    }

    func testAContinuationBehindTheGateResumesExactlyOnce() async {
        // The real use: several delegate callbacks racing to resume one
        // continuation. A second resume would trap, so reaching the assertion
        // at all is the test.
        let value: Int = await withCheckedContinuation { continuation in
            let gate = OneShotCompletion()
            gate.fire { continuation.resume(returning: 1) }
            gate.fire { continuation.resume(returning: 2) }
            gate.fire { continuation.resume(returning: 3) }
        }
        XCTAssertEqual(value, 1)
    }

    func testConcurrentFiresRunExactlyOne() {
        let gate = OneShotCompletion()
        let counter = ManagedAtomic()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            gate.fire { counter.increment() }
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testTheBodyRunsOutsideTheLockSoItMayFireAgainWithoutDeadlocking() {
        let gate = OneShotCompletion()
        var inner = false
        gate.fire {
            // Re-entrant fire from inside the body must return false, not hang.
            inner = gate.fire { XCTFail("must not run") }
        }
        XCTAssertFalse(inner)
    }
}

/// A tiny lock-protected counter for the concurrency test.
private final class ManagedAtomic {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
