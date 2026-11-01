//
//  LiveRowModel.swift
//  ReqRes
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
//  Live rows, the app's half (protocol-engine doc §S6): the core's
//  `session_started` / `session_progress` read into MCPKit's pure inputs, and
//  the one object per in-flight row that its table cell and the detail pane
//  observe — so a progress message re-renders one cell and appends to one
//  text view, never the whole traffic table.
//

import Combine
import Foundation
import MCPKit
import XReqResCore

/// `SessionCodable` already has what a live table needs.
extension SessionCodable: LiveTableRow {}

extension LiveStartInput where Row == SessionCodable {
    init(_ message: LiveSessionStarted) {
        let session = message.session
        self.init(
            exchangeID: message.exchangeID,
            phase: LivePhase(core: message.phase) ?? .waiting,
            row: session,
            requestBytes: message.requestBytes,
            responseBytes: message.responseBytes,
            requestComplete: message.requestComplete,
            textStatus: LiveTextState(raw: message.textStatus.rawValue),
            undecodedEncoding: message.undecodedEncoding,
            contentType: session.rspContentType.isEmpty ? nil : session.rspContentType,
            responseHeadAt: session.responseHeadTime
        )
    }
}

extension LiveProgressInput where Row == SessionCodable {
    init(_ message: LiveSessionProgress) {
        self.init(
            exchangeID: message.exchangeID,
            sequence: message.sequence,
            phase: LivePhase(core: message.phase),
            requestBytes: message.requestBytes,
            responseBytes: message.responseBytes,
            requestComplete: message.requestComplete,
            appendedText: message.appendedText,
            textOffset: message.textOffset,
            textStatus: LiveTextState(raw: message.textStatus.rawValue),
            undecodedEncoding: message.undecodedEncoding,
            row: message.session,
            contentType: message.session.flatMap { $0.rspContentType.isEmpty ? nil : $0.rspContentType },
            responseHeadAt: message.session?.responseHeadTime,
            sentAt: message.sentAt
        )
    }
}

extension LivePhase {
    /// nil for `withdrawn` (the row goes). An unknown phase from a later
    /// core has already been decoded by the core as `streaming`.
    init?(core: LiveExchangePhase) {
        switch core {
        case .waiting: self = .waiting
        case .streaming: self = .streaming
        case .withdrawn: return nil
        @unknown default: self = .streaming
        }
    }
}

extension SessionCodable {
    /// Extension wall clock of the response head, or nil before it.
    var responseHeadTime: TimeInterval? {
        let head = rspStartTime.doubleValue
        return head > 0 ? head : nil
    }
}

/// One in-flight row: what its table cell and the detail pane observe.
///
/// `state` is the only published value — it changes at most once per
/// 150 ms flush — so the cell re-renders on a phase or byte change and
/// nothing else does. Text is NOT published: it is handed to whoever is
/// showing it through `textAppended`, so a growing stream appends to one
/// text view instead of rebuilding anything.
final class LiveRowModel: ObservableObject {
    let rowID: UUID
    @Published private(set) var state: LiveRowState
    /// The response text so far, as it arrived.
    private(set) var chunks: [LiveTextChunk] = []
    private(set) var textByteCount = 0
    let textAppended = PassthroughSubject<[LiveTextChunk], Never>()

    init(state: LiveRowState, chunks: [LiveTextChunk] = []) {
        self.rowID = state.rowID
        self.state = state
        append(chunks)
    }

    var phase: MCPLivePhase { state.phase == .waiting ? .waiting : .streaming }

    var text: String { chunks.map(\.text).joined() }

    func update(_ newState: LiveRowState, appended: [LiveTextChunk]) {
        if newState != state { state = newState }
        append(appended)
    }

    private func append(_ pieces: [LiveTextChunk]) {
        guard !pieces.isEmpty else { return }
        chunks.append(contentsOf: pieces)
        textByteCount += pieces.reduce(0) { $0 + $1.text.utf8.count }
        textAppended.send(pieces)
    }
}

/// A row that stopped being live without its final row: the last facts heard.
struct LiveEndedRow: Equatable {
    var reason: LiveEndReason
    var lastState: LiveRowState
}

extension SessionCodable {
    /// Changes when a row's CONTENT changes under the same id — a live row
    /// gaining its response head, its final replacing it — so the detail
    /// pane's `Equatable` tab views (which skip re-rendering on a new capture
    /// elsewhere) still redraw for their own row. Cheap: counts, not text.
    var detailRevision: Int {
        var hasher = Hasher()
        hasher.combine(rspStatus)
        hasher.combine(rspStartTime.doubleValue)
        hasher.combine(rspEndTime.doubleValue)
        hasher.combine(rspHeaders?.utf8.count ?? -1)
        hasher.combine(rspBody.utf8.count)
        hasher.combine(rspBodyData?.count ?? -1)
        hasher.combine(reqBody.utf8.count)
        hasher.combine(reqHeaders.utf8.count)
        hasher.combine(outcome.rawValue)
        // Native gRPC's status is read from the trailers (doc §S9.6), and
        // `RPCStatusCache` keys on this revision — so trailers count too.
        hasher.combine(reqTrailers?.utf8.count ?? -1)
        hasher.combine(rspTrailers?.utf8.count ?? -1)
        return hasher.finalize()
    }
}
