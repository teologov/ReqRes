//
//  CoalescedLoad.swift
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

import Foundation

/// One load at a time, answered to everyone who asked while it ran — exactly
/// once each, whether it succeeded, failed or ran out of time.
///
/// Written for loading the capture tunnel's configuration (`VPNManager`,
/// F11): that load used to call back ONLY on success, so a failure left every
/// caller waiting forever — among them a status check suspended on a
/// continuation that was never resumed — and the checks that overlap at
/// launch each started a load of their own.
public final class CoalescedLoad<Value> {
    public typealias Completion = (Result<Value, Error>) -> Void

    /// The load did not answer in time.
    public struct TimedOut: LocalizedError, Equatable {
        public let seconds: TimeInterval
        public var errorDescription: String? {
            "The system did not answer within \(Int(seconds.rounded())) seconds."
        }
    }

    private let lock = NSLock()
    private var waiting: [Completion] = []
    /// The load under way, by number, so an answer or a time-out that
    /// belongs to an earlier one is ignored.
    private var inFlight: Int?
    private var loads = 0
    private let timeout: TimeInterval?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    /// `timeout` nil waits for the load however long it takes — for a load
    /// that may be waiting on a person (macOS asking to add a configuration).
    /// `schedule` runs the time-out; tests pass one they control.
    public init(
        timeout: TimeInterval?,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = CoalescedLoad.afterDelay
    ) {
        self.timeout = timeout
        self.schedule = schedule
    }

    public static func afterDelay(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Whether a load is under way.
    public var isLoading: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight != nil
    }

    /// Adds `completion` to the callers of the load under way, or starts one
    /// with `start`, which must call its argument when the load ends — from
    /// any thread; only its first call counts, and only if no time-out came
    /// first. Completions run on the thread that ends the load, never under
    /// the lock.
    public func load(_ completion: @escaping Completion, start: (@escaping Completion) -> Void) {
        lock.lock()
        waiting.append(completion)
        guard inFlight == nil else {
            lock.unlock()
            return
        }
        loads += 1
        let current = loads
        inFlight = current
        lock.unlock()

        if let timeout {
            schedule(timeout) { [weak self] in
                self?.finish(current, .failure(TimedOut(seconds: timeout)))
            }
        }
        start { [weak self] result in
            self?.finish(current, result)
        }
    }

    private func finish(_ load: Int, _ result: Result<Value, Error>) {
        lock.lock()
        guard inFlight == load else {
            lock.unlock()
            return
        }
        inFlight = nil
        let answered = waiting
        waiting = []
        lock.unlock()
        for completion in answered { completion(result) }
    }
}
