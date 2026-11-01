//
//  TrafficTableKeysTests.swift
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
//  F14: the traffic table's Esc and Delete act in one place only. The named
//  cases are the situations the app-wide monitor got wrong since 1.0.4, and
//  the two the first F14 fix got wrong in turn (a body being read lost Esc;
//  an empty table's keys, and a held Delete's repeats, beeped). ↑ and ↓
//  (2026-10-01) act where Delete does, with or without a selection. The
//  sweeps hold the whole truth tables: every window / sheet / modal /
//  modifier / responder / selection combination for the command, and every
//  combination of AppKit facts for where the keyboard is.
//

import XCTest
@testable import Utils

final class TrafficTableKeysTests: XCTestCase {
    private typealias Keys = TrafficTableKeys

    /// The table's own situation — its window, nothing over it, the keyboard
    /// on the window (a row was just clicked), rows selected — with one thing
    /// changed at a time.
    private func command(
        _ keyCode: UInt16,
        modifiers: Keys.Modifiers = [],
        isTrafficWindow: Bool = true,
        hasAttachedSheet: Bool = false,
        modalRunning: Bool = false,
        responder: Keys.Responder = .window,
        hasSelection: Bool = true
    ) -> Keys.Command? {
        Keys.command(keyCode: keyCode, modifiers: modifiers, isTrafficWindow: isTrafficWindow,
                     hasAttachedSheet: hasAttachedSheet, modalRunning: modalRunning,
                     responder: responder, hasSelection: hasSelection)
    }

    private let esc = TrafficTableKeys.Key.escape
    private let delete = TrafficTableKeys.Key.delete
    private let forwardDelete = TrafficTableKeys.Key.forwardDelete
    private let up = TrafficTableKeys.Key.upArrow
    private let down = TrafficTableKeys.Key.downArrow
    private var tableKeys: [UInt16] { [esc, delete, forwardDelete] }
    private var arrows: [UInt16] { [up, down] }
    /// What AppKit puts on every arrow key event.
    private let arrowFlags: Keys.Modifiers = [.function, .numericPad]

    // MARK: - The table's own keys

    /// A row clicked (the keyboard is the window's), rows selected: Esc
    /// deselects, both delete keys delete.
    func testTheTableAtRestTakesEscAndBothDeleteKeys() {
        XCTAssertEqual(command(esc), .clearSelection)
        XCTAssertEqual(command(delete), .deleteSelection)
        XCTAssertEqual(command(forwardDelete), .deleteSelection)
    }

    /// The traffic pane itself (a detail-pane control under Full Keyboard
    /// Access) is the table's too.
    func testAViewInTheTrafficPaneIsTheTables() {
        XCTAssertEqual(command(esc, responder: .trafficPane), .clearSelection)
        XCTAssertEqual(command(delete, responder: .trafficPane), .deleteSelection)
        XCTAssertEqual(command(forwardDelete, responder: .trafficPane), .deleteSelection)
    }

    /// Nothing selected: nothing to act on, but the key is still the table's
    /// — kept, as it has been since 1.0.4, so AppKit does not beep at it. The
    /// same holds for a held Delete's auto-repeats once its first press has
    /// deleted the selection.
    func testWithNothingSelectedTheTablesKeysAreKeptAndDoNothing() {
        for key in tableKeys {
            XCTAssertEqual(command(key, hasSelection: false), .nothingToDo)
            XCTAssertEqual(command(key, responder: .trafficPane, hasSelection: false), .nothingToDo)
        }
        XCTAssertEqual(command(esc, responder: .readingText, hasSelection: false), .nothingToDo)
    }

    /// …and only where it is the table's. With nothing selected here, every
    /// other window, sheet, alert, list, text and shortcut still gets its key
    /// — Saved Sessions' own Delete asks before it deletes a saved session.
    /// (With nothing selected the 1.0.4 monitor still swallowed them all.)
    func testWithNothingSelectedEveryoneElsesKeysStillPassThrough() {
        for key in tableKeys {
            XCTAssertNil(command(key, isTrafficWindow: false, hasSelection: false))
            XCTAssertNil(command(key, hasAttachedSheet: true, hasSelection: false))
            XCTAssertNil(command(key, modalRunning: true, hasSelection: false))
            XCTAssertNil(command(key, modifiers: .command, hasSelection: false))
            for responder in [Keys.Responder.text, .webView, .list, .otherPane, .other] {
                XCTAssertNil(command(key, responder: responder, hasSelection: false), "\(key) with \(responder) focused")
            }
        }
        XCTAssertNil(command(delete, responder: .readingText, hasSelection: false))
        XCTAssertNil(command(forwardDelete, responder: .readingText, hasSelection: false))
    }

    // MARK: - Other windows (the F14 report's cases)

    /// Saved Sessions' list focused: its own Delete asks before it deletes a
    /// saved session. The traffic selection must not go instead.
    func testAnotherWindowsKeysAreNeverTheTables() {
        // Saved Sessions and Destinations (a list), Help and Settings (the
        // window), the Paused Requests panel (a field, or the panel) — every
        // responder, since the key did not go to the table's window at all.
        for responder in Keys.Responder.allCases {
            for key in tableKeys {
                for selected in [true, false] {
                    XCTAssertNil(command(key, isTrafficWindow: false, responder: responder, hasSelection: selected),
                                 "\(key) to another window with \(responder) focused, selection \(selected)")
                }
            }
        }
    }

    /// A second main window (File ▸ New Window) is "another window" to the
    /// first one's table: each monitor acts only for its own window — and an
    /// empty table never keeps the other window's keys.
    func testASecondMainWindowsKeysAreItsOwn() {
        XCTAssertNil(command(delete, isTrafficWindow: false))
        XCTAssertNil(command(delete, isTrafficWindow: false, hasSelection: false))
        XCTAssertEqual(command(delete, isTrafficWindow: true), .deleteSelection)
    }

    /// A sheet on the table's window — New Host, an override form, the
    /// paywall, a SwiftUI alert: Esc is the sheet's Cancel, and Delete is the
    /// sheet's, even if the key were routed to the window under it.
    func testASheetOnTheTablesWindowTakesEveryKey() {
        for responder in Keys.Responder.allCases {
            for key in tableKeys {
                for selected in [true, false] {
                    XCTAssertNil(command(key, hasAttachedSheet: true, responder: responder, hasSelection: selected))
                }
            }
        }
    }

    /// An app-modal alert — Clear Traffic, Delete Override, Delete Host
    /// Filter, Quit: Esc is its Cancel.
    func testAModalAlertTakesEveryKey() {
        for responder in Keys.Responder.allCases {
            for key in tableKeys {
                for selected in [true, false] {
                    XCTAssertNil(command(key, modalRunning: true, responder: responder, hasSelection: selected))
                }
            }
        }
    }

    // MARK: - The table's window, the keyboard elsewhere

    /// Text being edited — the toolbar search field's editor: Esc must reach
    /// the field's own Escape (hide the suggestions, clear, give up focus),
    /// and Delete edits the text. The old monitor answered Esc here by
    /// taking focus away, and the field took it straight back, so Escape
    /// never cleared the search.
    func testTextBeingEditedKeepsItsKeys() {
        for key in tableKeys {
            for selected in [true, false] {
                XCTAssertNil(command(key, responder: .text, hasSelection: selected))
            }
        }
    }

    /// A body being read — the detail pane's request or response text,
    /// selectable, not editable — has no use for Esc: it closes the detail,
    /// as it did from 1.0.4 until the first F14 fix handed it to the text,
    /// where it only beeped. Delete stays with the text: it used to delete
    /// the row being read.
    func testATextBeingReadGivesEscToTheTableAndKeepsDelete() {
        XCTAssertEqual(command(esc, responder: .readingText), .clearSelection)
        XCTAssertNil(command(delete, responder: .readingText))
        XCTAssertNil(command(forwardDelete, responder: .readingText))
    }

    /// A web view: the page's keys.
    func testAWebViewKeepsItsKeys() {
        for key in tableKeys {
            for selected in [true, false] {
                XCTAssertNil(command(key, responder: .webView, hasSelection: selected))
            }
        }
    }

    /// The host sidebar and the overrides list share the window with the
    /// table (scoping to the WINDOW is not enough), and a WebSocket message
    /// list in the detail pane has a selection of its own.
    func testTheSidebarTheOverridesAndOtherListsKeepTheirKeys() {
        for responder in [Keys.Responder.list, .otherPane, .other] {
            for key in tableKeys {
                for selected in [true, false] {
                    XCTAssertNil(command(key, responder: responder, hasSelection: selected), "\(key) with \(responder) focused")
                }
            }
        }
    }

    /// Delete is the table's only where the table itself has the keyboard;
    /// Esc also where a body is being read.
    func testWhereEachKeyIsTheTables() {
        XCTAssertEqual(Set(Keys.Responder.allCases.filter(\.takesDelete)), [.window, .trafficPane])
        XCTAssertEqual(Set(Keys.Responder.allCases.filter(\.takesArrows)), [.window, .trafficPane])
        XCTAssertEqual(Set(Keys.Responder.allCases.filter(\.takesEscape)), [.window, .trafficPane, .readingText])
    }

    // MARK: - Modifiers

    /// ⌘⌫, ⌥⌫ and ⌃⌫ are shortcuts (Edit ▸ Delete elsewhere, delete a word),
    /// and ⌘Esc is not Esc — whether or not anything is selected.
    func testCommandOptionAndControlMakeAKeySomeoneElses() {
        for modifier in [Keys.Modifiers.command, .option, .control] {
            for key in tableKeys {
                for selected in [true, false] {
                    XCTAssertNil(command(key, modifiers: modifier, hasSelection: selected), "\(key) with \(modifier)")
                    XCTAssertNil(command(key, modifiers: [modifier, .shift], hasSelection: selected))
                }
            }
        }
    }

    /// fn-Delete on a laptop IS forward delete, and AppKit flags every
    /// function key — the flag must never block it. Shift and Caps Lock do
    /// not change what the key means.
    func testShiftFunctionAndCapsLockDoNotBlock() {
        XCTAssertEqual(command(forwardDelete, modifiers: .function), .deleteSelection)
        XCTAssertEqual(command(delete, modifiers: .shift), .deleteSelection)
        XCTAssertEqual(command(esc, modifiers: .capsLock), .clearSelection)
        XCTAssertEqual(command(forwardDelete, modifiers: [.function, .shift, .capsLock]), .deleteSelection)
        XCTAssertEqual(command(forwardDelete, modifiers: .function, hasSelection: false), .nothingToDo)
    }

    // MARK: - ↑ and ↓

    /// Where the table has the keyboard — a row was clicked, or the traffic
    /// pane holds it — ↑ and ↓ move the selection.
    func testTheArrowsMoveTheSelectionWhereTheTableHasTheKeyboard() {
        for responder in [Keys.Responder.window, .trafficPane] {
            XCTAssertEqual(command(up, modifiers: arrowFlags, responder: responder), .moveSelection(.up, extending: false))
            XCTAssertEqual(command(down, modifiers: arrowFlags, responder: responder), .moveSelection(.down, extending: false))
        }
    }

    /// Unlike Esc and Delete, the arrows act with nothing selected: ↓ then
    /// selects the first row and ↑ the last (`TrafficTableNavigation`).
    func testTheArrowsMoveWithNothingSelected() {
        XCTAssertEqual(command(down, modifiers: arrowFlags, hasSelection: false), .moveSelection(.down, extending: false))
        XCTAssertEqual(command(up, modifiers: arrowFlags, responder: .trafficPane, hasSelection: false),
                       .moveSelection(.up, extending: false))
    }

    /// ⇧ extends or shrinks the range; the flags AppKit sets on every arrow
    /// (function, numeric pad) and Caps Lock never block.
    func testShiftExtendsAndTheArrowFlagsNeverBlock() {
        XCTAssertEqual(command(down, modifiers: arrowFlags.union(.shift)), .moveSelection(.down, extending: true))
        XCTAssertEqual(command(up, modifiers: arrowFlags.union([.shift, .capsLock]), hasSelection: false), .moveSelection(.up, extending: true))
        for flags: Keys.Modifiers in [[], .function, .numericPad, .capsLock, [.function, .numericPad, .capsLock]] {
            XCTAssertEqual(command(down, modifiers: flags), .moveSelection(.down, extending: false), "flags \(flags.rawValue)")
        }
    }

    /// ⌘↑, ⌥↓, ⌃↓ and the rest are someone else's, ⇧ or not.
    func testCommandOptionAndControlArrowsPassThrough() {
        for modifier in [Keys.Modifiers.command, .option, .control] {
            for key in arrows {
                for selected in [true, false] {
                    XCTAssertNil(command(key, modifiers: arrowFlags.union(modifier), hasSelection: selected))
                    XCTAssertNil(command(key, modifiers: arrowFlags.union([modifier, .shift]), hasSelection: selected))
                }
            }
        }
    }

    /// A text — being read or edited — moves its caret with the arrows (the
    /// search field's ↓ walks its suggestions); a list moves its own
    /// selection; a web view keeps its page's keys; another pane or anything
    /// else keeps them too. Esc reaches the table from a body being read;
    /// the arrows do not.
    func testTheArrowsBelongToTextsListsWebViewsAndOtherPanes() {
        for responder in [Keys.Responder.readingText, .text, .webView, .list, .otherPane, .other] {
            for key in arrows {
                for selected in [true, false] {
                    XCTAssertNil(command(key, modifiers: arrowFlags, responder: responder, hasSelection: selected),
                                 "\(key) with \(responder) focused")
                }
            }
        }
    }

    /// Another window, a sheet on the table's window, a modal alert: never
    /// the table's arrows.
    func testTheArrowsOfOtherWindowsSheetsAndAlertsPassThrough() {
        for responder in Keys.Responder.allCases {
            for key in arrows {
                for selected in [true, false] {
                    XCTAssertNil(command(key, modifiers: arrowFlags, isTrafficWindow: false, responder: responder, hasSelection: selected))
                    XCTAssertNil(command(key, modifiers: arrowFlags, hasAttachedSheet: true, responder: responder, hasSelection: selected))
                    XCTAssertNil(command(key, modifiers: arrowFlags, modalRunning: true, responder: responder, hasSelection: selected))
                }
            }
        }
    }

    /// The releases the table listens for: ↑ and ↓ only — not ← and →, not
    /// Esc or Delete, no other key — so the detail pane learns when a held
    /// arrow is let go of (`TrafficDetailDebounce.keyReleased`).
    func testOnlyUpAndDownAreArrows() {
        XCTAssertTrue(Keys.isArrow(up))
        XCTAssertTrue(Keys.isArrow(down))
        XCTAssertEqual((0..<UInt16(256)).filter(Keys.isArrow), [0x7D, 0x7E])
    }

    // MARK: - Other keys

    func testNoOtherKeyIsTheTables() {
        // Return, Tab, Space, a letter, ← and →, keypad Clear, Home, End,
        // Page Up, Page Down.
        for key: UInt16 in [0x24, 0x30, 0x31, 0x00, 0x7B, 0x7C, 0x47, 0x73, 0x77, 0x74, 0x79] {
            for responder in Keys.Responder.allCases {
                for selected in [true, false] {
                    XCTAssertNil(command(key, responder: responder, hasSelection: selected))
                }
            }
        }
    }

    /// Virtual key codes, whatever the keyboard layout.
    func testTheKeyCodesAreTheHardwareOnes() {
        XCTAssertEqual(TrafficTableKeys.Key.escape, 53)
        XCTAssertEqual(TrafficTableKeys.Key.delete, 51)
        XCTAssertEqual(TrafficTableKeys.Key.forwardDelete, 117)
        XCTAssertEqual(TrafficTableKeys.Key.downArrow, 125)
        XCTAssertEqual(TrafficTableKeys.Key.upArrow, 126)
    }

    // MARK: - The whole truth table

    /// Every combination, against the rule stated once: a key can be the
    /// table's only in its own window, with no sheet or modal alert and no
    /// ⌘⌥⌃; Esc then where the keyboard is the window's, the traffic pane's
    /// or a body being read, Delete, forward delete, ↑ and ↓ where it is the
    /// window's or the traffic pane's. With rows selected Esc and Delete act;
    /// with none they keep the key and do nothing. The arrows move either
    /// way, extending with ⇧. Every other combination passes the key through.
    func testEveryCombination() {
        let keys: [UInt16] = [esc, delete, forwardDelete, up, down, 0x24, 0x31, 0x00]
        let flags: [Keys.Modifiers] = [.command, .option, .control, .shift, .function, .capsLock, .numericPad]
        var combinations = 0
        var cleared = 0
        var deleted = 0
        var kept = 0
        var moved = 0
        var extended = 0
        for key in keys {
            for mask in 0..<(1 << flags.count) {
                let modifiers = flags.enumerated().reduce(into: Keys.Modifiers()) { set, flag in
                    if mask & (1 << flag.offset) != 0 { set.insert(flag.element) }
                }
                for isTrafficWindow in [true, false] {
                    for hasAttachedSheet in [true, false] {
                        for modalRunning in [true, false] {
                            for responder in Keys.Responder.allCases {
                                for hasSelection in [true, false] {
                                    combinations += 1
                                    let result = command(key, modifiers: modifiers, isTrafficWindow: isTrafficWindow,
                                                         hasAttachedSheet: hasAttachedSheet, modalRunning: modalRunning,
                                                         responder: responder, hasSelection: hasSelection)
                                    let tableCanHaveIt = isTrafficWindow && !hasAttachedSheet && !modalRunning
                                        && !modifiers.contains(.command) && !modifiers.contains(.option)
                                        && !modifiers.contains(.control)
                                    let escapeIsTables = tableCanHaveIt && key == esc
                                        && [.window, .trafficPane, .readingText].contains(responder)
                                    let deleteIsTables = tableCanHaveIt && (key == delete || key == forwardDelete)
                                        && [.window, .trafficPane].contains(responder)
                                    let arrowIsTables = tableCanHaveIt && (key == up || key == down)
                                        && [.window, .trafficPane].contains(responder)
                                    let expected: Keys.Command?
                                    if escapeIsTables {
                                        expected = hasSelection ? .clearSelection : .nothingToDo
                                    } else if deleteIsTables {
                                        expected = hasSelection ? .deleteSelection : .nothingToDo
                                    } else if arrowIsTables {
                                        expected = .moveSelection(key == up ? .up : .down, extending: modifiers.contains(.shift))
                                    } else {
                                        expected = nil
                                    }
                                    switch result {
                                    case .clearSelection?: cleared += 1
                                    case .deleteSelection?: deleted += 1
                                    case .nothingToDo?: kept += 1
                                    case .moveSelection(_, let extending)?:
                                        moved += 1
                                        if extending { extended += 1 }
                                    case nil: break
                                    }
                                    XCTAssertEqual(result, expected,
                                                   "key \(key) modifiers \(modifiers.rawValue) window \(isTrafficWindow) sheet \(hasAttachedSheet) modal \(modalRunning) responder \(responder) selection \(hasSelection)")
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(combinations, 8 * 128 * 2 * 2 * 2 * 8 * 2)
        // Out of 131,072 combinations, over the 16 shift / fn / Caps Lock /
        // numeric pad mixes: Esc clears in 3 places, each delete key deletes
        // in 2, and the same places keep the key when nothing is selected;
        // each arrow moves in 2 places, selection or not, half of them with ⇧.
        XCTAssertEqual(cleared, 16 * 3)
        XCTAssertEqual(deleted, 16 * 2 * 2)
        XCTAssertEqual(kept, 16 * 3 + 16 * 2 * 2)
        XCTAssertEqual(moved, 16 * 2 * 2 * 2)
        XCTAssertEqual(extended, moved / 2)
    }
}

/// Where the keyboard is: the ORDER the AppKit facts are read in
/// (`TrafficTableKeys.responder`). A mistake here fails silently in the app —
/// a list read as the traffic pane deletes traffic rows with the Delete meant
/// for the list, which is how the key monitor went wrong from 1.0.4 — so the
/// order lives in Utils, tested, and TrafficTableKeyEvents only asks AppKit.
final class TrafficTableKeysResponderTests: XCTestCase {
    private typealias Keys = TrafficTableKeys

    /// A plain view in the traffic pane, with one fact changed at a time.
    private func responder(
        isWindow: Bool = false,
        isText: Bool = false,
        isEditable: Bool = false,
        isView: Bool = true,
        isInWebView: Bool = false,
        isList: Bool = false,
        isInTrafficPane: Bool = true,
        isInWindow: Bool = true
    ) -> Keys.Responder {
        Keys.responder(isWindow: isWindow, isText: isText, isEditable: isEditable, isView: isView,
                       isInWebView: isInWebView, isList: isList, isInTrafficPane: isInTrafficPane,
                       isInWindow: isInWindow)
    }

    func testAViewInTheTrafficPaneIsTheTrafficPane() {
        XCTAssertEqual(responder(), .trafficPane)
    }

    /// The window, or its root content view, whatever else is true of it.
    func testTheWindowAndItsRootViewAreTheWindow() {
        XCTAssertEqual(responder(isWindow: true), .window)
        XCTAssertEqual(responder(isWindow: true, isList: true, isInTrafficPane: false), .window)
    }

    /// Text first: a field being edited in a list row, a page or any pane is
    /// text, so Delete edits it.
    func testTextBeingEditedComesBeforeEverythingButTheWindow() {
        XCTAssertEqual(responder(isText: true, isEditable: true), .text)
        XCTAssertEqual(responder(isText: true, isEditable: true, isList: true), .text)
        XCTAssertEqual(responder(isText: true, isEditable: true, isInWebView: true), .text)
        XCTAssertEqual(responder(isText: true, isEditable: true, isInTrafficPane: false), .text)
    }

    /// Text that cannot be edited is being read. In the traffic pane (a
    /// body, a selectable label in a message row) it gives Esc to the table;
    /// anywhere else it is another pane's text.
    func testTextBeingReadIsReadingTextOnlyInTheTrafficPane() {
        XCTAssertEqual(responder(isText: true), .readingText)
        XCTAssertEqual(responder(isText: true, isList: true), .readingText)
        XCTAssertEqual(responder(isText: true, isInTrafficPane: false), .text)
        XCTAssertEqual(responder(isText: true, isInTrafficPane: false, isInWindow: false), .text)
    }

    func testAResponderThatIsNotAViewIsOther() {
        XCTAssertEqual(responder(isView: false), .other)
        XCTAssertEqual(responder(isView: false, isList: true), .other)
    }

    /// A web view comes before the list and the traffic pane: a page shown in
    /// the detail pane keeps its keys.
    func testAWebViewComesBeforeTheListAndTheTrafficPane() {
        XCTAssertEqual(responder(isInWebView: true), .webView)
        XCTAssertEqual(responder(isInWebView: true, isList: true), .webView)
    }

    /// A list comes before the traffic pane: the WebSocket message list in
    /// the detail pane keeps its own keys, as the sidebar does.
    func testAListInTheTrafficPaneIsAList() {
        XCTAssertEqual(responder(isList: true), .list)
        XCTAssertEqual(responder(isList: true, isInTrafficPane: false), .list)
    }

    func testAViewElsewhereIsAnotherPaneOrOther() {
        XCTAssertEqual(responder(isInTrafficPane: false), .otherPane)
        XCTAssertEqual(responder(isInTrafficPane: false, isInWindow: false), .other)
    }

    /// All 256 combinations of the eight facts, against the order stated once.
    func testEveryCombination() {
        var counts: [Keys.Responder: Int] = [:]
        for mask in 0..<(1 << 8) {
            let fact = { (bit: Int) in mask & (1 << bit) != 0 }
            let (isWindow, isText, isEditable, isView) = (fact(0), fact(1), fact(2), fact(3))
            let (isInWebView, isList, isInTrafficPane, isInWindow) = (fact(4), fact(5), fact(6), fact(7))
            let expected: Keys.Responder
            if isWindow {
                expected = .window
            } else if isText {
                expected = !isEditable && isInTrafficPane ? .readingText : .text
            } else if !isView {
                expected = .other
            } else if isInWebView {
                expected = .webView
            } else if isList {
                expected = .list
            } else if isInTrafficPane {
                expected = .trafficPane
            } else {
                expected = isInWindow ? .otherPane : .other
            }
            let result = Keys.responder(isWindow: isWindow, isText: isText, isEditable: isEditable, isView: isView,
                                        isInWebView: isInWebView, isList: isList, isInTrafficPane: isInTrafficPane,
                                        isInWindow: isInWindow)
            XCTAssertEqual(result, expected, "facts \(String(mask, radix: 2))")
            counts[result, default: 0] += 1
        }
        // Each step takes what the steps before it left: the window half of
        // everything, text half of the rest, and so on down to the 2 views
        // elsewhere in the window.
        XCTAssertEqual(counts, [.window: 128, .text: 48, .readingText: 16, .other: 34,
                                .webView: 16, .list: 8, .trafficPane: 4, .otherPane: 2])
    }
}

/// F14: the context menu's Delete acted on the whole selection even when the
/// row right-clicked was outside it, while Save beside it acted on that row.
final class TrafficRowTargetsTests: XCTestCase {
    private struct Row: Equatable {
        let id: Int
    }

    private let table = (1...6).map(Row.init)

    private func rows(clicked: Int, selection: Set<Int>, shown: [Row]? = nil) -> [Int] {
        TrafficRowTargets.rows(clicked: Row(id: clicked), selection: selection, shown: shown ?? table, id: \.id).map(\.id)
    }

    func testARowOutsideTheSelectionIsActedOnAlone() {
        XCTAssertEqual(rows(clicked: 5, selection: [1, 2, 3]), [5])
    }

    func testWithNothingSelectedTheClickedRowIsTheTarget() {
        XCTAssertEqual(rows(clicked: 4, selection: []), [4])
    }

    func testARowInsideTheSelectionTakesTheSelectionInTableOrder() {
        // The set's order is not the table's; the result is.
        XCTAssertEqual(rows(clicked: 3, selection: [6, 3, 1]), [1, 3, 6])
    }

    func testTheOnlySelectedRowIsJustItself() {
        XCTAssertEqual(rows(clicked: 2, selection: [2]), [2])
    }

    /// A selection can outlive a host or search change; rows it holds that
    /// the table no longer shows are never acted on, so the item's count is
    /// what the person can see.
    func testSelectedRowsTheTableDoesNotShowAreLeftAlone() {
        let shown = table.filter { $0.id % 2 == 0 } // 2, 4, 6
        XCTAssertEqual(rows(clicked: 4, selection: [1, 3, 4, 6], shown: shown), [4, 6])
    }

    /// Every selected row left the table between the menu opening and the
    /// click: the clicked row is still the one meant.
    func testTheClickedRowSurvivesATableThatEmptiedUnderTheMenu() {
        XCTAssertEqual(rows(clicked: 3, selection: [3, 4], shown: []), [3])
    }

    func testTheTitlesCountTheRowsTheyActOn() {
        XCTAssertEqual(TrafficRowTargets.saveTitle(count: 1), "Save session")
        XCTAssertEqual(TrafficRowTargets.saveTitle(count: 4), "Save 4 sessions")
        XCTAssertEqual(TrafficRowTargets.deleteTitle(count: 1), "Delete session")
        XCTAssertEqual(TrafficRowTargets.deleteTitle(count: 3), "Delete 3 sessions")
    }

    /// It deletes at once: an ellipsis would promise a dialog that does not
    /// exist (the old label said "Delete sessions...").
    func testTheDeleteTitleHasNoEllipsis() {
        for count in 1...3 {
            let title = TrafficRowTargets.deleteTitle(count: count)
            XCTAssertFalse(title.contains("…") || title.contains("..."), title)
        }
    }
}
