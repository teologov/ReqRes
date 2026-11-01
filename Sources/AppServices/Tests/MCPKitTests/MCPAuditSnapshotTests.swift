//
//  MCPAuditSnapshotTests.swift
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

final class MCPAuditSnapshotTests: XCTestCase {
    private func rule(id: Int64 = 12, enabled: Bool = true) -> MCPRule {
        MCPRule(
            id: id,
            hostId: 3,
            host: "api.example.com",
            enabled: enabled,
            mode: .override,
            matchType: .wildcard,
            path: "/v1/users?*",
            method: "GET",
            scheme: "https",
            responseStatus: 500
        )
    }

    func testAnEntryWithoutASnapshotStillDecodes() throws {
        // Logs written before this field existed must survive an upgrade
        // rather than taking the user's history with them.
        let legacy = """
        {"id":"\(UUID().uuidString)","date":0,"action":{"kind":"delete_rule","summary":"Delete rule #1","details":[]},"outcome":"performed"}
        """
        let entry = try JSONDecoder().decode(MCPAuditEntry.self, from: Data(legacy.utf8))

        XCTAssertNil(entry.previousState)
        XCTAssertFalse(entry.lateDecision)
        XCTAssertFalse(entry.isReversible, "with nothing to restore it cannot be reversed")
    }

    func testSnapshotRoundTrips() throws {
        let entry = MCPAuditEntry(
            action: MCPAgentAction(kind: .deleteRule, summary: "Delete rule #12"),
            outcome: .performed,
            previousState: .rule(rule())
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(MCPAuditEntry.self, from: data)

        XCTAssertEqual(decoded.previousState, .rule(rule()))
        XCTAssertTrue(decoded.isReversible)
    }

    func testHostSnapshotRoundTrips() throws {
        let host = MCPHost(id: 3, host: "api.example.com", scheme: "https", port: 443)
        let entry = MCPAuditEntry(
            action: MCPAgentAction(kind: .removeHost, summary: "Remove api.example.com"),
            outcome: .performed,
            previousState: .host(host)
        )

        let decoded = try JSONDecoder().decode(MCPAuditEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.previousState, .host(host))
    }

    /// A creation is reversed by deleting what it made, so it needs no
    /// snapshot — but it does need the id of the row it created (`created`,
    /// added with the undo in roadmap item 13). A denied one made nothing,
    /// and an entry written before that field existed cannot say what to
    /// delete, so neither offers an undo.
    func testCreationsAreReversibleOnlyWhenTheyActuallyMadeSomethingWeCanName() {
        let performed = MCPAuditEntry(
            action: MCPAgentAction(kind: .createRule, summary: "Create a rule"),
            outcome: .performed,
            created: .rule(41)
        )
        let denied = MCPAuditEntry(
            action: MCPAgentAction(kind: .createRule, summary: "Create a rule"),
            outcome: .denied
        )
        let legacy = MCPAuditEntry(
            action: MCPAgentAction(kind: .createRule, summary: "Create a rule"),
            outcome: .performed
        )

        XCTAssertTrue(performed.isReversible)
        XCTAssertFalse(denied.isReversible)
        XCTAssertFalse(legacy.isReversible, "better no button than one that deletes the wrong rule")
    }

    /// Cleared sessions cannot be recaptured, and capture is a toggle the user
    /// owns, so neither should advertise an undo that cannot deliver.
    func testThingsThatCannotBePutBackAreNotReversible() {
        for kind in [MCPAgentAction.Kind.clearSessions, .startCapture, .stopCapture] {
            let entry = MCPAuditEntry(
                action: MCPAgentAction(kind: kind, summary: "…"),
                outcome: .performed
            )
            XCTAssertFalse(entry.isReversible, "\(kind.rawValue) should not offer an undo")
        }
    }

    func testSummaryNamesWhatWouldBePutBack() {
        XCTAssertTrue(MCPAuditSnapshot.rule(rule(enabled: false)).summary.contains("disabled"))
        XCTAssertTrue(MCPAuditSnapshot.rule(rule()).summary.contains("/v1/users?*"))
        XCTAssertTrue(
            MCPAuditSnapshot.host(MCPHost(id: 1, host: "api.example.com", scheme: "https", port: 443))
                .summary.contains("api.example.com")
        )
    }
}
