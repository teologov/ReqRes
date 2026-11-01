//
//  StreamTimingIncrementalTests.swift
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
@testable import MCPKit

/// `StreamEventLog.timing` is kept up to date as events arrive, not
/// recomputed from every event on each read: a live stream's pane read it
/// twice per refresh, which made following a long stream quadratic
/// (release review, 2026-09-29).
final class StreamTimingIncrementalTests: XCTestCase {
    /// 1,400 chunks of 25 events each (35,000 events, ~4 MB of NDJSON) with
    /// `timing` read after every chunk — what the live pane does.
    func testReadingTimingAfterEveryChunkStaysLinear() {
        var log = StreamEventLog(format: .ndjson)
        let line = #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello world, this is a token"}}"# + "\n"
        let chunk = String(repeating: line, count: 25)
        let start = Date()
        var timed = 0
        for index in 0..<1_400 {
            log.append(text: chunk, receivedAt: Double(index) * 0.05)
            timed = log.timing.timedEvents
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(timed, 35_000)
        XCTAssertLessThan(elapsed, 1.0, "\(elapsed) s for 1,400 chunks")
    }

    /// Whatever order timed and untimed events come in, the running answer
    /// is `StreamTiming.of` over the same events.
    func testTheRunningTimingEqualsTheWholeWalk() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            var log = StreamEventLog(format: .ndjson)
            for _ in 0..<Int.random(in: 1...40, using: &generator) {
                let at: TimeInterval? = Bool.random(using: &generator) ? Double.random(in: 0...10, using: &generator) : nil
                let lines = Int.random(in: 0...3, using: &generator)
                log.append(text: String(repeating: "{\"a\":1}\n", count: lines) + (Bool.random(using: &generator) ? "{\"b\"" : ""), receivedAt: at)
                XCTAssertEqual(log.timing, StreamTiming.of(log.events))
            }
        }
    }
}
