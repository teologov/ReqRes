//
//  FailureRowsTests.swift
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
//  Failed, aborted and timed-out rows as every agent-facing surface reads
//  them (protocol PRD 3.4, decision D8; protocol-engine doc §S3). Before
//  this step a failure row decoded as an ordinary completed row: its outcome
//  went nowhere, `wait_for_session` resolved on the first cancelled request,
//  HAR wrote a ReqRes-generated 502 as the server's answer, and the
//  Destinations report counted requests that never left the Mac as Unknown.
//

import XCTest
@testable import MCPKit

final class FailureRowsTests: XCTestCase {

    // MARK: - Fixtures

    private func failed(
        _ uid: String,
        phase: MCPFailurePhase = .connect,
        detail: String? = "ReqRes could not connect to api.example.com:443 (connection refused).",
        status: Int? = 502,
        neverConnected: Bool? = true
    ) -> MCPSessionSummary {
        var session = makeSession(uid: uid, statusCode: status)
        session.outcome = .failed
        session.failurePhase = phase
        session.failureDetail = detail
        session.clientCancelled = false
        session.neverConnected = neverConnected
        return session
    }

    private func cancelled(_ uid: String) -> MCPSessionSummary {
        var session = makeSession(uid: uid, statusCode: 200)
        session.outcome = .aborted
        session.failurePhase = .response
        session.failureDetail = "The app closed the connection while the response was arriving."
        session.clientCancelled = true
        session.neverConnected = false
        return session
    }

    private func completed(_ uid: String) -> MCPSessionSummary {
        var session = makeSession(uid: uid)
        session.outcome = .completed
        return session
    }

    // MARK: - The vocabulary

    func testOutcomeTokensAndParsingAcceptEverySpellingAnAgentUses() {
        XCTAssertEqual(MCPSessionOutcome.tokens, ["completed", "failed", "aborted", "timed_out"])
        XCTAssertEqual(MCPSessionOutcome.parse("FAILED"), .failed)
        for spelling in ["timed_out", "timedOut", "timed-out", "timedout", "timeout"] {
            XCTAssertEqual(MCPSessionOutcome.parse(spelling), .timedOut, spelling)
        }
        XCTAssertNil(MCPSessionOutcome.parse("broken"))
        XCTAssertNil(MCPSessionOutcome.parse(""))
    }

    /// The core's own rule (C6.3): an outcome a later extension adds is at
    /// least "not completed", and a phase it adds is kept as `.other` — never
    /// a failed decode of the whole row (and so of the whole page).
    func testUnknownOutcomeAndPhaseDecodeInsteadOfFailingTheRow() throws {
        let json = #"{"uid":"u","host":"h","method":"GET","url":"https://h/","scheme":"https","outcome":"exploded","failurePhase":"quic"}"#
        let summary = try JSONDecoder().decode(MCPSessionSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.outcome, .failed)
        XCTAssertEqual(summary.failurePhase, .other)
    }

    /// An app from before the fields sent no outcome: every such row was a
    /// completed one, and nothing about it may read as a failure.
    func testASummaryFromAnOlderAppIsCompleted() throws {
        let json = #"{"uid":"u","host":"h","method":"GET","url":"https://h/","scheme":"https","statusCode":200}"#
        let summary = try JSONDecoder().decode(MCPSessionSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.outcome)
        XCTAssertEqual(summary.effectiveOutcome, .completed)
        XCTAssertNil(summary.failureFacts)
        XCTAssertFalse(MCPTextFormat.row(summary).contains("outcome="))
    }

    func testTheFieldsRoundTrip() throws {
        let original = failed("f1", phase: .tlsClient)
        let decoded = try JSONDecoder().decode(MCPSessionSummary.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Facts

    func testNeverConnectedIsAFailureWithNoServerAddressExceptServerTLS() {
        XCTAssertTrue(FailureRowFacts(outcome: .failed, phase: .dns).neverConnected)
        XCTAssertTrue(FailureRowFacts(outcome: .failed, phase: .connect).neverConnected)
        XCTAssertTrue(FailureRowFacts(outcome: .failed, phase: .tlsClient).neverConnected)
        XCTAssertTrue(FailureRowFacts(outcome: .aborted, phase: .request, clientCancelled: true).neverConnected,
                      "an app that left before the lazy dial went nowhere")
        XCTAssertFalse(FailureRowFacts(outcome: .failed, phase: .tlsUpstream).neverConnected,
                       "the TCP connect reached a server; an unrecorded address is unknown, not nowhere")
        XCTAssertFalse(FailureRowFacts(outcome: .failed, phase: .connect, hasServerAddress: true).neverConnected)
        XCTAssertFalse(FailureRowFacts(outcome: .completed).neverConnected, "a mock answered locally is not a failure")
    }

    /// D8: only a client-cancelled ABORT hides; a server's hang-up, a human's
    /// breakpoint abort and ReqRes's idle close are what the rows are for.
    /// D14's limit: only an exchange that got under way and kept a body is an
    /// inspection; a failed row (ReqRes's 502 sentence) never is.
    func testOnlyAnAbortedOrTimedOutRowWithABodyCarriesDecryptedContent() {
        XCTAssertTrue(FailureRowFacts(outcome: .aborted, phase: .response).carriesDecryptedBody(hasRecordedBody: true))
        XCTAssertTrue(FailureRowFacts(outcome: .timedOut, phase: .response).carriesDecryptedBody(hasRecordedBody: true))
        XCTAssertFalse(FailureRowFacts(outcome: .aborted, phase: .response).carriesDecryptedBody(hasRecordedBody: false))
        XCTAssertFalse(FailureRowFacts(outcome: .failed, phase: .dns, status: "502").carriesDecryptedBody(hasRecordedBody: true),
                       "a failed row's body is ReqRes's own 502 sentence")
        XCTAssertFalse(FailureRowFacts(outcome: .completed).carriesDecryptedBody(hasRecordedBody: true))
        XCTAssertTrue(FailureRowCopy.settingsExplanation.contains("an Aborted or Timed out one that kept a body counts"),
                      "Settings must not promise every failure row is free")
    }

    func testOnlyAClientCancelledAbortIsHiddenAndOnlyWhileTheSettingIsOff() {
        let cancel = FailureRowFacts(outcome: .aborted, phase: .response, clientCancelled: true)
        XCTAssertTrue(cancel.isHidden(showCancelled: false))
        XCTAssertFalse(cancel.isHidden(showCancelled: true))
        XCTAssertFalse(FailureRowFacts(outcome: .aborted, phase: .response, clientCancelled: false).isHidden(showCancelled: false))
        XCTAssertFalse(FailureRowFacts(outcome: .failed, phase: .connect).isHidden(showCancelled: false))
        XCTAssertFalse(FailureRowFacts(outcome: .timedOut, phase: .response).isHidden(showCancelled: false))
    }

    // MARK: - Copy

    func testTheCauseIsTheCoresSentenceOrThePhasesWhenThereIsNone() {
        XCTAssertEqual(FailureRowCopy.cause(FailureRowFacts(outcome: .failed, phase: .dns, detail: "  reqres.invalid did not resolve.  ")),
                       "reqres.invalid did not resolve.")
        XCTAssertEqual(FailureRowCopy.cause(FailureRowFacts(outcome: .failed, phase: .dns, detail: "")), "The server's name could not be resolved.")
        XCTAssertEqual(FailureRowCopy.cause(FailureRowFacts(outcome: .failed, phase: .tlsClient)), "The app refused ReqRes's certificate.")
        XCTAssertEqual(FailureRowCopy.cause(FailureRowFacts(outcome: .aborted, phase: .response)), "The response was cut off before it was complete.")
        XCTAssertTrue(FailureRowCopy.cause(FailureRowFacts(outcome: .timedOut)).contains("silent"))
    }

    /// Colour is never the only signal: every outcome has a word and a
    /// symbol, and the accessibility label carries the word AND the cause.
    func testEveryOutcomeHasAWordASymbolAndASpokenCause() {
        for outcome in MCPSessionOutcome.allCases {
            XCTAssertFalse(FailureRowCopy.label(outcome).isEmpty)
            XCTAssertFalse(FailureRowCopy.symbolName(outcome).isEmpty)
        }
        XCTAssertEqual(FailureRowCopy.label(.timedOut), "Timed out")
        let spoken = FailureRowCopy.accessibilityLabel(FailureRowFacts(outcome: .aborted, phase: .response, detail: "Cut.", clientCancelled: true))
        XCTAssertEqual(spoken, "Aborted: Cut. Cancelled by the app.")
    }

    /// The 502 ReqRes itself sent is named as ReqRes's — never read as the
    /// server's (C6.8: "a ReqRes-generated 502 reads as the server's").
    func testA502ReqResSentIsSaidToBeReqRessOwn() {
        let dial = FailureRowFacts(outcome: .failed, phase: .connect, status: "502")
        XCTAssertTrue(FailureRowCopy.answeredWithBadGateway(dial))
        XCTAssertTrue(FailureRowCopy.notes(dial).contains(FailureRowCopy.badGatewayNeverSentNote))
        XCTAssertFalse(FailureRowCopy.answeredWithBadGateway(FailureRowFacts(outcome: .failed, phase: .connect, status: nil)))
        XCTAssertFalse(FailureRowCopy.answeredWithBadGateway(FailureRowFacts(outcome: .aborted, phase: .response, status: "502")),
                       "an aborted 502 came from the server")
        XCTAssertFalse(FailureRowCopy.answeredWithBadGateway(FailureRowFacts(outcome: .failed, phase: .request, status: "502")),
                       "a request ReqRes refused is not a dial it answered")
        XCTAssertFalse(FailureRowCopy.answeredWithBadGateway(FailureRowFacts(outcome: .failed, phase: .tlsClient, status: "502")),
                       "the app refused ReqRes's certificate; nothing was answered")
    }

    /// Only a failure to resolve or connect proves the server never saw the
    /// request. A 502 at `response` (the server hung up after the request) or
    /// `tlsUpstream` (a TLS 1.3 client-certificate alert after the request
    /// went up, C6.2(b)) may have run a POST or DELETE — saying otherwise
    /// invites sending it again.
    func testA502AfterTheRequestWentUpNeverClaimsTheServerDidNotSeeIt() {
        for phase in [MCPFailurePhase.dns, .connect] {
            let facts = FailureRowFacts(outcome: .failed, phase: phase, status: "502")
            XCTAssertTrue(FailureRowCopy.notes(facts).contains { $0.contains("never saw the request") }, "\(phase)")
            XCTAssertTrue(FailureRowCopy.agentOutcomeLine(facts).contains("never saw the request"), "\(phase)")
        }
        for phase in [MCPFailurePhase.response, .tlsUpstream, .other] {
            let facts = FailureRowFacts(outcome: .failed, phase: phase, status: "502")
            XCTAssertTrue(FailureRowCopy.answeredWithBadGateway(facts), "\(phase)")
            let notes = FailureRowCopy.notes(facts)
            XCTAssertFalse(notes.contains { $0.contains("never saw") }, "\(phase): \(notes)")
            XCTAssertTrue(notes.contains(FailureRowCopy.badGatewayMayHaveReachedNote), "\(phase)")
            let line = FailureRowCopy.agentOutcomeLine(facts)
            XCTAssertFalse(line.contains("never saw"), line)
            XCTAssertTrue(line.contains("may have reached the server"), line)
        }
        let helpAbout502 = FailureRowCopy.helpBullets.filter { $0.contains("502") }
        XCTAssertFalse(helpAbout502.isEmpty)
        for bullet in helpAbout502 {
            XCTAssertFalse(bullet.contains("and the server never saw the request"), bullet)
            XCTAssertTrue(bullet.contains("may have run"), bullet)
        }
    }

    // MARK: - Actions

    /// The pinning case offers "Exclude <host>"; a command-line tool gets
    /// "Export the CA" first (it reads trust from a file); nothing else gets
    /// an action, and an already-excluded host is not offered again.
    func testActionsFollowThePhaseAndTheProcess() {
        let pinned = FailureRowFacts(outcome: .failed, phase: .tlsClient)
        XCTAssertEqual(FailureRowCopy.actions(pinned, host: "api.bank.example", isCommandLineTool: false, hostAlreadyExcluded: false),
                       [.excludeHost("api.bank.example")])
        XCTAssertEqual(FailureRowCopy.actions(pinned, host: "registry.npmjs.org", isCommandLineTool: true, hostAlreadyExcluded: false),
                       [.exportCertificateAndEnvironment, .excludeHost("registry.npmjs.org")])
        XCTAssertEqual(FailureRowCopy.actions(pinned, host: "api.bank.example", isCommandLineTool: false, hostAlreadyExcluded: true), [])
        XCTAssertEqual(FailureRowCopy.actions(FailureRowFacts(outcome: .failed, phase: .tlsUpstream), host: "dev.local", isCommandLineTool: false, hostAlreadyExcluded: false), [],
                       "the SERVER's certificate is not fixed by excluding it from interception")
        XCTAssertEqual(FailureRowCopy.actions(FailureRowFacts(outcome: .aborted, phase: .response), host: "a.com", isCommandLineTool: true, hostAlreadyExcluded: false), [])
        XCTAssertEqual(FailureRowCopy.actions(FailureRowFacts(outcome: .aborted, phase: .tlsClient), host: "a.com", isCommandLineTool: true, hostAlreadyExcluded: false), [],
                       "only a FAILED handshake is the pinning case")
        XCTAssertEqual(FailureRowCopy.actions(FailureRowFacts(outcome: .timedOut, phase: .tlsClient), host: "a.com", isCommandLineTool: false, hostAlreadyExcluded: false), [])
        XCTAssertEqual(FailureRowCopy.buttonTitle(.excludeHost("api.bank.example")), "Exclude api.bank.example…")
    }

    /// The core's refusal sentence already ends "exclude the host…"; the
    /// banner does not say it a second time. The CA export's sentence always
    /// shows — the core never mentions it.
    func testTheButtonsSentenceIsLeftOutWhenTheCauseAlreadySaysIt() {
        let coreSentence = "The app refused ReqRes's certificate for a.example (TLS alert: bad certificate). Apps that pin their certificates do this; exclude the host to let its traffic through unrecorded."
        XCTAssertNil(FailureRowCopy.explanation(.excludeHost("a.example"), cause: coreSentence))
        XCTAssertNotNil(FailureRowCopy.explanation(.excludeHost("a.example"), cause: "The TLS handshake between the app and ReqRes for a.example failed (no shared cipher)."))
        XCTAssertNotNil(FailureRowCopy.explanation(.exportCertificateAndEnvironment, cause: coreSentence))
    }

    /// Which processes get the CA-export action: a named executable outside
    /// any bundle, never an app, a system service or an unknown process.
    func testACommandLineToolIsANamedExecutableOutsideAnyBundle() {
        XCTAssertTrue(ProcessIdentity(name: "node", pid: 1, executablePath: "/opt/homebrew/bin/node").isCommandLineTool)
        XCTAssertFalse(ProcessIdentity(name: "Safari", pid: 2, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari").isCommandLineTool)
        XCTAssertFalse(ProcessIdentity(name: nil, pid: 3, executablePath: nil).isCommandLineTool)
        XCTAssertFalse(ProcessIdentity(name: "nsurlsessiond", pid: 4, executablePath: "/usr/libexec/nsurlsessiond").isCommandLineTool)
    }

    /// PRD 3.5's words, in both the human's confirmation and the agent's panel.
    func testTheExclusionConsequenceIsTheSameSentenceEverywhere() {
        let sentence = "ReqRes will stop recording api.bank.example; you will no longer see its traffic."
        XCTAssertEqual(FailureRowCopy.exclusionConsequence("api.bank.example"), sentence)
        XCTAssertTrue(FailureRowCopy.excludeConfirmation("api.bank.example").hasPrefix(sentence))
        XCTAssertTrue(FailureRowCopy.excludeConfirmation("api.bank.example").contains(FailureRowCopy.exclusionScope),
                      "the human's confirmation and the agent's panel state the same per-scheme scope")
    }

    // MARK: - The outcome filter

    func testTheOutcomeFilterIsReadNormalisedAndRefusedWhenUnusable() throws {
        let filter = try MCPSessionFilter(queryItems: [URLQueryItem(name: "outcome", value: "Timed-Out")])
        XCTAssertEqual(filter.outcome, "timed_out")
        XCTAssertEqual(filter.summaryText, "outcome=timed_out")
        XCTAssertThrowsError(try MCPSessionFilter(queryItems: [URLQueryItem(name: "outcome", value: "broken")])) { error in
            XCTAssertEqual((error as? MCPQueryParameterError)?.parameter, "outcome")
        }
    }

    func testTheOutcomeFilterMatchesAndAnOlderRowIsCompleted() {
        let filterFailed = MCPSessionFilter(outcome: "failed")
        XCTAssertTrue(filterFailed.matches(failed("f")))
        XCTAssertFalse(filterFailed.matches(cancelled("c")))
        XCTAssertFalse(filterFailed.matches(makeSession(uid: "old")))
        XCTAssertTrue(MCPSessionFilter(outcome: "completed").matches(makeSession(uid: "old")), "nil outcome is completed")
        XCTAssertFalse(MCPSessionFilter(outcome: "nonsense").matches(failed("f")), "a hand-built unusable value matches nothing")
    }

    /// The route refuses an unusable value with a 400 rather than an
    /// unfiltered page that reads as filtered.
    func testTheSessionsRouteFiltersByOutcomeAndRefusesAnUnusableOne() throws {
        let router = MCPBridgeRouter(
            token: "t",
            sessions: StubSessionProvider(summaries: [completed("ok"), failed("bad"), cancelled("gone")]),
            status: StubStatusProvider()
        )
        let page = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/sessions?outcome=failed", token: "t"))))
        XCTAssertEqual(page.status, 200)
        let rows = try XCTUnwrap(page.json?["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["uid"] as? String }, ["bad"])
        XCTAssertEqual(rows.first?["outcome"] as? String, "failed")
        XCTAssertEqual(rows.first?["failurePhase"] as? String, "connect")

        let refused = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: "/v1/sessions?outcome=broken", token: "t"))))
        XCTAssertEqual(refused.status, 400)
    }

    // MARK: - Waits skip failures unless asked (D8)

    /// Scripted pages and a virtual clock (the waiter tests' shape).
    private final class Script {
        let pages: [[MCPSessionSummary]]
        private var index = 0
        private var now: TimeInterval = 0
        init(_ pages: [[MCPSessionSummary]]) { self.pages = pages }
        func fetch() async throws -> [MCPSessionSummary] {
            defer { index += 1 }
            return pages[min(index, pages.count - 1)]
        }
        func sleep(_ interval: TimeInterval) async throws { now += interval }
        func elapsed() -> TimeInterval { now }
    }

    func testAWaitSkipsAFailureByDefaultAndResolvesOnTheNextCompletedRequest() async throws {
        let script = Script([
            [],
            [cancelled("c1"), failed("f1")],
            [completed("ok"), cancelled("c1"), failed("f1")],
        ])
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(), timeout: 10,
            fetch: script.fetch, elapsed: script.elapsed, sleep: script.sleep
        )
        XCTAssertEqual(outcome.session?.uid, "ok")
    }

    func testIncludeFailedResolvesOnTheEarliestFailure() async throws {
        let script = Script([[], [completed("ok"), failed("f1")]])
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(), includeFailed: true, timeout: 10,
            fetch: script.fetch, elapsed: script.elapsed, sleep: script.sleep
        )
        XCTAssertEqual(outcome.session?.uid, "f1", "newest-first input, so the earliest new match is the failure")
    }

    /// Asking for `outcome=aborted` IS asking for failures.
    func testAnOutcomeFilterNamingAFailureIsAskingForOne() async throws {
        let script = Script([[], [cancelled("c1")]])
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(outcome: "aborted"), timeout: 10,
            fetch: script.fetch, elapsed: script.elapsed, sleep: script.sleep
        )
        XCTAssertEqual(outcome.session?.uid, "c1")
    }

    func testTheCollectorSkipsFailuresUnlessAsked() async throws {
        for includeFailed in [false, true] {
            let script = Script([[], [completed("ok"), cancelled("c1"), failed("f1")]])
            let outcome = try await MCPSessionCollector.collect(
                filter: MCPSessionFilter(), includeFailed: includeFailed, timeout: 30, settleInterval: 1,
                fetch: script.fetch, elapsed: script.elapsed, sleep: script.sleep
            )
            XCTAssertEqual(outcome.sessions.map(\.uid), includeFailed ? ["f1", "c1", "ok"] : ["ok"], "includeFailed=\(includeFailed)")
        }
    }

    func testAnEmptyWaitSaysFailuresWereSkipped() {
        let empty = MCPSessionWaiter.Outcome(session: nil, timedOut: true, polls: 3)
        XCTAssertTrue(MCPTextFormat.waitOutcome(empty, timeout: 5).contains("include_failed=true"))
        XCTAssertFalse(MCPTextFormat.waitOutcome(empty, timeout: 5, includeFailed: true).contains("include_failed=true"))
        let none = MCPSessionCollector.Outcome(sessions: [], stopReason: .timedOut, polls: 3)
        XCTAssertTrue(MCPTextFormat.collectOutcome(none, timeout: 5).contains("include_failed=true"))
    }

    // MARK: - Text

    func testARowAndADetailSayHowTheRequestEnded() {
        let row = MCPTextFormat.row(failed("f1", phase: .dns, detail: "reqres.invalid did not resolve."))
        XCTAssertTrue(row.contains("outcome=failed(dns)"), row)
        XCTAssertTrue(MCPTextFormat.row(cancelled("c")).contains("outcome=aborted(response) cancelled_by_app"))

        let detail = MCPTextFormat.detail(MCPSessionDetail(summary: failed("f1")))
        XCTAssertTrue(detail.contains("Outcome: failed at connect — ReqRes could not connect to api.example.com:443 (connection refused)."), detail)
        XCTAssertTrue(detail.contains("ReqRes answered the app 502"), detail)
        XCTAssertFalse(MCPTextFormat.detail(MCPSessionDetail(summary: completed("ok"))).contains("Outcome:"))
    }

    // MARK: - HAR

    private func harEntry(_ summary: MCPSessionSummary) throws -> [String: Any] {
        let result = MCPHARExport.encode(sessions: [MCPSessionDetail(summary: summary)], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let log = try XCTUnwrap(json["log"] as? [String: Any])
        return try XCTUnwrap((log["entries"] as? [[String: Any]])?.first)
    }

    /// A failed row got no answer from any server — the 502 it carries is
    /// ReqRes's — so HAR writes status 0 and `_error`, Chrome's convention.
    func testHARWritesAFailedRowWithStatusZeroAndAnError() throws {
        let entry = try harEntry(failed("f1"))
        let response = try XCTUnwrap(entry["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 0)
        XCTAssertEqual(entry["_error"] as? String, "ReqRes could not connect to api.example.com:443 (connection refused).")
        XCTAssertEqual(entry["_reqresOutcome"] as? String, "failed")
        XCTAssertEqual(entry["_reqresFailurePhase"] as? String, "connect")
        XCTAssertNil(entry["_reqresClientCancelled"])
    }

    func testHARKeepsAnAbortedRowsStatusAndMarksIt() throws {
        let entry = try harEntry(cancelled("c1"))
        XCTAssertEqual((entry["response"] as? [String: Any])?["status"] as? Int, 200, "a 200 cut mid-body is still a 200")
        XCTAssertNotNil(entry["_error"])
        XCTAssertEqual(entry["_reqresClientCancelled"] as? Bool, true)
    }

    func testHARWritesNothingExtraForACompletedRow() throws {
        let entry = try harEntry(completed("ok"))
        XCTAssertNil(entry["_error"])
        XCTAssertNil(entry["_reqresOutcome"])
        XCTAssertEqual((entry["response"] as? [String: Any])?["status"] as? Int, 200)
    }

    // MARK: - Destinations

    /// A request that failed before connecting went nowhere: it is not an
    /// Unknown destination, it is no destination. Left out, and counted.
    func testNeverConnectedFailuresAreLeftOutOfDestinationsAndCounted() {
        var placed = makeSession(uid: "p", country: "US")
        placed.outcome = .completed
        var unplaceable = makeSession(uid: "u", country: nil)
        unplaceable.outcome = .completed
        let tlsUpstream = failed("t", phase: .tlsUpstream, neverConnected: false)
        let report = MCPDestinationAggregation.report(
            summaries: [placed, unplaceable, failed("d", phase: .dns), failed("x", phase: .tlsClient), tlsUpstream],
            filter: MCPSessionFilter()
        )
        XCTAssertEqual(report.neverConnected, 2)
        XCTAssertEqual(report.totalRequests, 3)
        XCTAssertEqual(report.destinations.first { $0.country == "unknown" }?.requests, 2, "the unplaceable completed row and the server-TLS failure")
        let text = MCPTextFormat.destinations(report)
        XCTAssertTrue(text.contains("2 requests that failed before connecting to any server are not counted"), text)
    }

    // MARK: - Diagnosis

    private func facts(_ rejections: [MCPTLSRejection]?, sessions: Int = 40) -> MCPSetupFacts {
        MCPSetupFacts(
            status: MCPBridgeStatus(captureActive: true, vpnStatus: "connected", extensionStatus: "ready",
                                    caCertificateInstalled: true, caCertificateTrusted: true, sessionCount: sessions),
            runningFromApplications: true,
            proxyPort: MCPLimits.proxyPort,
            proxyPortListening: true,
            licensed: true,
            tlsRejections: rejections
        )
    }

    func testTheTLSRejectionsCheckNamesHostsAndProcessesAndTheExcludeAction() throws {
        let report = MCPSetupDiagnosis.report(facts([
            MCPTLSRejection(host: "api.bank.example", app: "BankApp", count: 3),
            MCPTLSRejection(host: "registry.npmjs.org", app: "node", count: 1),
        ]))
        let check = try XCTUnwrap(report.checks.first { $0.id == "tls_rejections" })
        XCTAssertEqual(check.state, .warning)
        XCTAssertTrue(check.detail.contains("api.bank.example by BankApp (3 times)"), check.detail)
        XCTAssertTrue(check.detail.contains("registry.npmjs.org by node (once)"), check.detail)
        XCTAssertTrue(check.fix?.contains("exclude_host host=api.bank.example") ?? false)
        XCTAssertTrue(check.fix?.contains("capture_environment") ?? false)
        XCTAssertNil(report.blockingCheckId, "an app refusing the certificate does not stop capture")
        XCTAssertTrue(check.fix?.contains("list_sessions outcome=failed") ?? false)
        XCTAssertFalse(check.detail.contains("list_sessions"), "the detail is read by the human too; the agent's script is in the fix")
    }

    /// The verdict is the menu bar's tooltip: it never names a host, and a
    /// pinning app on an otherwise healthy machine does not stand in front
    /// of "set up correctly".
    func testTLSRejectionsNeverBecomeTheVerdict() {
        let report = MCPSetupDiagnosis.report(facts([
            MCPTLSRejection(host: "api.bank.example", app: "BankApp", count: 3),
        ]))
        XCTAssertEqual(report.checks.first { $0.id == "tls_rejections" }?.state, .warning, "the agent still sees it")
        XCTAssertFalse(report.verdict.contains("api.bank.example"), report.verdict)
        XCTAssertFalse(report.verdict.contains("BankApp"), report.verdict)
        XCTAssertEqual(report.verdict, MCPSetupDiagnosis.report(facts([])).verdict,
                       "the verdict is what it would be with no rejections at all")
    }

    /// Capture ▸ Diagnose Setup… shows a human fix, not the agent's script.
    func testTheTLSRejectionsFixHasAHumanWording() throws {
        let report = MCPSetupDiagnosis.report(facts([MCPTLSRejection(host: "a.example", count: 1)]))
        let check = try XCTUnwrap(report.checks.first { $0.id == "tls_rejections" })
        let human = try XCTUnwrap(MCPSetupDiagnosis.humanFix(for: check))
        for agentWord in ["exclude_host", "capture_environment", "list_sessions", "call ", "the user"] {
            XCTAssertFalse(human.contains(agentWord), "\(agentWord) in: \(human)")
        }
        XCTAssertTrue(human.contains("Exclude"))
        let traffic = try XCTUnwrap(report.checks.first { $0.id == "traffic" })
        XCTAssertNil(MCPSetupDiagnosis.humanFix(for: traffic), "every other check keeps the app's own rewording")
    }

    func testTheTLSRejectionsCheckIsOkWhenNoneAndAbsentWhenNotCounted() {
        let none = MCPSetupDiagnosis.report(facts([]))
        XCTAssertEqual(none.checks.first { $0.id == "tls_rejections" }?.state, .ok)
        XCTAssertNil(MCPSetupDiagnosis.report(facts(nil)).checks.first { $0.id == "tls_rejections" })
        XCTAssertNil(MCPSetupDiagnosis.report(facts([], sessions: 0)).checks.first { $0.id == "tls_rejections" },
                     "nothing recorded yet is not a finding")
    }

    func testTheCheckListsFiveAndCountsTheRest() throws {
        let many = (1...7).map { MCPTLSRejection(host: "h\($0).example", count: 1) }
        let check = try XCTUnwrap(MCPSetupDiagnosis.report(facts(many)).checks.first { $0.id == "tls_rejections" })
        XCTAssertTrue(check.detail.contains("and 2 more"), check.detail)
    }

    /// Per host AND process, busiest first: the same host refused by two
    /// apps is two findings (one of them may be fixable another way).
    func testRejectionsGroupPerHostAndProcessBusiestFirst() {
        let now = Date(timeIntervalSince1970: 1_000)
        let grouped = MCPTLSRejection.group([
            (host: "a.example", app: "Safari", at: now),
            (host: "b.example", app: "node", at: now),
            (host: "B.example", app: "node", at: now.addingTimeInterval(5)),
            (host: "a.example", app: "curl", at: now),
            (host: " ", app: "x", at: now),
        ])
        XCTAssertEqual(grouped.map(\.host), ["b.example", "a.example", "a.example"])
        XCTAssertEqual(grouped.first?.count, 2)
        XCTAssertEqual(grouped.first?.lastAt, now.addingTimeInterval(5))
    }
}
