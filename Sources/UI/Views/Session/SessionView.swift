//
//  SessionView.swift
//  ReqRes
//
//  Created by OloApps on 14.06.2023.
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
import SwiftUI
import XReqResCore
import SplitView
import Utils
import MCPKit

private struct NetworkInspectorPreferences {
    @AppStorage("network-inspector-selected-tab-request")
    var selectedTab: NetworkInspectorTabRequest = .summary
}

private struct NetworkInspectorPreferencesResponse {
    @AppStorage("network-inspector-selected-tab-response")
    var selectedTab: NetworkInspectorTabResponse = .response
}

enum NetworkInspectorTabRequest: String, Identifiable, CaseIterable, CustomStringConvertible {
    case summary = "Summary"
    case request = "Body"
    case headers = "Headers"
    case metrics = "Metrics"
    case curl = "cURL"

    var id: NetworkInspectorTabRequest { self }
    var description: String { self.rawValue }
}

enum NetworkInspectorTabResponse: String, Identifiable, CaseIterable, CustomStringConvertible {
    case summary = "Summary"
    case response = "Body"
    case headers = "Headers"
    case metrics = "Metrics"
    /// A streamed response's events (SSE / NDJSON) — offered only for a
    /// stream (`tabs(for:)`, StreamEventsView.swift).
    case events = "Events"
    /// A WebSocket's messages — offered only for a `101` naming websocket
    /// (`tabs(for:)`; protocol-engine doc §S7).
    case messages = "Messages"
    /// A gRPC-Web / Connect / gRPC call's messages and status — offered only
    /// for a finished row that reads as one (`tabs(for:)`; protocol-engine
    /// doc §S8).
    case rpc = "RPC"

    var id: NetworkInspectorTabResponse { self }
    var description: String { self.rawValue }
}

enum SessionMode: String {
    case Request = "Request"
    case Response = "Response"
}

let mockNow = Date().timeIntervalSince1970 // Current Unix timestamp

struct SessionView: View {
    @AppStorage("selectedSettingsTab") private var selectedSettingsTab = SettingsTab.general
    @Environment(\.openSettings) private var openSettings
    
    @ObservedObject var appState: AppState = AppState.shared
    @ObservedObject var sessionState: SessionState = SessionState.shared
    @ObservedObject private var licenseManager = LicenseManager.shared
    
    @State private var viewLoaded = false
    @State private var selectedSessionIds: Set<UUID> = []
    /// The detail pane's row. Written only by `refreshDetail()`, from the
    /// row `detailTiming` says the pane shows.
    @State private var selectedSession: SessionCodable?
    /// Where ⇧ ranges start, the active row (the one last clicked or moved
    /// to) and the rows a range keeps — by row ID, so the rows live traffic
    /// adds at the top never move them (`TrafficTableNavigation`).
    @State private var selectionCursor = TrafficTableNavigation.Cursor<UUID>()
    /// When the detail pane takes the row the arrow keys moved to
    /// (`TrafficDetailDebounce`). A box: its wake-ups must not re-render the
    /// table.
    @State private var detailTiming = DetailTimingBox()
    /// The row the arrow keys last moved to, for the table to keep in view;
    /// nil after a click or once nothing is selected.
    @State private var keyboardReveal: TrafficRowReveal?
    /// Where the table's laid-out rows, its pinned header and its visible
    /// area are — written by the list's geometry callbacks, read by the
    /// arrow keys: a reference, so neither re-renders anything.
    @State private var tableGeometry = TrafficTableGeometry()
    
    @State private var maxColWidth: CGFloat = 300
    @State var selectedTabRequest: NetworkInspectorTabRequest
    @State var selectedTabResponse: NetworkInspectorTabResponse
    @State private var keyMonitor: Any?
    /// Where this table is — its window and its pane — for the key monitor,
    /// which sees the keys of every window of the app (F14).
    @State private var paneAnchor = TrafficPaneAnchor.Box()
    /// Rows that already spent a free inspection — by ROW id, which a live
    /// row keeps through its final (`FreeTier.InspectionTally`).
    @State private var inspections = FreeTier.InspectionTally()
    
    let layout = LayoutHolder(.horizontal)
    let hide = SideHolder()
    
    init(tab: NetworkInspectorTabRequest = NetworkInspectorPreferences().selectedTab) {
        self._selectedTabRequest = State(initialValue: tab)
        self._selectedTabResponse = State(initialValue: NetworkInspectorPreferencesResponse().selectedTab)
    }

    var body: some View {
        Split(
            primary: {
                SessionListView(
                    sessionState: sessionState,
                    selectedSessionIds: $selectedSessionIds,
                    reveal: keyboardReveal,
                    geometry: tableGeometry,
                    // Handed down as a VALUE: this view already observes
                    // `AppState`; rows must not (UX spec §1.6).
                    attribution: appState.processAttribution,
                    onAppear: onAppear,
                    onDisappear: removeKeyMonitor,
                    handleRowSelection: handleRowSelection,
                    saveLabel: saveLabel,
                    saveSessions: saveSessions,
                    canSave: { !sessionsToSave(startingFrom: $0).isEmpty },
                    deleteLabel: deleteLabel,
                    deleteSessions: deleteSessions
                )
            },
            secondary: {
                // Pass a wrapper function for openSettings that matches the expected signature
                let openSettingsAction: () -> Void = { self.openSettings() }

                SessionDetailView(
                    selectedSession: selectedSession,
                    attribution: appState.processAttribution,
                    selectedSessionIds: $selectedSessionIds,
                    selectedTabRequest: $selectedTabRequest,
                    selectedTabResponse: $selectedTabResponse,
                    inspections: $inspections,
                    layout: layout,
                    hide: hide,
                    selectedSettingsTab: $selectedSettingsTab,
                    openSettingsAction: openSettingsAction
                )
                .onAppear {
                    refreshDetail()
                }
                // Esc, Delete, the ✕ and every other change: the pane follows
                // at once. A click has shown its row already, and an arrow
                // key's own change waits for its debounce (`moveSelection`).
                .onChange(of: selectedSessionIds) { _, selection in
                    if selection.isEmpty { keyboardReveal = nil }
                    if detailTiming.debounce.selectionChanged(to: detailRow(for: selection, cursor: selectionCursor)) {
                        refreshDetail()
                    }
                }
                // A live row replaced by its final, given its response head,
                // or ended: the pane holds a copy, so it takes the new one.
                // Only the row the pane shows matters; nothing else re-renders.
                .onReceive(sessionState.rowsChangedInPlace) { ids in
                    guard let shown = detailTiming.debounce.shown, ids.contains(shown) else { return }
                    refreshDetail()
                }
            }
        )
        .splitter { Splitter.invisible() }
        .layout(LayoutHolder(.vertical))
        // Open while the pane has a row to show: an arrow key's first row
        // arrives after its debounce, and the pane opens with it rather than
        // empty.
        .hide(SideHolder(selectedSession == nil ? .secondary : nil))
        .background(TrafficPaneAnchor(box: paneAnchor))
    }
    
    // MARK: - Event Functions
    
    func onAppear() -> Void {
        if (self.viewLoaded) {
            return
        }
        sessionState.updateFilteredSessions(selectedHost: nil)
        addKeyMonitor()
        viewLoaded = true

        #if DEBUG
        // Screenshot mode opens a request with a body worth showing, so the
        // inspector is not empty in marketing captures.
        if ScreenshotMocks.isEnabled {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let target = sessionState.filteredSessions.first(where: {
                    $0.uri.hasPrefix("/v1/products")
                }) else { return }
                // The pane follows the selection (`refreshDetail`).
                selectedSessionIds = [target.id]
                // Headers on the request side and the JSON body on the response
                // side read better than a wrapped cURL dump.
                selectedTabRequest = .headers
                selectedTabResponse = .response
            }
        }
        #endif
    }
    
    /// Esc deselects, Delete (or forward delete) removes the selected rows,
    /// and ↑ / ↓ move the selection (⇧ extends it) — in THIS table only.
    ///
    /// A local monitor sees every key of every window of the app. Until
    /// F14 this one took Esc and Delete wherever they were pressed: Delete in
    /// Saved Sessions, a sheet, an alert or the Paused Requests panel deleted
    /// the rows selected here, and Esc never reached a sheet, an alert or the
    /// search field. Now `TrafficTableKeys` decides from where the key went —
    /// this window, no sheet or modal alert, no ⌘⌥⌃, the keyboard on the
    /// traffic pane rather than the sidebar, a list, a text or a web view
    /// (Esc also from a body being read) — and every key that is not the
    /// table's is returned untouched. Esc or Delete with no row selected is
    /// kept and does nothing: returned, it would only make AppKit beep. The
    /// arrows move even then: ↓ selects the first row, ↑ the last.
    ///
    /// It hears key RELEASES too, and passes every one on: an arrow's tells
    /// the detail pane the key is up (`arrowReleased`), wherever it went.
    func addKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event -> NSEvent? in
            guard event.type == .keyDown else {
                if TrafficTableKeyEvents.releasesArrow(event) { self.arrowReleased() }
                return event
            }
            switch TrafficTableKeyEvents.command(for: event, pane: self.paneAnchor.view,
                                                 hasSelection: !self.selectedSessionIds.isEmpty) {
            case .clearSelection:
                self.selectedSessionIds = []
                return nil
            case .deleteSelection:
                self.deleteSelectedSessions()
                return nil
            case .moveSelection(let direction, let extending):
                self.moveSelection(direction, extending: extending)
                return nil
            case .nothingToDo:
                return nil
            case nil:
                return event
            }
        }
    }
    
    func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    
    /// The row the detail pane shows for a selection: the active row — the
    /// one last clicked or moved to — while it is selected; otherwise, as
    /// before, one of the selected rows.
    func detailRow(for selection: Set<UUID>, cursor: TrafficTableNavigation.Cursor<UUID>) -> UUID? {
        TrafficTableNavigation.activeRow(selection: selection, cursor: cursor)
            ?? selection.max(by: { $0.uuidString < $1.uuidString })
    }

    /// The detail pane's copy of the row it shows (`detailTiming`). The ONE
    /// writer of `selectedSession`: the free inspection is spent when the
    /// pane shows an HTTPS row (`HttpsSessionDetailContent`), so a row a held
    /// arrow key only passed over is never shown, and never counted.
    func refreshDetail() {
        let shown = detailTiming.debounce.shown
        selectedSession = shown.flatMap { id in sessionState.sessions.first { $0.id == id } }
    }

    /// A click on a row: plain selects it alone, ⌘ adds or removes it, ⇧
    /// selects the range from the anchor — the anchor ⇧↑ and ⇧↓ extend from
    /// (`TrafficTableNavigation`), kept by row ID: rows that arrive above it
    /// do not move it, and a list filtered shorter does not lose it. Never
    /// debounced: the detail pane shows the row at once.
    func handleRowSelection(sessionId: UUID) {
        let flags = NSEvent.modifierFlags
        let outcome = TrafficTableNavigation.click(
            sessionId,
            TrafficTableNavigation.Click(command: flags.contains(.command), shift: flags.contains(.shift)),
            rows: sessionState.filteredSessions.map(\.id),
            selection: selectedSessionIds,
            cursor: selectionCursor
        )
        selectionCursor = outcome.cursor
        keyboardReveal = nil
        detailTiming.debounce.show(detailRow(for: outcome.selection, cursor: outcome.cursor))
        selectedSessionIds = outcome.selection
        refreshDetail()
    }

    /// ↑ or ↓ from the key monitor: the selection moves one row in the order
    /// the table shows (⇧ extends or shrinks the range from the anchor), the
    /// table scrolls just enough to show the row below its pinned header
    /// (`SessionListView.revealRow`), and the detail pane takes the row once
    /// the keys pause and the key is let go of — a held key passes rows
    /// without rendering or counting any of them, whatever the repeat rate
    /// (`TrafficDetailDebounce`).
    func moveSelection(_ direction: TrafficTableNavigation.Direction, extending: Bool) {
        guard let outcome = TrafficTableNavigation.move(
            direction,
            extending: extending,
            rows: sessionState.filteredSessions.map(\.id),
            selection: selectedSessionIds,
            cursor: selectionCursor
        ) else { return }
        // Before the selection changes, so its onChange sees a key move
        // waiting and leaves the pane to the wake-up.
        if let wake = detailTiming.debounce.keyMoved(to: outcome.active) {
            settleDetail(after: wake)
        }
        // A key held at either end of the table moves nowhere: with the row
        // in view there is nothing to write, and so nothing re-renders on
        // every repeat. Out of view (the table was scrolled away from it),
        // the key brings it back.
        if outcome.selection == selectedSessionIds, outcome.cursor == selectionCursor,
           tableGeometry.showsWhole(outcome.active) {
            return
        }
        selectionCursor = outcome.cursor
        selectedSessionIds = outcome.selection
        detailTiming.reveals += 1
        keyboardReveal = TrafficRowReveal(row: outcome.active, direction: direction, serial: detailTiming.reveals)
    }

    /// An arrow key was let go of — wherever it went (a sheet may have come
    /// up while it was down): the row a held key stopped on shows now, if it
    /// has waited out its pause already; otherwise its wake-up shows it.
    func arrowReleased() {
        if let wake = detailTiming.debounce.keyReleased() {
            settleDetail(after: wake)
        }
    }

    /// The debounce's wake-up: shows the row once the keys have paused and
    /// the key is up; otherwise it is woken again when that can be.
    private func settleDetail(after wake: TrafficDetailDebounce<UUID>.Wake) {
        DispatchQueue.main.asyncAfter(deadline: .now() + wake.delay) {
            switch self.detailTiming.debounce.settle(wake.serial) {
            case .show:
                self.refreshDetail()
            case .wait(let later):
                self.settleDetail(after: later)
            case .idle:
                break
            }
        }
    }
    
    /// "Save session" for one, "Save 4 sessions" when a selection is in play —
    /// a context menu that silently acts on more rows than the one clicked is
    /// how people lose work they did not know they had selected.
    func saveLabel(for session: SessionCodable) -> String {
        TrafficRowTargets.saveTitle(count: sessionsToSave(startingFrom: session).count)
    }

    /// The rows a row's context menu acts on: the clicked row, unless it is
    /// part of the current selection, in which case every selected row the
    /// table shows. ONE rule for Save and Delete (`TrafficRowTargets`).
    func sessionsTargeted(from session: SessionCodable) -> [SessionCodable] {
        TrafficRowTargets.rows(clicked: session, selection: selectedSessionIds,
                               shown: sessionState.filteredSessions, id: \.id)
    }

    /// The rows Save acts on.
    ///
    /// Live rows (in flight, or ended without their final row) are left out
    /// of every save, whichever row was clicked: saved, half an exchange
    /// would read as the whole one (`LiveRowKeeping`).
    func sessionsToSave(startingFrom session: SessionCodable) -> [SessionCodable] {
        LiveRowKeeping.finished(sessionsTargeted(from: session)) { sessionState.isLiveSnapshot($0.id) }
    }

    /// "Delete session" or "Delete 3 sessions", counted from the rows the item
    /// deletes — not from the selection, which the clicked row may be outside.
    func deleteLabel(for session: SessionCodable) -> String {
        TrafficRowTargets.deleteTitle(count: sessionsTargeted(from: session).count)
    }

    /// The context menu's Delete. A row clicked outside the selection goes
    /// alone and the selection stays as it was; a row clicked inside it takes
    /// the selected rows with it, and the selection is cleared, as the Delete
    /// key clears it. The ⇧ anchor is a row ID, so deleting other rows does
    /// not move it; if it was among them, ⇧ starts again from what is still
    /// selected (`TrafficTableNavigation`).
    func deleteSessions(startingFrom session: SessionCodable) {
        let targets = sessionsTargeted(from: session)
        sessionState.removeSession(sessionUids: Set(targets.map(\.id)))
        if selectedSessionIds.contains(session.id) {
            selectedSessionIds.removeAll()
        }
    }

    func saveSessions(startingFrom session: SessionCodable) {
        let sessions = sessionsToSave(startingFrom: session)
        Task { @MainActor in
            for session in sessions {
                do {
                    try await SavedSessionsStore.shared.save(session)
                } catch {
                    AppLog.shared.error("[SavedSessions] could not save: \(error.localizedDescription, privacy: .public)")
                    break
                }
            }
        }
    }

    /// The Delete key's action: the whole selection.
    func deleteSelectedSessions() {
        // Remove selected sessions from the session state
        sessionState.removeSession(sessionUids: selectedSessionIds)
        selectedSessionIds.removeAll() // Clear the selected sessions
        selectionCursor = .init() // Its anchor and active row went with them
    }
}

/// `SessionView`'s timing state, held by reference: a wake-up that finds
/// nothing to do must not re-render the table.
final class DetailTimingBox {
    /// The key repeat timings are read when a wake-up needs them, so a change
    /// in System Settings ▸ Keyboard applies at once.
    var debounce = TrafficDetailDebounce<UUID>(holdLimit: {
        TrafficDetailDebounce<UUID>.holdLimit(repeatDelay: NSEvent.keyRepeatDelay,
                                              repeatInterval: NSEvent.keyRepeatInterval)
    })
    /// Numbers each arrow move's `TrafficRowReveal`, so two moves to the same
    /// row (⇧↓ then ⇧↑ back) each scroll.
    var reveals = 0
}

/// The row the arrow keys moved to, for `SessionListView` to keep in view.
struct TrafficRowReveal: Equatable {
    let row: UUID
    /// Where a row the table has not laid out most likely is (`TrafficTableScroll`).
    let direction: TrafficTableNavigation.Direction
    let serial: Int
}

/// Where the traffic table's laid-out rows, its pinned header and its visible
/// area are, in the visible area's coordinates (0 = its top edge). Written by
/// geometry callbacks, read when an arrow key moves: a reference, so neither
/// re-renders anything.
///
/// Measured in a replica of the main window (titled, full-size content, a
/// toolbar, the split view's hosting-controller panes): the table's scroll
/// view starts at the toolbar's lower edge — it does not reach behind the
/// toolbar — and the header pins at 0…32, so the header's bottom edge is all
/// that covers rows at the top.
final class TrafficTableGeometry {
    static let space = "traffic-table-visible-area"
    /// The rows the lazy stack has laid out — the ones on screen and a few
    /// beside them. A row it lets go of is removed (`onDisappear`).
    var rows: [UUID: CGRect] = [:]
    /// Where the pinned header ends: rows above it are hidden.
    var headerBottom: CGFloat = 0
    /// The visible area's height: rows below it are hidden.
    var viewport: CGFloat = 0
    /// A row's height, for a row not laid out: any laid-out row's (a few
    /// points off moves the row a fraction of a point — `TrafficTableScroll`).
    var rowHeight: Double { rows.values.first.map { Double($0.height) } ?? 26 }

    /// The row is laid out and wholly in view, below the pinned header.
    func showsWhole(_ row: UUID) -> Bool {
        guard let frame = rows[row] else { return false }
        return TrafficTableScroll.isInView(rowTop: Double(frame.minY), rowBottom: Double(frame.maxY),
                                           headerHeight: Double(headerBottom), viewportHeight: Double(viewport))
    }
}

struct SessionDetailView: View {
    var selectedSession: SessionCodable?
    let attribution: ProcessAttributionAvailability
    @Binding var selectedSessionIds: Set<UUID>
    @Binding var selectedTabRequest: NetworkInspectorTabRequest
    @Binding var selectedTabResponse: NetworkInspectorTabResponse
    @Binding var inspections: FreeTier.InspectionTally
    
    let layout: LayoutHolder
    let hide: SideHolder
    
    @Binding var selectedSettingsTab: SettingsTab
    let openSettingsAction: () -> Void
    
    @ObservedObject private var licenseManager = LicenseManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = selectedSession {
                SessionDetailHeaderView(session: session, attribution: attribution, onClose: {
                    selectedSessionIds = []
                })

                let detailAccess = access(for: session)
                if let ended = SessionState.shared.endedRow(session.id) {
                    EndedRowBanner(ended: ended)
                    Divider()
                }
                // An aborted or timed-out row that kept a body is decided as
                // an inspection (D14's limit), so its banner is drawn here,
                // above whatever that decision shows.
                if let facts = session.failureFacts, detailAccess != .failure, detailAccess != .relay {
                    FailureBanner(session: session, facts: facts, openCaptureSettings: {
                        selectedSettingsTab = .capture
                        openSettingsAction()
                    })
                    Divider()
                }

                // `FreeTier.detailAccess` (Utils, tested) decides, in the
                // order that matters: a relay first — it is HTTPS recorded
                // with NO certificate installed, and it is neither a
                // certificate problem nor an inspection — then the
                // certificate, then the licence.
                switch detailAccess {
                case .relay:
                    // A relay decides access first (it is never an
                    // inspection); a FAILED relay still states its cause
                    // above the connection's facts (C6.2(b): a DNS typo or a
                    // refused connect with no CA installed).
                    RelayDetailContent(session: session, openCaptureSettings: {
                        selectedSettingsTab = .capture
                        openSettingsAction()
                    }, openCertificateSettings: {
                        selectedSettingsTab = .certificate
                        openSettingsAction()
                    })
                case .failure:
                    // A failed, aborted or timed-out request (protocol PRD
                    // 3.4): the cause and the action first, then whatever it
                    // recorded — never counted (D14), never behind the
                    // certificate gate (the failure may BE the certificate).
                    if let facts = session.failureFacts {
                        FailureDetailView(session: session, facts: facts, openCaptureSettings: {
                            selectedSettingsTab = .capture
                            openSettingsAction()
                        }) {
                            SessionDetailContent(
                                session: session,
                                selectedTabRequest: $selectedTabRequest,
                                selectedTabResponse: $selectedTabResponse,
                                layout: layout,
                                hide: hide
                            )
                        }
                    }
                case .certificateRequired:
                    CertificateRequiredView(
                        selectedSettingsTab: $selectedSettingsTab,
                        openSettingsAction: openSettingsAction
                    )
                case .inspect(counted: true), .limitReached:
                    HttpsSessionDetailContent(
                        session: session,
                        selectedTabRequest: $selectedTabRequest,
                        selectedTabResponse: $selectedTabResponse,
                        inspections: $inspections,
                        layout: layout,
                        hide: hide
                    )
                case .inspect(counted: false):
                    // Regular session detail content (for HTTP or Pro users)
                    SessionDetailContent(
                        session: session,
                        selectedTabRequest: $selectedTabRequest,
                        selectedTabResponse: $selectedTabResponse,
                        layout: layout,
                        hide: hide
                    )
                }
            }
        }
    }

    private func access(for session: SessionCodable) -> FreeTier.DetailAccess {
        let isHTTPS = session.scheme == "https"
        return FreeTier.detailAccess(
            isRelay: session.relayed,
            isFailure: session.isFailure,
            failureCarriesDecryptedBody: session.failureCarriesDecryptedBody,
            isHTTPS: isHTTPS,
            // Asked only when it can matter: the keychain lookup is not free
            // and a relay or plain-HTTP row never needs it.
            certificateInstalled: session.relayed || (session.isFailure && !session.failureCarriesDecryptedBody)
                || !isHTTPS || CertHelper.getInstalledCertificate() != nil,
            licensed: licenseManager.checkLicense(),
            inspectionsUsedUp: AppState.shared.hasReachedFreeHttpsLimit
        )
    }
}

// Component for the session detail header with URL and close button
struct SessionDetailHeaderView: View {
    let session: SessionCodable
    let attribution: ProcessAttributionAvailability
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if session.relayed {
                // A connection, not a request: no status, no method, no URL.
                RelayDetailHeaderRow(session: session)
            } else if let facts = session.failureFacts {
                FailureDetailHeaderRow(session: session, facts: facts)
            } else {
                if let live = SessionState.shared.liveModel(for: session.id) {
                    LiveCodeCell(model: live, status: session.rspStatus)
                } else if let ended = SessionState.shared.endedRow(session.id) {
                    EndedRowGlyph(ended: ended)
                } else {
                    Chip(status: session.rspStatus)
                    if let rpc = RPCStatusCache.shared.facts(for: session),
                       let word = RPCStatusWord.text(rpc, httpStatus: session.rspStatus.flatMap { Int($0) }, isSelected: false) {
                        word.help(RPCStatusWord.label(rpc, httpStatus: session.rspStatus.flatMap { Int($0) }) ?? "")
                    }
                }
                Text(session.method)
                    .fontWeight(.medium)
                Divider()
                Text(verbatim: session.fullUrl)
                    .help(session.fullUrl)  // Tooltip with full URL
                    .truncationMode(.tail)  // Truncate text from the end if it's too long
                    .lineLimit(1)           // Ensure it's a single line for truncation to work
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // The only visible pid (UX spec §5.1): `name · pid N ⌄`, capped at
            // 220 so the URL is what yields, with the filters and the executable
            // path behind the chevron.
            ProcessLabel(
                identity: session.processIdentity,
                availability: attribution,
                style: .pill(actions: .traffic)
            )
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .imageScale(.medium)
                    .foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
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
}

// View shown when certificate is required
struct CertificateRequiredView: View {
    @Binding var selectedSettingsTab: SettingsTab
    let openSettingsAction: () -> Void
    
    var body: some View {
        PlaceholderView(
            imageName: "exclamationmark.circle",
            title: "Not Available",
            subtitle: "Install and trust the ReqRes CA Certificate to inspect HTTPS requests",
            buttonTitle: "Install CA Certificate",
            buttonAction: {
                selectedSettingsTab = .certificate
                openSettingsAction()
            }
        )
    }
}

// Toolbar for request/response tabs
struct SessionToolbar<T>: View where T: CaseIterable & Hashable & RawRepresentable & Identifiable, T.RawValue == String, T.AllCases: Collection, T.AllCases.Element == T {
    let title: SessionMode
    let tabItems: T.Type
    @Binding var selection: T
    
    var body: some View {
        HStack {
            Text(title.rawValue)
                .frame(minWidth: 0,
                       maxWidth: title == .Response ? 65 : 55,
                       minHeight: 20,
                       maxHeight: 20,
                       alignment: .center)
                .fontWeight(.semibold)
                .font(.system(size: 13))
                .padding([.horizontal], 10)
            
            InlineTabBar(items: Array(T.allCases), selection: $selection)
            Spacer()
        }
        .padding(.horizontal, 5)
        .offset(y: 0)
        .frame(height: 27, alignment: .center)
    }
}
struct SessionListView: View {
    @ObservedObject var sessionState: SessionState
    /// Observed HERE, never by a row: this view re-renders per capture flush
    /// anyway, and the agent badge (UX spec §8.2) is derived once per render
    /// and handed to rows as a value.
    @ObservedObject private var agentPresence = MCPAgentPresence.shared
    @Binding var selectedSessionIds: Set<UUID>
    /// The row the arrow keys last moved to: scrolled into view below the
    /// pinned header (`revealRow`), and kept in view when the visible area
    /// changes height under it (the detail pane opening) — if it was in view.
    /// nil after a click.
    let reveal: TrafficRowReveal?
    /// Where the laid-out rows, the header and the visible area are: written
    /// here by geometry callbacks, read here and by `SessionView`'s arrow
    /// keys. A box, `SessionView`'s: nothing renders from it.
    let geometry: TrafficTableGeometry

    /// Whether the extension can attribute connections on this Mac. A value,
    /// from `SessionView` (which observes `AppState`); rows never observe it.
    let attribution: ProcessAttributionAvailability

    let onAppear: () -> Void
    let onDisappear: () -> Void
    let handleRowSelection: (UUID) -> Void
    let saveLabel: (SessionCodable) -> String
    let saveSessions: (SessionCodable) -> Void
    /// False when every row the Save item would act on is live.
    let canSave: (SessionCodable) -> Bool
    let deleteLabel: (SessionCodable) -> String
    /// Deletes the rows the Delete item names — the same rows Save acts on.
    let deleteSessions: (SessionCodable) -> Void

    /// The one geometry read the table LAYS OUT from (UX spec §2.1): the
    /// pane's width picks the App column's width — read once, never per row.
    /// Rows do report their frames, but only into `geometry`, a box nothing
    /// renders from, read when an arrow key moves.
    @State private var paneWidth: CGFloat = 0

    private var mode: SessionTableLayout.Mode { SessionTableLayout.mode(forPaneWidth: paneWidth) }

    /// Spec §9: the column is shown unless attribution is UNAVAILABLE on this
    /// Mac. Per-row Unknown stays a cell value while the column shows; a table
    /// of 5,000 dashed glyphs would be noise on every row forever.
    private var showsApp: Bool { attribution != .unavailable }

    /// Settings ▸ General ▸ Traffic List. Absent = on; the toggle writes an
    /// explicit false. `UserDefaults.standard` includes the argument domain,
    /// so a probe passes `-traffic-column-destination NO` on the command line
    /// and never writes the stored defaults.
    @AppStorage(SessionTableLayout.destinationColumnDefaultsKey) private var showsDestinationPreferred = true

    /// The widths the user dragged the header's dividers to (JSON, see
    /// `SessionTableLayout.ColumnWidths`). Written when a drag ENDS; while it
    /// is in flight the widths live in `draggingWidths`, so a drag does not
    /// write the defaults sixty times a second.
    @AppStorage(SessionTableLayout.columnWidthsDefaultsKey) private var columnWidthsStorage = ""
    @State private var draggingWidths: SessionTableLayout.ColumnWidths?

    /// Every column's width for this render — the header and every row lay out
    /// from this one value, so they cannot disagree.
    private var columns: SessionTableLayout.Columns {
        SessionTableLayout.columns(
            paneWidth: paneWidth,
            showsApp: showsApp,
            destinationPreferred: showsDestinationPreferred,
            user: draggingWidths ?? SessionTableLayout.ColumnWidths(storage: columnWidthsStorage)
        )
    }

    private func resizing(_ columns: SessionTableLayout.Columns) -> ColumnResizing {
        ColumnResizing(
            change: { column, proposed in
                var widths = draggingWidths ?? SessionTableLayout.ColumnWidths(storage: columnWidthsStorage)
                widths[column] = SessionTableLayout.dragWidth(proposed, for: column, in: columns, paneWidth: paneWidth)
                draggingWidths = widths
            },
            commit: {
                if let draggingWidths { columnWidthsStorage = draggingWidths.storage }
                draggingWidths = nil
            },
            reset: { column in
                var widths = SessionTableLayout.ColumnWidths(storage: columnWidthsStorage)
                if let column { widths[column] = nil } else { widths = .init() }
                columnWidthsStorage = widths.storage
            }
        )
    }

    /// Scrolls just enough for the row the arrow keys moved to to show
    /// whole, below the pinned header — nothing when it already does.
    ///
    /// Not `scrollTo(id, anchor: nil)`: SwiftUI's own minimal scroll does not
    /// know the header is pinned over the rows. Measured on macOS 27 in a
    /// standalone harness, a row reached by ↑ ended wholly under the header,
    /// and so did the first row; with the anchor `TrafficTableScroll` (Utils,
    /// tested) picks from where the row is, 89 moves out of 89 left their row
    /// in view below it.
    private func revealRow(_ reveal: TrafficRowReveal, geometry: TrafficTableGeometry, proxy: ScrollViewProxy) {
        let frame = geometry.rows[reveal.row]
        guard let y = TrafficTableScroll.anchor(
            rowTop: frame.map { Double($0.minY) },
            rowBottom: frame.map { Double($0.maxY) },
            direction: reveal.direction,
            headerHeight: Double(geometry.headerBottom),
            viewportHeight: Double(geometry.viewport),
            estimatedRowHeight: geometry.rowHeight
        ) else { return }
        // The row's own id (a UUID, the ForEach's): an id of another type,
        // even one wrapping the same value, matches no row.
        proxy.scrollTo(reveal.row, anchor: UnitPoint(x: 0, y: y))
    }

    /// The visible area changed height under the row the arrow keys moved to
    /// — the detail pane opened below it (an arrow key's row arrives after
    /// its debounce), a window or divider was dragged: a row that was in view
    /// stays in view. One the table was scrolled away from stays where it was
    /// scrolled — a resize never brings it back.
    private func keepInView(_ reveal: TrafficRowReveal, viewportBefore: CGFloat, proxy: ScrollViewProxy) {
        let frame = geometry.rows[reveal.row]
        guard let y = TrafficTableScroll.anchorAfterResize(
            rowTop: frame.map { Double($0.minY) },
            rowBottom: frame.map { Double($0.maxY) },
            headerHeight: Double(geometry.headerBottom),
            viewportBefore: Double(viewportBefore),
            viewportAfter: Double(geometry.viewport)
        ) else { return }
        proxy.scrollTo(reveal.row, anchor: UnitPoint(x: 0, y: y))
    }

    var body: some View {
        let agents = agentPresence.attribution
        let columns = columns
        // Read ONCE per render, handed to rows as a value: the resolver is
        // main-actor and the failure never changes after launch.
        let tableFailure = columns.destination == nil ? nil : DestinationResolver.shared.tableFailureReason
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // Section for header
                    Section(header: SessionTableHeader(mode: mode, showsApp: showsApp, columns: columns, resizing: resizing(columns))
                        // How much of the visible area the pinned header covers.
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TrafficTableGeometry.space)).maxY } action: {
                            geometry.headerBottom = $0
                        }
                    ) {
                        // Table Rows
                        ForEach(Array(sessionState.filteredSessions.enumerated()), id: \.element.id) { index, session in
                            let agentName = agents.agentName(for: session.processIdentity)
                            // The row's destination through the ONE seam (spec
                            // §1.6): the resolver's per-address cache, a dictionary
                            // hit after the first request to each server. Not asked
                            // at all while the column is hidden.
                            let destination = columns.destination == nil ? nil : DestinationResolver.shared.destination(for: session)
                            TableRowView(
                                session: session,
                                isSelected: selectedSessionIds.contains(session.id),
                                isEvenRow: index % 2 == 0,
                                mode: mode,
                                showsApp: showsApp,
                                attribution: attribution,
                                isAgent: agentName != nil,
                                agentName: agentName,
                                destination: destination,
                                destinationTableFailure: tableFailure,
                                columns: columns,
                                // Two dictionary reads per row; nil for every
                                // finished row (protocol-engine doc §S6).
                                live: sessionState.liveModel(for: session.id),
                                ended: sessionState.endedRow(session.id),
                                // A cached read; a media-type check for every
                                // row that is not an RPC (doc §S8).
                                rpc: RPCStatusCache.shared.facts(for: session)
                            )
                            .onTapGesture {
                                // Hands the keyboard back to the window, taking it
                                // from the search field, a sidebar list or a body
                                // being read: a click on a row is what gives the
                                // table its Esc, Delete and arrows (`TrafficTableKeys`
                                // acts when the window itself holds the keyboard).
                                DispatchQueue.main.async {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                }
                                handleRowSelection(session.id)
                            }
                            .contextMenu {
                                rowFilterItems(for: session)
                                Button(action: {
                                    saveSessions(session)
                                }) {
                                    Label(saveLabel(session), systemImage: "square.and.arrow.down")
                                }
                                // A live row is half an exchange: saved, it would
                                // read as the whole one.
                                .disabled(!canSave(session))
                                // The same rows as Save: the clicked one, or the
                                // selection when the clicked row is in it. It
                                // deletes at once, so no ellipsis.
                                Button(action: {
                                    deleteSessions(session)
                                }) {
                                    Label(deleteLabel(session), systemImage: "trash")
                                }
                            }
                            // Where the row is in the visible area, for the arrow
                            // keys (`revealRow`). Into the box, never into state:
                            // a row observes nothing, and its position changing
                            // as the table scrolls re-renders nothing.
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TrafficTableGeometry.space)) } action: { frame in
                                geometry.rows[session.id] = frame
                            }
                            .onDisappear { geometry.rows[session.id] = nil }
                        }
                    }
                }
                // The width the rows really have — the CONTENT width, read on the
                // stack, not the ScrollView's frame: with System Settings ▸ "Show
                // scroll bars: Always" the scroller takes ~16pt of the frame, and
                // a row sized to the frame would clip Duration by exactly that in
                // the 16pt above each threshold. Under overlay scrollers (the
                // default) the two widths are the same, so nothing moves.
                // No animation: a column that slides between 96 and 132 while the
                // user drags the divider is motion nobody asked for.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    paneWidth = width
                }
            }
            // Rows and the header measure themselves against the VISIBLE area:
            // 0 is its top edge, which the pinned header covers.
            .coordinateSpace(.named(TrafficTableGeometry.space))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                let before = geometry.viewport
                geometry.viewport = height
                if let reveal { keepInView(reveal, viewportBefore: before, proxy: proxy) }
            }
            .onChange(of: reveal) { _, reveal in
                guard let reveal else { return }
                revealRow(reveal, geometry: geometry, proxy: proxy)
            }
        }
        // No fill: the pane shows the window background, exactly like the overrides
        // pane and the toolbar. `panelHeaderBackground` here tinted the whole table
        // area #F6F6F6 in light mode. The header row keeps its own tint.
        .background(Color.clear)
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
    }

    /// UX spec §2.5: two process filters above the existing items, for known
    /// rows only; then the destination items (destination-map UX spec §5.4);
    /// then a divider. Copy path / Show in Finder live in the detail pill,
    /// not here.
    ///
    /// The destination is resolved when the menu OPENS, through the
    /// resolver's address cache — never per row render, which is why this
    /// takes the session and not a pre-resolved value.
    @ViewBuilder
    private func rowFilterItems(for session: SessionCodable) -> some View {
        let identity = session.processIdentity
        if identity.isKnown, let name = identity.displayName {
            Button(action: {
                TrafficSearchState.shared.addToken(.app(name))
            }) {
                Label("Show only requests from \(name)", systemImage: "app")
            }
            if let pid = identity.pid {
                Button(action: {
                    TrafficSearchState.shared.addToken(.pid(pid))
                }) {
                    Label("Show only this process (pid \(pid))", systemImage: "tag")
                }
            }
        }
        let destination = DestinationResolver.shared.destination(for: session)
        // The app item's known-rows-only rule: a filter to "Unknown" is not
        // a place, so it is not offered here — the map is.
        if let phrase = destinationPhrase(destination) {
            Button(action: {
                TrafficSearchState.shared.addToken(.country(destination.token))
            }) {
                Label("Show only requests to \(phrase)", systemImage: "map")
            }
        }
        // Every row, Unknown included: the window opens with that pill
        // selected and its hosts in the breakdown — the answer to "why is
        // this unplaceable".
        Button(action: {
            DestinationsWindowController.shared.show(selecting: destination)
        }) {
            Label("Show Destination on Map", systemImage: "map")
        }
        Divider()
    }

    /// How the row's filter item names where the request went: the country's
    /// name, "this Mac", "the local network"; nil for Unknown.
    private func destinationPhrase(_ destination: TrafficDestination) -> String? {
        switch destination {
        case .country(let code): return CountryPresentation.name(for: code)
        case .thisMac: return "this Mac"
        case .localNetwork: return "the local network"
        case .unknown: return nil
        }
    }
}

// Table header component
//
// Every width here and in `TableRowView` comes from `SessionTableLayout`
// (Utils), whose tests hold the row's summed minimum under the traffic pane's
// 660pt floor — a literal in one of the two HStacks would drift from the other
// with nothing to say so.
struct SessionTableHeader: View {
    let mode: SessionTableLayout.Mode
    let showsApp: Bool
    /// The Destination column's form, or nil when it is hidden — decided by
    /// `SessionListView`, never here. Used only when `columns` is nil.
    var destination: SessionTableLayout.Mode? = nil
    /// The traffic list's resolved widths. nil in the Help window's and the
    /// probes' fixed tables, which draw the automatic widths for `mode`.
    var columns: SessionTableLayout.Columns? = nil
    /// Present in the traffic list only: its dividers become drag handles.
    var resizing: ColumnResizing? = nil

    private var layout: SessionTableLayout.Columns {
        columns ?? .automatic(mode: mode, showsApp: showsApp, destination: destination)
    }

    var body: some View {
        let layout = layout
        VStack {
            HStack(spacing: SessionTableLayout.stackSpacing) {
                title("Code")
                    .frame(width: layout.code, alignment: .center)

                VerticalDivider(color: .gray.opacity(0.8))

                title("Method")
                    .frame(width: layout.method, alignment: .center)

                if let app = layout.app {
                    divider(resizing: .method, width: layout.method)

                    title("App")
                        .frame(width: app, alignment: .leading)
                        .help("The process that opened the connection. Several requests can share one connection, so they share one name. A tool that ignores the system proxy never reaches ReqRes and is not listed at all — see Settings ▸ Capture.")

                    divider(resizing: .app, width: app)
                } else {
                    divider(resizing: .method, width: layout.method)
                }

                title("URL")
                    .frame(minWidth: SessionTableLayout.urlMin, idealWidth: SessionTableLayout.urlIdeal, maxWidth: .infinity, alignment: .leading)

                if let destinationWidth = layout.destination {
                    divider(resizing: .destination, width: destinationWidth)

                    // After the URL it names where that URL went; before
                    // Time so the two fixed time columns stay together at the
                    // edge. Too narrow for the word ("Destination" is 69pt),
                    // the header is the globe, named for VoiceOver.
                    Group {
                        if layout.destinationShowsName {
                            title("Destination")
                        } else {
                            Image(systemName: "globe")
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                        }
                    }
                    .frame(width: destinationWidth, alignment: layout.destinationShowsName ? .leading : .center)
                    .help(DestinationColumnCopy.summary + " " + DestinationCopy.whatACountryMeans)
                    .accessibilityLabel("Destination")
                }

                divider(resizing: .time, width: layout.time)

                title("Time")
                    .frame(width: layout.time, alignment: .leading)

                divider(resizing: .duration, width: layout.duration)

                title("Duration")
                    .frame(width: layout.duration, alignment: .leading)
            }
            .padding(.horizontal, SessionTableLayout.horizontalPadding / 2)
            .padding(.vertical, 8) // Add some padding to the headers
            // Opaque (rows scroll under the pinned header) but the WINDOW
            // background, so the header is the same colour as the pane, the
            // overrides pane and the toolbar in both appearances; the 1pt rule
            // below keeps it distinct. `panelHeaderBackground` tinted it
            // #F6F6F6 in light mode.
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(Color.gray.opacity(0.5))
                    .padding(.top, 40), // Add bottom border to header
                alignment: .bottom
            )
            .contextMenu {
                if let resizing {
                    Button("Reset Column Widths") { resizing.reset(nil) }
                }
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .fontWeight(.regular)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundColor(.primary)
    }

    /// The divider on `column`'s edge next to URL: a drag handle in the
    /// traffic list, a plain line in a fixed table.
    @ViewBuilder
    private func divider(resizing column: SessionTableLayout.Column, width: CGFloat) -> some View {
        if let resizing {
            ColumnResizeHandle(column: column, width: width, resizing: resizing)
        } else {
            VerticalDivider(color: .gray.opacity(0.8))
        }
    }
}

/// What the header's handles call; `SessionListView` owns the widths.
struct ColumnResizing {
    /// A drag moved `column`'s edge to give it this width (unclamped — the
    /// owner clamps with `SessionTableLayout.dragWidth`).
    let change: (SessionTableLayout.Column, CGFloat) -> Void
    /// The drag ended: persist.
    let commit: () -> Void
    /// Back to automatic: one column, or every column when nil.
    let reset: (SessionTableLayout.Column?) -> Void
}

/// A header divider the user can drag. The visible line is the same 1pt as
/// every other divider; the hit area is 9pt wide, centred on it, over the
/// gaps either side, so the layout does not move. Double-click puts the
/// column back to its automatic width.
///
/// The drag is measured in the GLOBAL space: the handle moves as its column
/// changes width, so a translation read in its own space would feed back on
/// itself and jitter.
private struct ColumnResizeHandle: View {
    let column: SessionTableLayout.Column
    let width: CGFloat
    let resizing: ColumnResizing
    @State private var startWidth: CGFloat?

    var body: some View {
        VerticalDivider(color: .gray.opacity(0.8))
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .modifier(ColumnResizeCursor())
                    .onTapGesture(count: 2) { resizing.reset(column) }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                // A column before URL grows as its right edge
                                // moves right; one after URL as its left edge
                                // moves left.
                                let delta = column.isBeforeURL ? value.translation.width : -value.translation.width
                                resizing.change(column, start + delta)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                resizing.commit()
                            }
                    )
            )
            .help("Drag to resize the column. Double-click to reset it.")
    }
}

/// The column-resize pointer over a handle: SwiftUI's own from macOS 15, the
/// AppKit cursor before that.
private struct ColumnResizeCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.columnResize)
        } else {
            content.onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
        }
    }
}

private struct TooltipView<Content>: View where Content: View {
    let content: () -> Content
    let tip: String
    let geometry: GeometryProxy

    init(_ tip: String, geometry: GeometryProxy, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.tip = tip
        self.geometry = geometry
    }

    var body: some View {
        Tooltip(tip, content: content)
            .frame(width: geometry.size.width, height: geometry.size.height)
    }
}

private struct Tooltip<Content: View>: NSViewRepresentable {
    typealias NSViewType = NSHostingView<Content>

    init(_ text: String?, @ViewBuilder content: () -> Content) {
        self.text = text
        self.content = content()
    }

    let text: String?
    let content: Content

    func makeNSView(context _: Context) -> NSHostingView<Content> {
        NSViewType(rootView: content)
    }

    func updateNSView(_ nsView: NSHostingView<Content>, context _: Context) {
        nsView.rootView = content
        nsView.toolTip = text
    }
}

extension View {
    func tooltip(_ tip: String) -> some View {
        ZStack {
            background(GeometryReader { childGeometry in
                TooltipView(tip, geometry: childGeometry) {
                    self
                }
            })
        }
    }
}

// View for HTTPS sessions with free tier limit
struct HttpsSessionDetailContent: View {
    let session: SessionCodable
    @Binding var selectedTabRequest: NetworkInspectorTabRequest
    @Binding var selectedTabResponse: NetworkInspectorTabResponse
    @Binding var inspections: FreeTier.InspectionTally
    
    let layout: LayoutHolder
    let hide: SideHolder
    
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        if appState.hasReachedFreeHttpsLimit {
            // The free inspections are used up. The words are PaywallCopy's,
            // the number FreeTier's; the button opens the ReqRes Pro sheet
            // with Reached on Unlimited HTTPS inspections.
            PlaceholderView(
                imageName: "lock.fill",
                title: PaywallCopy.inspectionLimitTitle,
                subtitle: PaywallCopy.inspectionLimitMessage,
                buttonTitle: PaywallCopy.inspectionLimitButton,
                buttonAction: {
                    PaywallPresentation.shared.show(.httpsInspections)
                }
            )
        } else {
            // Track session inspection and show details
            VStack(spacing: 0) {
                // Check if session needs counting and increment if needed
                // Once per ROW: a live row keeps its id through every update
                // and its final, so watching a stream grow spends one.
                if !inspections.hasCounted(session.id) {
                    // This Color.clear is a SwiftUI trick to execute code in a view
                    // without creating a visible element
                    Color.clear
                        .onAppear {
                            if inspections.recordView(rowID: session.id, access: .inspect(counted: true)) {
                                appState.incrementHttpsSessionCounter()
                            }
                        }
                        .frame(width: 0, height: 0)
                }
                
                // Session details
                SessionDetailContent(
                    session: session,
                    selectedTabRequest: $selectedTabRequest,
                    selectedTabResponse: $selectedTabResponse,
                    layout: layout,
                    hide: hide
                )
            }
        }
    }
}

// Core session detail content (request/response split view)
struct SessionDetailContent: View {
    let session: SessionCodable
    @Binding var selectedTabRequest: NetworkInspectorTabRequest
    @Binding var selectedTabResponse: NetworkInspectorTabResponse
    
    let layout: LayoutHolder
    let hide: SideHolder
    
    var body: some View {
        Split(
            primary: {
                VStack(alignment: .leading, spacing: 0) {
                    RequestToolbar(title: .Request, selection: $selectedTabRequest)
                    Divider()
                    
                        SessionRequestTabView(session: session, selectedTabRequest: $selectedTabRequest)
                            .equatable()
                    
                }
                .onChange(of: selectedTabRequest) { _, newTab in
                    NetworkInspectorPreferences().selectedTab = newTab
                }
            },
            secondary: {
                // An in-flight row's model: its Body tab grows, and its
                // Events tab is offered once the head names a stream.
                let live = SessionState.shared.liveModel(for: session.id)
                VStack(alignment: .leading, spacing: 0) {
                    ResponseToolbar(title: .Response, selection: $selectedTabResponse,
                                    items: NetworkInspectorTabResponse.tabs(for: session, live: live))
                    Divider()
                    
                        SessionResponseTabView(session: session, selectedTabResponse: $selectedTabResponse, live: live)
                            .equatable()
                    
                }
                .onChange(of: selectedTabResponse) { _, newTab in
                    NetworkInspectorPreferencesResponse().selectedTab = newTab
                }
            }
        )
        .constraints(minPFraction: 0.2, minSFraction: 0.1)
        .layout(layout)
        .splitter { ThinSplitter(layout: layout, hide: hide) }
    }
}

// Specialized toolbar components to avoid generic issues
struct RequestToolbar: View {
    let title: SessionMode
    @Binding var selection: NetworkInspectorTabRequest
    
    var body: some View {
        HStack {
            Text(title.rawValue)
                .frame(minWidth: 0,
                       maxWidth: 55,
                       minHeight: 20,
                       maxHeight: 20,
                       alignment: .center)
                .fontWeight(.semibold)
                .font(.system(size: 13))
                .padding([.horizontal], 10)
            
            InlineTabBar(items: NetworkInspectorTabRequest.allCases, selection: $selection)
            Spacer()
        }
        .padding(.horizontal, 5)
        .offset(y: 0)
        .frame(height: 27, alignment: .center)
    }
}

struct ResponseToolbar: View {
    let title: SessionMode
    @Binding var selection: NetworkInspectorTabResponse
    /// The tabs this session has (`NetworkInspectorTabResponse.tabs(for:)`).
    var items: [NetworkInspectorTabResponse] = NetworkInspectorTabResponse.standardTabs

    /// A remembered Events tab on a session that is not a stream shows its
    /// Body — and the bar says so, rather than highlighting nothing.
    private var shownSelection: Binding<NetworkInspectorTabResponse> {
        Binding(
            get: { items.contains(selection) ? selection : .response },
            set: { selection = $0 }
        )
    }
    
    var body: some View {
        // A stream's fifth tab (Events) does not fit beside the title in a
        // narrow pane; the title gives way whole rather than truncating to
        // "Resp…" (the tabs are fixed-size). Four tabs always fit.
        ViewThatFits(in: .horizontal) {
            HStack {
                titleText
                InlineTabBar(items: items, selection: shownSelection)
                Spacer(minLength: 0)
            }
            HStack {
                InlineTabBar(items: items, selection: shownSelection)
                    .padding(.leading, 5)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 5)
        .offset(y: 0)
        .frame(height: 27, alignment: .center)
    }

    private var titleText: some View {
        Text(title.rawValue)
            .frame(minHeight: 20, maxHeight: 20, alignment: .center)
            .fixedSize(horizontal: true, vertical: false)
            .fontWeight(.semibold)
            .font(.system(size: 13))
            .padding([.horizontal], 10)
    }
}

// ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ----

func formatRequestTimes(_ session: SessionCodable) -> (requestStartTime: String, requestEndTime: String, requestDuration: String) {
    let startTime = session.startTime.doubleValue
    let endTime = session.rspEndTime.doubleValue
    
    var totalTime = (endTime) - (startTime)
    
    if totalTime < 0 { totalTime = 0 }
    var totalTimeStr = String(format: "%.2f s", totalTime)//"\(totalTime)s"
    if totalTime < 1 {
        totalTimeStr = "\(Int(totalTime*1000)) ms"
    }
    
    var startTimeStr = ""
    var endTimeStr = ""
    
    if startTime > 0 , endTime > 0 {
        let startDate = Date(timeIntervalSince1970: startTime)
        startTimeStr = startDate.CurrentStringTimeForCell
    }
    if endTime > 0 {
        let endDate = Date(timeIntervalSince1970: endTime)
        endTimeStr = endDate.CurrentStringTimeForCell
    }
    
    return (startTimeStr, endTimeStr, totalTimeStr)
}


struct TableRowView: View {
    var session: SessionCodable
    var isSelected: Bool
    var isEvenRow: Bool
    /// All four are VALUES from `SessionListView`. A row observes nothing:
    /// `AppState`, `MCPServerService` and `SessionState` all publish on their
    /// own schedules, and 5,000 rows re-rendering on each was the hang of
    /// 2026-09-06.
    var mode: SessionTableLayout.Mode
    var showsApp: Bool
    var attribution: ProcessAttributionAvailability
    var isAgent: Bool
    var agentName: String? = nil
    /// Where this request went, resolved by `SessionListView` through the
    /// resolver's cache; nil means the Destination column is hidden and the
    /// row draws none. `.unknown` is a VALUE — the ? glyph and the word — so
    /// a row never shows a blank cell.
    var destination: TrafficDestination? = nil
    var destinationMode: SessionTableLayout.Mode = .narrow
    /// The resolver's table failure, for the Unknown cell's tooltip.
    var destinationTableFailure: String? = nil
    /// The traffic list's resolved widths — the header's exact numbers, which
    /// is what keeps every row aligned with it. nil in the Help window's and
    /// the probes' fixed tables, which draw the automatic widths.
    var columns: SessionTableLayout.Columns? = nil
    /// The row's live model while it is in flight (protocol-engine doc §S6):
    /// ONLY the live cells observe it, so a progress message re-renders this
    /// row's cells and nothing else.
    var live: LiveRowModel? = nil
    /// How the row ended, when it stopped being live without its final row.
    var ended: LiveEndedRow? = nil
    /// A gRPC-Web / Connect / gRPC row's protocol and RPC status, resolved by
    /// `SessionListView` through `RPCStatusCache` (protocol-engine doc §S8).
    var rpc: RPCStatusCache.Facts? = nil

    private var httpStatus: Int? { session.rspStatus.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    private var layout: SessionTableLayout.Columns {
        columns ?? .automatic(mode: mode, showsApp: showsApp, destination: destination == nil ? nil : destinationMode)
    }

    private var liveStartTime: String {
        let start = session.startTime.doubleValue
        return start > 0 ? Date(timeIntervalSince1970: start).CurrentStringTimeForCell : ""
    }

    var body: some View {
        let layout = layout
        // Every column but URL is an EXACT width (`frame(width:)`): a cell
        // whose content is wider truncates in place instead of widening its
        // column on this row alone, which is what shifted rows ("PROPFIND"
        // pushed App and URL 6pt right).
        HStack(spacing: SessionTableLayout.stackSpacing) {
            // A relayed connection has no status and no method: the Code cell
            // carries the "not decrypted" glyph and Method stays empty, so
            // the row reads as a connection, never as a request with a
            // missing answer.
            Group {
                if let live {
                    LiveCodeCell(model: live, status: session.rspStatus, isSelected: isSelected)
                } else if let ended {
                    EndedRowGlyph(ended: ended, isSelected: isSelected)
                } else if let facts = session.failureFacts {
                    // A request that did not complete — a relay included (its
                    // connect failed, or the idle limit closed it): the
                    // outcome's symbol here, the only place the table marks
                    // it; the word and cause are in its tooltip and VoiceOver
                    // label (protocol PRD 3.4).
                    FailureGlyph(facts: facts, isSelected: isSelected)
                } else if session.relayed {
                    RelayGlyph(scheme: session.scheme, pinnedBy: session.pinnedBy, appName: session.processIdentity.displayName, isSelected: isSelected)
                } else {
                    Chip(status: session.rspStatus)
                }
            }
            .frame(width: layout.code, alignment: .center)

            VerticalDivider(color: .clear)

            Text(session.relayed ? "" : session.method)
                .fontWeight(.medium)
                .lineLimit(1)
                // PROPPATCH (78pt) fits 70 at 0.85; MKCALENDAR still truncates.
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(width: layout.method, alignment: .center)

            if let appWidth = layout.app {
                VerticalDivider(color: .clear)

                // Actor before target reads as a sentence: `200 GET [Safari] https://…`.
                ProcessLabel(
                    identity: session.processIdentity,
                    availability: attribution,
                    style: .tableCell(isSelected: isSelected, isAgent: isAgent),
                    agentName: agentName
                )
                .frame(width: appWidth, alignment: .leading)
            }

            VerticalDivider(color: .clear)

            Group {
                if let live {
                    LiveURLCell(model: live, url: session.fullUrl, isSelected: isSelected)
                } else if let ended {
                    (EndedWord.text(isSelected: isSelected) + Text(verbatim: session.fullUrl))
                        .help(LiveRowCopy.endedExplanation(ended.reason) + "\n" + session.fullUrl)
                } else if session.relayed {
                    // `host:port · not decrypted · ↑ … ↓ …` — the endpoint and
                    // the traffic each way, which is all a relay has. A failed
                    // relay says so in the Code cell's glyph and the tooltip.
                    let failure = session.failureFacts
                    (Text(verbatim: session.relayEndpoint)
                        + Text(verbatim: "  ·  \(RecordedExchangeCopy.relayRowWord(scheme: session.scheme, pinnedBy: session.pinnedBy, appName: session.processIdentity.displayName))  ·  \(session.relayBytesText)")
                            .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary))
                        .help(failure.map { FailureRowCopy.accessibilityLabel($0) + "\n" + RecordedExchangeCopy.relayCellHelp(scheme: session.scheme, pinnedBy: session.pinnedBy, appName: session.processIdentity.displayName) }
                              ?? RecordedExchangeCopy.relayCellHelp(scheme: session.scheme, pinnedBy: session.pinnedBy, appName: session.processIdentity.displayName))
                } else if let facts = session.failureFacts {
                    // The outcome is the Code cell's glyph (its own symbol per
                    // outcome, and VoiceOver's label); the URL stays plain.
                    Text(verbatim: session.fullUrl)
                        .help(FailureRowCopy.accessibilityLabel(facts) + "\n" + session.fullUrl)
                } else if let rpc, let word = RPCStatusWord.text(rpc, httpStatus: httpStatus, isSelected: isSelected) {
                    // The RPC's status beside the HTTP one when they differ
                    // in meaning — a gRPC-Web error rides an HTTP 200 —
                    // as a symbol AND a word, before the URL.
                    (word + Text(verbatim: session.fullUrl))
                        .help((RPCStatusWord.label(rpc, httpStatus: httpStatus) ?? "") + "\n" + session.fullUrl)
                        .accessibilityLabel((RPCStatusWord.label(rpc, httpStatus: httpStatus) ?? "") + ", " + session.fullUrl)
                } else {
                    Text(session.fullUrl)
                        .help(session.fullUrl)  // Tooltip with full URL
                }
            }
                .truncationMode(.tail)  // Truncate text from the end if it's too long
                .lineLimit(1)           // Ensure it's a single line for truncation to work
                .fixedSize(horizontal: false, vertical: true)  // Prevents expansion and enables truncation
                .foregroundColor(isSelected ? .white : .primary)
                .frame(minWidth: SessionTableLayout.urlMin, idealWidth: SessionTableLayout.urlIdeal, maxWidth: .infinity, alignment: .leading)

            if let destination {
                VerticalDivider(color: .clear)

                DestinationCell(
                    destination: destination,
                    width: layout.destination ?? SessionTableLayout.destination(.narrow),
                    showsName: layout.destinationShowsName,
                    isSelected: isSelected,
                    tableFailure: destinationTableFailure
                )
            }

            VerticalDivider(color: .clear)

            // A live or ended row has no end time, which `formatRequestTimes`
            // needs; its start is known, so it is shown.
            Text(live != nil || ended != nil ? liveStartTime : formatRequestTimes(session).requestStartTime)
                // Tabular digits: every time is the same width, so the column
                // never truncates one row's time and not the next.
                .monospacedDigit()
                .lineLimit(1)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(width: layout.time, alignment: .leading)

            VerticalDivider(color: .clear)

            Group {
                if live != nil {
                    LiveElapsedCell(startTime: session.startTime.doubleValue, isSelected: isSelected)
                } else if ended != nil {
                    Text(verbatim: "—")
                        .foregroundColor(isSelected ? .white : .secondary)
                } else {
                    Text(formatRequestTimes(session).requestDuration)
                        .foregroundColor(isSelected ? .white : .primary)
                }
            }
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: layout.duration, alignment: .leading)
        }
        .padding(.horizontal, SessionTableLayout.horizontalPadding / 2)
        .padding(.vertical, 5)
        .background(isSelected ? Color(red: 0.23, green: 0.52, blue: 0.96) : (!isEvenRow ? Color.gray.opacity(0.05) : Color.clear)) // Lighter blue for selection and lighter alternating row color
        .contentShape(Rectangle()) // Ensure the whole row is clickable
    }
}

// MARK: - The Destination column

/// The words the Destination column and its Settings toggle share. Kept in
/// the app target beside the cell because they are about THIS column, not
/// about destinations in general (those sentences are `DestinationCopy`'s and
/// are quoted, never retyped).
enum DestinationColumnCopy {
    /// The header tooltip's first sentence and the Settings caption's.
    static let summary = "Where each request went — a country, This Mac, Local Network or Unknown."
    /// The Settings caption's second sentence: what the toggle does NOT
    /// control. `SessionTableLayout.destinationMode` is the rule — and at the
    /// app's default window the pane sits in its narrow band, so the
    /// glyph-only form is the first one most users meet; it is named here
    /// rather than discovered. No width is quoted: the thresholds depend on
    /// whether the App column is showing.
    static let hidesWhenNarrow = "In a narrower traffic pane the column shows the flag or symbol alone — hover it for the name — and it hides itself when there is no room for even that."
}

/// The Destination column's cell (destination-map UX spec §1.3 applied to a
/// 13pt table row): the country's flag or the class symbol, and in wide mode
/// the name beside it — "United States", "This Mac", "Local Network",
/// "Unknown". The name is always the accessibility value and always the
/// tooltip, so a narrow cell that shows only 🇩🇪 still reads "Germany".
///
/// The glyph mirrors `DestinationGlyph`'s rules (flag → class symbol → the
/// `flag` symbol for a country without an emoji flag) instead of embedding
/// it: a selected row's symbol has to turn white like Method and URL, and
/// `DestinationGlyph` draws its symbols secondary, fixed, for the list where
/// nothing is ever painted blue.
private struct DestinationCell: View {
    let destination: TrafficDestination
    /// The column's width, and whether it holds the name beside the glyph
    /// (`SessionTableLayout.Columns.destinationShowsName`).
    let width: CGFloat
    let showsName: Bool
    let isSelected: Bool
    /// The resolver's table failure, appended to Unknown's tooltip — the one
    /// case where "not in the table" is really "there is no table".
    let tableFailure: String?

    private var title: String { CountryPresentation.title(for: destination) }

    /// Unknown reads secondary, like the App column's Unknown: a value, but
    /// not one to catch the eye on 5,000 rows.
    private var textColor: Color {
        destination == .unknown
            ? (isSelected ? .white.opacity(0.75) : .secondary)
            : (isSelected ? .white : .primary)
    }

    private var symbolColor: Color {
        destination == .unknown
            ? (isSelected ? .white.opacity(0.75) : .secondary)
            : (isSelected ? .white : .secondary)
    }

    /// A class: its §6 sentence, led by its name so a hovered symbol is named
    /// before it is explained ("This Mac — Requests to this Mac itself…"). A
    /// country: the name, which the narrow cell does not show.
    private var tooltip: String {
        if let description = DestinationCopy.classDescription(destination, tableFailure: tableFailure) {
            return "\(title) — \(description)"
        }
        return title
    }

    var body: some View {
        HStack(spacing: SessionTableLayout.destinationGlyphSpacing) {
            glyph
                .frame(width: SessionTableLayout.destinationGlyphWidth, height: 16)
                .accessibilityHidden(true)
            if showsName {
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(textColor)
            }
        }
        .frame(width: width, alignment: showsName ? .leading : .center)
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Destination")
        .accessibilityValue(title)
    }

    @ViewBuilder
    private var glyph: some View {
        if let symbol = CountryPresentation.symbolName(for: destination) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(symbolColor)
        } else {
            let flag = CountryPresentation.flag(for: destination.isoCode ?? "")
            if flag.isEmpty {
                Image(systemName: "flag")
                    .font(.system(size: 13))
                    .foregroundStyle(symbolColor)
            } else {
                // 14pt: 20pt wide, the glyph box — a 13pt flag is 19 and reads
                // a shade small beside the App column's 16pt icon.
                Text(flag)
                    .font(.system(size: 14))
            }
        }
    }
}

// use our own divider, because the native one doesn't support a clear color
struct VerticalDivider: View {
    
    let color: Color
    let width: CGFloat
    
    init(color: Color, width: CGFloat = 1.0) {
        self.color = color
        self.width = width
    }
    
    var body: some View {
        color
            .frame(width: width)
    }
}

/// A Headers tab: the headers, then — under their own heading — the
/// trailers the core recorded since C13 (header fields sent after the body:
/// an HTTP/2 trailing HEADERS frame, an HTTP/1.1 chunked trailer section;
/// native gRPC's `grpc-status` lives there). Drawn by the core's own
/// renderer from a copy of the row whose headers ARE its trailers, so both
/// sections share one typography; only the heading is changed.
enum HeadersWithTrailers {
    static func render(_ session: SessionCodable, side: SessionMode) -> NSAttributedString {
        let renderer = SessionDetailsRenderer()
        let type: SessionDetailsRenderer.RenderType = side == .Request ? .requestHeaders : .responseHeaders
        let headers = renderer.render(session, contentType: type)
        guard let trailersRow = side == .Request ? session.requestTrailersAsHeaders : session.responseTrailersAsHeaders else {
            return headers
        }
        let trailers = NSMutableAttributedString(attributedString: renderer.render(trailersRow, contentType: type))
        let headerTitle = side == .Request ? "Request Headers" : "Response Headers"
        let trailerTitle = side == .Request ? SessionTrailersCopy.requestTitle : SessionTrailersCopy.responseTitle
        // ⚠️ Tied to the CLOSED core's heading text: `SessionDetailsRenderer`
        // titles these sections "Request Headers" / "Response Headers". If a
        // core rebuild changes that wording the retitle misses, so the miss
        // prepends our own heading line rather than leaving the trailers under
        // a second "Response Headers". Move the title into a renderer option
        // on the next core change (protocol-engine doc §S9.5).
        let range = (trailers.string as NSString).range(of: headerTitle)
        if range.location != NSNotFound {
            trailers.replaceCharacters(in: range, with: "\(trailerTitle) · \(SessionTrailersCopy.caption)")
        } else {
            trailers.insert(NSAttributedString(string: "\(trailerTitle) · \(SessionTrailersCopy.caption)\n"), at: 0)
        }
        let output = NSMutableAttributedString(attributedString: headers)
        if !output.string.hasSuffix("\n") { output.append(NSAttributedString(string: "\n")) }
        output.append(NSAttributedString(string: "\n"))
        output.append(trailers)
        return output
    }
}

struct SessionRequestTabView: View, Equatable {
    let session: SessionCodable
    @Binding var selectedTabRequest: NetworkInspectorTabRequest
    private var renderer: SessionDetailsRenderer { SessionDetailsRenderer() }
    
    var body: some View {
        switch selectedTabRequest {
            case .summary:
            RichSessionTextView(viewModel: .init(string: renderer.render(session, contentType: .requestSummary)))
            case .headers:
            RichSessionTextView(viewModel: .init(string: HeadersWithTrailers.render(session, side: .Request)))
            case .request:
                // A body the extension kept only in part says so ABOVE it —
                // a prefix with no notice reads as the whole body.
                RetainedBodyContainer(notice: session.requestBodyNotice) {
                    if let contentType = ContentType(rawValue: session.reqContentType),
                       contentType.isJSON && !session.reqBody.isEmpty {
                        RichSessionTextView(viewModel: .init(string: renderer.render(session, contentType: .requestBody)))
                    } else {
                       placeholder
                    }
                }
            case .metrics:
                NetworkMetricsView(session: session)
            case .curl:
            RichSessionTextView(viewModel: .init(string: renderer.renderPreformatted(session.cURL)))
            }
    }
    
    // this prevents rerenders when new session is added in the session state
    static func == (lhs: SessionRequestTabView, rhs: SessionRequestTabView) -> Bool {
        // Only re-render if the session changes: its id, or — for a live row,
        // which keeps its id — its content (`detailRevision`).
        return lhs.session.id == rhs.session.id && lhs.session.detailRevision == rhs.session.detailRevision
            && lhs.selectedTabRequest == rhs.selectedTabRequest
    }
    
    @ViewBuilder
    private var placeholder: some View {
        PlaceholderView(imageName: "exclamationmark.circle", title: "Not Available")
    }
}

struct SessionResponseTabView: View, Equatable {
    let session: SessionCodable
    @Binding var selectedTabResponse: NetworkInspectorTabResponse
    /// The row's live model while it is in flight: the Body tab shows the
    /// text as it arrives and Events appends (protocol-engine doc §S6).
    var live: LiveRowModel? = nil
    private var renderer: SessionDetailsRenderer { SessionDetailsRenderer() }
    
    var body: some View {
        GeometryReader { geometry in
            // The core scales image attachments to this size and locks focus
            // on the scaled NSImage. A ZERO size — which the first layout pass
            // inside an AppKit-hosted pane can deliver — makes that a size-zero
            // image and `lockFocus` throws NSImageCacheException, taking the
            // app down. Fall back to the renderer's own default until the pane
            // has a real size.
            let maxSize = geometry.size.width > 0 && geometry.size.height > 0
                ? geometry.size
                : CGSize(width: 300, height: 300)

            switch shownTab {
            case .summary:
                RichSessionTextView(viewModel: .init(string: renderer.render(session, contentType: .responseSummary(attachmentSize: maxSize))))
            case .headers:
                RichSessionTextView(viewModel: .init(string: HeadersWithTrailers.render(session, side: .Response)))
            case .response:
                if let live {
                    LiveResponseBodyView(model: live)
                } else {
                    RetainedBodyContainer(notice: session.responseBodyNotice) {
                        RichSessionTextView(viewModel: .init(string: renderer.render(session, contentType: .responseBody(attachmentSize: maxSize))))
                    }
                }
            case .metrics:
                NetworkMetricsView(session: session)
            case .messages:
                WebSocketMessagesView(session: session)
                    .id(session.id)
            case .rpc:
                RPCMessagesView(session: session)
                    .id(session.id)
            case .events:
                if let live {
                    VStack(spacing: 0) {
                        LiveDetailBanner(model: live)
                        Divider()
                        StreamEventsView(session: session, live: live)
                    }
                } else {
                    StreamEventsView(session: session)
                }
            }
        }
    }

    /// Events is remembered across sessions; one that is not a stream shows
    /// its Body instead (the toolbar highlights Body to match).
    private var shownTab: NetworkInspectorTabResponse {
        NetworkInspectorTabResponse.tabs(for: session, live: live).contains(selectedTabResponse) ? selectedTabResponse : .response
    }
    
    // this prevents rerenders when new session is added in the session state ^^,
    static func == (lhs: SessionResponseTabView, rhs: SessionResponseTabView) -> Bool {
        // Re-render when the session changes — its id, or its content for a
        // live row that keeps its id (`detailRevision`), or whether it is
        // still live. A progress message changes none of these: the live
        // views observe their model themselves.
        return lhs.session.id == rhs.session.id && lhs.session.detailRevision == rhs.session.detailRevision
            && lhs.live === rhs.live && lhs.selectedTabResponse == rhs.selectedTabResponse
    }
    
    @ViewBuilder
    private var placeholder: some View {
        PlaceholderView(imageName: "exclamationmark.circle", title: "Not Available")
    }
}
