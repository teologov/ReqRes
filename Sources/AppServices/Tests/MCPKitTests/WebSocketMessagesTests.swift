//
//  WebSocketMessagesTests.swift
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
//  WebSocket messages in the app (protocol-engine doc §S7): the wire mirror,
//  D10's ring, the app-wide bound, the words the Messages tab shows, the two
//  agent tools and HAR `_webSocketMessages`.
//

import XCTest
@testable import MCPKit

// MARK: - Fixtures

enum SocketFixtures {
    static let upgradeAt: Double = 1_790_000_000

    static func text(_ seq: Int64, _ text: String, sent: Bool = false, truncated: Bool = false, at offset: Double? = nil) -> SocketMessage {
        SocketMessage(seq: seq, direction: sent ? .clientToServer : .serverToClient, opcode: .text,
                      time: upgradeAt + (offset ?? Double(seq) * 0.01), size: Int64(text.utf8.count) + (truncated ? 10_000 : 0),
                      preview: text, previewEncoding: .text, truncated: truncated)
    }

    static func binary(_ seq: Int64, _ bytes: [UInt8], sent: Bool = false) -> SocketMessage {
        SocketMessage(seq: seq, direction: sent ? .clientToServer : .serverToClient, opcode: .binary,
                      time: upgradeAt + Double(seq) * 0.01, size: Int64(bytes.count),
                      preview: Data(bytes).base64EncodedString(), previewEncoding: .base64)
    }

    static func close(_ seq: Int64, code: Int, reason: String, sent: Bool = true) -> SocketMessage {
        SocketMessage(seq: seq, direction: sent ? .clientToServer : .serverToClient, opcode: .close,
                      time: upgradeAt + Double(seq) * 0.01, size: Int64(2 + reason.utf8.count),
                      preview: reason, previewEncoding: .text, closeCode: code, closeReason: reason)
    }

    static func batch(_ id: UUID, _ number: Int, _ messages: [SocketMessage], evicted: Int64 = 0, final: Bool = false,
                      close: SocketClose? = nil, gaveUp: [SocketTapIssue] = [], extensions: String? = nil) -> SocketMessageBatch {
        SocketMessageBatch(exchangeID: id, batch: number, messages: messages, evictedMessages: evicted, gaveUp: gaveUp,
                           extensions: extensions, final: final, close: close, sentAt: upgradeAt)
    }
}

/// A provider with WebSocket conversations: the rows, and a real store.
final class StubSocketProvider: MCPSessionProviding {
    struct Row {
        var summary: MCPSessionSummary
        var exchangeID: UUID
        var isWebSocket: Bool
        var upgradeAt: Double?
    }

    var rows: [Row] = []
    var store = SocketMessageStore()

    func sessionSummaries() -> [MCPSessionSummary] { rows.map(\.summary) }
    func sessionDetail(uid: String) -> MCPSessionDetail? {
        rows.first { $0.summary.uid == uid }.map { MCPSessionDetail(summary: $0.summary) }
    }
    func sessionBody(uid: String, side: MCPBodySide) -> String? { nil }

    func socketConversation(uid: String) -> MCPSocketConversation? {
        guard let row = rows.first(where: { $0.summary.uid == uid }) else { return nil }
        return MCPSocketConversation(uid: uid, host: row.summary.host, url: row.summary.url, upgradeAt: row.upgradeAt,
                                     isWebSocket: row.isWebSocket, log: store.log(for: row.exchangeID))
    }

    func socketFeed(afterOrdinal ordinal: Int64?, scanLimit: Int) -> MCPSocketFeedRaw {
        guard let ordinal else { return MCPSocketFeedRaw(latestOrdinal: store.latestOrdinal, items: []) }
        return MCPSocketFeedRaw.joining(
            latestOrdinal: store.latestOrdinal, after: ordinal,
            found: store.messages(afterOrdinal: ordinal, limit: scanLimit), scanLimit: scanLimit,
            now: SocketFixtures.upgradeAt + 60
        ) { exchange, stored in
            guard let row = rows.first(where: { $0.exchangeID == exchange }) else { return nil }
            return MCPSocketFeedItem(uid: row.summary.uid, host: row.summary.host, upgradeAt: row.upgradeAt, stored: stored)
        }
    }

    @discardableResult
    func addSocket(uid: String, host: String = "chat.example.com", url: String? = nil, isWebSocket: Bool = true) -> UUID {
        let id = UUID()
        var summary = makeSession(uid: uid, host: host, url: url ?? "https://\(host)/socket?room=1", statusCode: isWebSocket ? 101 : 200)
        summary.startedAt = Date(timeIntervalSince1970: SocketFixtures.upgradeAt - 0.1)
        rows.append(Row(summary: summary, exchangeID: id, isWebSocket: isWebSocket, upgradeAt: SocketFixtures.upgradeAt))
        return id
    }
}

// MARK: - The wire

final class SocketWireTests: XCTestCase {
    /// C11.3's exact keys, as the core's `WebSocketMessageBatch` encodes them.
    func testTheCoreBatchDecodesWithEveryField() throws {
        let json = """
        {"exchangeID":"8C4F3D0A-1B2C-4D5E-8F90-A1B2C3D4E5F6","batch":2,"evictedMessages":3,
         "messages":[{"seq":7,"direction":"clientToServer","opcode":"text","time":1790000000.5,"size":5,"wireSize":7,
                      "compressed":true,"frames":2,"preview":"hello","previewEncoding":"text","truncated":false},
                     {"seq":8,"direction":"serverToClient","opcode":"close","time":1790000001,"size":9,"wireSize":9,
                      "compressed":false,"frames":1,"preview":"bye now","previewEncoding":"text","truncated":false,
                      "closeCode":1000,"closeReason":"bye now"}],
         "gaveUp":[{"direction":"serverToClient","reason":"RSV2 set","atByte":12}],
         "extensions":"permessage-deflate","final":true,
         "close":{"end":"closeHandshake","code":1000,"reason":"bye now","initiatedBy":"clientToServer",
                  "totalMessages":9,"bytesFromClient":40,"bytesFromServer":60},
         "sentAt":1790000001.2}
        """
        let batch = try JSONDecoder().decode(SocketMessageBatch.self, from: Data(json.utf8))
        XCTAssertEqual(batch.exchangeID.uuidString, "8C4F3D0A-1B2C-4D5E-8F90-A1B2C3D4E5F6")
        XCTAssertEqual(batch.batch, 2)
        XCTAssertEqual(batch.evictedMessages, 3)
        XCTAssertEqual(batch.messages.count, 2)
        XCTAssertEqual(batch.messages[0].direction, .clientToServer)
        XCTAssertEqual(batch.messages[0].wireSize, 7)
        XCTAssertTrue(batch.messages[0].compressed)
        XCTAssertEqual(batch.messages[0].frames, 2)
        XCTAssertEqual(batch.messages[1].opcode, .close)
        XCTAssertEqual(batch.messages[1].closeCode, 1000)
        XCTAssertEqual(batch.gaveUp, [SocketTapIssue(direction: .serverToClient, reason: "RSV2 set", atByte: 12)])
        XCTAssertEqual(batch.extensions, "permessage-deflate")
        XCTAssertTrue(batch.final)
        XCTAssertEqual(batch.close?.end, .closeHandshake)
        XCTAssertEqual(batch.close?.initiatedBy, .clientToServer)
        XCTAssertEqual(batch.close?.totalMessages, 9)
    }

    /// The core's leniency, mirrored: unknown values fall back, missing
    /// fields default; only `exchangeID` is required.
    func testUnknownValuesFallBackAndMissingFieldsDefault() throws {
        let json = """
        {"exchangeID":"8C4F3D0A-1B2C-4D5E-8F90-A1B2C3D4E5F6",
         "messages":[{"direction":"sideways","opcode":"x-future","previewEncoding":"rot13"},{}],
         "close":{"end":"exploded"}}
        """
        let batch = try JSONDecoder().decode(SocketMessageBatch.self, from: Data(json.utf8))
        XCTAssertEqual(batch.batch, 0)
        XCTAssertFalse(batch.final)
        XCTAssertEqual(batch.messages[0].direction, .serverToClient)
        XCTAssertEqual(batch.messages[0].opcode, .binary)
        XCTAssertEqual(batch.messages[0].previewEncoding, .base64)
        XCTAssertEqual(batch.messages[1].frames, 1)
        XCTAssertEqual(batch.messages[1].preview, "")
        XCTAssertEqual(batch.close?.end, .connectionDropped)
        XCTAssertThrowsError(try JSONDecoder().decode(SocketMessageBatch.self, from: Data(#"{"batch":1}"#.utf8)))
    }

    func testPreviewTextReadsTextAndUTF8Base64ButNotBinary() {
        XCTAssertEqual(SocketFixtures.text(0, "hi").previewText, "hi")
        let jsonAsBinary = SocketMessage(seq: 0, direction: .serverToClient, opcode: .binary, time: 0, size: 7,
                                         preview: Data(#"{"a":1}"#.utf8).base64EncodedString(), previewEncoding: .base64)
        XCTAssertEqual(jsonAsBinary.previewText, #"{"a":1}"#)
        XCTAssertNil(SocketFixtures.binary(0, [0x00, 0xff, 0x10]).previewText)
        XCTAssertNil(SocketMessage(seq: 0, direction: .serverToClient, opcode: .binary, time: 0, size: 1, preview: "!!notbase64",
                                   previewEncoding: .base64).previewData)
    }
}

// MARK: - D10's ring

final class SocketMessageLogTests: XCTestCase {
    private func feed(_ log: inout SocketMessageLog, count: Int, from start: Int64 = 0, batchSize: Int = 400, text: (Int64) -> String = { "m\($0)" }) {
        var ordinal: Int64 = 0
        var seq = start
        var number = log.lastBatch
        while seq < start + Int64(count) {
            let end = min(seq + Int64(batchSize), start + Int64(count))
            number += 1
            log.apply(SocketFixtures.batch(log.exchangeID, number, (seq..<end).map { SocketFixtures.text($0, text($0)) }),
                      nextOrdinal: { ordinal += 1; return ordinal })
            seq = end
        }
    }

    /// THE ring: the first 200 and the last 2,000, and the 300 between them
    /// counted — as a gap line in the list, and in the numbers.
    func testTheRingKeepsTheFirst200AndTheLast2000AndCountsTheGap() {
        var log = SocketMessageLog(exchangeID: UUID())
        feed(&log, count: 2_500)
        XCTAssertEqual(log.received, 2_500)
        XCTAssertEqual(log.retainedCount, 2_200)
        XCTAssertEqual(log.droppedByApp, 300)
        let seqs = log.messages.map(\.message.seq)
        XCTAssertEqual(Array(seqs.prefix(200)), Array(0..<200))
        XCTAssertEqual(Array(seqs.suffix(2_000)), Array(500..<2_500))
        let items = SocketMessagePresentation.items(log.messages)
        let gaps = items.compactMap { item -> Int64? in if case .gap(let n, _) = item { return n } else { return nil } }
        XCTAssertEqual(gaps, [300], "one gap line, right after the head")
        XCTAssertEqual(items.count, 2_201)
        XCTAssertEqual(SocketMessagePresentation.gapLine(300), "300 messages not kept")
        XCTAssertEqual(SocketMessagePresentation.gapLine(1), "1 message not kept")
        XCTAssertEqual(SocketMessagePresentation.retentionLine(log),
                       "Not kept: 300 let go by ReqRes, which keeps the first 200 and the last 2,000 messages of a connection.")
    }

    /// Under 2,200 nothing is let go.
    func testNothingIsDroppedBelowTheRingsSize() {
        var log = SocketMessageLog(exchangeID: UUID())
        feed(&log, count: 2_200)
        XCTAssertEqual(log.retainedCount, 2_200)
        XCTAssertEqual(log.droppedByApp, 0)
        XCTAssertFalse(SocketMessagePresentation.items(log.messages).contains { if case .gap = $0 { return true } else { return false } })
    }

    /// Count alone would let 2,200 × 64 KB previews hold 140 MB: the byte
    /// budgets bound a connection at 8 MB, and the head stays the FIRST
    /// messages, contiguous.
    func testTheByteBudgetsBoundAConnectionAt8MB() {
        var log = SocketMessageLog(exchangeID: UUID())
        let big = String(repeating: "x", count: 60_000)
        feed(&log, count: 400, batchSize: 50, text: { _ in big })
        XCTAssertLessThanOrEqual(log.retainedBytes, SocketMessageLog.byteBudget)
        XCTAssertLessThanOrEqual(log.headBytes, SocketMessageLog.headByteBudget)
        XCTAssertLessThanOrEqual(log.tailBytes, SocketMessageLog.tailByteBudget)
        let seqs = log.messages.map(\.message.seq)
        XCTAssertEqual(seqs.first, 0)
        XCTAssertEqual(seqs.last, 399, "the newest message is always kept")
        XCTAssertEqual(Int64(log.retainedCount) + log.droppedByApp, 400)
        let headCount = log.head.count
        XCTAssertEqual(Array(seqs.prefix(headCount)), (0..<Int64(headCount)).map { $0 }, "the head is the first N, contiguous")
    }

    /// Everything that did not reach the app, whoever let it go: the
    /// extension's evictions (a seq gap), a lost batch, the close's count.
    func testExtensionEvictionsLostBatchesAndTheCloseAreCounted() {
        let id = UUID()
        var log = SocketMessageLog(exchangeID: id)
        var ordinal: Int64 = 0
        let next: () -> Int64 = { ordinal += 1; return ordinal }
        log.apply(SocketFixtures.batch(id, 1, (0..<10).map { SocketFixtures.text($0, "a\($0)") }), nextOrdinal: next)
        // Batch 2 never arrives; batch 3 says 5 were evicted in the extension.
        log.apply(SocketFixtures.batch(id, 3, (20..<25).map { SocketFixtures.text($0, "b\($0)") }, evicted: 5), nextOrdinal: next)
        // A repeat of batch 3, and a stale batch 2, change nothing.
        XCTAssertEqual(log.apply(SocketFixtures.batch(id, 3, [SocketFixtures.text(30, "dup")]), nextOrdinal: next), 0)
        XCTAssertEqual(log.apply(SocketFixtures.batch(id, 2, [SocketFixtures.text(15, "late")]), nextOrdinal: next), 0)
        let close = SocketClose(end: .closeHandshake, code: 1000, reason: "bye", initiatedBy: .clientToServer, totalMessages: 28)
        log.apply(SocketFixtures.batch(id, 4, [SocketFixtures.close(25, code: 1000, reason: "bye")], final: true, close: close), nextOrdinal: next)
        // Anything after the final batch is ignored.
        XCTAssertEqual(log.apply(SocketFixtures.batch(id, 5, [SocketFixtures.text(26, "ghost")]), nextOrdinal: next), 0)

        XCTAssertEqual(log.lostBatches, 1)
        XCTAssertEqual(log.droppedByExtension, 5)
        XCTAssertTrue(log.isFinal)
        XCTAssertEqual(log.close, close)
        XCTAssertEqual(log.messages.map(\.message.seq), Array(0..<10) + Array(20..<26))
        let items = SocketMessagePresentation.items(log.messages, close: log.close)
        let gaps = items.compactMap { item -> Int64? in if case .gap(let n, _) = item { return n } else { return nil } }
        XCTAssertEqual(gaps, [10, 2], "seq 10–19 between the batches; 26–27 the close counted but never came")
        XCTAssertEqual(SocketMessagePresentation.retentionLine(log),
                       "Not kept: 5 dropped before reaching the app (it fell behind); 1 batch of messages lost on the way to the app.")
    }

    func testOrdinalsGrowAndAreQueriedFromTheNewestEnd() {
        var log = SocketMessageLog(exchangeID: UUID())
        feed(&log, count: 2_500)
        let all = log.messages
        XCTAssertEqual(all.map(\.ordinal), all.map(\.ordinal).sorted())
        let cut = all[2_150].ordinal
        XCTAssertEqual(log.messages(afterOrdinal: cut).map(\.ordinal), all.suffix(49).map(\.ordinal))
        XCTAssertEqual(log.messages(afterOrdinal: 0).count, 2_200)
        XCTAssertEqual(log.messages(afterSeq: 2_495).map(\.message.seq), [2_496, 2_497, 2_498, 2_499])
    }
}

// MARK: - The app-wide bound

final class SocketMessageStoreTests: XCTestCase {
    func testTheAppWideByteBoundTrimsTheLargestConversationFirst() {
        var store = SocketMessageStore(maxBytes: 200_000, maxMessages: 100_000, maxConnections: 100)
        let big = UUID(), small = UUID()
        let payload = String(repeating: "y", count: 1_000)
        store.ingest(SocketFixtures.batch(small, 1, (0..<20).map { SocketFixtures.text($0, payload) }))
        store.ingest(SocketFixtures.batch(big, 1, (0..<400).map { SocketFixtures.text($0, payload) }))
        XCTAssertLessThanOrEqual(store.retainedBytes, 200_000)
        XCTAssertEqual(store.log(for: small)?.retainedCount, 20, "the small conversation is untouched")
        let bigLog = try! XCTUnwrap(store.log(for: big))
        XCTAssertGreaterThan(bigLog.droppedByApp, 0)
        XCTAssertEqual(bigLog.messages.last?.message.seq, 399)
        XCTAssertEqual(store.retainedMessages, store.logs.values.map(\.retainedCount).reduce(0, +))
        XCTAssertEqual(store.retainedBytes, store.logs.values.map(\.retainedBytes).reduce(0, +))
    }

    func testTheMessageAndConnectionBoundsHold() {
        var store = SocketMessageStore(maxBytes: .max, maxMessages: 500, maxConnections: 3)
        var ids: [UUID] = []
        for _ in 0..<5 {
            let id = UUID()
            ids.append(id)
            store.ingest(SocketFixtures.batch(id, 1, (0..<300).map { SocketFixtures.text($0, "z") }))
        }
        XCTAssertEqual(store.connectionCount, 3)
        XCTAssertNil(store.log(for: ids[0]), "the oldest conversation goes first")
        XCTAssertNil(store.log(for: ids[1]))
        XCTAssertLessThanOrEqual(store.retainedMessages, 500)
    }

    /// A deleted or cleared row's later batches are dropped, never re-created.
    func testForgottenConversationsStayForgotten() {
        var store = SocketMessageStore()
        let id = UUID()
        store.ingest(SocketFixtures.batch(id, 1, [SocketFixtures.text(0, "a")]))
        store.forget([id])
        XCTAssertNil(store.log(for: id))
        XCTAssertFalse(store.ingest(SocketFixtures.batch(id, 2, [SocketFixtures.text(1, "b")])))
        XCTAssertNil(store.log(for: id))
        XCTAssertEqual(store.retainedMessages, 0)
        let other = UUID()
        store.ingest(SocketFixtures.batch(other, 1, [SocketFixtures.text(0, "c")]))
        store.removeAll()
        XCTAssertFalse(store.ingest(SocketFixtures.batch(other, 2, [SocketFixtures.text(1, "d")])))
        XCTAssertEqual(store.connectionCount, 0)
        XCTAssertEqual(store.retainedBytes, 0)
    }

    /// A clear drops rows whose sockets have not spoken yet (and rows still
    /// buffered or in flight). Their first batch after the clear must not
    /// create a conversation no row will ever show — the agent feed would
    /// wait behind it and it would hold memory nothing can clear.
    func testAClearForgetsExchangesThatHaveNoLogYet() {
        var store = SocketMessageStore()
        let spoke = UUID(), quiet = UUID(), buffered = UUID(), later = UUID()
        store.ingest(SocketFixtures.batch(spoke, 1, [SocketFixtures.text(0, "a")]))
        store.removeAll(forgetting: [quiet, buffered])
        XCTAssertFalse(store.ingest(SocketFixtures.batch(quiet, 1, [SocketFixtures.text(0, "first words")])))
        XCTAssertFalse(store.ingest(SocketFixtures.batch(buffered, 1, [SocketFixtures.text(0, "b")], final: true)))
        XCTAssertFalse(store.ingest(SocketFixtures.batch(spoke, 2, [SocketFixtures.text(1, "c")])))
        XCTAssertEqual(store.connectionCount, 0)
        XCTAssertEqual(store.retainedMessages, 0)
        XCTAssertTrue(store.ingest(SocketFixtures.batch(later, 1, [SocketFixtures.text(0, "new")])),
                      "a connection opened after the clear is recorded")
        XCTAssertEqual(store.connectionCount, 1)
    }

    /// Past the app-wide bound every conversation of the same size is trimmed
    /// in turn, never one drained while the others keep everything: the
    /// largest gives up messages only until it is no longer the largest.
    func testTrimmingPassesToTheNextLargestConversation() {
        var store = SocketMessageStore(maxBytes: .max, maxMessages: 30, maxConnections: 10)
        let ids = (0..<4).map { _ in UUID() }
        for id in ids {
            store.ingest(SocketFixtures.batch(id, 1, (0..<10).map { SocketFixtures.text($0, "m\($0)") }))
        }
        XCTAssertEqual(store.retainedMessages, 30)
        let counts = ids.compactMap { store.log(for: $0)?.retainedCount }
        XCTAssertEqual(counts.count, 4)
        XCTAssertLessThanOrEqual((counts.max() ?? 0) - (counts.min() ?? 0), 1, "trimmed evenly: \(counts)")
        for id in ids {
            // Ten messages sit in the head, which gives up its NEWEST so it
            // stays "the first N" (the ring's rule): each keeps its first.
            XCTAssertEqual(store.log(for: id)?.messages.first?.message.seq, 0)
            XCTAssertGreaterThan(store.log(for: id)?.droppedByApp ?? 0, 0, "every conversation gave some up")
        }
        XCTAssertEqual(store.retainedMessages, store.logs.values.map(\.retainedCount).reduce(0, +))
        XCTAssertEqual(store.retainedBytes, store.logs.values.map(\.retainedBytes).reduce(0, +))
    }

    func testTheFeedIsInArrivalOrderAcrossConversations() {
        var store = SocketMessageStore()
        let a = UUID(), b = UUID()
        store.ingest(SocketFixtures.batch(a, 1, [SocketFixtures.text(0, "a0"), SocketFixtures.text(1, "a1")]))
        let mark = store.latestOrdinal
        store.ingest(SocketFixtures.batch(b, 1, [SocketFixtures.text(0, "b0")]))
        store.ingest(SocketFixtures.batch(a, 2, [SocketFixtures.text(2, "a2")]))
        let after = store.messages(afterOrdinal: mark, limit: 10)
        XCTAssertEqual(after.map(\.stored.message.preview), ["b0", "a2"])
        XCTAssertEqual(after.map(\.exchangeID), [b, a])
        XCTAssertEqual(store.messages(afterOrdinal: 0, limit: 2).map(\.stored.message.preview), ["a0", "a1"])
        XCTAssertTrue(store.messages(afterOrdinal: store.latestOrdinal, limit: 10).isEmpty)
    }
}

// MARK: - What the Messages tab says

final class SocketMessagePresentationTests: XCTestCase {
    func testOnlyA101NamingWebsocketIsAWebSocket() {
        XCTAssertTrue(SocketMessagePresentation.isWebSocketUpgrade(status: "101", responseHeaders: ["Upgrade": "websocket", "Connection": "Upgrade"]))
        XCTAssertTrue(SocketMessagePresentation.isWebSocketUpgrade(status: "101", responseHeaders: ["upgrade": "WebSocket"]))
        XCTAssertFalse(SocketMessagePresentation.isWebSocketUpgrade(status: "101", responseHeaders: ["Upgrade": "h2c"]))
        XCTAssertFalse(SocketMessagePresentation.isWebSocketUpgrade(status: "200", responseHeaders: ["Upgrade": "websocket"]))
        XCTAssertFalse(SocketMessagePresentation.isWebSocketUpgrade(status: nil, responseHeaders: [:]))
    }

    /// The classification behind every agent list/wait poll and every flush
    /// with a `proto:` chip runs this per row; only a 101 may parse headers
    /// (doc §S9.2 — ~94 ms per 5,000 rows on main when every row did).
    func testHeadersAreReadOnlyForA101() {
        var reads = 0
        func headers() -> [String: String] {
            reads += 1
            return ["Upgrade": "websocket"]
        }
        for status in ["200", "404", "", " 101x", nil] as [String?] {
            XCTAssertFalse(SocketMessagePresentation.isWebSocketUpgrade(status: status, responseHeaders: headers()))
        }
        XCTAssertEqual(reads, 0, "a non-101 row parsed its headers")
        XCTAssertTrue(SocketMessagePresentation.isWebSocketUpgrade(status: "101", responseHeaders: headers()))
        XCTAssertEqual(reads, 1)
    }

    func testTheLineFacts() {
        let up = SocketFixtures.upgradeAt
        XCTAssertEqual(SocketMessagePresentation.offset(up + 1.2404, from: up), "+1,240 ms")
        XCTAssertEqual(SocketMessagePresentation.offset(up, from: up), "+0 ms")
        XCTAssertNil(SocketMessagePresentation.offset(up, from: nil))
        XCTAssertEqual(SocketMessagePresentation.directionWord(.clientToServer), "Sent")
        XCTAssertEqual(SocketMessagePresentation.directionSymbol(.clientToServer), "arrow.up")
        XCTAssertEqual(SocketMessagePresentation.directionWord(.serverToClient), "Received")
        XCTAssertEqual(SocketMessagePresentation.directionSymbol(.serverToClient), "arrow.down")
        XCTAssertEqual(SocketMessagePresentation.oneLine(SocketFixtures.text(0, "{\n  \"a\": 1\n}")), "{ \"a\": 1 }")
        XCTAssertEqual(SocketMessagePresentation.oneLine(SocketFixtures.binary(0, Array(0..<20))),
                       "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f …")
        XCTAssertEqual(SocketMessagePresentation.oneLine(SocketFixtures.close(0, code: 1000, reason: "bye now")), "1000 Normal closure “bye now”")
        XCTAssertEqual(SocketMessagePresentation.accessibilityLabel(SocketFixtures.text(0, "x", sent: true, at: 0.25), upgrade: SocketFixtures.upgradeAt),
                       "Sent, text, 1 B, 250 milliseconds after the upgrade")
    }

    func testAMessageWholeIsPrettyJSONTextOrAHexDump() {
        let json = SocketMessagePresentation.body(SocketFixtures.text(0, #"{"type":"transcript.final","text":"hi"}"#))
        XCTAssertEqual(json.kind, .json)
        XCTAssertEqual(json.text, "{\n  \"text\" : \"hi\",\n  \"type\" : \"transcript.final\"\n}")
        XCTAssertEqual(SocketMessagePresentation.body(SocketFixtures.text(0, "plain words")).kind, .text)
        // A cut JSON document is shown as the text it is, never reformatted.
        XCTAssertEqual(SocketMessagePresentation.body(SocketFixtures.text(0, #"{"a":1}"#, truncated: true)).kind, .text)
        let hex = SocketMessagePresentation.body(SocketFixtures.binary(0, Array("Hello, world!\n".utf8) + [0x00, 0xff, 0x7f]))
        XCTAssertEqual(hex.kind, .hex)
        XCTAssertEqual(hex.text, "00000000  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 0a 00 ff  |Hello, world!...|\n00000010  7f" + String(repeating: " ", count: 48) + "|.|")
        XCTAssertEqual(SocketMessagePresentation.body(SocketFixtures.text(0, "")).kind, .empty)
        XCTAssertEqual(SocketMessagePresentation.truncatedNote(SocketFixtures.text(0, "abc", truncated: true)),
                       "ReqRes kept the first 3 B of this 9.8 KB message; the whole message was forwarded.")
    }

    func testTheCloseAndTheTapSayWhatHappened() {
        let close = SocketClose(end: .closeHandshake, code: 1000, reason: "bye now", initiatedBy: .clientToServer)
        XCTAssertEqual(SocketMessagePresentation.closeLine(close),
                       "Closed cleanly: both sides sent a close frame, first by the app — 1000 Normal closure “bye now”.")
        XCTAssertEqual(SocketMessagePresentation.closeLine(SocketClose(end: .connectionDropped)),
                       "The connection dropped without a close frame.")
        XCTAssertEqual(SocketMessagePresentation.closeLine(SocketClose(end: .idleTimeout)),
                       "Closed by ReqRes after 10 minutes with no data either way.")
        XCTAssertEqual(SocketMessagePresentation.gaveUpLine(SocketTapIssue(direction: .serverToClient, reason: "RSV2 set")),
                       "ReqRes stopped reading the server's messages: RSV2 set. The connection is unaffected — its bytes still flow.")
    }

    func testSearchWithinMessages() {
        XCTAssertTrue(SocketMessagePresentation.matches(SocketFixtures.text(0, #"{"type":"Transcript.Final"}"#), query: "transcript.final"))
        XCTAssertFalse(SocketMessagePresentation.matches(SocketFixtures.text(0, "hello"), query: "bye"))
        XCTAssertTrue(SocketMessagePresentation.matches(SocketFixtures.text(0, "hello"), query: "  "))
        XCTAssertTrue(SocketMessagePresentation.matches(SocketFixtures.binary(0, [0xde, 0xad, 0xbe, 0xef]), query: "de ad"))
        XCTAssertTrue(SocketMessagePresentation.matches(SocketFixtures.close(1, code: 1001, reason: "going away"), query: "going"))
        XCTAssertTrue(SocketMessagePresentation.matches(SocketFixtures.text(0, "x", sent: true), query: "sent"))
    }

    /// The tab's search, computed once per pull or keystroke by the model.
    func testTheShownItemsUnderASearch() {
        let log: [StoredSocketMessage] = [
            StoredSocketMessage(ordinal: 1, message: SocketFixtures.text(0, #"{"type":"transcript.partial"}"#)),
            StoredSocketMessage(ordinal: 2, message: SocketFixtures.text(5, #"{"type":"transcript.final"}"#)),
        ]
        let items = SocketMessagePresentation.items(log)
        XCTAssertEqual(items.map(\.id), ["m0", "g5", "m5"], "a gap line between seq 0 and 5")
        XCTAssertEqual(SocketMessagePresentation.shown(items, query: "  "), items, "a blank search shows everything")
        XCTAssertEqual(SocketMessagePresentation.shown(items, query: "FINAL").map(\.id), ["m5"], "matches only; no gap lines")
        XCTAssertTrue(SocketMessagePresentation.shown(items, query: "nope").isEmpty)
    }

    func testTheSummary() {
        let id = UUID()
        var log = SocketMessageLog(exchangeID: id)
        XCTAssertEqual(SocketMessagePresentation.summary(log), "No messages yet.")
        var ordinal: Int64 = 0
        log.apply(SocketFixtures.batch(id, 1, [SocketFixtures.text(0, "hello", sent: true), SocketFixtures.text(1, "welcome!")]),
                  nextOrdinal: { ordinal += 1; return ordinal })
        XCTAssertEqual(SocketMessagePresentation.summary(log), "2 messages · ↑ 1 sent (5 B) · ↓ 1 received (8 B) · open")
    }
}

// MARK: - The agent surface

final class SocketAgentSurfaceTests: XCTestCase {
    private let token = "t"

    private func get<T: Decodable>(_ type: T.Type, _ router: MCPBridgeRouter, _ target: String, status: Int = 200,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let response = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: target, token: token))))
        XCTAssertEqual(response.status, status, target, file: file, line: line)
        return try JSONDecoder().decode(T.self, from: response.body)
    }

    private func status(_ router: MCPBridgeRouter, _ target: String) -> Int? {
        parseRawResponse(router.respond(to: makeRequest(target: target, token: token)))?.status
    }

    private func chat() -> (StubSocketProvider, MCPBridgeRouter) {
        let provider = StubSocketProvider()
        let id = provider.addSocket(uid: "ws1")
        provider.addSocket(uid: "plain", isWebSocket: false)
        provider.store.ingest(SocketFixtures.batch(id, 1, [
            SocketFixtures.text(0, #"{"type":"session.update","voice":"alloy"}"#, sent: true),
            SocketFixtures.text(1, #"{"type":"transcript.delta","text":"hel"}"#),
            SocketFixtures.binary(2, [0x01, 0x02, 0x03]),
            SocketFixtures.text(3, #"{"type":"transcript.final","text":"hello"}"#),
            SocketMessage(seq: 4, direction: .serverToClient, opcode: .ping, time: SocketFixtures.upgradeAt + 1, size: 0, preview: "", previewEncoding: .text),
        ], extensions: "permessage-deflate"))
        return (provider, MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider()))
    }

    func testListMessagesPagesFiltersAndSaysWhatTheConnectionIs() throws {
        let (_, router) = chat()
        let page = try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages")
        XCTAssertEqual(page.messages.map(\.seq), [0, 1, 2, 3, 4])
        XCTAssertEqual(page.messages.map(\.direction), ["sent", "received", "received", "received", "received"])
        XCTAssertEqual(page.messages[0].dataFormat, "json")
        XCTAssertEqual(page.messages[0].atMs, 0)
        XCTAssertEqual(page.messages[1].atMs, 10)
        XCTAssertEqual(page.connection.messages, 5)
        XCTAssertEqual(page.connection.sent, 1)
        XCTAssertTrue(page.connection.open)
        XCTAssertEqual(page.connection.extensions, "permessage-deflate")
        XCTAssertNil(page.nextCursor)

        let received = try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages?direction=received&opcode=text")
        XCTAssertEqual(received.messages.map(\.seq), [1, 3])
        let final = try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages?contains=TRANSCRIPT.FINAL")
        XCTAssertEqual(final.messages.map(\.seq), [3])

        let first = try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages?limit=2")
        XCTAssertEqual(first.messages.map(\.seq), [0, 1])
        XCTAssertEqual(first.nextCursor, "1")
        XCTAssertEqual(first.totalMatched, 5)
        let second = try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages?limit=2&cursor=1")
        XCTAssertEqual(second.messages.map(\.seq), [2, 3])
        let last = try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages?limit=2&cursor=3")
        XCTAssertEqual(last.messages.map(\.seq), [4])
        XCTAssertNil(last.nextCursor)

        XCTAssertEqual(status(router, "/v1/sessions/nope/messages"), 404)
        XCTAssertEqual(status(router, "/v1/sessions/plain/messages"), 400, "not a WebSocket")
        XCTAssertEqual(status(router, "/v1/sessions/ws1/messages?direction=sideways"), 400, "an unknown filter is refused, never dropped")
        XCTAssertEqual(status(router, "/v1/sessions/ws1/messages?opcode=continuation"), 400)
    }

    /// Real binary is withheld while the host is redacted; the same message
    /// is base64 for a host the user excepted.
    func testBinaryIsWithheldWhileRedactingAndBase64ForAnExceptedHost() throws {
        let (provider, router) = chat()
        let redacted = try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages?opcode=binary")
        XCTAssertNil(redacted.messages[0].data)
        XCTAssertEqual(redacted.messages[0].withheld, MCPSocketEgress.binaryWithheld)
        XCTAssertEqual(redacted.messages[0].dataFormat, "none")
        let open = MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider(), redactor: MCPRedactor(enabled: false))
        let plain = try get(MCPSocketMessagePage.self, open, "/v1/sessions/ws1/messages?opcode=binary")
        XCTAssertEqual(plain.messages[0].data, "AQID")
        XCTAssertEqual(plain.messages[0].dataFormat, "base64")
    }

    /// A preview the extension CUT loses its trailing token before
    /// redaction: the cut can split a secret, and half of one has no shape.
    func testACutPreviewLosesItsTrailingTokenBeforeRedaction() {
        let stored = StoredSocketMessage(ordinal: 1, message: SocketFixtures.text(0, "user said the code is QZ7hunter2xy", truncated: true))
        let shown = MCPSocketEgress.message(stored, uid: "u", host: "h", upgradeAt: nil, redacting: true)
        XCTAssertEqual(shown.data, "user said the code is …")
        XCTAssertTrue(shown.dataTruncated)
        let whole = StoredSocketMessage(ordinal: 1, message: SocketFixtures.text(0, "user said the code is QZ7hunter2xy"))
        XCTAssertEqual(MCPSocketEgress.message(whole, uid: "u", host: "h", upgradeAt: nil, redacting: true).data?.hasPrefix("user said the code is"), true)
        // No separator at all: nothing of it is shown.
        let token = StoredSocketMessage(ordinal: 1, message: SocketFixtures.text(0, "QZ7hunter2xyQZ7hunter2xy", truncated: true))
        XCTAssertEqual(MCPSocketEgress.message(token, uid: "u", host: "h", upgradeAt: nil, redacting: true).data, "…")
    }

    /// A key-named secret in a JSON message is caught by structure, and one
    /// in a cut JSON message by name.
    func testKeyNamedSecretsAreRedactedWholeAndCut() {
        let whole = StoredSocketMessage(ordinal: 1, message: SocketFixtures.text(0, #"{"type":"auth","password":"hunter2"}"#))
        XCTAssertEqual(MCPSocketEgress.message(whole, uid: "u", host: "h", upgradeAt: nil, redacting: true).data,
                       #"{"password":"«redacted»","type":"auth"}"#)
        let cut = StoredSocketMessage(ordinal: 1, message: SocketFixtures.text(0, #"{"type":"auth","password":"hunter2","more":"lots of"#, truncated: true))
        let shown = MCPSocketEgress.message(cut, uid: "u", host: "h", upgradeAt: nil, redacting: true)
        XCTAssertFalse(shown.data?.contains("hunter2") ?? true, shown.data ?? "")
        XCTAssertEqual(shown.dataFormat, "text")
    }

    /// `contains` matches what the answer shows: a filter can never be used
    /// to probe for a value the answer masks.
    func testContainsCannotFindARedactedSecret() throws {
        let provider = StubSocketProvider()
        let id = provider.addSocket(uid: "ws1")
        provider.store.ingest(SocketFixtures.batch(id, 1, [SocketFixtures.text(0, #"{"password":"hunter2","note":"hi"}"#)]))
        let router = MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider())
        XCTAssertTrue(try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages?contains=hunter2").messages.isEmpty)
        XCTAssertEqual(try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages?contains=note").messages.count, 1)
        XCTAssertTrue(try get(MCPSocketFeed.self, router, "/v1/messages?since=0&contains=hunter2").messages.isEmpty)
    }

    /// The feed: no `since` = the baseline only; `since` = only what came
    /// after, oldest first, filtered by uid or host.
    func testTheFeedBaselineAndAfter() throws {
        let (provider, router) = chat()
        let baseline = try get(MCPSocketFeed.self, router, "/v1/messages")
        XCTAssertEqual(baseline.latestOrdinal, 5)
        XCTAssertTrue(baseline.messages.isEmpty, "the baseline carries no messages")
        let other = provider.addSocket(uid: "ws2", host: "feed.other.net")
        provider.store.ingest(SocketFixtures.batch(other, 1, [SocketFixtures.text(0, #"{"type":"tick"}"#)]))
        let wsID = try XCTUnwrap(provider.rows.first { $0.summary.uid == "ws1" }).exchangeID
        provider.store.ingest(SocketFixtures.batch(wsID, 2, [SocketFixtures.text(5, #"{"type":"transcript.final","text":"again"}"#)]))

        let after = try get(MCPSocketFeed.self, router, "/v1/messages?since=5")
        XCTAssertEqual(after.messages.map(\.uid), ["ws2", "ws1"])
        XCTAssertEqual(after.latestOrdinal, 7)
        XCTAssertEqual(after.scannedThrough, 7)
        XCTAssertEqual(try get(MCPSocketFeed.self, router, "/v1/messages?since=5&host=OTHER").messages.map(\.uid), ["ws2"])
        XCTAssertEqual(try get(MCPSocketFeed.self, router, "/v1/messages?since=5&uid=ws1&contains=transcript.final").messages.map(\.seq), [5])
        XCTAssertEqual(try get(MCPSocketFeed.self, router, "/v1/messages?since=0&contains=transcript.final").messages.map(\.seq), [3, 5])
        XCTAssertEqual(status(router, "/v1/messages?since=-3"), 400)
        XCTAssertEqual(status(router, "/v1/messages?since=0&direction=up-ish"), 400)
    }

    /// The row join (`MCPSocketFeedRaw.joining`): a message whose row has
    /// not landed stops the scan just before it; one missing for longer than
    /// the grace is skipped; a scan that hit its limit got only as far as its
    /// last message — even when it skipped an orphan on the way, which the
    /// old count-based rule read as a complete scan and jumped to the newest.
    func testTheFeedJoinStopsBeforeAMissingRowAndNeverPassesAnUnscannedMessage() {
        let known = UUID(), pending = UUID(), gone = UUID()
        func stored(_ ordinal: Int64, _ time: Double) -> StoredSocketMessage {
            StoredSocketMessage(ordinal: ordinal, message: SocketFixtures.text(ordinal, "m\(ordinal)", at: time - SocketFixtures.upgradeAt))
        }
        let now = SocketFixtures.upgradeAt + 100
        let row: (UUID, StoredSocketMessage) -> MCPSocketFeedItem? = { id, message in
            id == known ? MCPSocketFeedItem(uid: "ws1", host: "chat.example.com", upgradeAt: SocketFixtures.upgradeAt, stored: message) : nil
        }

        // A young orphan at ordinal 13 stops the scan at 12.
        let stalled = MCPSocketFeedRaw.joining(
            latestOrdinal: 20, after: 10,
            found: [(known, stored(11, now - 1)), (gone, stored(12, now - 60)), (pending, stored(13, now - 0.1)), (known, stored(14, now))],
            scanLimit: 100, now: now, row: row)
        XCTAssertEqual(stalled.items.map(\.stored.ordinal), [11])
        XCTAssertEqual(stalled.scannedThrough, 12)
        XCTAssertEqual(stalled.latestOrdinal, 20, "the newest ordinal is still reported truthfully")

        // A complete scan (below the limit), orphans all old: through the newest.
        let complete = MCPSocketFeedRaw.joining(
            latestOrdinal: 20, after: 10,
            found: [(known, stored(11, now)), (gone, stored(12, now - 60))],
            scanLimit: 100, now: now, row: row)
        XCTAssertEqual(complete.items.map(\.stored.ordinal), [11])
        XCTAssertEqual(complete.scannedThrough, 20)

        // The scan hit its limit of 3 and skipped one: only through 13.
        let limited = MCPSocketFeedRaw.joining(
            latestOrdinal: 20, after: 10,
            found: [(known, stored(11, now)), (gone, stored(12, now - 60)), (known, stored(13, now))],
            scanLimit: 3, now: now, row: row)
        XCTAssertEqual(limited.items.count, 2)
        XCTAssertEqual(limited.scannedThrough, 13)
        let feed = MCPSocketEgress.feed(limited, after: 10, filter: MCPMessageFilter(contains: "nothing matches"), limit: 20, redacts: { _ in true })
        XCTAssertEqual(feed.scannedThrough, 13, "the next poll resumes at 14, not past the unscanned 14…20")
        XCTAssertEqual(feed.latestOrdinal, 20)
    }

    func testTheToolTextReadsLikeTheTab() throws {
        let (_, router) = chat()
        let page = try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages")
        let text = MCPTextFormat.socketMessages(page)
        XCTAssertTrue(text.contains("WebSocket ws1 · https://chat.example.com/socket?room=1"), text)
        XCTAssertTrue(text.contains("5 messages (1 sent, 4 received) · 5 kept · open · extensions: permessage-deflate"), text)
        XCTAssertTrue(text.contains("#1 ↑ sent text +0ms 41B"), text)
        XCTAssertTrue(text.contains("  (\(MCPSocketEgress.binaryWithheld))"), text)
        let empty = MCPTextFormat.messageWait(MCPMessageWaiter.Outcome(message: nil, timedOut: true, polls: 3), timeout: 5,
                                              filter: MCPMessageFilter(contains: "transcript.final"))
        XCTAssertTrue(empty.hasPrefix("No new WebSocket message matching containing \"transcript.final\" arrived within 5s."), empty)
    }
}

// MARK: - The wait

final class MCPMessageWaiterTests: XCTestCase {
    private func message(_ ordinal: Int64, _ text: String = "m") -> MCPSocketMessage {
        MCPSocketMessage(uid: "ws1", host: "h", seq: ordinal, ordinal: ordinal, direction: "received", opcode: "text", atMs: nil,
                         time: 0, size: 1, compressed: false, frames: 1, data: text, dataFormat: "text", dataTruncated: false,
                         withheld: nil, closeCode: nil, closeReason: nil)
    }

    /// Messages already captured at the call never satisfy the wait — only
    /// one that ARRIVES after it does, however well the old one matches.
    func testTheBaselineIgnoresEverythingBeforeTheCall() async throws {
        var clock: TimeInterval = 0
        var asked: [Int64?] = []
        let outcome = try await MCPMessageWaiter.wait(
            timeout: 10,
            fetch: { since in
                asked.append(since)
                guard let since else { return MCPSocketFeed(latestOrdinal: 40, scannedThrough: 40, messages: []) }
                // The server only ever returns matches after `since`; a
                // stale answer that included an old one must still be skipped.
                if asked.count < 4 { return MCPSocketFeed(latestOrdinal: 39 + Int64(asked.count), scannedThrough: 39 + Int64(asked.count), messages: [self.message(12, "old")]) }
                return MCPSocketFeed(latestOrdinal: 44, scannedThrough: 44, messages: [self.message(12, "old"), self.message(44, "new")])
            },
            elapsed: { clock },
            sleep: { clock += $0 }
        )
        XCTAssertEqual(outcome.message?.data, "new")
        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(asked.first!, nil, "the first call is the baseline")
        XCTAssertEqual(asked.dropFirst().map { $0! }, [40, 41, 42], "each poll asks from where the previous one scanned")
    }

    func testItTimesOutWhenNothingNewArrives() async throws {
        var clock: TimeInterval = 0
        var polls = 0
        let outcome = try await MCPMessageWaiter.wait(
            timeout: 2,
            pollInterval: 0.5,
            fetch: { _ in polls += 1; return MCPSocketFeed(latestOrdinal: 7, scannedThrough: 7, messages: []) },
            elapsed: { clock },
            sleep: { clock += $0 }
        )
        XCTAssertTrue(outcome.timedOut)
        XCTAssertNil(outcome.message)
        XCTAssertEqual(outcome.polls, polls)
        XCTAssertEqual(polls, 5, "the baseline, then one poll every 0.5 s for 2 s")
    }

    /// End to end over the router: a message in the store before the call is
    /// not returned; one ingested during the wait is.
    func testThroughTheRouterANewMessageResolvesIt() async throws {
        let provider = StubSocketProvider()
        let id = provider.addSocket(uid: "ws1")
        provider.store.ingest(SocketFixtures.batch(id, 1, [SocketFixtures.text(0, #"{"type":"transcript.final","text":"before"}"#)]))
        let router = MCPBridgeRouter(token: "t", sessions: provider, status: StubStatusProvider())
        let filter = MCPMessageFilter(uid: "ws1", contains: "transcript.final")
        var clock: TimeInterval = 0
        var polls = 0
        let outcome = try await MCPMessageWaiter.wait(
            timeout: 10,
            fetch: { since in
                var items = filter.queryItems
                if let since { items.append(URLQueryItem(name: "since", value: String(since))) }
                var components = URLComponents()
                components.path = "/v1/messages"
                components.queryItems = items
                let response = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: components.string!, token: "t"))))
                return try JSONDecoder().decode(MCPSocketFeed.self, from: response.body)
            },
            elapsed: { clock },
            sleep: { interval in
                clock += interval
                polls += 1
                if polls == 3 {
                    provider.store.ingest(SocketFixtures.batch(id, 2, [SocketFixtures.text(1, #"{"type":"transcript.delta"}"#),
                                                                     SocketFixtures.text(2, #"{"type":"transcript.final","text":"after"}"#)]))
                }
            }
        )
        XCTAssertEqual(outcome.message?.seq, 2)
        XCTAssertTrue(outcome.message?.data?.contains("after") ?? false)
    }
}

// MARK: - HAR

final class SocketHARTests: XCTestCase {
    private func conversation(_ log: SocketMessageLog?, host: String = "chat.example.com") -> MCPSocketConversation {
        MCPSocketConversation(uid: "ws1", host: host, url: "https://\(host)/socket", upgradeAt: SocketFixtures.upgradeAt, isWebSocket: true, log: log)
    }

    private func log(_ messages: [SocketMessage], close: SocketClose? = nil, evicted: Int64 = 0) -> SocketMessageLog {
        let id = UUID()
        var log = SocketMessageLog(exchangeID: id)
        var ordinal: Int64 = 0
        log.apply(SocketFixtures.batch(id, 1, messages, evicted: evicted, final: close != nil, close: close), nextOrdinal: { ordinal += 1; return ordinal })
        return log
    }

    private func entry(_ data: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        return try XCTUnwrap(entries.first)
    }

    private func detail(host: String = "chat.example.com") -> MCPSessionDetail {
        MCPSessionDetail(summary: makeSession(uid: "ws1", host: host, statusCode: 101), responseHeaders: ["Upgrade": "websocket"])
    }

    /// Chrome's shape, on the 101 entry.
    func testTheMessagesRideOnThe101EntryInChromesShape() throws {
        let close = SocketClose(end: .closeHandshake, code: 1000, reason: "bye", initiatedBy: .clientToServer, totalMessages: 5)
        let messages = log([
            SocketFixtures.text(0, #"{"type":"hello"}"#, sent: true),
            SocketFixtures.text(1, "welcome"),
            SocketFixtures.binary(2, [0xff, 0x00]),
            SocketMessage(seq: 3, direction: .serverToClient, opcode: .ping, time: SocketFixtures.upgradeAt + 2, size: 0, preview: "", previewEncoding: .text),
            SocketFixtures.close(4, code: 1000, reason: "bye"),
        ], close: close, evicted: 2)
        let result = MCPHARExport.encode(sessions: [detail()], redactor: MCPRedactor(), creatorVersion: "1.1.0",
                                         webSocketMessages: ["ws1": conversation(messages)])
        let entry = try entry(result.data)
        let list = try XCTUnwrap(entry["_webSocketMessages"] as? [[String: Any]])
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(list.map { $0["type"] as? String }, ["send", "receive", "receive", "receive", "send"])
        XCTAssertEqual(list.map { $0["opcode"] as? Int }, [1, 1, 2, 9, 8])
        XCTAssertEqual(list[0]["time"] as? Double, SocketFixtures.upgradeAt)
        XCTAssertEqual(list[0]["data"] as? String, #"{"type":"hello"}"#)
        XCTAssertEqual(list[1]["data"] as? String, "welcome")
        XCTAssertEqual(list[2]["data"] as? String, "", "binary is withheld while the host is redacted")
        XCTAssertEqual(list[2]["_reqresWithheld"] as? String, MCPSocketEgress.binaryWithheld)
        XCTAssertEqual(list[4]["data"] as? String, "bye")
        for message in list {
            XCTAssertTrue(Set(message.keys).isSuperset(of: ["type", "time", "opcode", "data"]))
        }
        XCTAssertEqual(entry["_reqresWebSocketMessagesNotKept"] as? Int, 2)
        XCTAssertEqual((entry["_reqresWebSocketClose"] as? [String: Any])?["end"] as? String, "close_handshake")
        XCTAssertEqual((entry["_reqresWebSocketClose"] as? [String: Any])?["code"] as? Int, 1000)
    }

    func testTheMessagesAreRedactedAndBinaryIsBase64ForAnUnredactedHost() throws {
        let messages = log([
            SocketFixtures.text(0, #"{"token":"abc123","n":1}"#, sent: true),
            SocketFixtures.text(1, "key sk_live_" + "ABCDEF0123456789 here"),
            SocketFixtures.binary(2, [0xff, 0x00]),
        ])
        let redacted = try entry(MCPHARExport.encode(sessions: [detail()], redactor: MCPRedactor(), creatorVersion: "1",
                                                     webSocketMessages: ["ws1": conversation(messages)]).data)
        let list = try XCTUnwrap(redacted["_webSocketMessages"] as? [[String: Any]])
        XCTAssertEqual(list[0]["data"] as? String, #"{"n":1,"token":"«redacted»"}"#)
        XCTAssertFalse((list[1]["data"] as? String ?? "").contains("sk_live_ABCDEF"))
        let open = try entry(MCPHARExport.encode(sessions: [detail()], redactor: MCPRedactor(enabled: false), creatorVersion: "1",
                                                 webSocketMessages: ["ws1": conversation(messages)]).data)
        let plain = try XCTUnwrap(open["_webSocketMessages"] as? [[String: Any]])
        XCTAssertEqual(plain[2]["data"] as? String, "/wA=")
        XCTAssertEqual(plain[0]["data"] as? String, #"{"token":"abc123","n":1}"#)
    }

    /// The export's one size rule: an entry past the cap is cut short — the
    /// first entry is kept without its payloads, messages included.
    func testTheExportSizeCapAppliesToTheMessages() throws {
        let big = String(repeating: "w", count: 50_000)
        let messages = log((0..<10).map { SocketFixtures.text($0, big) })
        let result = MCPHARExport.encode(sessions: [detail()], redactor: MCPRedactor(enabled: false), creatorVersion: "1",
                                         maxEncodedBytes: 100_000, webSocketMessages: ["ws1": conversation(messages)])
        XCTAssertTrue(result.truncated)
        XCTAssertLessThan(result.data.count, 100_000)
        let entry = try entry(result.data)
        XCTAssertEqual((entry["_webSocketMessages"] as? [Any])?.count, 0)
        XCTAssertEqual(entry["_reqresWebSocketMessagesOmitted"] as? Int, 10)
    }

    func testANonWebSocketEntryHasNoMessagesKey() throws {
        let entry = try entry(MCPHARExport.encode(sessions: [MCPSessionDetail(summary: makeSession(uid: "a"))], redactor: MCPRedactor(), creatorVersion: "1").data)
        XCTAssertNil(entry["_webSocketMessages"])
    }
}
