//
//  TrafficDetailDebounceTests.swift
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
//  The detail pane follows the arrow keys once they pause and the key is let
//  go of: a held key swaps it once — to the row it stops on — and spends one
//  free inspection, whatever the repeat rate; a burst of taps one; a slow walk
//  one per row; a click one at once. Driven as the table drives it — each
//  press and release schedules its wake-up, the wake-ups arrive in time order
//  — on an injected clock, with the inspections counted by the real
//  `FreeTier.InspectionTally`, which counts a row when the pane shows it.
//

import XCTest
@testable import Utils

final class TrafficDetailDebounceTests: XCTestCase {
    private typealias Debounce = TrafficDetailDebounce<String>

    /// macOS's key repeat on a Mac whose settings were never changed
    /// (`NSEvent.keyRepeatDelay` / `keyRepeatInterval`, read on macOS 27).
    private static let defaultDelay = 0.5
    private static let defaultInterval = 1.0 / 12

    /// The delays until repeat and the repeat intervals System Settings ▸
    /// Keyboard's two sliders store (InitialKeyRepeat 15, 25, 35, 68, 94, 120
    /// and KeyRepeat 2, 6, 12, 30, 60, 90, 120, in steps of 15 ms).
    private static let settingsDelays = [15.0, 25, 35, 68, 94, 120].map { $0 * 0.015 }
    private static let settingsIntervals = [2.0, 6, 12, 30, 60, 90, 120].map { $0 * 0.015 }

    /// The table's side of it: the clock, the pending wake-ups, the pane, and
    /// the free inspections spent.
    private final class Table {
        var now: TimeInterval = 0
        var holdLimit = Debounce.holdLimit(repeatDelay: defaultDelay, repeatInterval: defaultInterval)
        lazy var debounce = Debounce(holdLimit: { [unowned self] in self.holdLimit },
                                     clock: { [unowned self] in self.now })
        private var wakes: [(at: TimeInterval, serial: Int)] = []
        /// Every row the pane swapped to, in order, and when.
        var swaps: [String?] = []
        var swapTimes: [TimeInterval] = []
        var tally = FreeTier.InspectionTally()
        var ids: [String: UUID] = [:]
        var spent = 0

        private func showInPane(_ row: String?) {
            swaps.append(row)
            swapTimes.append(now)
            guard let row else { return }
            let id = ids[row, default: UUID()]
            ids[row] = id
            // The pane shows an unlicensed HTTPS row: `HttpsSessionDetailContent`.
            if tally.recordView(rowID: id, access: .inspect(counted: true)) { spent += 1 }
        }

        private func schedule(_ wake: Debounce.Wake?) {
            if let wake { wakes.append((now + wake.delay, wake.serial)) }
        }

        /// The clock moves to `time`, delivering every wake-up due by then.
        func advance(to time: TimeInterval) {
            while let next = wakes.min(by: { $0.at < $1.at }), next.at <= time {
                wakes.removeAll { $0.at == next.at && $0.serial == next.serial }
                now = next.at
                switch debounce.settle(next.serial) {
                case .show(let row): showInPane(row)
                case .wait(let wake): schedule(wake)
                case .idle: break
                }
            }
            now = time
        }

        /// An arrow key goes down — or repeats while held — at `time`, moving
        /// the active row to `row`; the selection change it makes follows, as
        /// SwiftUI's onChange does.
        func press(_ row: String, at time: TimeInterval) {
            advance(to: time)
            schedule(debounce.keyMoved(to: row))
            if debounce.selectionChanged(to: row) { showInPane(row) }
        }

        /// The arrow key is let go of at `time`.
        func release(at time: TimeInterval) {
            advance(to: time)
            schedule(debounce.keyReleased())
        }

        /// A tap: down at `time`, up 60 ms later.
        func tap(_ row: String, at time: TimeInterval) {
            press(row, at: time)
            release(at: time + 0.06)
        }

        /// A held key: its press moves to `rows[0]`; macOS repeats it after
        /// `delay`, then every `interval`, a row per repeat; it is let go of
        /// halfway to the repeat after the last. Returns when the row it
        /// stops on is due: its pause over AND the key let go of.
        @discardableResult
        func hold(_ rows: [String], from start: TimeInterval, delay: TimeInterval, interval: TimeInterval) -> TimeInterval {
            press(rows[0], at: start)
            var last = start
            for (index, row) in rows.dropFirst().enumerated() {
                last = start + delay + Double(index) * interval
                press(row, at: last)
            }
            let letGo = last + (rows.count == 1 ? delay : interval) / 2
            release(at: letGo)
            return max(letGo, last + Debounce.defaultInterval)
        }

        /// A click at `time`: the pane shows the row at once.
        func click(_ row: String, at time: TimeInterval) {
            advance(to: time)
            debounce.show(row)
            showInPane(row)
            if debounce.selectionChanged(to: row) { showInPane(row) }
        }

        /// Esc, Delete, the ✕ — a selection change no key made.
        func selectionChanged(to row: String?, at time: TimeInterval) {
            advance(to: time)
            if debounce.selectionChanged(to: row) { showInPane(row) }
        }
    }

    private func rows(_ count: Int) -> [String] { (0..<count).map { "r\($0)" } }

    private func assertTimes(_ times: [TimeInterval], _ expected: [TimeInterval], _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(times.count, expected.count, message, file: file, line: line)
        for (time, want) in zip(times, expected) {
            XCTAssertEqual(time, want, accuracy: 0.000_001, message, file: file, line: line)
        }
    }

    // MARK: - Taps

    /// A burst of taps — closer together than the interval — swaps the pane
    /// ONCE, to the row the taps stopped on, and spends one inspection.
    func testABurstOfTapsSwapsOnceAndSpendsOneInspection() {
        let table = Table()
        for (index, row) in ["a", "b", "c", "d", "e", "f", "g"].enumerated() {
            table.tap(row, at: Double(index) * 0.1)
        }
        table.advance(to: 0.6 + 0.149)
        XCTAssertEqual(table.swaps, [], "the keys have not paused for 150 ms yet")
        table.advance(to: 2)
        XCTAssertEqual(table.swaps, ["g"])
        XCTAssertEqual(table.spent, 1)
        XCTAssertEqual(table.debounce.shown, "g")
        XCTAssertFalse(table.debounce.isWaiting)
    }

    /// Taps slower than the interval: each row is shown, 150 ms after its
    /// tap, and each spends one — like clicking them one by one.
    func testASlowWalkShowsAndCountsEveryRow() {
        let table = Table()
        for (index, row) in ["a", "b", "c", "d"].enumerated() {
            table.tap(row, at: Double(index) * 0.4)
        }
        table.advance(to: 5)
        XCTAssertEqual(table.swaps, ["a", "b", "c", "d"])
        assertTimes(table.swapTimes, [0.15, 0.55, 0.95, 1.35], "150 ms after each tap, not at its release")
        XCTAssertEqual(table.spent, 4)
    }

    /// Exactly the interval apart is a pause: the earlier row is shown just
    /// before the next tap.
    func testTheIntervalIsTheBoundary() {
        let table = Table()
        table.tap("a", at: 0)
        table.tap("b", at: Debounce.defaultInterval)
        table.advance(to: 1)
        XCTAssertEqual(table.swaps, ["a", "b"])
        XCTAssertEqual(Debounce.defaultInterval, 0.15)
    }

    // MARK: - A held key

    /// A held ↓ at macOS's default rate: the press, then — half a second
    /// later — a repeat every 83 ms. Only the row it stops on is shown, when
    /// the key is let go of; the row the press landed on and the rows the
    /// repeats passed are not, and spend nothing.
    func testAHeldKeyShowsOnlyTheRowItStopsOn() {
        let table = Table()
        let due = table.hold(rows(21), from: 0, delay: Self.defaultDelay, interval: Self.defaultInterval)
        XCTAssertEqual(table.swaps, [], "nothing while the key is down")
        table.advance(to: due + 1)
        XCTAssertEqual(table.swaps, ["r20"])
        assertTimes(table.swapTimes, [due], "150 ms after the last repeat, the key let go of by then")
        XCTAssertEqual(table.spent, 1)
        XCTAssertFalse(table.debounce.isKeyDown)
    }

    /// At every delay and repeat rate System Settings offers — including the
    /// slow ones, which leave more than 150 ms between repeats and used to
    /// show (and count) every row a held key passed — a hold shows one row
    /// and spends one inspection.
    func testAHeldKeyAtEverySystemSettingsRateShowsOnlyTheRowItStopsOn() {
        var holds = 0
        for delay in Self.settingsDelays {
            for interval in Self.settingsIntervals {
                let table = Table()
                table.holdLimit = Debounce.holdLimit(repeatDelay: delay, repeatInterval: interval)
                let due = table.hold(rows(6), from: 0, delay: delay, interval: interval)
                table.advance(to: due + 5)
                XCTAssertEqual(table.swaps, ["r5"], "delay \(delay), interval \(interval)")
                assertTimes(table.swapTimes, [due], "delay \(delay), interval \(interval)")
                XCTAssertEqual(table.spent, 1, "delay \(delay), interval \(interval)")
                holds += 1
            }
        }
        XCTAssertEqual(holds, 42)
    }

    /// A key held a little — longer than the interval, too short to repeat —
    /// shows its row when it is let go of, not before.
    func testAKeyHeldWithoutRepeatingShowsItsRowWhenLetGoOf() {
        let table = Table()
        table.press("a", at: 0)
        table.advance(to: 0.39)
        XCTAssertEqual(table.swaps, [])
        table.release(at: 0.4)
        table.advance(to: 1)
        XCTAssertEqual(table.swaps, ["a"])
        assertTimes(table.swapTimes, [0.4])
    }

    /// A key let go of before its pause is over waits out the rest of it:
    /// the wake-up the press scheduled shows the row.
    func testATapShowsItsRowAfterThePauseNotAtItsRelease() {
        var debounce = Debounce(clock: { 0.06 })
        let wake = try! XCTUnwrap(debounce.keyMoved(to: "a"))
        XCTAssertNil(debounce.keyReleased(), "the press's own wake-up shows it")
        XCTAssertFalse(debounce.isKeyDown)
        XCTAssertEqual(wake.delay, 0.15)
    }

    /// The key's release never came — the app was left while it was down —
    /// so the row shows once the key has been silent for the hold limit, and
    /// a late release does nothing more.
    func testALostReleaseShowsTheRowOnceTheKeyHasBeenSilentTooLong() {
        let table = Table()
        table.press("r0", at: 0)
        table.press("r1", at: 0.5)
        table.press("r2", at: 0.5 + Self.defaultInterval)
        let lastMove = 0.5 + Self.defaultInterval
        table.advance(to: lastMove + table.holdLimit - 0.001)
        XCTAssertEqual(table.swaps, [])
        table.advance(to: lastMove + table.holdLimit + 0.001)
        XCTAssertEqual(table.swaps, ["r2"])
        assertTimes(table.swapTimes, [lastMove + table.holdLimit])
        XCTAssertFalse(table.debounce.isKeyDown)
        table.release(at: 5)
        table.advance(to: 6)
        XCTAssertEqual(table.swaps, ["r2"])
        XCTAssertEqual(table.spent, 1)
    }

    /// The release that comes after the pause shows the row at once, and the
    /// wake-up parked for a lost release then finds nothing to do.
    func testAReleaseAfterThePauseShowsAtOnce() {
        var now = 0.0
        var debounce = Debounce(holdLimit: { 0.75 }, clock: { now })
        let wake = try! XCTUnwrap(debounce.keyMoved(to: "b"))
        now = 0.15
        guard case .wait(let parked) = debounce.settle(wake.serial) else { return XCTFail("shown with the key down") }
        XCTAssertEqual(parked.delay, 0.6, accuracy: 0.000_01, "parked until the hold limit")
        now = 0.3
        let released = try! XCTUnwrap(debounce.keyReleased())
        XCTAssertEqual(released, .init(serial: wake.serial, delay: 0))
        XCTAssertEqual(debounce.settle(released.serial), .show("b"))
        now = 0.75
        XCTAssertEqual(debounce.settle(parked.serial), .idle)
    }

    /// A release with nothing waiting, or with no key down, does nothing.
    func testAReleaseWithNothingWaitingDoesNothing() {
        var debounce = Debounce(clock: { 1 })
        XCTAssertNil(debounce.keyReleased(), "no key down")
        debounce.show("a")
        XCTAssertNil(debounce.keyMoved(to: "a"), "the end of the table: the row the pane shows")
        XCTAssertTrue(debounce.isKeyDown)
        XCTAssertNil(debounce.keyReleased())
        XCTAssertFalse(debounce.isKeyDown)
        XCTAssertNil(debounce.keyReleased())
        XCTAssertEqual(debounce.shown, "a")
    }

    /// Half again the longest gap macOS leaves between a held key's presses,
    /// so a key still held never shows a row it passes; never under half a
    /// second or over three, whatever the system reports.
    func testTheHoldLimit() {
        XCTAssertEqual(Debounce.holdLimit(repeatDelay: Self.defaultDelay, repeatInterval: Self.defaultInterval), 0.75)
        XCTAssertEqual(Debounce.holdLimit(repeatDelay: 1.8, repeatInterval: 1.8), 2.7, accuracy: 0.000_01)
        XCTAssertEqual(Debounce.holdLimit(repeatDelay: 0.225, repeatInterval: 0.03), 0.5, "the floor")
        XCTAssertEqual(Debounce.holdLimit(repeatDelay: 0, repeatInterval: 0), 0.5)
        XCTAssertEqual(Debounce.holdLimit(repeatDelay: 2, repeatInterval: 4500), 3, "the ceiling")
        XCTAssertEqual(Debounce.holdLimit(repeatDelay: .infinity, repeatInterval: 0), 3)
        XCTAssertEqual(Debounce.holdLimit(repeatDelay: .nan, repeatInterval: .nan), 3)
        for delay in Self.settingsDelays {
            for interval in Self.settingsIntervals {
                let limit = Debounce.holdLimit(repeatDelay: delay, repeatInterval: interval)
                XCTAssertGreaterThan(limit, max(delay, interval) * 1.2, "delay \(delay), interval \(interval)")
            }
        }
    }

    // MARK: - Clicks and other changes

    /// A click shows its row at once and spends one; a key move still
    /// waiting is dropped, so its wake-up shows nothing.
    func testAClickIsImmediateAndCancelsAWaitingMove() {
        let table = Table()
        table.tap("a", at: 0)
        table.click("x", at: 0.1)
        XCTAssertEqual(table.swaps, ["x"], "at once")
        table.advance(to: 1)
        XCTAssertEqual(table.swaps, ["x"], "the key's row never comes")
        XCTAssertEqual(table.spent, 1)
    }

    /// A click on the very row a key move is waiting for still shows it at
    /// once.
    func testAClickOnTheRowAKeyIsWaitingForIsImmediateToo() {
        let table = Table()
        table.tap("a", at: 0)
        table.click("a", at: 0.1)
        XCTAssertEqual(table.swaps, ["a"])
        table.advance(to: 1)
        XCTAssertEqual(table.swaps, ["a"])
        XCTAssertEqual(table.spent, 1)
    }

    /// Clicks are never debounced: three quick clicks, three swaps.
    func testQuickClicksEachShowTheirRow() {
        let table = Table()
        table.click("a", at: 0)
        table.click("b", at: 0.02)
        table.click("c", at: 0.04)
        XCTAssertEqual(table.swaps, ["a", "b", "c"])
        XCTAssertEqual(table.spent, 3)
    }

    /// Back to the row the pane shows within the interval: nothing waits,
    /// nothing is swapped, nothing is spent.
    func testMovingBackToTheShownRowSwapsNothing() {
        let table = Table()
        table.click("a", at: 0)
        table.tap("b", at: 1)
        table.tap("a", at: 1.1)
        XCTAssertFalse(table.debounce.isWaiting)
        table.advance(to: 3)
        XCTAssertEqual(table.swaps, ["a"])
        XCTAssertEqual(table.spent, 1)
    }

    /// At the end of the table ↓ stays on the last row, which the pane
    /// shows: no wake-up at all.
    func testAKeyThatStaysOnTheShownRowSchedulesNothing() {
        var debounce = Debounce(clock: { 0 })
        debounce.show("f")
        XCTAssertNil(debounce.keyMoved(to: "f"))
        XCTAssertFalse(debounce.isWaiting)
    }

    /// Esc (or Delete, or the ✕) while a key move waits: the pane closes at
    /// once and the move's wake-up shows nothing — with the key down or up.
    func testEscWhileAMoveWaitsClosesThePaneAtOnce() {
        let table = Table()
        table.click("a", at: 0)
        table.tap("b", at: 1)
        table.selectionChanged(to: nil, at: 1.1)
        XCTAssertEqual(table.swaps, ["a", nil])
        table.press("c", at: 2)
        table.selectionChanged(to: nil, at: 2.6)
        XCTAssertEqual(table.swaps, ["a", nil, nil], "the held key's row is dropped too")
        table.release(at: 2.7)
        table.advance(to: 4)
        XCTAssertEqual(table.swaps, ["a", nil, nil])
        XCTAssertNil(table.debounce.shown)
    }

    /// The selection change an arrow key makes is the key's own: it never
    /// shows the row early. Any other change shows its row at once, and a
    /// change to what the pane shows already does nothing.
    func testWhichSelectionChangesShowAtOnce() {
        var debounce = Debounce(clock: { 0 })
        debounce.show("a")
        XCTAssertFalse(debounce.selectionChanged(to: "a"), "already shown")
        _ = debounce.keyMoved(to: "b")
        XCTAssertFalse(debounce.selectionChanged(to: "b"), "the key's own change waits")
        XCTAssertEqual(debounce.shown, "a")
        XCTAssertTrue(debounce.selectionChanged(to: "c"), "anything else shows at once")
        XCTAssertEqual(debounce.shown, "c")
        XCTAssertFalse(debounce.isWaiting)
    }

    /// A wake-up that arrives early (timers are not exact) waits out the
    /// rest; one from an older move does nothing.
    func testAnEarlyWakeWaitsAndAnOldOneDoesNothing() {
        var now = 0.0
        var debounce = Debounce(clock: { now })
        let first = try! XCTUnwrap(debounce.keyMoved(to: "a"))
        XCTAssertEqual(first.delay, 0.15)
        now = 0.1
        let second = try! XCTUnwrap(debounce.keyMoved(to: "b"))
        now = 0.12
        XCTAssertNil(debounce.keyReleased(), "let go of before its pause is over")
        now = 0.15
        XCTAssertEqual(debounce.settle(first.serial), .idle, "a later move owns the wake-up")
        now = 0.249
        guard case .wait(let rest) = debounce.settle(second.serial) else { return XCTFail("woken early") }
        XCTAssertEqual(rest.serial, second.serial)
        XCTAssertEqual(rest.delay, 0.001, accuracy: 0.000_01)
        now = 0.25
        XCTAssertEqual(debounce.settle(second.serial), .show("b"))
        XCTAssertEqual(debounce.settle(second.serial), .idle, "shown once")
    }
}
