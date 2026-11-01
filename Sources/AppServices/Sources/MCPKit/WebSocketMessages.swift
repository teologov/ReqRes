//
//  WebSocketMessages.swift
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
//  WebSocket messages as the app keeps them (protocol PRD Phase 4b, decision
//  D10; protocol-engine doc §S7). The core's frame tap sends
//  `websocket_messages` batches (doc §C11.3); these are Foundation-only
//  mirrors of that wire contract, decoded straight from the bus JSON with
//  the same leniency the core's own decoder has, plus the retention rules:
//  per connection the FIRST 200 and the LAST 2,000 messages, under a byte
//  budget, with every message let go in between counted — and an app-wide
//  bound on top, so no number of sockets can grow the app without limit.
//
//  Named `Socket…` rather than `WebSocket…`: the app target imports both
//  this module and the core, which publishes `WebSocketMessage` & co.
//

import Foundation

// MARK: - The wire (doc §C11.3)

/// Who sent a message. Unknown values read as `serverToClient`, as in the core.
public enum SocketDirection: String, Codable, CaseIterable, Sendable {
    case clientToServer
    case serverToClient

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SocketDirection(rawValue: raw) ?? .serverToClient
    }

    /// The app sent it (↑ Sent); otherwise it arrived from the server (↓ Received).
    public var isSent: Bool { self == .clientToServer }

    /// The word agents read and filter by: `sent` / `received`.
    public var agentToken: String { isSent ? "sent" : "received" }

    /// An agent's `direction` argument. Accepts the agent tokens, the wire
    /// spellings and the obvious synonyms; nil for anything else (refused,
    /// never ignored — a dropped filter reads as a filtered answer).
    public static func parse(_ raw: String) -> SocketDirection? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "sent", "send", "out", "outgoing", "up", "client", "clienttoserver", "client_to_server": return .clientToServer
        case "received", "receive", "in", "incoming", "down", "server", "servertoclient", "server_to_client": return .serverToClient
        default: return nil
        }
    }
}

/// A message's opcode (its first frame's). Unknown values read as `binary`.
public enum SocketOpcode: String, Codable, CaseIterable, Sendable {
    case text
    case binary
    case close
    case ping
    case pong

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SocketOpcode(rawValue: raw) ?? .binary
    }

    public var isControl: Bool { self == .close || self == .ping || self == .pong }

    /// RFC 6455 §5.2's number — what Chrome's HAR `_webSocketMessages` writes.
    public var number: Int {
        switch self {
        case .text: return 1
        case .binary: return 2
        case .close: return 8
        case .ping: return 9
        case .pong: return 10
        }
    }

    public static func parse(_ raw: String) -> SocketOpcode? {
        SocketOpcode(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// How a preview is spelled. Unknown values read as `base64`, as in the core.
public enum SocketPreviewEncoding: String, Codable, CaseIterable, Sendable {
    case text
    case base64

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SocketPreviewEncoding(rawValue: raw) ?? .base64
    }
}

/// How a WebSocket connection ended. Unknown values read as `connectionDropped`.
public enum SocketEnd: String, Codable, CaseIterable, Sendable {
    case closeHandshake
    case closeFrame
    case connectionDropped
    case idleTimeout

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SocketEnd(rawValue: raw) ?? .connectionDropped
    }
}

/// One complete message, as the extension's tap read it. Emitted when its
/// last byte was read, so it is always whole — only its PREVIEW can be cut
/// (`truncated`, at 64 KB, in the extension, before anything else sees it).
public struct SocketMessage: Codable, Equatable, Sendable {
    /// Per connection, both directions, 0-based. A gap = messages not kept.
    public var seq: Int64
    public var direction: SocketDirection
    public var opcode: SocketOpcode
    /// When its last byte was read, seconds since 1970.
    public var time: Double
    /// Payload bytes after unmasking and inflating.
    public var size: Int64
    /// Payload bytes on the wire (differs from `size` only when compressed).
    public var wireSize: Int64
    public var compressed: Bool
    public var frames: Int
    /// The first 64 KB of the payload, as text or base64.
    public var preview: String
    public var previewEncoding: SocketPreviewEncoding
    /// The payload is longer than the preview.
    public var truncated: Bool
    public var closeCode: Int?
    public var closeReason: String?

    public init(seq: Int64, direction: SocketDirection, opcode: SocketOpcode, time: Double, size: Int64,
                wireSize: Int64? = nil, compressed: Bool = false, frames: Int = 1, preview: String,
                previewEncoding: SocketPreviewEncoding, truncated: Bool = false, closeCode: Int? = nil, closeReason: String? = nil) {
        self.seq = seq
        self.direction = direction
        self.opcode = opcode
        self.time = time
        self.size = size
        self.wireSize = wireSize ?? size
        self.compressed = compressed
        self.frames = frames
        self.preview = preview
        self.previewEncoding = previewEncoding
        self.truncated = truncated
        self.closeCode = closeCode
        self.closeReason = closeReason
    }

    private enum CodingKeys: String, CodingKey {
        case seq, direction, opcode, time, size, wireSize, compressed, frames, preview, previewEncoding, truncated, closeCode, closeReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decodeIfPresent(Int64.self, forKey: .seq) ?? 0
        direction = try c.decodeIfPresent(SocketDirection.self, forKey: .direction) ?? .serverToClient
        opcode = try c.decodeIfPresent(SocketOpcode.self, forKey: .opcode) ?? .binary
        time = try c.decodeIfPresent(Double.self, forKey: .time) ?? 0
        size = max(0, try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0)
        wireSize = max(0, try c.decodeIfPresent(Int64.self, forKey: .wireSize) ?? size)
        compressed = try c.decodeIfPresent(Bool.self, forKey: .compressed) ?? false
        frames = try c.decodeIfPresent(Int.self, forKey: .frames) ?? 1
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        previewEncoding = try c.decodeIfPresent(SocketPreviewEncoding.self, forKey: .previewEncoding) ?? .base64
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        closeCode = try c.decodeIfPresent(Int.self, forKey: .closeCode)
        closeReason = try c.decodeIfPresent(String.self, forKey: .closeReason)
    }

    /// The preview's bytes: UTF-8 for text, decoded for base64 (nil when the
    /// base64 does not decode — the message is then shown as unreadable,
    /// never guessed at).
    public var previewData: Data? {
        switch previewEncoding {
        case .text: return Data(preview.utf8)
        case .base64: return Data(base64Encoded: preview)
        }
    }

    /// The preview as text when it IS text: a text preview, or a base64 one
    /// whose bytes are valid UTF-8 with no control characters but tab and
    /// line breaks (a JSON frame sent as binary). Nil for real binary.
    public var previewText: String? {
        if previewEncoding == .text { return preview }
        guard let data = previewData, let text = String(data: data, encoding: .utf8) else { return nil }
        let printable = text.unicodeScalars.allSatisfy { scalar in
            scalar == "\t" || scalar == "\n" || scalar == "\r" || !CharacterSet.controlCharacters.contains(scalar)
        }
        return printable ? text : nil
    }

    /// What this message costs to keep, for the byte budgets: its preview's
    /// characters plus a fixed allowance for the record itself.
    public var retainedCost: Int { preview.utf8.count + (closeReason?.utf8.count ?? 0) + Self.recordOverhead }
    /// Fixed fields, the String headers and the stored ordinal — rounded up.
    public static let recordOverhead = 160
}

/// A direction the tap stopped reading. The connection is unaffected.
public struct SocketTapIssue: Codable, Equatable, Sendable {
    public var direction: SocketDirection
    /// The core's own sentence ("inflate", "RSV2 set", …) — not captured material.
    public var reason: String
    public var atByte: Int64

    public init(direction: SocketDirection, reason: String, atByte: Int64 = 0) {
        self.direction = direction
        self.reason = reason
        self.atByte = atByte
    }

    private enum CodingKeys: String, CodingKey { case direction, reason, atByte }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.decodeIfPresent(SocketDirection.self, forKey: .direction) ?? .serverToClient
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        atByte = try c.decodeIfPresent(Int64.self, forKey: .atByte) ?? 0
    }
}

/// How the connection closed — with the final batch.
public struct SocketClose: Codable, Equatable, Sendable {
    public var end: SocketEnd
    public var code: Int?
    public var reason: String?
    public var initiatedBy: SocketDirection?
    /// Messages the tap read over the whole connection (kept or not).
    public var totalMessages: Int64
    public var bytesFromClient: Int64
    public var bytesFromServer: Int64

    public init(end: SocketEnd, code: Int? = nil, reason: String? = nil, initiatedBy: SocketDirection? = nil,
                totalMessages: Int64 = 0, bytesFromClient: Int64 = 0, bytesFromServer: Int64 = 0) {
        self.end = end
        self.code = code
        self.reason = reason
        self.initiatedBy = initiatedBy
        self.totalMessages = totalMessages
        self.bytesFromClient = bytesFromClient
        self.bytesFromServer = bytesFromServer
    }

    private enum CodingKeys: String, CodingKey { case end, code, reason, initiatedBy, totalMessages, bytesFromClient, bytesFromServer }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        end = try c.decodeIfPresent(SocketEnd.self, forKey: .end) ?? .connectionDropped
        code = try c.decodeIfPresent(Int.self, forKey: .code)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        initiatedBy = try c.decodeIfPresent(SocketDirection.self, forKey: .initiatedBy)
        totalMessages = try c.decodeIfPresent(Int64.self, forKey: .totalMessages) ?? 0
        bytesFromClient = try c.decodeIfPresent(Int64.self, forKey: .bytesFromClient) ?? 0
        bytesFromServer = try c.decodeIfPresent(Int64.self, forKey: .bytesFromServer) ?? 0
    }
}

/// One `websocket_messages` payload (the value under `"data"`).
public struct SocketMessageBatch: Codable, Equatable, Sendable {
    /// The handshake's row: `SessionCodable.exchangeID` of the `101`.
    public var exchangeID: UUID
    /// 1, 2, 3 … per connection; a gap = a lost batch.
    public var batch: Int
    public var messages: [SocketMessage]
    /// Dropped IN THE EXTENSION since the previous batch (the app fell behind).
    public var evictedMessages: Int64
    /// Every direction the tap stopped reading so far (cumulative).
    public var gaveUp: [SocketTapIssue]
    /// The `101`'s `Sec-WebSocket-Extensions` (first and final batch).
    public var extensions: String?
    public var final: Bool
    public var close: SocketClose?
    public var sentAt: Double

    public init(exchangeID: UUID, batch: Int, messages: [SocketMessage], evictedMessages: Int64 = 0, gaveUp: [SocketTapIssue] = [],
                extensions: String? = nil, final: Bool = false, close: SocketClose? = nil, sentAt: Double = 0) {
        self.exchangeID = exchangeID
        self.batch = batch
        self.messages = messages
        self.evictedMessages = evictedMessages
        self.gaveUp = gaveUp
        self.extensions = extensions
        self.final = final
        self.close = close
        self.sentAt = sentAt
    }

    private enum CodingKeys: String, CodingKey { case exchangeID, batch, messages, evictedMessages, gaveUp, extensions, final, close, sentAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exchangeID = try c.decode(UUID.self, forKey: .exchangeID)
        batch = try c.decodeIfPresent(Int.self, forKey: .batch) ?? 0
        messages = try c.decodeIfPresent([SocketMessage].self, forKey: .messages) ?? []
        evictedMessages = max(0, try c.decodeIfPresent(Int64.self, forKey: .evictedMessages) ?? 0)
        gaveUp = try c.decodeIfPresent([SocketTapIssue].self, forKey: .gaveUp) ?? []
        extensions = try c.decodeIfPresent(String.self, forKey: .extensions)
        final = try c.decodeIfPresent(Bool.self, forKey: .final) ?? false
        close = try c.decodeIfPresent(SocketClose.self, forKey: .close)
        sentAt = try c.decodeIfPresent(Double.self, forKey: .sentAt) ?? 0
    }
}

// MARK: - One connection's messages (D10's ring)

/// A kept message and the app-wide number it was given on arrival — what a
/// wait uses to tell "after the call" from "before" (`MCPMessageWaiter`).
public struct StoredSocketMessage: Equatable, Sendable {
    public var ordinal: Int64
    public var message: SocketMessage

    public init(ordinal: Int64, message: SocketMessage) {
        self.ordinal = ordinal
        self.message = message
    }
}

/// One WebSocket connection's messages: the FIRST 200 and the LAST 2,000
/// (decision D10), each part under its own byte budget, with the messages let
/// go between them counted — never silently.
///
/// Why both ends: the first messages are the handshake-shaped ones (auth,
/// subscribe, session setup) that explain everything after; the last are
/// where the problem being debugged usually is. A connection left open for an
/// hour at 20 messages a second would otherwise hold 72,000.
public struct SocketMessageLog: Equatable, Sendable {
    public static let headCapacity = 200
    public static let tailCapacity = 2_000
    /// Previews are ≤ 64 KB of text or base64 (≈ 87 KB) each, so a count
    /// alone does not bound memory: 2,200 × 87 KB is 190 MB. D10: 8 MB a row.
    public static let headByteBudget = 2 * 1024 * 1024
    public static let tailByteBudget = 6 * 1024 * 1024
    public static var byteBudget: Int { headByteBudget + tailByteBudget }

    public let exchangeID: UUID
    public private(set) var head: [StoredSocketMessage] = []
    private var tail: [StoredSocketMessage] = []
    private var tailStart = 0
    /// Once a message has gone to the tail the head is final: it is the
    /// first N, contiguous, or it would not be "the first".
    private var headClosed = false
    public private(set) var headBytes = 0
    public private(set) var tailBytes = 0

    /// Messages that reached the app (kept or since let go).
    public private(set) var received: Int64 = 0
    /// Let go by THIS app: the ring (D10) and the app-wide bound.
    public private(set) var droppedByApp: Int64 = 0
    /// Dropped in the EXTENSION because the app was not reading fast enough
    /// (the batches' `evictedMessages`).
    public private(set) var droppedByExtension: Int64 = 0
    /// Batches that never arrived (a gap in `batch`).
    public private(set) var lostBatches = 0
    public private(set) var lastBatch = 0
    public private(set) var lastSeq: Int64 = -1
    public private(set) var gaveUp: [SocketTapIssue] = []
    public private(set) var extensions: String?
    public private(set) var close: SocketClose?
    public private(set) var isFinal = false
    public private(set) var sentCount: Int64 = 0
    public private(set) var receivedCount: Int64 = 0
    /// Payload bytes of the messages that reached the app, each way.
    public private(set) var sentBytes: Int64 = 0
    public private(set) var receivedBytes: Int64 = 0

    public init(exchangeID: UUID) {
        self.exchangeID = exchangeID
    }

    public var retainedCount: Int { head.count + tail.count - tailStart }
    public var retainedBytes: Int { headBytes + tailBytes }

    /// Every kept message, oldest first.
    public var messages: [StoredSocketMessage] {
        guard tailStart < tail.count else { return head }
        return head + tail[tailStart...]
    }

    /// Kept messages with `seq` greater than `seq`, oldest first.
    public func messages(afterSeq seq: Int64) -> [StoredSocketMessage] {
        messages.filter { $0.message.seq > seq }
    }

    /// Kept messages given an ordinal after `ordinal`, oldest first. Walks
    /// back from the newest: ordinals only grow within a connection.
    public func messages(afterOrdinal ordinal: Int64) -> [StoredSocketMessage] {
        var found: [StoredSocketMessage] = []
        var index = tail.count - 1
        while index >= tailStart, tail[index].ordinal > ordinal {
            found.append(tail[index])
            index -= 1
        }
        if index < tailStart {
            var headIndex = head.count - 1
            while headIndex >= 0, head[headIndex].ordinal > ordinal {
                found.append(head[headIndex])
                headIndex -= 1
            }
        }
        return found.reversed()
    }

    /// The newest ordinal this log holds, or nil when it keeps nothing.
    public var newestOrdinal: Int64? {
        tailStart < tail.count ? tail.last?.ordinal : head.last?.ordinal
    }

    /// Applies one batch. Returns the messages it kept (possibly fewer than it
    /// carried, never a message twice). A batch number already seen, or any
    /// batch after the final one, changes nothing.
    @discardableResult
    public mutating func apply(_ batch: SocketMessageBatch, nextOrdinal: () -> Int64) -> Int {
        guard !isFinal else { return 0 }
        if batch.batch > 0 {
            guard batch.batch > lastBatch else { return 0 }
            if lastBatch > 0 || batch.batch > 1 {
                lostBatches += max(0, batch.batch - lastBatch - 1)
            }
            lastBatch = batch.batch
        }
        droppedByExtension += batch.evictedMessages
        if !batch.gaveUp.isEmpty { gaveUp = batch.gaveUp }
        if let extensions = batch.extensions { self.extensions = extensions }
        var kept = 0
        for message in batch.messages where message.seq > lastSeq {
            lastSeq = message.seq
            append(StoredSocketMessage(ordinal: nextOrdinal(), message: message))
            kept += 1
        }
        if batch.final {
            isFinal = true
            close = batch.close
        }
        return kept
    }

    private mutating func append(_ stored: StoredSocketMessage) {
        received += 1
        if stored.message.direction.isSent {
            sentCount += 1
            sentBytes += stored.message.size
        } else {
            receivedCount += 1
            receivedBytes += stored.message.size
        }
        let cost = stored.message.retainedCost
        if !headClosed, head.count < Self.headCapacity, headBytes + cost <= Self.headByteBudget {
            head.append(stored)
            headBytes += cost
            return
        }
        headClosed = true
        tail.append(stored)
        tailBytes += cost
        while retainedTailCount > Self.tailCapacity || (tailBytes > Self.tailByteBudget && retainedTailCount > 1) {
            dropOldestTail()
        }
    }

    private var retainedTailCount: Int { tail.count - tailStart }

    private mutating func dropOldestTail() {
        guard tailStart < tail.count else { return }
        tailBytes -= tail[tailStart].message.retainedCost
        tailStart += 1
        droppedByApp += 1
        // Compact now and then rather than shifting the array per message.
        if tailStart > 1_024, tailStart * 2 > tail.count {
            tail.removeFirst(tailStart)
            tailStart = 0
        }
    }

    /// The app-wide bound's lever: lets go of the oldest tail message while
    /// the tail holds more than one; then the head's NEWEST (the head stays
    /// closed, so it is still "the first N"); the newest message of all goes
    /// last. Returns the bytes freed.
    @discardableResult
    public mutating func dropOneForAppLimit() -> Int {
        if retainedTailCount > 1 || (retainedTailCount == 1 && head.isEmpty) {
            let cost = tail[tailStart].message.retainedCost
            dropOldestTail()
            return cost
        }
        guard let last = head.popLast() else { return 0 }
        let cost = last.message.retainedCost
        headBytes -= cost
        headClosed = true
        droppedByApp += 1
        return cost
    }
}

// MARK: - Every connection's messages, bounded app-wide

/// All WebSocket conversations of the capture run, keyed by the `101` row's
/// `exchangeID`. NOT thread-safe: the app owns one behind a lock.
///
/// The bound (protocol-engine doc §S7): at most `maxRetainedPreviewBytes`
/// (64 MB, D10's "64 MB live in the app") of message records — previews plus
/// a fixed allowance per record — at most `maxRetainedMessages` records, and
/// at most `maxConnections` conversations. Past a bound the largest
/// conversation gives up its oldest tail message first; past the connection
/// cap the oldest conversation goes whole.
public struct SocketMessageStore: Sendable {
    public static let maxRetainedPreviewBytes = 64 * 1024 * 1024
    public static let maxRetainedMessages = 100_000
    public static let maxConnections = 1_000

    public private(set) var logs: [UUID: SocketMessageLog] = [:]
    private var order: [UUID] = []
    /// Rows the user deleted or cleared: later batches for them are dropped,
    /// never re-created (the same rule as live rows, doc §S6).
    private var forgotten = BoundedIDSet(capacity: 20_000)
    /// The newest ordinal handed out. Ordinals are app-wide and only grow.
    public private(set) var latestOrdinal: Int64 = 0
    public private(set) var retainedBytes = 0
    public private(set) var retainedMessages = 0

    let maxBytes: Int
    let maxMessages: Int
    let maxLogs: Int

    public init(maxBytes: Int = SocketMessageStore.maxRetainedPreviewBytes,
                maxMessages: Int = SocketMessageStore.maxRetainedMessages,
                maxConnections: Int = SocketMessageStore.maxConnections) {
        self.maxBytes = max(1, maxBytes)
        self.maxMessages = max(1, maxMessages)
        self.maxLogs = max(1, maxConnections)
    }

    public func log(for exchangeID: UUID) -> SocketMessageLog? { logs[exchangeID] }

    public var connectionCount: Int { logs.count }

    /// Applies a batch; returns true when anything a reader shows changed.
    @discardableResult
    public mutating func ingest(_ batch: SocketMessageBatch) -> Bool {
        let id = batch.exchangeID
        guard !forgotten.contains(id) else { return false }
        // Taken OUT of the dictionary while it changes: mutated through
        // `logs[id]` the dictionary would still hold the arrays, and every
        // append would copy the whole tail (up to 2,000 records) under the
        // lock, on the bus's event loop.
        var log: SocketMessageLog
        if let existing = logs.removeValue(forKey: id) {
            log = existing
        } else {
            order.append(id)
            log = SocketMessageLog(exchangeID: id)
        }
        let beforeBytes = log.retainedBytes
        let beforeCount = log.retainedCount
        let beforeFinal = log.isFinal
        var ordinal = latestOrdinal
        let kept = log.apply(batch, nextOrdinal: { ordinal += 1; return ordinal })
        latestOrdinal = ordinal
        retainedBytes += log.retainedBytes - beforeBytes
        retainedMessages += log.retainedCount - beforeCount
        logs[id] = log
        enforceConnectionCap()
        enforceRetentionBounds()
        return kept > 0 || log.isFinal != beforeFinal || batch.evictedMessages > 0 || !batch.gaveUp.isEmpty
    }

    /// The rows left the table (deleted, cleared, evicted by the 5,000 cap).
    public mutating func forget(_ exchangeIDs: [UUID]) {
        for id in exchangeIDs {
            forgotten.insert(id)
            drop(id)
        }
    }

    /// Clear. `forgetting` names the exchanges whose rows the clear dropped
    /// but which have no log YET — a 101 whose socket has not spoken, or a
    /// row still buffered or in flight: without it their first batch after
    /// the clear would create a conversation no row will ever show (and the
    /// agent feed would wait behind it).
    public mutating func removeAll(forgetting exchangeIDs: [UUID] = []) {
        for id in order { forgotten.insert(id) }
        for id in exchangeIDs { forgotten.insert(id) }
        logs.removeAll()
        order.removeAll()
        retainedBytes = 0
        retainedMessages = 0
    }

    /// Messages given an ordinal after `ordinal`, across every conversation,
    /// oldest first, at most `limit`. Ordinal order is arrival order.
    public func messages(afterOrdinal ordinal: Int64, limit: Int) -> [(exchangeID: UUID, stored: StoredSocketMessage)] {
        guard limit > 0, ordinal < latestOrdinal else { return [] }
        var found: [(exchangeID: UUID, stored: StoredSocketMessage)] = []
        for (id, log) in logs {
            guard let newest = log.newestOrdinal, newest > ordinal else { continue }
            for stored in log.messages(afterOrdinal: ordinal) { found.append((id, stored)) }
        }
        found.sort { $0.stored.ordinal < $1.stored.ordinal }
        return Array(found.prefix(limit))
    }

    private mutating func drop(_ id: UUID) {
        guard let log = logs.removeValue(forKey: id) else { return }
        retainedBytes -= log.retainedBytes
        retainedMessages -= log.retainedCount
        order.removeAll { $0 == id }
    }

    private mutating func enforceConnectionCap() {
        while logs.count > maxLogs, let oldest = order.first {
            drop(oldest)
        }
    }

    private mutating func enforceRetentionBounds() {
        while retainedBytes > maxBytes || retainedMessages > maxMessages {
            let overBytes = retainedBytes > maxBytes
            let size: (SocketMessageLog) -> Int = { overBytes ? $0.retainedBytes : $0.retainedCount }
            // One pass finds the largest AND the runner-up; the largest then
            // gives up messages until it is no longer the largest (or the
            // store is within bounds) before anyone looks again — not a scan
            // of every conversation per dropped message.
            var victim: UUID?
            var largest = Int.min
            var runnerUp = Int.min
            for (id, log) in logs {
                let value = size(log)
                if value > largest {
                    runnerUp = largest
                    largest = value
                    victim = id
                } else if value > runnerUp {
                    runnerUp = value
                }
            }
            guard let victim, var log = logs.removeValue(forKey: victim) else { return }
            var dropped = 0
            while log.retainedCount > 0,
                  retainedBytes > maxBytes || retainedMessages > maxMessages,
                  (retainedBytes > maxBytes) == overBytes,
                  dropped == 0 || size(log) >= runnerUp {
                retainedBytes -= log.dropOneForAppLimit()
                retainedMessages -= 1
                dropped += 1
            }
            logs[victim] = log
            guard dropped > 0 else { return }
        }
    }
}
