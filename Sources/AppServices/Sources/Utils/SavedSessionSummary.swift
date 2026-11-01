//
//  SavedSessionSummary.swift
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
//  How a saved session reads, for BOTH surfaces that read one out (1.1.0).
//
//  ReqRes is built so a human and an agent have the same power, which means
//  the window and the MCP text output describe the same stored row. If each
//  formatted it for itself they would drift — and the drift is invisible
//  until someone reads a session in the window, asks the agent about "the
//  200 from 3 minutes ago", and the two disagree about which row that is.
//  So the formatting lives here, once, tested.
//
//  Pure on purpose: no AppKit, no SwiftUI, and no `SessionCodable` (which is
//  a type in the closed core this package cannot see). Callers pass plain
//  values in. Everything time-dependent takes `now` — a formatter that reads
//  the clock itself cannot be tested, and this one has to be.
//
//  Locale: the sizes and ages below are built by hand rather than with
//  `ByteCountFormatter`/`RelativeDateTimeFormatter` because these strings are
//  also what an agent reads back over MCP. A number whose decimal separator
//  changes with the user's region is a string an agent has to guess at, and a
//  test that passes only in en_US is worse than no test.
//

import Foundation

/// One saved session, rendered.
///
/// Hold the values, not the row: the caller maps whatever it has (the core's
/// `SavedSessionCodable`, or a bridge response) onto this.
public struct SavedSessionSummary: Equatable, Sendable {
    /// Where the title's path stops being readable. Past roughly this many
    /// characters a row's path stops helping tell it apart from its
    /// neighbours and starts pushing everything else out of the line.
    public static let maxTitlePathLength = 48

    public let method: String
    public let host: String
    /// Path and query, host stripped, never shortened — `title` shortens for
    /// display and keeps this intact for anyone who needs the real thing.
    public let path: String
    /// The response status as the core stores it (a string), or nil when the
    /// exchange has none.
    public let status: String?
    /// When the traffic happened.
    public let capturedAt: Date?
    /// When the USER kept it, which is not when it was captured — a session
    /// saved from a list can be hours old, and that difference is the whole
    /// reason both dates are shown.
    public let savedAt: Date
    /// Bytes on disk for this row, when the caller knows; nil when it only
    /// has the totals.
    public let byteSize: Int64?

    public init(
        method: String,
        host: String,
        uri: String,
        status: String?,
        capturedAt: Date?,
        savedAt: Date,
        byteSize: Int64? = nil
    ) {
        self.method = method.trimmingCharacters(in: .whitespaces)
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.path = Self.displayPath(fromURI: uri)
        let trimmedStatus = status?.trimmingCharacters(in: .whitespaces)
        self.status = (trimmedStatus?.isEmpty ?? true) ? nil : trimmedStatus
        self.capturedAt = capturedAt
        self.savedAt = savedAt
        self.byteSize = byteSize
    }

    // MARK: - The line that identifies the session

    /// `GET api.example.com/v1/orders?page=2`, with the path shortened when
    /// it is long.
    public var title: String {
        let verb = method.isEmpty ? "" : method.uppercased()
        let target = host + Self.shortenedPath(path)
        return [verb, target].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `200 · 12 KB · captured 3 minutes ago · saved just now`.
    ///
    /// Both times are here even when they are the same: "saved" alone reads
    /// as when the traffic happened, which is wrong for every session kept
    /// out of a list some time after the fact.
    public func subtitle(now: Date, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        // Said out loud rather than left blank: a saved row with no status is
        // a request that never got an answer, which is usually exactly why
        // someone kept it.
        parts.append(status ?? "No response")
        if let byteSize {
            parts.append(Self.byteSizeText(byteSize))
        }
        if let capturedAt {
            parts.append("captured " + Self.relativeAge(of: capturedAt, now: now, calendar: calendar))
        }
        parts.append("saved " + Self.relativeAge(of: savedAt, now: now, calendar: calendar))
        return parts.joined(separator: " · ")
    }

    /// Title and subtitle in one string, for a surface with a single line to
    /// spend — an agent's list output, a log, an accessibility label.
    public func oneLine(now: Date, calendar: Calendar = .current) -> String {
        title + " — " + subtitle(now: now, calendar: calendar)
    }

    // MARK: - Pieces

    /// Path and query out of whatever the core recorded as the URI.
    ///
    /// Over plain HTTP the recorded URI is absolute (`http://host/path`), so
    /// the host is dropped here — otherwise a title would name its host
    /// twice for HTTP and once for HTTPS, and the two would not look like the
    /// same list. The QUERY is deliberately kept, unlike
    /// `TrafficSearchPath.extract`: two saved rows to the same endpoint often
    /// differ only in their query, and a title that cannot tell them apart is
    /// no title at all.
    ///
    /// An empty path is shown as `/`, because a session to the site root is a
    /// real request and a row that just says `GET example.com` reads like a
    /// missing value.
    public static func displayPath(fromURI uri: String) -> String {
        let trimmed = uri.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "/" }
        guard let components = URLComponents(string: trimmed), components.host != nil else {
            // Not a parseable absolute URL: it is already a path (the HTTPS
            // case, `/v1/users?x=1`) or something malformed. Shown as
            // recorded, except for a leading slash, because the title
            // concatenates host and path — without it `v1/users` would render
            // as `example.comv1/users`, which reads as a different host.
            return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        }
        // percentEncoded* on purpose. `components.path`/`.query` DECODE, so an
        // HTTP row (absolute URL) would read as `/files/report/final.pdf` while
        // the HTTPS row for the same endpoint kept `report%2Ffinal.pdf` — the
        // exact divergence this function exists to remove, and worse: a decoded
        // %2F renders one path segment as two, naming an endpoint that was
        // never requested. It also matches the invariant the proxy itself
        // follows: stored paths keep their percent-encoding, and the proxy
        // compares the raw URI.
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            path += "?" + query
        }
        return path
    }

    /// A path short enough for one row, cut in the MIDDLE.
    ///
    /// The tail is kept because that is where paths differ — an id, a file
    /// name, a query. Truncating the end (the obvious choice) makes
    /// `/v1/orders/1001` and `/v1/orders/1002` render identically, which is
    /// the one thing a list of saved sessions must never do.
    ///
    /// A result is never longer than `limit`: the ellipsis is paid for out of
    /// the budget, not added to it.
    public static func shortenedPath(_ path: String, limit: Int = maxTitlePathLength) -> String {
        guard limit > 1 else { return path.count <= limit ? path : "…" }
        guard path.count > limit else { return path }
        let available = limit - 1
        let tail = available / 2
        let head = available - tail
        return String(path.prefix(head)) + "…" + String(path.suffix(tail))
    }

    /// `999 bytes`, `1 KB`, `1.2 MB` — decimal units, the same ones Finder
    /// reports a file size in, so what Settings says matches what the user
    /// sees if they go and look.
    public static func byteSizeText(_ bytes: Int64) -> String {
        // A negative total can only be a bug upstream; reporting it as
        // "-1 KB" would spread that bug into the UI.
        let value = max(0, bytes)
        guard value >= 1000 else { return value == 1 ? "1 byte" : "\(value) bytes" }
        let units = ["KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = units[0]
        for candidate in units {
            amount /= 1000
            unit = candidate
            // 999.95 and not 1000: the value is printed to one decimal, so
            // anything above that rounds to "1000.0 KB" — a size no file
            // manager has ever shown. It belongs in the next unit.
            if amount < 999.95 { break }
        }
        // `String(format:)` with no locale writes "1.2", never "1,2" — see
        // the locale note at the top of this file.
        let text = String(format: "%.1f", amount)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + " " + unit
    }

    /// `just now`, `2 minutes ago`, `yesterday`, `3 days ago`.
    ///
    /// Relative all the way up rather than falling back to a formatted date:
    /// an absolute date would be the one locale-dependent string in an
    /// otherwise stable set, and "4 months ago" answers the only question a
    /// saved session's age is actually asked ("is this still current?").
    ///
    /// A date in the future reads as `just now`. Clocks move backwards (NTP,
    /// a timezone change, a row written by another process), and "in 2
    /// minutes" next to a row the user just saved reads as a bug.
    public static func relativeAge(of date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return plural(Int(seconds), "second") }
        if seconds < 3600 { return plural(Int(seconds / 60), "minute") }
        if calendar.isDate(date, inSameDayAs: now) { return plural(Int(seconds / 3600), "hour") }
        // Yesterday RELATIVE TO `now`, not to the system clock.
        // `calendar.isDateInYesterday` asks what today is, which quietly made
        // this function ignore the clock it was handed — the tests passed only
        // on the day they were written and started failing at midnight.
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        let days = Int(seconds / 86_400)
        if days < 7 { return plural(max(1, days), "day") }
        if days < 35 { return plural(days / 7, "week") }
        if days < 365 { return plural(max(1, days / 30), "month") }
        return plural(max(1, days / 365), "year")
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s") ago"
    }

    // MARK: - The whole store, in one sentence

    /// What Settings says about everything saved: `12 saved sessions, using
    /// 1.2 MB.`
    ///
    /// The count comes first because it is what a user is deciding about; the
    /// size is there because deleting them all is the button underneath, and
    /// nobody should have to guess what that frees.
    public static func storageSentence(count: Int, byteSize: Int64) -> String {
        guard count > 0 else { return "No saved sessions." }
        let sessions = count == 1 ? "1 saved session" : "\(count) saved sessions"
        return "\(sessions), using \(byteSizeText(byteSize))."
    }
}
