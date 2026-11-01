//
//  TrafficRowTargets.swift
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

import Foundation

/// Which rows a traffic row's context menu acts on, and what its items say.
///
/// ONE rule for every item (F14): the right-clicked row, unless it is part of
/// the selection — then every selected row the table shows. "Delete
/// session(s)…" used to delete the whole selection even when the row
/// right-clicked was outside it, while Save beside it acted on that row: the
/// row under the pointer is the one a person means.
public enum TrafficRowTargets {
    /// The rows a context-menu item acts on, in table order.
    ///
    /// - Parameters:
    ///   - clicked: the row right-clicked.
    ///   - selection: the selected rows' ids. It can hold rows the current
    ///     host or search hides; those are never acted on — only rows the
    ///     table shows, so the item's count is what the person can see.
    ///   - shown: the rows the table shows, in its order.
    public static func rows<Row, ID: Hashable>(
        clicked: Row,
        selection: Set<ID>,
        shown: [Row],
        id: (Row) -> ID
    ) -> [Row] {
        guard selection.contains(id(clicked)) else { return [clicked] }
        let selected = shown.filter { selection.contains(id($0)) }
        // Every selected row left the table between the menu opening and the
        // click (the retention cap, a clear): the clicked row is still the
        // one that was meant.
        return selected.isEmpty ? [clicked] : selected
    }

    /// "Save session", or "Save 4 sessions" when a selection is in play — a
    /// menu item that silently acts on more rows than the one clicked is how
    /// people lose work they did not know they had selected.
    public static func saveTitle(count: Int) -> String {
        count > 1 ? "Save \(count) sessions" : "Save session"
    }

    /// No ellipsis: the item deletes at once. An ellipsis promises a dialog,
    /// and there is none (the traffic list's Delete key asks nothing either).
    public static func deleteTitle(count: Int) -> String {
        count > 1 ? "Delete \(count) sessions" : "Delete session"
    }
}
