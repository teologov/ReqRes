//
//  ProcessAttributionIndex.swift
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
//  Which apps and processes the captured traffic came from (process-attribution
//  UX spec §1.7), kept beside `SessionState.sessions` and maintained in the
//  same flush that appends to it. The search field's `app:` and `pid:`
//  suggestions, the Settings ▸ Capture status line and the agent footer's
//  "Show its traffic" all ask this instead of scanning 5,000 sessions on the
//  main thread — the scan is what made the 2026-09-06 hang.
//
//  Pure: Foundation, `ProcessIdentity` and the search's app-match rule only.
//  No AppKit, no SessionState, so it compiles and runs on its own.
//

import Foundation
import MCPKit
import Utils

/// One app in the index — everything captured under one display name — and
/// how many requests each of its processes made.
struct AppIndexEntry: Equatable {
    /// The first identity seen under this display name. `ProcessIconCache`
    /// keys on its path, so this is what the suggestions draw their icon
    /// from; a second pid of the same app shares the icon anyway.
    let identity: ProcessIdentity
    /// Requests per process id. A session the extension named but could not
    /// number counts in `requests` and nowhere here.
    var requestsByPid: [Int: Int]
    var requests: Int
}

/// The index itself. Keys are the display name lower-cased PLUS whether the
/// identity is an app bundle or a bare executable: Claude Desktop ("Claude",
/// Claude.app) and the claude CLI ("claude", /usr/local/bin/claude) are two
/// entries, or the Settings line would count the Desktop helper as a terminal
/// tool — or miss both CLI processes — depending on which arrived first.
/// `identity(forDisplayName:)` stays the case-insensitive lookup the `app:`
/// chip needs; when both spellings exist it prefers the exact one typed.
struct ProcessAttributionIndex: Equatable {
    private(set) var entries: [String: AppIndexEntry] = [:]
    /// Sessions whose process could not be named. Not an entry: "Unknown" is
    /// the label the table prints, not a name a process has, and it goes last
    /// in the suggestions whatever its count.
    private(set) var unknownCount = 0

    init() {}

    init<S: Sequence>(_ identities: S) where S.Element == ProcessIdentity {
        for identity in identities { add(identity) }
    }

    /// The name half of a key — what `identity(forDisplayName:)` compares.
    static func key(for displayName: String) -> String {
        displayName.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The whole key: name half plus the kind, so a bundle and an executable
    /// that happen to share a name never merge. Nil for an unnamed identity.
    static func key(for identity: ProcessIdentity) -> String? {
        identity.displayName.map { Self.key(for: $0) + (identity.bundlePath == nil ? "\u{1F}exe" : "\u{1F}app") }
    }

    // MARK: - Maintenance (O(1) each; the flush calls it per session in the batch)

    mutating func add(_ identity: ProcessIdentity) {
        guard let key = Self.key(for: identity) else {
            unknownCount += 1
            return
        }
        var entry = entries[key] ?? AppIndexEntry(identity: identity, requestsByPid: [:], requests: 0)
        entry.requests += 1
        if let pid = identity.pid {
            entry.requestsByPid[pid, default: 0] += 1
        }
        entries[key] = entry
    }

    /// The exact inverse of `add`, so trimming the retained sessions past
    /// their cap and deleting rows keep the counts true instead of drifting
    /// upward until the next clear. An entry whose last request leaves is
    /// removed; a pid whose last request leaves is removed from its entry.
    mutating func remove(_ identity: ProcessIdentity) {
        guard let key = Self.key(for: identity) else {
            unknownCount = max(0, unknownCount - 1)
            return
        }
        guard var entry = entries[key] else { return }
        entry.requests -= 1
        if let pid = identity.pid, let count = entry.requestsByPid[pid] {
            entry.requestsByPid[pid] = count > 1 ? count - 1 : nil
        }
        entries[key] = entry.requests > 0 ? entry : nil
    }

    // MARK: - Queries (spec §1.7)

    /// Display names, busiest first, then `ProcessIdentity.unknownLabel` last
    /// when any session has no name. Ties fall back to the name so the order
    /// is stable between two flushes that changed nothing.
    func searchableApps() -> [String] {
        var seen = Set<String>()
        var names = sortedEntries().compactMap(\.identity.displayName).filter { seen.insert($0).inserted }
        if unknownCount > 0 {
            names.append(ProcessIdentity.unknownLabel)
        }
        return names
    }

    /// The identity behind an EXACT display name, case-insensitively — what an
    /// `app:` chip uses to show the app's real icon. Nil for "Unknown" and for
    /// a substring: a chip reading `app:cl` matches claude in the filter but
    /// names no single app to draw.
    func identity(forDisplayName name: String) -> ProcessIdentity? {
        entry(forDisplayName: name)?.identity
    }

    /// The entry behind a display name. Two entries can share the name half
    /// of their key (an app and an executable both called claude); the one
    /// spelled exactly as typed wins, then the busier.
    func entry(forDisplayName name: String) -> AppIndexEntry? {
        let wanted = Self.key(for: name)
        let matches = entries.values.filter { $0.identity.displayName.map(Self.key(for:)) == wanted }
        if matches.count <= 1 { return matches.first }
        let typed = name.trimmingCharacters(in: .whitespaces)
        if let exact = matches.first(where: { $0.identity.displayName == typed }) { return exact }
        return matches.max { $0.requests < $1.requests }
    }

    /// Every process id in the index, busiest first, each with the app it
    /// belongs to. `apps` are the committed `app:` chips: when there are any,
    /// only processes of apps those chips match are offered — matched by the
    /// filter's own substring rule, so `pid:` never suggests a process the
    /// chips have already filtered out. Empty means every app.
    func pidCandidates(restrictedTo apps: [String]) -> [(pid: Int, app: String)] {
        var rows: [(pid: Int, app: String, requests: Int)] = []
        for entry in entries.values {
            guard let name = entry.identity.displayName else { continue }
            if !apps.isEmpty, !apps.contains(where: { TrafficSearchAppMatch.matches($0, appName: name) }) {
                continue
            }
            for (pid, requests) in entry.requestsByPid {
                rows.append((pid: pid, app: name, requests: requests))
            }
        }
        return rows
            .sorted { lhs, rhs in
                if lhs.requests != rhs.requests { return lhs.requests > rhs.requests }
                return lhs.pid < rhs.pid
            }
            .map { (pid: $0.pid, app: $0.app) }
    }

    /// Apps that are not app bundles — the executables a terminal runs — for
    /// Settings ▸ Capture's "Reached ReqRes from a terminal in this capture"
    /// line. A well-known system service (WebKit Networking, Background
    /// Transfers) is also no bundle, but nobody ran it from a terminal, so it
    /// is left out; the errata's table arrived after §1.7 was written and the
    /// line is worded as what reached ReqRes from a terminal.
    ///
    /// `processes` is at least 1: an entry exists because something made a
    /// request, even when the extension could not number it.
    func commandLineTools() -> [(name: String, processes: Int)] {
        sortedEntries()
            .filter { $0.identity.bundlePath == nil && !$0.identity.isSystemService }
            .compactMap { entry in
                entry.identity.displayName.map { (name: $0, processes: max(entry.requestsByPid.count, 1)) }
            }
    }

    /// Busiest first, then by name — a dictionary's order is not one.
    private func sortedEntries() -> [AppIndexEntry] {
        entries.values.sorted { lhs, rhs in
            if lhs.requests != rhs.requests { return lhs.requests > rhs.requests }
            let left = lhs.identity.displayName ?? ""
            let right = rhs.identity.displayName ?? ""
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }
}
