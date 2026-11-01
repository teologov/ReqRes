//
//  StreamEventsView.swift
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
//  The response's Events tab (protocol PRD 2.4; protocol-engine doc §S5): a
//  streamed response (SSE or NDJSON) as numbered events, with a summary line
//  and — for an Anthropic or OpenAI stream — the answer put back together.
//
//  Built for the live transport that comes next: `StreamEventsModel` owns an
//  incremental `StreamEventLog`, `append` publishes only the rows it
//  completed, and each row is identified by its position, so a growing
//  stream appends rows without re-rendering the ones above or touching the
//  traffic table. Every word comes from `StreamEventsPresentation` (MCPKit).
//

import MCPKit
import SwiftUI
import XReqResCore

extension SessionCodable {
    /// The response is a stream the Events tab reads, and has a body to read.
    var responseStreamFormat: StreamFormat? {
        guard !relayed, !rspBody.isEmpty else { return nil }
        return StreamFormat.detect(contentType: rspContentType)
    }
}

extension NetworkInspectorTabResponse {
    /// The response tabs for this session: Events only for a stream — a
    /// finished one with a body, or one still arriving (a live row whose
    /// response head named SSE or NDJSON).
    ///
    /// Messages only for a WebSocket (a `101` naming websocket), and only
    /// where the messages exist: the current capture run. A saved session
    /// keeps the handshake, not its messages (`messages: false`).
    static func tabs(for session: SessionCodable, live: LiveRowModel? = nil, messages: Bool = true) -> [NetworkInspectorTabResponse] {
        let isStream = session.responseStreamFormat != nil || live?.state.streamFormat != nil
        let isWebSocket = messages && session.isWebSocketUpgrade
        // RPC for a finished row that reads as gRPC-Web / Connect / gRPC
        // (protocol-engine doc §S8): a live row's bodies are snapshots.
        let isRPC = live == nil && session.isRPC
        return allCases.filter { tab in
            switch tab {
            case .events: return isStream
            case .messages: return isWebSocket
            case .rpc: return isRPC
            default: return true
            }
        }
    }

    /// The tabs a pane with no session to ask shows.
    static var standardTabs: [NetworkInspectorTabResponse] { allCases.filter { $0 != .events && $0 != .messages && $0 != .rpc } }
}

/// One stream's parsed events, for one detail pane.
@MainActor
final class StreamEventsModel: ObservableObject {
    struct Snapshot {
        var format: StreamFormat
        var summary: String
        var assemblyLine: String?
        var pendingLine: String?
        var isTimed: Bool
        var assembly: LLMStreamAssembly
    }

    @Published private(set) var events: [StreamEvent] = []
    @Published private(set) var snapshot: Snapshot?

    private var log: StreamEventLog?
    private var assembler = LLMStreamAssembler()
    private var responseDurationMs: Double?
    private var loadedID: UUID?
    /// The live row being followed, and a digest of its text read so far —
    /// which decides whether its final row can keep the events (and their
    /// arrival times) or must be parsed again from the whole body: the text
    /// must BE the body, not merely as long.
    private var liveRowID: UUID?
    private var liveText = LiveTextDigest()
    private var liveTextIncomplete = false
    private(set) var isLive = false

    /// Starts following a live row: the text that arrived before the pane
    /// opened, then (through `appendLive`) each piece as it comes. Events are
    /// stamped with the time of the piece that completed them.
    func startLive(rowID: UUID, format: StreamFormat, chunks: [LiveTextChunk], textIncomplete: Bool) {
        guard liveRowID != rowID else { return }
        liveRowID = rowID
        loadedID = nil
        isLive = true
        events = []
        snapshot = nil
        assembler = LLMStreamAssembler()
        responseDurationMs = nil
        log = StreamEventLog(format: format)
        liveText = LiveTextDigest()
        liveTextIncomplete = textIncomplete
        feed(chunks, format: format)
    }

    func appendLive(_ chunks: [LiveTextChunk], format: StreamFormat, textIncomplete: Bool) {
        liveTextIncomplete = textIncomplete
        feed(chunks, format: format)
    }

    /// Every chunk parsed first, then ONE publish: the events appended once
    /// and the snapshot built once. Publishing per chunk rebuilt the
    /// snapshot — and copied the whole event list and the assembled text —
    /// for every piece, so opening a stream that had been running for a
    /// while replayed quadratically on main (release review, 2026-09-29:
    /// 263 ms at 1 MB, 24 s at the 16 MB cap).
    private func feed(_ chunks: [LiveTextChunk], format: StreamFormat) {
        var new: [StreamEvent] = []
        for chunk in chunks { new += parse(text: chunk.text, receivedAt: chunk.receivedAt, format: format) }
        if !new.isEmpty { events.append(contentsOf: new) }
        refreshSnapshot()
    }

    /// Parses a finished row off the main thread (a body can be 16 MB).
    ///
    /// A row this model followed live keeps its events — and their arrival
    /// times — when the text it read is exactly the final body; otherwise
    /// (a missed update, a body the live text stopped short of) it is parsed
    /// again from the final body, which is the whole truth.
    func load(_ session: SessionCodable) async {
        if liveRowID == session.id, var current = log, !liveTextIncomplete,
           liveText.byteCount == session.rspBody.utf8.count, liveText == LiveTextDigest(session.rspBody),
           session.responseStreamFormat == current.format {
            current.finish()
            log = current
            liveRowID = nil
            isLive = false
            loadedID = session.id
            let head = session.rspStartTime.doubleValue
            let end = session.rspEndTime.doubleValue
            responseDurationMs = head > 0 && end >= head ? (end - head) * 1000 : nil
            refreshSnapshot()
            return
        }
        liveRowID = nil
        isLive = false
        guard loadedID != session.id, let format = session.responseStreamFormat else { return }
        loadedID = session.id
        // Another session in the same pane: never show the previous one's
        // rows while this one parses.
        events = []
        snapshot = nil
        log = nil
        assembler = LLMStreamAssembler()
        let body = session.rspBody
        let head = session.rspStartTime.doubleValue
        let end = session.rspEndTime.doubleValue
        responseDurationMs = head > 0 && end >= head ? (end - head) * 1000 : nil
        let parsed = await Task.detached(priority: .userInitiated) { () -> (StreamEventLog, LLMStreamAssembler) in
            let log = StreamEventLog.parse(body: body, format: format)
            var assembler = LLMStreamAssembler()
            log.events.forEach { assembler.consume($0) }
            return (log, assembler)
        }.value
        guard loadedID == session.id else { return }
        log = parsed.0
        assembler = parsed.1
        events = parsed.0.events
        refreshSnapshot()
    }

    /// The live transport's entry point (next step): the next piece of the
    /// body and when it arrived, in seconds after the response head. Only the
    /// events it completed are published as new rows.
    func append(text: String, receivedAt: TimeInterval?, format: StreamFormat) {
        let new = parse(text: text, receivedAt: receivedAt, format: format)
        guard !new.isEmpty else { return }
        events.append(contentsOf: new)
        refreshSnapshot()
    }

    /// Feeds the log IN PLACE (a `var` copy of it would copy every event on
    /// the next append) and the assembler; returns the events completed.
    private func parse(text: String, receivedAt: TimeInterval?, format: StreamFormat) -> [StreamEvent] {
        if log == nil { log = StreamEventLog(format: format) }
        guard log != nil else { return [] }
        liveText.append(text)
        let added = log!.append(text: text, receivedAt: receivedAt)
        guard !added.isEmpty else { return [] }
        let new = Array(log!.events[added])
        new.forEach { assembler.consume($0) }
        return new
    }

    private func refreshSnapshot() {
        guard let log else { return }
        let assembly = assembler.assembly
        snapshot = Snapshot(
            format: log.format,
            summary: StreamEventsPresentation.summary(log: log, assembly: assembly, responseDurationMs: responseDurationMs),
            assemblyLine: StreamEventsPresentation.assemblyLine(assembly, inFlight: isLive),
            pendingLine: StreamEventsPresentation.pendingLine(log),
            isTimed: log.timing.timedEvents > 0,
            assembly: assembly
        )
    }
}

struct StreamEventsView: View {
    let session: SessionCodable
    /// Probes open the assembled answer; people choose.
    var assembledInitiallyExpanded = false
    /// Set while the row is in flight: its events are appended as they
    /// complete (protocol-engine doc §S6).
    var live: LiveRowModel? = nil

    @StateObject private var model = StreamEventsModel()
    @State private var assembledExpanded: Bool?

    private struct TaskKey: Equatable {
        let id: UUID
        let isLive: Bool
    }

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                content(snapshot)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Reading the stream's events")
            }
        }
        .task(id: TaskKey(id: session.id, isLive: live != nil)) {
            if let live, let format = live.state.streamFormat {
                model.startLive(rowID: live.rowID, format: format, chunks: live.chunks, textIncomplete: live.state.textIncomplete)
                // Buffered: `.values` asks for one element at a time, and a
                // PassthroughSubject drops whatever is sent while no demand
                // is outstanding — two flushes landing back to back after a
                // main-thread stall would lose a piece and join events
                // across the hole.
                for await pieces in live.textAppended.buffer(size: .max, prefetch: .byRequest, whenFull: .dropOldest).values {
                    model.appendLive(pieces, format: format, textIncomplete: live.state.textIncomplete)
                }
            } else {
                await model.load(session)
            }
        }
    }

    private func content(_ snapshot: StreamEventsModel.Snapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(snapshot)
                Divider()
                if model.events.isEmpty {
                    Text("No complete events in this body.")
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                ForEach(model.events, id: \.index) { event in
                    StreamEventRow(event: event, format: snapshot.format)
                        .equatable()
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ snapshot: StreamEventsModel.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "waveform.path")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(snapshot.summary)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !snapshot.isTimed {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help(StreamEventsPresentation.untimedExplanation)
                        .accessibilityLabel("About arrival times")
                        .accessibilityValue(StreamEventsPresentation.untimedExplanation)
                }
            }
            if let line = snapshot.assemblyLine {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let error = snapshot.assembly.error {
                Label {
                    Text("Error in event #\(error.eventIndex + 1): \([error.type, error.code].compactMap { $0 }.joined(separator: " / "))\(error.message.map { " — \($0)" } ?? "")")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.system(size: 11, weight: .medium))
            }
            if let pending = snapshot.pendingLine {
                Label(pending, systemImage: "scissors")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if snapshot.assembly.provider != nil {
                DisclosureGroup(isExpanded: Binding(
                    get: { assembledExpanded ?? assembledInitiallyExpanded },
                    set: { assembledExpanded = $0 }
                )) {
                    AssembledAnswerView(assembly: snapshot.assembly)
                        .padding(.top, 4)
                } label: {
                    Text("Assembled answer")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The answer put back together: text, then each tool call.
private struct AssembledAnswerView: View {
    let assembly: LLMStreamAssembly

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !assembly.text.isEmpty {
                Text(assembly.text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(Array(assembly.blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .toolCall:
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text([block.name, block.id].compactMap { $0 }.joined(separator: " · "))
                        } icon: {
                            Image(systemName: "wrench.and.screwdriver")
                        }
                        .font(.system(size: 11, weight: .medium))
                        Text(StreamEventsPresentation.displayData(block.content))
                            .font(.system(size: 11, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                case .thinking, .refusal:
                    VStack(alignment: .leading, spacing: 2) {
                        Text(block.kind == .thinking ? "Thinking" : "Refusal")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(block.content)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                case .text:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One event: number, name, time, data. Equatable by content so a growing
/// stream never re-renders a row that already exists.
private struct StreamEventRow: View, Equatable {
    let event: StreamEvent
    let format: StreamFormat

    var body: some View {
        let title = StreamEventsPresentation.title(of: event, format: format)
        let isError = StreamEventsPresentation.isError(event)
        let data = StreamEventsPresentation.displayData(event.data, maxBytes: StreamEventsPresentation.displayDataMaxBytes)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(event.index + 1)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .leading)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isError {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                if let offset = StreamEventsPresentation.offset(event.receivedAt) {
                    Text(offset)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(data.text)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if data.hiddenBytes > 0 {
                Text(StreamEventsPresentation.hiddenLine(data.hiddenBytes))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StreamEventsPresentation.accessibilityLabel(for: event, format: format))
        .accessibilityValue(String(data.text.prefix(500)))
    }
}
