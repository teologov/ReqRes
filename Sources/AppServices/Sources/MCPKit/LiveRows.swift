//
//  LiveRows.swift
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
//  Live rows, the app half (protocol PRD 4a.1–4a.2, decision D13;
//  protocol-engine doc §S6). The extension announces an exchange that is
//  still open 250 ms after its request head, or at its response head when
//  its type is a stream by definition (`session_started`, reason slow /
//  streamingResponse; core §C14), reports it at most four times a second
//  (`session_progress`) and then sends its final row (`send_session`) — or
//  withdraws it. This file is everything about that
//  which is not AppKit: the ledger that turns messages into table operations,
//  and the table rules (a final REPLACES its live row in place; an in-flight
//  row is never evicted by the retention cap).
//
//  Generic over the row type so the rules are tested without the closed core:
//  the app's `SessionCodable` conforms to `LiveTableRow` with no code (it has
//  `var id: UUID` and `var exchangeID: UUID?` already).
//

import Foundation

// MARK: - The row

/// A row a live table can hold. `id` is the row's identity in the table and
/// for agents (the uid); `exchangeID` is the extension's key for the exchange
/// (nil from a core that predates it — such a row is always final).
public protocol LiveTableRow {
    var id: UUID { get set }
    var exchangeID: UUID? { get }
}

// MARK: - Wire mirrors (the core's types, Foundation-only here)

/// Where an in-flight exchange stands. The core's `LiveExchangePhase` minus
/// `withdrawn`, which is not a state a row can be in (it removes the row).
public enum LivePhase: String, Codable, Equatable, Sendable, CaseIterable {
    /// No response head yet: uploading, the server has not answered, the dial
    /// is in flight, or the request is held at a breakpoint.
    case waiting
    /// The response head arrived (or a rule answered locally); bytes follow.
    case streaming
}

/// The core's `LiveTextStatus`, mirrored so MCPKit can reason about it. An
/// unknown value reads as `notText` (bytes only) — the core's own fallback.
public enum LiveTextState: String, Codable, Equatable, Sendable, CaseIterable {
    case awaitingResponse
    case text
    case noBody
    case notText
    case undecodedEncoding
    case unsupportedCharset
    case decodeFailed
    case replacedByRule
    case stoppedAtRetentionCap
    case stoppedFellBehind

    public init(raw: String) {
        self = LiveTextState(rawValue: raw) ?? .notText
    }

    public init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    /// Text may still arrive for the row.
    public var textMayFollow: Bool { self == .text || self == .awaitingResponse }
}

/// Why an in-flight row stopped being in flight WITHOUT its final row.
public enum LiveEndReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// Nothing heard for longer than the core's in-flight idle limit plus a
    /// margin (`LiveRowLedger.staleAfter`): the extension closes an exchange
    /// silent that long, so its end — a row or a withdraw — was lost.
    case stale
    /// Capture stopped while it was open; the tunnel took the connection with it.
    case captureStopped
}

/// A piece of response text and when it left the extension, in seconds after
/// the response head (nil when the head time is unknown). Kept as pieces, not
/// joined, so an event is stamped with the time of the piece that completed
/// it (S5 invariant 3) even when two progress messages share a flush.
public struct LiveTextChunk: Equatable, Sendable {
    public var text: String
    public var receivedAt: TimeInterval?

    public init(text: String, receivedAt: TimeInterval?) {
        self.text = text
        self.receivedAt = receivedAt
    }
}

// MARK: - Inputs

/// `session_started`, as the ledger reads it.
public struct LiveStartInput<Row: LiveTableRow> {
    public var exchangeID: UUID
    public var phase: LivePhase
    public var row: Row
    public var requestBytes: Int64
    public var responseBytes: Int64
    public var requestComplete: Bool
    public var textStatus: LiveTextState
    public var undecodedEncoding: String?
    /// The response's Content-Type once the head arrived (the row's `rspContentType`).
    public var contentType: String?
    /// Extension wall clock, seconds since 1970, of the response head; nil
    /// until it arrived.
    public var responseHeadAt: TimeInterval?

    public init(exchangeID: UUID, phase: LivePhase, row: Row, requestBytes: Int64 = 0, responseBytes: Int64 = 0,
                requestComplete: Bool = false, textStatus: LiveTextState = .awaitingResponse,
                undecodedEncoding: String? = nil, contentType: String? = nil, responseHeadAt: TimeInterval? = nil) {
        self.exchangeID = exchangeID
        self.phase = phase
        self.row = row
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.requestComplete = requestComplete
        self.textStatus = textStatus
        self.undecodedEncoding = undecodedEncoding
        self.contentType = contentType
        self.responseHeadAt = responseHeadAt
    }
}

/// `session_progress`, as the ledger reads it.
public struct LiveProgressInput<Row: LiveTableRow> {
    public var exchangeID: UUID
    public var sequence: Int
    /// nil = `withdrawn`: remove the row, no final follows.
    public var phase: LivePhase?
    public var requestBytes: Int64
    public var responseBytes: Int64
    public var requestComplete: Bool
    public var appendedText: String?
    /// UTF-8 bytes of text sent BEFORE this message.
    public var textOffset: Int64
    public var textStatus: LiveTextState
    public var undecodedEncoding: String?
    /// The row with the response head, in the first message after it arrived.
    public var row: Row?
    public var contentType: String?
    public var responseHeadAt: TimeInterval?
    /// Extension wall clock, seconds since 1970.
    public var sentAt: TimeInterval

    public init(exchangeID: UUID, sequence: Int, phase: LivePhase?, requestBytes: Int64 = 0, responseBytes: Int64 = 0,
                requestComplete: Bool = false, appendedText: String? = nil, textOffset: Int64 = 0,
                textStatus: LiveTextState = .text, undecodedEncoding: String? = nil, row: Row? = nil,
                contentType: String? = nil, responseHeadAt: TimeInterval? = nil, sentAt: TimeInterval = 0) {
        self.exchangeID = exchangeID
        self.sequence = sequence
        self.phase = phase
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.requestComplete = requestComplete
        self.appendedText = appendedText
        self.textOffset = textOffset
        self.textStatus = textStatus
        self.undecodedEncoding = undecodedEncoding
        self.row = row
        self.contentType = contentType
        self.responseHeadAt = responseHeadAt
        self.sentAt = sentAt
    }
}

public enum LiveIngestMessage<Row: LiveTableRow> {
    case started(LiveStartInput<Row>)
    case progress(LiveProgressInput<Row>)
    /// `send_session`: every exchange's final row, live or not.
    case final(Row)

    /// The exchange this message is about (a final row from a core that
    /// predates exchange ids has none).
    public var exchangeID: UUID? {
        switch self {
        case .started(let input): return input.exchangeID
        case .progress(let input): return input.exchangeID
        case .final(let row): return row.exchangeID
        }
    }
}

// MARK: - State

/// Counts complete events or lines of a live stream without keeping them —
/// what `wait_for_session(until: first_message)` and the list's marker need.
/// The parsers are S5's, so "complete" means exactly what the Events view and
/// the agent's `view=events` mean by it.
public struct LiveMessageCounter: Sendable, Equatable {
    public let format: StreamFormat
    private var sse = SSEParser()
    private var ndjson = NDJSONSplitter()
    public private(set) var completeMessages = 0

    public init(format: StreamFormat) {
        self.format = format
    }

    public mutating func feed(_ text: String) {
        switch format {
        case .sse: completeMessages += sse.feed(text).count
        case .ndjson: completeMessages += ndjson.feed(text).count
        }
    }

    /// Bytes at the end that are not a complete event or line yet.
    public var pendingBytes: Int {
        switch format {
        case .sse: return sse.pendingByteCount
        case .ndjson: return ndjson.pendingByteCount
        }
    }

    public static func == (lhs: LiveMessageCounter, rhs: LiveMessageCounter) -> Bool {
        lhs.format == rhs.format && lhs.completeMessages == rhs.completeMessages && lhs.pendingBytes == rhs.pendingBytes
    }
}

/// Everything the app knows about one in-flight row besides the row itself.
public struct LiveRowState: Equatable, Sendable {
    public var exchangeID: UUID
    /// The row's id in the table — the FIRST snapshot's, kept for every later
    /// snapshot and for the final row, so selection, the uid an agent holds
    /// and the free-tier tally all survive the replacement.
    public var rowID: UUID
    public var phase: LivePhase
    public var requestBytes: Int64
    public var responseBytes: Int64
    public var requestComplete: Bool
    public var textStatus: LiveTextState
    public var undecodedEncoding: String?
    /// UTF-8 bytes of response text the app holds (a prefix of the body).
    public var textBytes: Int64
    /// A message was missed (`textOffset` did not match): the text stops at
    /// `textBytes` until the final row carries the whole body.
    public var textIncomplete: Bool
    /// The stream shape, when the response is SSE or NDJSON.
    public var streamFormat: StreamFormat?
    /// Complete events or lines so far (0 for a non-stream).
    public var completeMessages: Int
    /// Bytes of an event or line not finished yet — withheld from agents.
    public var pendingBytes: Int
    /// The last `sequence` accepted (started is 0).
    public var lastSequence: Int
    /// APP clock (the ledger's `now`) of the last message heard.
    public var lastHeardAt: TimeInterval
    /// Extension clock of the response head, for event arrival offsets.
    public var responseHeadAt: TimeInterval?

    public init(exchangeID: UUID, rowID: UUID, phase: LivePhase, requestBytes: Int64 = 0, responseBytes: Int64 = 0,
                requestComplete: Bool = false, textStatus: LiveTextState = .awaitingResponse,
                undecodedEncoding: String? = nil, textBytes: Int64 = 0, textIncomplete: Bool = false,
                streamFormat: StreamFormat? = nil, completeMessages: Int = 0, pendingBytes: Int = 0,
                lastSequence: Int = 0, lastHeardAt: TimeInterval = 0, responseHeadAt: TimeInterval? = nil) {
        self.exchangeID = exchangeID
        self.rowID = rowID
        self.phase = phase
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.requestComplete = requestComplete
        self.textStatus = textStatus
        self.undecodedEncoding = undecodedEncoding
        self.textBytes = textBytes
        self.textIncomplete = textIncomplete
        self.streamFormat = streamFormat
        self.completeMessages = completeMessages
        self.pendingBytes = pendingBytes
        self.lastSequence = lastSequence
        self.lastHeardAt = lastHeardAt
        self.responseHeadAt = responseHeadAt
    }
}

// MARK: - Operations

/// What the table must do. Produced by `LiveRowLedger`, applied by
/// `LiveRowTable` (the rows) and by the app (the per-row live models).
public enum LiveRowOperation<Row: LiveTableRow> {
    /// A new in-flight row (at the top, like any arrival).
    case insertLive(Row, LiveRowState, [LiveTextChunk])
    /// An in-flight row changed. `row` is a new snapshot (the response head
    /// arrived) or nil when only the live facts changed — which touch no row
    /// in the table at all.
    case updateLive(row: Row?, state: LiveRowState, appended: [LiveTextChunk])
    /// The final row of an in-flight row, REPLACING it in place. Its `id`
    /// is already the live row's.
    case finalize(Row)
    /// A final row with no live row (every fast exchange, and every row from
    /// a core that predates live rows): inserted at the top, as always.
    case insertFinal(Row)
    /// `withdrawn`: the exchange ended without a row; the live row goes.
    case remove(rowID: UUID, exchangeID: UUID)
    /// The row stays, no longer in flight, marked as ended without its final.
    case end(rowID: UUID, exchangeID: UUID, reason: LiveEndReason)

    /// The row this operation is about.
    public var rowID: UUID {
        switch self {
        case .insertLive(let row, _, _): return row.id
        case .updateLive(_, let state, _): return state.rowID
        case .finalize(let row), .insertFinal(let row): return row.id
        case .remove(let rowID, _), .end(let rowID, _, _): return rowID
        }
    }

    /// Merges consecutive updates of one row (and an update into the insert
    /// just before it), so a flush that carried five progress messages for a
    /// stream costs one table pass and one model update. Text pieces are kept
    /// in order; the latest state and the latest snapshot win.
    public static func coalesced(_ operations: [LiveRowOperation<Row>]) -> [LiveRowOperation<Row>] {
        var out: [LiveRowOperation<Row>] = []
        var lastIndex: [UUID: Int] = [:]
        for operation in operations {
            if case .updateLive(let row, let state, let appended) = operation, let index = lastIndex[state.rowID] {
                switch out[index] {
                case .updateLive(let previousRow, _, let previousText):
                    out[index] = .updateLive(row: row ?? previousRow, state: state, appended: previousText + appended)
                    continue
                case .insertLive(let previousRow, _, let previousText):
                    out[index] = .insertLive(row ?? previousRow, state, previousText + appended)
                    continue
                default:
                    break
                }
            }
            lastIndex[operation.rowID] = out.count
            out.append(operation)
        }
        return out
    }
}

// MARK: - The ledger

/// A set of ids that forgets the oldest past `capacity` — the exchanges the
/// app has finished with, so a late or duplicate message for one is dropped.
public struct BoundedIDSet: Sendable, Equatable {
    public let capacity: Int
    private var members = Set<UUID>()
    private var order: [UUID] = []
    private var head = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { members.count }

    public func contains(_ id: UUID) -> Bool { members.contains(id) }

    public mutating func insert(_ id: UUID) {
        guard members.insert(id).inserted else { return }
        order.append(id)
        while members.count > capacity, head < order.count {
            members.remove(order[head])
            head += 1
        }
        // Compact the queue now and then rather than on every insert.
        if head > capacity {
            order.removeFirst(head)
            head = 0
        }
    }

    public mutating func removeAll() {
        members.removeAll()
        order.removeAll()
        head = 0
    }
}

/// Turns the extension's live messages into table operations, in order.
///
/// Rules (protocol PRD 4a.1, protocol-engine doc §S6):
/// - `started` inserts an in-flight row (or updates one already there);
/// - `progress` updates it; one for an exchange the ledger does not hold is
///   ignored; text is appended only when `textOffset` is exactly what the app
///   holds — otherwise the live text stops (`textIncomplete`) and the final
///   row brings the whole body;
/// - `withdrawn` removes the row;
/// - a final REPLACES the in-flight row (same id) — and an ENDED row too, if
///   it turns up late and the row is still in the table; a final for an
///   exchange the app already finished with — finalized, withdrawn, deleted
///   by the user, or evicted — is DROPPED, never re-inserted; a final with no
///   live row is inserted as always;
/// - a row not heard from for `staleAfter` is ended (`sweep`), and so is every
///   row when capture stops (`endAll`).
///
/// Not thread-safe; the app runs it on its ingest queue.
public struct LiveRowLedger<Row: LiveTableRow> {
    /// The core's in-flight idle limit (decision D6: 300 s of two-way silence
    /// while a response is pending or streaming) plus a margin for a message
    /// the bus held back. The extension closes such an exchange and sends its
    /// row, so an in-flight row older than this lost its end on the way.
    public static var inFlightIdleLimit: TimeInterval { 300 }
    public static var staleMargin: TimeInterval { 60 }
    public static var staleAfter: TimeInterval { inFlightIdleLimit + staleMargin }

    public private(set) var live: [UUID: LiveRowState] = [:]
    private var counters: [UUID: LiveMessageCounter] = [:]
    /// Exchanges the app has finished with.
    public private(set) var retired = BoundedIDSet(capacity: 20_000)
    /// Rows ended without their final (exchange → row id). A final that turns
    /// up late still REPLACES the ended row — it is the truth the ended row
    /// was standing in for — as long as the row is still in the table.
    private var endedRows: [UUID: UUID] = [:]
    private var endedOrder: [UUID] = []
    public static var maxEndedRowsRemembered: Int { 5_000 }

    public init() {}

    public var inFlightCount: Int { live.count }

    public func state(forExchange exchangeID: UUID) -> LiveRowState? { live[exchangeID] }

    public mutating func ingest(_ message: LiveIngestMessage<Row>, now: TimeInterval) -> [LiveRowOperation<Row>] {
        switch message {
        case .started(let started): return ingest(started, now: now)
        case .progress(let progress): return ingest(progress, now: now)
        case .final(let row): return ingest(final: row)
        }
    }

    private mutating func ingest(_ started: LiveStartInput<Row>, now: TimeInterval) -> [LiveRowOperation<Row>] {
        let exchange = started.exchangeID
        guard !retired.contains(exchange) else { return [] }
        if var state = live[exchange] {
            // A second started (the contract says once, but it is harmless):
            // an update with its snapshot.
            var row = started.row
            row.id = state.rowID
            state.phase = started.phase
            state.requestBytes = started.requestBytes
            state.responseBytes = started.responseBytes
            state.requestComplete = started.requestComplete
            state.textStatus = started.textStatus
            state.undecodedEncoding = started.undecodedEncoding
            state.lastHeardAt = now
            state.responseHeadAt = started.responseHeadAt ?? state.responseHeadAt
            attachCounterIfStream(&state, contentType: started.contentType)
            live[exchange] = state
            return [.updateLive(row: row, state: state, appended: [])]
        }
        var state = LiveRowState(
            exchangeID: exchange,
            rowID: started.row.id,
            phase: started.phase,
            requestBytes: started.requestBytes,
            responseBytes: started.responseBytes,
            requestComplete: started.requestComplete,
            textStatus: started.textStatus,
            undecodedEncoding: started.undecodedEncoding,
            lastSequence: 0,
            lastHeardAt: now,
            responseHeadAt: started.responseHeadAt
        )
        attachCounterIfStream(&state, contentType: started.contentType)
        live[exchange] = state
        return [.insertLive(started.row, state, [])]
    }

    private mutating func ingest(_ progress: LiveProgressInput<Row>, now: TimeInterval) -> [LiveRowOperation<Row>] {
        let exchange = progress.exchangeID
        guard var state = live[exchange] else {
            // Unknown (never started, or already finished with): ignored.
            return []
        }
        guard let phase = progress.phase else {
            live[exchange] = nil
            counters[exchange] = nil
            retired.insert(exchange)
            return [.remove(rowID: state.rowID, exchangeID: exchange)]
        }
        // Out of order or repeated: the ordering guarantee says this cannot
        // happen, so a message that looks like it is stale, never newer.
        guard progress.sequence > state.lastSequence else { return [] }
        state.lastSequence = progress.sequence
        state.lastHeardAt = now
        state.phase = phase
        state.requestBytes = progress.requestBytes
        state.responseBytes = progress.responseBytes
        state.requestComplete = progress.requestComplete
        state.textStatus = progress.textStatus
        state.undecodedEncoding = progress.undecodedEncoding
        state.responseHeadAt = progress.responseHeadAt ?? state.responseHeadAt

        var snapshot = progress.row
        if snapshot != nil {
            snapshot!.id = state.rowID
            attachCounterIfStream(&state, contentType: progress.contentType)
        }

        var appended: [LiveTextChunk] = []
        if let text = progress.appendedText, !text.isEmpty, !state.textIncomplete {
            let length = Int64(text.utf8.count)
            if progress.textOffset == state.textBytes {
                state.textBytes += length
                let at: TimeInterval? = state.responseHeadAt.map { max(0, progress.sentAt - $0) }
                appended.append(LiveTextChunk(text: text, receivedAt: at))
                if var counter = counters[exchange] {
                    counter.feed(text)
                    counters[exchange] = counter
                    state.completeMessages = counter.completeMessages
                    state.pendingBytes = counter.pendingBytes
                }
            } else if progress.textOffset + length <= state.textBytes {
                // Already held (a repeat): nothing new.
            } else {
                // A message was lost: what the app holds is still a prefix,
                // and appending this would put a hole in it.
                state.textIncomplete = true
            }
        }
        live[exchange] = state
        return [.updateLive(row: snapshot, state: state, appended: appended)]
    }

    private mutating func ingest(final row: Row) -> [LiveRowOperation<Row>] {
        guard let exchange = row.exchangeID else {
            // A core that predates exchange ids: every row is final and new.
            return [.insertFinal(row)]
        }
        guard !retired.contains(exchange) else { return [] }
        retired.insert(exchange)
        if let state = live.removeValue(forKey: exchange) {
            counters[exchange] = nil
            var final = row
            final.id = state.rowID
            return [.finalize(final)]
        }
        if let rowID = endedRows.removeValue(forKey: exchange) {
            var final = row
            final.id = rowID
            return [.finalize(final)]
        }
        return [.insertFinal(row)]
    }

    /// Ends every in-flight row not heard from for `staleAfter`.
    public mutating func sweep(now: TimeInterval) -> [LiveRowOperation<Row>] {
        let stale = live.values.filter { now - $0.lastHeardAt > Self.staleAfter }
        return stale.sorted { $0.lastHeardAt < $1.lastHeardAt }.map { end($0, reason: .stale) }
    }

    /// Ends ONE in-flight row; nothing when it is not live.
    public mutating func end(exchangeID: UUID, reason: LiveEndReason) -> [LiveRowOperation<Row>] {
        guard let state = live[exchangeID] else { return [] }
        return [end(state, reason: reason)]
    }

    /// Ends every in-flight row (capture stopped).
    public mutating func endAll(reason: LiveEndReason = .captureStopped) -> [LiveRowOperation<Row>] {
        live.values.sorted { $0.lastHeardAt < $1.lastHeardAt }.map { end($0, reason: reason) }
    }

    private mutating func end(_ state: LiveRowState, reason: LiveEndReason) -> LiveRowOperation<Row> {
        live[state.exchangeID] = nil
        counters[state.exchangeID] = nil
        // Not retired: progress for it is ignored from now on (it is not
        // live), but a late final may still replace the row.
        endedRows[state.exchangeID] = state.rowID
        endedOrder.append(state.exchangeID)
        if endedOrder.count > Self.maxEndedRowsRemembered {
            let forgotten = endedOrder.removeFirst()
            if endedRows.removeValue(forKey: forgotten) != nil { retired.insert(forgotten) }
        }
        return .end(rowID: state.rowID, exchangeID: state.exchangeID, reason: reason)
    }

    /// The user deleted or cleared these exchanges' rows: whatever arrives for
    /// them later is dropped. Returns the rows that were still in flight.
    @discardableResult
    public mutating func forget(exchangeIDs: [UUID]) -> [UUID] {
        var wereLive: [UUID] = []
        for exchange in exchangeIDs {
            if let state = live.removeValue(forKey: exchange) {
                counters[exchange] = nil
                wereLive.append(state.rowID)
            }
            endedRows[exchange] = nil
            retired.insert(exchange)
        }
        return wereLive
    }

    /// Every exchange the ledger still tracks (live or ended), for a clear.
    public var trackedExchangeIDs: [UUID] { Array(live.keys) + Array(endedRows.keys) }

    private mutating func attachCounterIfStream(_ state: inout LiveRowState, contentType: String?) {
        guard counters[state.exchangeID] == nil, state.textBytes == 0,
              let format = StreamFormat.detect(contentType: contentType) else { return }
        counters[state.exchangeID] = LiveMessageCounter(format: format)
        state.streamFormat = format
    }
}

// MARK: - Text identity

/// A running digest of text read in pieces (64-bit FNV-1a over its UTF-8
/// bytes): equal to the digest of the same text read whole, whatever the
/// piece boundaries. The Events tab uses it to decide whether the live text
/// it parsed IS the final body — equal length is not enough (a charset or
/// replacement-character difference can keep the byte count), and holding a
/// second copy of up to 16 MB just to compare it is not worth it.
public struct LiveTextDigest: Equatable, Sendable {
    public private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    public private(set) var byteCount = 0

    public init() {}

    public init(_ text: String) {
        append(text)
    }

    public mutating func append(_ text: String) {
        var hash = value
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        value = hash
        byteCount += text.utf8.count
    }
}

// MARK: - The table

/// Applies operations to a newest-first array of rows — the rules that keep a
/// live row where it is and never let the cap take it.
public enum LiveRowTable {
    public struct Report<Row: LiveTableRow> {
        /// New rows, newest first, as they now stand (a live row finalized in
        /// the same batch is here as its final).
        public var inserted: [Row] = []
        /// Rows already in the table replaced in place (a final, or a live
        /// snapshot with the response head).
        public var replaced: [(old: Row, new: Row)] = []
        /// Withdrawn rows that were in the table.
        public var removed: [Row] = []
        /// Completed rows the cap took.
        public var evicted: [Row] = []
        /// In-flight rows that ended without a final.
        public var ended: [(rowID: UUID, reason: LiveEndReason)] = []
        /// Operations whose row is no longer in the table (the user deleted
        /// it): nothing happened.
        public var dropped = 0
        /// For each row this batch ENDED, the last live state the batch
        /// itself carried for it (nil when the batch carried none — the
        /// caller's live model holds it). A row announced and ended in ONE
        /// flush (capture stopped within ~150 ms of `session_started`) never
        /// had a live model made for it, and without this its ended state was
        /// lost: it looked like an ordinary finished row, and an agent's
        /// `wait_for_session` resolved on it as a completed request.
        public var endedStates: [UUID: LiveRowState] = [:]

        public init() {}

        /// Whether the ROWS changed — anything inserted, replaced, removed,
        /// evicted or ended. A flush that carried only progress without a new
        /// snapshot changes none: the caller updates the live models and must
        /// not republish, re-filter and re-diff a 5,000-row table for it
        /// (that was up to ~6.7 full republishes a second per live stream).
        public var changesRows: Bool {
            !inserted.isEmpty || !replaced.isEmpty || !removed.isEmpty || !evicted.isEmpty || !ended.isEmpty
        }
    }

    /// - Parameters:
    ///   - rows: newest first.
    ///   - inFlight: ids of the rows still in flight; kept in step.
    ///   - cap: the retention cap. Only COMPLETED rows are evicted, oldest
    ///     first; in-flight rows may take the table over the cap.
    public static func apply<Row: LiveTableRow>(
        _ operations: [LiveRowOperation<Row>],
        to rows: inout [Row],
        inFlight: inout Set<UUID>,
        cap: Int
    ) -> Report<Row> {
        var report = Report<Row>()
        // New rows in arrival order; one `insert(contentsOf:)` at the end.
        var fresh: [Row] = []
        var freshIndex: [UUID: Int] = [:]
        var removedFresh = Set<UUID>()

        func replace(_ id: UUID, with row: Row) -> Bool {
            if let index = freshIndex[id], !removedFresh.contains(id) {
                fresh[index] = row
                return true
            }
            if let index = rows.firstIndex(where: { $0.id == id }) {
                report.replaced.append((old: rows[index], new: row))
                rows[index] = row
                return true
            }
            return false
        }

        // The last live state each row's operations carried in this batch.
        var lastState: [UUID: LiveRowState] = [:]

        for operation in operations {
            switch operation {
            case .insertLive(let row, let state, _):
                freshIndex[row.id] = fresh.count
                fresh.append(row)
                inFlight.insert(row.id)
                lastState[row.id] = state
            case .insertFinal(let row):
                freshIndex[row.id] = fresh.count
                fresh.append(row)
            case .updateLive(let row, let state, _):
                lastState[state.rowID] = state
                guard let row else { continue }
                if !replace(state.rowID, with: row) { report.dropped += 1 }
            case .finalize(let row):
                if replace(row.id, with: row) {
                    inFlight.remove(row.id)
                } else {
                    // Deleted by the user while it was in flight: the final
                    // is dropped, not re-inserted.
                    inFlight.remove(row.id)
                    report.dropped += 1
                }
            case .remove(let rowID, _):
                inFlight.remove(rowID)
                if freshIndex[rowID] != nil, !removedFresh.contains(rowID) {
                    removedFresh.insert(rowID)
                } else if let index = rows.firstIndex(where: { $0.id == rowID }) {
                    report.removed.append(rows.remove(at: index))
                } else {
                    report.dropped += 1
                }
            case .end(let rowID, _, let reason):
                if inFlight.remove(rowID) != nil {
                    report.ended.append((rowID: rowID, reason: reason))
                    if let state = lastState[rowID] { report.endedStates[rowID] = state }
                } else {
                    report.dropped += 1
                }
            }
        }

        let newestFirst = fresh.reversed().filter { !removedFresh.contains($0.id) }
        report.inserted = newestFirst
        if !newestFirst.isEmpty {
            rows.insert(contentsOf: newestFirst, at: 0)
        }
        report.evicted = evict(&rows, inFlight: inFlight, cap: cap)
        return report
    }

    /// Drops the oldest COMPLETED rows until `rows` fits `cap`, stepping over
    /// in-flight ones. O(dropped + in-flight rows met on the way).
    public static func evict<Row: LiveTableRow>(_ rows: inout [Row], inFlight: Set<UUID>, cap: Int) -> [Row] {
        var overflow = rows.count - max(0, cap)
        guard overflow > 0 else { return [] }
        var evicted: [Row] = []
        var keptTail: [Row] = []
        while overflow > 0, let last = rows.popLast() {
            if inFlight.contains(last.id) {
                keptTail.append(last)
            } else {
                evicted.append(last)
                overflow -= 1
            }
        }
        rows.append(contentsOf: keptTail.reversed())
        return evicted
    }

    /// What `mirror` did to a list: rows that came into it and rows that
    /// left it (a replacement is one of each), so the caller can keep
    /// per-list counts in O(changes).
    public struct MirrorResult<Row: LiveTableRow> {
        public var entered: [Row] = []
        public var left: [Row] = []
    }

    /// Mirrors a report onto a second list that holds a subset of the rows
    /// (the app's per-host lists): new rows that `belongs` are inserted at the
    /// top, replacements and removals follow the row, then the list's own cap
    /// (which never takes an in-flight row either).
    @discardableResult
    public static func mirror<Row: LiveTableRow>(
        _ report: Report<Row>,
        into list: inout [Row],
        belongs: (Row) -> Bool,
        inFlight: Set<UUID>,
        cap: Int
    ) -> MirrorResult<Row> {
        var result = MirrorResult<Row>()
        var arrivals = report.inserted.filter(belongs)
        for (old, new) in report.replaced {
            let index = list.firstIndex(where: { $0.id == old.id })
            switch (index, belongs(new)) {
            case (let index?, true):
                result.left.append(list[index])
                list[index] = new
                result.entered.append(new)
            case (let index?, false):
                result.left.append(list.remove(at: index))
            case (nil, true):
                arrivals.append(new)
            case (nil, false):
                break
            }
        }
        for row in report.removed {
            if let index = list.firstIndex(where: { $0.id == row.id }) { result.left.append(list.remove(at: index)) }
        }
        if !arrivals.isEmpty {
            list.insert(contentsOf: arrivals, at: 0)
            result.entered.append(contentsOf: arrivals)
        }
        result.left.append(contentsOf: evict(&list, inFlight: inFlight, cap: cap))
        return result
    }
}

// MARK: - Keeping a row (release review, 2026-09-29)

/// Which rows may be SAVED or turned into a MOCK. A live row — still in
/// flight, or ended without its final row (capture stopped, the stale sweep)
/// — is the core's LiveSessionStarted snapshot: the request body as far as it
/// had arrived and no response. Kept, it would read as a finished exchange,
/// and a saved row has no live state left to withhold its bodies by.
/// One predicate for every surface: the agent's save_session and
/// mock_from_session, and the window's Save on a multi-row selection.
public enum LiveRowKeeping {
    /// `rows` without the live ones, order kept.
    public static func finished<Row>(_ rows: [Row], isLive: (Row) -> Bool) -> [Row] {
        rows.filter { !isLive($0) }
    }

    /// Why `uid` cannot be kept for `purpose` ("save it", "mock it"), or nil
    /// when it is an ordinary finished row.
    public static func refusal(uid: String, live: MCPLiveState?, purpose: String) -> String? {
        guard let live else { return nil }
        if live.isInFlight {
            return "Session \(uid) is still in flight; \(purpose) once it finishes (wait_for_session with until=complete, or list_sessions again)."
        }
        let why: String
        switch live.endReason {
        case .captureStopped: why = "capture stopped while it was open"
        case .stale: why = "nothing was heard from it for too long"
        case nil: why = "it ended early"
        }
        return "Session \(uid) never finished (\(why)), so ReqRes holds only part of it; it cannot be kept as if it were a whole exchange."
    }
}
