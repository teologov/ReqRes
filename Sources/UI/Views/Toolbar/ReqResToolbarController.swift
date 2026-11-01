//
//  ReqResToolbarController.swift
//  ReqRes
//
//  Created by OloApps on 16.09.2026.
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
//  The app-owned `NSToolbar`, modelled on Apple Mail and Notes.
//
//  Arrangement — the order itself lives in `ReqResToolbarPlan` (Utils), where
//  it is unit-tested:
//
//    …flex… ⌸ │sidebar sep│ [host ⌄] │list sep│ ＋ ▶︎ ⚠︎ · 🗑 ✉︎ · [9/10 ▬▬] …flex… [search]
//
//  Load-bearing rules, all measured:
//   * The tracking separators need a REAL NSSplitView — provided by
//     `ReqResSplitHost`, which replaced `NavigationSplitView`.
//   * Clusters are single items hosting SwiftUI views: the system draws ONE
//     platter per item at standard height. Groups of bordered subitems render
//     taller chrome, flat image items refuse to merge, and unbordered subitems
//     lose the platter entirely. Hosted content must NOT draw its own glass.
//   * Hosted items carry a `menuFormRepresentation`, or the native overflow
//     chevron shows an empty row for them at narrow widths.
//   * `NSMenuToolbarItem` for ＋, not a hosted SwiftUI `Menu`: a SwiftUI Menu
//     whose label is an Image renders it at a fixed size and ignores every
//     sizing modifier — and in 1.0.4 dropped the glyph altogether, leaving the
//     bare chevron bubble with no glyph.
//   * `NSSearchToolbarItem` for search: it is the only thing that natively
//     compresses and then collapses to a magnifier, and — behind the trailing
//     flexible space — it is what actually pins the field to the right edge.
//   * The window title stays HIDDEN, and the selected host is a hosted chip.
//     AppKit's native title view has a 160pt floor and cannot overflow; with
//     the sidebar collapsed it shoved the list separator 79pt off its divider
//     and floated the title over the traffic pane (measured 2026-09-16).
//     Items overflow to the chevron; the title view does not. SwiftUI
//     re-asserts `.visible` whenever it pushes a title, so the hide is
//     re-applied from KVO, not set once.
//

import AppKit
import SwiftUI
import Combine
import MCPKit
import Utils
import XReqResCore

@MainActor
final class ReqResToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate, NSMenuItemValidation {

    /// The SwiftUI-backed clusters, supplied by `AppView` (they capture its
    /// observable objects). ＋ and search are native AppKit items.
    struct SlotViews {
        let host: AnyView
        let capture: AnyView
        let tools: AnyView
        let inspections: AnyView
    }

    /// Set by `ReqResSplitHost` before `install` runs.
    var slots: (() -> SlotViews)?

    /// Posted when the ＋ menu's rows are chosen, so the menu path and the
    /// overflow-chevron path stay identical.
    static let addHostFilter = Notification.Name("com.oloapps.ReqRes.toolbar.addHostFilter")
    static let createOverride = Notification.Name("com.oloapps.ReqRes.toolbar.createOverride")
    /// Posted by the ⌘F menu command; focuses the search field.
    static let focusSearch = Notification.Name("com.oloapps.ReqRes.toolbar.focusSearch")

    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private weak var window: NSWindow?

    /// The main window this toolbar is installed on, nil before `install`.
    /// One toolbar per window, so it is how AppView names its window to
    /// PaywallPresentation, which picks the one window that shows the ReqRes
    /// Pro sheet.
    var hostWindow: NSWindow? { window }

    private weak var splitView: NSSplitView?
    private var toolbar: NSToolbar?
    private var toolbarObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var isReassertingToolbar = false
    private var isApplyingTitlebar = false
    /// Set the instant the toolbar is attached to the window — and NOTHING
    /// may read `toolbar.items` before that. A read triggers AppKit's
    /// placeholder-item load early; the attach then loads them again over a
    /// stale index and throws NSInternalInconsistencyException from
    /// `-[NSToolbar _loadAllPlaceholderItems]` (crashed once at launch: the
    /// split view resized inside `install`, its observer read the items).
    private var isAttached = false
    private var slotViews: SlotViews?
    private var cancellables = Set<AnyCancellable>()
    /// The search field's durable brain (the real NSTextField, the debounce,
    /// the suggestions panel) — created once, for the life of the window.
    let searchModel = TrafficSearchFieldModel()
    private var lastRepair = Date.distantPast
    private var splitObserver: NSObjectProtocol?
    private var repairedItems: Set<NSToolbarItem.Identifier> = []

    #if DEBUG
    /// `REQRES_TOOLBAR_TRACE=1`: every delegate call and toolbar hand-off, to
    /// stderr, unbuffered — readable even from a run that dies mid-load.
    private static let traces = ProcessInfo.processInfo.environment["REQRES_TOOLBAR_TRACE"] != nil
    private static var traceDepth = 0
    private static func trace(_ message: String) {
        guard traces else { return }
        FileHandle.standardError.write(("[trace] " + String(repeating: "  ", count: traceDepth) + message + "\n").data(using: .utf8)!)
    }
    #endif

    private static func identifier(_ slot: ReqResToolbarSlot) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(slot.identifier)
    }

    /// Maps our plan onto AppKit's vocabulary — the system slots resolve to
    /// AppKit's own identifiers so we get its behaviour, not a lookalike.
    private static func toolbarIdentifier(for slot: ReqResToolbarSlot) -> NSToolbarItem.Identifier {
        switch slot {
        case .flexibleSpace: return .flexibleSpace
        case .space: return .space
        case .toggleSidebar: return .toggleSidebar
        case .sidebarSeparator: return .sidebarTrackingSeparator
        default: return identifier(slot)
        }
    }

    private static func slot(for identifier: NSToolbarItem.Identifier) -> ReqResToolbarSlot? {
        ReqResToolbarSlot.allCases.first { toolbarIdentifier(for: $0) == identifier }
    }

    // MARK: - Install

    /// Idempotent. Called by `ReqResSplitHost` once its NSSplitView is in the
    /// window — the tracking separators need both.
    func install(on window: NSWindow, splitView: NSSplitView) {
        if self.window === window, toolbar != nil, window.toolbar === toolbar { return }
        self.window = window
        self.splitView = splitView
        self.slotViews = slots?()

        let toolbar = NSToolbar(identifier: "ReqResMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        self.toolbar = toolbar

        // Content runs under the titlebar so the sidebar material is
        // full-height, and the centre title reserve is reclaimed — see the
        // header for why the title must never be visible here.
        window.styleMask.insert(.fullSizeContentView)
        if #available(macOS 26.0, *) {
            window.toolbarStyle = .automatic
        } else {
            window.toolbarStyle = .unified
        }

        #if DEBUG
        Self.trace("install: window.toolbar before = \(window.toolbar.map { "\($0.identifier) items=\($0.items.count)" } ?? "nil"), contentVC=\(type(of: window.contentViewController as Any)), splitView.window=\(splitView.window === window), arranged=\(splitView.arrangedSubviews.count)")
        #endif
        // Build EVERY item now, before the toolbar is attached, so the delegate
        // only ever hands back cached instances. Constructing an
        // `NSSearchToolbarItem` inside AppKit's placeholder load re-entered
        // that load (traced: a nested `itemFor search` before the constructor
        // returned), which built a second item and threw
        // NSInternalInconsistencyException on ~half of all launches.
        for slot in ReqResToolbarPlan.customSlots {
            let identifier = Self.toolbarIdentifier(for: slot)
            if items[identifier] == nil, let item = makeItem(slot: slot, identifier: identifier) {
                items[identifier] = item
            }
        }

        isReassertingToolbar = true
        window.toolbar = toolbar
        isReassertingToolbar = false
        isAttached = true
        #if DEBUG
        Self.trace("install: attached, items=\(toolbar.items.count)")
        #endif
        applyTitlebar(to: window)

        // SwiftUI flips `titleVisibility` back to `.visible` whenever it
        // pushes a title (AppView pins it to "" so that is rare, but the app
        // name is its fallback), and a visible-but-empty title still reserves
        // its 160pt floor. Re-hide on every change, guarded against our own.
        titleObservation = window.observe(\.titleVisibility, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isApplyingTitlebar, window.titleVisibility != .hidden else { return }
                self.applyTitlebar(to: window)
            }
        }

        // Hosted SwiftUI settles its size asynchronously after install, so a
        // transient overshoot can clip a cluster into the overflow — and a
        // static toolbar never re-evaluates on its own.
        for delay in [1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.repairEjectionsIfNeeded()
            }
        }

        // If anything replaces the window's toolbar later (SwiftUI does this
        // when a view in the hierarchy declares `.toolbar`), put ours back.
        // Guarded against our own write above.
        toolbarObservation = window.observe(\.toolbar, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isReassertingToolbar else { return }
                guard let mine = self.toolbar, window.toolbar !== mine else { return }
                #if DEBUG
                Self.trace("KVO: window.toolbar replaced by \(window.toolbar.map { "\($0.identifier)" } ?? "nil") — re-asserting")
                #endif
                self.isReassertingToolbar = true
                window.toolbar = mine
                self.isReassertingToolbar = false
                self.applyTitlebar(to: window)
            }
        }

        #if DEBUG
        // `REQRES_TOOLBAR_LOG=1` also reports where the window's frame comes
        // from: its AppKit autosave name and every persisted key that looks
        // like a frame or split state. `REQRES_RESET_WINDOW_FRAME=1` removes
        // those keys — the way to see the `.defaultSize` on a machine whose
        // saved frame was written by headless probe runs.
        if ProcessInfo.processInfo.environment["REQRES_TOOLBAR_LOG"] != nil {
            let defaults = UserDefaults.standard
            let keys = defaults.dictionaryRepresentation().keys
                .filter { $0.contains("Frame") || $0.contains("Split") || $0.contains("Window") }
                .sorted()
            let all = defaults.dictionaryRepresentation()
            let suspicious = all.filter { String(describing: $0.value).contains("1280") || String(describing: $0.value).contains("800") }
            var report = "[window] defaults keys=\(all.keys.count) mentioning 1280/800: \(suspicious.keys.sorted())\n"
            report += "[window] frame at install=\(Int(window.frame.width))×\(Int(window.frame.height))"
                + " autosaveName=\"\(window.frameAutosaveName)\" restorable=\(window.isRestorable)\n"
            for key in keys { report += "  default \"\(key)\" = \(defaults.object(forKey: key) ?? "nil")\n" }
            if ProcessInfo.processInfo.environment["REQRES_RESET_WINDOW_FRAME"] != nil {
                for key in keys { defaults.removeObject(forKey: key) }
                // The frame is ALSO kept by macOS window restoration, which the
                // app cannot delete (the archive is not where the API says).
                // It is rewritten at a graceful quit — so make the frame this
                // run will save BE the default, and leave the window restorable.
                window.setContentSize(ReqResMainWindow.defaultSize)
                window.center()
                // And the window-state archive, which restores the frame too.
                if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
                   let bundleID = Bundle.main.bundleIdentifier {
                    let state = library.appendingPathComponent("Saved Application State/\(bundleID).savedState")
                    let existed = FileManager.default.fileExists(atPath: state.path)
                    try? FileManager.default.removeItem(at: state)
                    report += "  saved state \(state.path): \(existed ? "removed" : "absent")\n"
                }
                report += "  removed \(keys.count) key(s); window set to the default size\n"
            }
            FileHandle.standardOutput.write(report.data(using: .utf8)!)
        }
        // `REQRES_TOOLBAR_APPEARANCE=light|dark` forces the appearance, so both
        // can be rendered headlessly regardless of the system setting.
        switch ProcessInfo.processInfo.environment["REQRES_TOOLBAR_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // `REQRES_TOOLBAR_WIDTH=900` forces a window width, so the narrow-width
        // fold (where items move into the overflow chevron) can be inspected
        // without dragging the window by hand.
        if let widthString = ProcessInfo.processInfo.environment["REQRES_TOOLBAR_WIDTH"],
           let width = Double(widthString) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
                guard let window else { return }
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
            }
        }
        // `REQRES_TOOLBAR_WIDTH_LATE=880` resizes at +5s, after everything has
        // settled — a user's resize, not a launch transient; the +8s capture
        // shows the result.
        if let widthString = ProcessInfo.processInfo.environment["REQRES_TOOLBAR_WIDTH_LATE"],
           let width = Double(widthString) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak window] in
                guard let window else { return }
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
            }
        }
        runSearchProbeIfRequested()
        if ProcessInfo.processInfo.environment["REQRES_TOOLBAR_LOG"] != nil {
            for delay in [2.0, 4.0, 8.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.logGeometry(label: "t+\(delay)s")
                }
            }
        }
        #endif

        NotificationCenter.default.publisher(for: Self.focusSearch)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.searchModel.requestFocus() }
            .store(in: &cancellables)

        // The inspection gauge exists only for the free tier. The item is
        // never conditionally BUILT (the item list is static); it is hidden
        // and shown as the licence state changes.
        LicenseManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires BEFORE the change lands; read after it.
                DispatchQueue.main.async { self?.updateInspectionsVisibility() }
            }
            .store(in: &cancellables)
        updateInspectionsVisibility()

        // The host chip's label budget follows the geometry of its section.
        splitObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHostChipBudget() }
        }
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: window)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateHostChipBudget() }
            .store(in: &cancellables)
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.updateHostChipBudget() }
        }

    }

    /// Reclaims the titlebar's title reserve. Idempotent and re-entrancy
    /// guarded, because it is also called from the KVO that watches for
    /// SwiftUI undoing it.
    private func applyTitlebar(to window: NSWindow) {
        isApplyingTitlebar = true
        defer { isApplyingTitlebar = false }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.title.isEmpty { window.title = "" }
    }

    // MARK: - Host chip budget
    //
    // snipperapp's answer to the same problem: the toolbar does not negotiate
    // a hosted item's width against the tracking separators, so the CONTENT
    // is told how much room its section has and lays out within it. The
    // section runs from the sidebar's trailing edge — or, with the sidebar
    // collapsed, from the toggle that then sits at the leading edge — to the
    // overrides divider.

    /// Everything in the chip that is not the host name: paddings, the icon,
    /// spacings, the chevron and the menu's own inset (measured: a 123pt chip
    /// carried a ~68pt label).
    private static let hostChipChrome: CGFloat = 56
    /// The toolbar's own margin either side of an item.
    private static let itemMargin: CGFloat = 8

    private func updateHostChipBudget() {
        guard isAttached, let splitView, let window else { return }
        let panes = splitView.arrangedSubviews
        guard panes.count >= 3 else { return }

        let sectionStart: CGFloat
        if panes[0].isHidden {
            guard let toggle = toolbar?.items.first(where: { $0.itemIdentifier == .toggleSidebar })?.view,
                  toggle.window === window else { return }
            sectionStart = toggle.convert(toggle.bounds, to: nil).maxX
        } else {
            sectionStart = splitView.convert(NSPoint(x: panes[0].frame.width, y: 0), to: nil).x
        }
        let dividerX = (panes[0].isHidden ? 0 : panes[0].frame.width + splitView.dividerThickness)
            + panes[1].frame.width
        let sectionEnd = splitView.convert(NSPoint(x: dividerX, y: 0), to: nil).x

        let available = sectionEnd - sectionStart - 2 * Self.itemMargin
        let budget = min(ReqResToolbarPlan.hostChipMaxWidth, max(24, available - Self.hostChipChrome))
        if abs(HostChipLayout.shared.labelMaxWidth - budget) >= 1 {
            HostChipLayout.shared.labelMaxWidth = budget
        }
    }

    // MARK: - Free-tier gauge visibility

    /// Shown for the free tier once validation has finished; hidden before
    /// that (no flash) and for licensed users. `NSToolbarItem.isHidden` on
    /// macOS 15+; on 14.6 the item is removed and re-inserted at its plan
    /// position — safe on our own toolbar, where nothing reconciles the list.
    private func updateInspectionsVisibility() {
        #if DEBUG
        Self.trace("updateInspectionsVisibility attached=\(isAttached)")
        #endif
        guard isAttached, let toolbar else { return }
        let manager = LicenseManager.shared
        let visible = manager.hasValidationFinished && !manager.checkLicense()
        let identifier = Self.identifier(.inspections)

        if #available(macOS 15.0, *) {
            guard let item = items[identifier] ?? toolbar.items.first(where: { $0.itemIdentifier == identifier }) else { return }
            if item.isHidden == visible { item.isHidden = !visible }
            return
        }

        let present = toolbar.items.firstIndex { $0.itemIdentifier == identifier }
        if visible, present == nil {
            // Directly before the trailing flexible space that precedes search.
            let searchIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.identifier(.search) } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: identifier, at: max(0, searchIndex - 1))
        } else if !visible, let present {
            toolbar.removeItem(at: present)
        }
    }

    // MARK: - Ejection repair

    /// Re-admits custom items the system clipped while hosted content was
    /// still sizing. This is our own toolbar, so removing and reinserting the
    /// same item at the same index is a safe, targeted re-layout.
    ///
    /// ONE-SHOT per item: a clip at install time is a transient of the async
    /// hosted sizing, but a clip that returns after a repair is the native
    /// overflow doing its job at a genuinely narrow width — re-admitting it
    /// again would just churn items in and out of the chevron.
    private func repairEjectionsIfNeeded() {
        guard isAttached, let toolbar, Date().timeIntervalSince(lastRepair) > 0.8 else { return }
        let visible = Set((toolbar.visibleItems ?? []).map(ObjectIdentifier.init))
        for (index, item) in toolbar.items.enumerated() {
            guard item.view != nil,
                  items[item.itemIdentifier] != nil,
                  !repairedItems.contains(item.itemIdentifier),
                  !visible.contains(ObjectIdentifier(item)) else { continue }
            lastRepair = Date()
            repairedItems.insert(item.itemIdentifier)
            toolbar.removeItem(at: index)
            toolbar.insertItem(withItemIdentifier: item.itemIdentifier, at: index)
            return // one per pass; the next pass handles the rest
        }
    }

    // MARK: - Diagnostics

    #if DEBUG
    /// `REQRES_TOOLBAR_LOG=1` dumps every item's slot geometry once the
    /// toolbar has settled — a self-verification harness, which needs
    /// no screen-recording permission. It answers the two questions a
    /// screenshot is usually taken for: is search actually against the right
    /// edge, and did anything silently fall into the overflow chevron.
    private func logGeometry(label: String) {
        guard isAttached, let toolbar, let window else { return }
        let visible = Set((toolbar.visibleItems ?? []).map(ObjectIdentifier.init))
        let panes = (splitView?.arrangedSubviews ?? []).map {
            $0.isHidden ? "hidden(\(Int($0.frame.width)))" : "\(Int($0.frame.width))"
        }
        var lines = ["[toolbar \(label)] windowWidth=\(Int(window.frame.width))"
                     + " split=\(Int(splitView?.frame.width ?? 0)) panes=\(panes)"]
        for item in toolbar.items {
            let id = item.itemIdentifier.rawValue.replacingOccurrences(
                of: "com.oloapps.ReqRes.toolbar.", with: "")
            // Overflow is only meaningful for items we built: AppKit
            // substitutes its own instance for the system ones, so an identity
            // check against `toolbar.items` reports a false overflow there.
            let overflow = (items[item.itemIdentifier] != nil
                            && !visible.contains(ObjectIdentifier(item))) ? " OVERFLOW" : ""
            let glyph = item.image == nil ? "" : " image=yes"
            // WINDOW coordinates: a slot's own frame is relative to its
            // parent, so raw minX/maxX say nothing about where the item sits
            // in the titlebar.
            if let view = item.view ?? (item as? NSSearchToolbarItem)?.searchField,
               view.window != nil {
                let frame = view.convert(view.bounds, to: nil)
                lines.append("  \(id) x=\(Int(frame.minX))..\(Int(frame.maxX)) w=\(Int(frame.width))\(glyph)\(overflow)")
            } else {
                lines.append("  [\(id)]\(glyph)\(overflow)")
            }
        }
        // Tracking separators have no `view` of their own; find AppKit's
        // separator views in the titlebar and compare them with the split
        // dividers. Any drift here is the failure the architecture exists to
        // prevent (a native window title caused 79pt of it, sidebar collapsed).
        if let split = splitView, let root = window.contentView?.superview {
            var separators: [CGFloat] = []
            func walk(_ view: NSView) {
                if String(describing: type(of: view)).contains("SeparatorToolbarItemView") {
                    separators.append(view.convert(view.bounds, to: nil).minX)
                }
                view.subviews.forEach(walk)
            }
            walk(root)
            let panes = split.arrangedSubviews
            var dividers: [CGFloat] = []
            var x: CGFloat = 0
            for (i, pane) in panes.enumerated() where i < panes.count - 1 {
                x += pane.isHidden ? 0 : pane.frame.width
                dividers.append(split.convert(NSPoint(x: x, y: 0), to: nil).x)
                x += split.dividerThickness
            }
            // Each separator against its NEAREST divider: AppKit's sidebar
            // separator is a different view class and may not be found, so a
            // positional zip would pair the list separator with divider 0.
            let drift = separators.sorted().map { sep -> Int in
                Int(dividers.map { sep - $0 }.min { abs($0) < abs($1) } ?? 0)
            }
            lines.append("  separators x=\(separators.sorted().map { Int($0) }) dividers x=\(dividers.map { Int($0) }) drift-to-nearest=\(drift)")
        }
        FileHandle.standardOutput.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        captureWindow(label: label)
    }

    // Note on the capture's limits: SwiftUI content that has re-rendered since
    // the first paint (macOS 14+ draws it through RenderBox display lists) is
    // NOT reliably rasterised by `cacheDisplay`, and `ImageRenderer` cannot
    // render a ScrollView's content at all. The traffic pane came out blank
    // in every capture where it was ≤621pt wide while its AppKit view tree —
    // frames included — was identical to the ≥643pt captures that showed the
    // table. Trust the view dump for layout; trust the pixels only for AppKit.

    /// `REQRES_SEARCH_PROBE=1`: drives the search field headlessly — focus,
    /// type `host:ex`, commit the first suggestion with Return, type free
    /// text — printing the filter after each step plus the suggestions panel
    /// and the toolbar strip as PNGs. Seeds the suggestion source so it works
    /// on a machine with no captured traffic. Exits when done.
    private func runSearchProbeIfRequested() {
        guard ProcessInfo.processInfo.environment["REQRES_SEARCH_PROBE"] != nil else { return }
        TrafficSearchState.shared.suggestionSource = { ["api.example.com", "cdn.example.com", "example.org"] }
        TrafficSearchState.shared.appSuggestionSource = { ["Brave Browser", "claude", "curl", TrafficSearchAppMatch.unknown] }
        // Destinations as `SessionState.countrySuggestions()` would hand them
        // over (destination-map UX spec §5.3's probe seeds), busiest first,
        // Unknown last. English titles on purpose: the checks below type
        // English names, so they assume an English-locale Mac either way.
        TrafficSearchState.shared.countrySuggestionSource = {
            [
                (token: "US", title: "United States", requests: 1204),
                (token: "DE", title: "Germany", requests: 88),
                (token: "mac", title: "This Mac", requests: 412),
                (token: "unknown", title: "Unknown", requests: 12),
            ]
        }
        let model = searchModel
        // Attribution as the index would hold it (UX spec §4.2's probe): two
        // claude processes, so its row carries "2 processes" and `pid:` lists
        // both; real paths, so the icons come through `ProcessIconCache`.
        model.debugSeedAttribution(
            apps: [
                (name: "Brave Browser", path: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper", processes: 1),
                (name: "claude", path: "/usr/local/bin/claude", processes: 2),
                (name: "curl", path: "/usr/bin/curl", processes: 1),
            ],
            pids: [(pid: 9437, app: "claude"), (pid: 40213, app: "Brave Browser"), (pid: 9767, app: "claude"), (pid: 5120, app: "curl")]
        )
        let out = FileHandle.standardOutput
        func log(_ text: String) { out.write(("[search] " + text + "\n").data(using: .utf8)!) }
        func check(_ label: String, _ condition: Bool) { log("\(label): \(condition ? "PASS" : "FAIL")") }
        func png(_ label: String) {
            guard let data = model.debugPanelPNG() else { return }
            out.write("<<<PNG \(label)\n".data(using: .utf8)!)
            out.write(data.base64EncodedString().data(using: .utf8)!)
            out.write("\nPNG>>>\n".data(using: .utf8)!)
        }
        func type(_ text: String) {
            model.field.stringValue = text
            model.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: model.field))
        }
        func key(_ selector: Selector) -> Bool {
            guard let editor = model.field.currentEditor() as? NSTextView else { return false }
            return model.control(model.field, textView: editor, doCommandBy: selector)
        }
        func after(_ delay: Double, _ block: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        }
        after(2.0) { [weak self] in
            model.requestFocus()
            after(0.5) {
                log("focused=\(model.isFieldFocused) fieldFrame=\(model.field.window.map { _ in model.field.convert(model.field.bounds, to: nil) } ?? .zero)")
                // An empty focused field: Hosts (4) + Apps (3) + the syntax hint.
                log("empty field panel=\(model.debugPanelIsVisible) groups=\(model.debugGroups)")
                check("empty field offers hosts, apps and the hint", model.debugGroups.hasPrefix("Hosts[") && model.debugGroups.contains(" Apps[") && model.debugGroups.hasSuffix("·[{\(TrafficSearchFieldModel.syntaxHintText)}]"))
                check("the hint names country: between pid: and method:", TrafficSearchFieldModel.syntaxHintText.contains("pid: · country: · method:"))
                png("suggestions-empty")
                type("host:ex")
                after(0.5) {
                    log("panel=\(model.debugPanelIsVisible) rows=\(model.debugSuggestions)")
                    if let png = model.debugPanelPNG() {
                        out.write("<<<PNG suggestions\n".data(using: .utf8)!)
                        out.write(png.base64EncodedString().data(using: .utf8)!)
                        out.write("\nPNG>>>\n".data(using: .utf8)!)
                    }
                    let handled = key(#selector(NSResponder.insertNewline(_:)))
                    log("return handled=\(handled) filter=\(TrafficSearchState.shared.filter) panel=\(model.debugPanelIsVisible)")
                    after(0.5) {
                        type("users")
                        after(0.6) {
                            log("after debounce filter=\(TrafficSearchState.shared.filter) focused=\(model.isFieldFocused)")
                            let escaped = key(#selector(NSResponder.cancelOperation(_:)))
                            log("escape handled=\(escaped) filter=\(TrafficSearchState.shared.filter) text='\(model.field.stringValue)'")
                            type("host:")
                            after(0.3) {
                                log("bare prefix panel=\(model.debugPanelIsVisible) rows=\(model.debugSuggestions)")
                                _ = key(#selector(NSResponder.moveDown(_:)))
                                _ = key(#selector(NSResponder.insertNewline(_:)))
                                type("GET")
                                after(0.6) {
                                    log("free text filter=\(TrafficSearchState.shared.filter)")
                                    // The other token kinds: a class match, an
                                    // exact method, and a status query that
                                    // cannot parse, which must fall back to
                                    // free text rather than becoming a token
                                    // that silently matches nothing.
                                    _ = key(#selector(NSResponder.cancelOperation(_:)))
                                    type("status:5")
                                    after(0.3) {
                                        log("status prefix panel=\(model.debugPanelIsVisible) rows=\(model.debugSuggestions)")
                                        _ = key(#selector(NSResponder.moveDown(_:)))
                                        _ = key(#selector(NSResponder.insertNewline(_:)))
                                        log("status committed filter=\(TrafficSearchState.shared.filter)")
                                        type("method:post")
                                        _ = key(#selector(NSResponder.insertNewline(_:)))
                                        log("method committed filter=\(TrafficSearchState.shared.filter)")
                                        type("status:banana")
                                        _ = key(#selector(NSResponder.insertNewline(_:)))
                                        after(0.4) {
                                            log("unparseable status filter=\(TrafficSearchState.shared.filter)")
                                            // The attribution tokens (UX spec §4.2). One Escape: the panel is
                                            // down, so it clears the chips and the text.
                                            let cleared = key(#selector(NSResponder.cancelOperation(_:)))
                                            log("cleared handled=\(cleared) filter=\(TrafficSearchState.shared.filter)")
                                            // No app chip yet: every seeded pid, busiest first, naming its app.
                                            type("pid:")
                                            after(0.3) {
                                                log("pid prefix, unrestricted groups=\(model.debugGroups)")
                                                check("pid: lists every seeded pid", model.debugSuggestions == ["9437", "40213", "9767", "5120"])
                                                type("app:cl")
                                                after(0.3) {
                                                    log("app prefix panel=\(model.debugPanelIsVisible) groups=\(model.debugGroups)")
                                                    png("suggestions-app")
                                                    _ = key(#selector(NSResponder.insertNewline(_:)))
                                                    log("app committed filter=\(TrafficSearchState.shared.filter)")
                                                    check("app:cl + Return commits apps == [claude]", TrafficSearchState.shared.filter.apps == ["claude"])
                                                    // With an app chip committed, `pid:` offers only that app's processes.
                                                    type("pid:")
                                                    after(0.3) {
                                                        log("pid prefix, restricted groups=\(model.debugGroups)")
                                                        check("pid: lists claude's two seeded pids", model.debugSuggestions == ["9437", "9767"])
                                                        png("suggestions-pid")
                                                        _ = key(#selector(NSResponder.moveDown(_:)))
                                                        _ = key(#selector(NSResponder.insertNewline(_:)))
                                                        log("pid committed filter=\(TrafficSearchState.shared.filter)")
                                                        check("↓ + Return commits the second pid", TrafficSearchState.shared.filter.pids == [9767])
                                                        // Back to an empty field: the flat index walks off the last host onto
                                                        // the first app, and Return commits the row's OWN kind.
                                                        type("")
                                                        after(0.3) {
                                                            log("empty again groups=\(model.debugGroups)")
                                                            for _ in 0..<3 { _ = key(#selector(NSResponder.moveDown(_:))) }
                                                            let lit = model.debugSuggestions.indices.contains(model.debugSelectedIndex) ? model.debugSuggestions[model.debugSelectedIndex] : "-"
                                                            log("after ↓↓↓ selected=\(model.debugSelectedIndex) row=\(lit)")
                                                            check("↓ past the last host lands on the first app", model.debugSelectedIndex == 3 && lit == "Brave Browser")
                                                            _ = key(#selector(NSResponder.insertNewline(_:)))
                                                            log("cross-group return filter=\(TrafficSearchState.shared.filter)")
                                                            check("Return commits it as an app chip", TrafficSearchState.shared.filter.apps == ["claude", "Brave Browser"])
                                                            // Attribution unavailable: one info row, nothing to select.
                                                            model.attributionAvailability = { .unavailable }
                                                            type("app:")
                                                            after(0.3) {
                                                                log("unavailable groups=\(model.debugGroups) selectable=\(model.debugSuggestions)")
                                                                check("unavailable shows the info row and nothing selectable", model.debugPanelIsVisible && model.debugSuggestions.isEmpty && model.debugGroups.contains("Not available on this Mac"))
                                                                png("suggestions-unavailable")
                                                                model.attributionAvailability = { .available }
                                                                // The `country:` token (destination-map UX spec §5.3). The panel
                                                                // is down, so this Escape clears the app and pid chips first.
                                                                _ = key(#selector(NSResponder.cancelOperation(_:)))
                                                                type("country:")
                                                                after(0.3) {
                                                                    log("country prefix groups=\(model.debugGroups)")
                                                                    check("country: lists the seeded destinations by name, Unknown last",
                                                                          model.debugGroups.hasPrefix("Destinations[")
                                                                            && model.debugSuggestions == ["United States", "Germany", "This Mac", "Unknown"]
                                                                            && model.debugGroups.contains("Germany (88 requests)"))
                                                                    png("suggestions-country")
                                                                    type("country:un")
                                                                    after(0.3) {
                                                                        log("country:un rows=\(model.debugSuggestions)")
                                                                        check("country:un matches the name and the token: United States, Unknown", model.debugSuggestions == ["United States", "Unknown"])
                                                                        type("country:ger")
                                                                        after(0.3) {
                                                                            log("country:ger rows=\(model.debugSuggestions)")
                                                                            _ = key(#selector(NSResponder.insertNewline(_:)))
                                                                            log("country:ger committed filter=\(TrafficSearchState.shared.filter)")
                                                                            check("country:ger + Return commits the row's token DE, not the name", TrafficSearchState.shared.filter.countries == ["DE"])
                                                                            type("country:united states")
                                                                            after(0.3) {
                                                                                _ = key(#selector(NSResponder.insertNewline(_:)))
                                                                                check("country:united states + Return commits US", TrafficSearchState.shared.filter.countries == ["DE", "US"])
                                                                                type("country:mac")
                                                                                after(0.3) {
                                                                                    _ = key(#selector(NSResponder.insertNewline(_:)))
                                                                                    let chipTitles = TrafficSearchState.shared.filter.tokens.filter { if case .country = $0 { return true } else { return false } }.map { TrafficSearchDestinationLookup.chipTitle(for: $0) ?? $0.displayName }
                                                                                    log("country chips=\(chipTitles) help=\(TrafficSearchDestinationLookup.chipHelp(for: .country("US")) ?? "-")")
                                                                                    check("country:mac commits mac and its chip reads This Mac",
                                                                                          TrafficSearchState.shared.filter.countries == ["DE", "US", "mac"] && chipTitles.last == "This Mac")
                                                                                    check("a country chip reads as the country's name, not its code",
                                                                                          chipTitles.first != "DE" && chipTitles.first == CountryPresentation.name(for: "DE"))
                                                                                    check("the chip's tooltip spells the token and the name",
                                                                                          TrafficSearchDestinationLookup.chipHelp(for: .country("US")) == "country:US — requests whose server address resolved to \(CountryPresentation.name(for: "US"))")
                                                                                    // No seeded row for Japan: Return resolves the NAME before the
                                                                                    // parser sees it (the field model, never Utils).
                                                                                    type("country:japan")
                                                                                    after(0.3) {
                                                                                        log("country:japan panel=\(model.debugPanelIsVisible) rows=\(model.debugSuggestions)")
                                                                                        _ = key(#selector(NSResponder.insertNewline(_:)))
                                                                                        check("country:japan with no row + Return resolves the name to JP",
                                                                                              !model.debugPanelIsVisible && TrafficSearchState.shared.filter.countries.last == "JP")
                                                                                        // An ambiguous name (North Korea, South Korea) is not a token:
                                                                                        // it stays free text, the `status:banana` contract.
                                                                                        type("country:korea")
                                                                                        after(0.3) {
                                                                                            _ = key(#selector(NSResponder.insertNewline(_:)))
                                                                                            log("country:korea filter=\(TrafficSearchState.shared.filter)")
                                                                                            check("an ambiguous country name stays free text",
                                                                                                  TrafficSearchState.shared.filter.freeText == "country:korea" && TrafficSearchState.shared.filter.countries == ["DE", "US", "mac", "JP"])
                                                                                            type("")
                                                                                            after(0.2) {
                                                                                                _ = key(#selector(NSResponder.cancelOperation(_:)))
                                                                                                log("final filter=\(TrafficSearchState.shared.filter) panel=\(model.debugPanelIsVisible)")
                                                                                                self?.logGeometry(label: "search-probe")
                                                                                                self?.captureWindow(label: "search-probe")
                                                                                                fflush(stdout)
                                                                                                exit(0)
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Renders the titlebar strip (or, with `REQRES_TOOLBAR_SHOT=full`, the
    /// whole window) offscreen and writes it to STDOUT as base64.
    ///
    /// `cacheDisplay` draws through the app's own view tree, so unlike a screen
    /// capture it needs no screen-recording permission and works headlessly.
    /// It goes to stdout rather than a file because the app is sandboxed: /tmp
    /// is denied outright, and the container's own temp directory is not
    /// readable from outside the container.
    private func captureWindow(label: String) {
        guard let frame = window?.contentView?.superview else { return }
        let env = ProcessInfo.processInfo.environment
        let strip = env["REQRES_TOOLBAR_SHOT"] == "full"
            ? frame.bounds
            : NSRect(x: 0, y: frame.bounds.height - 130, width: frame.bounds.width, height: 130)
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: strip) else { return }
        frame.cacheDisplay(in: strip, to: rep)

        // Who paints what: sample the rendered pixels under the toolbar and in
        // each pane, and list the views in the traffic pane that draw a
        // background (`REQRES_TOOLBAR_VIEWS=all` lists every view with its
        // frame). Answers "why is the table a different colour" with numbers.
        if env["REQRES_TOOLBAR_SHOT"] == "full", let split = splitView {
            let scale = CGFloat(rep.pixelsWide) / strip.width
            func sample(_ name: String, _ x: CGFloat, _ yFromTop: CGFloat) {
                guard let c = rep.colorAt(x: Int(x * scale), y: Int(yFromTop * scale))?
                    .usingColorSpace(.sRGB) else { return }
                FileHandle.standardOutput.write(String(format: "  pixel %@ (%.0f,%.0f) = #%02X%02X%02X\n",
                    name, x, yFromTop, Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)).data(using: .utf8)!)
            }
            let panes = split.arrangedSubviews.map { $0.isHidden ? 0 : $0.frame.width }
            let overridesMid = panes[0] + panes[1] / 2
            let trafficX = panes[0] + panes[1] + panes[2] * 0.6
            sample("toolbar", trafficX, 14)
            sample("overrides-pane", overridesMid, strip.height * 0.85)
            sample("traffic-pane-top", trafficX, 70)
            sample("traffic-pane-body", trafficX, strip.height * 0.85)

            var lines: [String] = []
            let everything = env["REQRES_TOOLBAR_VIEWS"] == "all"
            func walk(_ view: NSView, _ depth: Int) {
                guard depth < 16, lines.count < (everything ? 140 : 40) else { return }
                let cls = String(describing: type(of: view))
                var note = ""
                if let v = view as? NSVisualEffectView { note = " material=\(v.material.rawValue) blend=\(v.blendingMode.rawValue)" }
                if let sv = view as? NSScrollView { note = " drawsBackground=\(sv.drawsBackground) doc=\(sv.documentView.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "nil") clip=\(Int(sv.contentView.bounds.width))×\(Int(sv.contentView.bounds.height))" }
                if let tv = view as? NSTableView { note = " bg=\(tv.backgroundColor)" }
                if let layer = view.layer, let bg = layer.backgroundColor, bg.alpha > 0 {
                    let c = NSColor(cgColor: bg)?.usingColorSpace(.sRGB)
                    note += String(format: " layerBG=#%02X%02X%02X a=%.2f", Int((c?.redComponent ?? 0)*255), Int((c?.greenComponent ?? 0)*255), Int((c?.blueComponent ?? 0)*255), bg.alpha)
                }
                if !note.isEmpty || depth < 3 || everything {
                    lines.append("  " + String(repeating: "  ", count: depth) + cls + note
                                 + String(format: " [%.0f,%.0f %.0f×%.0f]%@", view.frame.minX, view.frame.minY, view.frame.width, view.frame.height, view.isHidden ? " HIDDEN" : ""))
                }
                view.subviews.forEach { walk($0, depth + 1) }
            }
            walk(split.arrangedSubviews[2], 0)
            // The overrides pane's OWN wrapper (AppKit's, for a content-list
            // item), to compare materials with the traffic pane's.
            func materials(_ view: NSView, _ depth: Int) {
                guard depth < 4 else { return }
                if let v = view as? NSVisualEffectView {
                    lines.append("  overrides-pane effect: material=\(v.material.rawValue) blend=\(v.blendingMode.rawValue) state=\(v.state.rawValue) [\(Int(view.frame.width))×\(Int(view.frame.height))]")
                }
                view.subviews.forEach { materials($0, depth + 1) }
            }
            materials(split.arrangedSubviews[1], 0)
            // What paints the overrides pane: its top levels, with any drawn
            // background, plus the split view's own background properties.
            lines.append("  split view: drawsBackground?=\(split.wantsLayer) layerBG=\(split.layer?.backgroundColor.map { String(describing: $0) } ?? "nil")")
            lines.append("  overrides pane views:")
            let saved = lines.count
            func walkPane(_ view: NSView, _ depth: Int) {
                guard depth < 6, lines.count - saved < 30 else { return }
                let cls = String(describing: type(of: view))
                var note = ""
                if let layer = view.layer, let bg = layer.backgroundColor, bg.alpha > 0 {
                    let c = NSColor(cgColor: bg)?.usingColorSpace(.sRGB)
                    note += String(format: " layerBG=#%02X%02X%02X a=%.2f", Int((c?.redComponent ?? 0)*255), Int((c?.greenComponent ?? 0)*255), Int((c?.blueComponent ?? 0)*255), bg.alpha)
                }
                if let box = view as? NSBox { note += " box fill=\(box.fillColor)" }
                if view.isOpaque { note += " opaque" }
                lines.append("  " + String(repeating: "  ", count: depth + 1) + cls + note + String(format: " [%.0f×%.0f]", view.frame.width, view.frame.height))
                view.subviews.forEach { walkPane($0, depth + 1) }
            }
            walkPane(split.arrangedSubviews[1], 0)
            FileHandle.standardOutput.write(("  traffic pane views:\n" + lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        }

        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let out = FileHandle.standardOutput
        out.write("<<<PNG \(label)\n".data(using: .utf8)!)
        out.write(png.base64EncodedString().data(using: .utf8)!)
        out.write("\nPNG>>>\n".data(using: .utf8)!)
    }
    #endif

    // MARK: - NSToolbarDelegate

    private var defaultOrder: [NSToolbarItem.Identifier] {
        ReqResToolbarPlan.order.map(Self.toolbarIdentifier(for:))
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        #if DEBUG
        Self.trace("defaultItemIdentifiers (\(defaultOrder.count))")
        #endif
        return defaultOrder
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultOrder
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        #if DEBUG
        Self.trace("itemFor \(itemIdentifier.rawValue.replacingOccurrences(of: "com.oloapps.ReqRes.toolbar.", with: "")) cached=\(items[itemIdentifier] != nil)")
        #endif
        if let existing = items[itemIdentifier] { return existing }
        // Everything ours is pre-built in `install`; this is only a fallback.
        guard let slot = Self.slot(for: itemIdentifier), !slot.isSystemProvided else {
            return nil // spaces and the sidebar toggle are the system's
        }
        let item = makeItem(slot: slot, identifier: itemIdentifier)
        items[itemIdentifier] = item
        return item
    }

    private func makeItem(slot: ReqResToolbarSlot, identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch slot {
        case .sidebarSeparator, .listSeparator:
            // Both separators are built here, the sidebar one under AppKit's
            // own identifier so the system toggle keeps its behaviour. Left
            // to AppKit, the sidebar separator was a launch race — see the
            // plan.
            guard let splitView, let divider = slot.trackedDividerIndex else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: identifier, splitView: splitView, dividerIndex: divider)
        case .add:
            return makeAddItem(identifier: identifier, slot: slot)
        case .search:
            return makeSearchItem(identifier: identifier, slot: slot)
        case .hostSwitcher, .capture, .tools, .inspections:
            guard let slotViews else { return nil }
            let content: AnyView
            switch slot {
            case .hostSwitcher: content = slotViews.host
            case .capture: content = slotViews.capture
            case .inspections: content = slotViews.inspections
            default: content = slotViews.tools
            }
            return makeHostedItem(identifier: identifier, slot: slot, content: content)
        default:
            return nil
        }
    }

    // MARK: - Item construction

    /// The ＋ menu. A NATIVE bordered menu item — see the header for why this
    /// is not a hosted SwiftUI `Menu`.
    private func makeAddItem(identifier: NSToolbarItem.Identifier, slot: ReqResToolbarSlot) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        item.label = slot.label
        item.toolTip = "Add a host filter or create an override"
        item.isBordered = true
        item.showsIndicator = false
        item.menu = addMenu()
        // The MENU is the action, so there is no target/action on the item
        // itself — autovalidation would walk the responder chain, find
        // nothing, and render the item permanently dimmed.
        item.autovalidates = false
        item.isEnabled = true
        item.menuFormRepresentation = menuForm(for: slot)
        return item
    }

    /// The tokenized search field (snipperapp 3's), hosted at the plan's
    /// REQUIRED constant width. Behind `.flexibleSpace` this is what holds
    /// the field against the window's right edge; narrow widths are the
    /// overflow chevron's job, and `visibilityPriority` makes search the last
    /// thing taken. The field never sizes itself, so the item never
    /// re-measures while the user types.
    private func makeSearchItem(identifier: NSToolbarItem.Identifier, slot: ReqResToolbarSlot) -> NSToolbarItem {
        let width = ReqResToolbarPlan.searchWidth
        let content = AnyView(
            TrafficSearchField(model: searchModel, search: TrafficSearchState.shared, availableWidth: width)
                .frame(width: width)
        )
        let item = makeHostedItem(identifier: identifier, slot: slot, content: content)
        item.toolTip = "Search captured traffic — type host: to filter by host"
        item.visibilityPriority = .high
        return item
    }

    /// A SwiftUI cluster on one system platter.
    private func makeHostedItem(
        identifier: NSToolbarItem.Identifier,
        slot: ReqResToolbarSlot,
        content: AnyView
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let hosting = NSHostingView(rootView: content)
        // `.minSize` as well as intrinsic: a slot whose root is a conditional
        // reports no intrinsic metric, and with intrinsic sizing alone the
        // toolbar lays the cluster out at 0×0 while its fitting size is
        // healthy.
        // `.minSize` as well as intrinsic: a slot whose root is a conditional
        // reports no intrinsic metric, and with intrinsic sizing alone the
        // toolbar lays the cluster out at 0×0 while its fitting size is
        // healthy.
        hosting.sizingOptions = [.minSize, .intrinsicContentSize]
        // NSToolbar SQUEEZES view items when content overflows instead of
        // clipping them; items must never silently shrink — narrow widths are
        // the overflow chevron's job. (The host chip is sized to its section
        // by `updateHostChipBudget` instead: two attempts to let the toolbar
        // negotiate its width failed — `.defaultLow` compression resistance
        // was ignored and the separator moved 66pt; constraints without an
        // intrinsic size were laid out at the FLOOR in every state.)
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        item.view = hosting
        item.label = slot.label
        item.menuFormRepresentation = menuForm(for: slot)
        item.visibilityPriority = .standard
        return item
    }

    // MARK: - Menus

    private func addMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(notificationRow("Add a Host Filter", Self.addHostFilter))
        menu.addItem(notificationRow("Create an Override", Self.createOverride))
        return menu
    }

    private func notificationRow(_ title: String, _ name: Notification.Name) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: #selector(postNotificationAction(_:)), keyEquivalent: "")
        row.target = self
        row.representedObject = name
        return row
    }

    /// What the native overflow chevron shows for a folded item. Rows post the
    /// same notifications the real controls use, so the menu path stays live.
    private func menuForm(for slot: ReqResToolbarSlot) -> NSMenuItem? {
        guard let title = slot.overflowMenuTitle else { return nil }
        let form = NSMenuItem()
        form.title = title

        switch slot {
        case .hostSwitcher:
            // Hosts change at runtime; the submenu rebuilds itself on open.
            let sub = NSMenu(title: title)
            sub.delegate = self
            form.submenu = sub
        case .add:
            form.submenu = addMenu()
        case .capture:
            let sub = NSMenu()
            sub.addItem(commandRow("Start or Pause Capture", #selector(menuToggleCapture)))
            form.submenu = sub
        case .tools:
            let sub = NSMenu()
            sub.addItem(commandRow("Show Destinations", #selector(menuShowDestinations)))
            sub.addItem(commandRow("Clear Captured Traffic", #selector(menuClearTraffic)))
            sub.addItem(commandRow("Send Feedback", #selector(menuSendFeedback)))
            form.submenu = sub
        default:
            break // search: a plain labelled row (the field is one widen — or ⌘F — away)
        }
        return form
    }

    @objc private func postNotificationAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? Notification.Name else { return }
        NotificationCenter.default.post(name: name, object: nil)
    }

    /// Overflow rows for the traffic controls call `TrafficCommands` DIRECTLY
    /// rather than posting a notification: a folded toolbar item does not
    /// mount its hosted view, so a listener living inside the cluster would be
    /// gone at exactly the width where the overflow menu is the only way in.
    /// The controller is always alive.
    private func commandRow(_ title: String, _ selector: Selector) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        row.target = self
        return row
    }

    @objc private func menuToggleCapture() { TrafficCommands.toggleCapture() }
    @objc private func menuShowDestinations() { TrafficCommands.showDestinations() }
    @objc private func menuClearTraffic() { TrafficCommands.clearTraffic() }
    @objc private func menuSendFeedback() { TrafficCommands.sendFeedback() }

    @objc private func menuSelectHost(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? HostCodable else { return }
        AppState.shared.selectedHost = host
    }

    // MARK: - NSMenuItemValidation (the overflow rows)

    /// Clear Captured Traffic is enabled only when there is traffic to clear,
    /// like the toolbar's trash it stands in for (`TrafficToolsSlot`). Enabled
    /// with nothing captured, it asked to discard "0 captured requests" — and
    /// offered “Don’t ask again” on a clear that discards nothing. Every other
    /// row this controller targets stays enabled, as before; the menus
    /// autoenable, so this is what decides.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(menuClearTraffic) {
            return !SessionState.shared.sessions.isEmpty
        }
        return true
    }

    // MARK: - NSMenuDelegate (the host chip's overflow submenu)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let selected = AppState.shared.selectedHost
        for host in AppState.shared.hosts {
            let row = NSMenuItem(title: host.host, action: #selector(menuSelectHost(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = host
            row.state = host == selected ? .on : .off
            menu.addItem(row)
        }
    }
}
