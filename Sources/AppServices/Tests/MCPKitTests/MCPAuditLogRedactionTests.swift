//
//  MCPAuditLogRedactionTests.swift
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
//  An activity-log entry as the log keeps it (`MCPRedactor.redactLogEntry`):
//  the one treatment the router gives an entry it records and the app gives
//  every entry it loads (F15 and its review). Build 51 persisted an answered
//  held request's URL raw in the result line, and the log is read back at
//  every launch — so the treatment must clean such a row, keep a failure's
//  words, leave the undo snapshot alone, and change nothing the second time.
//

import XCTest
@testable import MCPKit

final class MCPAuditLogRedactionTests: XCTestCase {
    private let redactor = MCPRedactor()
    /// Short and plain: only redaction by the parameter's NAME catches it.
    private let token = "short-secret-42"
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghij"

    private func entry(
        _ outcome: MCPAuditOutcome,
        detail: String?,
        summary: String = "Answer a held request",
        details: [String] = []
    ) -> MCPAuditEntry {
        MCPAuditEntry(
            action: MCPAgentAction(kind: .answerPausedRequest, summary: summary, details: details),
            outcome: outcome,
            detail: detail
        )
    }

    // MARK: - The result line

    /// A result is the router's own rendering and gets the action's
    /// treatment: URL tokens by parameter name, "Name: value" by name.
    func testAResultLineGetsTheActionsTreatment() {
        let resumed = redactor.redactLogEntry(entry(.performed,
            detail: "Resumed GET https://api.example.com/v1/orders?access_token=\(token)&page=2 untouched."))
        XCTAssertEqual(resumed.detail, "Resumed GET https://api.example.com/v1/orders?access_token=REDACTED&page=2 untouched.")

        let named = redactor.redactLogEntry(entry(.performed, detail: "Headers set — X-Api-Key: live-9912"))
        XCTAssertEqual(named.detail, "Headers set — X-Api-Key: \(MCPRedactor.placeholder)")
    }

    /// A reason is a sentence from a seam, not a "Name: value" rendering, and
    /// the name pass read the last word before its colon as a field name.
    /// URL tokens still go, on every outcome that carries a reason.
    func testAReasonKeepsItsWordsAndLosesItsURLTokens() {
        let locked = "Could not save the session: The database is locked."
        XCTAssertEqual(redactor.redactLogEntry(entry(.failed, detail: locked)).detail, locked)

        for outcome in [MCPAuditOutcome.failed, .denied, .timedOut] {
            let logged = redactor.redactLogEntry(entry(outcome,
                detail: "https://api.example.com/v1/orders?token=\(token) could not be resumed."))
            XCTAssertEqual(logged.detail, "https://api.example.com/v1/orders?token=REDACTED could not be resumed.", "\(outcome)")
        }
    }

    // MARK: - What it leaves alone

    /// An undo writes the snapshot back into live traffic, where a
    /// placeholder would go in as if it were a credential — so the log keeps
    /// the real values there, and Export… redacts them on the way to a file.
    func testTheSnapshotAndTheEntrysIdentityAreKept() {
        let rule = MCPRule(
            id: 12, hostId: 3, host: "api.example.com", enabled: true, mode: .extend, matchType: .wildcard,
            path: "/v1/*", method: "", scheme: "https",
            requestHeaders: ["Authorization": "Bearer real-credential-value"]
        )
        let original = MCPAuditEntry(
            action: MCPAgentAction(kind: .updateRule, summary: "Change rule #12",
                                   details: ["Sets request headers — Authorization: Bearer agent-value"]),
            outcome: .performed,
            detail: "rule #12",
            lateDecision: true,
            previousState: .rule(rule),
            created: .rule(12),
            byUser: false
        )

        let logged = redactor.redactLogEntry(original)

        XCTAssertEqual(logged.previousState, .rule(rule), "the real value is what an undo restores")
        XCTAssertEqual(logged.id, original.id)
        XCTAssertEqual(logged.date, original.date)
        XCTAssertEqual(logged.created, .rule(12))
        XCTAssertEqual(logged.lateDecision, true)
        XCTAssertEqual(logged.rulesMatchMethod, original.rulesMatchMethod)
        XCTAssertEqual(logged.detail, "rule #12")
        XCTAssertFalse(logged.action.details.joined().contains("agent-value"), "the action is redacted: \(logged.action.details)")
    }

    func testAnEntryWithNothingToHideIsUnchanged() {
        let plain = entry(.performed, detail: "host #5 api.example.com",
                          summary: "Add the host filter api.example.com (https)", details: ["Port: 443"])
        XCTAssertEqual(redactor.redactLogEntry(plain), plain)
    }

    func testRedactionSwitchedOffLeavesTheEntryAlone() {
        let raw = entry(.performed, detail: "Resumed GET https://api.example.com/x?access_token=\(token) untouched.")
        XCTAssertEqual(MCPRedactor(enabled: false).redactLogEntry(raw), raw)
    }

    // MARK: - Run again at every launch

    /// The app applies this to the whole log each time it loads it, so a
    /// second pass must give the first pass's text. One case needed a fix:
    /// the shape pass puts the placeholder inside a URL — where a JWT sat in
    /// a path or an ordinary parameter — and `URLComponents`, reading that URL
    /// again, wrote it back percent-encoded (`%C2%ABredacted%C2%BB`).
    func testASecondPassChangesNothing() {
        let lines: [(MCPAuditOutcome, String)] = [
            (.performed, "Resumed GET https://api.example.com/v1/orders?access_token=\(token)&page=2 untouched."),
            (.performed, "Resumed GET https://api.example.com/magic/\(jwt)/confirm with edited headers."),
            (.performed, "Resumed GET https://api.example.com/cb?state=\(jwt)&page=2 untouched."),
            (.performed, "Aborted DELETE https://api.example.com/keys/ghp_abcdefghijklmnop/revoke with 409 — it never reached the server."),
            (.performed, "Headers set — X-Api-Key: live-9912 · Accept: application/json"),
            (.failed, "https://user:pass@api.example.com/x?token=\(token) could not be resumed."),
            (.failed, "Could not save the session: The database is locked."),
            (.denied, "The user declined."),
        ]
        for (outcome, line) in lines {
            let original = entry(outcome, detail: line,
                                 summary: "Resume POST https://api.example.com/cb?state=\(jwt)",
                                 details: ["Held request — POST https://api.example.com/v1/orders?access_token=\(token)",
                                           "Headers set — Authorization: Bearer agent-value"])
            let once = redactor.redactLogEntry(original)
            XCTAssertEqual(redactor.redactLogEntry(once), once, line)
            XCTAssertFalse(once.detail?.contains("%C2%AB") ?? false, once.detail ?? "")
        }
    }

    /// The row build 51 left on a test Mac, as it decodes from
    /// UserDefaults: the action already redacted, the result line raw. After
    /// the load-time pass neither the row nor anything exported from it
    /// holds the token.
    func testARowAnEarlierBuildPersistedIsCleaned() throws {
        let persisted = #"""
        {"id":"8D0B2F4A-1C3E-4F5A-9B6D-7E8F9A0B1C2D","date":"2026-09-30T10:12:00Z",
         "action":{"kind":"answer_paused_request","summary":"Resumed GET https://httpbin.org/get?access_token=REDACTED&page=2 untouched.","details":["Held request — GET https://httpbin.org/get?access_token=REDACTED&page=2","Sent on unchanged"]},
         "outcome":"performed",
         "detail":"Resumed GET https://httpbin.org/get?access_token=VERIFYtok3n42&page=2 untouched.",
         "lateDecision":false,"undone":false,"byUser":false,"rulesMatchMethod":true}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(MCPAuditEntry.self, from: Data(persisted.utf8))
        XCTAssertTrue(row.detail?.contains("VERIFYtok3n42") ?? false, "the fixture is the leaked row")

        let cleaned = redactor.redactLogEntry(row)

        XCTAssertEqual(cleaned.detail, "Resumed GET https://httpbin.org/get?access_token=REDACTED&page=2 untouched.")
        XCTAssertEqual(cleaned.action, row.action, "already redacted when it was recorded")
        XCTAssertEqual(cleaned.id, row.id)
        for export in [MCPAuditExport.text([cleaned]), MCPAuditExport.json([cleaned])] {
            XCTAssertFalse(export.content.contains("VERIFYtok3n42"), export.content)
        }
    }
}
