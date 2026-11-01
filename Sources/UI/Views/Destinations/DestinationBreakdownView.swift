//
//  DestinationBreakdownView.swift
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
//  The hosts and apps behind a destination (destination-map UX spec §3.5):
//  two five-row columns under the map, in a FIXED 148pt band so a destination
//  with two hosts does not shrink the section and the map above it never
//  jumps. Scope is the selection, else the whole index. The row context menus
//  are the traffic table's own two sentences, and both front the main window.
//

import MCPKit
import SwiftUI

struct DestinationBreakdownView: View {
    let index: DestinationIndex
    let selection: TrafficDestination?
    /// Spec §7 state 7: `.unavailable` shows `None` under Apps — the extension
    /// could not name any process, so a column of guesses would be worse.
    let attribution: ProcessAttributionAvailability

    static let height: CGFloat = 148
    static let rowLimit = 5

    private var scope: DestinationEntry? {
        selection.flatMap { index.entries[$0] }
    }

    private var hosts: [(name: String, requests: Int)] {
        scope?.topHosts(Self.rowLimit) ?? index.topHosts(Self.rowLimit)
    }

    private var apps: [(name: String?, requests: Int)] {
        guard attribution != .unavailable else { return [] }
        return scope?.topApps(Self.rowLimit) ?? index.topApps(Self.rowLimit)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            column("Hosts", isEmpty: hosts.isEmpty) {
                ForEach(hosts, id: \.name) { host in
                    row(name: host.name, count: host.requests, truncation: .middle, icon: nil)
                        .contextMenu {
                            Button("Show only requests to \(host.name)") {
                                TrafficSearchState.shared.addToken(.host(host.name))
                                DestinationsWindow.frontMainWindow()
                            }
                        }
                }
            }
            column("Apps", isEmpty: apps.isEmpty) {
                ForEach(Array(apps.enumerated()), id: \.offset) { _, app in
                    let name = app.name ?? TrafficDestination.unknownLabel
                    let row = row(name: name, count: app.requests, truncation: .tail, icon: identity(for: app.name))
                    if let appName = app.name {
                        row.contextMenu {
                            Button("Show only requests from \(appName)") {
                                TrafficSearchState.shared.addToken(.app(appName))
                                DestinationsWindow.frontMainWindow()
                            }
                        }
                    } else {
                        row
                    }
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(height: Self.height, alignment: .top)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func column<Rows: View>(_ title: String, isEmpty: Bool, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The suggestions panel's group header.
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(height: 16, alignment: .leading)
            if isEmpty {
                Text("None")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(height: 22, alignment: .leading)
            } else {
                rows()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(name: String, count: Int, truncation: Text.TruncationMode, icon: ProcessIdentity?) -> some View {
        HStack(spacing: 8) {
            if let icon {
                ProcessLabel(identity: icon, availability: attribution, style: .icon(size: 14))
            }
            Text(name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(truncation)
            Spacer(minLength: 6)
            Text(CountryPresentation.groupedDigits(count))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .help(name)
    }

    /// The identity behind a display name, from the index `SessionState`
    /// maintains (a READ, never an observation), so the icon is the one the
    /// App column draws. A name the index no longer holds — or the Unknown
    /// bucket — falls back to an identity built from the name alone, which
    /// `ProcessLabel` renders with its own placeholder rules.
    private func identity(for name: String?) -> ProcessIdentity {
        if let name, let known = SessionState.shared.identity(forDisplayName: name) { return known }
        return ProcessIdentity(name: name, pid: nil, executablePath: nil)
    }
}
