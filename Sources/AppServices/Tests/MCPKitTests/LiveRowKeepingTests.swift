//
//  LiveRowKeepingTests.swift
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

/// A live row is never kept as a finished exchange — not by save_session,
/// not by mock_from_session, not by the window's Save on a mixed selection
/// (release review, 2026-09-29).
final class LiveRowKeepingTests: XCTestCase {
    func testAFinishedRowIsKept() {
        XCTAssertNil(LiveRowKeeping.refusal(uid: "u", live: nil, purpose: "save it"))
    }

    func testAnInFlightRowIsRefused() throws {
        let text = try XCTUnwrap(LiveRowKeeping.refusal(uid: "u", live: MCPLiveState(phase: .streaming), purpose: "save it"))
        XCTAssertTrue(text.contains("still in flight"), text)
        XCTAssertTrue(text.contains("save it"), text)
    }

    /// The case the old `isInFlight` guard missed: the row left `inFlight`
    /// when capture stopped, but it is still the start snapshot.
    func testARowThatEndedWithoutItsFinalRowIsRefused() throws {
        for reason in LiveEndReason.allCases {
            let live = MCPLiveState(phase: .ended, endReason: reason)
            XCTAssertFalse(live.isInFlight)
            let text = try XCTUnwrap(LiveRowKeeping.refusal(uid: "u", live: live, purpose: "mock it"), "\(reason)")
            XCTAssertTrue(text.contains("never finished"), text)
        }
    }

    func testAMixedSelectionKeepsOnlyTheFinishedRowsInOrder() {
        let rows = ["done-1", "live", "ended", "done-2"]
        let live: Set<String> = ["live", "ended"]
        XCTAssertEqual(LiveRowKeeping.finished(rows) { live.contains($0) }, ["done-1", "done-2"])
        XCTAssertEqual(LiveRowKeeping.finished(["live"]) { live.contains($0) }, [])
    }
}
