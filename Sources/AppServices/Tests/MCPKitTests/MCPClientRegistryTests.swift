//
//  MCPClientRegistryTests.swift
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
@testable import MCPKit

final class MCPClientRegistryTests: XCTestCase {
    /// A clock the test drives, so "90 seconds later" costs nothing.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    private func makeRegistry() -> (MCPClientRegistry, Clock) {
        let clock = Clock()
        return (MCPClientRegistry(now: { clock.now }), clock)
    }

    func testRecordsAnIdentifiedClient() {
        let (registry, _) = makeRegistry()
        let client = registry.record(header: "name=Claude Code; id=41207; version=0.2.0")

        XCTAssertEqual(client?.name, "Claude Code")
        XCTAssertEqual(client?.id, "41207")
        XCTAssertEqual(client?.version, "0.2.0")
        XCTAssertEqual(registry.activeClients().count, 1)
    }

    /// Anything holding the token can call the bridge. Inventing an anonymous
    /// row for it would put a number in the UI the user cannot explain.
    func testUnidentifiedRequestsAreNotCounted() {
        let (registry, _) = makeRegistry()

        XCTAssertNil(registry.record(header: nil))
        XCTAssertNil(registry.record(header: ""))
        XCTAssertNil(registry.record(header: "garbage"))
        XCTAssertNil(registry.record(header: "name=Claude Code"))   // no id
        XCTAssertNil(registry.record(header: "id=1"))               // no name
        XCTAssertTrue(registry.activeClients().isEmpty)
    }

    func testRepeatRequestsRefreshRatherThanDuplicate() {
        let (registry, clock) = makeRegistry()
        registry.record(header: "name=Cursor; id=900")
        let first = registry.activeClients().first?.lastSeen

        clock.advance(30)
        registry.record(header: "name=Cursor; id=900")
        let clients = registry.activeClients()

        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.firstSeen, first)
        XCTAssertEqual(clients.first?.lastSeen, clock.now)
    }

    /// Two editor windows are two clients: the id is the helper's pid.
    func testSameNameDifferentProcessesAreSeparateClients() {
        let (registry, _) = makeRegistry()
        registry.record(header: "name=Cursor; id=900")
        registry.record(header: "name=Cursor; id=901")

        XCTAssertEqual(registry.activeClients().count, 2)
    }

    func testAClientGoesQuietAfterTheActiveWindow() {
        let (registry, clock) = makeRegistry()
        registry.record(header: "name=Claude Code; id=1")

        clock.advance(MCPClientRegistry.activeWindow - 1)
        XCTAssertEqual(registry.activeClients().count, 1, "still within the window")

        clock.advance(2)
        XCTAssertTrue(registry.activeClients().isEmpty, "past the window it should disappear")
    }

    func testMostRecentlyActiveComesFirst() {
        let (registry, clock) = makeRegistry()
        registry.record(header: "name=Claude Code; id=1")
        clock.advance(5)
        registry.record(header: "name=Cursor; id=2")

        XCTAssertEqual(registry.activeClients().map(\.name), ["Cursor", "Claude Code"])
    }

    func testResetForgetsEveryone() {
        let (registry, _) = makeRegistry()
        registry.record(header: "name=Claude Code; id=1")
        registry.reset()

        XCTAssertTrue(registry.activeClients().isEmpty)
    }

    /// The header comes from outside the app and lands in a sidebar label.
    func testHostileNamesAreTrimmedAndFlattened() {
        let (registry, _) = makeRegistry()
        let long = String(repeating: "A", count: 200)
        registry.record(header: "name=\(long); id=7")
        guard let client = registry.activeClients().first else { return XCTFail("not recorded") }

        XCTAssertEqual(client.name.count, 48)

        registry.reset()
        registry.record(header: "name=Evil\nClient; id=8")
        XCTAssertEqual(registry.activeClients().first?.name, "Evil Client")
    }

    func testParsingIsForgivingAboutSpacingAndCase() {
        let parsed = MCPClientRegistry.parse("  NAME = Claude Code ;  ID =41207;version= 0.2.0 ")
        XCTAssertEqual(parsed?.name, "Claude Code")
        XCTAssertEqual(parsed?.id, "41207")
        XCTAssertEqual(parsed?.version, "0.2.0")
    }

    func testIdentityHeaderRoundTrips() {
        let header = MCPBridgeClient.identityHeader(version: "1.2.3", pid: 55, parentName: "Claude Code", parentPID: 41180)
        let parsed = MCPClientRegistry.parse(header)

        XCTAssertEqual(parsed?.name, "Claude Code")
        XCTAssertEqual(parsed?.id, "55")
        XCTAssertEqual(parsed?.version, "1.2.3")
        XCTAssertEqual(parsed?.processID, 41180)
    }

    /// A helper that cannot read its parent still identifies itself, otherwise
    /// it would vanish from the UI entirely.
    func testIdentityFallsBackWhenTheParentIsUnknown() {
        let header = MCPBridgeClient.identityHeader(version: "1.0", pid: 9, parentName: nil)
        XCTAssertEqual(MCPClientRegistry.parse(header)?.name, "MCP client")
    }

    // MARK: - The client's own pid (UX spec §8.1)

    /// The header names the helper's PARENT pid — the MCP client itself. That
    /// is the pid a CLI agent's captured requests carry, so it is what lets
    /// the app mark an agent's own traffic and offer "Show its traffic".
    func testTheIdentityHeaderCarriesTheParentPid() {
        let header = MCPBridgeClient.identityHeader(version: "1.0", pid: 55, parentName: "claude", parentPID: 9437)
        XCTAssertTrue(header.hasSuffix("; ppid=9437"), header)
        XCTAssertEqual(header, "name=claude; id=55; version=1.0; ppid=9437")
    }

    /// Left to its default, the header reports THIS process's real parent —
    /// whatever spawned the test runner — not a placeholder.
    func testTheDefaultParentPidIsTheRealOne() {
        let header = MCPBridgeClient.identityHeader(version: "1.0", pid: 55, parentName: "x")
        XCTAssertEqual(MCPClientRegistry.parse(header)?.processID, Int(getppid()))
    }

    func testARecordedClientKeepsItsProcessID() {
        let (registry, _) = makeRegistry()
        let client = registry.record(header: "name=Claude Code; id=41207; version=0.2.0; ppid=41180")

        XCTAssertEqual(client?.processID, 41180)
        XCTAssertEqual(registry.activeClients().first?.processID, 41180)
    }

    /// An older helper sends no ppid; a client without one is still a client.
    func testAHeaderWithoutAPpidIsRecordedWithNoProcessID() {
        let (registry, _) = makeRegistry()
        let client = registry.record(header: "name=Claude Code; id=41207; version=0.2.0")

        XCTAssertNotNil(client)
        XCTAssertNil(client?.processID)
    }

    /// The pid is matched against captured sessions' pids, so anything that is
    /// not a positive integer is dropped — never coerced, never a label.
    func testAPpidThatIsNotAPidIsDropped() {
        for hostile in ["curl", "-1", "+5", "0", "12abc", "9437 9438", "", String(repeating: "9", count: 60)] {
            let parsed = MCPClientRegistry.parse("name=X; id=1; ppid=\(hostile)")
            XCTAssertNotNil(parsed, "the rest of the header is still fine for '\(hostile)'")
            XCTAssertNil(parsed?.processID, "'\(hostile)' is not a process id")
        }
        XCTAssertEqual(MCPClientRegistry.parse("name=X; id=1; ppid= 42 ")?.processID, 42, "whitespace is trimmed like every other field")
    }
}
