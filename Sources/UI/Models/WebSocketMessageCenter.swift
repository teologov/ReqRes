//
//  WebSocketMessageCenter.swift
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
//  WebSocket messages in the app (protocol-engine doc §S7). The core's tap
//  sends `websocket_messages` batches (doc §C11.3); they land here, off the
//  main thread, in ONE `SocketMessageStore` (MCPKit: D10's ring and the
//  app-wide bound) behind a lock — the bridge reads it from its own queue
//  without a main-thread hop. The main thread hears about it at most once
//  per 150 ms (the traffic table's flush interval), as a set of changed
//  connections, and ONLY the Messages tab of an open connection listens: a
//  batch never touches `SessionState` or re-renders the traffic table.
//

import Combine
import Foundation
import MCPKit

final class WebSocketMessageCenter: @unchecked Sendable {
    static let shared = WebSocketMessageCenter()

    private let lock = NSLock()
    private var store = SocketMessageStore()
    private var dirty = Set<UUID>()
    private var notifyScheduled = false
    private static let notifyInterval: DispatchTimeInterval = .milliseconds(150)

    /// Main thread: the connections whose messages changed since the last
    /// notification. Not `@Published`: nothing but an open Messages tab
    /// should re-render.
    let changed = PassthroughSubject<Set<UUID>, Never>()

    /// Any thread (the bus's event loop).
    func ingest(_ batch: SocketMessageBatch) {
        lock.lock()
        let changedAnything = store.ingest(batch)
        if changedAnything { dirty.insert(batch.exchangeID) }
        let schedule = changedAnything && !notifyScheduled
        if schedule { notifyScheduled = true }
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.notifyInterval) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        let ids = dirty
        dirty.removeAll()
        notifyScheduled = false
        lock.unlock()
        if !ids.isEmpty { changed.send(ids) }
    }

    /// A copy of one connection's log (a value type: safe to read anywhere).
    func log(for exchangeID: UUID) -> SocketMessageLog? {
        lock.lock()
        defer { lock.unlock() }
        return store.log(for: exchangeID)
    }

    func messages(afterOrdinal ordinal: Int64, limit: Int) -> (latest: Int64, found: [(exchangeID: UUID, stored: StoredSocketMessage)]) {
        lock.lock()
        defer { lock.unlock() }
        return (store.latestOrdinal, store.messages(afterOrdinal: ordinal, limit: limit))
    }

    var latestOrdinal: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return store.latestOrdinal
    }

    /// The rows left the table (deleted, evicted, cleared): their messages
    /// go, and later batches for them are dropped.
    func forget(_ exchangeIDs: [UUID]) {
        guard !exchangeIDs.isEmpty else { return }
        lock.lock()
        store.forget(exchangeIDs)
        lock.unlock()
    }

    /// Clear: every conversation goes, and `exchangeIDs` (rows the clear
    /// dropped that may have no log yet) stay forgotten too.
    func removeAll(forgetting exchangeIDs: [UUID] = []) {
        lock.lock()
        store.removeAll(forgetting: exchangeIDs)
        dirty.removeAll()
        lock.unlock()
    }
}

/// One open Messages tab's view of its connection. Pulls the log when the
/// center says its connection changed — never more often than the center
/// notifies (≤ 1 per 150 ms) — and publishes once per pull. The search is
/// applied HERE, once per pull or query change, not in the view's body (which
/// reads the list several times per render).
@MainActor
final class WebSocketConversationModel: ObservableObject {
    @Published private(set) var log: SocketMessageLog?
    @Published private(set) var items: [SocketMessagePresentation.Item] = []
    /// `items` under the current search.
    @Published private(set) var shownItems: [SocketMessagePresentation.Item] = []
    /// Bumped on every pull that changed the log. The list follows the end on
    /// THIS, not on a count: once the ring is full the count stops changing
    /// while messages keep arriving.
    @Published private(set) var revision = 0

    let exchangeID: UUID?
    /// Remembers each message's answer for the current query, so a pull
    /// tests only the messages it added (`IncrementalSearch`).
    private var search: SocketMessagePresentation.IncrementalSearch
    private var cancellable: AnyCancellable?

    init(exchangeID: UUID?, query: String = "") {
        self.exchangeID = exchangeID
        self.search = SocketMessagePresentation.IncrementalSearch(query: query)
        reload()
        guard let exchangeID else { return }
        cancellable = WebSocketMessageCenter.shared.changed
            .filter { $0.contains(exchangeID) }
            .sink { [weak self] _ in self?.reload() }
    }

    func setQuery(_ newQuery: String) {
        let before = search.query
        search.setQuery(newQuery)
        guard search.query != before else { return }
        shownItems = search.shown(items)
    }

    func reload() {
        guard let exchangeID, let fresh = WebSocketMessageCenter.shared.log(for: exchangeID) else { return }
        guard fresh != log else { return }
        log = fresh
        items = SocketMessagePresentation.items(fresh.messages, close: fresh.close)
        shownItems = search.shown(items)
        revision &+= 1
    }
}
