//
//  MCPSavedSessionTests.swift
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
//  The agent surface for saved sessions (1.1.0).
//
//  The load-bearing test in this file is `testASavedSessionCannotLaunderA
//  Credential`: the store keeps the REAL exchange, so if the read path ever
//  stops redacting, save_session + get_saved_session becomes a two-call route
//  around the read surface's redaction. The stub below therefore stores
//  unredacted material on purpose — a stub that pre-redacted would make that
//  test pass no matter what the router did.
//

import XCTest
@testable import MCPKit

/// In-memory saved-session store. Holds the exchange exactly as captured,
/// like the core's does.
final class StubSavedSessionStore: MCPSavedSessionProviding {
    /// Newest-saved last; the seam is responsible for the ordering it promises.
    var stored: [MCPSavedSession] = []
    /// What the current capture run holds, by uid — the same details the
    /// router's session provider is given, so the two cannot disagree about
    /// which uid exists.
    var live: [String: MCPSessionDetail] = [:]
    var saveError: MCPWriteError?
    var deleteError: MCPWriteError?
    var requestedLimits: [Int] = []
    var savedRequests: [(uid: String, note: String?)] = []
    var deletedIds: [Int64] = []

    private var nextId: Int64 = 1
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    func savedSessions(limit: Int) throws -> MCPSavedSessionPage {
        requestedLimits.append(limit)
        let newestFirst = stored.sorted { $0.savedAt > $1.savedAt }
        return MCPSavedSessionPage(
            saved: newestFirst.prefix(limit).map(Self.summary),
            totalCount: stored.count
        )
    }

    func savedSession(id: Int64) throws -> MCPSavedSession? {
        stored.first { $0.id == id }
    }

    func saveSession(uid: String, note: String?) throws -> MCPSavedSessionSummary {
        if let saveError { throw saveError }
        savedRequests.append((uid, note))
        guard let detail = live[uid] else {
            throw MCPWriteError.notFound("No session with uid \(uid) in the current capture run.")
        }
        clock.addTimeInterval(60)
        let saved = MCPSavedSession(id: nextId, savedAt: clock, note: note, session: detail)
        nextId += 1
        stored.append(saved)
        return Self.summary(saved)
    }

    func deleteSavedSession(id: Int64) throws {
        if let deleteError { throw deleteError }
        guard stored.contains(where: { $0.id == id }) else {
            throw MCPWriteError.notFound("No saved session with id \(id).")
        }
        deletedIds.append(id)
        stored.removeAll { $0.id == id }
    }

    static func summary(_ saved: MCPSavedSession) -> MCPSavedSessionSummary {
        MCPSavedSessionSummary(id: saved.id, savedAt: saved.savedAt, note: saved.note, session: saved.session.summary)
    }
}

final class MCPSavedSessionTests: XCTestCase {
    private let token = "test-token"
    private var consent: StubConsent!
    private var audit: StubAudit!
    private var store: StubSavedSessionStore!

    override func setUp() {
        super.setUp()
        consent = StubConsent()
        audit = StubAudit()
        store = StubSavedSessionStore()
    }

    // MARK: - Fixtures

    /// A captured exchange carrying material that MUST NOT survive egress: a
    /// bearer header, a token in the query string, and a refresh token in the
    /// response body.
    private func detail(uid: String, host: String = "api.example.com") -> MCPSessionDetail {
        MCPSessionDetail(
            summary: makeSession(uid: uid, host: host, url: "https://\(host)/v1/users?access_token=live-secret-9912"),
            requestHeaders: ["Authorization": "Bearer super-secret-token-value", "Accept": "application/json"],
            responseHeaders: ["Content-Type": "application/json"],
            responseBodyPreview: #"{"refresh_token":"rt-secret-42","name":"Ada"}"#,
            curl: "curl -H 'Authorization: Bearer super-secret-token-value' https://\(host)/v1/users"
        )
    }

    /// Wires one set of details into BOTH the live session provider and the
    /// saved store, so a uid the router can resolve is a uid the seam can save.
    private func makeRouter(live: [MCPSessionDetail] = [], wireStore: Bool = true) -> MCPBridgeRouter {
        store.live = Dictionary(uniqueKeysWithValues: live.map { ($0.summary.uid, $0) })
        let sessions = StubSessionProvider(
            summaries: live.map(\.summary),
            details: store.live
        )
        return MCPBridgeRouter(
            token: token,
            sessions: sessions,
            status: StubStatusProvider(),
            writes: MCPWriteSeams(
                rules: StubRuleProvider(),
                hosts: StubHostProvider(),
                capture: StubCaptureController(),
                consent: consent,
                audit: audit,
                savedSessions: wireStore ? store : nil
            )
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func call(_ router: MCPBridgeRouter, _ method: String, _ target: String, body: [String: Any]? = nil) throws -> ParsedResponse {
        var request = makeRequest(method: method, target: target, token: token)
        if let body {
            request.body = try JSONSerialization.data(withJSONObject: body)
            request.headers["content-type"] = "application/json"
        }
        return try XCTUnwrap(parseRawResponse(router.respond(to: request)))
    }

    /// Puts one row in the store without going through the route under test.
    @discardableResult
    private func preload(_ detail: MCPSessionDetail, note: String? = nil) throws -> Int64 {
        store.live[detail.summary.uid] = detail
        return try store.saveSession(uid: detail.summary.uid, note: note).id
    }

    // MARK: - save_session

    func testSavingAKeptSessionReportsItsDurableId() throws {
        let router = makeRouter(live: [detail(uid: "s1")])

        let response = try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s1", "note": "the 401 loop"])
        XCTAssertEqual(response.status, 201)

        let saved = try Self.decoder.decode(MCPSavedSessionSummary.self, from: response.body)
        XCTAssertEqual(saved.id, 1)
        XCTAssertEqual(saved.note, "the 401 loop")
        XCTAssertEqual(store.savedRequests.map(\.uid), ["s1"])
        XCTAssertEqual(store.stored.count, 1)
        XCTAssertEqual(audit.entries.last?.outcome, .performed)
        XCTAssertEqual(audit.entries.last?.action.kind, .saveSession)
        XCTAssertEqual(audit.entries.last?.detail, "saved session #1 api.example.com")
    }

    /// "Save a session" tells the human nothing about which traffic is about
    /// to land on disk — the host has to be in the sentence they read.
    func testTheApprovalNamesTheHostAndWhatIsStored() throws {
        let router = makeRouter(live: [detail(uid: "s1", host: "billing.example.com")])

        _ = try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s1", "note": "card decline"])
        let action = try XCTUnwrap(consent.asked.last)

        XCTAssertEqual(action.kind, .saveSession)
        XCTAssertEqual(action.severity, .exportsData)
        XCTAssertTrue(action.summary.contains("billing.example.com"), "the panel must name whose traffic is being kept")
        XCTAssertTrue(action.details.contains { $0.contains("/v1/users") })
        XCTAssertTrue(action.details.contains { $0.contains("card decline") })
        // The one thing nobody would guess: the stored copy is not masked.
        XCTAssertTrue(action.details.contains { $0.contains("unmasked") })
    }

    func testADeniedSaveKeepsNothing() throws {
        consent.decision = .denied(reason: "not that one")
        let router = makeRouter(live: [detail(uid: "s1")])

        let response = try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s1"])

        XCTAssertEqual(response.status, 403)
        XCTAssertTrue(store.stored.isEmpty, "a refusal must not leave a saved session behind")
        XCTAssertTrue(store.savedRequests.isEmpty, "the seam must not be reached at all")
        XCTAssertEqual(audit.entries.last?.outcome, .denied)
    }

    /// Nobody answering is not the same as saying no: the agent may retry.
    func testAnUnansweredApprovalIsATimeoutNotADenial() throws {
        consent.decision = .timedOut(reason: "no answer")
        let router = makeRouter(live: [detail(uid: "s1")])

        let response = try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s1"])

        XCTAssertEqual(response.status, 408)
        XCTAssertEqual(audit.entries.last?.outcome, .timedOut)
        XCTAssertTrue(store.stored.isEmpty)
    }

    /// A uid that has already aged out fails before the human is interrupted.
    func testAnUnknownUidIsA404AndAsksNobody() throws {
        let router = makeRouter(live: [detail(uid: "s1")])

        let response = try call(router, "POST", "/v1/saved-sessions", body: ["uid": "gone"])

        XCTAssertEqual(response.status, 404)
        XCTAssertTrue(consent.asked.isEmpty, "a call that cannot work must not interrupt the human")
        XCTAssertTrue(store.stored.isEmpty)
    }

    func testAMissingUidIsRejected() throws {
        let router = makeRouter(live: [detail(uid: "s1")])

        XCTAssertEqual(try call(router, "POST", "/v1/saved-sessions", body: ["uid": "  "]).status, 400)
        XCTAssertEqual(try call(router, "POST", "/v1/saved-sessions", body: ["note": "x"]).status, 400)
        XCTAssertTrue(consent.asked.isEmpty)
    }

    /// The note is rendered as its own line in the approval panel, so a note
    /// carrying newlines is how an agent would forge lines into the text a
    /// human is reading to decide.
    func testANoteWithALineBreakIsRefused() throws {
        let router = makeRouter(live: [detail(uid: "s1")])

        let response = try call(router, "POST", "/v1/saved-sessions", body: [
            "uid": "s1",
            "note": "harmless\nAllow: this is routine",
        ])

        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(consent.asked.isEmpty)
    }

    func testAnOverlongNoteIsRefusedAndAnEmptyOneBecomesNil() throws {
        let router = makeRouter(live: [detail(uid: "s1"), detail(uid: "s2")])

        let long = String(repeating: "x", count: MCPSavedSessionValidation.maxNoteLength + 1)
        XCTAssertEqual(try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s1", "note": long]).status, 400)

        XCTAssertEqual(try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s2", "note": "   "]).status, 201)
        XCTAssertNil(store.savedRequests.last?.note, "whitespace is not a note")
    }

    func testAFailingStoreIsReportedAndLogged() throws {
        store.saveError = .failed("database is locked")
        let router = makeRouter(live: [detail(uid: "s1")])

        let response = try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s1"])

        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(audit.entries.last?.outcome, .failed)
        XCTAssertEqual(audit.entries.last?.detail, "database is locked")
    }

    /// The app's own message has the shape "Could not save the session:
    /// <reason>", and the log's name pass — built for "Name: value" as the
    /// consent layer renders it — read "session" as a credential's name and
    /// logged "Could not save the session: «redacted»" (review of F15). A
    /// failure's reason keeps its words in the log; only URL tokens go.
    func testAStoreFailureKeepsItsReasonInTheLog() throws {
        let message = "Could not save the session: The database is locked."
        store.saveError = .failed(message)
        let router = makeRouter(live: [detail(uid: "s1")])

        let response = try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s1"])

        XCTAssertEqual(response.status, 500)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("The database is locked."))
        XCTAssertEqual(audit.entries.last?.outcome, .failed)
        XCTAssertEqual(audit.entries.last?.detail, message)
    }

    // MARK: - Redaction on the way back out

    /// THE test this surface exists to pass: the stored copy is real, so if
    /// the read path stops redacting, save + get is a two-call route around
    /// the read surface's redaction.
    func testASavedSessionCannotLaunderACredential() throws {
        let router = makeRouter()
        let id = try preload(detail(uid: "s1"))

        let response = try call(router, "GET", "/v1/saved-sessions/\(id)")
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)

        XCTAssertFalse(text.contains("super-secret-token-value"), "the stored Authorization header reached the agent")
        XCTAssertFalse(text.contains("live-secret-9912"), "the stored query token reached the agent")
        XCTAssertFalse(text.contains("rt-secret-42"), "the stored response body's refresh token reached the agent")
        XCTAssertTrue(text.contains(MCPRedactor.placeholder) || text.contains(MCPRedactor.urlPlaceholder))
        // And what it was kept FOR still comes back.
        XCTAssertTrue(text.contains("Ada"))
        // cURL embeds raw headers, so the redactor drops it outright.
        let saved = try Self.decoder.decode(MCPSavedSession.self, from: response.body)
        XCTAssertNil(saved.session.curl)
        XCTAssertEqual(saved.id, id)
    }

    /// The list is an egress too — a token in a query string is just as
    /// readable from a row as from a detail.
    func testTheListRedactsEveryRow() throws {
        let router = makeRouter()
        try preload(detail(uid: "s1"), note: "kept")

        let response = try call(router, "GET", "/v1/saved-sessions")
        XCTAssertEqual(response.status, 200)

        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains("live-secret-9912"))
        let page = try Self.decoder.decode(MCPSavedSessionPage.self, from: response.body)
        XCTAssertEqual(page.saved.first?.note, "kept")
        XCTAssertEqual(page.totalCount, 1)
    }

    /// The response to `save_session` echoes the session, so it needs the same
    /// treatment as a read — saving and reading the ANSWER must not differ.
    func testTheSaveResponseIsRedactedToo() throws {
        let router = makeRouter(live: [detail(uid: "s1")])

        let response = try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s1"])

        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("live-secret-9912"))
        XCTAssertFalse(store.stored.isEmpty, "the STORED copy stays real — only egress is redacted")
        XCTAssertEqual(store.stored.first?.session.requestHeaders["Authorization"], "Bearer super-secret-token-value")
    }

    /// Bodies are capped after redaction, the same order the live route uses —
    /// capping first can cut a secret mid-value where redaction can no longer
    /// recognise it.
    func testALargeStoredBodyIsCappedWithAMarker() throws {
        var big = detail(uid: "s1")
        big.responseBodyPreview = String(repeating: "A", count: MCPLimits.bodyPreviewMaxBytes * 2)
        let router = makeRouter()
        let id = try preload(big)

        let response = try call(router, "GET", "/v1/saved-sessions/\(id)")
        let saved = try Self.decoder.decode(MCPSavedSession.self, from: response.body)

        XCTAssertTrue(saved.session.responseBodyTruncated)
        XCTAssertLessThan(saved.session.responseBodyPreview?.count ?? .max, MCPLimits.bodyPreviewMaxBytes * 2)
        XCTAssertTrue(saved.session.responseBodyPreview?.contains(MCPLimits.truncationMarker) ?? false)
    }

    // MARK: - Reading

    func testReadsNeverAskForConsentOrWriteToTheLog() throws {
        let router = makeRouter()
        let id = try preload(detail(uid: "s1"))

        XCTAssertEqual(try call(router, "GET", "/v1/saved-sessions").status, 200)
        XCTAssertEqual(try call(router, "GET", "/v1/saved-sessions/\(id)").status, 200)

        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertTrue(audit.entries.isEmpty)
    }

    func testAnUnknownSavedIdIsA404() throws {
        let router = makeRouter()

        XCTAssertEqual(try call(router, "GET", "/v1/saved-sessions/404").status, 404)
        XCTAssertEqual(try call(router, "DELETE", "/v1/saved-sessions/404").status, 404)
        XCTAssertTrue(consent.asked.isEmpty, "there is nothing to approve when the row does not exist")
    }

    func testAMalformedIdIsA400() throws {
        let router = makeRouter()

        XCTAssertEqual(try call(router, "GET", "/v1/saved-sessions/abc").status, 400)
    }

    /// An agent asking for everything gets a capped page plus the real total,
    /// not an error — and never more than a tool result can carry.
    func testTheLimitIsClampedAndTheTotalIsStatedAnyway() throws {
        let router = makeRouter()
        for index in 0..<5 {
            try preload(detail(uid: "s\(index)"))
        }

        _ = try call(router, "GET", "/v1/saved-sessions?limit=5000")
        XCTAssertEqual(store.requestedLimits.last, MCPLimits.maxPageSize)

        _ = try call(router, "GET", "/v1/saved-sessions?limit=0")
        XCTAssertEqual(store.requestedLimits.last, 1)

        _ = try call(router, "GET", "/v1/saved-sessions")
        XCTAssertEqual(store.requestedLimits.last, MCPLimits.defaultPageSize)

        let page = try Self.decoder.decode(
            MCPSavedSessionPage.self,
            from: try call(router, "GET", "/v1/saved-sessions?limit=2").body
        )
        XCTAssertEqual(page.saved.count, 2)
        XCTAssertEqual(page.totalCount, 5)
    }

    // MARK: - delete_saved_session

    func testDeletingRemovesTheRowAndLogsIt() throws {
        let router = makeRouter()
        let id = try preload(detail(uid: "s1"), note: "the 401 loop")

        let response = try call(router, "DELETE", "/v1/saved-sessions/\(id)")
        XCTAssertEqual(response.status, 200)

        XCTAssertEqual(store.deletedIds, [id])
        XCTAssertTrue(store.stored.isEmpty)
        XCTAssertEqual(audit.entries.last?.outcome, .performed)
        XCTAssertEqual(audit.entries.last?.action.kind, .deleteSavedSession)
        XCTAssertEqual(audit.entries.last?.detail, "saved session #\(id)")
    }

    /// "Delete saved session #1" says nothing about what is being lost.
    func testTheDeleteApprovalNamesWhatIsBeingLost() throws {
        let router = makeRouter()
        let id = try preload(detail(uid: "s1", host: "billing.example.com"), note: "card decline")

        _ = try call(router, "DELETE", "/v1/saved-sessions/\(id)")
        let action = try XCTUnwrap(consent.asked.last)

        XCTAssertEqual(action.severity, .destructive)
        XCTAssertTrue(action.summary.contains("billing.example.com"))
        XCTAssertTrue(action.details.contains { $0.contains("/v1/users") })
        XCTAssertTrue(action.details.contains { $0.contains("card decline") })
        XCTAssertTrue(action.details.contains { $0.hasPrefix("Saved ") })
    }

    func testADeniedDeleteKeepsTheRow() throws {
        let router = makeRouter()
        let id = try preload(detail(uid: "s1"))
        consent.decision = .denied(reason: "keep it")

        let response = try call(router, "DELETE", "/v1/saved-sessions/\(id)")

        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(store.stored.count, 1)
        XCTAssertTrue(store.deletedIds.isEmpty)
        XCTAssertEqual(audit.entries.last?.outcome, .denied)
    }

    /// Undo for saved sessions is deliberately absent: putting the exchange
    /// into `previousState` would make the persisted, exportable activity log
    /// a second copy of captured headers and bodies.
    func testSavedSessionEntriesAreNotOfferedAnUndo() throws {
        let router = makeRouter(live: [detail(uid: "s1")])
        _ = try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s1"])
        _ = try call(router, "DELETE", "/v1/saved-sessions/1")

        for entry in audit.entries {
            XCTAssertFalse(entry.isReversible, "\(entry.action.kind) must not offer an undo")
            XCTAssertNil(MCPUndo.plan(for: entry))
            XCTAssertNil(entry.previousState, "the log must not hold a copy of the exchange")
        }
    }

    // MARK: - Not wired

    /// A build without the store says which piece is missing rather than
    /// blaming the whole write surface.
    func testABuildWithoutTheStoreSaysSo() throws {
        let router = makeRouter(live: [detail(uid: "s1")], wireStore: false)

        for (method, target) in [("GET", "/v1/saved-sessions"), ("GET", "/v1/saved-sessions/1"), ("DELETE", "/v1/saved-sessions/1")] {
            let response = try call(router, method, target)
            XCTAssertEqual(response.status, 503, "\(method) \(target)")
            XCTAssertEqual((response.json?["error"] as? [String: Any])?["code"] as? String, "unavailable")
        }
        let save = try call(router, "POST", "/v1/saved-sessions", body: ["uid": "s1"])
        XCTAssertEqual(save.status, 503)
        XCTAssertTrue(consent.asked.isEmpty)
    }

    /// The paths are registered, so a wrong verb is a 405 rather than a 404
    /// that reads like "this build has no saved sessions".
    func testAWrongMethodIsA405() throws {
        let router = makeRouter()

        XCTAssertEqual(try call(router, "PUT", "/v1/saved-sessions").status, 405)
        XCTAssertEqual(try call(router, "PUT", "/v1/saved-sessions/1").status, 405)
    }

    func testTheBridgeStillRequiresItsToken() throws {
        let router = makeRouter()
        let request = makeRequest(method: "GET", target: "/v1/saved-sessions", token: nil)

        XCTAssertEqual(parseRawResponse(router.respond(to: request))?.status, 401)
    }

    // MARK: - Tool output

    func testTheTextRowLeadsWithTheDurableId() {
        let saved = MCPSavedSessionSummary(
            id: 12,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            note: "the 401 loop",
            session: makeSession(uid: "s1")
        )
        let row = MCPTextFormat.savedRow(saved)

        XCTAssertTrue(row.hasPrefix("#12"), "the id is the handle every other saved-session tool takes")
        XCTAssertTrue(row.contains("the 401 loop"))
        XCTAssertFalse(row.contains("uid="), "a capture uid is meaningless once the run ends")
    }

    func testAPartialPageSaysSo() {
        let rows = (0..<2).map {
            MCPSavedSessionSummary(id: Int64($0), savedAt: Date(), note: nil, session: makeSession(uid: "s\($0)"))
        }
        XCTAssertTrue(MCPTextFormat.savedSessions(MCPSavedSessionPage(saved: rows, totalCount: 40)).contains("2 of 40"))
        XCTAssertTrue(MCPTextFormat.savedSessions(MCPSavedSessionPage(saved: rows, totalCount: 2)).contains("2 saved."))
        XCTAssertTrue(MCPTextFormat.savedSessions(MCPSavedSessionPage(saved: [], totalCount: 0)).contains("save_session"))
    }
}

/// The approval panel and the activity LOG are different places with different
/// lifetimes, and the review of the saved-session tools found the seam: a
/// consent line carried the raw captured URL, and `performWrite` handed that
/// same action to the audit log, which is persisted to UserDefaults and
/// exportable to a file. A 16-character token in a query parameter is too
/// short for the exporter's entropy floor and has no "Name: value" shape for
/// its field-name pass, so it went through both.
final class MCPAuditURLRedactionTests: XCTestCase {
    private let token = "test-token"

    private func makeRouter(consent: StubConsent, audit: StubAudit, sessions: StubSessionProvider) -> MCPBridgeRouter {
        MCPBridgeRouter(
            token: token,
            sessions: sessions,
            status: StubStatusProvider(),
            writes: MCPWriteSeams(
                rules: StubRuleProvider(),
                hosts: StubHostProvider(),
                capture: StubCaptureController(),
                consent: consent,
                audit: audit
            )
        )
    }

    /// The exact case from the review: a short, low-entropy token in a query
    /// parameter, which nothing downstream would have caught.
    func testACapturedTokenInAQueryStringNeverReachesTheLog() throws {
        let secret = "live-secret-9912"
        let summary = makeSession(uid: "s1", url: "https://api.example.com/v1/users?access_token=\(secret)")
        let consent = StubConsent()
        let audit = StubAudit()
        let sessions = StubSessionProvider(
            summaries: [summary],
            details: ["s1": MCPSessionDetail(summary: summary)]
        )
        let router = makeRouter(consent: consent, audit: audit, sessions: sessions)

        var request = makeRequest(method: "POST", target: "/v1/rules/from-session", token: token)
        request.body = try JSONSerialization.data(withJSONObject: ["uid": "s1", "responseStatus": 500])
        request.headers["content-type"] = "application/json"
        _ = router.respond(to: request)

        let logged = try XCTUnwrap(audit.entries.last)
        let text = ([logged.action.summary] + logged.action.details).joined(separator: " | ")
        XCTAssertFalse(text.contains(secret), "the persisted log must not carry a captured credential: \(text)")
    }

    /// The panel still identifies the request — host and path survive, because
    /// a person approving a write has to know which one it is. Only the
    /// credential-shaped query VALUES go, which is `redactURL`'s whole job and
    /// what every other write route on this surface already does.
    func testThePanelStillIdentifiesTheRequest() throws {
        let secret = "live-secret-9912"
        let summary = makeSession(uid: "s1", url: "https://api.example.com/v1/users?access_token=\(secret)")
        let consent = StubConsent()
        let sessions = StubSessionProvider(
            summaries: [summary],
            details: ["s1": MCPSessionDetail(summary: summary)]
        )
        let router = makeRouter(consent: consent, audit: StubAudit(), sessions: sessions)

        var request = makeRequest(method: "POST", target: "/v1/rules/from-session", token: token)
        request.body = try JSONSerialization.data(withJSONObject: ["uid": "s1", "responseStatus": 500])
        request.headers["content-type"] = "application/json"
        _ = router.respond(to: request)

        let asked = try XCTUnwrap(consent.asked.last)
        let shown = ([asked.summary] + asked.details).joined(separator: " | ")
        XCTAssertTrue(shown.contains("api.example.com"), "the human must be able to tell which request this is")
        XCTAssertTrue(shown.contains("/v1/users"), "got: \(shown)")
        XCTAssertFalse(shown.contains(secret), "a token in a query value is not what identifies a request")
    }

    func testTheRedactorLeavesOrdinaryProseAlone() {
        let redactor = MCPRedactor()
        let action = MCPAgentAction(
            kind: .createRule,
            summary: "Create an override rule for api.example.com",
            details: ["Match: wildcard · https", "Response body (12 bytes): {\"ok\":true}"]
        )

        let logged = redactor.redactAction(action)

        XCTAssertEqual(logged.summary, action.summary)
        XCTAssertEqual(logged.details, action.details)
    }

    /// A URL at the end of a sentence must not eat the full stop, or every
    /// logged line starts losing its punctuation.
    func testTrailingPunctuationSurvives() {
        let redactor = MCPRedactor()
        let text = redactor.redactURLs(in: "Replays https://api.example.com/v1/x?token=abcdefghijklmnop.")

        XCTAssertTrue(text.hasSuffix("."), "got: \(text)")
        XCTAssertFalse(text.contains("abcdefghijklmnop"))
    }
}

/// The persisted activity log had two holes, found by two different reviews.
/// URLs were the first; header VALUES were the second, and only the EXPORT
/// path was masking those — the copy in UserDefaults, which outlives the
/// decision it was written for, carried them verbatim.
final class MCPAuditHeaderRedactionTests: XCTestCase {
    func testAnAgentSuppliedHeaderValueDoesNotReachTheLog() {
        let redactor = MCPRedactor()
        let action = MCPAgentAction(
            kind: .createRule,
            summary: "Create an override rule for api.example.com",
            details: ["Sets request headers — X-Api-Key: live-secret-9912 ⚠️"]
        )

        let logged = redactor.redactAction(action)

        XCTAssertFalse(logged.details.joined().contains("live-secret-9912"), "got: \(logged.details)")
        XCTAssertTrue(logged.details.joined().contains("X-Api-Key"), "the name stays so the reader knows what was hidden")
    }

    func testHarmlessHeadersAreLeftReadable() {
        let redactor = MCPRedactor()
        let action = MCPAgentAction(
            kind: .createRule,
            summary: "Create a rule",
            details: ["Sets request headers — Accept: application/json"]
        )

        XCTAssertEqual(redactor.redactAction(action).details, action.details)
    }
}
