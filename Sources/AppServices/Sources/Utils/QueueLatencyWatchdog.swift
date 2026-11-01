//
//  QueueLatencyWatchdog.swift
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
//  How long a queue takes to run a block handed to it — the time a click or
//  a keystroke would wait on the main thread. The live-rows load probe
//  (DEBUG) measures with it. Its first shape deadlocked on exit: the pinging
//  loop ran on the serial queue that also guarded the samples, and `stop()`
//  — called from a main-queue block — did `sync` on that queue while the
//  loop waited for a ping queued behind that very block (release review,
//  2026-09-29). Here the loop has its own thread, the samples a lock, and
//  `stop()` waits on nothing.
//

import Foundation

public final class QueueLatencyWatchdog: @unchecked Sendable {
    public struct Report: Equatable, Sendable {
        public var samples: Int
        public var median: Double
        public var p99: Double
        public var worst: Double
        public var over100ms: Int
        public var over250ms: Int
    }

    private let target: DispatchQueue
    private let interval: TimeInterval
    private let lock = NSLock()
    private var latencies: [Double] = []
    private var running = false

    /// `target` is the queue measured (the main queue in the app).
    public init(target: DispatchQueue = .main, interval: TimeInterval = 0.02) {
        self.target = target
        self.interval = interval
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let thread = Thread { [self] in loop() }
        thread.name = "queue-latency-watchdog"
        thread.start()
    }

    private func loop() {
        while isRunning {
            let sent = CFAbsoluteTimeGetCurrent()
            let done = DispatchSemaphore(value: 0)
            target.async { [self] in
                let latency = CFAbsoluteTimeGetCurrent() - sent
                lock.lock()
                latencies.append(latency)
                lock.unlock()
                done.signal()
            }
            done.wait()
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Stops pinging and reports what was measured. Safe to call ON the
    /// target queue with a ping outstanding: it waits for nothing. A ping
    /// still queued lands after the report and is not in it.
    public func stop() -> Report {
        lock.lock()
        running = false
        let sorted = latencies.sorted()
        lock.unlock()
        func at(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        return Report(samples: sorted.count, median: at(0.5), p99: at(0.99), worst: sorted.last ?? 0,
                      over100ms: sorted.filter { $0 > 0.1 }.count, over250ms: sorted.filter { $0 > 0.25 }.count)
    }
}
