//
//  SessionTableLayout.swift
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
//  The traffic table's column widths as pure, tested numbers (process-
//  attribution UX spec §1.5). The header and every row read ONLY these, so
//  the App column can be added — and hidden when attribution is unavailable —
//  and the Destination column shown, sized or hidden by the pane's width,
//  without a width literal in a view drifting from its neighbour's.
//
//  Why a number here is a test and not a comment: the traffic pane's minimum
//  is `ReqResSplitHost.Metrics.trafficMin` = 660 (measured 2026-09-17: at 520
//  the table clipped `Code`, and the side-by-side request|response tab bars
//  need ~620), and the row's HStack sums its children, dividers, gaps and
//  padding into a width that either fits inside 660 or clips the Duration
//  column off the pane's right edge with nothing to say so. `requiredWidth`
//  is that sum; the tests hold it under the pane minimum.
//

import Foundation

public enum SessionTableLayout {
    /// The App column has two widths, chosen by pane width: 96 shows
    /// "Safari", "claude", "Xcode", "Cursor" and "Unknown" whole beside a
    /// 16pt icon; 132 also fits "Brave Browser" and "Google Chrome".
    public enum Mode: Equatable, Sendable {
        case narrow
        case wide
    }

    /// Pane width at or above which `Mode` is `.wide`.
    public static let wideThreshold: CGFloat = 720

    public static let code: CGFloat = 40
    /// Exact, like every column but URL (rows shifted otherwise). It
    /// was min 60 / ideal 70 with no maximum, so a cell wider than 60 grew its
    /// column on THAT row only and pushed App and URL right — "PROPFIND" is
    /// 65.7pt at 13pt medium (measured), so every CalDAV row sat 6pt off its
    /// neighbours. 70 holds every method up to PROPFIND whole; PROPPATCH (78.1)
    /// and MKCALENDAR (89.2) scale down, then truncate, and the column can be
    /// dragged wider. URL's minimum gave the 10pt back, so every sum below is
    /// what it was.
    public static let method: CGFloat = 70

    /// min = ideal = max: the name is always shown, the column never flexes.
    public static func app(_ mode: Mode) -> CGFloat {
        mode == .wide ? 132 : 96
    }

    /// Was 200; gave Method 10pt and Time 8pt when both became exact
    /// (2026-09-29), so every row sum below is unchanged.
    public static let urlMin: CGFloat = 182
    public static let urlIdeal: CGFloat = 430

    /// The Destination column (where each request went — a country, This
    /// Mac, Local Network or Unknown), after URL and before Time. Narrow is
    /// the glyph alone — a flag at 14pt measures 20pt wide (AppKit, 2026-09-25),
    /// centred in 28; the header there is the `globe` symbol, since the word
    /// "Destination" is 69pt. Wide is the glyph, a 6pt gap and the name: 128
    /// leaves 102 for the label, which holds the longest names this column
    /// meets whole IN ENGLISH — "United Kingdom" 97.3, "Local Network" 86.4,
    /// "United States" 82.1 at 13pt (measured, not eyeballed: the 110 first
    /// proposed would have truncated "Local Network" by 2pt). "United Arab
    /// Emirates" (128) truncates, and so do longer localised names
    /// (`CountryPresentation.title` follows `Locale.current`: "Vereinigtes
    /// Königreich" is ~140); the tooltip carries the whole name either way.
    /// 128 is also the ceiling the row can afford — wide already needs 838
    /// beside the App column.
    public static func destination(_ mode: Mode) -> CGFloat {
        mode == .wide ? 128 : 28
    }

    /// The glyph's box inside the cell: the 14pt flag's 20pt, which the class
    /// symbols and the header's globe share so text after it lines up.
    public static let destinationGlyphWidth: CGFloat = 20
    public static let destinationGlyphSpacing: CGFloat = 6

    /// The `UserDefaults` key of the "Show Destination column" preference,
    /// read by the traffic list (`@AppStorage`) and written by Settings ▸
    /// General ▸ Traffic List. Absent means ON: the column is on by default
    /// and the toggle stores an explicit false.
    public static let destinationColumnDefaultsKey = "traffic-column-destination"

    /// Exact, with TABULAR digits (2026-09-29). It was min 80 with no
    /// maximum and proportional digits, so "08:08:08.888" (84.2pt) widened
    /// its own row; exact at 80 it truncated ("18:28:40.3…"). Tabular digits
    /// make every time 84.4pt at 13pt (measured), and 88 leaves SwiftUI the
    /// few points it needs before it truncates.
    public static let time: CGFloat = 88
    /// Was 80. `HH:mm:ss.SSS` needs ~75 of Time's 80 at 13pt, so the room for
    /// the App column comes out of Duration, whose longest realistic value
    /// ("12345 ms") fits 66.
    public static let duration: CGFloat = 66

    /// The row HStack's horizontal padding (both sides together), the spacing
    /// between its children, and each `VerticalDivider`'s width.
    public static let horizontalPadding: CGFloat = 30
    public static let stackSpacing: CGFloat = 8
    public static let dividerWidth: CGFloat = 1

    /// The narrowest pane a row lays out in without clipping: every column at
    /// its minimum, a divider between each pair, a gap between every child,
    /// plus the padding.
    ///
    /// With the App column that is 6 columns + 5 dividers = 11 children and 10
    /// gaps: narrow 40+70+96+182+88+66 = 542, + 80 gaps + 5 dividers + 30 =
    /// 657 (≤ 660, the pane minimum); wide 578 + 115 = 693 (≤ 720, the
    /// threshold, leaving URL ≥ 227 there). Without it, 5 columns + 4
    /// dividers = 9 children, 8 gaps: 446 + 64 + 4 + 30 = 544.
    ///
    /// Each further column costs its width plus a divider and two gaps (17):
    /// Destination narrow adds 45, wide adds 145.
    public static func requiredWidth(showsApp: Bool, mode: Mode) -> CGFloat {
        requiredWidth(showsApp: showsApp, showsDestination: false, mode: mode)
    }

    /// The same sum with the Destination column in or out, both optional
    /// columns at `mode`.
    public static func requiredWidth(showsApp: Bool, showsDestination: Bool, mode: Mode) -> CGFloat {
        requiredWidth(app: showsApp ? mode : nil, destination: showsDestination ? mode : nil)
    }

    /// The general form: each optional column at its own mode, or absent
    /// (nil). The two are chosen separately — the App column's mode is a
    /// pane-width threshold, the Destination column's is whatever fits — so
    /// a row can carry a wide App column beside a narrow Destination one.
    public static func requiredWidth(app: Mode?, destination: Mode?) -> CGFloat {
        var columns: [CGFloat] = [code, method, urlMin, time, duration]
        if let app {
            columns.append(Self.app(app))
        }
        if let destination {
            columns.append(Self.destination(destination))
        }
        let dividers = CGFloat(columns.count - 1)
        let children = CGFloat(columns.count) + dividers
        let gaps = children - 1
        return columns.reduce(0, +)
            + dividers * dividerWidth
            + gaps * stackSpacing
            + horizontalPadding
    }

    public static func mode(forPaneWidth width: CGFloat) -> Mode {
        width >= wideThreshold ? .wide : .narrow
    }

    // MARK: - The Destination column's visibility

    /// Whether the Destination column is drawn: only when the user wants it
    /// (`preferred`, the Settings toggle) AND the row still fits the pane
    /// with it — see `destinationMode` for the widths at which that is true.
    public static func showsDestination(preferred: Bool, paneWidth: CGFloat, showsApp: Bool) -> Bool {
        destinationMode(preferred: preferred, paneWidth: paneWidth, showsApp: showsApp) != nil
    }

    /// Which form the Destination column takes at `paneWidth`, or nil when it
    /// is hidden. Wide when the row fits with the wide column; else narrow
    /// when the row fits with the narrow one; else nothing — the column never
    /// clips Duration off the pane's edge to make room for itself.
    ///
    /// BOTH checks assume the App column at its WIDE width, which is what
    /// makes the column MONOTONIC in the pane width by construction — never
    /// lost by widening the pane — rather than by the accident of today's
    /// numbers. The trap: with the App column narrow, the narrow row would
    /// already fit at 702 (657 + 45), but at 720 the App column widens to 132
    /// and the same row needs 738, so a column that appeared at 702 would
    /// vanish again from 720 to 737. Appearing 36pt later is the smaller
    /// cost, so it appears at 738. (For the wide check the assumption changes
    /// nothing today — 802 is already past the 720 threshold — but it means a
    /// future shrink of `urlMin` or `app(.narrow)` cannot reopen the trap;
    /// the sweep test holds it either way.)
    ///
    /// `paneWidth` is the table's CONTENT width, not the ScrollView's frame:
    /// `SessionListView` reads it from the LazyVStack, so a legacy (always-
    /// shown) scroller's ~16pt is already subtracted and the row really has
    /// the width it is compared against. Under overlay scrollers, the
    /// default, the two are equal.
    ///
    /// The numbers (the tests state them):
    ///   App shown:  hidden below 738 · narrow 738…837 · wide from 838
    ///               (so at the 660 pane minimum it is hidden, and the row
    ///               there is the 657 the App column proved).
    ///   App hidden: narrow 589…688 · wide from 689 — visible at 660 already,
    ///               which is what a Mac without attribution gets.
    ///
    /// Worth knowing when reading a first-run screenshot: the DEFAULT window
    /// (`ReqResMainWindow.defaultSize` 1250, sidebar 220, overrides 280)
    /// gives the traffic pane ≈ 750, inside the narrow band — a new user sees
    /// flags under a globe header and gets the name from the tooltip until the
    /// window is wider. Settings ▸ General says so. Landing the default in the
    /// wide band would need a 1340pt default window and a `layoutGeneration`
    /// bump; that is a product decision, not this rule's.
    public static func destinationMode(preferred: Bool, paneWidth: CGFloat, showsApp: Bool) -> Mode? {
        guard preferred else { return nil }
        let appWidest: Mode? = showsApp ? .wide : nil
        if requiredWidth(app: appWidest, destination: .wide) <= paneWidth {
            return .wide
        }
        if requiredWidth(app: appWidest, destination: .narrow) <= paneWidth {
            return .narrow
        }
        return nil
    }
}

// MARK: - Exact widths, and columns the user resizes

extension SessionTableLayout {
    /// The columns a drag can resize. Code is a fixed chip; URL is the one
    /// flexible column and takes whatever the others leave.
    public enum Column: String, CaseIterable, Codable, Sendable {
        case method, app, destination, time, duration

        /// Which side of URL the column sits on, and so which of its edges
        /// the header's handle is: a column before URL is resized from its
        /// RIGHT edge, one after it from its LEFT edge — the edge next to URL
        /// in both cases, so the divider stays under the pointer while URL
        /// takes up the difference.
        public var isBeforeURL: Bool { self == .method || self == .app }
    }

    /// How narrow and how wide a drag may make each column. The minimums keep
    /// something readable (a 16pt icon for App, the glyph for Destination);
    /// the maximums keep one column from eating the table.
    public static func range(_ column: Column) -> ClosedRange<CGFloat> {
        switch column {
        case .method: return 44...160
        case .app: return 44...320
        case .destination: return destination(.narrow)...240
        case .time: return 60...160
        case .duration: return 44...140
        }
    }

    /// Below this the Destination cell is the glyph alone (and the header the
    /// globe); at or above it, the glyph and the name. Automatic sizing gives
    /// 28 or 128, so the rule reproduces narrow and wide exactly.
    public static let destinationNameMinimum: CGFloat = 60

    /// The `UserDefaults` key holding the widths the user dragged to, as the
    /// JSON `ColumnWidths.storage` writes. Absent or empty = automatic.
    public static let columnWidthsDefaultsKey = "traffic-column-widths"

    /// The widths the user chose. A column with no entry is automatic; every
    /// stored value is clamped to its column's `range`.
    public struct ColumnWidths: Equatable, Sendable {
        public private(set) var values: [Column: CGFloat]

        public init(_ values: [Column: CGFloat] = [:]) {
            self.values = [:]
            for (column, width) in values { self[column] = width }
        }

        public subscript(column: Column) -> CGFloat? {
            get { values[column] }
            set {
                guard let newValue, newValue.isFinite else { values[column] = nil; return }
                let range = SessionTableLayout.range(column)
                values[column] = min(max(newValue.rounded(), range.lowerBound), range.upperBound)
            }
        }

        public var isEmpty: Bool { values.isEmpty }

        /// Reads what `storage` wrote. Anything unreadable — a bad string, an
        /// unknown column, a non-number — is dropped, never an error: the
        /// worst a damaged preference can do is put a column back to automatic.
        public init(storage: String) {
            self.init()
            guard let data = storage.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            for (key, value) in object {
                guard let column = Column(rawValue: key), let number = value as? NSNumber else { continue }
                self[column] = CGFloat(number.doubleValue)
            }
        }

        /// `{"app":150,"method":80}` — sorted keys, so the same widths always
        /// write the same string. Empty when every column is automatic.
        public var storage: String {
            guard !values.isEmpty else { return "" }
            let object = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, Double($0.value)) })
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Every column's width for one render of the table; the header and every
    /// row lay out from the same value, which is what keeps them aligned.
    public struct Columns: Equatable, Sendable {
        public var method: CGFloat
        /// nil = the column is hidden.
        public var app: CGFloat?
        /// nil = the column is hidden.
        public var destination: CGFloat?
        public var time: CGFloat
        public var duration: CGFloat

        public init(method: CGFloat, app: CGFloat?, destination: CGFloat?, time: CGFloat, duration: CGFloat) {
            self.method = method
            self.app = app
            self.destination = destination
            self.time = time
            self.duration = duration
        }

        public var code: CGFloat { SessionTableLayout.code }

        /// Whether the Destination cell shows the name beside the glyph.
        public var destinationShowsName: Bool { (destination ?? 0) >= SessionTableLayout.destinationNameMinimum }

        public func width(of column: Column) -> CGFloat? {
            switch column {
            case .method: return method
            case .app: return app
            case .destination: return destination
            case .time: return time
            case .duration: return duration
            }
        }

        mutating func set(_ column: Column, _ width: CGFloat?) {
            switch column {
            case .method: method = width ?? method
            case .app: app = width
            case .destination: destination = width
            case .time: time = width ?? time
            case .duration: duration = width ?? duration
            }
        }

        /// The row's width with URL at its minimum — the same sum as
        /// `requiredWidth(app:destination:)`, for any widths.
        public var requiredWidth: CGFloat {
            var widths: [CGFloat] = [code, method, SessionTableLayout.urlMin, time, duration]
            if let app { widths.append(app) }
            if let destination { widths.append(destination) }
            let dividers = CGFloat(widths.count - 1)
            let gaps = CGFloat(widths.count) + dividers - 1
            return widths.reduce(0, +) + dividers * dividerWidth + gaps * stackSpacing + horizontalPadding
        }

        /// The automatic widths for a given App and Destination form — what
        /// the table shows before anyone drags a divider, and what the Help
        /// window's and the probes' fixed tables draw.
        public static func automatic(mode: Mode, showsApp: Bool, destination: Mode?) -> Columns {
            Columns(
                method: SessionTableLayout.method,
                app: showsApp ? SessionTableLayout.app(mode) : nil,
                destination: destination.map(SessionTableLayout.destination),
                time: SessionTableLayout.time,
                duration: SessionTableLayout.duration
            )
        }
    }

    /// The table's columns at `paneWidth` with the user's widths applied.
    ///
    /// With no user widths this is exactly the automatic table: App 96/132 by
    /// `mode`, Destination by `destinationMode` (the tests hold the two equal
    /// at every width). A user width replaces its column's automatic one, and
    /// three rules keep Duration on the pane:
    /// - Destination is judged the way `destinationMode` judges it — with the
    ///   App column at its WIDE width unless the user fixed it — so widening
    ///   the pane never loses it; a user-sized Destination that no longer fits
    ///   falls back to the glyph, then hides.
    /// - If the row still does not fit (columns dragged wide, then the window
    ///   narrowed), user-widened columns give their extra back — Duration,
    ///   Time, App, Method, then Destination's — before anything else.
    /// - Then Destination hides; then the dragged columns shrink to their
    ///   range minimums. At the 660pt pane minimum the row always fits.
    /// The stored widths are never changed by this: widen the window again
    /// and the user's widths come back.
    public static func columns(paneWidth: CGFloat, showsApp: Bool, destinationPreferred: Bool, user: ColumnWidths) -> Columns {
        let mode = mode(forPaneWidth: paneWidth)
        var result = Columns(
            method: user[.method] ?? method,
            app: showsApp ? (user[.app] ?? app(mode)) : nil,
            destination: nil,
            time: user[.time] ?? time,
            duration: user[.duration] ?? duration
        )
        if destinationPreferred {
            var probe = result
            probe.app = showsApp ? (user[.app] ?? app(.wide)) : nil
            let candidates = user[.destination].map { [$0, destination(.narrow)] } ?? [destination(.wide), destination(.narrow)]
            for candidate in candidates {
                probe.destination = candidate
                if probe.requiredWidth <= paneWidth {
                    result.destination = candidate
                    break
                }
            }
        }
        guard result.requiredWidth > paneWidth else { return result }

        // Dragged-wide columns give back what they took above automatic.
        let automatic = Columns.automatic(mode: mode, showsApp: showsApp, destination: result.destination == nil ? nil : .narrow)
        for column: Column in [.duration, .time, .app, .method, .destination] {
            let excess = result.requiredWidth - paneWidth
            guard excess > 0 else { return result }
            guard user[column] != nil, let current = result.width(of: column), let floor = automatic.width(of: column), current > floor else { continue }
            result.set(column, current - min(excess, current - floor))
        }
        guard result.requiredWidth > paneWidth else { return result }
        result.destination = nil
        for column: Column in [.duration, .time, .app, .method] {
            let excess = result.requiredWidth - paneWidth
            guard excess > 0 else { return result }
            guard user[column] != nil, let current = result.width(of: column) else { continue }
            let floor = range(column).lowerBound
            if current > floor { result.set(column, current - min(excess, current - floor)) }
        }
        return result
    }

    /// The width a drag may give `column`: inside its `range`, and never more
    /// than the pane has spare with URL at its minimum — a divider dragged
    /// past that stops, rather than pushing Duration off the edge.
    public static func dragWidth(_ proposed: CGFloat, for column: Column, in current: Columns, paneWidth: CGFloat) -> CGFloat {
        let range = range(column)
        let now = current.width(of: column) ?? range.lowerBound
        let spare = max(0, paneWidth - current.requiredWidth)
        let upper = max(range.lowerBound, min(range.upperBound, now + spare))
        return min(max(proposed.rounded(), range.lowerBound), upper)
    }
}
