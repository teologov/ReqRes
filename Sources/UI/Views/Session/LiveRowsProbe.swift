//
//  LiveRowsProbe.swift
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
//  DEBUG instruments for live rows (protocol-engine doc §S6), both driven
//  through the REAL ingest path (`SessionState.enqueue` → ledger → the 150 ms
//  flush → the table), because a probe that fed the views directly would
//  prove only the views:
//
//  - `REQRES_UI_PROBE=live-rows | live-events | live-body` renders a waiting
//    row, a streaming row, an ended row and a finished one in the table, or
//    the detail of a streaming SSE row with its Events or Body tab while text
//    keeps arriving (HelpWindowController's probe prints the PNG).
//  - `REQRES_LIVE_LOAD_PROBE=1` feeds ten concurrent streams at 100 events/s
//    plus ordinary rows for `REQRES_LIVE_LOAD_PROBE_SECONDS` (default 60)
//    through the bus decoder and the ingest path while the real `SessionView`
//    is on screen, and prints how busy the main thread was.
//

#if DEBUG
import AppKit
import MCPKit
import SwiftUI
import Utils
import XReqResCore

// MARK: - Synthetic messages

enum LiveProbeMessages {
    static let sseType = "text/event-stream; charset=utf-8"

    /// A request snapshot as `session_started` carries it: no response body.
    static func snapshot(exchange: UUID, host: String, uri: String, streaming: Bool, start: TimeInterval,
                         contentType: String = sseType) -> SessionCodable {
        var session = SESSION_MOCK_SSE
        session.id = UUID()
        session.exchangeID = exchange
        session.host = host
        session.uri = uri
        session.startTime = NSNumber(value: start)
        session.reqStartTime = NSNumber(value: start)
        session.rspBody = ""
        session.rspEndTime = NSNumber(value: 0)
        session.responseBytes = NSNumber(value: 0)
        if streaming {
            session.rspStartTime = NSNumber(value: start + 0.4)
            session.rspContentType = contentType
        } else {
            session.rspStatus = nil
            session.rspReasonPhrase = nil
            session.rspHeaders = nil
            session.rspContentType = ""
            session.rspStartTime = NSNumber(value: 0)
        }
        return session
    }

    static func started(_ snapshot: SessionCodable, streaming: Bool) -> LiveSessionStarted {
        LiveSessionStarted(
            exchangeID: snapshot.exchangeID!,
            reason: streaming ? .streamingResponse : .slow,
            phase: streaming ? .streaming : .waiting,
            session: snapshot,
            requestBytes: 142,
            responseBytes: 0,
            requestComplete: true,
            textStatus: streaming ? .text : .awaitingResponse,
            sentAt: Date().timeIntervalSince1970
        )
    }

    static func progress(exchange: UUID, sequence: Int, text: String, offset: Int64, responseBytes: Int64,
                         session: SessionCodable? = nil) -> LiveSessionProgress {
        LiveSessionProgress(
            exchangeID: exchange, sequence: sequence, phase: .streaming, requestBytes: 142,
            responseBytes: responseBytes, requestComplete: true, appendedText: text, textOffset: offset,
            textStatus: .text, session: session, sentAt: Date().timeIntervalSince1970
        )
    }

    static func final(_ snapshot: SessionCodable, body: String) -> SessionCodable {
        var row = snapshot
        row.id = UUID()
        row.rspBody = body
        row.rspStatus = "200"
        row.rspEndTime = NSNumber(value: Date().timeIntervalSince1970)
        row.responseBytes = NSNumber(value: body.utf8.count)
        return row
    }

    /// One SSE token event, ~110 bytes.
    static func tokenEvent(_ n: Int) -> String {
        #"event: content_block_delta"# + "\n" +
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" token \#(n)"}}"# + "\n\n"
    }

    /// Delivers through the REAL bus delegate: encoded as the extension
    /// encodes it, decoded as the app decodes every frame.
    static func deliver<T: Codable>(_ action: ClientBusAction, _ value: T) {
        let message = ClientBusMessage(action: action, payload: ["data": value])
        guard let data = message.toJSONData(),
              let generic = ClientBusMessageNonGeneric.fromJSONData(data) else { return }
        AppController.shared.tcpServerBus(AppController.tcpServerBus, didReceiveMessage: generic, data: data)
    }
}

// MARK: - Render probe

struct LiveRowsProbe: View {
    let target: String
    @ObservedObject private var state = SessionState.shared

    static let waitingExchange = UUID()
    static let streamingExchange = UUID()
    static let endedExchange = UUID()
    static let doneExchange = UUID()

    /// Seeds the real ingest path: a finished row, a request still waiting,
    /// an SSE answer streaming, and one that ended without its final. More
    /// text arrives after the first render, so the capture shows a view that
    /// GREW, not one that was built whole.
    static func seed() {
        let now = Date().timeIntervalSince1970
        var done = SESSION_MOCK
        done.id = UUID()
        done.exchangeID = doneExchange
        done.startTime = NSNumber(value: now - 5)
        done.reqStartTime = NSNumber(value: now - 5)
        done.rspEndTime = NSNumber(value: now - 4.8)
        LiveProbeMessages.deliver(.sendSession, done)

        let waiting = LiveProbeMessages.snapshot(exchange: waitingExchange, host: "api.example.com", uri: "/v1/reports/export?year=2026",
                                                 streaming: false, start: now - 12)
        LiveProbeMessages.deliver(.sessionStarted, LiveProbeMessages.started(waiting, streaming: false))

        let ended = LiveProbeMessages.snapshot(exchange: endedExchange, host: "updates.example.net", uri: "/feed",
                                               streaming: false, start: now - 30)
        LiveProbeMessages.deliver(.sessionStarted, LiveProbeMessages.started(ended, streaming: false))

        let streaming = LiveProbeMessages.snapshot(exchange: streamingExchange, host: "api.anthropic.com", uri: "/v1/messages?beta=true",
                                                   streaming: true, start: now - 3)
        LiveProbeMessages.deliver(.sessionStarted, LiveProbeMessages.started(streaming, streaming: true))
        let events = SESSION_MOCK_SSE_BODY.components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { $0 + "\n\n" }
        // First piece: four events and HALF of the fifth (a fragment).
        var sent = 0
        var sequence = 0
        func send(_ text: String) {
            sequence += 1
            LiveProbeMessages.deliver(.sessionProgress, LiveProbeMessages.progress(
                exchange: streamingExchange, sequence: sequence, text: text, offset: Int64(sent), responseBytes: Int64(sent + text.utf8.count)))
            sent += text.utf8.count
        }
        let fifth = events[4]
        send(events[0..<4].joined() + String(fifth.prefix(40)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            send(String(fifth.dropFirst(40)) + events[5..<9].joined())
            // The "ended" row: capture stopping ends what is still open —
            // here for ONE row, through the real ledger and flush.
            SessionState.shared.endForProbe(exchange: endedExchange, reason: .captureStopped)
        }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ exchange: UUID) -> SessionCodable? {
        state.sessions.first { $0.exchangeID == exchange }
    }

    @ViewBuilder
    private var content: some View {
        if target == "live-rows" {
            ScrollView {
                LazyVStack(spacing: 0) {
                    SessionTableHeader(mode: .wide, showsApp: true)
                    // Only the seeded rows: Debug builds also seed the mocks.
                    let seeded: Set<UUID> = [Self.waitingExchange, Self.streamingExchange, Self.endedExchange, Self.doneExchange]
                    ForEach(Array(state.sessions.filter { $0.exchangeID.map(seeded.contains) ?? false }.enumerated()), id: \.element.id) { index, session in
                        TableRowView(session: session, isSelected: session.exchangeID == Self.streamingExchange,
                                     isEvenRow: index % 2 == 0, mode: .wide, showsApp: true, attribution: .available,
                                     isAgent: false, live: state.liveModel(for: session.id), ended: state.endedRow(session.id))
                    }
                }
            }
        } else if let session = row(Self.streamingExchange) {
            let live = state.liveModel(for: session.id)
            let tab: NetworkInspectorTabResponse = target == "live-body" ? .response : .events
            VStack(alignment: .leading, spacing: 0) {
                SessionDetailHeaderView(session: session, attribution: .available, onClose: {})
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        RequestToolbar(title: .Request, selection: .constant(.headers))
                        Divider()
                        SessionRequestTabView(session: session, selectedTabRequest: .constant(.headers))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        ResponseToolbar(title: .Response, selection: .constant(tab),
                                        items: NetworkInspectorTabResponse.tabs(for: session, live: live))
                        Divider()
                        SessionResponseTabView(session: session, selectedTabResponse: .constant(tab), live: live)
                    }
                }
            }
        } else {
            Text("seeding…")
        }
    }
}

// MARK: - Load probe

enum LiveLoadProbe {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["REQRES_LIVE_LOAD_PROBE"] != nil else { return }
        let seconds = env["REQRES_LIVE_LOAD_PROBE_SECONDS"].flatMap(Double.init) ?? 60
        let streams = env["REQRES_LIVE_LOAD_PROBE_STREAMS"].flatMap(Int.init) ?? 10
        let eventsPerSecond = env["REQRES_LIVE_LOAD_PROBE_EVENTS"].flatMap(Int.init) ?? 100
        let rowsPerSecond = env["REQRES_LIVE_LOAD_PROBE_ROWS"].flatMap(Int.init) ?? 20

        // The real traffic view, on screen, at the default window size — so
        // SwiftUI's diffing and drawing are in the measurement, not just the
        // model. A second window follows one stream's Events tab.
        let hosting = NSHostingView(rootView: SessionView())
        hosting.frame = NSRect(x: 0, y: 0, width: 1250, height: 800)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()

        // Utils.QueueLatencyWatchdog: its stop() is safe from main (the probe's own
        // first watchdog deadlocked there — release review, 2026-09-29).
        let watchdog = QueueLatencyWatchdog()
        watchdog.start()
        let mainCPUBefore = MainThreadCPU.seconds()
        let wallStart = CFAbsoluteTimeGetCurrent()

        let generator = DispatchQueue(label: "live-load-probe")
        var stream = (0..<streams).map { _ in ProbeStream() }
        var tick = 0
        let tickInterval = 0.05 // 20 ticks a second
        let progressEvery = 5   // a progress per stream every 250 ms (the core's rate)
        let eventsPerProgress = max(1, eventsPerSecond / 4)
        let streamLifetime = 20.0
        var progressSent = 0, rowsSent = 0, streamsFinished = 0, eventsSent = 0
        var detailWindow: NSWindow?

        let timer = DispatchSource.makeTimerSource(queue: generator)
        timer.schedule(deadline: .now(), repeating: tickInterval)
        timer.setEventHandler {
            let now = Date().timeIntervalSince1970
            tick += 1
            // Ordinary fast rows (their final only, like every fast exchange).
            let rowsThisTick = rowsPerSecond / 20 + (tick % 20 < rowsPerSecond % 20 ? 1 : 0)
            for _ in 0..<rowsThisTick {
                var row = SESSION_MOCK
                row.id = UUID()
                row.exchangeID = UUID()
                row.uri = "/v1/items/\(rowsSent)"
                row.startTime = NSNumber(value: now - 0.1)
                row.reqStartTime = NSNumber(value: now - 0.1)
                row.rspEndTime = NSNumber(value: now)
                LiveProbeMessages.deliver(.sendSession, row)
                rowsSent += 1
            }
            for index in stream.indices {
                if stream[index].exchange == nil {
                    stream[index] = ProbeStream(start: now, index: index)
                    let snapshot = stream[index].snapshot!
                    LiveProbeMessages.deliver(.sessionStarted, LiveProbeMessages.started(snapshot, streaming: true))
                    continue
                }
                guard tick % progressEvery == index % progressEvery else { continue }
                var text = ""
                for _ in 0..<eventsPerProgress {
                    text += LiveProbeMessages.tokenEvent(stream[index].events)
                    stream[index].events += 1
                }
                eventsSent += eventsPerProgress
                stream[index].sequence += 1
                LiveProbeMessages.deliver(.sessionProgress, LiveProbeMessages.progress(
                    exchange: stream[index].exchange!, sequence: stream[index].sequence, text: text,
                    offset: Int64(stream[index].body.utf8.count), responseBytes: Int64(stream[index].body.utf8.count + text.utf8.count)))
                stream[index].body += text
                progressSent += 1
                if now - stream[index].start > streamLifetime {
                    LiveProbeMessages.deliver(.sendSession, LiveProbeMessages.final(stream[index].snapshot!, body: stream[index].body))
                    streamsFinished += 1
                    stream[index] = ProbeStream()
                }
            }
            if tick == 10 {
                // Follow stream 0's Events tab once it exists.
                DispatchQueue.main.async {
                    guard let exchange = stream.first?.exchange,
                          let session = SessionState.shared.sessions.first(where: { $0.exchangeID == exchange }),
                          let live = SessionState.shared.liveModel(for: session.id) else { return }
                    let view = SessionResponseTabView(session: session, selectedTabResponse: .constant(.events), live: live)
                    let hosting = NSHostingView(rootView: view)
                    hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
                    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    window.contentView = hosting
                    window.orderFrontRegardless()
                    detailWindow = window
                }
            }
            if Double(tick) * tickInterval >= seconds {
                timer.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let wall = CFAbsoluteTimeGetCurrent() - wallStart
                    let cpu = MainThreadCPU.seconds() - mainCPUBefore
                    let report = watchdog.stop()
                    let state = SessionState.shared
                    print("""
                    [live-load] \(String(format: "%.1f", wall)) s wall; \(streams) streams × \(eventsPerSecond) events/s (\(eventsPerProgress) events per progress, 4 progress/s each) + \(rowsPerSecond) rows/s
                    [live-load] sent: \(progressSent) progress, \(eventsSent) events, \(rowsSent) ordinary rows, \(streamsFinished) streams finished (each replaced in place)
                    [live-load] table: \(state.sessions.count) rows, \(state.inFlightCount) in flight
                    [live-load] main thread CPU: \(String(format: "%.2f", cpu)) s = \(String(format: "%.1f", cpu / wall * 100)) % of wall (includes SwiftUI layout and drawing of the table and the Events window)
                    [live-load] ingest apply on main: \(state.applyCount) flushes, \(String(format: "%.0f", state.applyBusySeconds * 1000)) ms total, longest \(String(format: "%.1f", state.applyLongestSeconds * 1000)) ms
                    [live-load] responsiveness (a ping to main every 20 ms): \(report.samples) pings, median \(String(format: "%.1f", report.median * 1000)) ms, p99 \(String(format: "%.1f", report.p99 * 1000)) ms, worst \(String(format: "%.1f", report.worst * 1000)) ms, \(report.over100ms) over 100 ms, \(report.over250ms) over 250 ms
                    """)
                    _ = detailWindow
                    fflush(stdout)
                    exit(0)
                }
            }
        }
        timer.resume()
    }

    private struct ProbeStream {
        var exchange: UUID?
        var snapshot: SessionCodable?
        var start: TimeInterval = 0
        var sequence = 0
        var events = 0
        var body = ""

        init() {}

        init(start: TimeInterval, index: Int) {
            let exchange = UUID()
            self.exchange = exchange
            self.start = start
            self.snapshot = LiveProbeMessages.snapshot(exchange: exchange, host: "stream\(index).example.com",
                                                       uri: "/v1/messages", streaming: true, start: start)
        }
    }
}

/// CPU time (user + system) of the main thread, from the kernel.
enum MainThreadCPU {
    static func seconds() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads, count > 0 else { return 0 }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        // The first thread of the task is the main thread.
        var info = thread_basic_info()
        var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                thread_info(threads[0], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }
}
// MARK: - Column widths probe

/// `REQRES_UI_PROBE=traffic-columns | traffic-columns-resized`: the table with
/// a method of every width (GET … MKCALENDAR) and every destination class, at
/// the automatic widths or at dragged ones, through the same
/// `SessionTableLayout.columns` the traffic list uses. Rows that line up
/// here line up in the list: both lay out from one `Columns` value.
struct ColumnsProbe: View {
    let resized: Bool

    private static let rows: [(String, TrafficDestination)] = [
        ("GET", .country("US")), ("PROPFIND", .country("US")), ("PROPPATCH", .country("DE")),
        ("MKCALENDAR", .unknown), ("OPTIONS", .thisMac), ("CONNECT", .localNetwork),
    ]

    private func session(_ method: String) -> SessionCodable {
        var session = SESSION_MOCK
        session.method = method
        return session
    }

    var body: some View {
        let user: SessionTableLayout.ColumnWidths = resized
            ? .init([.method: 96, .app: 180, .destination: 50, .time: 100])
            : .init()
        let columns = SessionTableLayout.columns(paneWidth: 1000, showsApp: true, destinationPreferred: true, user: user)
        ScrollView {
            LazyVStack(spacing: 0) {
                SessionTableHeader(mode: .wide, showsApp: true, columns: columns,
                                   resizing: ColumnResizing(change: { _, _ in }, commit: {}, reset: { _ in }))
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                    TableRowView(session: session(row.0), isSelected: index == 2, isEvenRow: index % 2 == 0,
                                 mode: .wide, showsApp: true, attribution: .available, isAgent: false,
                                 destination: row.1, columns: columns)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#endif
