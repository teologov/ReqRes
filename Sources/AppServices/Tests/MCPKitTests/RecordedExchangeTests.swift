//
//  RecordedExchangeTests.swift
//  AppServices
//
//  Created by OloApps on 9/28/26.
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
//  The shell's reading of what the 1.1.0 core records (protocol-engine doc
//  §S2): repeated headers shown as repeated, a reused connection labelled,
//  a body kept only in part never presented as whole, and a relayed
//  connection presented as a connection — in the agent's text, the body
//  query, HAR, and the copy every surface quotes.
//

import XCTest
@testable import MCPKit

final class RecordedExchangeTests: XCTestCase {

    // MARK: - The engine's numbers (decisions D6, D10)

    func testTheEngineNumbersAreTheDecisions() {
        XCTAssertEqual(CaptureEngineFacts.idleBetweenExchanges, 30)
        XCTAssertEqual(CaptureEngineFacts.idleWhileInFlight, 300)
        XCTAssertEqual(CaptureEngineFacts.idleRelay, 600)
        XCTAssertEqual(CaptureEngineFacts.retainedBytesPerExchange, 16 * 1024 * 1024)
    }

    func testTheIdleSentenceQuotesAllThreeNumbers() {
        let sentence = CaptureEngineFacts.idleSentence()
        XCTAssertTrue(sentence.contains("30 s between requests"), sentence)
        XCTAssertTrue(sentence.contains("300 s while a response is awaited or streaming"), sentence)
        XCTAssertTrue(sentence.contains("10 minutes on a relayed connection"), sentence)
        // The app passes the running core's numbers; the sentence follows them.
        XCTAssertTrue(CaptureEngineFacts.idleSentence(between: 45, inFlight: 120, relay: 900).contains("45 s between requests"))
        XCTAssertTrue(CaptureEngineFacts.idleSentence(between: 45, inFlight: 120, relay: 900).contains("15 minutes"))
    }

    func testDurationsReadAsSecondsOrWholeMinutes() {
        XCTAssertEqual(CaptureEngineFacts.duration(30), "30 s")
        XCTAssertEqual(CaptureEngineFacts.duration(300), "300 s")
        XCTAssertEqual(CaptureEngineFacts.duration(600), "10 minutes")
        XCTAssertEqual(CaptureEngineFacts.duration(630), "630 s")
    }

    func testRetentionSentenceNamesTheLimitAndThatEverythingIsForwarded() {
        let sentence = CaptureEngineFacts.retentionSentence()
        XCTAssertTrue(sentence.contains("16 MB"), sentence)
        XCTAssertTrue(sentence.contains("sent on in full"), sentence)
    }

    // MARK: - Reused connections

    func testTheFirstExchangeOnAConnectionHasNoLabel() {
        XCTAssertNil(RecordedExchangeCopy.connectionLabel(reused: false, exchangeIndex: 0))
        XCTAssertTrue(RecordedExchangeCopy.showsConnectionSetup(reused: false, exchangeIndex: 0))
    }

    func testAReusedExchangeIsLabelledWithItsOneBasedPosition() {
        XCTAssertEqual(RecordedExchangeCopy.connectionLabel(reused: true, exchangeIndex: 2), "Reused connection · request 3 on it")
        XCTAssertEqual(RecordedExchangeCopy.connectionLabel(reused: true, exchangeIndex: 1), "Reused connection · request 2 on it")
        XCTAssertFalse(RecordedExchangeCopy.showsConnectionSetup(reused: true, exchangeIndex: 2))
    }

    func testAnInconsistentRowStillReadsReusedWithoutInventingAPosition() {
        XCTAssertEqual(RecordedExchangeCopy.connectionLabel(reused: true, exchangeIndex: 0), "Reused connection")
        XCTAssertNotNil(RecordedExchangeCopy.connectionLabel(reused: false, exchangeIndex: 3))
    }

    // MARK: - Bodies kept only in part

    func testAWholeBodyHasNoNotice() {
        XCTAssertNil(RecordedExchangeCopy.notRetainedNotice(notRetained: 0, totalAsSent: 1_000))
        XCTAssertNil(RecordedExchangeCopy.agentNotRetainedNote(notRetained: 0))
    }

    func testAPartBodySaysHowMuchIsMissingOfHowMuch() throws {
        let notice = try XCTUnwrap(RecordedExchangeCopy.notRetainedNotice(notRetained: 24 * 1_048_576, totalAsSent: 40 * 1_048_576))
        XCTAssertTrue(notice.hasPrefix("Not the whole body"), notice)
        XCTAssertTrue(notice.contains("24 MB of it as sent is not shown"), notice)
        XCTAssertTrue(notice.contains("(40 MB in all)"), notice)
        XCTAssertTrue(notice.contains("first 16 MB"), notice)
        // Never phrased as characters of text: for a gzip body the count is
        // in bytes as sent, and the shown text is a decoded prefix.
        XCTAssertFalse(notice.contains("characters"), notice)
    }

    func testTheAgentNoteCarriesTheExactByteCount() throws {
        let note = try XCTUnwrap(RecordedExchangeCopy.agentNotRetainedNote(notRetained: 25_165_824))
        XCTAssertTrue(note.contains("25165824 bytes"), note)
        XCTAssertTrue(note.contains("not in the app either"), note)
    }

    // MARK: - Relayed connections

    func testARelayEndpointAlwaysCarriesItsPort() {
        XCTAssertEqual(RecordedExchangeCopy.relayEndpoint(host: "api.github.com"), "api.github.com:443")
        XCTAssertEqual(RecordedExchangeCopy.relayEndpoint(host: "db.internal:8443"), "db.internal:8443")
        XCTAssertEqual(RecordedExchangeCopy.relayEndpoint(host: "10.0.0.2"), "10.0.0.2:443")
        XCTAssertEqual(RecordedExchangeCopy.relayEndpoint(host: "::1"), "[::1]:443")
        XCTAssertEqual(RecordedExchangeCopy.relayEndpoint(host: "[2001:db8::1]"), "[2001:db8::1]:443")
        XCTAssertEqual(RecordedExchangeCopy.relayEndpoint(host: "[2001:db8::1]:8443"), "[2001:db8::1]:8443")
        XCTAssertEqual(RecordedExchangeCopy.relayEndpoint(host: ""), "—")
    }

    func testBinaryBytesAddUpAgainstTheSixteenMegabyteLimit() {
        XCTAssertEqual(RecordedExchangeCopy.binaryBytes(0), "0 B")
        XCTAssertEqual(RecordedExchangeCopy.binaryBytes(512), "512 B")
        XCTAssertEqual(RecordedExchangeCopy.binaryBytes(1_536), "1.5 KB")
        XCTAssertEqual(RecordedExchangeCopy.binaryBytes(16 * 1_048_576), "16 MB")
        XCTAssertEqual(RecordedExchangeCopy.binaryBytes(25_165_824), "24 MB")
        XCTAssertEqual(RecordedExchangeCopy.binaryBytes(-5), "0 B")
    }

    // MARK: - The agent's list row and detail

    private func relaySummary() -> MCPSessionSummary {
        MCPSessionSummary(
            uid: "r1", host: "api.github.com", method: "CONNECT", url: "https://api.github.com",
            scheme: "https", statusCode: nil, durationMs: 15_559, requestBodySize: 2_318, responseBodySize: 48_911,
            app: "git-remote-https", pid: 51_307, kind: .relay
        )
    }

    func testARelayRowReadsAsAConnectionNotARequest() {
        let row = MCPTextFormat.row(relaySummary())
        XCTAssertTrue(row.contains("kind=relay"), row)
        XCTAssertTrue(row.contains("api.github.com:443"), row)
        XCTAssertTrue(row.contains("not decrypted"), row)
        XCTAssertTrue(row.contains("sent 2.3 KB, received 47.8 KB"), row)
        XCTAssertFalse(row.contains("CONNECT"), "a relay has no method: \(row)")
        XCTAssertTrue(row.contains("uid=r1"), row)
    }

    func testAnExchangeRowIsUnchanged() {
        let row = MCPTextFormat.row(makeSession(uid: "s1"))
        XCTAssertFalse(row.contains("kind="), row)
        XCTAssertTrue(row.hasPrefix("200  GET  https://api.example.com/v1/resource/s1"), row)
    }

    func testARelayDetailExplainsWhyThereIsNothingInside() {
        let detail = MCPSessionDetail(summary: relaySummary(), serverAddress: "140.82.121.6")
        let text = MCPTextFormat.detail(detail)
        XCTAssertTrue(text.hasPrefix("Relayed connection api.github.com:443 — kind=relay"), text)
        XCTAssertTrue(text.contains(RecordedExchangeCopy.relayExplanation), text)
        XCTAssertTrue(text.contains("Traffic: sent 2.3 KB, received 47.8 KB"), text)
        XCTAssertTrue(text.contains("Server: 140.82.121.6"), text)
        XCTAssertFalse(text.contains("Status:"), text)
        XCTAssertFalse(text.contains("Request headers"), text)
    }

    func testAReusedExchangeDetailSaysSo() {
        let detail = MCPSessionDetail(summary: makeSession(uid: "s1"), connectionReused: true, exchangeIndex: 2)
        XCTAssertTrue(MCPTextFormat.detail(detail).contains("Connection: reused — request 3 on it (no DNS, TCP or TLS of its own)"))
        let first = MCPSessionDetail(summary: makeSession(uid: "s0"), connectionReused: false, exchangeIndex: 0)
        XCTAssertTrue(MCPTextFormat.detail(first).contains("Connection: new — request 1 on it"))
    }

    /// An app older than the 1.1.0 core never reported the connection; the
    /// text says nothing rather than guessing "new".
    func testADetailFromAnOlderAppHasNoConnectionLine() {
        XCTAssertFalse(MCPTextFormat.detail(MCPSessionDetail(summary: makeSession(uid: "s1"))).contains("Connection:"))
    }

    func testABodyKeptInPartIsMarkedInTheDetail() {
        let detail = MCPSessionDetail(
            summary: makeSession(uid: "s1"),
            responseBodyPreview: "{\"events\":[",
            responseBodyNotRetainedBytes: 25_165_824
        )
        let text = MCPTextFormat.detail(detail)
        XCTAssertTrue(text.contains("Response body:\n{\"events\":["), text)
        XCTAssertTrue(text.contains("25165824 bytes of this body as sent are not in it"), text)
    }

    func testABodyKeptNotAtAllIsStillReportedAsABody() {
        let detail = MCPSessionDetail(summary: makeSession(uid: "s1"), requestBodyNotRetainedBytes: 900)
        let text = MCPTextFormat.detail(detail)
        XCTAssertTrue(text.contains("Request body: none kept"), text)
        XCTAssertTrue(text.contains("900 bytes"), text)
    }

    /// A body the capture cut at 16 MB is always over the 10 KB preview cap
    /// too, so both flags are set together in production. The preview line
    /// must not send the agent to the app "for the full body" while the
    /// retention note says the app does not have it (review finding, S2).
    func testAPreviewOfABodyKeptInPartDoesNotSendTheAgentToTheAppForTheRest() {
        let detail = MCPSessionDetail(
            summary: makeSession(uid: "s1"),
            responseBodyPreview: "{\"events\":[",
            responseBodyTruncated: true,
            responseBodyNotRetainedBytes: 1_000
        )
        let text = MCPTextFormat.detail(detail)
        XCTAssertFalse(text.contains("open the session in ReqRes for the full body"), text)
        XCTAssertTrue(text.contains("(this preview stops at 10 KB; query_session_body reads the rest of what was kept)"), text)
        XCTAssertTrue(text.contains("not in the app either"), text)
    }

    /// A body kept whole but longer than the preview: the app DOES hold the
    /// rest, so the old pointer is still the right one.
    func testAPreviewOfAWholeBodyStillPointsAtTheApp() {
        let detail = MCPSessionDetail(summary: makeSession(uid: "s1"), responseBodyPreview: "abc", responseBodyTruncated: true)
        XCTAssertTrue(MCPTextFormat.detail(detail).contains("(truncated — open the session in ReqRes for the full body)"))
    }

    // MARK: - Repeated headers, everywhere they are printed

    /// Two `Set-Cookie` recorded by the core are two lines in the agent's
    /// text. Before, the newline-joined value printed as ONE `Set-Cookie:`
    /// line with the second cookie on a bare continuation line.
    func testTwoSetCookiePrintAsTwoHeaderLines() {
        let raw = #"[{"Set-Cookie":"sid=1; Path=/"},{"Content-Type":"text/plain"},{"Set-Cookie":"csrf=2; Expires=Wed, 21 Oct 2026 07:28:00 GMT"}]"#
        let detail = MCPSessionDetail(summary: makeSession(uid: "s1"), responseHeaders: MCPRecordedHeaders.dictionary(from: raw))
        let lines = MCPTextFormat.detail(detail).components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("  Set-Cookie: ") }, [
            "  Set-Cookie: sid=1; Path=/",
            "  Set-Cookie: csrf=2; Expires=Wed, 21 Oct 2026 07:28:00 GMT",
        ])
        XCTAssertFalse(lines.contains("csrf=2; Expires=Wed, 21 Oct 2026 07:28:00 GMT"), "no bare continuation line")
    }

    /// Redacted, the two cookies stay two placeholders — not one line that
    /// reads as a single cookie.
    func testRedactionKeepsOnePlaceholderPerRecordedLine() {
        let headers = MCPRecordedHeaders.dictionary(from: #"[{"Set-Cookie":"a=1"},{"Set-Cookie":"b=2"}]"#)
        let redacted = MCPRedactor().redactHeaders(headers)
        XCTAssertEqual(redacted["Set-Cookie"], "\(MCPRedactor.placeholder)\n\(MCPRedactor.placeholder)")
        let detail = MCPRedactor().redactDetail(MCPSessionDetail(summary: makeSession(uid: "s1"), responseHeaders: headers))
        let lines = MCPTextFormat.detail(detail).components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("  Set-Cookie: ") }.count, 2)
    }

    func testADiffPrintsARepeatedHeaderOnePerLine() {
        let left = MCPSessionDetail(summary: makeSession(uid: "a"))
        let right = MCPSessionDetail(
            summary: makeSession(uid: "b"),
            responseHeaders: MCPRecordedHeaders.dictionary(from: #"[{"Set-Cookie":"a=1"},{"Set-Cookie":"b=2"}]"#)
        )
        let text = MCPSessionDiffFormat.render(MCPSessionDiff.diff(left, right))
        let added = text.components(separatedBy: "\n").filter { $0.hasPrefix("  + Set-Cookie: ") }
        XCTAssertEqual(added.count, 2, text)
    }

    func testDisplayLinesSplitOnlyWhatWasJoined() {
        XCTAssertEqual(MCPRecordedHeaders.lines(of: "a, b"), ["a, b"])
        XCTAssertEqual(MCPRecordedHeaders.lines(of: "a\nb"), ["a", "b"])
        XCTAssertEqual(MCPRecordedHeaders.displayLines(["b": "2", "A": "1\n3"]), ["A: 1", "A: 3", "b: 2"])
    }

    /// Only `Set-Cookie` is split back into its recorded lines; any other
    /// repeated name stays one line, joined the way HTTP allows. The copy an
    /// agent reads must say exactly that (review finding: it claimed every
    /// repeated header was listed twice).
    func testOtherRepeatedHeadersStayOneCombinedLineAsTheCopySays() throws {
        let headers = MCPRecordedHeaders.dictionary(from: #"[{"Vary":"Accept"},{"Vary":"Origin"},{"Set-Cookie":"a=1"},{"Set-Cookie":"b=2"}]"#)
        let lines = MCPTextFormat.detail(MCPSessionDetail(summary: makeSession(uid: "s1"), responseHeaders: headers))
            .components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("  Vary: ") }, ["  Vary: Accept, Origin"])
        XCTAssertEqual(lines.filter { $0.hasPrefix("  Set-Cookie: ") }.count, 2)

        let skill = try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/reqres-mcp/SKILL.md"), encoding: .utf8)
        XCTAssertFalse(skill.contains("Nothing is folded"), "SKILL.md claims no header is combined")
        XCTAssertFalse(skill.contains("A header sent twice is listed twice"))
        XCTAssertTrue(skill.contains("`Vary: Accept, Origin`"), "SKILL.md should show how other repeated headers read")
    }

    // MARK: - Where connection reuse is a fact

    /// The exchange engine numbers exchanges on decrypted HTTPS and, since
    /// core ef40bdf (C5), on plain http:// too; relays carry false/0
    /// defaults that must not print as "new — request 1".
    func testConnectionReuseIsReportedOnlyWhereTheCoreCountsIt() {
        XCTAssertTrue(RecordedExchangeCopy.tracksConnectionReuse(scheme: "https", isRelay: false))
        XCTAssertTrue(RecordedExchangeCopy.tracksConnectionReuse(scheme: "HTTPS", isRelay: false))
        XCTAssertTrue(RecordedExchangeCopy.tracksConnectionReuse(scheme: "http", isRelay: false), "plain http:// is numbered per exchange since C5")
        XCTAssertFalse(RecordedExchangeCopy.tracksConnectionReuse(scheme: "https", isRelay: true))
        XCTAssertFalse(RecordedExchangeCopy.tracksConnectionReuse(scheme: "", isRelay: false))
    }

    // MARK: - The copy's scope

    /// Plain http:// keeps 16 MB per REQUEST since core ef40bdf (C5), like
    /// HTTPS; the old per-connection sentence would now be false.
    func testTheRetentionCopySaysEveryRequestKeepsItsOwnBudget() throws {
        XCTAssertTrue(CaptureEngineFacts.retentionSentence().contains("Each request keeps at most the first 16 MB of its bodies"))
        XCTAssertFalse(CaptureEngineFacts.retentionSentence().contains("share one"), "no scheme shares a budget any more")
        let notice = try XCTUnwrap(RecordedExchangeCopy.notRetainedNotice(notRetained: 1, totalAsSent: 2))
        XCTAssertTrue(notice.contains("of each request's bodies"), notice)
        XCTAssertFalse(notice.contains("connection's"), notice)
        let note = try XCTUnwrap(RecordedExchangeCopy.agentNotRetainedNote(notRetained: 1))
        XCTAssertTrue(note.contains("of this row's bodies"), note)
    }

    /// The core still writes one header of its own, on the response that
    /// replaces a request a human aborted at a breakpoint; the copy names it.
    func testTheNoHeadersCopyNamesTheAbortHeader() throws {
        XCTAssertTrue(CaptureEngineFacts.addsNoHeaders.contains("X-Req-Res-Aborted: breakpoint"))
        let skill = try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/reqres-mcp/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(skill.contains("`X-Req-Res-Aborted: breakpoint`"))
    }

    // MARK: - query_session_body

    private func router(_ sessions: StubSessionProvider) -> MCPBridgeRouter {
        MCPBridgeRouter(token: "t", sessions: sessions, status: StubStatusProvider(), redactor: MCPRedactor())
    }

    func testABodyQueryOnAPartBodyReportsWhatWasNotKept() throws {
        let sessions = StubSessionProvider(
            summaries: [makeSession(uid: "s1")],
            details: ["s1": MCPSessionDetail(summary: makeSession(uid: "s1"), responseBodyNotRetainedBytes: 4_096)],
            bodies: ["s1:response": #"{"items":[1,2"#]
        )
        let response = router(sessions).respond(to: makeRequest(target: "/v1/sessions/s1/body?side=response&mode=structure", token: "t"))
        let parsed = try XCTUnwrap(parseRawResponse(response))
        XCTAssertEqual(parsed.status, 200)
        let result = try JSONDecoder().decode(MCPBodyQueryResult.self, from: parsed.body)
        XCTAssertEqual(result.notRetainedBytes, 4_096)
        let text = MCPTextFormat.bodyQuery(result)
        XCTAssertTrue(text.contains("4096 bytes of this body as sent are not in it"), text)
        XCTAssertTrue(text.contains("may simply not have been kept"), text)
    }

    func testABodyQueryOnAWholeBodyAddsNothing() throws {
        let result = MCPBodyQueryResult(uid: "s1", side: .response, mode: "structure", path: nil, found: true, text: "object", notRetainedBytes: 0)
        XCTAssertEqual(MCPTextFormat.bodyQuery(result), "object")
        let older = MCPBodyQueryResult(uid: "s1", side: .response, mode: "structure", path: nil, found: true, text: "object")
        XCTAssertEqual(MCPTextFormat.bodyQuery(older), "object")
    }

    func testABodyQueryOnARelaySaysThereIsNoBodyToQuery() throws {
        let sessions = StubSessionProvider(
            summaries: [relaySummary()],
            details: ["r1": MCPSessionDetail(summary: relaySummary())]
        )
        let response = router(sessions).respond(to: makeRequest(target: "/v1/sessions/r1/body", token: "t"))
        let parsed = try XCTUnwrap(parseRawResponse(response))
        XCTAssertEqual(parsed.status, 404)
        let message = try XCTUnwrap((parsed.json?["error"] as? [String: Any])?["message"] as? String)
        XCTAssertTrue(message.contains("is a relayed connection"), message)
        XCTAssertTrue(message.contains("There is no body to query."), message)
    }

    /// The body query reads the two facts it needs through the light seam
    /// and never builds a whole detail (which renders a cURL from a body of
    /// up to 16 MB). This provider has NO details at all.
    func testABodyQueryReadsItsFactsWithoutBuildingADetail() throws {
        let sessions = FactsOnlySessionProvider(
            facts: [
                "s1": MCPSessionBodyFacts(isRelay: false, responseNotRetainedBytes: 2_048),
                "r1": MCPSessionBodyFacts(isRelay: true),
            ],
            bodies: ["s1:response": #"{"a":1"#]
        )
        let router = MCPBridgeRouter(token: "t", sessions: sessions, status: StubStatusProvider(), redactor: MCPRedactor())

        let part = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/sessions/s1/body?side=response", token: "t"))))
        XCTAssertEqual(part.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(MCPBodyQueryResult.self, from: part.body).notRetainedBytes, 2_048)

        let relay = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/sessions/r1/body", token: "t"))))
        XCTAssertEqual(relay.status, 404)
        let message = try XCTUnwrap((relay.json?["error"] as? [String: Any])?["message"] as? String)
        XCTAssertTrue(message.contains("is a relayed connection"), message)

        XCTAssertEqual(sessions.detailCalls, 0, "the body query built a whole detail")
    }

    /// Providers that implement only the detail (older conformers, the test
    /// stub) still get the facts, derived from it.
    func testTheBodyFactsDefaultDerivesFromTheDetail() {
        let sessions = StubSessionProvider(details: ["s1": MCPSessionDetail(
            summary: makeSession(uid: "s1"), requestBodyNotRetainedBytes: 7, responseBodyNotRetainedBytes: 9
        )])
        XCTAssertEqual(sessions.sessionBodyFacts(uid: "s1"), MCPSessionBodyFacts(isRelay: false, requestNotRetainedBytes: 7, responseNotRetainedBytes: 9))
        XCTAssertNil(sessions.sessionBodyFacts(uid: "missing"))
    }

    // MARK: - HAR

    private func harEntry(_ detail: MCPSessionDetail) throws -> [String: Any] {
        let result = MCPHARExport.encode(sessions: [detail], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let entries = try XCTUnwrap((json["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        return try XCTUnwrap(entries.first)
    }

    func testHARMarksAResponseBodyKeptInPart() throws {
        let entry = try harEntry(MCPSessionDetail(
            summary: makeSession(uid: "s1"),
            responseBodyPreview: "partial",
            responseBodyNotRetainedBytes: 25_165_824
        ))
        let content = try XCTUnwrap((entry["response"] as? [String: Any])?["content"] as? [String: Any])
        XCTAssertEqual(content["_reqresNotRetainedBytes"] as? Int, 25_165_824)
        let comment = try XCTUnwrap(content["comment"] as? String)
        XCTAssertTrue(comment.hasPrefix("Incomplete"), comment)
    }

    func testHARMarksARequestBodyKeptNotAtAll() throws {
        let entry = try harEntry(MCPSessionDetail(summary: makeSession(uid: "s1", method: "POST"), requestBodyNotRetainedBytes: 1_000))
        let postData = try XCTUnwrap((entry["request"] as? [String: Any])?["postData"] as? [String: Any])
        XCTAssertEqual(postData["_reqresNotRetainedBytes"] as? Int, 1_000)
        XCTAssertEqual(postData["text"] as? String, "")
    }

    func testHARLeavesAWholeBodyUnmarked() throws {
        let entry = try harEntry(MCPSessionDetail(summary: makeSession(uid: "s1"), responseBodyPreview: "whole", responseBodyNotRetainedBytes: 0))
        let content = try XCTUnwrap((entry["response"] as? [String: Any])?["content"] as? [String: Any])
        XCTAssertNil(content["_reqresNotRetainedBytes"])
        XCTAssertNil(content["comment"])
    }

    func testHARFlagsARelayAndCarriesTheConnectionFacts() throws {
        let relay = try harEntry(MCPSessionDetail(summary: relaySummary()))
        XCTAssertEqual(relay["_reqresKind"] as? String, "relay")
        XCTAssertEqual(relay["comment"] as? String, RecordedExchangeCopy.relayExplanation)

        let reused = try harEntry(MCPSessionDetail(summary: makeSession(uid: "s1"), connectionReused: true, exchangeIndex: 2))
        XCTAssertEqual(reused["_reqresConnectionReused"] as? Bool, true)
        XCTAssertEqual(reused["_reqresExchangeIndex"] as? Int, 2)
        XCTAssertNil(reused["_reqresKind"])
    }

    // MARK: - Wire compatibility between app and helper builds

    /// A helper and an app of different builds exchange these as JSON; one
    /// without the new fields must still decode, as an exchange.
    func testSummariesAndDetailsFromAnOlderAppStillDecode() throws {
        let summaryJSON = #"{"uid":"s1","host":"h","method":"GET","url":"https://h/","scheme":"https"}"#
        let summary = try JSONDecoder().decode(MCPSessionSummary.self, from: Data(summaryJSON.utf8))
        XCTAssertNil(summary.kind)
        XCTAssertFalse(summary.isRelay)

        let detailJSON = #"{"summary":\#(summaryJSON),"requestHeaders":{},"responseHeaders":{},"requestBodyTruncated":false,"responseBodyTruncated":false}"#
        let detail = try JSONDecoder().decode(MCPSessionDetail.self, from: Data(detailJSON.utf8))
        XCTAssertNil(detail.connectionReused)
        XCTAssertEqual(detail.notRetainedBytes(.response), 0)
    }

    func testTheNewFieldsRoundTrip() throws {
        let detail = MCPSessionDetail(summary: relaySummary(), connectionReused: true, exchangeIndex: 4,
                                      requestBodyNotRetainedBytes: 1, responseBodyNotRetainedBytes: 2)
        let decoded = try JSONDecoder().decode(MCPSessionDetail.self, from: JSONEncoder().encode(detail))
        XCTAssertEqual(decoded, detail)
        XCTAssertEqual(decoded.summary.kind, .relay)
    }

    /// A kind a newer app sends (a D8 failure row, say) must not fail the
    /// whole page for an older helper; it reads as an ordinary row.
    func testAnUnknownKindFromANewerAppStillDecodes() throws {
        let json = #"[{"uid":"s1","host":"h","method":"GET","url":"https://h/","scheme":"https","kind":"failure"},{"uid":"r1","host":"h","method":"CONNECT","url":"https://h","scheme":"https","kind":"relay"}]"#
        let summaries = try JSONDecoder().decode([MCPSessionSummary].self, from: Data(json.utf8))
        XCTAssertEqual(summaries.map(\.kind), [.exchange, .relay])
        XCTAssertFalse(summaries[0].isRelay)
        let encoded = try JSONEncoder().encode(MCPSessionKind.relay)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #""relay""#)
    }

    // MARK: - The copy the helper ships

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/MCPKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AppServices
    }

    /// SKILL.md is prose an agent reads; it cannot interpolate the numbers,
    /// so it is checked against them.
    func testSkillStatesTheEngineNumbers() throws {
        let skill = try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/reqres-mcp/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(skill.contains("\(Int(CaptureEngineFacts.idleBetweenExchanges)) s with nothing moving"), "SKILL.md's idle number drifted")
        XCTAssertTrue(skill.contains("\(Int(CaptureEngineFacts.idleWhileInFlight)) s while a response is awaited or streaming"))
        XCTAssertTrue(skill.contains("\(Int(CaptureEngineFacts.idleRelay) / 60) minutes on a relayed connection"))
        XCTAssertTrue(skill.contains("\(RecordedExchangeCopy.binaryBytes(CaptureEngineFacts.retainedBytesPerExchange)) per exchange"))
        XCTAssertTrue(skill.contains("kind=relay"))
        XCTAssertTrue(skill.contains("ReqRes adds no headers of its own"))
    }
}

/// A provider that answers the body query's facts and bodies but has no
/// details, and counts any attempt to build one.
private final class FactsOnlySessionProvider: MCPSessionProviding {
    let facts: [String: MCPSessionBodyFacts]
    let bodies: [String: String]
    private(set) var detailCalls = 0

    init(facts: [String: MCPSessionBodyFacts], bodies: [String: String]) {
        self.facts = facts
        self.bodies = bodies
    }

    func sessionSummaries() -> [MCPSessionSummary] { [] }
    func sessionDetail(uid: String) -> MCPSessionDetail? {
        detailCalls += 1
        return nil
    }
    func sessionBody(uid: String, side: MCPBodySide) -> String? { bodies["\(uid):\(side.rawValue)"] }
    func sessionBodyFacts(uid: String) -> MCPSessionBodyFacts? { facts[uid] }
}
