//
//  ReqResSplitHost.swift
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
//  The app's three panes on a REAL `NSSplitViewController` — hosts | overrides
//  | traffic — hosted inside the existing SwiftUI window, replacing
//  `NavigationSplitView`.
//
//  Why: `NavigationSplitView` is not NSSplitView-backed on macOS 26, so the
//  toolbar can never get the `NSTrackingSeparatorToolbarItem`s that anchor its
//  sections to the panes. Without them the toolbar's items float wherever the
//  layout leaves them — which is why 1.0.4's search box sits mid-toolbar and
//  the sidebar toggle drifts away from the sidebar edge. A real NSSplitView
//  gives the separators something to track, and gives the sidebar the system's
//  own material, collapse behaviour and full-height treatment under the
//  titlebar.
//
//  The measured rules in the comments below were verified here.
//

import AppKit
import SwiftUI

struct ReqResSplitHost: NSViewControllerRepresentable {
    let toolbar: ReqResToolbarController
    /// Built lazily at toolbar-install time so the slot views capture the
    /// observable objects and bindings that AppView owns.
    let toolbarSlots: () -> ReqResToolbarController.SlotViews
    let sidebar: AnyView
    let overrides: AnyView
    let traffic: AnyView

    func makeNSViewController(context: Context) -> ReqResSplitHostController {
        let controller = ReqResSplitHostController()
        toolbar.slots = toolbarSlots
        controller.configure(sidebar: sidebar, overrides: overrides, traffic: traffic, toolbar: toolbar)
        return controller
    }

    func updateNSViewController(_ controller: ReqResSplitHostController, context: Context) {
        controller.update(sidebar: sidebar, overrides: overrides, traffic: traffic)
    }

    /// Never report an ideal size of our own. SwiftUI sizes a NEW window to
    /// its root view's ideal size, and a representable's default ideal is its
    /// AppKit fitting size — which silently overrode `.defaultSize`: the window
    /// opened at 1016×600 (the seeded pane frames) with restoration bypassed.
    /// Take whatever is proposed; the panes' own minimums still bind the
    /// window through `contentMinSize`.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: ReqResSplitHostController,
                      context: Context) -> CGSize? {
        let size = CGSize(width: proposal.width ?? ReqResMainWindow.defaultSize.width,
                          height: proposal.height ?? ReqResMainWindow.defaultSize.height)
        #if DEBUG
        if ProcessInfo.processInfo.environment["REQRES_TOOLBAR_LOG"] != nil {
            FileHandle.standardOutput.write("[sizeThatFits] proposal=\(proposal.width.map { Int($0) } ?? -1)×\(proposal.height.map { Int($0) } ?? -1) -> \(Int(size.width))×\(Int(size.height))\n".data(using: .utf8)!)
        }
        #endif
        return size
    }
}

@MainActor
final class ReqResSplitHostController: NSViewController {

    // Pane geometry. The detail pane carries the session table, which needs
    // real width before its columns become unreadable.
    private enum Metrics {
        static let sidebarMin: CGFloat = 180
        static let sidebarMax: CGFloat = 300
        static let sidebarDefault: CGFloat = 220

        static let overridesMin: CGFloat = 200
        static let overridesMax: CGFloat = 400
        // 280, snipperapp's list default: with the SIDEBAR COLLAPSED the toggle
        // moves to the leading edge and eats ~136pt of this pane's toolbar
        // section, and 280 still leaves the host chip its full width there
        // (measured: at 260 the list separator was nudged 6pt off its divider).
        static let overridesDefault: CGFloat = 280

        // The pane's CONTENT sets this, measured from a screenshot
        // at a 520pt pane: the session table needs ~540 (its `Code` column
        // was cut), and the request | response tab bars side by side need
        // ~620 (`Request` + five tabs ≈ 325, `Response` + four ≈ 290). Below
        // that SwiftUI centres the overflow and clips both edges.
        static let trafficMin: CGFloat = 660

    }

    private let splitVC = ReqResSplitViewController()
    private var sidebarHost: NSHostingController<AnyView>!
    private var overridesHost: NSHostingController<AnyView>!
    private var trafficHost: NSHostingController<AnyView>!
    private var sidebarItem: NSSplitViewItem!
    private weak var toolbar: ReqResToolbarController?
    private var toolbarInstalled = false
    private var installedAt: Date?
    private var splitResizeObserver: NSObjectProtocol?
    private var windowResizeObserver: NSObjectProtocol?
    /// True only while the sidebar is hidden BY THE AUTO-COLLAPSE — a sidebar
    /// the user closed with the toggle must not spring back on widening.
    ///
    /// PERSISTED, because the split view's own autosave restores a collapsed
    /// sidebar on the next launch: without this the flag started false and a
    /// sidebar we had collapsed looked user-collapsed forever after a relaunch.
    private var sidebarAutoCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoCollapsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoCollapsedKey) }
    }
    private static let autoCollapsedKey = "ReqResSidebarAutoCollapsed"

    deinit {
        for observer in [splitResizeObserver, windowResizeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func configure(sidebar: AnyView, overrides: AnyView, traffic: AnyView, toolbar: ReqResToolbarController) {
        self.toolbar = toolbar
        sidebarHost = NSHostingController(rootView: sidebar)
        overridesHost = NSHostingController(rootView: overrides)
        trafficHost = NSHostingController(rootView: traffic)

        // Panes are sized by the SPLIT VIEW alone. With default sizing options
        // each hosting controller also imposes its SwiftUI content's ideal
        // size as constraints, which re-squeezes a pane back to that ideal
        // after the first layout pass.
        for host in [sidebarHost, overridesHost, trafficHost] {
            host?.sizingOptions = []
        }

        // Seed sane first-layout sizes — the representable's initial pass
        // otherwise lays the panes out below their own minimums.
        sidebarHost.view.setFrameSize(NSSize(width: Metrics.sidebarDefault, height: 600))
        overridesHost.view.setFrameSize(NSSize(width: Metrics.overridesDefault, height: 600))
        trafficHost.view.setFrameSize(NSSize(width: 700, height: 600))

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = Metrics.sidebarMin
        sidebarItem.maximumThickness = Metrics.sidebarMax
        sidebarItem.canCollapse = true

        let overridesItem = NSSplitViewItem(contentListWithViewController: overridesHost)
        overridesItem.minimumThickness = Metrics.overridesMin
        overridesItem.maximumThickness = Metrics.overridesMax
        overridesItem.canCollapse = true

        // A plain item, like the overrides pane: both show the window's own
        // background, so they cannot disagree. (A `.contentBackground` material
        // wrapper was tried for this pane and blended the desktop in — the
        // grey was `SessionListView` painting its own fill.)
        let trafficItem = NSSplitViewItem(viewController: trafficHost)
        trafficItem.minimumThickness = Metrics.trafficMin

        // Window resizes flex the TRAFFIC pane; the two narrow panes hold.
        // Notes and Mail draw a hairline under the toolbar across the content
        // and detail panes. `.automatic` never shows it here — AppKit
        // looks for an NSScrollView at the top of the pane and the SwiftUI
        // table's is not where it looks — so it is forced on. The sidebar
        // keeps the system behaviour: no line over the sidebar material.
        overridesItem.titlebarSeparatorStyle = .line
        trafficItem.titlebarSeparatorStyle = .line

        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        overridesItem.holdingPriority = NSLayoutConstraint.Priority(255)
        trafficItem.holdingPriority = NSLayoutConstraint.Priority(250)

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(overridesItem)
        splitVC.addSplitViewItem(trafficItem)
        splitVC.splitView.autosaveName = "ReqResMainSplit"
    }

    func update(sidebar: AnyView, overrides: AnyView, traffic: AnyView) {
        sidebarHost.rootView = sidebar
        overridesHost.rootView = overrides
        trafficHost.rootView = traffic
    }

    override func loadView() {
        view = NSView()
        addChild(splitVC)
        splitVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitVC.view)
        NSLayoutConstraint.activate([
            splitVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            splitVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !toolbarInstalled, let window = view.window, let toolbar else { return }
        // Tag it, so the menu bar item can find this window rather than
        // guessing at `NSApp.windows.first`.
        window.identifier = ReqResMainWindow.identifier
        toolbarInstalled = true
        installedAt = Date()

        // Apply the default frame ONCE per layout generation. macOS window
        // restoration keeps the previous frame in state the app cannot see or
        // delete, so `.defaultSize` alone never reaches an existing install —
        // nor a developer whose other running build keeps re-saving its own
        // frame. Bump the generation whenever the layout's needs change.
        let generationKey = "ReqResWindowLayoutGeneration"
        if UserDefaults.standard.integer(forKey: generationKey) < Self.layoutGeneration {
            window.setContentSize(ReqResMainWindow.defaultSize)
            window.center()
            UserDefaults.standard.set(Self.layoutGeneration, forKey: generationKey)
        }

        toolbar.install(on: window, splitView: splitVC.splitView)
        splitVC.onSidebarToggled = { [weak self] in self?.sidebarToggledByUser() }

        // Two mechanisms keep the panes fitting the window — see the
        // "Sidebar auto-collapse" section:
        //  * the WINDOW's resize drives the auto-collapse (this view's own
        //    layout stops changing once the hosting view starts clipping);
        //  * the SPLIT VIEW's resize maintains the window minimum.
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoCollapseSidebarIfNeeded() }
        }
        splitResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitVC.splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyWindowMinimumSize() }
        }
        applyWindowMinimumSize()

        // A sidebar the split autosave restored COLLAPSED is treated as ours
        // to reopen, and the width decides: wide enough now → it comes back,
        // still narrow → it stays and returns on widening. The persisted flag
        // only distinguishes a user's toggle from ours WITHIN a session; across
        // a relaunch a stuck-hidden sidebar is far
        // worse than a hand-collapsed one reappearing in a wide window.
        sidebarAutoCollapsed = sidebarItem.isCollapsed
        autoCollapseSidebarIfNeeded()

        #if DEBUG
        // `REQRES_TOOLBAR_COLLAPSE_SIDEBAR=1` collapses the sidebar shortly
        // after launch — the state in which a native window title shoved the
        // list separator 79pt off its divider. The geometry probe must show
        // the toolbar's separators still on the dividers here.
        if ProcessInfo.processInfo.environment["REQRES_TOOLBAR_COLLAPSE_SIDEBAR"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.sidebarItem?.isCollapsed = true
            }
        }
        #endif

        // First-appearance layout can leave dividers outside their items'
        // legal ranges on a fresh autosave — normalize once, after the window
        // frame restoration has settled. A user drag autosaves over this.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.normalizePanes()
        }
    }

    // MARK: - Sidebar auto-collapse + window minimum
    //
    // Apple Mail's behaviour, and snipperapp's: narrow the window past what
    // the three panes need and the sidebar gets out of the way; widen it again
    // and the sidebar comes back — unless the user closed it themselves.
    //
    // A window whose contentViewController IS the NSSplitViewController gets
    // the minimum-size half of this free. Nested inside a SwiftUI hosting view
    // it does not: the window could be dragged narrower than the panes could
    // lay out in and the traffic pane was clipped off the right edge
    // (measured: 180+239+520 of panes inside a 760pt window).
    //
    // Two rules, and the order matters:
    //  * The window MINIMUM is the collapsed-sidebar minimum, always. If it
    //    were the expanded minimum the window could never be dragged into the
    //    range where the auto-collapse is supposed to fire.
    //  * Below the expanded minimum the sidebar auto-collapses; above it plus
    //    a hysteresis it auto-expands, but only if the auto-collapse is what
    //    hid it. A sidebar the user opens by hand at a width that cannot hold
    //    it widens the window instead.
    //
    // State is read from `NSSplitViewItem.isCollapsed` (the INTENT — it flips
    // the moment a collapse is requested, before the animation lands), while
    // pane widths come from the views. `isHidden` is the truth for "taking up
    // space": AppKit keeps a collapsed pane's last width in its frame.

    /// The collapse fires this much BEFORE the window reaches the expanded
    /// minimum. Measured: the panes' own minimum-thickness constraints DO
    /// bind the window (a `setFrame` to 880 landed at 902), so a threshold at
    /// exactly the expanded minimum can never be crossed — the window is
    /// clamped there first and the sidebar never gets out of the way.
    private static let collapseMargin: CGFloat = 40
    private static let expandHysteresis: CGFloat = 40

    /// 1 = the NavigationSplitView era (never recorded); 2 = the AppKit split
    /// with the 660pt traffic minimum and the 1250×630 default (2026-09-17).
    private static let layoutGeneration = 2

    /// What the panes need with the sidebar hidden (the overrides pane may be
    /// collapsed too).
    private var collapsedMinimumWidth: CGFloat {
        let split = splitVC.splitView
        var width = Metrics.trafficMin
        if split.arrangedSubviews.count > 1, !split.arrangedSubviews[1].isHidden {
            width += Metrics.overridesMin + split.dividerThickness
        }
        return width
    }

    /// What the panes need with the sidebar showing.
    private var expandedMinimumWidth: CGFloat {
        collapsedMinimumWidth + Metrics.sidebarMin + splitVC.splitView.dividerThickness
    }

    private var isLaunching: Bool {
        installedAt.map { Date().timeIntervalSince($0) < 1.5 } ?? true
    }

    private func autoCollapseSidebarIfNeeded() {
        guard toolbarInstalled, let window = view.window, let sidebarItem else { return }
        // The WINDOW's width: the view animates through intermediate widths
        // while a collapse relayout is in flight, and measuring those flaps
        // the state. The window width jumps atomically to its target.
        let width = window.frame.width
        // Instant during a live-resize drag (an animation would lag the window
        // edge) and during launch; animated for everything else.
        let animate = !window.inLiveResize && !isLaunching

        if !sidebarItem.isCollapsed, width < expandedMinimumWidth + Self.collapseMargin {
            sidebarAutoCollapsed = true
            if animate {
                NSAnimationContext.runAnimationGroup({ _ in
                    sidebarItem.animator().isCollapsed = true
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated { self?.restoreOverridesWidthAfterCollapse() }
                })
            } else {
                sidebarItem.isCollapsed = true
                restoreOverridesWidthAfterCollapse()
            }
        } else if sidebarItem.isCollapsed, sidebarAutoCollapsed,
                  width >= expandedMinimumWidth + Self.collapseMargin + Self.expandHysteresis {
            sidebarAutoCollapsed = false
            if animate {
                NSAnimationContext.runAnimationGroup({ _ in
                    sidebarItem.animator().isCollapsed = false
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated { self?.restorePaneDefaultsAfterExpand() }
                })
            } else {
                sidebarItem.isCollapsed = false
                restorePaneDefaultsAfterExpand()
            }
        }
    }

    /// The panes were squeezed to their minimums on the way DOWN (the window
    /// shrank before the sidebar hid) and the autosave keeps those widths, so
    /// a sidebar reopening into a wide window came back at 181/200. Hand both
    /// their defaults back when there is room; a user's later drag autosaves
    /// over it.
    private func restorePaneDefaultsAfterExpand() {
        let split = splitVC.splitView
        guard split.arrangedSubviews.count >= 3, !split.arrangedSubviews[0].isHidden,
              !split.arrangedSubviews[1].isHidden else { return }
        let needed = Metrics.sidebarDefault + Metrics.overridesDefault + Metrics.trafficMin + 2 * split.dividerThickness
        guard split.frame.width >= needed else { return }
        if split.arrangedSubviews[0].frame.width < Metrics.sidebarDefault {
            split.setPosition(Metrics.sidebarDefault, ofDividerAt: 0)
        }
        if split.arrangedSubviews[1].frame.width < Metrics.overridesDefault {
            split.setPosition(Metrics.sidebarDefault + split.dividerThickness + Metrics.overridesDefault, ofDividerAt: 1)
        }
    }

    /// The window shrinks BEFORE the sidebar hides, so by the time it does the
    /// overrides pane has already been squeezed to its minimum — and the space
    /// the sidebar frees all goes to the traffic pane (the lowest holding
    /// priority). Hand the overrides pane its default back when there is room:
    /// at its 200pt minimum the toolbar section over it cannot hold the host
    /// chip and the list separator drifts (measured: 66pt).
    private func restoreOverridesWidthAfterCollapse() {
        let split = splitVC.splitView
        guard split.arrangedSubviews.count >= 3,
              split.arrangedSubviews[0].isHidden,
              !split.arrangedSubviews[1].isHidden else { return }
        let current = split.arrangedSubviews[1].frame.width
        guard current < Metrics.overridesDefault,
              split.frame.width - Metrics.overridesDefault - split.dividerThickness >= Metrics.trafficMin
        else { return }
        split.setPosition(Metrics.overridesDefault, ofDividerAt: 1)
    }

    private func applyWindowMinimumSize() {
        guard let window = view.window else { return }
        let size = NSSize(width: ceil(collapsedMinimumWidth), height: 400)
        if window.contentMinSize != size { window.contentMinSize = size }
    }

    /// The user toggled the sidebar (toolbar button or ⌃⌘S). Either way it is
    /// now THEIR state, so the auto-expand must not fight it — and a sidebar
    /// opened at a width that cannot hold it widens the window to fit rather
    /// than letting the panes overflow.
    ///
    /// This lives on the toggle ACTION and nowhere else: a first version ran
    /// it from `didResizeSubviews`, which fires during `setFrame` — BEFORE the
    /// window's resize notification — so it widened the window back before
    /// the auto-collapse could run, and fired on launch transients too
    /// (measured: every window opening at exactly 902pt).
    private func sidebarToggledByUser() {
        guard let window = view.window, let sidebarItem else { return }
        sidebarAutoCollapsed = false
        if !sidebarItem.isCollapsed, window.frame.width < expandedMinimumWidth + Self.collapseMargin {
            var frame = window.frame
            frame.size.width = ceil(expandedMinimumWidth + Self.collapseMargin)
            window.setFrame(frame, display: true, animate: true)
        }
    }

    /// Clamps both dividers into their items' legal ranges, each to its seeded
    /// default when out of range. Positions are only ever written from here,
    /// and never while an animation is in flight — a `setPosition` against a
    /// running animation makes the layout solver move the OTHER divider, and
    /// window state restoration then persists the damage.
    private func normalizePanes() {
        let split = splitVC.splitView
        let panes = split.arrangedSubviews
        guard panes.count >= 3 else { return }
        let widths = panes.map(\.frame.width)

        // A hidden pane is collapsed, which is legitimate (the user's toggle) —
        // never force one open, and never move a divider it does not own.
        var sidebarWidth = panes[0].isHidden ? 0 : widths[0]
        if !panes[0].isHidden, !(Metrics.sidebarMin...Metrics.sidebarMax).contains(widths[0]) {
            sidebarWidth = Metrics.sidebarDefault
            split.setPosition(Metrics.sidebarDefault, ofDividerAt: 0)
        }
        if !panes[1].isHidden,
           !(Metrics.overridesMin...Metrics.overridesMax).contains(widths[1]) {
            split.setPosition(sidebarWidth + split.dividerThickness + Metrics.overridesDefault, ofDividerAt: 1)
        }
    }
}

/// The split controller, so the user's sidebar toggle — the toolbar's system
/// item and ⌃⌘S both arrive here through the responder chain — can be told
/// apart from the host's own auto-collapse, which sets `isCollapsed` directly.
@MainActor
final class ReqResSplitViewController: NSSplitViewController {
    var onSidebarToggled: (() -> Void)?

    override func toggleSidebar(_ sender: Any?) {
        super.toggleSidebar(sender)
        onSidebarToggled?()
    }
}
