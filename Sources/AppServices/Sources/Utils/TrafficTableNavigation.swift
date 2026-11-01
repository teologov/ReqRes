//
//  TrafficTableNavigation.swift
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
//  How the traffic table's selection moves — by ↑ and ↓, and by clicks,
//  which share the rules for ⇧.
//
//  Everything is by ROW ID, in the order the table SHOWS (the filtered list,
//  newest first), never by index. The table gains rows at the top while it is
//  read — live traffic arrives every 150 ms — so an index names a different
//  row a moment later. Until this type, ⇧-click's anchor was such an index:
//  after new rows arrived it extended from the wrong row, and after the list
//  was filtered shorter than the anchor's index it trapped (the range ran past
//  the end of the array).
//
//  The rules, as Mail and Finder's lists keep them:
//   * ↓ / ↑ select the row after the bottom-most selected row / the row before
//     the top-most, alone. With nothing selected that the table shows —
//     nothing at all, or only rows a host filter or search now hides — ↓
//     selects the first row and ↑ the last. At either end the selection stays
//     where it is: no wrapping.
//   * ⇧↓ / ⇧↑ move the ACTIVE end of a range whose other end is the ANCHOR —
//     extending it, or shrinking it back toward the anchor and past it. ⇧-click
//     selects the range from that same anchor to the row clicked.
//   * The anchor is set by a plain click, a ⌘-click or an unshifted arrow. Rows
//     selected before it (by ⌘-clicks) stay selected whatever the range does.
//   * When the anchor is gone — hidden by a filter, deleted, aged out — a ⇧
//     move starts again from the rows still selected on screen, which stand in
//     for the range: anchored at their far end from the active row (or, with
//     no active row on screen, at the end the move leaves behind; for a click,
//     at the end farther from the row clicked).
//

import Foundation

public enum TrafficTableNavigation {
    /// Which way an arrow moves, in the table's order (↓ = toward older rows).
    public enum Direction: Equatable, Sendable {
        case up
        case down
    }

    /// What a click asks for. ⌘ wins over ⇧, as it always has here.
    public enum Click: Equatable, Sendable {
        /// A plain click: the row alone.
        case select
        /// ⌘-click: add the row, or take it out.
        case toggle
        /// ⇧-click: the range from the anchor to the row.
        case extend

        public init(command: Bool, shift: Bool) {
            if command {
                self = .toggle
            } else if shift {
                self = .extend
            } else {
                self = .select
            }
        }
    }

    /// What the selection remembers between moves and clicks, all by row ID.
    public struct Cursor<ID: Hashable>: Equatable {
        /// Where ⇧ ranges start: the row of the last plain click, ⌘-click or
        /// unshifted arrow.
        public var anchor: ID?
        /// The active row: the row last clicked or moved to. ⇧-moves go on
        /// from it, the table scrolls to it, and the detail pane shows it
        /// while it is selected.
        public var active: ID?
        /// Rows a ⇧ range keeps selected whatever it covers: those selected
        /// when the anchor was set, the anchor itself aside.
        public var kept: Set<ID>

        public init(anchor: ID? = nil, active: ID? = nil, kept: Set<ID> = []) {
            self.anchor = anchor
            self.active = active
            self.kept = kept
        }
    }

    /// A move's or a click's result: the new selection and cursor.
    public struct Outcome<ID: Hashable>: Equatable {
        public var selection: Set<ID>
        public var cursor: Cursor<ID>
        /// The row moved to or clicked — `cursor.active`, never nil here.
        public var active: ID

        public init(selection: Set<ID>, cursor: Cursor<ID>, active: ID) {
            self.selection = selection
            self.cursor = cursor
            self.active = active
        }
    }

    /// ↑ or ↓, with or without ⇧. nil when the table shows no rows: there is
    /// nothing to move to.
    ///
    /// - Parameters:
    ///   - rows: the rows the table shows, in its order.
    ///   - selection: the selected rows; it can hold rows the table no
    ///     longer shows, which count as not selected here.
    public static func move<ID: Hashable>(
        _ direction: Direction,
        extending: Bool,
        rows: [ID],
        selection: Set<ID>,
        cursor: Cursor<ID>
    ) -> Outcome<ID>? {
        guard let last = rows.indices.last else { return nil }
        guard let span = shownSpan(of: selection, in: rows) else {
            // Nothing selected on screen: ↓ starts at the first row and ↑ at
            // the last, with or without ⇧.
            return single(rows[direction == .down ? 0 : last])
        }
        let step = direction == .down ? 1 : -1
        guard extending else {
            // One row past the selection's edge, alone. A single row's edges
            // are the row itself.
            let edge = direction == .down ? span.upperBound : span.lowerBound
            return single(rows[clamped(edge + step, last)])
        }
        let anchor: Int
        let active: Int
        let kept: Set<ID>
        if let stored = cursor.anchor.flatMap({ rows.firstIndex(of: $0) }) {
            anchor = stored
            active = cursor.active.flatMap { rows.firstIndex(of: $0) } ?? farEnd(of: span, from: stored)
            kept = cursor.kept.intersection(selection)
        } else {
            // The anchor is gone: what is still selected on screen stands in
            // for the range, anchored at its far end from the active row — or,
            // with no active row on screen, at the end this move leaves behind.
            if let shown = cursor.active.flatMap({ rows.firstIndex(of: $0) }), span.contains(shown) {
                anchor = farEnd(of: span, from: shown)
                active = shown
            } else {
                anchor = direction == .down ? span.lowerBound : span.upperBound
                active = direction == .down ? span.upperBound : span.lowerBound
            }
            kept = selection.subtracting(rows[span])
        }
        let moved = clamped(active + step, last)
        return Outcome(
            selection: kept.union(rows[min(anchor, moved)...max(anchor, moved)]),
            cursor: Cursor(anchor: rows[anchor], active: rows[moved], kept: kept),
            active: rows[moved]
        )
    }

    /// A click on `row`, which the table shows.
    public static func click<ID: Hashable>(
        _ row: ID,
        _ click: Click,
        rows: [ID],
        selection: Set<ID>,
        cursor: Cursor<ID>
    ) -> Outcome<ID> {
        switch click {
        case .select:
            return single(row)
        case .toggle:
            var toggled = selection
            if toggled.remove(row) == nil { toggled.insert(row) }
            return Outcome(selection: toggled,
                           cursor: Cursor(anchor: row, active: row, kept: toggled.subtracting([row])),
                           active: row)
        case .extend:
            // With nothing selected on screen there is no range to extend,
            // whatever the anchor: the row alone, as ⇧↓ starts afresh.
            guard let clicked = rows.firstIndex(of: row),
                  let span = shownSpan(of: selection, in: rows) else { return single(row) }
            let anchor: Int
            let kept: Set<ID>
            if let stored = cursor.anchor.flatMap({ rows.firstIndex(of: $0) }) {
                anchor = stored
                kept = cursor.kept.intersection(selection)
            } else {
                anchor = farEnd(of: span, from: clicked)
                kept = selection.subtracting(rows[span])
            }
            return Outcome(
                selection: kept.union(rows[min(anchor, clicked)...max(anchor, clicked)]),
                cursor: Cursor(anchor: rows[anchor], active: row, kept: kept),
                active: row
            )
        }
    }

    /// The row the detail pane shows for a selection: the active row while it
    /// is selected; nil otherwise (a ⌘-click took it out, Esc cleared it), and
    /// the caller falls back to a selected row of its choosing.
    public static func activeRow<ID: Hashable>(selection: Set<ID>, cursor: Cursor<ID>) -> ID? {
        guard let active = cursor.active, selection.contains(active) else { return nil }
        return active
    }

    // MARK: - Helpers

    private static func single<ID: Hashable>(_ row: ID) -> Outcome<ID> {
        Outcome(selection: [row], cursor: Cursor(anchor: row, active: row), active: row)
    }

    /// From the top-most to the bottom-most selected row the table shows.
    private static func shownSpan<ID: Hashable>(of selection: Set<ID>, in rows: [ID]) -> ClosedRange<Int>? {
        guard !selection.isEmpty,
              let top = rows.firstIndex(where: { selection.contains($0) }),
              let bottom = rows.lastIndex(where: { selection.contains($0) }) else { return nil }
        return top...bottom
    }

    /// The end of `span` farther from `index`; the top one when both are as far.
    private static func farEnd(of span: ClosedRange<Int>, from index: Int) -> Int {
        index - span.lowerBound >= span.upperBound - index ? span.lowerBound : span.upperBound
    }

    private static func clamped(_ index: Int, _ last: Int) -> Int {
        min(max(index, 0), last)
    }
}
