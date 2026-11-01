//
//  WebSocketMessagesView.swift
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
//  The Messages tab of a WebSocket row (protocol PRD Phase 4b; protocol-engine
//  doc §S7): one line per message — direction as symbol AND word, +ms after
//  the upgrade, opcode, size, a one-line preview — the selected message whole
//  below it (JSON pretty-printed, text as text, binary as a hex dump), a line
//  wherever messages were not kept, and how the connection closed. It grows
//  while the socket is open: `WebSocketConversationModel` pulls the log when
//  the message center says this connection changed (≤ 1 per 150 ms), and
//  nothing else re-renders — the traffic table never hears of a message.
//
//  Opening this tab spends NO free-tier inspection (decision D14): the row's
//  detail already spent its one when it was first shown (by row id, like any
//  HTTPS row), and watching its messages arrive — for as long as the socket
//  stays open — spends nothing more.
//
//  Every word is `SocketMessagePresentation`'s (MCPKit, tested).
//

import AppKit
import MCPKit
import SwiftUI
import XReqResCore

extension SessionCodable {
    /// A `101` that names `websocket` in its response's `Upgrade`: the rows
    /// the core reads messages on. The header parse is an autoclosure in
    /// MCPKit, so only a `101` pays for it — every row's protocol
    /// classification calls this (doc §S9.2).
    var isWebSocketUpgrade: Bool {
        SocketMessagePresentation.isWebSocketUpgrade(status: rspStatus, responseHeaders: MCPRecordedHeaders.dictionary(from: rspHeaders))
    }

    /// When the `101` arrived — the zero of every message's `+ms`.
    var webSocketUpgradeTime: Double? {
        let head = rspStartTime.doubleValue
        if head > 0 { return head }
        let end = rspEndTime.doubleValue
        return end > 0 ? end : nil
    }
}

struct WebSocketMessagesView: View {
    let session: SessionCodable

    @StateObject private var model: WebSocketConversationModel
    @State private var selection: String?
    @State private var query = ""

    /// `initialSelection` / `initialQuery`: the render probe's (an item id
    /// such as "m3", and a search); people start with neither.
    init(session: SessionCodable, initialSelection: String? = nil, initialQuery: String = "") {
        self.session = session
        _model = StateObject(wrappedValue: WebSocketConversationModel(exchangeID: session.exchangeID, query: initialQuery))
        _selection = State(initialValue: initialSelection)
        _query = State(initialValue: initialQuery)
    }

    private var upgrade: Double? { session.webSocketUpgradeTime }

    private var selectedMessage: StoredSocketMessage? {
        guard let selection else { return nil }
        // Only a message the list shows: a search that hides the selected
        // one hides its detail too, rather than showing a message that is
        // not on screen.
        for item in model.shownItems {
            if case .message(let stored) = item, item.id == selection { return stored }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .onChange(of: query) { _, newValue in model.setQuery(newValue) }
            Divider()
            VSplitView {
                list
                    .frame(minHeight: 120, idealHeight: 260)
                detail
                    .frame(minHeight: 90, idealHeight: 180)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: model.log?.isFinal == true ? "bubble.left.and.bubble.right" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(SocketMessagePresentation.summary(model.log))
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            // VoiceOver: the phase (open / closed) is the value and changes
            // once; the ticking counts are read on focus, never announced.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("WebSocket messages")
            .accessibilityValue(model.log?.isFinal == true ? "Closed" : "Open")
            .accessibilityHint(SocketMessagePresentation.summary(model.log))

            if let log = model.log {
                ForEach(Array(log.gaveUp.enumerated()), id: \.offset) { _, issue in
                    Label(SocketMessagePresentation.gaveUpLine(issue), systemImage: "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = SocketMessagePresentation.retentionLine(log) {
                    Label(line, systemImage: "scissors")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search messages", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityLabel("Search messages")
                if !query.isEmpty {
                    Text("\(model.shownItems.count) of \(model.log?.retainedCount ?? 0)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(model.shownItems) { item in
                    switch item {
                    case .message(let stored):
                        WebSocketMessageRow(message: stored.message, upgrade: upgrade)
                            .equatable()
                            .tag(item.id)
                    case .gap(let count, _):
                        Label(SocketMessagePresentation.gapLine(count), systemImage: "ellipsis")
                            .font(.system(size: 11).italic())
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }
                if let close = model.log?.close, query.isEmpty {
                    Label(SocketMessagePresentation.closeLine(close), systemImage: "xmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectionDisabled()
                        .id("close")
                }
                if model.items.isEmpty {
                    Text(model.log?.isFinal == true ? "No messages were sent on this connection." : "Messages appear here as they are sent.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 20)
            // Follows the end while nothing is selected and nothing searched:
            // a person reading an older message is not dragged away from it.
            .onChange(of: model.revision) { _, _ in
                guard selection == nil, query.isEmpty, let last = model.items.last else { return }
                proxy.scrollTo(model.log?.close != nil ? "close" : last.id, anchor: .bottom)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let stored = selectedMessage {
            // Equatable on the message: a batch arriving while one is
            // selected re-renders the list, not this (a 64 KB binary preview
            // is a ~320 KB hex dump, built once per selection).
            WebSocketMessageDetail(message: stored.message, upgrade: upgrade)
                .equatable()
        } else {
            Text("Select a message to see it whole.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The selected message, whole.
struct WebSocketMessageDetail: View, Equatable {
    let message: SocketMessage
    let upgrade: Double?

    var body: some View {
        let whole = SocketMessagePresentation.body(message)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: SocketMessagePresentation.directionSymbol(message.direction))
                        .accessibilityHidden(true)
                    Text(SocketMessagePresentation.detailFacts(message))
                    if let offset = SocketMessagePresentation.offset(message.time, from: upgrade) {
                        Text(offset).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                if let note = SocketMessagePresentation.truncatedNote(message) {
                    Label(note, systemImage: "scissors")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(whole.text)
                    .font(.system(size: 12, design: whole.kind == .text ? .default : .monospaced))
                    .foregroundStyle(whole.kind == .empty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
    }
}

/// One message's line. Equatable on the message: a new batch appends rows
/// and re-renders none of the existing ones.
struct WebSocketMessageRow: View, Equatable {
    let message: SocketMessage
    let upgrade: Double?

    var body: some View {
        HStack(spacing: 8) {
            // Direction: symbol AND word — never colour alone.
            HStack(spacing: 3) {
                Image(systemName: SocketMessagePresentation.directionSymbol(message.direction))
                    .foregroundStyle(message.direction.isSent ? Color.accentColor : Color.green)
                    .font(.system(size: 10, weight: .bold))
                Text(SocketMessagePresentation.directionWord(message.direction))
            }
            .frame(width: 74, alignment: .leading)
            Text(SocketMessagePresentation.offset(message.time, from: upgrade) ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            Text(SocketMessagePresentation.opcodeWord(message.opcode))
                .foregroundStyle(message.opcode.isControl ? .secondary : .primary)
                .frame(width: 44, alignment: .leading)
            Text(SocketMessagePresentation.size(message.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text(SocketMessagePresentation.oneLine(message))
                .font(.system(size: 11, design: message.previewText == nil || message.opcode == .close ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SocketMessagePresentation.accessibilityLabel(message, upgrade: upgrade))
        .accessibilityValue(SocketMessagePresentation.oneLine(message))
    }
}
