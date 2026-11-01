//
//  TrafficTableKeys.swift
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
//  What Esc, Delete and the ↑ ↓ arrows do for the traffic table — and, just
//  as much, where they must do nothing (F14, 2026-09-30; the arrows,
//  2026-10-01).
//
//  The table has no AppKit view of its own to take keys (its rows are a
//  LazyVStack), so its keys come from a local key monitor, and a local
//  monitor sees EVERY key of every window of the app. From 1.0.4 until F14 it
//  asked one question — is a text view being edited? — and otherwise took Esc
//  and Delete for itself wherever they were pressed:
//   * Delete in Saved Sessions, Destinations, a sheet, an alert or the Paused
//     Requests panel deleted the traffic list's selected rows, with no prompt
//     and no undo, and Saved Sessions' own confirming Delete never ran;
//   * Esc never reached a sheet's Cancel, an alert's Cancel, the Paused
//     Requests panel or Destinations, and in the toolbar search field it only
//     took focus away, so the field's own Escape (clear it) never ran.
//
//  So the decision starts with WHERE the key went. A key can be the table's
//  only in the window the table is in, with no sheet or modal alert up and no
//  ⌘/⌥/⌃ held. Then it depends on where the keyboard is:
//   * Delete and forward delete: with the window itself (a row was clicked)
//     or the traffic pane — not the sidebar, the overrides list, another
//     list, a text or a web view;
//   * ↑ and ↓ (⇧ extends): there too, and only there — a text, being read or
//     edited, moves its caret with them, and a list (the host sidebar, a
//     WebSocket's messages) its own selection;
//   * Esc: there too, and in a text being read in the traffic pane (a body),
//     which has no use for it — so it closes the detail, as it has since
//     1.0.4, while Delete there never deletes the row being read.
//  A key that is the table's is kept even with no row selected, as it has
//  been since 1.0.4: passed on, it could only end in AppKit's beep. The arrows
//  act with no row selected too — ↓ selects the first row, ↑ the last
//  (`TrafficTableNavigation`). Every other key is let through untouched. An
//  arrow key's RELEASE is heard wherever it went, and always let through: the
//  detail pane waits for a held arrow to be let go of (`isArrow`).
//
//  `SessionView` only maps AppKit state onto these inputs
//  (TrafficTableKeyEvents.swift); the decisions are here so that every
//  combination is tested (Sources/UI has no test target).
//

import Foundation

public enum TrafficTableKeys {
    /// What the table does with a key.
    public enum Command: Equatable, Sendable {
        /// Esc: deselect every row, which closes the detail pane.
        case clearSelection
        /// Delete or forward delete: remove the selected rows.
        case deleteSelection
        /// ↑ or ↓: move the selection one row; with ⇧, extend or shrink the
        /// range from the anchor (`TrafficTableNavigation`). Even with no row
        /// selected: ↓ then selects the first row and ↑ the last.
        case moveSelection(TrafficTableNavigation.Direction, extending: Bool)
        /// The table's key with no row selected — Esc or Delete on a table
        /// with nothing selected, or the auto-repeats of a held Delete whose
        /// first press already deleted the selection. Nothing happens, and
        /// the key is kept: passed on, it would only make AppKit beep.
        case nothingToDo
    }

    /// Where the keyboard is in the table's window — the window's first
    /// responder, as far as the table's keys are concerned.
    public enum Responder: Equatable, Sendable, CaseIterable {
        /// The window itself (or its root content view): nothing in it holds
        /// the keyboard. A click on a traffic row leaves it here — the row's
        /// tap hands the keyboard back to the window, taking it from the
        /// search field — and so does the search field's own last Escape.
        case window
        /// The traffic pane, or a view in it that is none of the kinds below:
        /// a control of the detail pane under Full Keyboard Access.
        case trafficPane
        /// Text being read in the traffic pane — a request or response body,
        /// its headers, a live row's text: selectable, not editable. It has
        /// no use for Esc, which closes the detail here as it has since
        /// 1.0.4. Delete stays with it — a row is never deleted while it is
        /// being read — and so do the arrows, which move its caret.
        case readingText
        /// Text being edited — the toolbar search field, a WebSocket's
        /// "Search messages" — or any text outside the traffic pane. Delete,
        /// Esc and the arrows belong to the text: the search field's Escape
        /// clears it, its ↓ walks its suggestions.
        case text
        /// A web view: the page's keys. The main window has none today; one
        /// added later keeps its page's keys.
        case webView
        /// A list or table — the host sidebar, the overrides list, a WebSocket
        /// message list. Its keys are its own: the sidebar and the message
        /// list move their selection with the arrows.
        case list
        /// A view elsewhere in the window: the host sidebar, the overrides
        /// pane, a toolbar control.
        case otherPane
        /// Anything this cannot place. Treated as someone else's.
        case other

        /// Where Delete and forward delete mean the traffic table.
        public var takesDelete: Bool { self == .window || self == .trafficPane }
        /// Where ↑ and ↓ mean the traffic table: exactly where Delete does.
        /// Not in a text being read — they move its caret, and scroll it —
        /// nor in a list, whose keys are its own.
        public var takesArrows: Bool { takesDelete }
        /// Where Esc means the traffic table: wherever Delete does, and in a
        /// text being read in the traffic pane.
        public var takesEscape: Bool { takesDelete || self == .readingText }
    }

    /// The modifier keys held with the key. Only ⌘, ⌥ and ⌃ make a key
    /// someone else's (⌘⌫ is Edit ▸ Delete's own shortcut in many apps, ⌥⌫
    /// deletes a word; ⌘↑ goes to the top of a document, ⌥↓ to the end of a
    /// paragraph, ⌃↓ a page down — AppKit's StandardKeyBinding.dict — and,
    /// with Mission Control's shortcut on, ⌃↓ shows the app's windows) — so
    /// they are left alone.
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
        /// AppKit sets it on every function key, forward delete included —
        /// which is how fn-Delete arrives on a laptop — and on the arrows, so
        /// it never blocks.
        public static let function = Modifiers(rawValue: 1 << 4)
        public static let capsLock = Modifiers(rawValue: 1 << 5)
        /// AppKit sets it on every arrow key, whatever the keyboard: it never
        /// blocks.
        public static let numericPad = Modifiers(rawValue: 1 << 6)

        /// The ones that make a key a shortcut rather than the key itself.
        public static let shortcut: Modifiers = [.command, .option, .control]
    }

    /// Virtual key codes (Carbon's `kVK_*`), which is what `NSEvent.keyCode`
    /// carries whatever the keyboard layout.
    public enum Key {
        public static let escape: UInt16 = 0x35
        /// The key marked Delete (⌫).
        public static let delete: UInt16 = 0x33
        /// Forward delete (⌦): the Del key, or fn-Delete on a laptop.
        public static let forwardDelete: UInt16 = 0x75
        public static let downArrow: UInt16 = 0x7D
        public static let upArrow: UInt16 = 0x7E
    }

    /// Whether a key is ↑ or ↓ — asked of every key RELEASE the app gets,
    /// wherever it went: the detail pane does not show the row a held arrow
    /// is passing until the key is let go of
    /// (`TrafficDetailDebounce.keyReleased`). A release is never kept.
    public static func isArrow(_ keyCode: UInt16) -> Bool {
        keyCode == Key.upArrow || keyCode == Key.downArrow
    }

    /// The table's command for a key, or nil to let the key through untouched.
    ///
    /// - Parameters:
    ///   - isTrafficWindow: the key went to the window the table is in. Every
    ///     other window — Saved Sessions, Destinations, Help, Settings, the
    ///     Paused Requests panel, a second main window — has keys of its own,
    ///     whether or not this table has rows selected.
    ///   - hasAttachedSheet: the table's window has a sheet up (New Host, an
    ///     override form, the paywall, a SwiftUI alert): the keys are the
    ///     sheet's, whatever window they were routed to.
    ///   - modalRunning: an app-modal alert is running (Clear Traffic, Delete
    ///     Override, Delete Host Filter, Quit).
    ///   - responder: where the keyboard is in the table's window.
    ///   - hasSelection: at least one row is selected. With none, Esc or
    ///     Delete where they are the table's is kept and does nothing
    ///     (`nothingToDo`); an arrow still moves (`moveSelection`).
    public static func command(
        keyCode: UInt16,
        modifiers: Modifiers,
        isTrafficWindow: Bool,
        hasAttachedSheet: Bool,
        modalRunning: Bool,
        responder: Responder,
        hasSelection: Bool
    ) -> Command? {
        guard isTrafficWindow, !hasAttachedSheet, !modalRunning else { return nil }
        guard modifiers.isDisjoint(with: .shortcut) else { return nil }
        switch keyCode {
        case Key.escape:
            guard responder.takesEscape else { return nil }
            return hasSelection ? .clearSelection : .nothingToDo
        case Key.delete, Key.forwardDelete:
            guard responder.takesDelete else { return nil }
            return hasSelection ? .deleteSelection : .nothingToDo
        case Key.upArrow, Key.downArrow:
            guard responder.takesArrows else { return nil }
            return .moveSelection(keyCode == Key.upArrow ? .up : .down, extending: modifiers.contains(.shift))
        default:
            return nil
        }
    }

    /// Where the keyboard is, from what AppKit says about the window's first
    /// responder. Each argument answers ONE question TrafficTableKeyEvents
    /// asks of it; the order the answers are read in is the rule, so it is
    /// here, where every combination is tested:
    ///  1. the window itself, or its root content view: `.window`;
    ///  2. text — before anything else, so a field being edited in a list
    ///     row, a pane or a page is text: `.readingText` when it cannot be
    ///     edited and sits in the traffic pane, `.text` otherwise;
    ///  3. a responder that is not a view at all: `.other`;
    ///  4. in a web view: `.webView`;
    ///  5. a list — even one in the traffic pane, a WebSocket message list:
    ///     `.list`;
    ///  6. in the traffic pane: `.trafficPane`;
    ///  7. elsewhere in the table's window: `.otherPane`; anything else:
    ///     `.other`.
    ///
    /// - Parameters:
    ///   - isWindow: it is the window, or the window's root content view.
    ///   - isText: it is text — a field editor, a text view, a text field.
    ///   - isEditable: that text can be edited.
    ///   - isView: it is a view.
    ///   - isInWebView: it is, or sits in, a web view.
    ///   - isList: it is a table or collection view.
    ///   - isInTrafficPane: it sits in the traffic pane.
    ///   - isInWindow: it sits in the table's window.
    public static func responder(
        isWindow: Bool,
        isText: Bool,
        isEditable: Bool,
        isView: Bool,
        isInWebView: Bool,
        isList: Bool,
        isInTrafficPane: Bool,
        isInWindow: Bool
    ) -> Responder {
        if isWindow { return .window }
        if isText { return !isEditable && isInTrafficPane ? .readingText : .text }
        guard isView else { return .other }
        if isInWebView { return .webView }
        if isList { return .list }
        if isInTrafficPane { return .trafficPane }
        return isInWindow ? .otherPane : .other
    }
}
