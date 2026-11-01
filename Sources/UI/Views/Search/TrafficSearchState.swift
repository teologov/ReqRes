//
//  TrafficSearchState.swift
//  ReqRes
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

import Combine
import Foundation
import MCPKit
import Utils

/// The committed search filter, published on its own object.
///
/// The toolbar's search field observes THIS and not `SessionState`: the
/// latter publishes its session arrays on every 150ms capture flush, and a
/// toolbar item that re-rendered on each of those would be exactly the
/// rebuild storm snipperapp's field was built to survive. `SessionState`
/// subscribes to `$filter` and re-filters; the field only edits it.
///
/// Main-thread only, like the field that drives it.
final class TrafficSearchState: ObservableObject {
    static let shared = TrafficSearchState()

    @Published private(set) var filter = TrafficSearchFilter()

    /// Hosts the field may suggest after `host:`, most relevant first.
    /// `SessionState` supplies the hosts seen in captured traffic (by request
    /// count) followed by the sidebar's host filters.
    var suggestionSource: () -> [String] = { [] }

    /// Apps the field may suggest after `app:`, busiest first, with
    /// `TrafficSearchAppMatch.unknown` last when any session has no name.
    /// Supplied by `SessionState` once attribution lands in the flush; empty
    /// until then, which makes `app:` offer nothing rather than something wrong.
    var appSuggestionSource: () -> [String] = { [] }

    /// Process ids the field may suggest after `pid:`, busiest first, each
    /// with the display name of its app. The argument is the `app:` chips
    /// already committed: with any, only their processes are offered; with
    /// none, every process the index knows. Supplied by `SessionState`
    /// (`pidCandidates(restrictedTo:)`); empty until then.
    var pidSuggestionSource: ([String]) -> [(pid: Int, app: String)] = { _ in [] }

    /// Destinations the field may suggest after `country:` (destination-map
    /// UX spec §5.3): every destination seen in the retained traffic as
    /// `(token, title, requests)` — `("US", "United States", 1204)`,
    /// `("mac", "This Mac", 412)` — busiest first, Unknown last. Supplied by
    /// `SessionState` (`countrySuggestions()`) from its `DestinationIndex`;
    /// empty until then, so `country:` offers nothing rather than something
    /// wrong. The row shows the title and commits the token.
    var countrySuggestionSource: () -> [(token: String, title: String, requests: Int)] = { [] }

    /// What the session index holds for an app the panel or a chip names:
    /// its identity (for the icon) and how many distinct processes made its
    /// requests (for the "3 processes" detail). Nil for a name the index has
    /// not seen — a seeded suggestion, or a chip typed by hand — and the
    /// caller falls back to the kind's symbol rather than guessing.
    ///
    /// Read on demand on the main thread, never observed: the index is a plain
    /// `var` on `SessionState` for exactly that reason. A closure so the
    /// headless probe can seed it the way it seeds the sources.
    var appLookup: (String) -> (identity: ProcessIdentity, processes: Int)? = { name in
        guard let entry = SessionState.shared.attributionEntry(forDisplayName: name) else { return nil }
        return (entry.identity, entry.requestsByPid.count)
    }

    /// The display name of the app the index attributes a pid to, for a
    /// `pid:` chip's icon and its "claude · pid 9437" tooltip. Nil when no
    /// captured request came from that pid.
    var appLookupByPid: (Int) -> String? = { pid in
        SessionState.shared.attributionIndex.values
            .first { $0.requestsByPid[pid] != nil }?
            .identity.displayName
    }

    /// Every write is guarded so an unchanged filter publishes nothing —
    /// each publish re-filters the whole session list.
    func updateFreeText(_ text: String) {
        guard filter.freeText != text else { return }
        filter.freeText = text
    }

    func addToken(_ token: TrafficSearchToken) {
        var next = filter
        next.addToken(token)
        if next != filter { filter = next }
    }

    func removeToken(_ token: TrafficSearchToken) {
        var next = filter
        next.removeToken(token)
        if next != filter { filter = next }
    }

    func clear() {
        guard !filter.isEmpty else { return }
        filter.clear()
    }
}
