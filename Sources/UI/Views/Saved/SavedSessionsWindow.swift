//
//  SavedSessionsWindow.swift
//  ReqRes
//
//  Created by OloApps on 21.09.2026.
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
//  The browser for sessions the user chose to keep: list on the left, the
//  selected exchange rendered on the right by the app's own viewers.
//
//  `HSplitView`, not `NavigationSplitView`. The main window's split had to
//  become a real `NSSplitViewController` because its toolbar's tracking
//  separators need one; this window has no toolbar to anchor, so the plain
//  AppKit-backed split is enough and brings none of that machinery.
//
//  Every failure mode is spelled out rather than rendered as emptiness: a
//  database read that failed, a list still loading, a search that matched
//  nothing and a genuinely empty store all look identical as "no rows", and
//  only one of them is the user's fault.
//

import SwiftUI
import XReqResCore

struct SavedSessionsWindow: View {
    @ObservedObject private var store = SavedSessionsStore.shared

    @State private var selection: Int64?
    @State private var query = ""
    @State private var pendingDeletion: SavedSessionCodable?

    private var filtered: [SavedSessionCodable] {
        store.sessions.filter { SavedSessionRow.matches($0, query: query) }
    }

    private var selected: SavedSessionCodable? {
        guard let selection else { return nil }
        return store.sessions.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
            detailPane
                .frame(minWidth: 520, maxWidth: .infinity)
        }
        .frame(minWidth: 860, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        // The controller reloads on every `show()` so a reopened window is
        // fresh; this makes the VIEW able to load itself as well. A view that
        // only has data when one particular caller fetched it first is a view
        // nobody can preview, probe or reuse — and that is not hypothetical:
        // rendered on its own it showed "0 saved" with three rows in the
        // database. `reload()` is idempotent, so both paths running costs one
        // query on open.
        .task {
            guard store.sessions.isEmpty else { return }
            await store.reload()
        }
        .confirmationDialog(
            // Names the row, because a confirmation that only asks "are you
            // sure?" makes the person cancel and go back to check which one
            // they had selected.
            pendingDeletion.map { "Delete the saved \($0.session.method) to \($0.session.host)?" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { target in
            Button("Delete", role: .destructive) { delete(target) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { target in
            Text("\(SavedSessionRow.path(of: target.session))\n\nThe stored request and response are removed from disk. This cannot be undone — the captured traffic it came from is long gone from memory.")
        }
    }

    // MARK: - List

    private var listPane: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if let error = store.lastError {
                errorBanner(error)
                Divider()
            }
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
            // `prompt:` rather than a title, and leading alignment: a titled
            // TextField is promoted to a row label in this app's forms and
            // the typed text right-aligns (measured — see CaptureSettingsView).
            TextField("", text: $query, prompt: Text("Search host, path, method, app or note"))
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
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var listBody: some View {
        if store.sessions.isEmpty {
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.lastError != nil {
                // The banner above already says what went wrong; repeating it
                // here would read as two separate failures.
                Color.clear.frame(maxHeight: .infinity)
            } else {
                emptyStore
            }
        } else if filtered.isEmpty {
            PlaceholderView(
                imageName: "magnifyingglass",
                title: "No matches",
                subtitle: "Nothing saved matches “\(query)”. Search covers the host, path, method, app and note."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(filtered, selection: $selection) { saved in
            // No `.tag`: `List(_:selection:)` selects by the element's `id`,
            // which `SavedSessionCodable` already types as the row's `Int64`
            // database id — the durable handle every delete goes through.
            SavedSessionRow(saved: saved)
                .contextMenu {
                    Button("Delete Saved Session…", role: .destructive) {
                        pendingDeletion = saved
                    }
                }
        }
        .listStyle(.inset)
        // The Delete key acts on the SELECTION, which is not necessarily the
        // row the context menu was opened on — so it reads `selected`, not
        // whatever was last right-clicked.
        .onDeleteCommand {
            if let selected { pendingDeletion = selected }
        }
    }

    private var emptyStore: some View {
        PlaceholderView(
            imageName: "tray",
            title: "Nothing saved yet",
            // Someone opening an empty browser has no way to guess where the
            // verb lives, and there is no toolbar button for it on purpose:
            // saving is opt-in and stays out of the way until asked for.
            subtitle: "Captured traffic is dropped as new requests arrive. To keep an exchange, right-click it in the traffic list and choose Save Session — or ask an AI agent to call the save_session tool."
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry") {
                Task { await store.reload() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(footerSummary)
            Spacer(minLength: 0)
            if store.isLoading && !store.sessions.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Never implies the list is everything. The store loads one page
    /// (`SavedSessionsStore.pageSize`), so a person with more saved than that
    /// would otherwise believe the rest had been lost.
    private var footerSummary: String {
        let loaded = store.sessions.count
        let shown = filtered.count
        var parts: [String] = []
        if !query.isEmpty {
            parts.append("\(shown) of \(loaded) shown")
        } else {
            parts.append("\(loaded) saved")
        }
        if store.totalCount > loaded {
            parts.append("newest \(loaded) of \(store.totalCount) loaded")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let selected {
            SavedSessionDetailView(saved: selected)
        } else {
            PlaceholderView(
                imageName: "sidebar.right",
                title: store.sessions.isEmpty ? "No Saved Session" : "Select a Saved Session",
                subtitle: store.sessions.isEmpty
                    ? nil
                    : "Its request and response open here, in the same inspector the traffic table uses."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - Actions

    private func delete(_ target: SavedSessionCodable) {
        pendingDeletion = nil
        // Cleared here, not inside the Task: `selection` is `@State` and the
        // detail pane resolves it against the store, so a selection still
        // pointing at a deleted id renders an empty pane that reads as a bug
        // rather than as the deletion the person just asked for.
        if selection == target.id { selection = nil }
        Task { await store.delete(id: target.id) }
    }
}

#Preview {
    SavedSessionsWindow()
}
