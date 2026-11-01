//
//  PaywallPresentation.swift
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
//  Who opened the ReqRes Pro sheet, from where, and which window shows it
//  (the paywall design of 2026-10-06, shell steps 4 and 5; the paywall
//  review's F26).
//
//  Every control that opens the sheet calls `show(_:)`, never
//  `LicenseManager.showPurchaseWindow()` itself: a limit's Upgrade… (host
//  filters, rules), the inspector's limit placeholder, the toolbar's
//  inspection gauge and the sidebar's Free Version badge. The sheet reads two
//  things from here:
//
//   - `reached`: the limit that opened it, whose row then says Reached. The
//     gauge passes `.httpsInspections` only when no inspection is left; the
//     badge passes nothing.
//   - `openedByPerson`: whether Return is Buy a License.
//     Return opens the browser only when the person asked for the sheet; the
//     one LicenseManager raises by itself at launch has no default button.
//
//  With several main windows (File ▸ New Window), exactly one shows the sheet,
//  `sheetOwner`: the window the person opened it from, else the key or
//  frontmost main window (PaywallSheetOwner, in Utils, decides). Each AppView
//  registers its window here and presents only when it is the owner.
//
//  The owner's AppView clears all three when the sheet goes, so the next
//  sheet starts from nothing reached, opened by nobody and owned by no window.
//

import AppKit
import Combine
import Foundation
import Utils
import XReqResCore

@MainActor
final class PaywallPresentation: ObservableObject {
    static let shared = PaywallPresentation()

    /// The free limit the person just reached, if a limit opened the sheet.
    @Published var reached: PaywallTrigger?

    /// True when a person opened the sheet; false for the one shown at launch.
    @Published var openedByPerson = false

    /// The window (its AppView's token) that shows the sheet, or nil while
    /// none does. AppViews watch it: the owner presents while LicenseManager's
    /// flag is up, and when the owner's window closes another one claims.
    @Published private(set) var sheetOwner: UUID?

    private var ownership = PaywallSheetOwner<UUID>()

    /// Every main window's AppView by its token, and how to find its window
    /// (nil until AppKit has put the view in one).
    private var windows: [UUID: @MainActor () -> NSWindow?] = [:]

    /// Opens the sheet for a person, with Reached on `trigger`'s row (none
    /// for nil), in the window the person is in. With the sheet already up in
    /// another window, that window comes forward instead of a second sheet.
    func show(_ trigger: PaywallTrigger?) {
        reached = trigger
        openedByPerson = true
        if let showing = ownership.open(from: keyMainWindow) {
            windows[showing]?()?.makeKeyAndOrderFront(nil)
        }
        publishOwner()
        LicenseManager.shared.showPurchaseWindow()
    }

    /// `token`'s AppView is on screen; `window` finds its window.
    func register(_ token: UUID, window: @escaping @MainActor () -> NSWindow?) {
        windows[token] = window
    }

    /// LicenseManager's flag is up: whether `token`'s window presents the
    /// sheet. With no owner yet, every window makes the same choice, so
    /// whichever asks first, one window presents.
    func claimSheet(for token: UUID) -> Bool {
        let claimed = ownership.claim(token, key: keyMainWindow, frontToBack: mainWindowsFrontToBack)
        publishOwner()
        return claimed
    }

    /// Whether `token`'s window shows the sheet: only its dismissal resets
    /// the presentation.
    func ownsSheet(_ token: UUID) -> Bool {
        ownership.owner == token
    }

    /// `token`'s window has closed. If it showed the sheet, the sheet has no
    /// owner, and a window still open claims it.
    func windowClosed(_ token: UUID) {
        windows[token] = nil
        ownership.release(token)
        publishOwner()
    }

    /// The sheet has gone: nothing reached, opened by nobody, owned by no
    /// window.
    func reset() {
        reached = nil
        openedByPerson = false
        ownership = PaywallSheetOwner()
        publishOwner()
    }

    private func publishOwner() {
        if sheetOwner != ownership.owner {
            sheetOwner = ownership.owner
        }
    }

    /// The main window the person is in: the key window, or the window a key
    /// sheet belongs to (a form's Upgrade…, the sheet's own key entry).
    private var keyMainWindow: UUID? {
        var window = NSApp.keyWindow
        while let parent = window?.sheetParent {
            window = parent
        }
        return token(for: window)
    }

    private var mainWindowsFrontToBack: [UUID] {
        NSApp.orderedWindows.compactMap { window in token(for: window) }
    }

    private func token(for window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return windows.first { entry in entry.value() === window }?.key
    }
}
