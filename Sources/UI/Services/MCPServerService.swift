//
//  MCPServerService.swift
//  ReqRes
//
//  Created by OloApps on 8/26/26.
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

import AppKit
import Foundation
import MCPKit
import NetworkExtension
import SwiftUI
import Utils
import XReqResCore

/// Hosts the loopback agent bridge inside the running app and publishes the
/// handshake file the stdio `reqres-mcp` binary reads.
///
/// Everything protocol-shaped lives in MCPKit (testable without the closed
/// core); this type only adapts live app state onto MCPKit's two seams.
final class MCPServerService: ObservableObject {
    static let shared = MCPServerService()

    /// Why the last start failed, for the Settings status row — otherwise the
    /// toggle stays on, nothing listens, and the UI says "Starting…" forever.
    @Published private(set) var lastStartError: String?

    /// Agents that have used the bridge recently. Published so the sidebar can
    /// show who is connected without polling the registry from a view body.
    @Published private(set) var connectedClients: [MCPClient] = []

    /// Which captured sessions were made by a connected agent — see
    /// `MCPAgentPresence`. Kept off this object on purpose: the traffic list
    /// observes the presence object alone, so a `lastSeen` tick on
    /// `connectedClients` (every 2 s while an agent is talking) does not
    /// re-render every row — the hang of 2026-09-06 again.

    /// Identities are recorded by the router; this polls the registry because a
    /// bridge request arrives on a connection queue and the UI must only ever
    /// be touched on main. A 2s tick is far below the 90s active window, so the
    /// list is never visibly stale, and it stops entirely when the bridge does.
    private let clientRegistry = MCPClientRegistry()
    private var clientPollTimer: Timer?

    /// The Settings toggle. ON by default: the bridge listens on loopback only,
    /// is authenticated by a 0600 handshake file in the app group, redacts
    /// everything it reads and asks the human before every write — so the cost
    /// of having it ready is small next to making every user find a setting
    /// first. Turning it off is the kill switch and is remembered.
    static let enabledDefaultsKey = "MCPBridgeEnabled"

    private var server: MCPBridgeServer?
    private var handshakeURL: URL?
    private let queue = DispatchQueue(label: "com.oloapps.ReqRes.mcp-service")

    private init() {
        // Registered rather than written, so "never touched" reads as ON while
        // an explicit OFF still wins.
        UserDefaults.standard.register(defaults: [Self.enabledDefaultsKey: true])
        // Built here, on the main thread, because the bridge's redactor
        // provider below runs on a connection queue — letting THAT be the
        // first touch would construct an ObservableObject and write its
        // @Published policy off main.
        _ = MCPRedactionSettings.shared
    }

    var isRunning: Bool { server?.port != nil }
    var port: UInt16? { server?.port }
    var handshakePath: String? { handshakeURL?.path }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
    }

    /// The Settings toggle: persists the choice and starts or stops the
    /// listener to match. Completion runs on the main thread.
    func setEnabled(_ enabled: Bool, completion: @escaping () -> Void = {}) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        queue.async { [weak self] in
            if enabled { self?.start() } else { self?.stop() }
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: - Lifecycle

    /// Starts the bridge unless disabled. Safe to call twice; never throws into
    /// app startup — a bridge failure must not stop the app from launching.
    func startIfEnabled() {
        #if DEBUG
        // `REQRES_MCP_BRIDGE=1`: start regardless of the setting and print the
        // endpoint to stdout — the headless end-to-end check reads it there
        // (the handshake file lives in the group container).
        if ProcessInfo.processInfo.environment["REQRES_MCP_BRIDGE"] != nil {
            queue.async { [weak self] in
                self?.start()
                if let port = self?.port, let path = self?.handshakePath,
                   let token = try? MCPHandshakeFile.read(from: URL(fileURLWithPath: path)).token {
                    print("[mcp] bridge port=\(port) token=\(token)")
                    fflush(stdout)
                }
            }
            // `REQRES_MCP_FIXTURE_PROBE=1`: report the fixtures directory every
            // 2s — the container is TCC-protected, so the headless check
            // cannot list it from the shell.
            if ProcessInfo.processInfo.environment["REQRES_MCP_FIXTURE_PROBE"] != nil {
                Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    let files = (try? MCPRuleAdapter.fixturesDirectory())
                        .flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
                    print("[mcp] fixtures: \(files.count) \(files.sorted())")
                    // Exports live in the same TCC-protected container, and
                    // the end-to-end check has no other way to see that a HAR
                    // actually landed — or to read back what is inside it.
                    if let exports = try? MCPExportAdapter.exportsDirectory() {
                        for name in ((try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? []).sorted() {
                            let url = exports.appendingPathComponent(name)
                            let size = (try? Data(contentsOf: url).count) ?? -1
                            print("[mcp] export: \(name) \(size) bytes")
                            // `REQRES_MCP_EXPORT_CLEAR=1`: the end-to-end
                            // check writes into the real container, which no
                            // shell can reach to tidy up afterwards.
                            if ProcessInfo.processInfo.environment["REQRES_MCP_EXPORT_CLEAR"] != nil {
                                try? FileManager.default.removeItem(at: url)
                                print("[mcp] export removed: \(name)")
                            }
                            if ProcessInfo.processInfo.environment["REQRES_MCP_EXPORT_DUMP"] != nil,
                               let text = try? String(contentsOf: url, encoding: .utf8) {
                                print("<<<EXPORT \(name)\n\(text)\nEXPORT>>>")
                            }
                        }
                    }
                    fflush(stdout)
                }
            }
            // `REQRES_MCP_UNDO_PROBE=1`: undo the newest reversible entry as
            // soon as one appears, and say what happened. Undo is UI-only by
            // design (see MCPUndo), so this is the only way to exercise the
            // real adapters end to end without a human clicking.
            if ProcessInfo.processInfo.environment["REQRES_MCP_UNDO_PROBE"] != nil {
                var done = false
                Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
                    guard !done else { return timer.invalidate() }
                    guard let entry = MCPAgentActivity.shared.entries.first(where: { MCPUndo.plan(for: $0) != nil }),
                          let plan = MCPUndo.plan(for: entry) else {
                        print("[mcp] undo: nothing reversible yet")
                        fflush(stdout)
                        return
                    }
                    done = true
                    print("[mcp] undo: \(entry.action.summary) → \(MCPUndo.summary(for: plan))")
                    MCPAgentActivity.shared.undo(entry) { failure in
                        let top = MCPAgentActivity.shared.entries.first
                        print("[mcp] undo result: \(failure ?? "ok") | logged: \(top?.action.summary ?? "-") byUser=\(top?.byUser ?? false) | original undone=\(MCPAgentActivity.shared.entries.first { $0.id == entry.id }?.undone ?? false)")
                        fflush(stdout)
                    }
                }
            }
            // `REQRES_MCP_PROBE_PNG=1`: rasterise each settings tab at the
            // real window size.
            if ProcessInfo.processInfo.environment["REQRES_MCP_PROBE_PNG"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    let previousTab = UserDefaults.standard.object(forKey: "selectedSettingsTab")
                    let tabs: [(String, SettingsTab)] = [("general", .general), ("certificate", .certificate), ("subscription", .subscription), ("mcp", .mcp)]
                    for (index, tab) in tabs.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.2) {
                            UserDefaults.standard.set(tab.1.rawValue, forKey: "selectedSettingsTab")
                            let hosting = NSHostingView(rootView: SettingsView())
                            hosting.translatesAutoresizingMaskIntoConstraints = false
                            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
                            window.contentView = hosting
                            window.orderBack(nil)
                            hosting.layoutSubtreeIfNeeded()
                            let size = hosting.fittingSize
                            window.setContentSize(size)
                            hosting.frame = NSRect(origin: .zero, size: size)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                print("[mcp] tab \(tab.0) size=\(size)")
                                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                                    if let png = rep.representation(using: .png, properties: [:]) {
                                        print("<<<PNG tab-\(tab.0)\n\(png.base64EncodedString())\nPNG>>>")
                                    }
                                }
                                fflush(stdout)
                                window.orderOut(nil)
                                if index == tabs.count - 1 {
                                    if let previousTab {
                                        UserDefaults.standard.set(previousTab, forKey: "selectedSettingsTab")
                                    } else {
                                        UserDefaults.standard.removeObject(forKey: "selectedSettingsTab")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return
        }
        #endif
        guard UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) else {
            AppLog.shared.debug("[MCPServerService] Bridge disabled (\(Self.enabledDefaultsKey) is off)")
            return
        }
        queue.async { [weak self] in
            self?.start()
        }
    }

    func start() {
        guard server == nil else { return }
        do {
            let token = try MCPHandshakeFile.generateToken()
            let router = MCPBridgeRouter(
                token: token,
                sessions: MCPSessionAdapter(),
                status: MCPStatusAdapter(),
                // Read per request, so excepting a host in Settings applies to
                // the next call instead of the next launch.
                redactorProvider: { MCPRedactionSettings.shared.currentRedactor },
                // RR-MCP-2: every write goes consent → perform → audit.
                writes: MCPWriteSeams(
                    rules: MCPRuleAdapter(),
                    hosts: MCPHostAdapter(),
                    capture: MCPCaptureAdapter(),
                    consent: MCPConsentAdapter(),
                    audit: MCPAuditAdapter(),
                    exporter: MCPExportAdapter(),
                    savedSessions: MCPSavedSessionAdapter(),
                    replay: MCPReplayAdapter(),
                    breakpoints: MCPBreakpointAdapter(),
                    exclusions: MCPExclusionAdapter()
                ),
                clients: clientRegistry
            )
            let server = MCPBridgeServer(router: router)
            let port = try server.start()
            self.server = server

            let url = Self.handshakeFileURL()
            try MCPHandshakeFile.write(MCPHandshake(port: port, token: token), to: url)
            handshakeURL = url

            AppLog.shared.debug("[MCPServerService] Bridge listening on 127.0.0.1:\(port); handshake at \(url.path)")
            DispatchQueue.main.async {
                self.lastStartError = nil
                self.startWatchingClients()
            }
        } catch {
            AppLog.shared.error("[MCPServerService] Failed to start bridge: \(error.localizedDescription, privacy: .public)")
            let message = error.localizedDescription
            stop()
            DispatchQueue.main.async { self.lastStartError = message }
        }
    }

    /// Stops the listener and removes the handshake so no stale token
    /// survives — and refuses anything an agent is waiting to have approved.
    /// The Settings copy calls this the kill switch; leaving a panel up whose
    /// Allow still wrote through a stopped bridge made that untrue.
    func stop() {
        server?.stop()
        server = nil
        if let handshakeURL {
            MCPHandshakeFile.remove(at: handshakeURL)
        }
        handshakeURL = nil
        clientRegistry.reset()
        DispatchQueue.main.async {
            self.stopWatchingClients()
            // Claiming a client is connected to a server that no longer exists
            // is worse than showing nothing.
            self.connectedClients = []
            self.updateAgentIdentities(from: [])
            MCPAgentActivity.shared.cancelAll(reason: "The AI bridge was turned off in ReqRes.")
        }
    }

    private func startWatchingClients() {
        stopWatchingClients()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let active = self.clientRegistry.activeClients()
            // Only publish on a real change: this fires every 2s for the life
            // of the app and SwiftUI should not re-render the sidebar for it.
            if active != self.connectedClients {
                self.connectedClients = active
                self.updateAgentIdentities(from: active)
                #if DEBUG
                // Same probe channel as the bridge's port line: stdout, because
                // the app is sandboxed and its log is awkward to read from a
                // harness.
                print("[mcp] agents active: \(active.map(\.name).joined(separator: ", "))")
                fflush(stdout)
                #endif
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clientPollTimer = timer
    }

    private func stopWatchingClients() {
        clientPollTimer?.invalidate()
        clientPollTimer = nil
    }

    /// Main thread. Publishes each derived set only when it changed — a
    /// `lastSeen` tick changes `connectedClients` without changing either.
    private func updateAgentIdentities(from clients: [MCPClient]) {
        // The presence object is main-actor state (the traffic list observes
        // it); this caller runs on main today, but hopping makes that a fact
        // the compiler checks rather than a comment.
        Task { @MainActor in MCPAgentPresence.shared.update(from: clients) }
    }

    /// Pure, so the derivation is one function: the pids of the clients that
    /// sent one, and names keyed lower-cased with the first client to claim a
    /// name keeping it.

    /// App-group container when reachable (stable, documented path for the
    /// helper binary), else the app's own Application Support directory.
    static func handshakeFileURL() -> URL {
        let fileManager = FileManager.default
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) {
            return group.appendingPathComponent("MCP", isDirectory: true)
                .appendingPathComponent(MCPHandshakeFile.fileName)
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent(MCPHandshakeFile.fileName)
    }
}

// MARK: - Session seam

/// Maps `SessionCodable` (core model, newest-first in SessionState) onto
/// MCPKit's transport-shaped models (oldest-first, as the query contract expects).
struct MCPSessionAdapter: MCPSessionProviding {
    /// `SessionState` is `@Published` state owned by the main thread, and the
    /// bridge answers on its own queue — so every read is marshalled. Safe from
    /// deadlock because the main thread never waits on the bridge queue.
    static func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    /// One hop to main for what only main may read — the row array (a
    /// copy-on-write copy), each row's live state and its destination (both
    /// dictionary lookups) — and the summaries built on the caller's queue.
    /// Building all 5,000 inside `main.sync` held the window for as long as
    /// the slowest per-row read took, on every agent list and every poll of
    /// a wait (release review, 2026-09-29).
    func sessionSummaries() -> [MCPSessionSummary] {
        let (rows, live, countries) = Self.onMain { () -> ([SessionCodable], [UUID: MCPLiveState], [String?]) in
            let state = SessionState.shared
            let now = Date()
            let rows = state.sessions
            var live: [UUID: MCPLiveState] = [:]
            var countries: [String?] = []
            countries.reserveCapacity(rows.count)
            for session in rows {
                if let state = state.agentLiveState(for: session, now: now) { live[session.id] = state }
                countries.append(Self.country(for: session))
            }
            return (rows, live, countries)
        }
        return zip(rows, countries).reversed().map { session, country in
            var summary = Self.summary(from: session, country: country)
            // A live row says so (protocol-engine doc §S6); nil for an
            // ordinary finished row, which is every row but a few.
            summary.live = live[session.id]
            return summary
        }
    }

    func sessionDetail(uid: String) -> MCPSessionDetail? {
        guard let id = UUID(uuidString: uid) else { return nil }
        guard let found = Self.onMain({ () -> (SessionCodable, MCPLiveState?)? in
            let state = SessionState.shared
            return state.sessions.first(where: { $0.id == id }).map { ($0, state.agentLiveState(for: $0)) }
        }) else {
            return nil
        }
        let (session, live) = found
        var detail = Self.detail(from: session)
        detail.summary.live = live
        // No body at all while the row is live (in flight, or ended without
        // its final row): a live snapshot's request body may still be
        // uploading or be past its 64 KB, and a JSON prefix defeats
        // structural redaction. A stream's complete events are
        // `view=events`. The router applies the same rule at egress.
        return detail.withholdingLiveBodies()
    }

    /// For a stream still arriving, the text so far; otherwise the body. The
    /// stream views parse it and let only COMPLETE events out.
    func sessionStreamBody(uid: String) -> String? {
        guard let id = UUID(uuidString: uid) else { return nil }
        return Self.onMain {
            let state = SessionState.shared
            if let model = state.liveModel(for: id) {
                guard model.state.streamFormat != nil, model.textByteCount > 0 else { return nil }
                return model.text
            }
            guard let session = state.sessions.first(where: { $0.id == id }), !session.relayed, !session.rspBody.isEmpty else {
                return nil
            }
            return session.rspBody
        }
    }

    /// `get_session view=rpc` (protocol-engine doc §S8): the row's bytes and
    /// headers, read on main; decoding happens on the bridge's queue.
    func sessionRPCFacts(uid: String) -> MCPSessionRPCFacts? {
        guard let id = UUID(uuidString: uid) else { return nil }
        return Self.onMain {
            let state = SessionState.shared
            return state.sessions.first(where: { $0.id == id }).map { session in
                MCPSessionRPCFacts(
                    host: session.host,
                    isRelay: session.relayed,
                    isLive: state.agentLiveState(for: session) != nil,
                    input: session.rpcInput
                )
            }
        }
    }

    /// `list_messages` (protocol-engine doc §S7): the 101 row and a copy of
    /// its connection's kept messages. The row is found on main (it is
    /// `@Published` state); the messages come from the center's lock.
    func socketConversation(uid: String) -> MCPSocketConversation? {
        guard let id = UUID(uuidString: uid),
              let session = Self.onMain({ SessionState.shared.sessions.first(where: { $0.id == id }) }) else { return nil }
        return MCPSocketConversation(
            uid: uid,
            host: session.host,
            url: session.fullUrl,
            upgradeAt: session.webSocketUpgradeTime,
            isWebSocket: session.isWebSocketUpgrade,
            log: session.exchangeID.flatMap { WebSocketMessageCenter.shared.log(for: $0) }
        )
    }

    /// `wait_for_message`'s poll: kept messages after `ordinal` across every
    /// connection, each with the row it belongs to. The join (and when a
    /// missing row stops the scan) is `MCPSocketFeedRaw.joining`, tested.
    func socketFeed(afterOrdinal ordinal: Int64?, scanLimit: Int) -> MCPSocketFeedRaw {
        let center = WebSocketMessageCenter.shared
        guard let ordinal else { return MCPSocketFeedRaw(latestOrdinal: center.latestOrdinal, items: []) }
        let (latest, found) = center.messages(afterOrdinal: ordinal, limit: scanLimit)
        guard !found.isEmpty else { return MCPSocketFeedRaw(latestOrdinal: latest, items: []) }
        let wanted = Set(found.map(\.exchangeID))
        let rows: [UUID: SessionCodable] = Self.onMain {
            var rows: [UUID: SessionCodable] = [:]
            for session in SessionState.shared.sessions {
                if let exchange = session.exchangeID, wanted.contains(exchange) { rows[exchange] = session }
            }
            return rows
        }
        return MCPSocketFeedRaw.joining(
            latestOrdinal: latest, after: ordinal, found: found, scanLimit: scanLimit,
            now: Date().timeIntervalSince1970
        ) { exchange, stored in
            rows[exchange].map { MCPSocketFeedItem(uid: $0.id.uuidString, host: $0.host, upgradeAt: $0.webSocketUpgradeTime, stored: stored) }
        }
    }

    /// `query_session_body`'s facts, read without building the detail: the
    /// detail renders `session.cURL`, a computed string over a request body of
    /// up to 16 MB, and the query needs only these three values.
    func sessionBodyFacts(uid: String) -> MCPSessionBodyFacts? {
        guard let id = UUID(uuidString: uid) else { return nil }
        return Self.onMain {
            let state = SessionState.shared
            return state.sessions.first(where: { $0.id == id }).map { session in
                MCPSessionBodyFacts(
                    isRelay: session.relayed,
                    requestNotRetainedBytes: session.reqBodyTruncatedBytes,
                    responseNotRetainedBytes: session.rspBodyTruncatedBytes,
                    isLive: state.agentLiveState(for: session) != nil
                )
            }
        }
    }

    /// The stream views' facts (`get_session view=events|assembled`), read
    /// without building the detail — same reason as `sessionBodyFacts`.
    func sessionStreamFacts(uid: String) -> MCPSessionStreamFacts? {
        guard let id = UUID(uuidString: uid) else { return nil }
        return Self.onMain {
            let state = SessionState.shared
            return state.sessions.first(where: { $0.id == id }).map { session in
                var facts = Self.streamFacts(from: session)
                facts.inFlight = state.isInFlight(session.id)
                return facts
            }
        }
    }

    static func streamFacts(from session: SessionCodable) -> MCPSessionStreamFacts {
        let head = session.rspStartTime.doubleValue
        let end = session.rspEndTime.doubleValue
        return MCPSessionStreamFacts(
            isRelay: session.relayed,
            contentType: session.rspContentType.isEmpty ? nil : session.rspContentType,
            host: session.host,
            // Core timestamps are seconds (see `date(from:)`).
            responseDurationMs: head > 0 && end >= head ? (end - head) * 1000 : nil,
            notRetainedBytes: session.rspBodyTruncatedBytes
        )
    }

    /// THE mapping from a core session to the bridge's detail — live sessions
    /// and saved ones both go through it (`MCPSavedSessionAdapter`), so an
    /// agent cannot tell one from the other by shape, and a field added here
    /// reaches both. The saved copy used to be a hand-kept duplicate and had
    /// already lost the server address.
    static func detail(from session: SessionCodable) -> MCPSessionDetail {
        // A relayed connection has no request or response inside it: no
        // headers, no body, and no cURL for a request that never existed.
        let isRelay = session.relayed
        let tracksReuse = RecordedExchangeCopy.tracksConnectionReuse(scheme: session.scheme, isRelay: isRelay)
        return MCPSessionDetail(
            summary: Self.summary(from: session),
            requestHeaders: isRelay ? [:] : Self.headers(from: session.reqHeaders),
            responseHeaders: isRelay ? [:] : Self.headers(from: session.rspHeaders),
            requestBodyPreview: isRelay ? nil : Self.requestBodyPreview(for: session),
            responseBodyPreview: isRelay ? nil : Self.responseBodyPreview(for: session),
            curl: isRelay ? nil : session.cURL,
            // The raw server address, detail only (destination-map UX spec
            // §8.1, §11): never in the activity log or its export.
            serverAddress: session.remoteAddressText,
            connectionReused: tracksReuse ? session.connectionReused : nil,
            exchangeIndex: tracksReuse ? session.exchangeIndex : nil,
            requestBodyNotRetainedBytes: session.reqBodyTruncatedBytes,
            responseBodyNotRetainedBytes: session.rspBodyTruncatedBytes,
            // Header fields sent after the body (core C13); redacted like
            // headers on the way out (`MCPRedactor.redactDetail`).
            requestTrailers: isRelay ? nil : Self.headers(from: session.reqTrailers),
            responseTrailers: isRelay ? nil : Self.headers(from: session.rspTrailers)
        )
    }

    /// Full, uncapped body for server-side querying — never returned whole to
    /// the agent; MCPJSONQuery reduces it to the requested subset first.
    func sessionBody(uid: String, side: MCPBodySide) -> String? {
        guard let id = UUID(uuidString: uid) else { return nil }
        guard let session = Self.onMain({ SessionState.shared.sessions.first(where: { $0.id == id }) }) else {
            return nil
        }
        guard !session.relayed else { return nil }
        // A binary body answers with its description, so the query says
        // "not JSON" rather than "no body".
        return side == .request ? Self.requestBodyPreview(for: session) : Self.responseBodyPreview(for: session)
    }

    static func summary(from session: SessionCodable) -> MCPSessionSummary {
        summary(from: session, country: country(for: session))
    }

    /// `country` already resolved (on main, by the caller).
    static func summary(from session: SessionCodable, country: String?) -> MCPSessionSummary {
        let identity = session.processIdentity
        return MCPSessionSummary(
            uid: session.id.uuidString,
            host: session.host,
            method: session.method,
            url: session.fullUrl,
            scheme: session.scheme,
            statusCode: session.rspStatus.flatMap { Int($0) },
            startedAt: Self.date(from: session.startTime),
            durationMs: Self.durationMs(for: session),
            requestBodySize: session.requestBytes.intValue,
            responseBodySize: session.responseBytes.intValue,
            contentType: session.rspContentType.isEmpty ? nil : session.rspContentType,
            // Name and pid only, never the path (UX spec §11): the path
            // carries the username and no agent needs it. Read through the
            // same seam as the App column, so an agent's `app` and the
            // human's `app:` cannot disagree about a session.
            app: identity.displayName,
            pid: identity.pid,
            country: country,
            kind: session.relayed ? .relay : .exchange,
            // How it ended (protocol PRD 3.4). Sent for every row, so a
            // completed one says so rather than leaving the helper to guess.
            outcome: session.sessionOutcome,
            failurePhase: session.sessionFailurePhase,
            failureDetail: session.isFailure ? session.failureDetail : nil,
            clientCancelled: session.isFailure ? session.clientCancelled : nil,
            neverConnected: session.isFailure ? session.neverConnected : nil,
            // The RPC's own status (protocol-engine doc §S8), from the same
            // cache the table and the `grpc:` chip read.
            grpcStatus: RPCStatusCache.shared.facts(for: session)?.status?.code,
            // What the row spoke (doc §S9) — the version as RECORDED, never a
            // constant, and the one token `proto=` and the `proto:` chip use.
            // A relay recorded no version: nothing inside it was read.
            httpVersion: session.relayed ? nil : session.recordedHTTPVersion,
            proto: session.sessionProtocol?.token,
            // A relay to a host macOS pins (live-run F5): the policy, which
            // the row's wording names.
            pinnedBy: session.relayed ? session.pinnedBy : nil
        )
    }

    /// The destination token (`"US"`, `"local"`, `"mac"`) through the same
    /// resolver as the window and the `country:` chip — and nil when Unknown,
    /// so the row omits it (destination-map UX spec §8.1). Resolution is a
    /// cached lookup on main; re-entrant through `onMain` when the caller is
    /// already there.
    static func country(for session: SessionCodable) -> String? {
        let destination = onMain { MainActor.assumeIsolated { DestinationResolver.shared.destination(for: session) } }
        return destination == .unknown ? nil : destination.token
    }

    /// Binary payloads are described, never inlined — an agent gets the shape
    /// without a megabyte of base64 in its context.
    private static func responseBodyPreview(for session: SessionCodable) -> String? {
        if !session.rspBody.isEmpty { return session.rspBody }
        if let data = session.rspBodyData, !data.isEmpty {
            return MCPBinaryBody.description(contentType: session.rspContentType, bytes: data,
                                             undecodedEncoding: session.rspBodyUndecodedEncoding)
        }
        return nil
    }

    /// The request side, described the same way. Since core C7 a binary
    /// request body is in `reqBodyData` with `reqBody` empty, and reading
    /// `reqBody` alone showed no body at all (release review, 2026-09-29).
    private static func requestBodyPreview(for session: SessionCodable) -> String? {
        if !session.reqBody.isEmpty { return session.reqBody }
        if let data = session.reqBodyData, !data.isEmpty {
            return MCPBinaryBody.description(contentType: session.reqContentType, bytes: data,
                                             undecodedEncoding: session.reqBodyUndecodedEncoding)
        }
        return nil
    }

    /// `reqHeaders`/`rspHeaders` are an ordered pair array since the 1.1.0 core
    /// (`[{"Set-Cookie":"a=1"}, …]`) and a JSON object before it (every older
    /// saved session). `MCPRecordedHeaders` reads both; reading only the object
    /// shape returned no headers at all for a new row.
    static func headers(from raw: String?) -> [String: String] {
        MCPRecordedHeaders.dictionary(from: raw)
    }

    /// Core timestamps are SECONDS since the epoch (`Date().timeIntervalSince1970`),
    /// not milliseconds — dividing here would date every session to 1970.
    static func date(from value: NSNumber) -> Date? {
        let seconds = value.doubleValue
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func durationMs(for session: SessionCodable) -> Double? {
        let start = session.reqStartTime.doubleValue
        let end = session.rspEndTime.doubleValue
        guard start > 0, end > start else { return nil }
        return (end - start) * 1000
    }
}

// MARK: - Status seam

struct MCPStatusAdapter: MCPStatusProviding {
    func bridgeStatus() -> MCPBridgeStatus {
        // The keychain lookup is thread-safe and slow; do it off main.
        let installedCertificate = CertHelper.getInstalledCertificate()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        // `vpnStatus`, `extensionStatus` and `sessions` are @Published state
        // owned by the main thread — and `sessions` is replaced wholesale every
        // 150ms while capture runs. Read all three in ONE hop, like the
        // session seam does.
        let (vpn, ext, count, delivery) = MCPSessionAdapter.onMain {
            (AppState.shared.vpnStatus, AppState.shared.extensionStatus, SessionState.shared.sessions.count,
             // A fresh look, not the last published verdict (F11).
             MainActor.assumeIsolated { CaptureDeliveryMonitor.shared.bridgeFact() })
        }
        return MCPBridgeStatus(
            captureActive: vpn == .connected,
            vpnStatus: Self.describe(vpn),
            extensionStatus: ext.rawValue,
            caCertificateInstalled: installedCertificate != nil,
            // Installed and TRUSTED are different states, and only both
            // together decrypt: an installed-but-untrusted CA RELAYS every
            // HTTPS connection (core C7/C8, one kind=relay row each), which
            // looks like capture half-working. Reported nil only when the
            // lookup fails.
            caCertificateTrusted: installedCertificate == nil ? nil : Self.certificateTrusted(),
            sessionCount: count,
            appVersion: version,
            // Where Settings ▸ Capture last exported the CA, so
            // `capture_environment` renders the same lines as the pane
            // (errata 3: one renderer, one path).
            caExportedPath: Self.exportedCertificatePath(),
            // Step C8: an export made before this install's CA existed (or
            // of an earlier install's) holds a CA tools can no longer use,
            // and an older "ReqRes CA" may still be in the keychain.
            caExportedCertificateOutdated: Self.exportedCertificateOutdated(),
            caOutdatedCertificatesInstalled: CertHelper.outdatedInstalledCertificates().count,
            // What capture_environment's keychain step selects by: an older
            // "ReqRes CA" can sit beside this one under the same name.
            caFingerprintSHA256: (try? CertificateAuthority.ensureInstallCA())?.fingerprintSHA256,
            // The user's Settings ▸ Capture choice (doc §S9), read from the
            // app's own defaults — the one place it is stored. On the status
            // so capture_status's protocol notes and diagnose_setup's
            // http2_capture check read the same value (doc §S13).
            http2CaptureEnabled: HTTP2CaptureSetting.isEnabled(in: .standard),
            // The port the proxy is on (Settings ▸ Capture can change it),
            // so the helper's environment lines and diagnosis name it.
            proxyPort: CaptureProxyPort.active(tunnelUp: vpn == .connected),
            // Capture on is not rows arriving (F11): capture_status's
            // Delivery line and diagnose_setup's `delivery` check.
            delivery: delivery
        )
    }

    /// True when the remembered export holds a CA other than this install's;
    /// nil when nothing was exported or there is no CA to compare with.
    static func exportedCertificateOutdated() -> Bool? {
        let defaults = UserDefaults.standard
        switch CaptureEnvironmentLines.exportFreshness(
            exportedPath: defaults.string(forKey: CaptureEnvironmentLines.exportedPathDefaultsKey),
            exportedFingerprint: defaults.string(forKey: CaptureEnvironmentLines.exportedFingerprintDefaultsKey),
            currentFingerprint: (try? CertificateAuthority.ensureInstallCA())?.fingerprintSHA256
        ) {
        case .outdated: return true
        case .current: return false
        case .none, .unknown: return nil
        }
    }

    /// UserDefaults `CaptureEnvironmentLines.exportedPathDefaultsKey`, or nil
    /// before any export — the pane's `@AppStorage` stores "" for "never".
    /// UserDefaults is thread-safe, so no main hop.
    static func exportedCertificatePath() -> String? {
        guard let path = UserDefaults.standard.string(forKey: CaptureEnvironmentLines.exportedPathDefaultsKey),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    /// The core's `CertHelper` reads the trust setting for us; it is async, so
    /// this blocks the bridge's own connection queue for it and never the main
    /// thread. Any failure is nil — "could not tell", not "not trusted".
    static func certificateTrusted() -> Bool? {
        try? MCPSync.wait { try await CertHelper.getRootCertificate().trusted }
    }

    /// Facts only the app can see: where it is installed, whether the proxy's
    /// port is really accepting connections, and how much of the free tier is
    /// left. Everything unobtainable stays nil.
    func setupFacts() -> MCPSetupFacts {
        let status = bridgeStatus()
        let (used, limit, licensed, attribution) = MCPSessionAdapter.onMain {
            (AppState.shared.freeHttpsSessionsInspected, AppState.shared.maxFreeHttpsSessions, LicenseManager.shared.isProUser(),
             AppState.shared.processAttribution)
        }
        // SessionState stores newest-first, and the core's timestamps are
        // SECONDS since the epoch (the 1970 bug this adapter already learned).
        let lastSession = MCPSessionAdapter.onMain { SessionState.shared.sessions.first.flatMap { MCPSessionAdapter.date(from: $0.startTime) } }
        // The destinations check (destination-map UX spec §8.5): how many
        // retained sessions were placed in a country, how many carry no
        // address at all (every one of them when the running extension
        // predates the field), and whether the offline table loaded. Read
        // from the index the flush maintains — one pass over the retained
        // sessions for the nil count, on demand only.
        let (tableLoaded, placeable, withoutAddress) = MCPSessionAdapter.onMain {
            MainActor.assumeIsolated {
                let state = SessionState.shared
                let placed = state.destinationIndex.plottable.reduce(0) { $0 + $1.requests }
                // A failure that never connected has no address by nature —
                // not a sign of an old extension, so it is not counted here.
                let missing = state.sessions.reduce(0) { $0 + ($1.remoteAddressText == nil && !$1.neverConnected ? 1 : 0) }
                return (DestinationResolver.shared.tableLoaded, placed, missing)
            }
        }
        // Apps that refused ReqRes's certificate in this run (the pinning
        // case, protocol PRD 3.4), per host and process — the rows the core
        // wrote, coalesced per 30 s, grouped here.
        let rejections = MCPSessionAdapter.onMain {
            SessionState.shared.sessions
                .filter { $0.sessionOutcome == .failed && $0.sessionFailurePhase == .tlsClient }
                .map { (host: $0.host, app: $0.processIdentity.displayName, at: MCPSessionAdapter.date(from: $0.startTime)) }
        }
        return MCPSetupFacts(
            status: status,
            runningFromApplications: Bundle.main.bundlePath.hasPrefix("/Applications/"),
            proxyPort: status.effectiveProxyPort,
            // Only worth asking while the tunnel claims to be up — that is the
            // pair that used to disagree, and a connect attempt costs a socket.
            proxyPortListening: status.captureActive ? Self.isListening(port: status.effectiveProxyPort) : nil,
            freeInspectionsUsed: used,
            freeInspectionsLimit: limit,
            licensed: licensed,
            lastSessionAt: lastSession,
            // nil until the extension has reported (UX spec §9.1), so the
            // diagnosis skips the check rather than guessing either way.
            processAttribution: attribution.isAvailable,
            destinationTableLoaded: tableLoaded,
            destinationsPlaceable: placeable,
            destinationsWithoutAddress: withoutAddress,
            tlsRejections: MCPTLSRejection.group(rejections)
            // http2CaptureEnabled: taken from `status` (bridgeStatus reads
            // the setting once for both tools, doc §S13).
        )
    }

    /// A plain loopback connect with a short timeout. The proxy runs inside
    /// the system extension, in another process, so this is the only honest
    /// way to ask whether it is really there — the tunnel's own status is
    /// what lied in the phantom-start bug.
    static func isListening(port: Int, timeout: TimeInterval = 0.4) -> Bool? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var timeval = timeval(tv_sec: Int(timeout), tv_usec: Int32(timeout.truncatingRemainder(dividingBy: 1) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    static func describe(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }
}

/// The one publisher of "which processes belong to a connected agent". The
/// rule is `MCPAgentAttribution` (MCPKit); this publishes it only when the
/// sets change, and the traffic list observes THIS object rather than the
/// service, so client heartbeats never re-render rows.
@MainActor
final class MCPAgentPresence: ObservableObject {
    static let shared = MCPAgentPresence()
    @Published private(set) var attribution = MCPAgentAttribution(clients: [])

    func update(from clients: [MCPClient]) {
        let next = MCPAgentAttribution(clients: clients)
        if next != attribution { attribution = next }
    }
}
