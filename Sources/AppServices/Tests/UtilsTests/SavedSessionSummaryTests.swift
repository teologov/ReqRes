//
//  SavedSessionSummaryTests.swift
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
//  These pin the strings a user reads in the saved-sessions list AND the
//  strings an agent reads back over MCP — one formatter serves both, so a
//  change here changes both at once, which is the point.
//
//  Every time-dependent case injects `now` and a fixed UTC calendar: a test
//  that reads the machine's clock or region passes in the morning and fails
//  in the evening, and this suite runs on whatever machine picks the branch
//  up next.
//

import XCTest
@testable import Utils

final class SavedSessionSummaryTests: XCTestCase {
    /// Fixed, UTC, Gregorian — "yesterday" is a calendar question, and the
    /// answer must not depend on where the test runs.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date(2026, 9, 21, 12) }

    private func summary(
        method: String = "GET",
        host: String = "api.example.com",
        uri: String = "/v1/orders",
        status: String? = "200",
        capturedAt: Date? = nil,
        savedAt: Date? = nil,
        byteSize: Int64? = nil
    ) -> SavedSessionSummary {
        SavedSessionSummary(
            method: method,
            host: host,
            uri: uri,
            status: status,
            capturedAt: capturedAt,
            savedAt: savedAt ?? now,
            byteSize: byteSize
        )
    }

    // MARK: - Title

    func testTheTitleIsMethodHostAndPath() {
        XCTAssertEqual(summary(method: "get").title, "GET api.example.com/v1/orders")
    }

    /// A request to the site root is a real request; `GET example.com` with
    /// nothing after it reads as a value that failed to load.
    func testAnEmptyPathShowsAsTheRoot() {
        XCTAssertEqual(summary(uri: "").title, "GET api.example.com/")
        XCTAssertEqual(summary(uri: "   ").title, "GET api.example.com/")
        XCTAssertEqual(summary(uri: "/").title, "GET api.example.com/")
        XCTAssertEqual(summary(uri: "https://api.example.com").title, "GET api.example.com/")
    }

    /// Over plain HTTP the core records an absolute URI. Without stripping it
    /// the row would name its host twice, and HTTP rows would not look like
    /// HTTPS rows in the same list.
    func testAnAbsoluteURIKeepsItsQueryAndLosesItsHost() {
        let summary = summary(uri: "http://api.example.com/v1/orders?page=2&sort=asc")

        XCTAssertEqual(summary.path, "/v1/orders?page=2&sort=asc")
        XCTAssertEqual(summary.title, "GET api.example.com/v1/orders?page=2&sort=asc")
    }

    func testAPathWithoutALeadingSlashGetsOneSoItCannotGlueOntoTheHost() {
        XCTAssertEqual(summary(uri: "v1/orders").title, "GET api.example.com/v1/orders")
    }

    func testAMissingHostOrMethodLeavesNoStrayWhitespace() {
        XCTAssertEqual(summary(method: "", host: "").title, "/v1/orders")
        XCTAssertEqual(summary(method: "", uri: "/x").title, "api.example.com/x")
    }

    // MARK: - Path shortening

    func testAPathIsKeptWholeUpToTheLimitAndCutOneCharacterLater() {
        let exact = "/" + String(repeating: "a", count: SavedSessionSummary.maxTitlePathLength - 1)
        XCTAssertEqual(exact.count, SavedSessionSummary.maxTitlePathLength)
        XCTAssertEqual(SavedSessionSummary.shortenedPath(exact), exact, "at the limit nothing is cut")

        let overLimit = exact + "b"
        let shortened = SavedSessionSummary.shortenedPath(overLimit)
        XCTAssertNotEqual(shortened, overLimit)
        XCTAssertEqual(shortened.count, SavedSessionSummary.maxTitlePathLength,
                       "the ellipsis is paid for out of the budget, not added to it")
    }

    /// The reason the cut is in the middle: ids live at the end.
    func testTwoLongPathsThatDifferOnlyAtTheEndStayDistinguishable() {
        let base = "/v1/organisations/8f3b21c4/projects/deployments/logs/entries/"
        let first = SavedSessionSummary.shortenedPath(base + "1001")
        let second = SavedSessionSummary.shortenedPath(base + "1002")

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasSuffix("1001"))
        XCTAssertTrue(first.hasPrefix("/v1/organisations"))
        XCTAssertTrue(first.contains("…"))
    }

    func testAnAbsurdlySmallLimitStillReturnsSomething() {
        XCTAssertEqual(SavedSessionSummary.shortenedPath("/orders", limit: 1), "…")
        XCTAssertEqual(SavedSessionSummary.shortenedPath("/", limit: 1), "/")
    }

    // MARK: - Subtitle

    func testTheSubtitleCarriesStatusSizeAndBothTimes() {
        let summary = summary(
            capturedAt: date(2026, 9, 21, 11, 55),
            savedAt: now,
            byteSize: 12_000
        )

        XCTAssertEqual(summary.subtitle(now: now, calendar: calendar),
                       "200 · 12 KB · captured 5 minutes ago · saved just now")
    }

    /// A saved request with no response is usually exactly why it was saved.
    func testAMissingStatusIsSaidOutLoud() {
        XCTAssertTrue(summary(status: nil).subtitle(now: now, calendar: calendar).hasPrefix("No response"))
        XCTAssertTrue(summary(status: "  ").subtitle(now: now, calendar: calendar).hasPrefix("No response"))
    }

    func testCaptureTimeIsOmittedWhenUnknownButSaveTimeNeverIs() {
        let subtitle = summary(capturedAt: nil).subtitle(now: now, calendar: calendar)

        XCTAssertFalse(subtitle.contains("captured"))
        XCTAssertTrue(subtitle.contains("saved just now"))
    }

    /// Kept minutes after the traffic happened — the case that makes showing
    /// both times worth the width.
    func testAnOldSessionSavedNowShowsTwoDifferentAges() {
        let summary = summary(capturedAt: date(2026, 9, 21, 9), savedAt: now)

        XCTAssertEqual(summary.subtitle(now: now, calendar: calendar),
                       "200 · captured 3 hours ago · saved just now")
    }

    func testOneLineCarriesBothHalves() {
        let line = summary().oneLine(now: now, calendar: calendar)

        XCTAssertEqual(line, "GET api.example.com/v1/orders — 200 · saved just now")
    }

    // MARK: - Relative age

    func testSomethingSavedInTheSameSecondReadsAsJustNow() {
        XCTAssertEqual(SavedSessionSummary.relativeAge(of: now, now: now, calendar: calendar), "just now")
        XCTAssertEqual(SavedSessionSummary.relativeAge(of: now.addingTimeInterval(-4), now: now, calendar: calendar),
                       "just now")
    }

    /// Clocks move backwards (NTP, a timezone change). "in 2 minutes" on a
    /// row the user just saved reads as a bug in the app.
    func testAFutureDateReadsAsJustNowRatherThanCountingUp() {
        XCTAssertEqual(SavedSessionSummary.relativeAge(of: now.addingTimeInterval(600), now: now, calendar: calendar),
                       "just now")
    }

    func testTheUnitsAndTheirBoundaries() {
        let cases: [(TimeInterval, String)] = [
            (5, "5 seconds ago"),
            (59, "59 seconds ago"),
            (60, "1 minute ago"),
            (120, "2 minutes ago"),
            (3_599, "59 minutes ago"),
            (3_600, "1 hour ago"),
        ]

        for (seconds, expected) in cases {
            let age = SavedSessionSummary.relativeAge(of: now.addingTimeInterval(-seconds), now: now, calendar: calendar)
            XCTAssertEqual(age, expected, "\(seconds)s ago")
        }
    }

    func testDaysWeeksMonthsAndYears() {
        let cases: [(Date, String)] = [
            (date(2026, 9, 20, 18), "yesterday"),
            (date(2026, 9, 20, 1), "yesterday"),
            (date(2026, 9, 18, 12), "3 days ago"),
            (date(2026, 9, 11, 12), "1 week ago"),
            (date(2026, 8, 22, 12), "4 weeks ago"),
            (date(2026, 7, 21, 12), "2 months ago"),
            (date(2025, 9, 21, 12), "1 year ago"),
        ]

        for (saved, expected) in cases {
            XCTAssertEqual(SavedSessionSummary.relativeAge(of: saved, now: now, calendar: calendar), expected)
        }
    }

    /// Yesterday evening is only ~14 hours ago, which the hour branch would
    /// happily call "14 hours ago" on a different date. The day comparison
    /// has to win.
    func testYesterdayBeatsTheHourCount() {
        let lateYesterday = date(2026, 9, 20, 22)

        XCTAssertEqual(SavedSessionSummary.relativeAge(of: lateYesterday, now: now, calendar: calendar), "yesterday")
    }

    // MARK: - Sizes

    func testByteSizesAtTheirBoundaries() {
        let cases: [(Int64, String)] = [
            (0, "0 bytes"),
            (1, "1 byte"),
            (2, "2 bytes"),
            (999, "999 bytes"),
            (1_000, "1 KB"),
            (1_500, "1.5 KB"),
            (999_999, "1 MB"),
            (1_000_000, "1 MB"),
            (1_200_000, "1.2 MB"),
            (1_000_000_000, "1 GB"),
            (2_500_000_000_000, "2.5 TB"),
        ]

        for (bytes, expected) in cases {
            XCTAssertEqual(SavedSessionSummary.byteSizeText(bytes), expected, "\(bytes)")
        }
    }

    /// A negative total can only be a bug upstream; "-1 KB" would carry it
    /// into the window.
    func testANegativeSizeReadsAsNothing() {
        XCTAssertEqual(SavedSessionSummary.byteSizeText(-4_096), "0 bytes")
    }

    // MARK: - The settings sentence

    func testTheStorageSentenceCountsAndSizes() {
        XCTAssertEqual(SavedSessionSummary.storageSentence(count: 0, byteSize: 0), "No saved sessions.")
        XCTAssertEqual(SavedSessionSummary.storageSentence(count: 1, byteSize: 12_000),
                       "1 saved session, using 12 KB.")
        XCTAssertEqual(SavedSessionSummary.storageSentence(count: 24, byteSize: 1_200_000),
                       "24 saved sessions, using 1.2 MB.")
    }

    /// Saved sessions can be tiny; the sentence still has to say a size,
    /// because it sits above a button that deletes all of them.
    func testTheStorageSentenceStillReportsZeroBytesForRowsThatHaveNoBody() {
        XCTAssertEqual(SavedSessionSummary.storageSentence(count: 3, byteSize: 0),
                       "3 saved sessions, using 0 bytes.")
    }
}
