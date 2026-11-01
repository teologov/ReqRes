//
//  TrafficTableScroll.swift
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
//  How far the traffic table scrolls when ↑ or ↓ moves its selection: just
//  enough for the row moved to to be wholly visible BELOW the pinned header,
//  as NSTableView does — nothing when it already is.
//
//  SwiftUI's own minimal scroll (`scrollTo(id, anchor: nil)`) knows nothing of
//  a pinned section header. Measured on macOS 27 (26A428) in a standalone
//  harness — a LazyVStack with a pinned 32pt header and 26pt rows, a 400pt
//  viewport — a row reached by moving up ended at y 0…26, wholly under the
//  header; a row 3.8pt of which showed below the header counted as visible
//  and was left there; and scrolling to the FIRST row put it under the header
//  too. So the table measures where the row is and asks SwiftUI for an anchor
//  instead, and this decides which: the same harness then kept every row
//  reached by 89 moves (up and down, far off screen, the viewport shrinking
//  under it as the detail pane opens) wholly below the header.
//
//  When the visible area changes height under that row — the detail pane
//  opening below the table, a window or divider dragged — a row that was in
//  view is kept in view, and only then: a row the table was scrolled away
//  from stays where the person scrolled it (`anchorAfterResize`).
//
//  Coordinates are the scroll view's VISIBLE area: 0 is its top edge, which
//  the pinned header covers down to `headerHeight`; `viewportHeight` is its
//  bottom edge.
//

import Foundation

public enum TrafficTableScroll {
    /// Layout lands rows on fractions of a point (a row at 373.8…399.8 in a
    /// 400pt area); a row within half a point of an edge counts as inside it.
    public static let tolerance = 0.5

    /// The anchor's y for `ScrollViewProxy.scrollTo(row, anchor:)` that shows
    /// a row wholly below the pinned header with the least scrolling — nil
    /// when it is shown so already.
    ///
    /// - Parameters:
    ///   - rowTop: the row's top edge in the visible area; nil when the row is
    ///     not laid out (the lazy stack has not built it: it is off screen).
    ///   - rowBottom: its bottom edge.
    ///   - direction: the move that made it the active row — where a row that
    ///     is not laid out most likely is: above for ↑, below for ↓.
    ///   - estimatedRowHeight: any row's height, for a row not laid out. A few
    ///     points off moves the row by a fraction of a point
    ///     (`belowHeader`'s error is header × error ÷ viewport).
    public static func anchor(
        rowTop: Double?,
        rowBottom: Double?,
        direction: TrafficTableNavigation.Direction,
        headerHeight: Double,
        viewportHeight: Double,
        estimatedRowHeight: Double
    ) -> Double? {
        guard let rowTop, let rowBottom else {
            // Off screen: up goes to the top, under the header; down to the
            // bottom edge. A guess that is wrong (↓ to a row above, after the
            // table was scrolled away from the selection) still shows the
            // row — scrolling stops at either end of the list.
            switch direction {
            case .up:
                return belowHeader(rowHeight: estimatedRowHeight, headerHeight: headerHeight, viewportHeight: viewportHeight)
            case .down:
                return 1
            }
        }
        let height = rowBottom - rowTop
        let belowTheHeader = belowHeader(rowHeight: height, headerHeight: headerHeight, viewportHeight: viewportHeight)
        if rowTop < headerHeight - tolerance {
            // Above the visible area, or under the header.
            return belowTheHeader
        }
        if rowBottom > viewportHeight + tolerance {
            // Below it. A row taller than the room under the header shows its
            // top instead of its bottom.
            return height > viewportHeight - headerHeight ? belowTheHeader : 1
        }
        return nil
    }

    /// Whether a row is wholly in view: below the pinned header and above
    /// the bottom edge, within `tolerance`.
    public static func isInView(rowTop: Double, rowBottom: Double, headerHeight: Double, viewportHeight: Double) -> Bool {
        rowTop >= headerHeight - tolerance && rowBottom <= viewportHeight + tolerance
    }

    /// The visible area changed height from `viewportBefore` to
    /// `viewportAfter` under the row the arrow keys moved to: the anchor that
    /// keeps the row in view — only when it WAS wholly in view before, and is
    /// not any more. nil for a row still in view, and for one the table was
    /// scrolled away from (or that is not laid out): a resize never brings
    /// back a row the person scrolled away from; the arrow keys do.
    public static func anchorAfterResize(
        rowTop: Double?,
        rowBottom: Double?,
        headerHeight: Double,
        viewportBefore: Double,
        viewportAfter: Double
    ) -> Double? {
        guard let rowTop, let rowBottom,
              isInView(rowTop: rowTop, rowBottom: rowBottom, headerHeight: headerHeight, viewportHeight: viewportBefore)
        else { return nil }
        return anchor(rowTop: rowTop, rowBottom: rowBottom, direction: .down, headerHeight: headerHeight,
                      viewportHeight: viewportAfter, estimatedRowHeight: rowBottom - rowTop)
    }

    /// The anchor that puts a row's top edge right under the pinned header.
    ///
    /// `scrollTo(row, anchor: y)` lines the point at fraction y of the row's
    /// height up with the point at fraction y of the visible area's:
    ///
    ///     rowTop + y · rowHeight = offset + y · viewportHeight
    ///
    /// so `offset = rowTop − y · (viewportHeight − rowHeight)`. The row's top
    /// is `headerHeight` below the visible top when `offset = rowTop −
    /// headerHeight`, which gives `y = headerHeight ÷ (viewportHeight −
    /// rowHeight)`. A visible area no taller than the row cannot hold it below
    /// anything: its top then goes to the top (0).
    public static func belowHeader(rowHeight: Double, headerHeight: Double, viewportHeight: Double) -> Double {
        let room = viewportHeight - rowHeight
        guard room > 0 else { return 0 }
        return max(0, headerHeight) / room
    }
}
