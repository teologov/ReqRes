//
//  TrafficDetailDebounce.swift
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
//  When the traffic detail pane takes the row the arrow keys moved to.
//
//  A click shows its row at once. An arrow key's row is shown once the keys
//  have paused: `interval` (150 ms) after the last move, and not while the
//  arrow key is still down. A held ↓ passes a row every key repeat — 83 ms at
//  macOS's default rate, 30 ms at the fastest — and showing each one on the
//  way would render every body it passes (up to 16 MB each) and, for a free
//  user, spend one of the launch's ten HTTPS inspections on each:
//  `FreeTier.InspectionTally` counts a row when the pane SHOWS it. Debounced,
//  the pane swaps once, to the row the key stopped on — so a held key spends
//  one inspection whatever the repeat rate, a quick burst of taps one, a slow
//  walk one per row, a click one: what a person actually looked at.
//
//  Why the key's release and not only a pause: macOS waits before it repeats
//  a held key (half a second by default), and at its slower repeat rates
//  leaves more than 150 ms between repeats. A pause alone showed — and
//  counted — the row a held key's first press landed on, and at those rates
//  every row it passed. So the table tells this type when an arrow key is let
//  go of (`keyReleased`). If that never comes — the app was left while the key
//  was down — the row is shown once the key has been silent for longer than
//  macOS ever leaves between a held key's presses (`holdLimit`).
//
//  The clock and the hold limit are injected; the table schedules the
//  wake-ups (`keyMoved` and `keyReleased` return when) and asks `settle` what
//  to do when one arrives.
//

import Foundation

public struct TrafficDetailDebounce<Row: Hashable> {
    /// How long the keys must pause before the pane takes their row.
    public static var defaultInterval: TimeInterval { 0.15 }

    /// The hold limit's bounds: never shorter than half a second, never
    /// longer than three, whatever the system reports.
    public static var minimumHoldLimit: TimeInterval { 0.5 }
    public static var maximumHoldLimit: TimeInterval { 3 }

    /// How long after its last move an arrow key still down is taken for let
    /// go (its release lost: the app was left while it was down). Half again
    /// as long as the longest gap macOS leaves between a held key's presses —
    /// the delay before its first repeat, or the repeat interval — so a key
    /// still held never shows a row it is passing; within
    /// `minimumHoldLimit`…`maximumHoldLimit`.
    ///
    /// - Parameters:
    ///   - repeatDelay: `NSEvent.keyRepeatDelay` (System Settings ▸ Keyboard ▸
    ///     Delay until repeat; 0.5 s on a Mac that never changed it).
    ///   - repeatInterval: `NSEvent.keyRepeatInterval` (Key repeat rate;
    ///     1/12 s on a Mac that never changed it).
    public static func holdLimit(repeatDelay: TimeInterval, repeatInterval: TimeInterval) -> TimeInterval {
        let gap = max(repeatDelay, repeatInterval)
        guard gap.isFinite else { return maximumHoldLimit }
        return min(max(gap * 1.5, minimumHoldLimit), maximumHoldLimit)
    }

    /// When to call `settle(_:)`, and with which serial.
    public struct Wake: Equatable, Sendable {
        public let serial: Int
        public let delay: TimeInterval
    }

    /// What a wake-up does.
    public enum Settle: Equatable {
        /// The keys paused: the pane shows this row now.
        case show(Row?)
        /// Woken before the pause was over, or with the key still down: call
        /// again then.
        case wait(Wake)
        /// A later move, or a click, has taken over: nothing to do.
        case idle
    }

    private struct Waiting {
        let row: Row
        let movedAt: TimeInterval
        let due: TimeInterval
        let serial: Int
    }

    public let interval: TimeInterval
    private let clock: () -> TimeInterval
    private let holdLimit: () -> TimeInterval
    /// The row the pane shows; nil when it shows none.
    public private(set) var shown: Row?
    private var waiting: Waiting?
    private var serial = 0
    /// An arrow key the table moved by is down: its release has not come yet.
    public private(set) var isKeyDown = false

    public init(
        interval: TimeInterval = TrafficDetailDebounce.defaultInterval,
        holdLimit: @escaping () -> TimeInterval = {
            TrafficDetailDebounce.holdLimit(repeatDelay: 0.5, repeatInterval: 1.0 / 12)
        },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.interval = interval
        self.holdLimit = holdLimit
        self.clock = clock
    }

    /// True while an arrow key's row waits to be shown.
    public var isWaiting: Bool { waiting != nil }

    /// A click, Esc, Delete, the pane's ✕ — anything but an arrow key: the
    /// pane shows `row` now, and a key move still waiting is dropped.
    public mutating func show(_ row: Row?) {
        waiting = nil
        shown = row
    }

    /// An arrow key — pressed, or repeating while held — made `row` the
    /// active row; the key is down. Returns when to call `settle(_:)` — or
    /// nil when the pane shows that row already (the keys came back to it,
    /// or stayed on it at the end of the table): nothing waits then, and a
    /// move still waiting is dropped.
    public mutating func keyMoved(to row: Row) -> Wake? {
        isKeyDown = true
        guard row != shown else {
            waiting = nil
            return nil
        }
        serial += 1
        let now = clock()
        waiting = Waiting(row: row, movedAt: now, due: now + interval, serial: serial)
        return Wake(serial: serial, delay: interval)
    }

    /// An arrow key was let go of — wherever it went, so a key whose press
    /// the table took is never left down here. Returns a wake-up to schedule
    /// now when the row it moved to has waited out its pause already (the
    /// key was held past it); nil when the wake-up `keyMoved` scheduled is
    /// still to come and shows it, or when nothing waits.
    public mutating func keyReleased() -> Wake? {
        guard isKeyDown else { return nil }
        isKeyDown = false
        guard let waiting, clock() >= waiting.due else { return nil }
        return Wake(serial: waiting.serial, delay: 0)
    }

    /// A wake-up scheduled by `keyMoved` or `keyReleased`.
    public mutating func settle(_ serial: Int) -> Settle {
        guard let waiting, waiting.serial == serial else { return .idle }
        let now = clock()
        if now < waiting.due {
            return .wait(Wake(serial: serial, delay: waiting.due - now))
        }
        if isKeyDown {
            // Still down: the row is being passed, not stopped on — unless the
            // key has been silent for longer than a held key ever is between
            // its presses, and its release was lost.
            let lost = waiting.movedAt + holdLimit()
            if now < lost {
                return .wait(Wake(serial: serial, delay: lost - now))
            }
            isKeyDown = false
        }
        self.waiting = nil
        shown = waiting.row
        return .show(waiting.row)
    }

    /// The selection changed, to one whose detail is `row`. True when the
    /// pane must show `row` now — a change made by something other than an
    /// arrow key (Esc, Delete, the ✕). False for the arrow key's own change,
    /// which its wake-up shows, and when the pane shows `row` already.
    public mutating func selectionChanged(to row: Row?) -> Bool {
        if let waiting, waiting.row == row { return false }
        if waiting == nil, shown == row { return false }
        show(row)
        return true
    }
}
