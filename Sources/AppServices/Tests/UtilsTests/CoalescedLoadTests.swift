//
//  CoalescedLoadTests.swift
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
//  The capture configuration's load (F11) called back only on success, so a
//  failure hung every caller, and the checks that overlap at launch each
//  started their own. These pin the replacement: every caller answered once,
//  failure and time-out included, and one load for all of them.
//

import XCTest
@testable import Utils

final class CoalescedLoadTests: XCTestCase {
    private struct Failure: Error, Equatable {}

    /// A time-out the test fires by hand.
    private final class ManualClock {
        var pending: [(TimeInterval, () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { pending.append((delay, work)) }
        func fireAll() {
            let due = pending
            pending = []
            due.forEach { $0.1() }
        }
    }

    private final class Recorder {
        var results: [Result<Int, Error>] = []
        func record(_ result: Result<Int, Error>) { results.append(result) }
        var values: [Int?] { results.map { try? $0.get() } }
    }

    // MARK: - One load for everyone

    func testCallersWhileALoadRunsShareIt() {
        let clock = ManualClock()
        let load = CoalescedLoad<Int>(timeout: 10, schedule: clock.schedule)
        let recorder = Recorder()
        var starts = 0
        var finish: ((Result<Int, Error>) -> Void)?

        for _ in 0..<3 {
            load.load(recorder.record) { done in
                starts += 1
                finish = done
            }
        }
        XCTAssertEqual(starts, 1, "three callers, one load")
        XCTAssertTrue(load.isLoading)
        XCTAssertTrue(recorder.results.isEmpty)

        finish?(.success(7))
        XCTAssertEqual(recorder.values, [7, 7, 7], "each caller answered, once")
        XCTAssertFalse(load.isLoading)
    }

    /// A failure answers everyone — the old load answered only a success.
    func testAFailureAnswersEveryCaller() {
        let load = CoalescedLoad<Int>(timeout: nil)
        let recorder = Recorder()
        var finish: ((Result<Int, Error>) -> Void)?
        load.load(recorder.record) { finish = $0 }
        load.load(recorder.record) { _ in XCTFail("a second load started") }
        finish?(.failure(Failure()))
        XCTAssertEqual(recorder.results.count, 2)
        for result in recorder.results {
            XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? Failure, Failure()) }
        }
    }

    // MARK: - Time-out

    func testATimeOutAnswersEveryCallerOnceAndALateAnswerIsIgnored() {
        let clock = ManualClock()
        let load = CoalescedLoad<Int>(timeout: 10, schedule: clock.schedule)
        let recorder = Recorder()
        var finish: ((Result<Int, Error>) -> Void)?
        load.load(recorder.record) { finish = $0 }
        load.load(recorder.record) { _ in XCTFail("a second load started") }
        XCTAssertEqual(clock.pending.map { $0.0 }, [10])

        clock.fireAll()
        XCTAssertEqual(recorder.results.count, 2)
        for result in recorder.results {
            XCTAssertThrowsError(try result.get()) {
                XCTAssertEqual($0 as? CoalescedLoad<Int>.TimedOut, CoalescedLoad<Int>.TimedOut(seconds: 10))
            }
        }
        XCTAssertFalse(load.isLoading)

        finish?(.success(1))
        XCTAssertEqual(recorder.results.count, 2, "the load that timed out answers nobody twice")
    }

    /// A time-out that belongs to a load already answered does nothing — not
    /// even to the next load's callers.
    func testAnOldTimeOutDoesNotAnswerTheNextLoad() {
        let clock = ManualClock()
        let load = CoalescedLoad<Int>(timeout: 10, schedule: clock.schedule)
        let first = Recorder()
        load.load(first.record) { $0(.success(1)) }
        XCTAssertEqual(first.values, [1])

        let second = Recorder()
        var finish: ((Result<Int, Error>) -> Void)?
        load.load(second.record) { finish = $0 }
        guard clock.pending.count == 2 else {
            return XCTFail("each load schedules its own time-out: \(clock.pending.count)")
        }
        let firstTimeOut = clock.pending.removeFirst()
        firstTimeOut.1()
        XCTAssertTrue(second.results.isEmpty, "the first load's time-out ended the second")
        XCTAssertTrue(load.isLoading)
        finish?(.success(2))
        XCTAssertEqual(second.values, [2])
    }

    func testNoTimeOutWhenNoneIsGiven() {
        let clock = ManualClock()
        let load = CoalescedLoad<Int>(timeout: nil, schedule: clock.schedule)
        load.load({ _ in }) { _ in }
        XCTAssertTrue(clock.pending.isEmpty)
        XCTAssertTrue(load.isLoading)
    }

    // MARK: - Once, and again

    /// Only the first answer counts, from any number of calls.
    func testALoadThatAnswersTwiceCountsOnce() {
        let load = CoalescedLoad<Int>(timeout: nil)
        let recorder = Recorder()
        load.load(recorder.record) { done in
            done(.success(1))
            done(.success(2))
            done(.failure(Failure()))
        }
        XCTAssertEqual(recorder.values, [1])
    }

    /// Once answered, the next caller starts a new load.
    func testTheNextCallerStartsANewLoad() {
        let load = CoalescedLoad<Int>(timeout: nil)
        var starts = 0
        let recorder = Recorder()
        load.load(recorder.record) { starts += 1; $0(.success(1)) }
        load.load(recorder.record) { starts += 1; $0(.success(2)) }
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(recorder.values, [1, 2])
    }

    /// From many threads at once: one load, every caller answered once.
    func testConcurrentCallersFromManyThreads() {
        let load = CoalescedLoad<Int>(timeout: nil)
        let lock = NSLock()
        var starts = 0
        var answers = 0
        var finish: ((Result<Int, Error>) -> Void)?
        let group = DispatchGroup()
        for _ in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                load.load({ _ in
                    lock.lock(); answers += 1; lock.unlock()
                }) { done in
                    lock.lock(); starts += 1; finish = done; lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        lock.lock(); let done = finish; lock.unlock()
        done?(.success(9))
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(answers, 50)
    }
}
