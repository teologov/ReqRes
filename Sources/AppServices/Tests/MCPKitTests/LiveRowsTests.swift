//
//  LiveRowsTests.swift
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
//  Live rows, the app half (protocol-engine doc §S6): the ledger that turns
//  the extension's messages into table operations, and the table rules.
//

import XCTest
@testable import MCPKit

/// A stand-in for `SessionCodable`: an id, the exchange, and enough content
/// to tell a live snapshot from its final row.
struct TestRow: LiveTableRow, Equatable {
    var id: UUID
    var exchangeID: UUID?
    var host: String = "api.example.com"
    var label: String

    init(id: UUID = UUID(), exchangeID: UUID?, host: String = "api.example.com", label: String) {
        self.id = id
        self.exchangeID = exchangeID
        self.host = host
        self.label = label
    }
}

/// Feeds messages through a ledger and applies them to a table, the way the
/// app's flush does.
struct LiveHarness {
    var ledger = LiveRowLedger<TestRow>()
    var rows: [TestRow] = []
    var inFlight = Set<UUID>()
    var cap = 5_000
    var now: TimeInterval = 0
    var lastReport = LiveRowTable.Report<TestRow>()
    var lastOperations: [LiveRowOperation<TestRow>] = []

    @discardableResult
    mutating func feed(_ messages: [LiveIngestMessage<TestRow>]) -> [LiveRowOperation<TestRow>] {
        var operations: [LiveRowOperation<TestRow>] = []
        for message in messages { operations += ledger.ingest(message, now: now) }
        operations = LiveRowOperation.coalesced(operations)
        lastOperations = operations
        lastReport = LiveRowTable.apply(operations, to: &rows, inFlight: &inFlight, cap: cap)
        return operations
    }

    mutating func apply(_ operations: [LiveRowOperation<TestRow>]) {
        lastOperations = operations
        lastReport = LiveRowTable.apply(operations, to: &rows, inFlight: &inFlight, cap: cap)
    }
}

func started(_ exchange: UUID, label: String = "live", phase: LivePhase = .waiting, contentType: String? = nil,
             host: String = "api.example.com") -> LiveIngestMessage<TestRow> {
    .started(LiveStartInput(exchangeID: exchange, phase: phase, row: TestRow(exchangeID: exchange, host: host, label: label),
                            contentType: contentType))
}

func progress(_ exchange: UUID, _ sequence: Int, phase: LivePhase? = .streaming, text: String? = nil, offset: Int64 = 0,
              bytes: Int64 = 0, row: TestRow? = nil, contentType: String? = nil) -> LiveIngestMessage<TestRow> {
    .progress(LiveProgressInput(exchangeID: exchange, sequence: sequence, phase: phase, responseBytes: bytes,
                                appendedText: text, textOffset: offset, textStatus: .text, row: row,
                                contentType: contentType, responseHeadAt: row == nil ? nil : 100, sentAt: 100.5))
}

func final(_ exchange: UUID?, label: String = "final", host: String = "api.example.com") -> LiveIngestMessage<TestRow> {
    .final(TestRow(exchangeID: exchange, host: host, label: label))
}

final class LiveRowLedgerTests: XCTestCase {

    // MARK: Upsert order

    func testStartedThenProgressThenFinalIsOneRowReplacedInPlaceUnderOneID() throws {
        var h = LiveHarness()
        let x = UUID()
        h.feed([final(UUID(), label: "older")])
        h.feed([started(x)])
        XCTAssertEqual(h.rows.map(\.label), ["live", "older"])
        let rowID = h.rows[0].id
        XCTAssertTrue(h.inFlight.contains(rowID))

        // The head arrives: the snapshot replaces the row, same id.
        h.feed([progress(x, 1, row: TestRow(exchangeID: x, label: "with head"), contentType: "application/json")])
        XCTAssertEqual(h.rows.map(\.label), ["with head", "older"])
        XCTAssertEqual(h.rows[0].id, rowID)

        // Something else arrives above it; the final replaces it WHERE IT IS.
        h.feed([final(UUID(), label: "newer")])
        h.feed([final(x)])
        XCTAssertEqual(h.rows.map(\.label), ["newer", "final", "older"])
        XCTAssertEqual(h.rows[1].id, rowID, "the final keeps the live row's id")
        XCTAssertTrue(h.inFlight.isEmpty)
        XCTAssertEqual(h.ledger.inFlightCount, 0)
    }

    func testEverythingInOneFlushLandsAsTheFinalRowOnly() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x), progress(x, 1, text: "a"), final(x)])
        XCTAssertEqual(h.rows.map(\.label), ["final"])
        XCTAssertTrue(h.inFlight.isEmpty)
        XCTAssertEqual(h.lastReport.inserted.map(\.label), ["final"])
        XCTAssertTrue(h.lastReport.replaced.isEmpty)
    }

    func testAFinalBeforeItsStartedIsInsertedAndTheLateStartedAndProgressAreDropped() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([final(x)])
        XCTAssertEqual(h.feed([started(x)]).count, 0)
        XCTAssertEqual(h.feed([progress(x, 1, text: "late")]).count, 0)
        XCTAssertEqual(h.rows.map(\.label), ["final"])
        XCTAssertTrue(h.inFlight.isEmpty)
    }

    func testADuplicateFinalIsDropped() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x)])
        h.feed([final(x)])
        XCTAssertEqual(h.feed([final(x, label: "again")]).count, 0)
        XCTAssertEqual(h.rows.map(\.label), ["final"])

        // And for a fast exchange that never went live.
        let y = UUID()
        h.feed([final(y, label: "fast")])
        h.feed([final(y, label: "fast again")])
        XCTAssertEqual(h.rows.map(\.label), ["fast", "final"])
    }

    func testARowFromACoreWithoutExchangeIDsIsAlwaysInserted() {
        var h = LiveHarness()
        h.feed([final(nil, label: "a"), final(nil, label: "b")])
        XCTAssertEqual(h.rows.map(\.label), ["b", "a"])
    }

    func testProgressForAnUnknownExchangeIsIgnored() {
        var h = LiveHarness()
        XCTAssertTrue(h.feed([progress(UUID(), 1, text: "who?")]).isEmpty)
        XCTAssertTrue(h.rows.isEmpty)
    }

    func testWithdrawnRemovesTheLiveRowAndAFinalAfterItIsDropped() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([final(UUID(), label: "other")])
        h.feed([started(x)])
        h.feed([progress(x, 1, phase: nil)])
        XCTAssertEqual(h.rows.map(\.label), ["other"])
        XCTAssertEqual(h.lastReport.removed.map(\.label), ["live"])
        XCTAssertTrue(h.inFlight.isEmpty)
        XCTAssertTrue(h.feed([final(x)]).isEmpty)
        XCTAssertEqual(h.rows.map(\.label), ["other"])
    }

    func testAStaleOrRepeatedSequenceIsIgnored() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x), progress(x, 2, text: "ab", offset: 0)])
        XCTAssertTrue(h.feed([progress(x, 2, text: "ab", offset: 0)]).isEmpty)
        XCTAssertTrue(h.feed([progress(x, 1, text: "zz", offset: 0)]).isEmpty)
        XCTAssertEqual(h.ledger.state(forExchange: x)?.textBytes, 2)
    }

    // MARK: Eviction

    func testTheCapNeverEvictsAnInFlightRowItTakesTheOldestCompletedOnes() {
        var h = LiveHarness()
        h.cap = 3
        let x = UUID()
        h.feed([started(x)])
        let liveID = h.rows[0].id
        h.feed((1...5).map { final(UUID(), label: "f\($0)") })
        XCTAssertEqual(h.rows.map(\.label), ["f5", "f4", "live"])
        XCTAssertEqual(Set(h.lastReport.evicted.map(\.label)), ["f1", "f2", "f3"])
        XCTAssertTrue(h.inFlight.contains(liveID))
        // It still finalizes in place.
        h.feed([final(x)])
        XCTAssertEqual(h.rows.map(\.label), ["f5", "f4", "final"])
    }

    func testInFlightRowsMayTakeTheTableOverTheCap() {
        var h = LiveHarness()
        h.cap = 1
        h.feed([started(UUID(), label: "a"), started(UUID(), label: "b"), started(UUID(), label: "c")])
        XCTAssertEqual(h.rows.map(\.label), ["c", "b", "a"])
        XCTAssertTrue(h.lastReport.evicted.isEmpty)
    }

    func testAFinalForARowThatWasEvictedIsDroppedNotReinserted() {
        var h = LiveHarness()
        h.cap = 2
        let x = UUID()
        h.feed([started(x)])
        // It ends (stale) — an ordinary row now — and is then evicted.
        h.now = LiveRowLedger<TestRow>.staleAfter + 1
        h.apply(h.ledger.sweep(now: h.now))
        XCTAssertTrue(h.inFlight.isEmpty)
        h.feed([final(UUID(), label: "n1"), final(UUID(), label: "n2")])
        XCTAssertFalse(h.rows.contains { $0.label == "live" })
        // The late final: not re-inserted.
        h.feed([final(x, label: "late")])
        XCTAssertEqual(h.rows.map(\.label), ["n2", "n1"])
        XCTAssertEqual(h.lastReport.dropped, 1)
    }

    func testAFinalForARowTheUserDeletedIsDropped() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x)])
        let rowID = h.rows[0].id
        h.rows.removeAll { $0.id == rowID }
        h.inFlight.remove(rowID)
        h.ledger.forget(exchangeIDs: [x])
        XCTAssertTrue(h.feed([final(x)]).isEmpty)
        XCTAssertTrue(h.rows.isEmpty)
    }

    func testAFinalForALiveRowDeletedBeforeTheLedgerHeardIsDroppedByTheTable() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x)])
        h.rows.removeAll()
        h.feed([final(x)])
        XCTAssertTrue(h.rows.isEmpty, "a finalize whose row is gone is dropped, never inserted")
        XCTAssertEqual(h.lastReport.dropped, 1)
    }

    // MARK: Ending

    func testASilentRowEndsAfterTheIdleLimitPlusMarginAndNotBefore() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x)])
        XCTAssertTrue(h.ledger.sweep(now: LiveRowLedger<TestRow>.staleAfter - 1).isEmpty)
        XCTAssertEqual(LiveRowLedger<TestRow>.staleAfter, 360)
        let ended = h.ledger.sweep(now: LiveRowLedger<TestRow>.staleAfter + 1)
        h.apply(ended)
        XCTAssertEqual(h.lastReport.ended.map(\.reason), [.stale])
        XCTAssertEqual(h.rows.count, 1, "the row stays, as an ordinary row")
        XCTAssertTrue(h.inFlight.isEmpty)
        // Progress after the end is ignored.
        XCTAssertTrue(h.feed([progress(x, 5, text: "x")]).isEmpty)
    }

    func testProgressKeepsARowAlive() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x)])
        h.now = 300
        h.feed([progress(x, 1, bytes: 10)])
        XCTAssertTrue(h.ledger.sweep(now: 600).isEmpty)
        XCTAssertEqual(h.ledger.sweep(now: 661).count, 1)
    }

    func testStoppingCaptureEndsEveryLiveRowAndALateFinalStillReplacesIt() {
        var h = LiveHarness()
        let x = UUID(), y = UUID()
        h.feed([started(x, label: "x"), started(y, label: "y")])
        let xID = h.rows.first { $0.label == "x" }!.id
        h.apply(h.ledger.endAll(reason: .captureStopped))
        XCTAssertEqual(h.lastReport.ended.count, 2)
        XCTAssertTrue(h.lastReport.ended.allSatisfy { $0.reason == .captureStopped })
        XCTAssertTrue(h.inFlight.isEmpty)
        // A final that arrives after the stop is the truth the ended row stood
        // in for: it replaces it, same id.
        h.feed([final(x, label: "x final")])
        XCTAssertEqual(h.rows.first { $0.id == xID }?.label, "x final")
        XCTAssertEqual(h.rows.count, 2)
        XCTAssertTrue(h.feed([final(x, label: "dup")]).isEmpty)
    }

    // MARK: Text

    func testTextIsAppendedOnlyWhenItsOffsetMatches() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x)])
        let a = h.feed([progress(x, 1, text: "héllo", offset: 0)])
        guard case .updateLive(_, let s1, let t1) = a[0] else { return XCTFail() }
        XCTAssertEqual(t1.map(\.text), ["héllo"])
        XCTAssertEqual(s1.textBytes, 6, "UTF-8 bytes, not characters")
        let b = h.feed([progress(x, 2, text: " world", offset: 6)])
        guard case .updateLive(_, _, let t2) = b[0] else { return XCTFail() }
        XCTAssertEqual(t2.map(\.text), [" world"])
        // A gap: the text stops, and never resumes with a hole in it.
        let c = h.feed([progress(x, 4, text: "later", offset: 40)])
        guard case .updateLive(_, let s3, let t3) = c[0] else { return XCTFail() }
        XCTAssertTrue(t3.isEmpty)
        XCTAssertTrue(s3.textIncomplete)
        let d = h.feed([progress(x, 5, text: "more", offset: 12)])
        guard case .updateLive(_, let s4, let t4) = d[0] else { return XCTFail() }
        XCTAssertTrue(t4.isEmpty)
        XCTAssertEqual(s4.textBytes, 12)
    }

    func testCompleteMessagesAreCountedAndAnUnfinishedOneIsPending() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x, phase: .streaming, contentType: "text/event-stream; charset=utf-8")])
        let ops = h.feed([progress(x, 1, text: "data: {\"a\":1}\n\ndata: {\"b\"", offset: 0)])
        guard case .updateLive(_, let state, _) = ops[0] else { return XCTFail() }
        XCTAssertEqual(state.streamFormat, .sse)
        XCTAssertEqual(state.completeMessages, 1)
        XCTAssertEqual(state.pendingBytes, "data: {\"b\"".utf8.count)
        let more = h.feed([progress(x, 2, text: ":2}\n\n", offset: Int64("data: {\"a\":1}\n\ndata: {\"b\"".utf8.count))])
        guard case .updateLive(_, let after, _) = more[0] else { return XCTFail() }
        XCTAssertEqual(after.completeMessages, 2)
        XCTAssertEqual(after.pendingBytes, 0)
    }

    func testAStreamAnnouncedWhileWaitingGetsItsCounterWhenTheHeadArrives() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x)])
        let ops = h.feed([progress(x, 1, text: "{\"n\":1}\n{\"n\"", offset: 0,
                                   row: TestRow(exchangeID: x, label: "head"), contentType: "application/x-ndjson")])
        guard case .updateLive(_, let state, let text) = ops[0] else { return XCTFail() }
        XCTAssertEqual(state.streamFormat, .ndjson)
        XCTAssertEqual(state.completeMessages, 1)
        XCTAssertEqual(text.first?.receivedAt, 0.5, "seconds after the response head")
    }

    func testANonStreamHasNoMessageCount() {
        var h = LiveHarness()
        let x = UUID()
        h.feed([started(x, phase: .streaming, contentType: "application/json")])
        let ops = h.feed([progress(x, 1, text: "{\"a\":", offset: 0)])
        guard case .updateLive(_, let state, _) = ops[0] else { return XCTFail() }
        XCTAssertNil(state.streamFormat)
        XCTAssertEqual(MCPLiveState(state: state, elapsedSeconds: nil).completeMessages, nil)
    }

    // MARK: Coalescing

    func testAFlushOfManyProgressMessagesIsOneUpdatePerRowWithTheTextInOrder() {
        var ledger = LiveRowLedger<TestRow>()
        let x = UUID(), y = UUID()
        var ops: [LiveRowOperation<TestRow>] = []
        ops += ledger.ingest(started(x), now: 0)
        ops += ledger.ingest(started(y), now: 0)
        ops += ledger.ingest(progress(x, 1, text: "a", offset: 0), now: 0)
        ops += ledger.ingest(progress(y, 1, text: "1", offset: 0), now: 0)
        ops += ledger.ingest(progress(x, 2, text: "b", offset: 1), now: 0)
        ops += ledger.ingest(progress(x, 3, text: "c", offset: 2, bytes: 3), now: 0)
        let merged = LiveRowOperation.coalesced(ops)
        XCTAssertEqual(merged.count, 2, "each insert absorbs its row's updates")
        guard case .insertLive(_, let state, let text) = merged[0] else { return XCTFail() }
        XCTAssertEqual(text.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(state.responseBytes, 3)
        XCTAssertEqual(state.lastSequence, 3)
    }

    func testBoundedIDSetForgetsTheOldest() {
        var set = BoundedIDSet(capacity: 3)
        let ids = (0..<5).map { _ in UUID() }
        ids.forEach { set.insert($0) }
        XCTAssertEqual(set.count, 3)
        XCTAssertFalse(set.contains(ids[0]))
        XCTAssertFalse(set.contains(ids[1]))
        XCTAssertTrue(set.contains(ids[4]))
    }

    // MARK: Per-host lists

    func testMirrorKeepsAHostListInStepAndReportsWhatEnteredAndLeft() {
        var h = LiveHarness()
        let x = UUID()
        var hostList: [TestRow] = []
        h.feed([started(x, host: "a.test"), final(UUID(), label: "other", host: "b.test")])
        var change = LiveRowTable.mirror(h.lastReport, into: &hostList, belongs: { $0.host == "a.test" }, inFlight: h.inFlight, cap: 10)
        XCTAssertEqual(hostList.map(\.label), ["live"])
        XCTAssertEqual(change.entered.map(\.label), ["live"])
        h.feed([final(x, host: "a.test")])
        change = LiveRowTable.mirror(h.lastReport, into: &hostList, belongs: { $0.host == "a.test" }, inFlight: h.inFlight, cap: 10)
        XCTAssertEqual(hostList.map(\.label), ["final"])
        XCTAssertEqual(change.left.map(\.label), ["live"])
        XCTAssertEqual(change.entered.map(\.label), ["final"])
    }
}

// MARK: - wait_for_session(until:)

final class LiveWaitTests: XCTestCase {
    private func summary(_ uid: String, live: MCPLiveState? = nil, status: Int? = 200) -> MCPSessionSummary {
        var session = makeSession(uid: uid, statusCode: status)
        session.live = live
        return session
    }

    private func waiting(_ uid: String) -> MCPSessionSummary { summary(uid, live: MCPLiveState(phase: .waiting), status: nil) }
    private func streaming(_ uid: String, messages: Int? = nil) -> MCPSessionSummary {
        summary(uid, live: MCPLiveState(phase: .streaming, responseBytes: 10, completeMessages: messages, pendingBytes: messages == nil ? nil : 3))
    }

    /// Runs a wait over a scripted sequence of polls (each newest first).
    private func run(_ stage: MCPWaitStage, polls: [[MCPSessionSummary]], includeFailed: Bool = false) async throws -> MCPSessionWaiter.Outcome {
        var index = 0
        var clock: TimeInterval = 0
        return try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(), includeFailed: includeFailed, until: stage, timeout: 10, pollInterval: 1,
            fetch: {
                defer { index = min(index + 1, polls.count - 1) }
                return polls[index]
            },
            elapsed: { clock },
            sleep: { clock += $0 }
        )
    }

    func testHeadersReturnsARowWhoseHeadArrivedWhileItIsStillOpen() async throws {
        let outcome = try await run(.headers, polls: [[summary("old")], [waiting("w"), summary("old")], [streaming("w"), summary("old")]])
        XCTAssertEqual(outcome.session?.uid, "w")
        XCTAssertEqual(outcome.session?.isInFlight, true)
    }

    func testCompleteWaitsForTheFinalRowUnderTheSameUID() async throws {
        let outcome = try await run(.complete, polls: [[waiting("w")], [streaming("w", messages: 3)], [summary("w")]])
        XCTAssertEqual(outcome.session?.uid, "w")
        XCTAssertEqual(outcome.session?.isInFlight, false)
        XCTAssertEqual(outcome.polls, 3, "an in-flight row at the baseline counts once it completes")
    }

    func testFirstMessageNeedsOneCompleteMessage() async throws {
        let outcome = try await run(.firstMessage, polls: [[], [streaming("s", messages: 0)], [streaming("s", messages: 1)]])
        XCTAssertEqual(outcome.session?.uid, "s")
        XCTAssertEqual(outcome.polls, 3)
    }

    func testFirstMessageOnAResponseThatIsNotAStreamMeansComplete() async throws {
        let outcome = try await run(.firstMessage, polls: [[], [streaming("j")], [streaming("j")], [summary("j")]])
        XCTAssertEqual(outcome.session?.uid, "j")
        XCTAssertEqual(outcome.session?.isInFlight, false)
    }

    func testARowPastTheStageAtTheBaselineIsOldNews() async throws {
        let outcome = try await run(.headers, polls: [[streaming("s")], [summary("s")], [summary("s")]])
        XCTAssertTrue(outcome.timedOut)
    }

    func testEveryStageIsReachedByAFinishedRow() {
        let done = summary("d")
        for stage in MCPWaitStage.allCases { XCTAssertTrue(done.hasReached(stage)) }
        XCTAssertFalse(waiting("w").hasReached(.headers))
        XCTAssertTrue(streaming("s").hasReached(.headers))
        XCTAssertFalse(streaming("s").hasReached(.complete))
    }

    func testARowEndedWithoutItsFinalIsAFailureForTheWaits() async throws {
        let ended = summary("e", live: MCPLiveState(phase: .ended, endReason: .captureStopped), status: nil)
        let skipped = try await run(.complete, polls: [[], [ended]])
        XCTAssertTrue(skipped.timedOut)
        let taken = try await run(.complete, polls: [[], [ended]], includeFailed: true)
        XCTAssertEqual(taken.session?.uid, "e")
    }

    func testTheCollectorCountsARowThatWasInFlightAtTheCallOnceItFinishes() async throws {
        let polls: [[MCPSessionSummary]] = [[waiting("w")], [streaming("w")], [summary("w")], [summary("w")]]
        var index = 0
        var clock: TimeInterval = 0
        let outcome = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(), maxCount: 1, timeout: 10, settleInterval: 5, pollInterval: 1,
            fetch: { defer { index = min(index + 1, polls.count - 1) }; return polls[index] },
            elapsed: { clock }, sleep: { clock += $0 })
        XCTAssertEqual(outcome.sessions.map(\.uid), ["w"])
        XCTAssertEqual(outcome.sessions.first?.isInFlight, false)
    }

    func testUntilParses() {
        XCTAssertEqual(MCPWaitStage.parse("headers"), .headers)
        XCTAssertEqual(MCPWaitStage.parse("first_message"), .firstMessage)
        XCTAssertEqual(MCPWaitStage.parse("COMPLETE"), .complete)
        XCTAssertNil(MCPWaitStage.parse("soon"))
    }
}

// MARK: - The agent surface

/// A provider whose one row is a stream still arriving.
private final class LiveStreamProvider: MCPSessionProviding {
    var summary: MCPSessionSummary
    var text: String?

    init(text: String?, live: MCPLiveState) {
        var summary = MCPSessionSummary(uid: "s1", host: "api.anthropic.com", method: "POST",
                                        url: "https://api.anthropic.com/v1/messages", scheme: "https",
                                        statusCode: 200, contentType: "text/event-stream")
        summary.live = live
        self.summary = summary
        self.text = text
    }

    func sessionSummaries() -> [MCPSessionSummary] { [summary] }
    func sessionDetail(uid: String) -> MCPSessionDetail? { uid == "s1" ? MCPSessionDetail(summary: summary) : nil }
    func sessionBody(uid: String, side: MCPBodySide) -> String? { nil }
    func sessionStreamFacts(uid: String) -> MCPSessionStreamFacts? {
        MCPSessionStreamFacts(isRelay: false, contentType: "text/event-stream", host: "api.anthropic.com", inFlight: summary.isInFlight)
    }
    func sessionStreamBody(uid: String) -> String? { text }
}

final class LiveAgentSurfaceTests: XCTestCase {
    private let token = "t"

    private func get(_ router: MCPBridgeRouter, _ target: String) -> ParsedResponse? {
        parseRawResponse(router.respond(to: makeRequest(target: target, token: token)))
    }

    func testAnInFlightStreamShowsOnlyItsCompleteEventsAndWithholdsTheFragment() throws {
        // The second event is cut mid-value: a secret in its tail must not
        // leave as half an event.
        let text = "data: {\"type\":\"a\"}\n\ndata: {\"type\":\"b\",\"api_key\":\"sk_live_4eC39Hq"
        let provider = LiveStreamProvider(text: text, live: MCPLiveState(phase: .streaming, completeMessages: 1, pendingBytes: 44))
        let router = MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider())
        let response = try XCTUnwrap(get(router, "/v1/sessions/s1/events"))
        XCTAssertEqual(response.status, 200)
        let body = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(body.contains("4eC39Hq"), "the unfinished tail never leaves")
        let page = try JSONDecoder().decode(MCPStreamEventsPage.self, from: response.body)
        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.facts.pendingBytes, "data: {\"type\":\"b\",\"api_key\":\"sk_live_4eC39Hq".utf8.count)
        XCTAssertEqual(page.facts.inFlight, true)
        let rendered = MCPTextFormat.streamEvents(page)
        XCTAssertTrue(rendered.contains("still streaming"))
        XCTAssertTrue(rendered.contains("bytes pending"))
    }

    func testAnUnfinishedLLMStreamReadsAsStillStreamingNotCut() throws {
        let events = StreamFixtures.anthropicToolUse.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        let head = events.prefix(4).joined(separator: "\n\n") + "\n\n"
        let log = StreamEventLog.parse(body: head, format: .sse)
        let assembly = LLMStreamAssembler.assemble(log.events)
        XCTAssertEqual(StreamEventsPresentation.assemblyLine(assembly, inFlight: true)?.hasSuffix("still streaming"), true)
        XCTAssertEqual(StreamEventsPresentation.assemblyLine(assembly)?.hasSuffix("ended without its end marker"), true)
        let provider = LiveStreamProvider(text: head, live: MCPLiveState(phase: .streaming))
        let router = MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider())
        let response = try XCTUnwrap(get(router, "/v1/sessions/s1/assembled"))
        let assembled = try JSONDecoder().decode(MCPStreamAssembled.self, from: response.body)
        XCTAssertTrue(MCPTextFormat.streamAssembled(assembled).contains("still streaming"))
    }

    func testAnInFlightStreamWithNoTextYetSaysSo() throws {
        let provider = LiveStreamProvider(text: nil, live: MCPLiveState(phase: .waiting))
        let router = MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider())
        let response = try XCTUnwrap(get(router, "/v1/sessions/s1/events"))
        XCTAssertEqual(response.status, 404)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("still in flight"))
    }

    func testListAndDetailSayARowIsInFlightWithItsPhase() {
        var session = makeSession(uid: "w", statusCode: nil)
        session.live = MCPLiveState(phase: .waiting, requestComplete: true, elapsedSeconds: 12.7)
        XCTAssertTrue(MCPTextFormat.row(session).contains("IN_FLIGHT waiting 12s"))
        let detail = MCPTextFormat.detail(MCPSessionDetail(summary: session))
        XCTAssertTrue(detail.contains("In flight: waiting for the response head (12s so far)"))

        session.live = MCPLiveState(phase: .streaming, responseBytes: 2048, completeMessages: 7, pendingBytes: 9)
        XCTAssertTrue(MCPTextFormat.row(session).contains("IN_FLIGHT streaming 2048B 7 complete 9B pending"))
        XCTAssertTrue(MCPTextFormat.detail(MCPSessionDetail(summary: session)).contains("7 complete messages (9 bytes of an unfinished one withheld)"))

        session.live = MCPLiveState(phase: .ended, endReason: .captureStopped)
        XCTAssertTrue(MCPTextFormat.row(session).contains("ENDED_WITHOUT_FINAL_ROW capture_stopped"))
    }

    func testAFinishedRowCarriesNoLiveMarker() throws {
        let session = makeSession(uid: "f")
        XCTAssertFalse(MCPTextFormat.row(session).contains("IN_FLIGHT"))
        let data = try JSONEncoder().encode(session)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"live\""))
    }

    func testTheLiveStateSurvivesTheWireAndAnUnknownPhaseReadsAsStreaming() throws {
        var session = makeSession(uid: "w")
        session.live = MCPLiveState(phase: .streaming, responseBytes: 5, completeMessages: 2)
        let decoded = try JSONDecoder().decode(MCPSessionSummary.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.live, session.live)
        let later = #"{"phase":"teleporting","requestBytes":0,"responseBytes":0,"requestComplete":false}"#
        XCTAssertEqual(try JSONDecoder().decode(MCPLiveState.self, from: Data(later.utf8)).phase, .streaming)
    }

    func testWaitOutcomeSaysARequestIsNotOverYet() {
        var session = makeSession(uid: "s")
        session.live = MCPLiveState(phase: .streaming, responseBytes: 10)
        let text = MCPTextFormat.waitOutcome(MCPSessionWaiter.Outcome(session: session, timedOut: false, polls: 2), timeout: 30, until: .headers)
        XCTAssertTrue(text.contains("In flight: streaming"))
        let none = MCPTextFormat.waitOutcome(MCPSessionWaiter.Outcome(session: nil, timedOut: true, polls: 2), timeout: 30, until: .firstMessage)
        XCTAssertTrue(none.contains("got its first complete message"))
    }
}

// MARK: - HAR export skips in-flight rows

final class LiveExportTests: XCTestCase {
    private let token = "test-token"

    private func router(_ details: [MCPSessionDetail], exporter: StubExporter, consent: StubConsent, audit: StubAudit) -> MCPBridgeRouter {
        let sessions = StubSessionProvider(
            summaries: details.map(\.summary),
            details: Dictionary(uniqueKeysWithValues: details.map { ($0.summary.uid, $0) })
        )
        return MCPBridgeRouter(
            token: token, sessions: sessions, status: StubStatusProvider(),
            writes: MCPWriteSeams(rules: StubRuleProvider(), hosts: StubHostProvider(), capture: StubCaptureController(),
                                  consent: consent, audit: audit, exporter: exporter)
        )
    }

    private func export(_ router: MCPBridgeRouter, uids: [String]) throws -> ParsedResponse {
        var request = makeRequest(method: "POST", target: "/v1/sessions/export", token: token)
        request.body = try JSONSerialization.data(withJSONObject: ["uids": uids, "filename": "flow.har"])
        request.headers["content-type"] = "application/json"
        return try XCTUnwrap(parseRawResponse(router.respond(to: request)))
    }

    private func detail(_ uid: String, live: MCPLiveState? = nil) -> MCPSessionDetail {
        var summary = makeSession(uid: uid)
        summary.live = live
        return MCPSessionDetail(summary: summary, responseBodyPreview: live == nil ? #"{"ok":true}"# : nil)
    }

    func testInFlightRowsAreLeftOutAndCounted() throws {
        let exporter = StubExporter()
        let r = router([detail("done"), detail("live", live: MCPLiveState(phase: .streaming))],
                       exporter: exporter, consent: StubConsent(), audit: StubAudit())
        let response = try export(r, uids: ["done", "live"])
        XCTAssertEqual(response.status, 201)
        let result = try JSONDecoder().decode(MCPExportResult.self, from: response.body)
        XCTAssertEqual(result.includedCount, 1)
        XCTAssertEqual(result.requestedCount, 2)
        XCTAssertEqual(result.skippedInFlight, 1)
        XCTAssertTrue(MCPTextFormat.export(result).contains("Skipped 1 session that is still in flight"))
        let har = String(decoding: try XCTUnwrap(exporter.written.first).data, as: UTF8.self)
        XCTAssertFalse(har.contains("/resource/live"))
    }

    func testOnlyInFlightRowsIsRefusedWithoutAskingAnyone() throws {
        let consent = StubConsent()
        let r = router([detail("live", live: MCPLiveState(phase: .waiting))], exporter: StubExporter(), consent: consent, audit: StubAudit())
        let response = try export(r, uids: ["live"])
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(consent.asked.isEmpty)
    }

    func testAnEndedRowIsExportedLikeAnyFinishedOne() throws {
        let exporter = StubExporter()
        let r = router([detail("e", live: MCPLiveState(phase: .ended, endReason: .stale))],
                       exporter: exporter, consent: StubConsent(), audit: StubAudit())
        XCTAssertEqual(try export(r, uids: ["e"]).status, 201)
    }
}

// MARK: - A live row's bodies never leave (review finding, S6)

final class LiveEgressTests: XCTestCase {
    private let token = "test-token"
    /// A login body cut mid-document: what a live snapshot holds while the
    /// upload is under way, or past the 64 KB it shows. It does not parse as
    /// JSON, so structural redaction cannot see the password field.
    private let partialLogin = #"{"username":"bob","password":"hunter2","blob":"aaaaaaaa"#

    private func liveDetail(_ uid: String, live: MCPLiveState) -> MCPSessionDetail {
        var summary = makeSession(uid: uid, method: "POST", statusCode: nil)
        summary.live = live
        return MCPSessionDetail(
            summary: summary,
            requestHeaders: ["Content-Type": "application/json"],
            requestBodyPreview: partialLogin,
            responseBodyPreview: #"{"token":"abc"#,
            curl: "curl -d '\(partialLogin)' https://api.example.com/login"
        )
    }

    private func router(_ detail: MCPSessionDetail, exporter: StubExporter = StubExporter()) -> MCPBridgeRouter {
        let uid = detail.summary.uid
        let sessions = StubSessionProvider(
            summaries: [detail.summary],
            details: [uid: detail],
            bodies: ["\(uid):request": partialLogin, "\(uid):response": #"{"token":"abc"#]
        )
        return MCPBridgeRouter(
            token: token, sessions: sessions, status: StubStatusProvider(),
            writes: MCPWriteSeams(rules: StubRuleProvider(), hosts: StubHostProvider(), capture: StubCaptureController(),
                                  consent: StubConsent(), audit: StubAudit(), exporter: exporter)
        )
    }

    /// The premise changed in the release review (2026-09-29): a JSON body
    /// that does not parse is now redacted by NAME leniently
    /// (`redactPartialJSONByName`), so this prefix no longer leaks. A live
    /// row's bodies are still withheld — a prefix can be cut inside a value
    /// whose name has not arrived yet, which no name pass can see.
    func testThePartialBodyIsRedactedByNameButStillWithheld() {
        let redacted = MCPRedactor().redactBody(partialLogin, contentType: "application/json")
        XCTAssertFalse(redacted.contains("hunter2"), redacted)
    }

    func testGetSessionOnAnInFlightRowSendsNoBodyAndNoCurl() throws {
        for live in [MCPLiveState(phase: .waiting), MCPLiveState(phase: .streaming, responseBytes: 12)] {
            let r = router(liveDetail("live", live: live))
            let response = try XCTUnwrap(parseRawResponse(r.respond(to: makeRequest(target: "/v1/sessions/live", token: token))))
            XCTAssertEqual(response.status, 200)
            let text = String(decoding: response.body, as: UTF8.self)
            XCTAssertFalse(text.contains("hunter2"), "\(live.phase)")
            XCTAssertFalse(text.contains("token"), "\(live.phase)")
            let detail = try MCPBridgeClient.decode(MCPSessionDetail.self, data: response.body, status: 200)
            XCTAssertNil(detail.requestBodyPreview)
            XCTAssertNil(detail.responseBodyPreview)
            XCTAssertNil(detail.curl)
        }
    }

    func testARowEndedWithoutItsFinalSendsNoBodyEither() throws {
        let r = router(liveDetail("e", live: MCPLiveState(phase: .ended, endReason: .captureStopped)))
        let response = try XCTUnwrap(parseRawResponse(r.respond(to: makeRequest(target: "/v1/sessions/e", token: token))))
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("hunter2"))
    }

    func testTheBodyQueryRefusesALiveRow() throws {
        let r = router(liveDetail("live", live: MCPLiveState(phase: .waiting)))
        for side in ["request", "response"] {
            let request = makeRequest(target: "/v1/sessions/live/body?side=\(side)&mode=path&path=password", token: token)
            let response = try XCTUnwrap(parseRawResponse(r.respond(to: request)))
            XCTAssertEqual(response.status, 409, side)
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("hunter2"), side)
        }
    }

    func testAFinishedRowKeepsItsBodies() throws {
        var finished = liveDetail("done", live: MCPLiveState(phase: .waiting))
        finished.summary.live = nil
        finished.requestBodyPreview = #"{"q":1}"#
        XCTAssertEqual(finished.withholdingLiveBodies().requestBodyPreview, #"{"q":1}"#)
    }

    func testAnEndedRowIsExportedWithoutItsPartialBody() throws {
        let exporter = StubExporter()
        let r = router(liveDetail("e", live: MCPLiveState(phase: .ended, endReason: .stale)), exporter: exporter)
        var request = makeRequest(method: "POST", target: "/v1/sessions/export", token: token)
        request.body = try JSONSerialization.data(withJSONObject: ["uids": ["e"], "filename": "flow.har"])
        request.headers["content-type"] = "application/json"
        XCTAssertEqual(try XCTUnwrap(parseRawResponse(r.respond(to: request))).status, 201)
        let har = String(decoding: try XCTUnwrap(exporter.written.first).data, as: UTF8.self)
        XCTAssertFalse(har.contains("hunter2"))
    }

    func testTheInFlightLineSaysNeitherBodyIsShown() {
        XCTAssertTrue(LiveRowCopy.agentDetailLine(MCPLiveState(phase: .waiting)).contains("Neither body is shown"))
    }
}

// MARK: - A long request finalized out of the newest page (review finding, S6)

/// A store the waiters read the way the bridge serves it: `page` is the
/// newest `pageSize` rows only, `watch` every in-flight row plus the named
/// ones (`/v1/sessions/watched`).
private final class ScrollingStore {
    var rows: [MCPSessionSummary]   // newest first
    let pageSize: Int
    var watchCalls = 0

    init(rows: [MCPSessionSummary], pageSize: Int = MCPLimits.maxPageSize) {
        self.rows = rows
        self.pageSize = pageSize
    }

    func page() -> [MCPSessionSummary] { Array(rows.prefix(pageSize)) }
    func watch(_ uids: Set<String>) -> [MCPSessionSummary] {
        watchCalls += 1
        return rows.filter { $0.isInFlight || uids.contains($0.uid) }
    }

    func push(_ count: Int, prefix: String) {
        rows.insert(contentsOf: (0..<count).map { makeSession(uid: "\(prefix)\($0)") }.reversed(), at: 0)
    }

    /// The final replaces the live row IN PLACE, as `LiveRowTable` does.
    func finish(_ uid: String) {
        guard let index = rows.firstIndex(where: { $0.uid == uid }) else { return }
        rows[index].live = nil
        rows[index].statusCode = 200
    }
}

final class LiveWatchTests: XCTestCase {
    private func live(_ uid: String) -> MCPSessionSummary {
        var row = makeSession(uid: uid, statusCode: nil)
        row.live = MCPLiveState(phase: .streaming, responseBytes: 10)
        return row
    }

    /// Poll 1: the stream is near the top. Poll 2: 150 newer rows push it past
    /// the 100-row page. Poll 3: it finishes where no page looks.
    private func scrollingScript(_ store: ScrollingStore) -> (TimeInterval) -> Void {
        var polls = 0
        return { _ in
            polls += 1
            if polls == 1 { store.push(150, prefix: "n") }
            if polls == 2 { store.finish("stream") }
        }
    }

    func testTheWaiterSeesALongRequestFinishPastTheNewestPage() async throws {
        let store = ScrollingStore(rows: [live("stream")] + (0..<5).map { makeSession(uid: "old\($0)") })
        let step = scrollingScript(store)
        var clock: TimeInterval = 0
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(urlContains: "/resource/stream"), until: .complete, timeout: 10, pollInterval: 1,
            fetch: { store.page() }, watch: { store.watch($0) },
            elapsed: { clock }, sleep: { step($0); clock += $0 })
        XCTAssertEqual(outcome.session?.uid, "stream")
        XCTAssertEqual(outcome.session?.isInFlight, false)
    }

    func testWithoutTheWatchTheSameWaitTimesOut() async throws {
        // The failure the watch exists for, pinned so the scenario is real.
        let store = ScrollingStore(rows: [live("stream")] + (0..<5).map { makeSession(uid: "old\($0)") })
        let step = scrollingScript(store)
        var clock: TimeInterval = 0
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(urlContains: "/resource/stream"), until: .complete, timeout: 5, pollInterval: 1,
            fetch: { store.page() },
            elapsed: { clock }, sleep: { step($0); clock += $0 })
        XCTAssertTrue(outcome.timedOut)
    }

    func testARowAlreadyPastThePageAtTheCallIsWatchedToo() async throws {
        // In flight at position 150 when the wait begins.
        let store = ScrollingStore(rows: (0..<150).map { makeSession(uid: "n\($0)") } + [live("stream")])
        var polls = 0
        var clock: TimeInterval = 0
        let outcome = try await MCPSessionWaiter.wait(
            filter: MCPSessionFilter(), until: .complete, timeout: 10, pollInterval: 1,
            fetch: { store.page() }, watch: { store.watch($0) },
            elapsed: { clock },
            sleep: { polls += 1; if polls == 2 { store.finish("stream") }; clock += $0 })
        XCTAssertEqual(outcome.session?.uid, "stream")
    }

    func testTheCollectorSeesALongRequestFinishPastTheNewestPage() async throws {
        let store = ScrollingStore(rows: [live("stream")])
        let step = scrollingScript(store)
        var clock: TimeInterval = 0
        let outcome = try await MCPSessionCollector.collect(
            filter: MCPSessionFilter(urlContains: "/resource/stream"), maxCount: 1, timeout: 10, settleInterval: 5, pollInterval: 1,
            fetch: { store.page() }, watch: { store.watch($0) },
            elapsed: { clock }, sleep: { step($0); clock += $0 })
        XCTAssertEqual(outcome.sessions.map(\.uid), ["stream"])
        XCTAssertEqual(outcome.stopReason, .reachedCount)
    }

    func testMergePrefersTheWatchedCopyAndAppendsWhatThePageLacks() {
        var finished = makeSession(uid: "a")
        finished.live = nil
        var liveA = live("a")
        liveA.statusCode = nil
        let merged = MCPWatchedRows.merge(page: [liveA, makeSession(uid: "b")], watched: [finished, live("z")])
        XCTAssertEqual(merged.map(\.uid), ["a", "b", "z"])
        XCTAssertEqual(merged.first?.isInFlight, false)
    }

    func testFollowLetsGoOfFinishedSettledAndVanishedRows() {
        var watched = MCPWatchedRows()
        watched.follow([live("a"), live("b"), live("c"), makeSession(uid: "d")], settled: ["c"])
        XCTAssertEqual(watched.uids, ["a", "b"])
        watched.follow([makeSession(uid: "a")], settled: [])   // a finished, b vanished
        XCTAssertEqual(watched.uids, [])
    }

    func testFollowIsBounded() {
        var watched = MCPWatchedRows()
        watched.follow((0..<(MCPWatchedRows.capacity + 20)).map { live("r\($0)") }, settled: [])
        XCTAssertEqual(watched.uids.count, MCPWatchedRows.capacity)
        XCTAssertFalse(watched.uids.contains("r0"), "the oldest followed is let go first")
    }

    func testTheWatchedRouteReturnsInFlightAndNamedRowsWherever() throws {
        let rows = [makeSession(uid: "new")] + (0..<150).map { makeSession(uid: "n\($0)") } + [live("deep"), makeSession(uid: "named")]
        let r = MCPBridgeRouter(token: "t", sessions: StubSessionProvider(summaries: rows.reversed()), status: StubStatusProvider())
        let response = try XCTUnwrap(parseRawResponse(r.respond(to: makeRequest(target: "/v1/sessions/watched?uids=named,unknown", token: "t"))))
        XCTAssertEqual(response.status, 200)
        let page = try MCPBridgeClient.decode(MCPSessionPage.self, data: response.body, status: 200)
        XCTAssertEqual(Set(page.sessions.map(\.uid)), ["deep", "named"])
    }
}

// MARK: - The flush report and the text digest (review findings, S6)

final class LiveFlushReportTests: XCTestCase {
    private struct Row: LiveTableRow, Equatable {
        var id = UUID()
        var exchangeID: UUID?
    }

    private func state(_ row: Row, phase: LivePhase = .waiting) -> LiveRowState {
        LiveRowState(exchangeID: row.exchangeID!, rowID: row.id, phase: phase)
    }

    func testARowAnnouncedAndEndedInOneFlushKeepsItsEndedState() {
        let row = Row(exchangeID: UUID())
        var rows: [Row] = []
        var inFlight = Set<UUID>()
        let started = state(row)
        let report = LiveRowTable.apply(
            [.insertLive(row, started, []), .end(rowID: row.id, exchangeID: row.exchangeID!, reason: .captureStopped)],
            to: &rows, inFlight: &inFlight, cap: 10)
        XCTAssertEqual(rows.map(\.id), [row.id])
        XCTAssertTrue(inFlight.isEmpty)
        XCTAssertEqual(report.ended.map(\.rowID), [row.id])
        XCTAssertEqual(report.endedStates[row.id], started, "the caller has no model for it: the batch's state is the only record")
    }

    func testTheEndedStateIsTheLastOneTheBatchCarried() {
        let row = Row(exchangeID: UUID())
        var rows: [Row] = []
        var inFlight = Set<UUID>()
        let streaming = state(row, phase: .streaming)
        let report = LiveRowTable.apply(
            [.insertLive(row, state(row), []), .updateLive(row: nil, state: streaming, appended: []),
             .end(rowID: row.id, exchangeID: row.exchangeID!, reason: .stale)],
            to: &rows, inFlight: &inFlight, cap: 10)
        XCTAssertEqual(report.endedStates[row.id]?.phase, .streaming)
    }

    func testProgressWithoutASnapshotChangesNoRows() {
        let row = Row(exchangeID: UUID())
        var rows = [row]
        var inFlight: Set<UUID> = [row.id]
        let progress = LiveRowTable.apply([.updateLive(row: nil, state: state(row, phase: .streaming), appended: [])],
                                          to: &rows, inFlight: &inFlight, cap: 10)
        XCTAssertFalse(progress.changesRows, "a progress-only flush must not republish the table")
        let snapshot = LiveRowTable.apply([.updateLive(row: row, state: state(row, phase: .streaming), appended: [])],
                                          to: &rows, inFlight: &inFlight, cap: 10)
        XCTAssertTrue(snapshot.changesRows)
        let ended = LiveRowTable.apply([.end(rowID: row.id, exchangeID: row.exchangeID!, reason: .stale)],
                                       to: &rows, inFlight: &inFlight, cap: 10)
        XCTAssertTrue(ended.changesRows)
    }

    func testTheDigestIgnoresPieceBoundariesAndSeesEqualLengthDifferences() {
        var pieces = LiveTextDigest()
        ["data: {\"a\":", "1}\n\nda", "ta: é\n\n"].forEach { pieces.append($0) }
        XCTAssertEqual(pieces, LiveTextDigest("data: {\"a\":1}\n\ndata: é\n\n"))
        let other = LiveTextDigest("data: {\"a\":2}\n\ndata: é\n\n")
        XCTAssertEqual(pieces.byteCount, other.byteCount)
        XCTAssertNotEqual(pieces, other)
    }
}
