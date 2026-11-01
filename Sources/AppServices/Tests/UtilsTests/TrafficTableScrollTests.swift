//
//  TrafficTableScrollTests.swift
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
//  The arrow keys' scrolling: the row moved to ends wholly below the pinned
//  header, with the least scrolling. The anchors are checked against a model
//  of `ScrollViewProxy.scrollTo(_:anchor:)` — the documented alignment, the
//  offset clamped to the content — which the standalone harness on macOS 27
//  agreed with to a tenth of a point (rows at 32.0…58.0 under a 32pt header,
//  373.8…399.8 at the bottom of a 400pt area).
//

import XCTest
@testable import Utils

final class TrafficTableScrollTests: XCTestCase {
    private typealias Scroll = TrafficTableScroll

    private let header = 32.0
    private let viewport = 400.0
    private let row = 26.0

    private func anchor(top: Double?, bottom: Double?, _ direction: TrafficTableNavigation.Direction = .down,
                        viewport: Double? = nil, estimate: Double = 26) -> Double? {
        Scroll.anchor(rowTop: top, rowBottom: bottom, direction: direction, headerHeight: header,
                      viewportHeight: viewport ?? self.viewport, estimatedRowHeight: estimate)
    }

    private var belowHeader: Double { header / (viewport - row) }

    // MARK: - The decision

    /// Wholly visible below the header: no scrolling, whichever way the key
    /// moved — even at the very edges.
    func testARowAlreadyInViewIsLeftWhereItIs() {
        for direction in [TrafficTableNavigation.Direction.up, .down] {
            XCTAssertNil(anchor(top: 100, bottom: 126, direction))
            XCTAssertNil(anchor(top: header, bottom: header + row, direction), "right under the header")
            XCTAssertNil(anchor(top: viewport - row, bottom: viewport, direction), "on the bottom edge")
        }
    }

    /// Under the header, partly or wholly, or above the visible area: the
    /// row's top goes right under the header. SwiftUI's own minimal scroll
    /// counted the partly hidden row as visible and left it.
    func testARowUnderTheHeaderOrAboveGoesRightBelowTheHeader() {
        XCTAssertEqual(anchor(top: 9.8, bottom: 35.8, .up), belowHeader, "3.8pt showing below the header")
        XCTAssertEqual(anchor(top: 0, bottom: 26, .up), belowHeader, "wholly under it")
        XCTAssertEqual(anchor(top: -60, bottom: -34, .up), belowHeader, "above the visible area")
        XCTAssertEqual(anchor(top: 9.8, bottom: 35.8, .down), belowHeader, "the same whichever way the key moved")
    }

    /// Below the bottom edge, partly or wholly: its bottom goes to the bottom.
    func testARowBelowGoesToTheBottomEdge() {
        XCTAssertEqual(anchor(top: 390, bottom: 416), 1)
        XCTAssertEqual(anchor(top: 500, bottom: 526), 1)
        XCTAssertEqual(anchor(top: 390, bottom: 416, .up), 1)
    }

    /// A row taller than the room under the header shows its top.
    func testARowTallerThanTheRoomShowsItsTop() {
        let tall = Scroll.belowHeader(rowHeight: 100, headerHeight: header, viewportHeight: 120)
        XCTAssertEqual(anchor(top: 60, bottom: 160, .down, viewport: 120), tall)
        XCTAssertEqual(anchor(top: -100, bottom: 0, .up, viewport: 120), tall)
    }

    /// A row the lazy stack has not laid out is off screen: above it for ↑,
    /// below it for ↓.
    func testARowNotLaidOutGoesWhereTheKeyMoved() {
        XCTAssertEqual(anchor(top: nil, bottom: nil, .up), belowHeader)
        XCTAssertEqual(anchor(top: nil, bottom: nil, .down), 1)
    }

    /// Half a point either way is layout rounding, not a hidden row.
    func testHalfAPointIsRounding() {
        XCTAssertNil(anchor(top: header - 0.4, bottom: header + row - 0.4))
        XCTAssertNil(anchor(top: viewport - row + 0.4, bottom: viewport + 0.4))
        XCTAssertNotNil(anchor(top: header - 0.6, bottom: header + row - 0.6))
        XCTAssertNotNil(anchor(top: viewport - row + 0.6, bottom: viewport + 0.6))
    }

    /// y = header ÷ (visible height − row height); a visible area no taller
    /// than the row puts its top at the top; a header measured as nothing
    /// yet puts the row at the top too.
    func testTheAnchorBelowTheHeader() {
        XCTAssertEqual(Scroll.belowHeader(rowHeight: 26, headerHeight: 32, viewportHeight: 400), 32.0 / 374.0)
        XCTAssertEqual(Scroll.belowHeader(rowHeight: 26, headerHeight: 32, viewportHeight: 26), 0)
        XCTAssertEqual(Scroll.belowHeader(rowHeight: 26, headerHeight: 32, viewportHeight: 10), 0)
        XCTAssertEqual(Scroll.belowHeader(rowHeight: 26, headerHeight: 0, viewportHeight: 400), 0)
        XCTAssertEqual(Scroll.belowHeader(rowHeight: 26, headerHeight: -5, viewportHeight: 400), 0)
    }

    /// In view is what the anchor leaves alone: for a laid-out row, no
    /// anchor exactly when it is wholly in view below the header.
    func testInViewIsWhereNoScrollIsPlanned() {
        for top in stride(from: -60.0, through: 440, by: 0.25) {
            let bottom = top + row
            let inView = Scroll.isInView(rowTop: top, rowBottom: bottom, headerHeight: header, viewportHeight: viewport)
            XCTAssertEqual(anchor(top: top, bottom: bottom) == nil, inView, "row at \(top)")
        }
        XCTAssertTrue(Scroll.isInView(rowTop: header - 0.5, rowBottom: header + row - 0.5, headerHeight: header, viewportHeight: viewport))
        XCTAssertFalse(Scroll.isInView(rowTop: header - 0.6, rowBottom: header + row - 0.6, headerHeight: header, viewportHeight: viewport))
    }

    // MARK: - A resize under the row

    private func afterResize(top: Double?, bottom: Double?, from before: Double, to after: Double) -> Double? {
        Scroll.anchorAfterResize(rowTop: top, rowBottom: bottom, headerHeight: header,
                                 viewportBefore: before, viewportAfter: after)
    }

    /// The detail pane opening below the table: a row that was in view at
    /// the bottom goes to the new bottom edge; one still in view stays put.
    func testAResizeKeepsARowThatWasInViewInView() {
        XCTAssertEqual(afterResize(top: 374, bottom: 400, from: 400, to: 220), 1, "was on the bottom edge")
        XCTAssertEqual(afterResize(top: 200, bottom: 226, from: 400, to: 220), 1, "half below the new edge")
        XCTAssertNil(afterResize(top: 100, bottom: 126, from: 400, to: 220), "still in view")
        XCTAssertNil(afterResize(top: 374, bottom: 400, from: 400, to: 600), "the area grew")
    }

    /// A row the table was scrolled away from — above, under the header,
    /// below, or no longer laid out — is never brought back by a resize: the
    /// person scrolled away from it. Only the arrow keys bring it back.
    func testAResizeNeverBringsBackARowScrolledAwayFrom() {
        for (before, after) in [(400.0, 220.0), (220.0, 400.0), (400.0, 380.0), (400.0, 60.0)] {
            XCTAssertNil(afterResize(top: -100, bottom: -74, from: before, to: after), "above")
            XCTAssertNil(afterResize(top: 10, bottom: 36, from: before, to: after), "under the header")
            XCTAssertNil(afterResize(top: before + 50, bottom: before + 76, from: before, to: after), "below")
            XCTAssertNil(afterResize(top: before - 10, bottom: before + 16, from: before, to: after), "half below")
            XCTAssertNil(afterResize(top: nil, bottom: nil, from: before, to: after), "not laid out")
        }
    }

    // MARK: - Against a model of scrollTo

    /// A lazy stack under a pinned header: content y 0…header is the header's
    /// place at the top, row i at header + i·rowHeight.
    private struct Model {
        let header: Double
        let rowHeight: Double
        let rows: Int
        let viewport: Double
        var offset: Double = 0

        var maxOffset: Double { max(0, header + Double(rows) * rowHeight - viewport) }
        func top(_ index: Int) -> Double { header + Double(index) * rowHeight - offset }
        func bottom(_ index: Int) -> Double { top(index) + rowHeight }
        /// What the lazy stack has built: the rows on screen and a few beside.
        func isLaidOut(_ index: Int) -> Bool { bottom(index) > -100 && top(index) < viewport + 100 }

        /// `scrollTo(row, anchor: y)`: the point at y of the row lines up with
        /// the point at y of the visible area; the offset stays in the content.
        mutating func scroll(to index: Int, anchor y: Double) {
            let contentTop = header + Double(index) * rowHeight
            offset = min(max(contentTop + y * rowHeight - y * viewport, 0), maxOffset)
        }

        /// `scrollTo(row, anchor: nil)`: SwiftUI's minimal scroll, which knows
        /// the visible area's edges and nothing of the pinned header.
        mutating func scrollMinimally(to index: Int) {
            if top(index) < 0 {
                scroll(to: index, anchor: 0)
            } else if bottom(index) > viewport {
                scroll(to: index, anchor: 1)
            }
        }
    }

    /// Why the table does not use SwiftUI's own minimal scroll: moving up,
    /// the row ends under the header — what the harness measured (y 0…26) —
    /// and so does the first row.
    func testSwiftUIsOwnMinimalScrollLeavesTheRowUnderTheHeader() {
        var model = Model(header: header, rowHeight: row, rows: 300, viewport: viewport)
        model.scroll(to: 100, anchor: 1)
        model.scrollMinimally(to: 80)
        XCTAssertEqual(model.top(80), 0, accuracy: 0.001)
        XCTAssertLessThan(model.bottom(80), header, "wholly under the header")
        model.scrollMinimally(to: 0)
        XCTAssertLessThan(model.top(0), header)
    }

    /// Every row reached by ↑ or ↓, from every place the table can be scrolled
    /// to, in a tall and a short visible area: the planned scroll leaves it
    /// wholly below the header, and no scroll is planned for a row that is
    /// there already.
    func testEveryMoveEndsBelowTheHeaderWithTheLeastScrolling() {
        var moves = 0
        var failures: [String] = []
        for viewport in [400.0, 220.0, 59.0] {
            var model = Model(header: header, rowHeight: row, rows: 80, viewport: viewport)
            for start in stride(from: 0.0, through: model.maxOffset, by: 13.0) {
                for target in 0..<model.rows {
                    for direction in [TrafficTableNavigation.Direction.up, .down] {
                        model.offset = start
                        let laidOut = model.isLaidOut(target)
                        let wasInView = model.top(target) >= header - 0.5 && model.bottom(target) <= viewport + 0.5
                        let y = Scroll.anchor(rowTop: laidOut ? model.top(target) : nil,
                                              rowBottom: laidOut ? model.bottom(target) : nil,
                                              direction: direction, headerHeight: header,
                                              viewportHeight: viewport, estimatedRowHeight: row)
                        if let y { model.scroll(to: target, anchor: y) }
                        moves += 1
                        let inView = model.top(target) >= header - 0.5 && model.bottom(target) <= viewport + 0.5
                        if !inView || (wasInView && y != nil) {
                            failures.append("viewport \(viewport) offset \(start) row \(target) \(direction): "
                                            + "y \(y.map { "\($0)" } ?? "nil") → \(model.top(target))…\(model.bottom(target))")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(failures.prefix(5), [], "\(failures.count) of \(moves) moves")
        XCTAssertGreaterThan(moves, 10_000)
    }

    /// A row not laid out is placed with a guessed height; a guess a few
    /// points off moves it a fraction of a point (header × error ÷ room:
    /// 32 × 4 ÷ 374 ≈ 0.34).
    func testAWrongRowHeightGuessMovesTheRowAFractionOfAPoint() {
        for guess in [22.0, 26.0, 30.0] {
            var model = Model(header: header, rowHeight: row, rows: 300, viewport: viewport)
            model.scroll(to: 200, anchor: 1)
            let y = try! XCTUnwrap(Scroll.anchor(rowTop: nil, rowBottom: nil, direction: .up, headerHeight: header,
                                                  viewportHeight: viewport, estimatedRowHeight: guess))
            model.scroll(to: 19, anchor: y)
            XCTAssertEqual(model.top(19), header, accuracy: 0.5, "guess \(guess)")
        }
    }

    /// The visible area shrinking under the active row (the detail pane
    /// opening below the table) is planned like any move: the row goes to
    /// the new bottom edge.
    func testAShrinkingVisibleAreaKeepsTheRowInView() {
        var model = Model(header: header, rowHeight: row, rows: 300, viewport: viewport)
        model.scroll(to: 262, anchor: 1)
        XCTAssertEqual(model.bottom(262), viewport, accuracy: 0.001)
        let shrunk = Model(header: header, rowHeight: row, rows: 300, viewport: 220, offset: model.offset)
        var after = shrunk
        let y = Scroll.anchor(rowTop: shrunk.top(262), rowBottom: shrunk.bottom(262), direction: .down,
                              headerHeight: header, viewportHeight: 220, estimatedRowHeight: row)
        XCTAssertEqual(y, 1)
        after.scroll(to: 262, anchor: try! XCTUnwrap(y))
        XCTAssertEqual(after.bottom(262), 220, accuracy: 0.001)
    }

    /// Every row, from every place the table can be scrolled to, under a
    /// visible area that shrinks or grows: a row that was wholly in view
    /// ends wholly in view; a row that was not is never scrolled to — the
    /// offset the person scrolled to is kept.
    func testEveryResizeKeepsAVisibleRowAndNeverPullsBackAnother() {
        var resizes = 0
        var kept = 0
        var failures: [String] = []
        for (before, after) in [(400.0, 220.0), (400.0, 59.0), (220.0, 400.0), (400.0, 387.0)] {
            var model = Model(header: header, rowHeight: row, rows: 80, viewport: before)
            for start in stride(from: 0.0, through: model.maxOffset, by: 13.0) {
                for target in 0..<model.rows {
                    model = Model(header: header, rowHeight: row, rows: 80, viewport: before, offset: start)
                    let wasInView = model.top(target) >= header - 0.5 && model.bottom(target) <= before + 0.5
                    let laidOut = model.isLaidOut(target)
                    var resized = Model(header: header, rowHeight: row, rows: 80, viewport: after, offset: min(start, Model(header: header, rowHeight: row, rows: 80, viewport: after).maxOffset))
                    // Rows keep their place under the top edge unless the
                    // offset had to come back inside the content.
                    let y = Scroll.anchorAfterResize(rowTop: laidOut ? model.top(target) : nil,
                                                     rowBottom: laidOut ? model.bottom(target) : nil,
                                                     headerHeight: header, viewportBefore: before, viewportAfter: after)
                    let offsetBefore = resized.offset
                    if let y { resized.scroll(to: target, anchor: y) }
                    resizes += 1
                    let inView = resized.top(target) >= header - 0.5 && resized.bottom(target) <= after + 0.5
                    if wasInView {
                        kept += 1
                        if !inView && after - header >= row {
                            failures.append("\(before)→\(after) offset \(start) row \(target): lost from view")
                        }
                    } else if y != nil || resized.offset != offsetBefore {
                        failures.append("\(before)→\(after) offset \(start) row \(target): scrolled to a row out of view")
                    }
                }
            }
        }
        XCTAssertEqual(failures.prefix(5), [], "\(failures.count) of \(resizes) resizes")
        XCTAssertGreaterThan(resizes, 10_000)
        XCTAssertGreaterThan(kept, 1_000)
    }
}
