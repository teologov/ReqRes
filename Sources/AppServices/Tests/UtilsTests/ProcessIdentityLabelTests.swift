//
//  ProcessIdentityLabelTests.swift
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
//  The one place both modules meet. `TrafficSearchAppMatch.unknown` (Utils)
//  is the string that lets `app:unknown` select unattributed sessions, and
//  `ProcessIdentity.unknownLabel` (MCPKit) is what the App column prints for
//  them. Utils cannot import MCPKit (it would drag Sentry and Sparkle into
//  the sandboxed helper), so neither can reference the other, and this test
//  is what keeps the two words the same.
//

import XCTest
import MCPKit
@testable import Utils

final class ProcessIdentityLabelTests: XCTestCase {
    func testTheAppColumnsWordForUnknownIsTheSearchTokens() {
        XCTAssertEqual(ProcessIdentity.unknownLabel, TrafficSearchAppMatch.unknown)
    }

    /// The consequence the equality exists for: what the column prints for an
    /// unattributed row is exactly what `app:` must be given to select it.
    func testTypingTheColumnsLabelSelectsUnattributedSessions() {
        let identity = ProcessIdentity(name: nil, pid: nil, executablePath: nil)
        let label = identity.displayName ?? ProcessIdentity.unknownLabel

        XCTAssertTrue(TrafficSearchAppMatch.matches(label, appName: identity.displayName))
        XCTAssertTrue(
            TrafficSearchFilter(apps: [label]).matches(
                host: "a.com", url: "https://a.com/", method: "GET", status: "200",
                app: identity.displayName, pid: identity.pid, country: nil, outcome: nil, grpcStatus: nil, proto: nil
            )
        )
    }

    /// And a known process is selected by its display name, the same string
    /// the column shows — `SessionState` passes `processIdentity.displayName`
    /// to the filter, so the human's `app:` and the table cannot disagree.
    func testAKnownProcessIsSelectedByItsDisplayName() {
        let brave = ProcessIdentity(
            name: "Brave Browser Helper", pid: 4127,
            executablePath: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"
        )
        let filter = TrafficSearchFilter(apps: ["brave"], pids: [4127])
        XCTAssertTrue(filter.matches(host: "a.com", url: "https://a.com/", method: "GET", status: "200", app: brave.displayName, pid: brave.pid, country: nil, outcome: nil, grpcStatus: nil, proto: nil))
        XCTAssertFalse(filter.matches(host: "a.com", url: "https://a.com/", method: "GET", status: "200", app: brave.displayName, pid: 1, country: nil, outcome: nil, grpcStatus: nil, proto: nil))
    }
}
