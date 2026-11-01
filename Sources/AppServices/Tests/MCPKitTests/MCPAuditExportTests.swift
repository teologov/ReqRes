//
//  MCPAuditExportTests.swift
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

final class MCPAuditExportTests: XCTestCase {
    private func rule(id: Int64 = 12, requestHeaders: [String: String] = [:], responseBody: String? = nil) -> MCPRule {
        MCPRule(
            id: id, hostId: 3, host: "api.example.com", enabled: true, mode: .override, matchType: .wildcard,
            path: "/v1/users?*", method: "GET", scheme: "https", requestHeaders: requestHeaders,
            responseStatus: 200, responseBody: responseBody
        )
    }

    private func entry(
        id: UUID = UUID(),
        date: Date,
        kind: MCPAgentAction.Kind = .updateRule,
        summary: String = "Change rule #12",
        details: [String] = [],
        detail: String? = "rule #12",
        previousState: MCPAuditSnapshot? = nil
    ) -> MCPAuditEntry {
        MCPAuditEntry(
            id: id, date: date, action: MCPAgentAction(kind: kind, summary: summary, details: details),
            outcome: .performed, detail: detail, previousState: previousState
        )
    }

    // MARK: - The whole point of the file

    /// This is the exact shape of the risk the file exists to close: a rule
    /// an agent changed carries the REAL header it was extending requests
    /// with (see MCPAuditEntry.previousState's own doc comment), and both
    /// export forms must mask it just as the write surface already does for
    /// an agent reading the rule live.
    func testCredentialHeaderInASnapshotIsMaskedInBothForms() throws {
        let secret = rule(requestHeaders: ["Authorization": "Bearer live-session-token"])
        let log = [entry(date: Date(timeIntervalSince1970: 1), previousState: .rule(secret))]

        let text = MCPAuditExport.text(log).content
        XCTAssertFalse(text.contains("live-session-token"))
        XCTAssertTrue(text.contains(MCPRedactor.placeholder))

        let json = MCPAuditExport.json(log).content
        XCTAssertFalse(json.contains("live-session-token"))
        XCTAssertTrue(json.contains(MCPRedactor.placeholder))
        let decodedEntry = try decodedEntries(from: json)[0]
        guard let previousState = decodedEntry.previousState, case .rule(let decodedRule) = previousState else {
            return XCTFail("expected a rule snapshot to round-trip")
        }
        XCTAssertEqual(decodedRule.requestHeaders["Authorization"], MCPRedactor.placeholder)
    }

    /// The approval-sheet detail lines quote raw values too (a body preview,
    /// a header a rule is about to inject) — MCPBridgeRouter.details(_:)
    /// builds them from the unredacted draft. A JWT is used here because its
    /// match does not depend on the entropy heuristic that only runs in
    /// "aggressive" mode, so this proves the aggressive path is actually
    /// being taken, not just the cheap always-on one.
    func testFreeTextDetailsAndSummaryAreRedacted() throws {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let log = [entry(
            date: Date(timeIntervalSince1970: 1),
            summary: "Create an override rule for api.example.com: GET /users?* → 200",
            details: ["Sets request headers — X-Session: \(jwt)"],
            detail: "rule #7 (token \(jwt))"
        )]

        for content in [MCPAuditExport.text(log).content, MCPAuditExport.json(log).content] {
            XCTAssertFalse(content.contains(jwt))
        }
    }

    /// A disabled redactor is an explicit, deliberate choice by whoever calls
    /// this file (MCPRedactor's own `enabled` flag), not a way to bypass it —
    /// this only proves the exporter actually consults the flag it was
    /// handed rather than always redacting or never redacting.
    func testADisabledRedactorIsHonoured() {
        let secret = rule(requestHeaders: ["Authorization": "Bearer live-session-token"])
        let log = [entry(date: Date(timeIntervalSince1970: 1), previousState: .rule(secret))]

        let result = MCPAuditExport.text(log, redactor: MCPRedactor(enabled: false))
        XCTAssertTrue(result.content.contains("live-session-token"))
        XCTAssertFalse(result.redacted)
    }

    // MARK: - Determinism

    /// Two exports of the SAME log, handed in different orders (as a caller
    /// reading from a store makes no promises about), must be byte-identical
    /// — this is what would fail if entries were rendered in input order
    /// instead of being sorted first.
    func testOrderingIsDeterministicRegardlessOfInputOrder() {
        let log = (0..<5).map { entry(date: Date(timeIntervalSince1970: Double($0)), detail: "rule #\($0)") }

        // The export stamps when it was made, so the clock is pinned here:
        // what is being asserted is that ENTRY ORDER does not depend on input
        // order, not that two exports taken seconds apart are identical.
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let inOrder = MCPAuditExport.text(log, exportedAt: exportedAt)
        let shuffled = MCPAuditExport.text(log.shuffled(), exportedAt: exportedAt)
        XCTAssertEqual(inOrder.content, shuffled.content)

        let jsonInOrder = MCPAuditExport.json(log, exportedAt: exportedAt)
        let jsonShuffled = MCPAuditExport.json(log.shuffled(), exportedAt: exportedAt)
        XCTAssertEqual(jsonInOrder.content, jsonShuffled.content)
    }

    // MARK: - Truncation

    /// Over budget, the OLDEST entries are the ones cut — an agent's most
    /// recent actions are what a reviewer still cares about — and the
    /// truncation is reported on `Result`, not just buried in the text.
    func testTruncationDropsOldestFirstAndReportsItself() throws {
        let log = (0..<10).map { entry(date: Date(timeIntervalSince1970: Double($0)), detail: "rule #\($0)") }

        let text = MCPAuditExport.text(log, maxEntries: 3)
        XCTAssertTrue(text.truncated)
        XCTAssertEqual(text.includedCount, 3)
        XCTAssertEqual(text.totalCount, 10)
        XCTAssertFalse(text.content.contains("rule #0"), "the oldest entry should have been dropped")
        XCTAssertFalse(text.content.contains("rule #6"), "still outside the newest 3")
        XCTAssertTrue(text.content.contains("rule #9"), "the newest entry must survive the cap")

        let json = MCPAuditExport.json(log, maxEntries: 3)
        XCTAssertTrue(json.truncated)
        XCTAssertEqual(json.includedCount, 3)
        XCTAssertEqual(json.totalCount, 10)
        let decoded = try decodedEntries(from: json.content)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.compactMap(\.detail), ["rule #7", "rule #8", "rule #9"])
    }

    // MARK: - Empty log

    func testAnEmptyLogProducesValidNonEmptyOutput() throws {
        let text = MCPAuditExport.text([])
        XCTAssertFalse(text.content.isEmpty)
        XCTAssertFalse(text.truncated)
        XCTAssertEqual(text.includedCount, 0)

        let json = MCPAuditExport.json([])
        XCTAssertFalse(json.content.isEmpty)
        let decoded = try decodedEntries(from: json.content)
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - JSON round-trip

    func testJSONFormRoundTrips() throws {
        let log = [
            entry(date: Date(timeIntervalSince1970: 1), kind: .createRule, summary: "Create a rule", detail: "rule #1"),
            entry(date: Date(timeIntervalSince1970: 2), kind: .deleteRule, summary: "Delete rule #1", detail: "rule #1"),
        ]

        let result = MCPAuditExport.json(log)
        let decoded = try decodedEntries(from: result.content)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].action.kind, .createRule)
        XCTAssertEqual(decoded[1].action.kind, .deleteRule)

        // The envelope's own bookkeeping fields must survive the round trip too.
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]
        )
        XCTAssertEqual(envelope["redacted"] as? Bool, true)
        XCTAssertEqual(envelope["truncated"] as? Bool, false)
        XCTAssertEqual(envelope["totalCount"] as? Int, 2)
    }

    // MARK: - Helpers

    private struct DecodedEnvelope: Decodable {
        let entries: [MCPAuditEntry]
    }

    private func decodedEntries(from json: String) throws -> [MCPAuditEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(DecodedEnvelope.self, from: Data(json.utf8))
        return envelope.entries
    }
}

/// The approval-sheet strings an export carries are not prose: the consent
/// layer renders them as "Name: value" so a human can see what a rule would
/// inject. Shape-based redaction cannot see a short credential in one of
/// those ("Cookie: sid=42" has no shape at all), so the exporter reads the
/// name — and these pin that it reads it in every arrangement the consent
/// layer actually produces.
final class MCPAuditExportNamedValueTests: XCTestCase {
    private func exportedText(details: [String]) -> String {
        let entry = MCPAuditEntry(
            action: MCPAgentAction(kind: .createRule, summary: "Create a rule", details: details),
            outcome: .performed
        )
        return MCPAuditExport.text([entry], exportedAt: Date(timeIntervalSince1970: 1_700_000_000)).content
    }

    func testAShortCredentialInAHeaderLineIsRedacted() {
        let text = exportedText(details: ["Sets request headers — Authorization: Bearer hunter2 ⚠️"])

        XCTAssertFalse(text.contains("hunter2"), "a value shape-detection cannot see must still be caught by its name")
        XCTAssertTrue(text.contains("Authorization: \(MCPRedactor.placeholder)"),
                      "the name stays so the reader knows what was hidden")
    }

    /// The mock_from_session line puts a captured header after a prose colon;
    /// splitting on the FIRST colon would leave the real value in the file.
    func testASecondColonOnTheLineIsStillFound() {
        let text = exportedText(details: ["Headers set: Set-Cookie: sid=42"])

        XCTAssertFalse(text.contains("sid=42"))
        XCTAssertTrue(text.contains("Headers set: Set-Cookie: \(MCPRedactor.placeholder)"))
    }

    func testOtherHeadersOnTheSameLineSurvive() {
        let text = exportedText(details: ["Sets request headers — Accept: application/json · Cookie: sid=42"])

        XCTAssertTrue(text.contains("Accept: application/json"), "a harmless header is still worth reading")
        XCTAssertFalse(text.contains("sid=42"))
    }

    /// A value carrying the separator splits into segments that no longer look
    /// like a pair. Those continuations are dropped rather than half-leaked.
    func testAValueContainingTheSeparatorDoesNotLeakItsTail() {
        let text = exportedText(details: ["Cookie: a=1 · b=2 · Accept: text/plain"])

        XCTAssertFalse(text.contains("b=2"))
        XCTAssertTrue(text.contains("Accept: text/plain"), "a real pair after it ends the continuation")
    }

    func testProseIsLeftAlone() {
        let text = exportedText(details: ["Response body (12 bytes): {\"ok\":true}", "Match: wildcard · https"])

        XCTAssertTrue(text.contains(#"{"ok":true}"#), "a body preview is not a credential-named field")
        XCTAssertTrue(text.contains("Match: wildcard · https"))
    }
}
