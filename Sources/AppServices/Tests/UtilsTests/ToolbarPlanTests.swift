//
//  ToolbarPlanTests.swift
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
//  Guards the main window toolbar's ARRANGEMENT.
//
//  Each test here corresponds to a defect that was visible in a screenshot of
//  1.0.4 and invisible to the compiler: the search box sitting in the middle
//  of the toolbar, the sidebar toggle floating away from the sidebar edge,
//  and view-backed items vanishing into an empty overflow chevron at narrow
//  widths. Reordering `ReqResToolbarPlan.order` by hand should fail here
//  before it ever reaches a build.
//

import XCTest
@testable import Utils

final class ToolbarPlanTests: XCTestCase {

    private let order = ReqResToolbarPlan.order

    private func index(of slot: ReqResToolbarSlot) -> Int {
        guard let index = order.firstIndex(of: slot) else {
            XCTFail("\(slot) is missing from the toolbar plan")
            return -1
        }
        return index
    }

    // MARK: - Right edge

    /// The reported defect: "Search input ... is not to the right".
    func testSearchIsTheRightMostItem() {
        XCTAssertEqual(order.last, .search)
    }

    /// Being last is not enough — without a flexible space in front of it,
    /// search packs against its left-hand neighbour and floats mid-toolbar.
    func testSearchIsPushedToTheRightEdgeByAFlexibleSpace() {
        let searchIndex = index(of: .search)
        XCTAssertGreaterThan(searchIndex, 0)
        XCTAssertEqual(order[searchIndex - 1], .flexibleSpace)
    }

    /// A content-sized search item re-measures when the clear button appears
    /// on the first keystroke and shoves its neighbours sideways.
    func testSearchWidthIsAUsableConstant() {
        XCTAssertGreaterThanOrEqual(ReqResToolbarPlan.searchWidth, 180)
    }

    // MARK: - Sidebar edge

    /// The toggle belongs against the sidebar's trailing edge, where Mail and
    /// Notes keep it — which is what the leading flexible space buys.
    func testSidebarToggleIsPinnedToTheSidebarTrailingEdge() {
        let toggleIndex = index(of: .toggleSidebar)
        XCTAssertGreaterThan(toggleIndex, 0)
        XCTAssertEqual(order[toggleIndex - 1], .flexibleSpace)
        XCTAssertEqual(order[toggleIndex + 1], .sidebarSeparator)
    }

    // MARK: - Tracking separators

    func testExactlyOneSeparatorPerSplitDivider() {
        XCTAssertEqual(order.filter { $0 == .sidebarSeparator }.count, 1)
        XCTAssertEqual(order.filter { $0 == .listSeparator }.count, 1)
    }

    /// Separators must appear in the same order as the dividers they track,
    /// or the toolbar's sections anchor to the wrong panes.
    func testSeparatorsAppearInAscendingDividerOrder() {
        let separators = order.filter { $0.isTrackingSeparator }
        let dividers = separators.compactMap(\.trackedDividerIndex)
        XCTAssertEqual(dividers.count, separators.count, "a separator is missing its divider index")
        XCTAssertEqual(dividers, dividers.sorted())
        XCTAssertEqual(dividers, [0, 1])
    }

    // MARK: - Host switcher

    /// Measured: a chip placed in the SIDEBAR section fell
    /// into the overflow the moment the sidebar collapsed. It goes first after
    /// the sidebar separator instead.
    func testHostSwitcherIsTheFirstItemAfterTheSidebarSeparator() {
        XCTAssertEqual(order[index(of: .sidebarSeparator) + 1], .hostSwitcher)
    }

    /// The overrides pane can be as narrow as 200pt. One item in that section
    /// can overflow to the chevron; two items would squeeze the tracking
    /// separator off its divider. This is also why the title is a chip and not
    /// the window's native title: AppKit's title view has a 160pt floor and
    /// CANNOT overflow, which shoved the separator 79pt off the divider with
    /// the sidebar collapsed (measured 2026-09-16).
    func testHostSwitcherIsAloneInTheOverridesSection() {
        let between = Array(order[(index(of: .sidebarSeparator) + 1)..<index(of: .listSeparator)])
        XCTAssertEqual(between, [.hostSwitcher])
    }

    /// ＋, capture and the tools cluster live over the detail pane — past the
    /// list separator, where the pane is never narrower than 520pt.
    func testActionsSitOverTheDetailPane() {
        let listSeparator = index(of: .listSeparator)
        for slot in [ReqResToolbarSlot.add, .capture, .tools, .inspections, .search] {
            XCTAssertGreaterThan(index(of: slot), listSeparator, "\(slot) is not over the detail pane")
        }
    }

    // MARK: - Overflow survival

    /// A view-backed item with no `menuFormRepresentation` shows an EMPTY row
    /// in the native overflow chevron — the control silently becomes
    /// unreachable at narrow window widths.
    func testEveryHostedItemSurvivesTheOverflowChevron() {
        for slot in ReqResToolbarPlan.contentSlots {
            XCTAssertFalse(slot.label.isEmpty, "\(slot) has no toolbar label")
            XCTAssertNotNil(slot.overflowMenuTitle, "\(slot) would fold into an empty overflow row")
        }
    }

    func testSystemSlotsCarryNoContentOfTheirOwn() {
        for slot in order where slot.isSystemProvided {
            XCTAssertTrue(slot.label.isEmpty)
            XCTAssertNil(slot.overflowMenuTitle)
        }
    }

    // MARK: - Identifiers

    /// AppKit persists item identifiers in the window's saved configuration,
    /// so a collision silently drops one of the colliding items.
    func testIdentifiersAreUniqueAndNamespaced() {
        let identifiers = ReqResToolbarSlot.allCases.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        for identifier in identifiers {
            XCTAssertTrue(identifier.hasPrefix("com.oloapps.ReqRes.toolbar."))
        }
    }

    /// Spaces and the toggle are AppKit's to build; handing back our own item
    /// for those identifiers loses the system behaviour. BOTH tracking
    /// separators are ours: left to AppKit, the sidebar one exists only if it
    /// finds a split view under the window in time, and a missing item made
    /// the placeholder load throw at launch (measured 2026-09-17).
    func testOnlyNonSystemSlotsAreOursToBuild() {
        XCTAssertEqual(
            Set(ReqResToolbarPlan.customSlots),
            [.sidebarSeparator, .hostSwitcher, .listSeparator, .add, .capture, .tools, .inspections, .search])
    }

    func testBothTrackingSeparatorsAreBuiltByUs() {
        for slot in ReqResToolbarPlan.order where slot.isTrackingSeparator {
            XCTAssertFalse(slot.isSystemProvided, "\(slot) must be built by the delegate")
        }
    }

    /// `contentSlots` is what the delegate loops over to build hosted views;
    /// a tracking separator leaking in would crash on a missing root view.
    func testContentSlotsExcludeTrackingSeparators() {
        XCTAssertFalse(ReqResToolbarPlan.contentSlots.contains { $0.isTrackingSeparator })
        XCTAssertEqual(Set(ReqResToolbarPlan.contentSlots), [.hostSwitcher, .add, .capture, .tools, .inspections, .search])
    }

    // MARK: - Metrics

    /// The measured icon metric — the default borderless style renders
    /// each button ~37pt wide, which is what overflowed the cluster.
    func testIconButtonMetricMatchesTheMeasuredValue() {
        XCTAssertEqual(ReqResToolbarPlan.iconButtonSize, CGSize(width: 32, height: 26))
        XCTAssertEqual(ReqResToolbarPlan.iconPointSize, 16)
    }

    /// The chip must always fit its section at the overrides pane's 200pt
    /// minimum, with room for the platter's own insets.
    func testHostChipFitsTheNarrowestOverridesPane() {
        XCTAssertLessThanOrEqual(ReqResToolbarPlan.hostChipMaxWidth + 40, 200)
    }

    /// The gauge is status, not a control cluster: it sits after the tools,
    /// separated by a space, and is the item nearest the search field so it
    /// is the first thing the overflow takes before any control.
    func testInspectionGaugeSitsBetweenToolsAndSearch() {
        let gauge = index(of: .inspections)
        XCTAssertGreaterThan(gauge, index(of: .tools))
        XCTAssertEqual(order[gauge - 1], .space)
        XCTAssertEqual(order[gauge + 1], .flexibleSpace)
        XCTAssertEqual(order[gauge + 2], .search)
    }

    /// The hosted field divides its width between chips and the caret
    /// (66pt of chrome + a 44pt caret floor) and drops a 240pt-minimum
    /// suggestions panel under itself; a narrower slot would either starve
    /// the caret or hang the panel past the field's edge.
    func testSearchSlotIsWideEnoughForChipsCaretAndSuggestions() {
        XCTAssertGreaterThanOrEqual(ReqResToolbarPlan.searchWidth, 240)
    }
}
