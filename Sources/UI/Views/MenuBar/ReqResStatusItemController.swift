//
//  ReqResStatusItemController.swift
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
//  The menu bar item.
//
//  Its job is disclosure, not convenience. While capture runs, HTTPS
//  connections on this Mac are decrypted and re-signed with this Mac's own
//  ReqRes CA — and before this existed, pressing ⌘W left nothing anywhere on
//  the machine saying so. That is the whole argument for taking a permanent
//  slot in the strip users are most protective of; the two clicks it saves are
//  a bonus.
//
//  Four rules it is built to, each from something measured:
//
//   1. **The arrangement is DATA.** `ReqResStatusMenuPlan` lives in `Utils`
//      with 54 tests and no AppKit. This file turns rows into NSMenuItems and
//      nothing else — the same split that lets `ReqResToolbarPlan` be asserted
//      without standing a window up.
//   2. **The glyph is PUSHED, the diagnosis is PULLED.** Everything the icon
//      shows comes from `@Published` state that already exists. The full setup
//      diagnosis reads the keychain, hops through `main.sync` twice and opens
//      a socket — so it runs when the menu opens, never on a timer. No timer
//      exists in this file, and the icon costs nothing while nothing changes.
//   3. **Nothing here duplicates a panel.** There is no MCP-approval row: a
//      pending approval already puts a floating, close-buttonless panel on
//      screen in every app, so a menu row would be a second place to look for
//      something that cannot be missed. Breakpoints DO get a row, because
//      their panel can be closed while the queue survives.
//   4. **No hostnames, no URLs, ever.** The menu bar is the strip most visible
//      during a screen share. Counts and states only.
//

import AppKit
import Combine
import MCPKit
import Utils
import XReqResCore

@MainActor
final class ReqResStatusItemController: NSObject, NSMenuDelegate {
    static let shared = ReqResStatusItemController()

    /// Whether the user wants the item. Default ON: the
    /// feature exists to be seen, and Charles and LuLu both ship theirs on
    /// with an opt-out.
    static let visibilityDefaultsKey = "ShowMenuBarItem"

    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private var visibilityObservation: NSKeyValueObservation?
    /// The last diagnosis, computed off-main when the menu opens. Rendered
    /// from cache so opening the menu never waits on a socket.
    private var cachedVerdict: String?
    private var diagnosisInFlight = false

    private override init() { super.init() }

    // MARK: - Lifecycle

    func applyVisibilityPreference() {
        UserDefaults.standard.bool(forKey: Self.visibilityDefaultsKey) ? install() : remove()
    }

    func install() {
        guard statusItem == nil else { return }
        // A FIXED square, so the item cannot change width and shove every
        // icon to its left. `variableLength` contradicted this file's own
        // stated invariant.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // `.removalAllowed` lets the user ⌘-drag the item out of the menu bar,
        // which is what people expect of anything up there. The KVO below is
        // what keeps the Settings checkbox honest when they do — without it the
        // preference would claim the item is shown while it is gone, and the
        // one thing a missing icon cannot tell you is where to get it back.
        item.behavior = [.removalAllowed]
        item.autosaveName = "ReqResStatusItem"
        // ⚠️ MUST come after `autosaveName` and BEFORE the KVO below.
        //
        // `.removalAllowed` means AppKit sets `visible = NO` when the user
        // ⌘-drags the item out, and `visible` is persisted against the
        // autosave name — so assigning that name synchronously restores the
        // saved NO. Without this line the item could never be brought back:
        // Settings would tick ON, `install()` would build an item AppKit
        // immediately hid, and the pane's own promise ("switch it back on
        // here") was the one path that could not work. Re-showing is
        // documented as the app's job. Measured: the poisoned key is
        // `NSStatusItem VisibleCC ReqResStatusItem`, and a plain
        // `removeStatusItem` does NOT write it — only a user drag-out does.
        item.isVisible = true

        let menu = NSMenu()
        menu.delegate = self
        // The PLAN decides what is enabled, not AppKit. Left at its default,
        // `-[NSMenu update]` re-enables any item whose target responds to the
        // action — which silently discarded the one conditional row we have,
        // making Start/Stop Capturing clickable mid-transition. Clicking it
        // then reaches `stopVPNTunnel()` on a half-built tunnel, which is how
        // the extension gets wedged in `Connecting`.
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard let visible = change.newValue else { return }
            Task { @MainActor in
                UserDefaults.standard.set(visible, forKey: Self.visibilityDefaultsKey)
                if !visible { self?.remove() }
            }
        }

        observeState()
        refreshIcon()
    }

    func remove() {
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        cancellables.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    // MARK: - State

    /// Everything the ICON needs, and nothing that costs work to obtain.
    ///
    /// Deliberately does NOT include the setup diagnosis: it is not published
    /// by anything, so an icon derived from it could only be kept current by
    /// polling. `setupBlocked` therefore means what the toolbar's warning
    /// triangle has always meant — the extension is not ready — and the
    /// diagnosis that can also catch a dead proxy port is computed when the
    /// menu opens. That limit is stated rather than designed away.
    private func currentState() -> ReqResStatusState {
        let app = AppState.shared
        let pending = BreakpointService.shared.pending
        let fuses = pending.map { BreakpointService.shared.secondsRemaining(for: $0) }
        return ReqResStatusState(
            capturing: app.vpnStatus == .connected,
            setupBlocked: app.extensionStatus != .ready,
            // `.reasserting` is transitional everywhere else in this app
            // (the toolbar's own `isBusy`, the agent write guard, the setup
            // diagnosis). Omitting it here meant the glyph read "not
            // capturing" while the proxy was up and still decrypting — the
            // exact disclosure this item exists for — and the row offered
            // "Start Capturing" for an action that would have stopped it.
            transitional: app.vpnStatus == .connecting
                || app.vpnStatus == .disconnecting
                || app.vpnStatus == .reasserting,
            heldRequestCount: pending.count,
            shortestFuseSeconds: ReqResStatusMenuPlan.shortestFuse(among: fuses),
            activeAgentName: MCPServerService.shared.connectedClients.first?.name,
            capturingSince: app.capturingSince,
            bridgeEnabled: MCPServerService.shared.isEnabled,
            // Published by the delivery monitor, which already looks once a
            // second while capture is on — no timer here (F11).
            delivery: CaptureDeliveryMonitor.shared.delivery,
            holdsBus: AppController.tcpServerBus.isServerListening()
        )
    }

    /// Subscribes to the publishers that already exist. No timer: an icon that
    /// woke the CPU on a schedule to show a state that had not changed would
    /// be the first thing a user turned off.
    private func observeState() {
        let refresh: () -> Void = { [weak self] in
            Task { @MainActor in
                // The cached verdict described the PREVIOUS state; keeping it
                // would leave the tooltip asserting something that has just
                // stopped being true.
                self?.cachedVerdict = nil
                self?.refreshIcon()
            }
        }
        AppState.shared.$vpnStatus.sink { _ in refresh() }.store(in: &cancellables)
        AppState.shared.$extensionStatus.sink { _ in refresh() }.store(in: &cancellables)
        BreakpointService.shared.$pending.sink { _ in refresh() }.store(in: &cancellables)
        CaptureDeliveryMonitor.shared.$delivery.sink { _ in refresh() }.store(in: &cancellables)
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let state = currentState()
        let icon = ReqResStatusMenuPlan.icon(for: state)

        // A FIXED box, always. A status item that changes width shoves every
        // icon to its left — the same rule the toolbar learned, where the cost
        // was only our own neighbours.
        let image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        // Dim, never spin. A spinner re-measures the item and reads as a hang.
        button.appearsDisabled = ReqResStatusMenuPlan.isDimmed(for: state)
        // The glyph is not a signal for a VoiceOver user; the words are.
        button.setAccessibilityLabel(ReqResStatusMenuPlan.accessibilityLabel(for: state))
        button.toolTip = cachedVerdict ?? ReqResStatusMenuPlan.statusTitle(for: state)
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
        // Refresh the diagnosis BEHIND the open menu. It cannot be computed
        // here: `setupFacts()` blocks on `DispatchQueue.main.sync` twice and
        // main is inside menu tracking. The menu shows the cached verdict and
        // the next open shows the new one.
        requestDiagnosis()
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = currentState()
        let sinceText = ReqResStatusMenuPlan.sinceText(
            for: state.capturingSince,
            formatter: ReqResStatusMenuPlan.sinceFormatter()
        )

        for row in ReqResStatusMenuPlan.rows(for: state, capturingSinceText: sinceText) {
            guard !row.isSeparator else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: row.title, action: action(for: row.id), keyEquivalent: keyEquivalent(for: row.id))
            item.keyEquivalentModifierMask = modifiers(for: row.id)
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(row.id.identifier)
            item.isEnabled = row.isEnabled
            menu.addItem(item)
        }
    }

    private func action(for id: ReqResStatusMenuItem) -> Selector? {
        switch id {
        case .toggleCapture: return #selector(toggleCapture)
        case .restartCapture: return #selector(restartCapture)
        case .resumeAll: return #selector(resumeAllHeld)
        case .turnOffBridge: return #selector(turnOffBridge)
        case .openApp: return #selector(openApp)
        case .diagnoseSetup: return #selector(diagnoseSetup)
        case .settings: return #selector(openSettings)
        case .quit: return #selector(quit)
        // Informational rows get no action, which is also what greys them out.
        case .status, .heldRequests, .activeAgent, .sectionSeparator, .appSeparator: return nil
        }
    }

    private func keyEquivalent(for id: ReqResStatusMenuItem) -> String {
        switch id {
        case .toggleCapture: return "c"
        case .quit: return "q"
        default: return ""
        }
    }

    private func modifiers(for id: ReqResStatusMenuItem) -> NSEvent.ModifierFlags {
        switch id {
        case .toggleCapture: return [.command, .shift]
        case .quit: return [.command]
        default: return []
        }
    }

    // MARK: - Diagnosis, off main and cached

    private func requestDiagnosis() {
        guard !diagnosisInFlight else { return }
        diagnosisInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let report = MCPSetupDiagnosis.report(MCPStatusAdapter().setupFacts())
            Task { @MainActor in
                // The tooltip is read by a person: the verdict with the
                // person's fix, not the agent's ("call stop_capture…").
                self.cachedVerdict = MCPSetupDiagnosis.humanVerdict(report)
                self.diagnosisInFlight = false
                self.refreshIcon()
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleCapture() { TrafficCommands.toggleCapture() }

    @objc private func restartCapture() { CaptureDeliveryMonitor.shared.restartCapture() }

    @objc private func resumeAllHeld() { BreakpointService.shared.resumeAll() }

    @objc private func turnOffBridge() { MCPServerService.shared.setEnabled(false) }

    /// Brings the main window back, whatever state it is in.
    ///
    /// The first version sent `newWindowForTab:`, which nothing in a SwiftUI
    /// `WindowGroup` handles — the row did nothing at all with the window
    /// closed. It also picked a window out of `NSApp.windows`, whose order is
    /// unspecified, so with Settings open it could raise Settings instead, and
    /// a minimised window was never deminiaturised.
    ///
    /// So: find OUR window by the identifier the split host stamps on it, and
    /// fall back to the File ▸ New Window command, which exists because the
    /// app keeps the standard `.newItem` group.
    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.identifier == ReqResMainWindow.identifier }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }

        // No main window exists any more. Perform the real New Window item
        // rather than guessing a selector.
        if let fileMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.action == #selector(NSDocumentController.newDocument(_:)) } ?? false })?.submenu,
           let index = fileMenu.items.firstIndex(where: { $0.action == #selector(NSDocumentController.newDocument(_:)) }) {
            fileMenu.performActionForItem(at: index)
        }
    }

    @objc private func diagnoseSetup() {
        NSApp.activate(ignoringOtherApps: true)
        TrafficCommands.explainSetup()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // The same route `ReqResToolbarSlots` uses; SwiftUI's `openSettings`
        // action is not reachable from an AppKit target.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Goes through the normal terminate path, so the "this stops capture"
    /// confirmation still runs. Before Phase 0 that path could not terminate
    /// at all while capturing.
    @objc private func quit() {
        // Activate first: the terminate path raises a confirmation, and from a
        // status-item click with no window on screen it would otherwise appear
        // behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.terminate(nil)
    }
}
