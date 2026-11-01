//
//  TrafficSearchFieldModel.swift
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
//  The durable brain of the toolbar search field — snipperapp 3's
//  `SearchFieldModel`, with `tag:`/`folder:` replaced by `host:` and the
//  filter living on `TrafficSearchState`.
//
//  This object owns the REAL AppKit field (`StableSearchTextField`, created
//  once, self-healing — see TrafficSearchFieldCore.swift) and everything
//  stateful around it: the text, the 300ms debounce, and the suggestions
//  panel. SwiftUI only ever *hosts* the field; destroying and recreating the
//  SwiftUI layer reconnects to the same NSTextField with the same text and
//  caret. The toolbar controller holds it for the life of the window.
//
//  The only published properties are `hasInputText` (drives the ✕ button,
//  flips on empty↔non-empty) and the chip keyboard selection — keystrokes
//  publish nothing through the toolbar item.
//

import AppKit
import MCPKit
import SwiftUI
import Utils

@MainActor
final class TrafficSearchFieldModel: NSObject, ObservableObject, NSTextFieldDelegate {

    static let accessibilityIdentifier = "reqresToolbarSearchField"

    // MARK: - Published (deliberately minimal)

    /// Whether the input currently holds any text — drives the ✕ button.
    @Published private(set) var hasInputText = false

    /// Token-field style: the committed chip the keyboard has "selected"
    /// (Backspace deletes it, ←/→ walk across chips, typing deselects).
    @Published var selectedTokenIndex: Int?

    // MARK: - Durable state

    private let state: TrafficSearchState

    /// Debounces the free-text search.
    private var searchTask: Task<Void, Never>?

    /// The width of the search box (the toolbar slot's width), used to size
    /// the suggestions panel. Kept fresh by the representable.
    var availableWidth: CGFloat = 260

    /// Set just before this object gives up focus on purpose (Escape, Tab),
    /// so `controlTextDidEndEditing` does not mistake it for a forced
    /// teardown and steal the caret back.
    private var intentionalResign = false

    private let panel = TrafficSearchSuggestionsPanel()

    /// Rows currently shown, grouped as the panel draws them — cached at
    /// display time so the keyboard selection and a click always act on
    /// exactly what is on screen.
    private var groups: [TrafficSearchSuggestionGroup] = []

    /// Every row in panel order, info rows included.
    private var rows: [TrafficSearchSuggestion] { groups.flatMap(\.rows) }

    /// The rows ↑/↓ walk and Return commits: one flat index ACROSS the groups,
    /// so ↓ from the last host lands on the first app. Info rows are skipped.
    private var selectableRows: [TrafficSearchSuggestion] {
        TrafficSearchSuggestionGroup.selectableRows(in: groups)
    }

    /// Index into `selectableRows`.
    private var selectedSuggestionIndex = 0

    /// Whether the extension can say which process opened a connection on
    /// this Mac. When it cannot, `app:` and `pid:` offer one line saying so
    /// instead of an empty panel that looks like nothing was captured. Read
    /// on demand from `AppState` — never observed here, for the same reason
    /// `SessionState` is not — and a closure so the probe can force the
    /// degraded state without a broken socket table.
    var attributionAvailability: () -> ProcessAttributionAvailability = { AppState.shared.processAttribution }

    init(state: TrafficSearchState = .shared) {
        self.state = state
        super.init()
    }

    // MARK: - The field

    lazy var field: StableSearchTextField = {
        let field = StableSearchTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.placeholderString = "Search traffic"
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        field.setAccessibilityLabel("Search traffic")
        // Fill whatever width SwiftUI proposes instead of hugging the text.
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        field.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        field.onFocusGained = { [weak self] in self?.fieldDidGainFocus() }
        return field
    }()

    var isFieldFocused: Bool { field.currentEditor() != nil }

    /// The caret sits at position 0 with no selection — the boundary where
    /// Backspace/← start acting on the committed chips.
    private var caretAtStart: Bool {
        guard let editor = field.currentEditor() else { return false }
        return editor.selectedRange.location == 0 && editor.selectedRange.length == 0
    }

    private var committedTokens: [TrafficSearchToken] { state.filter.tokens }

    // MARK: - Wiring

    /// Chips or the host list changed under an open panel — refresh its rows.
    /// Called from `updateNSView`, inside SwiftUI's update; the window work
    /// is deferred a turn so AppKit window ordering never runs mid-update.
    func environmentDidChange() {
        guard panel.isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.refreshSuggestionList()
        }
    }

    /// Asks the field to take keyboard focus, now if it is in a window,
    /// otherwise as soon as it lands in one (⌘F while the item is folded).
    func requestFocus() {
        field.focusWhenAttached()
    }

    func cancelPendingSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    func clearAll() {
        field.stringValue = ""
        if hasInputText { hasInputText = false }
        if selectedTokenIndex != nil { selectedTokenIndex = nil }
        cancelPendingSearch()
        hidePanel()
        state.clear()
    }

    /// A chip was clicked — select it and keep the caret in the field so
    /// ←/→/Backspace work immediately.
    func selectToken(at index: Int) {
        guard committedTokens.indices.contains(index) else { return }
        selectedTokenIndex = index
        hidePanel()
        field.window?.makeFirstResponder(field)
    }

    func removeToken(_ token: TrafficSearchToken) {
        state.removeToken(token)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        intentionalResign = false
        // Typing hands the keyboard back to the text — chip selection ends.
        if selectedTokenIndex != nil { selectedTokenIndex = nil }
        let text = field.stringValue
        if hasInputText != !text.isEmpty { hasInputText = !text.isEmpty }
        handleInputChange(text)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        hidePanel()

        // Editing ends for two very different reasons, and only one is the
        // user's doing: a click elsewhere / Tab / our own Escape resign, or
        // AppKit force-ending the session because a toolbar rebuild removed a
        // view containing the window's field editor. Take the caret back only
        // in the second case. Discriminators: our own resigns set
        // `intentionalResign`; Tab/Return arrive as an NSTextMovement; a
        // click-away means the event being processed RIGHT NOW is a mouse
        // event in this window.
        let movementRaw = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        let userNavigated = movementRaw == NSTextMovement.tab.rawValue
            || movementRaw == NSTextMovement.backtab.rawValue
            || movementRaw == NSTextMovement.return.rawValue

        let mouseTypes: Set<NSEvent.EventType> = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
        ]
        let userClickedAway: Bool = {
            guard let event = NSApp.currentEvent,
                  mouseTypes.contains(event.type),
                  event.window === field.window else { return false }
            // `NSApp.currentEvent` is merely the LAST event delivered — only
            // an event being processed right now counts.
            guard ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5 else { return false }
            // A click INSIDE the field is the click that GAVE us focus.
            let locationInField = field.convert(event.locationInWindow, from: nil)
            return !field.bounds.contains(locationInField)
        }()

        let resignWasIntentional = intentionalResign
        intentionalResign = false

        if !resignWasIntentional && !userNavigated && !userClickedAway {
            let selection = (obj.userInfo?["NSFieldEditor"] as? NSText)?.selectedRange
            field.healFocus(restoring: selection)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            guard panel.isVisible, !selectableRows.isEmpty else { return false }
            navigateSuggestion(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard panel.isVisible, !selectableRows.isEmpty else { return false }
            navigateSuggestion(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            handleSubmit()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            let tokens = committedTokens
            if let index = selectedTokenIndex, tokens.indices.contains(index) {
                // Delete the selected chip, then select the previous one —
                // or hand the caret back when none remains.
                selectedTokenIndex = index > 0 ? index - 1 : nil
                state.removeToken(tokens[index])
                return true
            }
            if caretAtStart, !tokens.isEmpty {
                // First Backspace at the start SELECTS the last chip; the
                // next one deletes it.
                selectedTokenIndex = tokens.count - 1
                hidePanel()
                return true
            }
            return false
        case #selector(NSResponder.deleteForward(_:)):
            let tokens = committedTokens
            if let index = selectedTokenIndex, tokens.indices.contains(index) {
                selectedTokenIndex = index < tokens.count - 1 ? index : nil
                state.removeToken(tokens[index])
                return true
            }
            return false
        case #selector(NSResponder.moveLeft(_:)):
            if let index = selectedTokenIndex {
                if index > 0 { selectedTokenIndex = index - 1 }
                return true
            }
            if caretAtStart, !committedTokens.isEmpty {
                selectedTokenIndex = committedTokens.count - 1
                hidePanel()
                return true
            }
            return false
        case #selector(NSResponder.moveRight(_:)):
            if let index = selectedTokenIndex {
                selectedTokenIndex = index < committedTokens.count - 1 ? index + 1 : nil
                return true
            }
            return false
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            // A selected chip is the most transient state — Escape releases
            // it before it touches the panel, the text or the focus.
            if selectedTokenIndex != nil {
                selectedTokenIndex = nil
                return true
            }
            return handleEscape()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // Deliberate focus navigation — let AppKit move the caret.
            intentionalResign = true
            return false
        default:
            return false
        }
    }

    // MARK: - Input handling

    private func handleInputChange(_ text: String) {
        if TrafficSearchTokenKind.parse(text) != nil {
            // Mid-token: an armed free-text debounce must NOT fire — it would
            // search for "hos…" the user never asked for. Drop a partial free
            // text already pinned by the debounce before the ":" arrived.
            cancelPendingSearch()
            state.updateFreeText("")
            selectedSuggestionIndex = 0
            refreshSuggestionList()
        } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            hidePanel()
            cancelPendingSearch()
            searchTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.state.updateFreeText(text)
            }
        } else {
            cancelPendingSearch()
            state.updateFreeText("")
            if isFieldFocused {
                selectedSuggestionIndex = 0
                refreshSuggestionList()
            } else {
                hidePanel()
            }
        }
    }

    private func handleSubmit() {
        let selectable = selectableRows
        if panel.isVisible, selectable.indices.contains(selectedSuggestionIndex) {
            // The row carries its own kind: under an empty field the lit row
            // may be a host or an app, and re-parsing the (empty) text could
            // not tell which. It also carries what it commits — a destination
            // row reads "Germany" and commits `DE`.
            let row = selectable[selectedSuggestionIndex]
            commitToken(kind: row.kind, query: row.commitValue)
        } else if let parsed = TrafficSearchTokenKind.parse(field.stringValue), !parsed.query.isEmpty {
            // Return on "host:api.example.com" commits what was typed even
            // when it is not a host we have seen.
            commitToken(kind: parsed.kind, query: parsed.query)
        } else {
            // Immediate search on Return.
            cancelPendingSearch()
            state.updateFreeText(field.stringValue)
        }
    }

    /// Escape, in precedence order — one action per press:
    ///   1. panel open      -> dismiss it
    ///   2. content present -> clear it
    ///   3. otherwise       -> give up focus
    private func handleEscape() -> Bool {
        if panel.isVisible {
            hidePanel()
            return true
        }
        if !state.filter.isEmpty || !field.stringValue.isEmpty {
            clearAll()
            return true
        }
        intentionalResign = true
        field.window?.makeFirstResponder(nil)
        return true
    }

    private func fieldDidGainFocus() {
        guard field.stringValue.isEmpty else { return }
        // A turn later, so the first focus does not flash a panel while the
        // click that gave focus is still being processed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isFieldFocused, self.field.stringValue.isEmpty else { return }
            self.selectedSuggestionIndex = 0
            self.refreshSuggestionList()
        }
    }

    // MARK: - Suggestions

    /// Commits a token, or falls back to free text when the query cannot make
    /// one. `status:banana` becomes an ordinary search for that text rather
    /// than a token that silently matches nothing, which would be
    /// indistinguishable from the search having done nothing at all.
    private func commitToken(kind: TrafficSearchTokenKind, query: String) {
        guard let token = TrafficSearchToken.parse(kind: kind, query: query) ?? destinationToken(forName: query, kind: kind) else {
            cancelPendingSearch()
            state.updateFreeText(field.stringValue)
            hidePanel()
            return
        }
        state.addToken(token)
        field.stringValue = ""
        if hasInputText { hasInputText = false }
        hidePanel()
    }

    /// `country:germany` typed with no row to pick (destination-map UX spec
    /// §5.3): the name is resolved to its code HERE, before the parser sees
    /// it — Utils owns no locale, and the parser accepts codes and the three
    /// class words only. A class label typed in full ("this mac") resolves
    /// too. Only a UNIQUE country match commits: `country:united` could mean
    /// three countries and stays free text, like `status:banana`. Nil for
    /// every other kind.
    private func destinationToken(forName query: String, kind: TrafficSearchTokenKind) -> TrafficSearchToken? {
        guard kind == .country else { return nil }
        let name = query.trimmingCharacters(in: .whitespaces)
        for classToken in TrafficDestination.specialTokens
        where TrafficSearchCountryMatch.displayName(forToken: classToken).caseInsensitiveCompare(name) == .orderedSame {
            return .country(classToken)
        }
        return CountryPresentation.code(matchingName: name).map { .country($0) }
    }

    private func navigateSuggestion(_ direction: Int) {
        let newIndex = selectedSuggestionIndex + direction
        guard selectableRows.indices.contains(newIndex) else { return }
        selectedSuggestionIndex = newIndex
        presentPanel(updateOnly: true)
    }

    /// Recomputes the rows for the current text and shows/updates/hides the
    /// panel accordingly. A panel with only info rows still shows — the
    /// line saying why `app:` has nothing is the point of it.
    private func refreshSuggestionList() {
        groups = computeGroups()
        if rows.isEmpty {
            hidePanel()
            return
        }
        let selectableCount = selectableRows.count
        if selectedSuggestionIndex >= selectableCount {
            selectedSuggestionIndex = max(0, selectableCount - 1)
        }
        presentPanel(updateOnly: false)
    }

    private func hidePanel() {
        panel.hide()
    }

    private func presentPanel(updateOnly: Bool) {
        let content = AnyView(
            TrafficSearchSuggestionsView(
                groups: groups,
                selectedIndex: selectedSuggestionIndex,
                onSelect: { [weak self] row in
                    self?.commitToken(kind: row.kind, query: row.commitValue)
                }
            )
        )
        let width = max(240, availableWidth)
        if updateOnly || panel.isVisible {
            panel.update(content: content, width: width)
        } else {
            panel.show(below: field, width: width, content: content)
        }
    }

    #if DEBUG
    /// For the headless search probe (`REQRES_SEARCH_PROBE`).
    var debugPanelIsVisible: Bool { panel.isVisible }
    /// The titles Return can commit, in keyboard order.
    var debugSuggestions: [String] { selectableRows.map(\.title) }
    /// Every group as the panel draws it: `Hosts[api.example.com, …]
    /// Apps[claude (2 processes), Unknown] ·[hint text]`, info rows in braces.
    var debugGroups: String {
        groups.map { group in
            let rows = group.rows.map { row -> String in
                guard row.isSelectable else { return "{\(row.title)}" }
                return row.detail.map { "\(row.title) (\($0))" } ?? row.title
            }
            return "\(group.title.isEmpty ? "·" : group.title)[\(rows.joined(separator: ", "))]"
        }.joined(separator: " ")
    }
    /// Which row is lit, by keyboard index.
    var debugSelectedIndex: Int { selectedSuggestionIndex }
    func debugPanelPNG() -> Data? { panel.snapshotPNG() }

    /// Seeds the attribution lookups for the probe on a Mac with no captured
    /// traffic: one identity per app (its icon then comes through
    /// `ProcessIconCache`, so the real icon path runs), a process count for
    /// the "N processes" detail, and the pids `pid:` offers — restricted to
    /// the committed `app:` chips the way `SessionState.pidCandidates` is.
    func debugSeedAttribution(apps: [(name: String, path: String, processes: Int)], pids: [(pid: Int, app: String)]) {
        let entries = Dictionary(uniqueKeysWithValues: apps.map { app in
            (
                app.name.lowercased(),
                (
                    identity: ProcessIdentity(
                        name: app.name,
                        pid: pids.first { $0.app == app.name }?.pid,
                        executablePath: app.path
                    ),
                    processes: app.processes
                )
            )
        })
        state.appLookup = { entries[$0.lowercased()] }
        state.appLookupByPid = { pid in pids.first { $0.pid == pid }?.app }
        state.pidSuggestionSource = { committed in
            // The index restricts by the filter's own substring rule, so the
            // seed does too: `app:cl` keeps claude's pids.
            pids.filter { candidate in
                committed.isEmpty || committed.contains { TrafficSearchAppMatch.matches($0, appName: candidate.app) }
            }
        }
    }
    #endif

    // MARK: - Row assembly (UX spec §4.2)

    /// The groups for the current text. Hosts, methods and statuses are as
    /// before; apps and pids come from the attribution index through the
    /// state's sources; an empty focused field offers the busiest hosts and
    /// apps under a syntax hint.
    private func computeGroups() -> [TrafficSearchSuggestionGroup] {
        let text = field.stringValue
        if let parsed = TrafficSearchTokenKind.parse(text) {
            switch parsed.kind {
            case .host:
                return nonEmpty([hostGroup(matching: parsed.query, limit: 10)])
            case .app:
                guard attributionAvailability() != .unavailable else { return [unavailableGroup(for: .app)] }
                return nonEmpty([appGroup(matching: parsed.query, limit: 10)])
            case .pid:
                guard attributionAvailability() != .unavailable else { return [unavailableGroup(for: .pid)] }
                return nonEmpty([pidGroup(matching: parsed.query, limit: 10)])
            case .country:
                return nonEmpty([countryGroup(matching: parsed.query, limit: 10)])
            case .method, .status, .outcome, .grpc, .proto:
                // Fixed vocabularies, so they are offered from the kind itself
                // rather than from whatever happens to have been captured.
                let query = parsed.query.trimmingCharacters(in: .whitespaces).lowercased()
                let titles = parsed.kind.staticSuggestions.filter {
                    query.isEmpty || $0.lowercased().hasPrefix(query)
                }
                return nonEmpty([TrafficSearchSuggestionGroup(
                    title: parsed.kind.suggestionsTitle,
                    rows: titles.map { TrafficSearchSuggestion(kind: parsed.kind, title: $0, icon: .symbol(parsed.kind.symbolName)) }
                )])
            case .path:
                // A path has no useful vocabulary to offer: it is whatever the
                // user is looking for, and a list of every path seen would be
                // longer than the panel and never the one they want.
                return []
            }
        }
        if text.trimmingCharacters(in: .whitespaces).isEmpty, isFieldFocused {
            // An empty focused field offers the busiest hosts and apps as a
            // hint that the prefixes exist, and says so in words underneath.
            var groups = nonEmpty([hostGroup(matching: "", limit: 4), appGroup(matching: "", limit: 3)])
            groups.append(TrafficSearchSuggestionGroup(title: "", rows: [syntaxHint]))
            return groups
        }
        return []
    }

    private func nonEmpty(_ groups: [TrafficSearchSuggestionGroup]) -> [TrafficSearchSuggestionGroup] {
        groups.filter { !$0.rows.isEmpty }
    }

    private func hostGroup(matching query: String, limit: Int) -> TrafficSearchSuggestionGroup {
        let hosts = TrafficSearchSuggestions.hosts(
            matching: query, in: state.suggestionSource(), excluding: state.filter.hosts, limit: limit
        )
        return TrafficSearchSuggestionGroup(
            title: TrafficSearchTokenKind.host.suggestionsTitle,
            rows: hosts.map { TrafficSearchSuggestion(kind: .host, title: $0, icon: .symbol(TrafficSearchTokenKind.host.symbolName)) }
        )
    }

    /// Apps busiest first, with "Unknown" last whatever the ranking did with
    /// it — it is the table's placeholder, not a competitor for the top of the
    /// list. The detail says how many processes made the app's requests, only
    /// when more than one did: it is the pointer to `pid:`.
    private func appGroup(matching query: String, limit: Int) -> TrafficSearchSuggestionGroup {
        var apps = TrafficSearchSuggestions.apps(
            matching: query, in: state.appSuggestionSource(), excluding: state.filter.apps, limit: limit
        )
        if let unknown = apps.firstIndex(where: { $0.caseInsensitiveCompare(TrafficSearchAppMatch.unknown) == .orderedSame }),
           unknown != apps.count - 1 {
            apps.append(apps.remove(at: unknown))
        }
        let rows = apps.map { app -> TrafficSearchSuggestion in
            let processes = state.appLookup(app)?.processes ?? 0
            return TrafficSearchSuggestion(
                kind: .app,
                title: app,
                detail: processes > 1 ? "\(processes) processes" : nil,
                icon: TrafficSearchProcessLookup.icon(forApp: app, state: state)
            )
        }
        return TrafficSearchSuggestionGroup(title: TrafficSearchTokenKind.app.suggestionsTitle, rows: rows)
    }

    /// Processes busiest first — only those of the committed `app:` chips when
    /// there are any — prefix-matched on the digits typed. A pid already a
    /// chip is not offered again, and one the source lists twice is offered
    /// once (a row id must be unique in the panel).
    private func pidGroup(matching query: String, limit: Int) -> TrafficSearchSuggestionGroup {
        let digits = query.trimmingCharacters(in: .whitespaces)
        var seen = Set<Int>()
        var rows: [TrafficSearchSuggestion] = []
        for candidate in state.pidSuggestionSource(state.filter.apps) where rows.count < limit {
            guard !state.filter.containsPid(candidate.pid), !seen.contains(candidate.pid) else { continue }
            guard digits.isEmpty || String(candidate.pid).hasPrefix(digits) else { continue }
            seen.insert(candidate.pid)
            rows.append(TrafficSearchSuggestion(
                kind: .pid,
                title: String(candidate.pid),
                detail: candidate.app,
                icon: TrafficSearchProcessLookup.icon(forApp: candidate.app, state: state)
            ))
        }
        return TrafficSearchSuggestionGroup(title: TrafficSearchTokenKind.pid.suggestionsTitle, rows: rows)
    }

    /// Destinations busiest first, Unknown last (destination-map UX spec
    /// §5.3): the query matches the localised name AND the token, so `un`
    /// offers United States and Unknown and `de` offers Germany. The row
    /// shows the name with its flag and the request count, and commits the
    /// TOKEN — the parser accepts codes, never names. A destination already
    /// a chip is not offered again.
    private func countryGroup(matching query: String, limit: Int) -> TrafficSearchSuggestionGroup {
        let destinations = TrafficSearchSuggestions.destinations(
            matching: query, in: state.countrySuggestionSource(), excluding: state.filter.countries, limit: limit
        )
        let rows = destinations.map { destination in
            TrafficSearchSuggestion(
                kind: .country,
                title: destination.title,
                commitValue: destination.token,
                detail: CountryPresentation.plural(destination.requests, "request"),
                icon: TrafficSearchDestinationLookup.icon(forToken: destination.token)
            )
        }
        return TrafficSearchSuggestionGroup(title: TrafficSearchTokenKind.country.suggestionsTitle, rows: rows)
    }

    /// The one line `app:` and `pid:` show when the extension cannot attribute
    /// connections on this Mac (UX spec §9, explanation 3 of 5).
    private func unavailableGroup(for kind: TrafficSearchTokenKind) -> TrafficSearchSuggestionGroup {
        TrafficSearchSuggestionGroup(title: "", rows: [
            .info(id: "unavailable", kind: kind, text: "Not available on this Mac — Capture ▸ Diagnose Setup… explains."),
        ])
    }

    /// The footer under an empty field's hosts and apps. Seven prefixes wrap
    /// to two lines at the panel's width; the info row allows two.
    private var syntaxHint: TrafficSearchSuggestion {
        .info(id: "hint", kind: .host, text: Self.syntaxHintText)
    }

    /// One spelling for the hint, so the probe's check and the panel cannot
    /// drift apart.
    static let syntaxHintText = "host: · app: · pid: · country: · method: · status: · path:"
}
