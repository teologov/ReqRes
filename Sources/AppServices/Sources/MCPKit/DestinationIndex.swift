//
//  DestinationIndex.swift
//  AppServices
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
//  Per-destination aggregates over the retained sessions (destination-map UX
//  spec §1.4), maintained in `SessionState`'s flush beside
//  `ProcessAttributionIndex`: every arrival added, every row the cap drops
//  removed again with the same arguments — O(batch + dropped), never a rescan
//  of the 5,000 retained. Pure, so the ordering rules that decide what the
//  window and the agent show first are stated here and tested here.
//

import Foundation

/// One destination's totals and the hosts and apps behind them.
public struct DestinationEntry: Equatable, Sendable, Identifiable {
    public let destination: TrafficDestination
    public var id: TrafficDestination { destination }
    public var requests: Int
    public var bytes: Int64
    /// `session.host` → requests.
    public var hostsByCount: [String: Int]
    /// `ProcessIdentity.displayName` → requests; an unattributed session is
    /// counted under `DestinationIndex.unknownAppKey`.
    public var appsByCount: [String: Int]

    public init(destination: TrafficDestination, requests: Int = 0, bytes: Int64 = 0, hostsByCount: [String: Int] = [:], appsByCount: [String: Int] = [:]) {
        self.destination = destination
        self.requests = requests
        self.bytes = bytes
        self.hostsByCount = hostsByCount
        self.appsByCount = appsByCount
    }

    public var hostCount: Int { hostsByCount.count }
    public var appCount: Int { appsByCount.count }

    /// Busiest first, then by name, so two hosts with equal counts keep one
    /// order from one render to the next.
    public func topHosts(_ limit: Int = 5) -> [(name: String, requests: Int)] {
        DestinationIndex.rankedHosts(hostsByCount, limit: limit)
    }

    /// Busiest first, then by name; the nil (unattributed) bucket LAST
    /// whatever its count — a placeholder never outranks a name.
    public func topApps(_ limit: Int = 5) -> [(name: String?, requests: Int)] {
        DestinationIndex.rankedApps(appsByCount, limit: limit)
    }
}

/// Every destination seen in the retained sessions, with totals.
public struct DestinationIndex: Equatable, Sendable {
    /// The key an unattributed session's app is counted under. A control
    /// character, so no real process name can collide with it.
    public static let unknownAppKey = "\u{1F}unknown"

    public private(set) var entries: [TrafficDestination: DestinationEntry]
    public private(set) var totalRequests: Int
    public private(set) var totalBytes: Int64

    public init() {
        entries = [:]
        totalRequests = 0
        totalBytes = 0
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func add(destination: TrafficDestination, host: String, bytes: Int64, app: String?) {
        var entry = entries[destination] ?? DestinationEntry(destination: destination)
        entry.requests += 1
        entry.bytes += bytes
        entry.hostsByCount[host, default: 0] += 1
        entry.appsByCount[Self.appKey(app), default: 0] += 1
        entries[destination] = entry
        totalRequests += 1
        totalBytes += bytes
    }

    /// The exact inverse of `add` with the same arguments. An entry whose
    /// last request leaves is removed; a removal that has no matching add is
    /// ignored rather than driving a count negative.
    public mutating func remove(destination: TrafficDestination, host: String, bytes: Int64, app: String?) {
        guard var entry = entries[destination], entry.requests > 0 else { return }
        entry.requests -= 1
        entry.bytes -= bytes
        Self.decrement(&entry.hostsByCount, host)
        Self.decrement(&entry.appsByCount, Self.appKey(app))
        if entry.requests == 0 {
            entries[destination] = nil
        } else {
            entries[destination] = entry
        }
        totalRequests = max(0, totalRequests - 1)
        totalBytes -= bytes
    }

    /// Requests desc, bytes desc, token asc — and `.unknown` LAST whatever
    /// its count (the `app:` panel's rule for its own placeholder): a row
    /// that means "could not be placed" never heads the list.
    public func sorted() -> [DestinationEntry] {
        entries.values.sorted { lhs, rhs in
            if (lhs.destination == .unknown) != (rhs.destination == .unknown) {
                return rhs.destination == .unknown
            }
            if lhs.requests != rhs.requests { return lhs.requests > rhs.requests }
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.destination.token < rhs.destination.token
        }
    }

    /// Countries only, in `sorted()` order — what the map draws.
    public var plottable: [DestinationEntry] {
        sorted().filter { $0.destination.isPlottable }
    }

    /// The dot scale's denominator; 0 when no country has been seen. The
    /// three classes are rows, never marks, so they do not take part.
    public var maxCountryRequests: Int {
        entries.values.filter { $0.destination.isPlottable }.map(\.requests).max() ?? 0
    }

    /// Hosts summed across every destination, busiest first.
    public func topHosts(_ limit: Int) -> [(name: String, requests: Int)] {
        var merged: [String: Int] = [:]
        for entry in entries.values {
            for (host, count) in entry.hostsByCount { merged[host, default: 0] += count }
        }
        return Self.rankedHosts(merged, limit: limit)
    }

    /// Apps summed across every destination, busiest first, the nil bucket last.
    public func topApps(_ limit: Int) -> [(name: String?, requests: Int)] {
        var merged: [String: Int] = [:]
        for entry in entries.values {
            for (app, count) in entry.appsByCount { merged[app, default: 0] += count }
        }
        return Self.rankedApps(merged, limit: limit)
    }

    // MARK: - Shared ranking

    static func appKey(_ app: String?) -> String {
        guard let app = app?.trimmingCharacters(in: .whitespaces), !app.isEmpty else { return unknownAppKey }
        return app
    }

    static func rankedHosts(_ counts: [String: Int], limit: Int) -> [(name: String, requests: Int)] {
        counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        .prefix(max(0, limit))
        .map { (name: $0.key, requests: $0.value) }
    }

    static func rankedApps(_ counts: [String: Int], limit: Int) -> [(name: String?, requests: Int)] {
        counts.sorted { lhs, rhs in
            let lhsUnknown = lhs.key == unknownAppKey
            let rhsUnknown = rhs.key == unknownAppKey
            if lhsUnknown != rhsUnknown { return rhsUnknown }
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        .prefix(max(0, limit))
        .map { (name: $0.key == unknownAppKey ? nil : $0.key, requests: $0.value) }
    }

    private static func decrement(_ counts: inout [String: Int], _ key: String) {
        guard let current = counts[key] else { return }
        if current <= 1 {
            counts[key] = nil
        } else {
            counts[key] = current - 1
        }
    }
}
