//
//  TrafficTableKeyCopyTests.swift
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
//  Help's "Moving through the list with the keyboard": each sentence of
//  TrafficTableKeyCopy is checked against the rule it describes, so a change
//  to the keys that leaves Help behind fails here; and Help is checked to
//  print the copy (Sources/UI has no test target, so that part reads the
//  source).
//

import XCTest
@testable import Utils

final class TrafficTableKeyCopyTests: XCTestCase {
    private typealias Keys = TrafficTableKeys
    private typealias Nav = TrafficTableNavigation
    private typealias Cursor = TrafficTableNavigation.Cursor<String>

    private var text: String { TrafficTableKeyCopy.helpBullets.joined(separator: "\n") }

    /// The bullet that says `phrase`, so a failure names the sentence.
    private func bullet(saying phrase: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(TrafficTableKeyCopy.helpBullets.first { $0.contains(phrase) },
                      "No bullet says “\(phrase)” — reworded? Update this test with the rule it states.",
                      file: file, line: line)
    }

    private let table = ["a", "b", "c", "d", "e"]

    private func move(_ direction: Nav.Direction, shift: Bool = false,
                      selection: Set<String>, cursor: Cursor = Cursor()) -> Nav.Outcome<String>? {
        Nav.move(direction, extending: shift, rows: table, selection: selection, cursor: cursor)
    }

    private func command(_ key: UInt16, _ modifiers: Keys.Modifiers = [], responder: Keys.Responder = .window,
                         sheet: Bool = false, modal: Bool = false, selection: Bool = true) -> Keys.Command? {
        Keys.command(keyCode: key, modifiers: modifiers, isTrafficWindow: true, hasAttachedSheet: sheet,
                     modalRunning: modal, responder: responder, hasSelection: selection)
    }

    private static let arrows = [Keys.Key.upArrow, Keys.Key.downArrow]
    private static let tableKeys = [Keys.Key.upArrow, Keys.Key.downArrow, Keys.Key.escape,
                                    Keys.Key.delete, Keys.Key.forwardDelete]

    // MARK: - The words

    func testTheHeadingAndEverySentenceAreThere() {
        XCTAssertEqual(TrafficTableKeyCopy.heading, "Moving through the list with the keyboard")
        XCTAssertEqual(TrafficTableKeyCopy.helpBullets.count, 6)
        for bullet in TrafficTableKeyCopy.helpBullets {
            XCTAssertTrue(bullet.hasSuffix("."), "a sentence: \(bullet)")
            XCTAssertFalse(bullet.contains("  "), "no double space: \(bullet)")
        }
    }

    /// The numbers are read from the rules, never typed.
    func testTheNumbersComeFromTheRules() throws {
        XCTAssertEqual(TrafficTableKeyCopy.detailDelayMilliseconds,
                       Int((TrafficDetailDebounce<Int>.defaultInterval * 1000).rounded()))
        XCTAssertEqual(TrafficTableKeyCopy.detailDelayMilliseconds, 150, "the pause the debounce waits today")
        let pause = try bullet(saying: "waits until you stop")
        XCTAssertTrue(pause.contains("\(TrafficTableKeyCopy.detailDelayMilliseconds) ms after the last key"), pause)
        XCTAssertTrue(pause.contains("at most one of the \(FreeTier.httpsSessionDetailsPerLaunch) free HTTPS inspections"), pause)
    }

    // MARK: - ↑ and ↓

    /// "↓ and ↑ select the request below or above the selection … With
    /// nothing selected, ↓ starts at the top of the list and ↑ at the bottom.
    /// At the first or the last request the selection stays where it is — it
    /// does not wrap around."
    func testTheArrowsAreAsHelpSaysThey() throws {
        _ = try bullet(saying: "↓ and ↑ select the request below or above the selection")
        XCTAssertEqual(move(.down, selection: ["b"])?.selection, ["c"])
        XCTAssertEqual(move(.up, selection: ["b"])?.selection, ["a"])
        XCTAssertEqual(move(.down, selection: ["b", "c"])?.selection, ["d"], "below the selection, alone")

        _ = try bullet(saying: "With nothing selected, ↓ starts at the top of the list and ↑ at the bottom.")
        XCTAssertEqual(move(.down, selection: [])?.selection, ["a"])
        XCTAssertEqual(move(.up, selection: [])?.selection, ["e"])

        _ = try bullet(saying: "it does not wrap around")
        XCTAssertEqual(move(.down, selection: ["e"])?.selection, ["e"])
        XCTAssertEqual(move(.up, selection: ["a"])?.selection, ["a"])
    }

    /// "⇧↓ and ⇧↑ grow the selection one request at a time from where it
    /// started, and shrink it again on the way back. ⇧-click selects every
    /// request from that same starting point to the one you click; ⌘-click
    /// adds or removes one."
    func testShiftAndCommandAreAsHelpSaysThey() throws {
        _ = try bullet(saying: "⇧↓ and ⇧↑ grow the selection one request at a time from where it started, and shrink it again on the way back.")
        let start = try XCTUnwrap(move(.down, selection: ["a"]))  // b, alone: where it started
        let one = try XCTUnwrap(move(.down, shift: true, selection: start.selection, cursor: start.cursor))
        XCTAssertEqual(one.selection, ["b", "c"])
        let two = try XCTUnwrap(move(.down, shift: true, selection: one.selection, cursor: one.cursor))
        XCTAssertEqual(two.selection, ["b", "c", "d"])
        let back = try XCTUnwrap(move(.up, shift: true, selection: two.selection, cursor: two.cursor))
        XCTAssertEqual(back.selection, ["b", "c"], "shrinks on the way back")

        _ = try bullet(saying: "⇧-click selects every request from that same starting point to the one you click")
        let clicked = Nav.click("e", .extend, rows: table, selection: back.selection, cursor: back.cursor)
        XCTAssertEqual(clicked.selection, ["b", "c", "d", "e"])

        _ = try bullet(saying: "⌘-click adds or removes one")
        let added = Nav.click("e", .toggle, rows: table, selection: ["b"], cursor: start.cursor)
        XCTAssertEqual(added.selection, ["b", "e"])
        let removed = Nav.click("e", .toggle, rows: table, selection: added.selection, cursor: added.cursor)
        XCTAssertEqual(removed.selection, ["b"])
    }

    /// "With several requests selected, the detail pane shows the one you
    /// clicked or moved to last." — the active row, which the pane shows.
    func testTheActiveRowIsTheOneMovedToOrClickedLast() throws {
        _ = try bullet(saying: "the detail pane shows the one you clicked or moved to last")
        let start = try XCTUnwrap(move(.down, selection: ["a"]))
        let grown = try XCTUnwrap(move(.down, shift: true, selection: start.selection, cursor: start.cursor))
        XCTAssertEqual(grown.active, "c")
        XCTAssertEqual(grown.cursor.active, "c")
        let clicked = Nav.click("a", .toggle, rows: table, selection: grown.selection, cursor: grown.cursor)
        XCTAssertEqual(clicked.active, "a")
    }

    // MARK: - The detail pane's pause

    /// "A click shows its request in the detail pane at once. With the arrow
    /// keys the pane waits until you stop … and never while an arrow is held
    /// down — so holding ↓ to skim the list opens only the request you stop
    /// on." Clock and key repeats as macOS's defaults (half a second, then
    /// every 83 ms).
    func testAClickShowsAtOnceAndAHeldKeyOnlyWhereItStops() throws {
        _ = try bullet(saying: "A click shows its request in the detail pane at once.")
        var now: TimeInterval = 0
        var pane = TrafficDetailDebounce<String>(clock: { now })
        pane.show("a")
        XCTAssertEqual(pane.shown, "a", "a click: at once")

        _ = try bullet(saying: "never while an arrow is held down")
        var shown: [String] = []
        var wakes: [(at: TimeInterval, serial: Int)] = []
        func settleDue() {
            wakes.sort { $0.at < $1.at }
            while let first = wakes.first, first.at <= now {
                wakes.removeFirst()
                switch pane.settle(first.serial) {
                case .show(let row): shown.append(row ?? "no row")
                case .wait(let wake): wakes.append((now + wake.delay, wake.serial))
                case .idle: break
                }
            }
        }
        let presses = [0.0] + (0..<8).map { 0.5 + Double($0) / 12 }
        for (index, time) in presses.enumerated() {
            now = time
            settleDue()
            if let wake = pane.keyMoved(to: ["b", "c", "d", "e", "f", "g", "h", "i", "j"][index]) {
                wakes.append((now + wake.delay, wake.serial))
            }
        }
        now = presses.last! + 0.5
        settleDue()
        XCTAssertEqual(shown, [], "nothing while the key is down")
        if let wake = pane.keyReleased() { wakes.append((now + wake.delay, wake.serial)) }
        settleDue()
        XCTAssertEqual(shown, ["j"], "only the request it stopped on")
    }

    // MARK: - Esc and Delete

    /// "Esc deselects everything and closes the detail pane — also while you
    /// are reading a body or headers in it. Delete (or ⌦) removes the
    /// selected requests from the list."
    func testEscAndDeleteAreAsHelpSaysThey() throws {
        _ = try bullet(saying: "Esc deselects everything and closes the detail pane — also while you are reading a body or headers in it.")
        XCTAssertEqual(command(Keys.Key.escape), .clearSelection)
        XCTAssertEqual(command(Keys.Key.escape, responder: .readingText), .clearSelection)

        _ = try bullet(saying: "Delete (or ⌦) removes the selected requests from the list")
        XCTAssertEqual(command(Keys.Key.delete), .deleteSelection)
        XCTAssertEqual(command(Keys.Key.forwardDelete), .deleteSelection)
        XCTAssertEqual(command(Keys.Key.delete, .function), .deleteSelection, "fn-Delete is ⌦ on a laptop")
    }

    // MARK: - Where the keys are the list's

    /// "These keys belong to the list while it has the keyboard — after you
    /// click a request, for example." A click on a row hands the keyboard to
    /// the window; so does the traffic pane.
    func testTheKeysAreTheListsWhenItHasTheKeyboard() throws {
        _ = try bullet(saying: "These keys belong to the list while it has the keyboard — after you click a request, for example.")
        for responder in [Keys.Responder.window, .trafficPane] {
            XCTAssertEqual(command(Keys.Key.downArrow, responder: responder), .moveSelection(.down, extending: false))
            XCTAssertEqual(command(Keys.Key.upArrow, .shift, responder: responder), .moveSelection(.up, extending: true))
            XCTAssertEqual(command(Keys.Key.downArrow, [.function, .numericPad], responder: responder),
                           .moveSelection(.down, extending: false), "the flags every arrow carries")
        }
    }

    /// "Everywhere else they keep their own meaning: in the search field ↓
    /// walks its suggestions and Esc clears it; in a body or headers the
    /// arrows move the text cursor; in the sidebar and in a WebSocket's
    /// message list they move that list's own selection; and while a sheet or
    /// an alert is open, they are its keys."
    func testElsewhereTheKeysKeepTheirOwnMeaning() throws {
        _ = try bullet(saying: "in the search field ↓ walks its suggestions and Esc clears it")
        for key in Self.tableKeys {
            XCTAssertNil(command(key, responder: .text), "the search field keeps key \(key)")
        }
        _ = try bullet(saying: "in a body or headers the arrows move the text cursor")
        for key in Self.arrows {
            XCTAssertNil(command(key, responder: .readingText))
        }
        _ = try bullet(saying: "in the sidebar and in a WebSocket's message list they move that list's own selection")
        for key in Self.arrows {
            XCTAssertNil(command(key, responder: .list))
        }
        _ = try bullet(saying: "while a sheet or an alert is open, they are its keys")
        for key in Self.tableKeys {
            XCTAssertNil(command(key, sheet: true), "a sheet keeps key \(key)")
            XCTAssertNil(command(key, modal: true), "an alert keeps key \(key)")
        }
    }

    /// "Held with ⌘, ⌥ or ⌃, an arrow, Esc or Delete is never taken by the
    /// list."
    func testShortcutsAreNeverTheLists() throws {
        _ = try bullet(saying: "Held with ⌘, ⌥ or ⌃, an arrow, Esc or Delete is never taken by the list.")
        for key in Self.tableKeys {
            for modifier in [Keys.Modifiers.command, .option, .control] {
                for responder in Keys.Responder.allCases {
                    XCTAssertNil(command(key, modifier, responder: responder),
                                 "key \(key) with \(modifier) in \(responder)")
                    XCTAssertNil(command(key, [modifier, .shift], responder: responder),
                                 "key \(key) with \(modifier)⇧ in \(responder)")
                }
            }
        }
    }

    // MARK: - Help prints it

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
    }

    /// Help's source with `//` comments dropped, flattened to one line.
    private func help() throws -> String {
        let text = try String(contentsOf: Self.sourcesRoot.appendingPathComponent("UI/Views/Help/HelpContent.swift"),
                              encoding: .utf8)
        return text.components(separatedBy: "\n").map { line in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testHelpPrintsTheHeadingAndEveryBullet() throws {
        let help = try help()
        XCTAssertTrue(help.contains("helpHeading(TrafficTableKeyCopy.heading) {"), "Help prints the heading")
        XCTAssertTrue(help.contains("ForEach(TrafficTableKeyCopy.helpBullets, id: \\.self) { helpBullet($0) }"),
                      "Help prints every bullet")
        let capture = try XCTUnwrap(help.range(of: "private var captureTopic"), "the Capture topic")
        let certificate = try XCTUnwrap(help.range(of: "private var certificateTopic"), "the topic after it")
        let section = try XCTUnwrap(help.range(of: "TrafficTableKeyCopy.heading"))
        XCTAssertTrue(capture.upperBound < section.lowerBound && section.upperBound < certificate.lowerBound,
                      "in the Capture topic, which introduces the list")
    }
}
