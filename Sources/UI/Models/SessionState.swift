//
//  SessionState.swift
//  ReqRes
//
//  Created by OloApps on 10/2/24.
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
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

import Foundation
import AppKit
import Combine
import MCPKit
import Utils
import XReqResCore

class SessionState: ObservableObject {
    static let shared = SessionState()
    
    @Published var sessions = [SessionCodable]()
    @Published var sessionsByHost: [String: [SessionCodable]] = [:]
    @Published var filteredSessions = [SessionCodable]()
    @Published var sessionsSubtitle = ""

    /// Which apps and processes the retained `sessions` came from (UX spec
    /// §1.7). A plain var, NOT `@Published`: it changes on every flush, and
    /// the surfaces that read it — the search field's `app:`/`pid:`
    /// suggestions, Settings ▸ Capture, the agent footer — ask on demand, on
    /// main. Maintained in `flushPendingSessions` in O(batch), corrected as
    /// rows leave (the retention cap, deletes), rebuilt in both clear paths.
    private var index = ProcessAttributionIndex()
    /// Keyed by display name lower-cased.
    var attributionIndex: [String: AppIndexEntry] { index.entries }
    /// Retained sessions whose process could not be named.
    var unknownCount: Int { index.unknownCount }

    /// Where the retained `sessions` went (destination-map UX spec §1.7),
    /// maintained beside `index` with the same discipline: every arrival
    /// added, every row the cap drops removed again with the SAME arguments,
    /// rebuilt in both clear paths. A plain var read on main; the
    /// Destinations window never observes this object — `DestinationsStore`
    /// is told after every mutation and publishes at ≤ 1 Hz while open.
    private var destinations = DestinationIndex()
    var destinationIndex: DestinationIndex { destinations }

    /// How many rows D8 can hide (client-cancelled aborts) in `sessions` and
    /// in each `sessionsByHost` list, kept with the same discipline as the
    /// indexes above. While a list holds none — or the setting shows them —
    /// the unfiltered traffic list shares the array (copy-on-write, O(1))
    /// instead of copying up to 5,000 rows every 150 ms flush: that copy
    /// (`initializeWithCopy for SessionCodable`) is what pegged main in the
    /// 2026-09-06 hang. Also what the sidebar badges subtract, so a badge
    /// counts the rows the list shows. The two lists are counted apart
    /// because they are capped apart (a host's list can keep rows the global
    /// cap has already dropped).
    private var hideableInSessions = 0
    private var hideableByHost: [String: Int] = [:]

    private static func isHideable(_ session: SessionCodable) -> Bool {
        session.isHiddenFromTraffic(showCancelled: false)
    }

    /// The rows the traffic list shows for a host ("All traffic" or nil for
    /// every host) — the sidebar badge's number.
    func visibleRequestCount(host: String?, showCancelled: Bool) -> Int {
        if let host, host != "All traffic" {
            let total = sessionsByHost[host]?.count ?? 0
            return showCancelled ? total : max(0, total - (hideableByHost[host] ?? 0))
        }
        return showCancelled ? sessions.count : max(0, sessions.count - hideableInSessions)
    }

    private func adjustHideable(byHost host: String, _ delta: Int) {
        let next = (hideableByHost[host] ?? 0) + delta
        hideableByHost[host] = next > 0 ? next : nil
    }

    // The search filter (free text + host chips) lives on
    // `TrafficSearchState`, so the toolbar's field can observe it without
    // observing this object's per-flush session publishes; `init` subscribes.
    private var cancellables = Set<AnyCancellable>()
    /// Captured sessions are BATCHED before touching @Published state.
    ///
    /// Doing it per-request hung the app under real browsing load: each session
    /// meant `sessions.insert(at: 0)` (an O(n) memmove of a struct that carries
    /// whole request/response bodies), the same again for `sessionsByHost`, a
    /// full re-filter, and a Combine publish for each — all on the main thread.
    /// A 40-second beachball was reproducible just by browsing (hang report
    /// 2026-09-06: main thread 100% busy in swift_arrayInitWithCopy /
    /// PublishedSubject.send, 383 MB footprint).
    private let ingestQueue = DispatchQueue(label: "com.oloapps.ReqRes.session-ingest")
    /// Every message from the extension that changes the table — final rows
    /// AND live-row messages — in arrival order, until the next flush.
    private var pendingMessages: [LiveIngestMessage<SessionCodable>] = []
    private var flushScheduled = false
    /// Live rows (protocol-engine doc §S6). Confined to `ingestQueue`: it turns
    /// the batch into table operations off main, so the main thread only
    /// applies them.
    private var ledger = LiveRowLedger<SessionCodable>()
    private var sweepScheduled = false
    /// The app clock the ledger measures silence with (monotonic).
    var liveClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Main thread: rows still in flight, their models (what a live cell and
    /// the detail pane observe), and rows that ended without a final.
    private var inFlight = Set<UUID>()
    private var liveModels: [UUID: LiveRowModel] = [:]
    private var endedRows: [UUID: LiveEndedRow] = [:]
    /// Row ids whose content changed IN PLACE this flush (a final replacing
    /// its live row, a live snapshot gaining its response head, a row
    /// ending). The detail pane holds a copy of its row; this tells it to
    /// take the new one. Not `@Published`: nothing else should re-render.
    let rowsChangedInPlace = PassthroughSubject<Set<UUID>, Never>()

    #if DEBUG
    /// The live-load probe's instrument: main-thread time spent applying
    /// flushes (seconds), and the longest single apply.
    private(set) var applyBusySeconds: Double = 0
    private(set) var applyLongestSeconds: Double = 0
    private(set) var applyCount = 0
    #endif

    /// How long captured sessions may wait before appearing. Small enough to feel
    /// live, large enough that a burst costs one main-thread pass instead of hundreds.
    private static let flushInterval: DispatchTimeInterval = .milliseconds(150)
    /// How often in-flight rows are checked for staleness while any exist.
    private static let staleSweepInterval: DispatchTimeInterval = .seconds(15)

    /// Upper bound on retained sessions. Without it, memory grows without limit
    /// for as long as capture runs.
    static let maxRetainedSessions = 5_000

    init() {
        TrafficSearchState.shared.$filter
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFilteredSessions(selectedHost: AppState.shared.selectedHost)
            }
            .store(in: &cancellables)
        TrafficSearchState.shared.suggestionSource = { [weak self] in self?.searchableHosts() ?? [] }
        TrafficSearchState.shared.appSuggestionSource = { [weak self] in self?.searchableApps() ?? [] }
        TrafficSearchState.shared.pidSuggestionSource = { [weak self] apps in self?.pidCandidates(restrictedTo: apps) ?? [] }
        TrafficSearchState.shared.countrySuggestionSource = { [weak self] in self?.countrySuggestions() ?? [] }
    }

    // MARK: - Attribution index (UX spec §1.7)

    /// Display names for the `app:` suggestions, busiest first, then
    /// `ProcessIdentity.unknownLabel` last when any session has no name.
    func searchableApps() -> [String] {
        index.searchableApps()
    }

    /// The identity behind an EXACT display name, case-insensitively — what an
    /// `app:` chip draws its icon from. Nil for "Unknown" and for a substring.
    func identity(forDisplayName name: String) -> ProcessIdentity? {
        index.identity(forDisplayName: name)
    }

    func attributionEntry(forDisplayName name: String) -> AppIndexEntry? {
        index.entry(forDisplayName: name)
    }

    /// Process ids for the `pid:` suggestions, busiest first, limited to the
    /// apps the committed `app:` chips match when there are any.
    func pidCandidates(restrictedTo apps: [String]) -> [(pid: Int, app: String)] {
        index.pidCandidates(restrictedTo: apps)
    }

    /// Executables that are not app bundles — what Settings ▸ Capture lists
    /// as having reached ReqRes from a terminal in this capture.
    func commandLineTools() -> [(name: String, processes: Int)] {
        index.commandLineTools()
    }

    // MARK: - Destination index (destination-map UX spec §1.7)

    /// Rows for the search panel after `country:`: every destination seen,
    /// busiest first with Unknown last (`DestinationIndex.sorted()`'s rule),
    /// each with its title and request count.
    func countrySuggestions() -> [(token: String, title: String, requests: Int)] {
        destinations.sorted().map { entry in
            (token: entry.destination.token, title: CountryPresentation.title(for: entry.destination), requests: entry.requests)
        }
    }

    /// Where a session went, through the resolver's address cache — a
    /// dictionary hit per row after the first sight of an address. Main
    /// thread: every caller below is inside a main-queue block.
    private func destination(of session: SessionCodable) -> TrafficDestination {
        MainActor.assumeIsolated { DestinationResolver.shared.destination(for: session) }
    }

    /// A request that failed before connecting went nowhere, so it is no
    /// destination — not even Unknown (protocol PRD 3.4). Every add, remove
    /// and rebuild asks the same question, so the index stays exact.
    private func addDestination(of session: SessionCodable) {
        guard !session.neverConnected else { return }
        destinations.add(destination: destination(of: session), host: session.host,
                         bytes: session.transferredBytes, app: session.processIdentity.displayName)
    }

    /// The exact inverse of `addDestination`, with the same arguments.
    private func removeDestination(of session: SessionCodable) {
        guard !session.neverConnected else { return }
        destinations.remove(destination: destination(of: session), host: session.host,
                            bytes: session.transferredBytes, app: session.processIdentity.displayName)
    }

    /// Rebuilt from whatever `sessions` still holds, exactly as `index` is in
    /// the clear paths: empty for "All traffic", unchanged in substance for
    /// one host. Cached lookups, so this is a pass over the array, not a
    /// second resolution.
    private func rebuildDestinations() {
        var rebuilt = DestinationIndex()
        for session in sessions where !session.neverConnected {
            rebuilt.add(destination: destination(of: session), host: session.host,
                        bytes: session.transferredBytes, app: session.processIdentity.displayName)
        }
        destinations = rebuilt
    }

    /// Tells the window's store, which coalesces and drops while closed.
    private func publishDestinations() {
        let snapshot = destinations
        MainActor.assumeIsolated { DestinationsStore.shared.indexDidChange(snapshot) }
    }

    /// Hosts the search field may offer after `host:`: those seen in captured
    /// traffic, busiest first, then the sidebar's host filters.
    func searchableHosts() -> [String] {
        var ordered = sessionsByHost
            .filter { !$0.value.isEmpty }
            .sorted { $0.value.count > $1.value.count }
            .map(\.key)
        var seen = Set(ordered.map { $0.lowercased() })
        for host in AppState.shared.hosts where host.host != "All traffic" && !seen.contains(host.host.lowercased()) {
            ordered.append(host.host)
            seen.insert(host.host.lowercased())
        }
        return ordered
    }

    func addSession(session: SessionCodable) {
        enqueue(.final(session))
    }

    /// `session_started`: an exchange still open 250 ms after its request,
    /// or, at its response head, one whose type is a stream by definition
    /// (SSE, NDJSON, gRPC, gRPC-Web, Connect streaming,
    /// multipart/x-mixed-replace).
    func addLiveStarted(_ message: LiveSessionStarted) {
        enqueue(.started(LiveStartInput(message)))
    }

    /// `session_progress`, including `withdrawn`.
    func addLiveProgress(_ message: LiveSessionProgress) {
        enqueue(.progress(LiveProgressInput(message)))
    }

    /// Everything goes through ONE queue and ONE 150 ms flush — a live
    /// message never costs a main-thread pass of its own (the 2026-09-06
    /// hang class).
    func enqueue(_ message: LiveIngestMessage<SessionCodable>) {
        ingestQueue.async { [weak self] in
            guard let self else { return }
            self.pendingMessages.append(message)
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.ingestQueue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
                self?.flushPendingSessions()
            }
        }
    }

    /// Runs the batch through the ledger (on `ingestQueue`) and hands the
    /// resulting operations to main in ONE block.
    private func flushPendingSessions() {
        let operations = drainPendingOperations()
        scheduleStaleSweepIfNeeded()
        apply(operations)
    }

    /// `ingestQueue` only.
    private func drainPendingOperations() -> [LiveRowOperation<SessionCodable>] {
        let batch = pendingMessages
        pendingMessages.removeAll(keepingCapacity: true)
        flushScheduled = false
        guard !batch.isEmpty else { return [] }
        let now = liveClock()
        var operations: [LiveRowOperation<SessionCodable>] = []
        operations.reserveCapacity(batch.count)
        for message in batch {
            operations.append(contentsOf: ledger.ingest(message, now: now))
        }
        return LiveRowOperation.coalesced(operations)
    }

    /// `ingestQueue` only. While anything is in flight, look every 15 s for a
    /// row nothing has been heard about for longer than the core's in-flight
    /// idle limit plus a margin — the core withdraws on every path it knows
    /// (C10.2), but the app is the last line.
    private func scheduleStaleSweepIfNeeded() {
        guard ledger.inFlightCount > 0, !sweepScheduled else { return }
        sweepScheduled = true
        ingestQueue.asyncAfter(deadline: .now() + Self.staleSweepInterval) { [weak self] in
            guard let self else { return }
            self.sweepScheduled = false
            let ended = self.ledger.sweep(now: self.liveClock())
            self.apply(ended)
            self.scheduleStaleSweepIfNeeded()
        }
    }

    /// Capture stopped: every in-flight row ends as it stands. Whatever the
    /// extension already sent is applied first, so a final that beat the stop
    /// is never mistaken for a lost one.
    func endAllInFlight(reason: LiveEndReason = .captureStopped) {
        ingestQueue.async { [weak self] in
            guard let self else { return }
            var operations = self.drainPendingOperations()
            operations.append(contentsOf: self.ledger.endAll(reason: reason))
            self.apply(operations)
        }
    }

    #if DEBUG
    /// The render probe's "capture stopped while this one was open", for ONE
    /// exchange, through the real ledger and apply.
    func endForProbe(exchange: UUID, reason: LiveEndReason) {
        ingestQueue.async { [weak self] in
            guard let self else { return }
            var operations = self.drainPendingOperations()
            operations.append(contentsOf: self.ledger.end(exchangeID: exchange, reason: reason))
            self.apply(operations)
        }
    }
    #endif

    // MARK: - Live rows, read on main

    /// The live model of an in-flight row, or nil. Main thread.
    func liveModel(for rowID: UUID) -> LiveRowModel? { liveModels[rowID] }

    /// How a row that stopped being live without its final ended. Main thread.
    func endedRow(_ rowID: UUID) -> LiveEndedRow? { endedRows[rowID] }

    func isInFlight(_ rowID: UUID) -> Bool { inFlight.contains(rowID) }

    /// In flight, or ended without its final row: either way the row is a
    /// live snapshot, not a finished exchange (`LiveRowKeeping`). Main thread.
    func isLiveSnapshot(_ rowID: UUID) -> Bool { inFlight.contains(rowID) || endedRows[rowID] != nil }

    var inFlightCount: Int { inFlight.count }

    /// What an agent is told about a row's live state (nil for an ordinary
    /// finished row). Main thread.
    func agentLiveState(for session: SessionCodable, now: Date = Date()) -> MCPLiveState? {
        if let model = liveModels[session.id] {
            let start = session.startTime.doubleValue
            let elapsed = start > 0 ? max(0, now.timeIntervalSince1970 - start) : nil
            return MCPLiveState(state: model.state, elapsedSeconds: elapsed)
        }
        if let ended = endedRows[session.id] {
            var state = MCPLiveState(state: ended.lastState, elapsedSeconds: nil)
            state.phase = .ended
            state.endReason = ended.reason
            return state
        }
        return nil
    }

    // MARK: - Applying a flush (main)

    private func apply(_ operations: [LiveRowOperation<SessionCodable>]) {
        guard !operations.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            #if DEBUG
            let started = CFAbsoluteTimeGetCurrent()
            #endif
            self.applyOnMain(operations)
            #if DEBUG
            let spent = CFAbsoluteTimeGetCurrent() - started
            self.applyBusySeconds += spent
            self.applyLongestSeconds = max(self.applyLongestSeconds, spent)
            self.applyCount += 1
            #endif
        }
    }

    /// ONE mutation per published property: `sessions` is copied once (the
    /// local `rows`), changed, and assigned back.
    private func applyOnMain(_ operations: [LiveRowOperation<SessionCodable>]) {
        var rows = sessions
        let report = LiveRowTable.apply(operations, to: &rows, inFlight: &inFlight, cap: Self.maxRetainedSessions)

        // The per-row live models: no table work at all for a progress that
        // carried no new snapshot.
        var changedInPlace = Set<UUID>()
        for operation in operations {
            switch operation {
            case .insertLive(let row, let state, let text):
                guard inFlight.contains(row.id) else { continue }
                liveModels[row.id] = LiveRowModel(state: state, chunks: text)
            case .updateLive(let row, let state, let appended):
                guard let model = liveModels[state.rowID] else { continue }
                if row != nil || model.phase != (state.phase == .waiting ? .waiting : .streaming) {
                    changedInPlace.insert(state.rowID)
                }
                model.update(state, appended: appended)
            case .finalize(let row):
                liveModels[row.id] = nil
                endedRows[row.id] = nil
                changedInPlace.insert(row.id)
            case .remove(let rowID, _):
                liveModels[rowID] = nil
            case .insertFinal:
                break
            case .end(let rowID, _, let reason):
                // A row announced and ended in this same flush never got a
                // model (it was no longer in flight when `.insertLive` came
                // round): the batch's own last state stands in, or it would
                // read as an ordinary finished row — to the table and to an
                // agent's wait.
                if let state = liveModels.removeValue(forKey: rowID)?.state ?? report.endedStates[rowID] {
                    endedRows[rowID] = LiveEndedRow(reason: reason, lastState: state)
                    changedInPlace.insert(rowID)
                }
            }
        }

        // Progress without a new snapshot moved no row: the live models above
        // are all that changed, and each open row's cell observes its own.
        // Republishing `sessions` here re-filtered and re-diffed the whole
        // table up to ~6.7 times a second per live stream (review of S6).
        guard report.changesRows else {
            if !changedInPlace.isEmpty { rowsChangedInPlace.send(changedInPlace) }
            return
        }

        // The indexes follow `sessions` exactly — O(changes), never a rescan.
        for session in report.inserted {
            index.add(session.processIdentity)
            addDestination(of: session)
            if Self.isHideable(session) { hideableInSessions += 1 }
        }
        for (old, new) in report.replaced {
            index.remove(old.processIdentity)
            removeDestination(of: old)
            if Self.isHideable(old) { hideableInSessions -= 1 }
            index.add(new.processIdentity)
            addDestination(of: new)
            if Self.isHideable(new) { hideableInSessions += 1 }
        }
        // A row that left the table takes its WebSocket messages with it.
        WebSocketMessageCenter.shared.forget((report.removed + report.evicted).compactMap(\.exchangeID))
        for session in report.removed + report.evicted {
            index.remove(session.processIdentity)
            removeDestination(of: session)
            if Self.isHideable(session) { hideableInSessions -= 1 }
            liveModels[session.id] = nil
            endedRows[session.id] = nil
        }
        sessions = rows
        publishDestinations()

        // The per-host lists, each capped on its own as before.
        var hosts = Set(report.inserted.map(\.host))
        report.replaced.forEach { hosts.insert($0.old.host); hosts.insert($0.new.host) }
        report.removed.forEach { hosts.insert($0.host) }
        for host in hosts {
            var list = sessionsByHost[host] ?? []
            let change = LiveRowTable.mirror(report, into: &list, belongs: { $0.host == host }, inFlight: inFlight, cap: Self.maxRetainedSessions)
            let delta = change.entered.lazy.filter(Self.isHideable).count - change.left.lazy.filter(Self.isHideable).count
            if delta != 0 { adjustHideable(byHost: host, delta) }
            sessionsByHost[host] = list
        }

        updateFilteredSessions(selectedHost: AppState.shared.selectedHost)
        if !changedInPlace.isEmpty { rowsChangedInPlace.send(changedInPlace) }
    }

    func removeSession(sessionUids: Set<UUID>) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // A deleted row's live messages and final are dropped from now on,
            // never re-inserted (the user removed it on purpose).
            let exchanges = self.sessions.compactMap { sessionUids.contains($0.id) ? $0.exchangeID : nil }
            if !exchanges.isEmpty {
                self.ingestQueue.async { self.ledger.forget(exchangeIDs: exchanges) }
                WebSocketMessageCenter.shared.forget(exchanges)
            }
            for id in sessionUids {
                self.inFlight.remove(id)
                self.liveModels[id] = nil
                self.endedRows[id] = nil
            }

            self.sessions.removeAll {
                if sessionUids.contains($0.id) {
                    let host = $0.host
                    if Self.isHideable($0) { self.hideableInSessions -= 1 }
                    self.sessionsByHost[host, default: []].removeAll {
                        guard sessionUids.contains($0.id) else { return false }
                        if Self.isHideable($0) { self.adjustHideable(byHost: host, -1) }
                        return true
                    }
                    self.index.remove($0.processIdentity)
                    self.removeDestination(of: $0)
                    return true
                }
                return false
            }
            self.publishDestinations()

            self.updateFilteredSessions(selectedHost: AppState.shared.selectedHost)
        }
    }
    
    func updateFilteredSessions(selectedHost: HostCodable?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let filter = TrafficSearchState.shared.filter
        // Naming a process splits its path three ways; with 5,000 rows on
        // every 150 ms flush that is only worth doing when a chip asks for it.
        let needsProcess = !filter.apps.isEmpty || !filter.pids.isEmpty
        // Same rule for the destination: resolved (a cached dictionary hit)
        // only when a `country:` chip asks — nil never satisfies one.
        let needsCountry = !filter.countries.isEmpty
        // And the RPC status: a cached read per row (`RPCStatusCache`), only
        // while a `grpc:` chip asks — nil never satisfies one.
        let needsGRPC = !filter.grpcStatuses.isEmpty
        // And the protocol: a 101's headers are parsed to tell a WebSocket
        // from HTTP/1.1, only while a `proto:` chip asks.
        let needsProto = !filter.protocols.isEmpty
        // D8: client-cancelled aborts are hidden unless Settings ▸ Capture
        // says otherwise. Read once per pass, not per row.
        let showCancelled = CancelledRequestsSetting.showCancelled
        let visible: (SessionCodable) -> Bool = { !$0.isHiddenFromTraffic(showCancelled: showCancelled) }

            if let host = selectedHost?.host, host != "All traffic" {
                if filter.isEmpty {
                    // Shared, not copied, while nothing in it can be hidden.
                    let list = sessionsByHost[host] ?? []
                    filteredSessions = showCancelled || (hideableByHost[host] ?? 0) == 0 ? list : list.filter(visible)
                } else {
                    // Filter by host
                    filteredSessions = sessionsByHost[host]?.filter { session in
                        guard visible(session) else { return false }
                        // Apply search if there's any text entered
                        let identity = needsProcess ? session.processIdentity : nil
                        return filter.matches(host: session.host, url: session.fullUrl, method: session.method, status: session.rspStatus,
                                       app: identity?.displayName, pid: identity?.pid,
                                       country: needsCountry ? self.destination(of: session).token : nil,
                                       outcome: session.outcomeToken,
                                       grpcStatus: needsGRPC ? session.rpcStatus?.code : nil,
                                       proto: needsProto ? session.sessionProtocol?.token : nil)
                    } ?? []
                }
            } else {
                if filter.isEmpty {
                    filteredSessions = showCancelled || hideableInSessions == 0 ? sessions : sessions.filter(visible)
                } else {
                    // Show all sessions, filtered by search text
                    filteredSessions = sessions.filter { session in
                        guard visible(session) else { return false }
                        let identity = needsProcess ? session.processIdentity : nil
                        return filter.matches(host: session.host, url: session.fullUrl, method: session.method, status: session.rspStatus,
                                       app: identity?.displayName, pid: identity?.pid,
                                       country: needsCountry ? self.destination(of: session).token : nil,
                                       outcome: session.outcomeToken,
                                       grpcStatus: needsGRPC ? session.rpcStatus?.code : nil,
                                       proto: needsProto ? session.sessionProtocol?.token : nil)
                    }
                }
            }
            
            // Update the subtitle reflecting the filtered session count
            updateSessionsSubtitle()
        }
        
    }
    
    func clearAllSessionsForGroup() {
        DispatchQueue.main.async { [weak self] in
              guard let self = self else { return }
            if let host = AppState.shared.selectedHost?.host {
                if host == "All traffic" {
                    // Every row's exchange, not just the ones with messages
                    // so far: a quiet socket's first batch after the clear
                    // must not create a conversation no row shows. Rows
                    // still in the ledger are forgotten in `forgetAllLive`.
                    WebSocketMessageCenter.shared.removeAll(forgetting: sessions.compactMap(\.exchangeID))
                    sessions = []
                    sessionsByHost = [:]
                    hideableInSessions = 0
                    hideableByHost = [:]
                    forgetAllLive()
                } else {
                    sessionsByHost[host] = []
                    hideableByHost[host] = nil
                }
                // Rebuilt from what `sessions` still holds: empty for "All
                // traffic", unchanged in substance for one host (this path
                // leaves `sessions` alone), and consistent either way.
                index = ProcessAttributionIndex(sessions.lazy.map(\.processIdentity))
                rebuildDestinations()
                publishDestinations()
                filteredSessions = []
                updateSessionsSubtitle()
            }
      }
    }
    
    /// Drops every captured session, whatever host is selected. Main thread.
    /// Returns how many were dropped — including the ones still buffered off
    /// main, which would otherwise be flushed in 150ms and reappear as if the
    /// clear had not happened.
    @discardableResult
    func clearAllSessions() -> Int {
        var count = sessions.count
        // Every exchange this clear drops — the table's rows, the buffered
        // messages and the ledger's — is forgotten by the ledger AND the
        // message center, so nothing for them comes back: not a row (a
        // buffered `started` would otherwise return with its final) and not
        // a conversation no row shows.
        var dropped = sessions.compactMap(\.exchangeID)
        ingestQueue.sync {
            count += pendingMessages.reduce(0) { total, message in
                if case .final = message { return total + 1 }
                return total
            }
            let buffered = pendingMessages.compactMap(\.exchangeID)
            pendingMessages.removeAll()
            let exchanges = ledger.trackedExchangeIDs + buffered
            ledger.forget(exchangeIDs: exchanges)
            dropped += exchanges
        }
        inFlight.removeAll()
        liveModels.removeAll()
        endedRows.removeAll()
        WebSocketMessageCenter.shared.removeAll(forgetting: dropped)
        sessions = []
        sessionsByHost = [:]
        hideableInSessions = 0
        hideableByHost = [:]
        index = ProcessAttributionIndex()
        destinations = DestinationIndex()
        publishDestinations()
        filteredSessions = []
        updateSessionsSubtitle()
        return count
    }

    /// Main thread: drops every live row's state and tells the ledger, so
    /// their later messages and finals are dropped rather than re-inserted.
    private func forgetAllLive() {
        inFlight.removeAll()
        liveModels.removeAll()
        endedRows.removeAll()
        ingestQueue.async { [weak self] in
            guard let self else { return }
            let tracked = self.ledger.trackedExchangeIDs
            self.ledger.forget(exchangeIDs: tracked)
            WebSocketMessageCenter.shared.forget(tracked)
        }
    }

    func updateSessionsSubtitle() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sessionsSubtitle = "\(self.filteredSessions.count) \(self.filteredSessions.count == 1 ? "request" : "requests" )"
        }
    }
    
}
