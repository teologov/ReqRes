//
//  ToolbarPlan.swift
//  AppServices
//
//  Created by OloApps on 16.09.2026.
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
//  The main window toolbar's ARRANGEMENT, as pure data.
//
//  It lives here — not next to the NSToolbarDelegate that consumes it —
//  because the arrangement is the part that breaks silently. An item in the
//  wrong place still compiles, still runs, and only shows up as "the search
//  box drifted into the middle again" in a screenshot weeks later. Pure data
//  with no AppKit in it can be asserted in `swift test`, which is the only
//  test runner this repo actually has wired.
//
//  Arrangement (Apple Mail's, with ReqRes's control set):
//
//    …flex… ⌸ │sidebar sep│ [host ⌄] │list sep│ ＋ ▶︎ ⚠︎ · 🗑 ✉︎ · [9/10 ▬▬] …flex… [search]
//
//  The selected host is a hosted CHIP (a menu that also switches hosts), never
//  the window's native title: AppKit's title view has a 160pt floor and cannot
//  overflow, so with the sidebar collapsed it shoved the list separator 79pt
//  off its divider (measured 2026-09-16). Toolbar items overflow; the title
//  view does not. Every rule encoded here is enforced by ToolbarPlanTests.
//

import Foundation

/// One slot in the main window's toolbar.
///
/// `system` slots are AppKit's own (spaces, the sidebar toggle, the tracking
/// separators); `custom` slots are ours and must carry both a label and an
/// overflow menu title — the native overflow chevron shows *nothing* for a
/// view-backed item without a `menuFormRepresentation`.
public enum ReqResToolbarSlot: String, CaseIterable, Sendable {
    /// Pushes the sidebar toggle against the sidebar's trailing edge, and
    /// (in its second occurrence) glues search to the window's right edge.
    case flexibleSpace
    case toggleSidebar
    /// Tracks split divider 0 — anchors the toolbar's sidebar section. Built
    /// by US, under AppKit's own identifier:
    /// left to AppKit, the item exists only if it can find a split view under
    /// the window at attach time — a child of SwiftUI's hosting controller
    /// here, so a race — and a missing item made the placeholder load throw
    /// NSInternalInconsistencyException on 2 of 4 launches (2026-09-17).
    case sidebarSeparator
    /// The selected host, as a chip that also switches hosts. FIRST after the
    /// sidebar separator and ALONE in its section: the overrides pane can be
    /// as narrow as 200pt, and one item can overflow to the chevron without
    /// ever squeezing the separator off its divider. (Placed in the sidebar
    /// section instead, it fell into the overflow the moment the sidebar
    /// collapsed.)
    case hostSwitcher
    /// Tracks split divider 1 — anchors the overrides section.
    case listSeparator
    /// ＋ — add a host filter or create an override.
    case add
    /// Start/pause capture, plus the setup-warning affordance.
    case capture
    case space
    /// Clear captured traffic · send feedback.
    case tools
    /// Free-tier HTTPS inspection gauge (count + progress). Hidden once
    /// licensed; a click opens the plans. A fixed-width box, so the count
    /// changing never re-measures the item.
    case inspections
    /// Always the right-most item.
    case search

    /// AppKit provides the item; we must not build one.
    public var isSystemProvided: Bool {
        switch self {
        case .flexibleSpace, .space, .toggleSidebar:
            return true
        case .sidebarSeparator, .hostSwitcher, .listSeparator, .add, .capture, .tools, .inspections, .search:
            return false
        }
    }

    /// Tracking separators are ours to *construct* but carry no content, so
    /// they are exempt from the label/menu-form rules below.
    public var isTrackingSeparator: Bool {
        self == .sidebarSeparator || self == .listSeparator
    }

    /// The split-view divider a tracking separator follows.
    public var trackedDividerIndex: Int? {
        switch self {
        case .sidebarSeparator: return 0
        case .listSeparator: return 1
        default: return nil
        }
    }

    /// Stable `NSToolbarItem.Identifier` string. Stable matters: AppKit
    /// persists item identifiers in the window's saved toolbar configuration.
    public var identifier: String { "com.oloapps.ReqRes.toolbar.\(rawValue)" }

    /// Shown under the item in text/overflow presentations.
    public var label: String {
        switch self {
        case .hostSwitcher: return "Host"
        case .add: return "Add"
        case .capture: return "Capture"
        case .tools: return "Tools"
        case .inspections: return "Free Inspections"
        case .search: return "Search"
        case .flexibleSpace, .space, .toggleSidebar,
             .sidebarSeparator, .listSeparator: return ""
        }
    }

    /// Title of the row the overflow chevron shows when this item is folded.
    /// `nil` for items that have nothing to offer there.
    public var overflowMenuTitle: String? {
        switch self {
        case .hostSwitcher: return "Host"
        case .add: return "Add"
        case .capture: return "Capture"
        case .tools: return "Tools"
        case .inspections: return "Free HTTPS Inspections"
        case .search: return "Search"
        default: return nil
        }
    }
}

public enum ReqResToolbarPlan {

    /// Left to right. Duplicated `.flexibleSpace` is deliberate — see the
    /// two rules it enforces in `ReqResToolbarSlot.flexibleSpace`.
    public static let order: [ReqResToolbarSlot] = [
        .flexibleSpace,
        .toggleSidebar,
        .sidebarSeparator,
        .hostSwitcher,
        .listSeparator,
        .add,
        .capture,
        .space,
        .tools,
        .space,
        .inspections,
        .flexibleSpace,
        .search,
    ]

    /// The search item's constant outer width.
    ///
    /// Constant, not a range: an item that sizes to its CONTENT re-measures
    /// when the clear button appears on the first keystroke and shoves every
    /// neighbour sideways. This is a measured rule.
    public static let searchWidth: CGFloat = 260

    /// The inspection gauge's constant width — label and bar lay out inside it.
    public static let inspectionsGaugeWidth: CGFloat = 136

    /// Cap on the host name inside the switcher chip. Content must not grow
    /// the toolbar unboundedly; a longer host truncates inside this box.
    public static let hostChipMaxWidth: CGFloat = 160

    /// Icon-button metric for controls hosted on a system platter: a 16pt
    /// symbol in a fixed 32×26 hit area. The platter is the chrome, so the
    /// buttons inside it draw no border of their own.
    public static let iconButtonSize = CGSize(width: 32, height: 26)
    public static let iconPointSize: CGFloat = 16

    /// Slots we build ourselves (everything AppKit does not provide).
    public static var customSlots: [ReqResToolbarSlot] {
        order.filter { !$0.isSystemProvided }
    }

    /// Slots that carry content of their own — i.e. need a label and an
    /// overflow row. (Tracking separators are ours to build but show nothing.)
    public static var contentSlots: [ReqResToolbarSlot] {
        customSlots.filter { !$0.isTrackingSeparator }
    }
}
