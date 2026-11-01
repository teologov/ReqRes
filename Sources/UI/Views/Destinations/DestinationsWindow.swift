//
//  DestinationsWindow.swift
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
//  Where captured requests went (destination-map UX spec §3): a list of
//  destinations on the left, the world map with a header and a hosts/apps
//  breakdown on the right — the Saved Sessions window's shape, because a
//  second window is how this app already asks a second question over the
//  same traffic. Everything here observes `DestinationsStore` and nothing
//  observes `SessionState`: rows and the map take VALUES from the store's
//  ≤ 1 Hz publish.
//
//  A single click selects and nothing else; only Show in Traffic, a
//  double-click and the context items commit a `country:` chip — and when they
//  do, the sidebar goes to All traffic first, because this window counts ALL
//  captured traffic and a chip applied to one host would show a count the map
//  never claimed. Escape deselects.
//

import MCPKit
import SwiftUI

struct DestinationsWindow: View {
    @ObservedObject private var store = DestinationsStore.shared

    @State private var selection: TrafficDestination?
    @State private var hovered: TrafficDestination?
    @State private var query = ""

    private var entries: [DestinationEntry] { store.index.sorted() }

    private var filtered: [DestinationEntry] {
        entries.filter { DestinationRow.matches($0, query: query) }
    }

    private var selectedEntry: DestinationEntry? {
        selection.flatMap { store.index.entries[$0] }
    }

    private var tableFailure: String? { DestinationResolver.shared.tableFailureReason }

    private var showsApps: Bool { store.attribution != .unavailable }

    var body: some View {
        HSplitView {
            listPane
                // Rows are short; the saved window's 520 cap is for URLs.
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            mapPane
                .frame(minWidth: 520, maxWidth: .infinity)
        }
        .frame(minWidth: 860, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(store.$pendingSelection) { pending in
            guard let pending else { return }
            selection = pending
            store.pendingSelection = nil
        }
        .onChange(of: selection) { _, current in
            store.currentSelection = current
        }
        .onExitCommand { selection = nil }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            listBody
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("", text: $query, prompt: Text("Filter by country, host or app"))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var listBody: some View {
        if entries.isEmpty {
            if store.isCapturing {
                PlaceholderView(
                    imageName: "tray",
                    title: "No Destinations Yet",
                    subtitle: "Requests appear here as they are captured."
                )
            } else {
                PlaceholderView(imageName: "tray", title: "No Destinations")
            }
        } else if filtered.isEmpty {
            PlaceholderView(
                imageName: "magnifyingglass",
                title: "No matches",
                subtitle: "No destination matches “\(query)”. The filter covers country names and codes, hosts and apps."
            )
        } else {
            list
        }
    }

    private var list: some View {
        // No `.tag`: `List(_:selection:)` selects by the element's `id`, which
        // `DestinationEntry` types as the destination itself.
        List(filtered, selection: $selection) { entry in
            DestinationRow(entry: entry, tableFailure: tableFailure, showsApps: showsApps)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { showInTraffic(entry.destination) }
                .contextMenu {
                    Button("Show in Traffic") { showInTraffic(entry.destination) }
                }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(footerSummary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// "All captured traffic" is load-bearing: the index counts every retained
    /// session, not the sidebar's host and not the table's chips. At the
    /// retention cap it says so, or "all" would be a lie.
    private var footerSummary: String {
        let total = store.index.totalRequests
        return DestinationCopy.footerSummary(
            destinationCount: entries.count,
            requests: total,
            shown: query.isEmpty ? nil : filtered.count,
            retentionCap: total >= SessionState.maxRetainedSessions ? SessionState.maxRetainedSessions : nil
        )
    }

    // MARK: - Map pane

    private var mapPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = store.geometryError {
                errorBanner(error)
                Divider()
            }
            mapArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 200)
            Divider()
            DestinationBreakdownView(index: store.index, selection: selection, attribution: store.attribution)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var mapArea: some View {
        if entries.isEmpty && !store.isCapturing {
            // Spec §7 state 1: nothing to draw and nothing coming.
            PlaceholderView(
                imageName: "map",
                title: "Start Capturing to See Destinations",
                subtitle: "As requests are captured, the countries they go to appear here as dots, with the hosts and apps behind each.",
                buttonTitle: store.extensionReady ? "Start Capturing" : "Diagnose Setup…",
                buttonAction: store.extensionReady ? { TrafficCommands.toggleCapture() } : { TrafficCommands.explainSetup() }
            )
        } else if store.geometryError != nil || store.geometry != nil {
            // Spec §7 state 4: the banner above already said what went wrong,
            // so the Apple map draws bare — no dots, wash or arcs — while the
            // pills, the origin sentence and the legal corner still render.
            DestinationMapView(
                geometry: store.geometryError == nil ? store.geometry : nil,
                index: store.index,
                origin: store.origin,
                selection: selection,
                hovered: $hovered,
                onSelect: { selection = $0 },
                onOpenInTraffic: { showInTraffic($0) },
                tableFailure: tableFailure,
                attribution: store.attribution,
                isOffline: store.isOffline
            )
        } else if store.isLoadingGeometry {
            ProgressView()
                .controlSize(.small)
        } else {
            Color.clear
        }
    }

    // MARK: - Header (SessionDetailHeaderView's treatment)

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            headerGlyph
            Text(headerTitle)
                .fontWeight(.medium)
            Divider()
            Text(headerMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if let selection {
                Button("Show in Traffic") { showInTraffic(selection) }
                    .controlSize(.small)
                Button(action: { self.selection = nil }) {
                    Image(systemName: "xmark")
                        .imageScale(.medium)
                        .foregroundColor(.gray)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Clear selection")
            }
        }
        .frame(minWidth: 0,
               maxWidth: .infinity,
               minHeight: 20,
               maxHeight: 20,
               alignment: .topLeading)
        .padding([.trailing], 15)
        .padding([.leading], 15)
        .padding([.vertical], 8)
        .background(Color.panelBodyBackground)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.gray).opacity(0.5), alignment: .top)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.gray).opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var headerGlyph: some View {
        if let selection {
            DestinationGlyph(destination: selection, flagSize: 13, symbolSize: 12)
        } else {
            Image(systemName: "map")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var headerTitle: String {
        selection.map { CountryPresentation.title(for: $0) } ?? "All captured traffic"
    }

    private var headerMeta: String {
        guard let selection else {
            return DestinationCopy.headerMeta(
                selection: nil,
                destinationCount: entries.count,
                requests: store.index.totalRequests,
                bytes: store.index.totalBytes,
                hostCount: 0,
                appCount: nil,
                // Spec §7 state 3: the one "destination" is the Unknown class.
                allUnknown: !entries.isEmpty && entries.allSatisfy { $0.destination == .unknown }
            )
        }
        let entry = selectedEntry
        return DestinationCopy.headerMeta(
            selection: selection,
            destinationCount: entries.count,
            requests: entry?.requests ?? 0,
            bytes: entry?.bytes ?? 0,
            hostCount: entry?.hostCount ?? 0,
            appCount: showsApps ? (entry?.appCount ?? 0) : nil
        )
    }

    /// The saved window's banner, without Retry: the load runs once per launch
    /// and a resource missing from the bundle will not appear on a second try.
    private func errorBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("The country outlines and centroids could not be loaded (\(reason)), so nothing can be plotted. Destinations are still listed.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Actions (spec §5.1)

    private func showInTraffic(_ destination: TrafficDestination) {
        Self.showInTraffic(destination)
    }

    /// Filters the traffic list to `destination`: All traffic in the sidebar
    /// first (this window counts everything), then the chip, then the main
    /// window in front. This window stays open behind it.
    static func showInTraffic(_ destination: TrafficDestination) {
        // By name: "All traffic" is inserted at index 0 at bootstrap, but a host row
        // without an id can be removed by a delete that matches on `hostDbId == nil`.
        AppState.shared.selectedHost = AppState.shared.hosts.first { $0.host == "All traffic" } ?? AppState.shared.hosts.first
        TrafficSearchState.shared.addToken(.country(destination.token))
        frontMainWindow()
    }

    static func frontMainWindow() {
        NSApp.windows.first { $0.identifier == ReqResMainWindow.identifier }?.makeKeyAndOrderFront(nil)
    }
}

#Preview {
    DestinationsWindow()
}
