//
//  PaywallSheetOwner.swift
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
//  Which main window shows the ReqRes Pro sheet (the paywall review's F26).
//
//  Every main window is an AppView, and File ▸ New Window opens more. Each one
//  used to raise its own copy of the sheet from LicenseManager's one flag, so
//  with two windows both showed it: answering one left the other up, and the
//  shared presentation (the limit marked Reached, whether Return buys) was
//  reset under the copy still on screen. Exactly one window owns the sheet:
//
//   - A person opens it from a window (a limit's Upgrade…, the inspector's
//     limit, the toolbar gauge, the sidebar badge): that window shows it. If
//     another window already owns it, no second sheet appears; that window
//     comes forward instead.
//   - LicenseManager raises it by itself (at launch): the key main window,
//     else the frontmost main window, else the first window whose view sees
//     the flag. Every window computes the same choice, so whichever view
//     sees the flag first, the same window presents.
//   - Only the owner's dismissal resets the presentation. A window that
//     closes gives its claim up, and another window takes the sheet.
//
//  Plain data over any window identity, so the choices are tested without a
//  window (PaywallSheetOwnerTests); PaywallPresentation feeds it AppKit's
//  key and front-to-back windows.
//

import Foundation

public struct PaywallSheetOwner<Window: Hashable>: Equatable {
    /// The window that shows the sheet, or nil while none does.
    public private(set) var owner: Window?

    public init() {}

    /// The window a sheet that nobody opened goes to: the key main window,
    /// else the frontmost main window, else `candidate`, the window asking.
    public static func preferred(key: Window?, frontToBack: [Window], candidate: Window) -> Window {
        key ?? frontToBack.first ?? candidate
    }

    /// A person opened the sheet from `opener` (nil when its window is not
    /// known). With no owner yet, that window becomes it. Returns the window
    /// to bring forward instead of showing a second sheet: the owner, when
    /// it is another window.
    public mutating func open(from opener: Window?) -> Window? {
        guard let owner else {
            self.owner = opener
            return nil
        }
        return owner == opener ? nil : owner
    }

    /// LicenseManager's flag is up, and `window`'s view asks whether it
    /// presents the sheet. With no owner yet, the preferred window becomes
    /// it, whichever window asks first.
    public mutating func claim(_ window: Window, key: Window?, frontToBack: [Window]) -> Bool {
        if owner == nil {
            owner = Self.preferred(key: key, frontToBack: frontToBack, candidate: window)
        }
        return owner == window
    }

    /// `window` closed. Returns true when it owned the sheet, which then has
    /// no owner, so another window can claim it.
    @discardableResult
    public mutating func release(_ window: Window) -> Bool {
        guard owner == window else { return false }
        owner = nil
        return true
    }
}
