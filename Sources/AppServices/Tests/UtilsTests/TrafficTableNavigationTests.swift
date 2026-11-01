//
//  TrafficTableNavigationTests.swift
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
//  The traffic table's ↑ / ↓ and the clicks that share their ⇧ anchor. Rows are
//  letters in the order the table shows them; the selection and the cursor are
//  by row, never by index — the table gains rows at the top while it is read.
//

import XCTest
@testable import Utils

final class TrafficTableNavigationTests: XCTestCase {
    private typealias Nav = TrafficTableNavigation
    private typealias Cursor = TrafficTableNavigation.Cursor<String>

    /// The table as shown: newest first.
    private let table = ["a", "b", "c", "d", "e", "f"]

    private func move(_ direction: Nav.Direction, shift: Bool = false, rows: [String]? = nil,
                      selection: Set<String>, cursor: Cursor = Cursor()) -> Nav.Outcome<String>? {
        Nav.move(direction, extending: shift, rows: rows ?? table, selection: selection, cursor: cursor)
    }

    private func click(_ row: String, _ kind: Nav.Click, rows: [String]? = nil,
                       selection: Set<String>, cursor: Cursor = Cursor()) -> Nav.Outcome<String> {
        Nav.click(row, kind, rows: rows ?? table, selection: selection, cursor: cursor)
    }

    /// A click on `row` alone, as the table's state after it.
    private func clicked(_ row: String) -> (selection: Set<String>, cursor: Cursor) {
        let outcome = click(row, .select, selection: [])
        return (outcome.selection, outcome.cursor)
    }

    // MARK: - ↑ and ↓

    private struct Case {
        let name: String
        let direction: Nav.Direction
        var rows: [String]? = nil
        let selection: Set<String>
        let expected: String
    }

    /// Without ⇧: one row past the selection's edge, alone — anchor, active
    /// row and selection all on it.
    func testTheArrowsMoveToTheNextRowAlone() {
        let cases: [Case] = [
            Case(name: "nothing selected, ↓: the first row", direction: .down, selection: [], expected: "a"),
            Case(name: "nothing selected, ↑: the last row", direction: .up, selection: [], expected: "f"),
            Case(name: "one row, ↓", direction: .down, selection: ["c"], expected: "d"),
            Case(name: "one row, ↑", direction: .up, selection: ["c"], expected: "b"),
            Case(name: "the last row, ↓: stays (no wrap)", direction: .down, selection: ["f"], expected: "f"),
            Case(name: "the first row, ↑: stays (no wrap)", direction: .up, selection: ["a"], expected: "a"),
            Case(name: "several, ↓: after the bottom-most", direction: .down, selection: ["b", "d"], expected: "e"),
            Case(name: "several, ↑: before the top-most", direction: .up, selection: ["b", "d"], expected: "a"),
            Case(name: "a range, ↓", direction: .down, selection: ["b", "c", "d"], expected: "e"),
            Case(name: "a range, ↑", direction: .up, selection: ["b", "c", "d"], expected: "a"),
            Case(name: "several reaching the end, ↓: the last row alone", direction: .down, selection: ["a", "f"], expected: "f"),
            Case(name: "several reaching the top, ↑: the first row alone", direction: .up, selection: ["a", "f"], expected: "a"),
            Case(name: "only hidden rows selected, ↓: as nothing selected", direction: .down, selection: ["x"], expected: "a"),
            Case(name: "only hidden rows selected, ↑: as nothing selected", direction: .up, selection: ["x", "y"], expected: "f"),
            Case(name: "a hidden row besides a shown one: the shown one counts", direction: .down, selection: ["x", "c"], expected: "d"),
            Case(name: "a one-row table, ↓", direction: .down, rows: ["a"], selection: ["a"], expected: "a"),
            Case(name: "a one-row table, ↑, nothing selected", direction: .up, rows: ["a"], selection: [], expected: "a"),
        ]
        for test in cases {
            guard let outcome = move(test.direction, rows: test.rows, selection: test.selection) else {
                XCTFail("\(test.name): no outcome")
                continue
            }
            XCTAssertEqual(outcome.selection, [test.expected], test.name)
            XCTAssertEqual(outcome.active, test.expected, test.name)
            XCTAssertEqual(outcome.cursor, Cursor(anchor: test.expected, active: test.expected, kept: []), test.name)
        }
    }

    /// An empty table has nothing to move to, with or without ⇧.
    func testAnEmptyTableHasNothingToMoveTo() {
        for direction in [Nav.Direction.up, .down] {
            for shift in [false, true] {
                XCTAssertNil(move(direction, shift: shift, rows: [], selection: ["a"], cursor: Cursor(anchor: "a", active: "a")))
                XCTAssertNil(move(direction, shift: shift, rows: [], selection: []))
            }
        }
    }

    /// A held ↓ walks the whole table one row at a time and stops at the end.
    func testAHeldArrowWalksTheTableAndStopsAtTheEnd() {
        var selection: Set<String> = []
        var cursor = Cursor()
        var visited: [String] = []
        for _ in 0..<8 {
            let outcome = try! XCTUnwrap(move(.down, selection: selection, cursor: cursor))
            selection = outcome.selection
            cursor = outcome.cursor
            visited.append(outcome.active)
        }
        XCTAssertEqual(visited, ["a", "b", "c", "d", "e", "f", "f", "f"])
        for _ in 0..<7 {
            let outcome = try! XCTUnwrap(move(.up, selection: selection, cursor: cursor))
            selection = outcome.selection
            cursor = outcome.cursor
            visited.append(outcome.active)
        }
        XCTAssertEqual(visited.suffix(7), ["e", "d", "c", "b", "a", "a", "a"])
    }

    /// The selection is a row, not a position: rows arriving at the top (live
    /// traffic, every 150 ms) never move it, for the arrows or for ⇧.
    func testRowsArrivingAtTheTopNeverMoveTheSelection() {
        let grown = ["n2", "n1"] + table
        let one = clicked("c")
        XCTAssertEqual(move(.down, rows: grown, selection: one.selection, cursor: one.cursor)?.selection, ["d"])
        XCTAssertEqual(move(.up, rows: grown, selection: one.selection, cursor: one.cursor)?.selection, ["b"])

        let range = try! XCTUnwrap(move(.down, shift: true, selection: one.selection, cursor: one.cursor)) // c, d
        let extended = move(.down, shift: true, rows: grown, selection: range.selection, cursor: range.cursor)
        XCTAssertEqual(extended?.selection, ["c", "d", "e"])
        XCTAssertEqual(extended?.cursor.anchor, "c")
        // ⇧-click too: the anchor is the row clicked before the rows arrived.
        XCTAssertEqual(click("e", .extend, rows: grown, selection: one.selection, cursor: one.cursor).selection, ["c", "d", "e"])
    }

    // MARK: - ⇧↑ and ⇧↓

    /// ⇧ walks the active end away from the anchor, and back: the range
    /// grows, shrinks to the anchor, and grows past it the other way.
    func testShiftExtendsShrinksAndReversesAcrossTheAnchor() {
        var state = clicked("c")
        let steps: [(Nav.Direction, Set<String>, String)] = [
            (.down, ["c", "d"], "d"),          // extend
            (.down, ["c", "d", "e"], "e"),
            (.up, ["c", "d"], "d"),            // shrink
            (.up, ["c"], "c"),                 // back to the anchor
            (.up, ["b", "c"], "b"),            // past it: the other way
            (.up, ["a", "b", "c"], "a"),
            (.up, ["a", "b", "c"], "a"),       // the first row: stays
            (.down, ["b", "c"], "b"),          // shrink back toward it
            (.down, ["c"], "c"),
            (.down, ["c", "d"], "d"),          // and across it again
        ]
        for (index, step) in steps.enumerated() {
            let outcome = try! XCTUnwrap(move(step.0, shift: true, selection: state.selection, cursor: state.cursor))
            XCTAssertEqual(outcome.selection, step.1, "step \(index + 1)")
            XCTAssertEqual(outcome.active, step.2, "step \(index + 1)")
            XCTAssertEqual(outcome.cursor.anchor, "c", "step \(index + 1): the anchor never moves")
            state = (outcome.selection, outcome.cursor)
        }
    }

    func testShiftStopsAtTheEnds() {
        let bottom = try! XCTUnwrap(move(.down, shift: true, selection: ["e"], cursor: Cursor(anchor: "e", active: "e")))
        XCTAssertEqual(bottom.selection, ["e", "f"])
        let still = try! XCTUnwrap(move(.down, shift: true, selection: bottom.selection, cursor: bottom.cursor))
        XCTAssertEqual(still.selection, ["e", "f"])
        XCTAssertEqual(still.active, "f")
        let top = try! XCTUnwrap(move(.up, shift: true, selection: ["a", "b"], cursor: Cursor(anchor: "b", active: "a")))
        XCTAssertEqual(top.selection, ["a", "b"])
        XCTAssertEqual(top.active, "a")
    }

    /// With nothing selected on screen there is no range: ⇧↓ starts at the
    /// first row and ⇧↑ at the last, as the plain arrows do — whatever anchor
    /// an earlier selection (cleared by Esc) left behind.
    func testShiftWithNothingSelectedStartsLikeThePlainArrows() {
        let stale = Cursor(anchor: "c", active: "d")
        for selection: Set<String> in [[], ["x"]] {
            XCTAssertEqual(move(.down, shift: true, selection: selection, cursor: stale)?.cursor, Cursor(anchor: "a", active: "a"))
            XCTAssertEqual(move(.up, shift: true, selection: selection, cursor: stale)?.cursor, Cursor(anchor: "f", active: "f"))
            XCTAssertEqual(move(.down, shift: true, selection: selection, cursor: stale)?.selection, ["a"])
        }
    }

    /// Rows ⌘-clicked before the anchor was set stay selected whatever the
    /// ⇧ range does — and the range is from the anchor alone.
    func testRowsSelectedBeforeTheAnchorStayWhateverTheRangeDoes() {
        let first = clicked("a")
        let added = click("d", .toggle, selection: first.selection, cursor: first.cursor)
        XCTAssertEqual(added.selection, ["a", "d"])
        XCTAssertEqual(added.cursor, Cursor(anchor: "d", active: "d", kept: ["a"]))
        var state = (added.selection, added.cursor)
        for (direction, expected) in [(Nav.Direction.down, Set(["a", "d", "e"])), (.up, ["a", "d"]), (.up, ["a", "c", "d"]), (.up, ["a", "b", "c", "d"])] {
            let outcome = try! XCTUnwrap(move(direction, shift: true, selection: state.0, cursor: state.1))
            XCTAssertEqual(outcome.selection, expected)
            state = (outcome.selection, outcome.cursor)
        }
    }

    /// The anchor hidden by a filter while the active row and others stay
    /// shown: the shown selection stands in for the range, anchored at its
    /// far end from the active row. Nothing already selected is dropped —
    /// the hidden anchor stays selected.
    func testAHiddenAnchorIsReplacedByTheFarEndOfWhatIsStillSelected() {
        let filtered = ["a", "b", "d", "e", "f"] // c hidden
        let cursor = Cursor(anchor: "c", active: "e")
        let down = try! XCTUnwrap(move(.down, shift: true, rows: filtered, selection: ["c", "d", "e"], cursor: cursor))
        XCTAssertEqual(down.selection, ["c", "d", "e", "f"])
        XCTAssertEqual(down.cursor, Cursor(anchor: "d", active: "f", kept: ["c"]))
        let up = try! XCTUnwrap(move(.up, shift: true, rows: filtered, selection: ["c", "d", "e"], cursor: cursor))
        XCTAssertEqual(up.selection, ["c", "d"], "⇧↑ shrinks from the active end toward the stand-in anchor")
        XCTAssertEqual(up.cursor, Cursor(anchor: "d", active: "d", kept: ["c"]))
        // Then on from the new anchor.
        let again = try! XCTUnwrap(move(.up, shift: true, rows: filtered, selection: up.selection, cursor: up.cursor))
        XCTAssertEqual(again.selection, ["b", "c", "d"])
    }

    /// The anchor gone and the active row gone too: the range runs from the
    /// end of the shown selection the move leaves behind. A gap in it is
    /// filled — the range is contiguous.
    func testWithNoAnchorAndNoActiveRowTheMoveLeavesTheFarEndBehind() {
        let lost = Cursor(anchor: "x", active: "y")
        let down = try! XCTUnwrap(move(.down, shift: true, selection: ["b", "c", "d"], cursor: lost))
        XCTAssertEqual(down.selection, ["b", "c", "d", "e"])
        XCTAssertEqual(down.cursor, Cursor(anchor: "b", active: "e"))
        let up = try! XCTUnwrap(move(.up, shift: true, selection: ["b", "c", "d"], cursor: lost))
        XCTAssertEqual(up.selection, ["a", "b", "c", "d"])
        XCTAssertEqual(up.cursor, Cursor(anchor: "d", active: "a"))
        let gap = try! XCTUnwrap(move(.down, shift: true, selection: ["b", "d"], cursor: Cursor(anchor: "x", active: "d")))
        XCTAssertEqual(gap.selection, ["b", "c", "d", "e"])
    }

    /// The anchor shown but the active row gone: the range resumes from the
    /// end of the shown selection farther from the anchor.
    func testAHiddenActiveRowResumesFromTheFarEndOfTheSelection() {
        let outcome = try! XCTUnwrap(move(.down, shift: true, selection: ["b", "c", "d"], cursor: Cursor(anchor: "b", active: "x")))
        XCTAssertEqual(outcome.selection, ["b", "c", "d", "e"])
        XCTAssertEqual(outcome.cursor, Cursor(anchor: "b", active: "e"))
    }

    // MARK: - Clicks

    func testAPlainClickSelectsTheRowAloneAndAnchorsThere() {
        let outcome = click("e", .select, selection: ["a", "c"], cursor: Cursor(anchor: "a", active: "c", kept: ["x"]))
        XCTAssertEqual(outcome.selection, ["e"])
        XCTAssertEqual(outcome.cursor, Cursor(anchor: "e", active: "e"))
    }

    func testACommandClickTogglesTheRowAndAnchorsThere() {
        let added = click("d", .toggle, selection: ["a"], cursor: Cursor(anchor: "a", active: "a"))
        XCTAssertEqual(added.selection, ["a", "d"])
        XCTAssertEqual(added.cursor, Cursor(anchor: "d", active: "d", kept: ["a"]))
        let removed = click("a", .toggle, selection: added.selection, cursor: added.cursor)
        XCTAssertEqual(removed.selection, ["d"])
        XCTAssertEqual(removed.cursor, Cursor(anchor: "a", active: "a", kept: ["d"]))
        XCTAssertNil(Nav.activeRow(selection: removed.selection, cursor: removed.cursor),
                     "the row ⌘-clicked out is not shown in the detail pane")
    }

    /// ⇧-click selects the range from the anchor — and, like ⇧↑, shrinks it
    /// and reverses it across the anchor (it used to only ever add rows).
    func testAShiftClickSelectsTheRangeFromTheAnchor() {
        let start = clicked("b")
        let far = click("e", .extend, selection: start.selection, cursor: start.cursor)
        XCTAssertEqual(far.selection, ["b", "c", "d", "e"])
        XCTAssertEqual(far.cursor, Cursor(anchor: "b", active: "e"))
        let nearer = click("c", .extend, selection: far.selection, cursor: far.cursor)
        XCTAssertEqual(nearer.selection, ["b", "c"])
        let across = click("a", .extend, selection: nearer.selection, cursor: nearer.cursor)
        XCTAssertEqual(across.selection, ["a", "b"])
        XCTAssertEqual(across.cursor.anchor, "b")
    }

    /// ⇧-click and ⇧↑/⇧↓ share one anchor and one active row: each picks up
    /// where the other left off.
    func testShiftClicksAndShiftArrowsShareTheAnchor() {
        let start = clicked("c")
        let down = try! XCTUnwrap(move(.down, shift: true, selection: start.selection, cursor: start.cursor))
        let further = try! XCTUnwrap(move(.down, shift: true, selection: down.selection, cursor: down.cursor))
        XCTAssertEqual(further.selection, ["c", "d", "e"])
        let clickedAbove = click("b", .extend, selection: further.selection, cursor: further.cursor)
        XCTAssertEqual(clickedAbove.selection, ["b", "c"], "from the arrows' anchor, c")
        let thenDown = try! XCTUnwrap(move(.down, shift: true, selection: clickedAbove.selection, cursor: clickedAbove.cursor))
        XCTAssertEqual(thenDown.selection, ["c"], "on from the row clicked")
        XCTAssertEqual(thenDown.active, "c")
    }

    func testAShiftClickKeepsRowsSelectedBeforeTheAnchor() {
        let first = clicked("a")
        let added = click("d", .toggle, selection: first.selection, cursor: first.cursor)
        XCTAssertEqual(click("f", .extend, selection: added.selection, cursor: added.cursor).selection, ["a", "d", "e", "f"])
    }

    /// With nothing selected on screen a ⇧-click is a plain click — as ⇧↓
    /// is a plain ↓ then. It used to extend from wherever the last click had
    /// been, even after Esc had cleared the selection.
    func testAShiftClickWithNothingSelectedIsAPlainClick() {
        let stale = Cursor(anchor: "b", active: "b")
        XCTAssertEqual(click("e", .extend, selection: [], cursor: stale).selection, ["e"])
        XCTAssertEqual(click("e", .extend, selection: [], cursor: stale).cursor, Cursor(anchor: "e", active: "e"))
        XCTAssertEqual(click("e", .extend, selection: ["x"], cursor: stale).selection, ["e"])
    }

    /// The ⇧-click anchor used to be an INDEX into the filtered list: a row
    /// clicked far down, then a search that left fewer rows, made a ⇧-click
    /// build a range past the end of the array — a trap. By row, a hidden
    /// anchor is simply not there.
    func testAShiftClickAfterTheListGotShorterNeverReachesPastIt() {
        let start = clicked("f")
        let short = ["a", "b"]
        XCTAssertEqual(click("b", .extend, rows: short, selection: start.selection, cursor: start.cursor).selection, ["b"])
    }

    /// The anchor gone: the range runs from the end of the shown selection
    /// farther from the row clicked (the top one when both are as far).
    func testAShiftClickWithTheAnchorGoneExtendsFromTheFarEnd() {
        let lost = Cursor(anchor: "x", active: "x")
        let selection: Set<String> = ["c", "d", "e"]
        XCTAssertEqual(click("f", .extend, selection: selection, cursor: lost).selection, ["c", "d", "e", "f"])
        XCTAssertEqual(click("f", .extend, selection: selection, cursor: lost).cursor, Cursor(anchor: "c", active: "f"))
        XCTAssertEqual(click("a", .extend, selection: selection, cursor: lost).selection, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(click("d", .extend, selection: selection, cursor: lost).selection, ["c", "d"])
        // Rows selected outside what the table shows stay selected.
        XCTAssertEqual(click("f", .extend, selection: selection.union(["x"]), cursor: lost).selection, ["c", "d", "e", "f", "x"])
    }

    /// ⌘ wins over ⇧, as it always has here.
    func testWhichClickTheModifiersMake() {
        XCTAssertEqual(Nav.Click(command: false, shift: false), .select)
        XCTAssertEqual(Nav.Click(command: true, shift: false), .toggle)
        XCTAssertEqual(Nav.Click(command: false, shift: true), .extend)
        XCTAssertEqual(Nav.Click(command: true, shift: true), .toggle)
    }

    // MARK: - The active row

    /// The detail pane shows the row last clicked or moved to while it is
    /// selected — the end a ⇧-move just reached, not some other selected row.
    func testTheActiveRowIsTheOneLastClickedOrMovedTo() {
        let start = clicked("c")
        let down = try! XCTUnwrap(move(.down, shift: true, selection: start.selection, cursor: start.cursor))
        XCTAssertEqual(Nav.activeRow(selection: down.selection, cursor: down.cursor), "d")
        XCTAssertNil(Nav.activeRow(selection: [], cursor: down.cursor), "Esc cleared the selection")
        XCTAssertNil(Nav.activeRow(selection: ["c"], cursor: Cursor()))
    }
}
