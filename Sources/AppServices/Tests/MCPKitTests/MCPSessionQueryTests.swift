//
//  MCPSessionQueryTests.swift
//  AppServices
//
//  Created by OloApps on 8/26/26.
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

import XCTest
@testable import MCPKit

final class MCPSessionQueryTests: XCTestCase {
    func testPagesAreNewestFirst() {
        let sessions = (1...5).map { makeSession(uid: "s\($0)") }
        let page = MCPSessionQuery.page(from: sessions)
        XCTAssertEqual(page.sessions.map(\.uid), ["s5", "s4", "s3", "s2", "s1"])
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.totalMatched, 5)
        XCTAssertNil(page.note)
    }

    func testCursorWalksTheWholeSetWithoutOverlap() {
        let sessions = (1...7).map { makeSession(uid: "s\($0)") }
        var collected: [String] = []
        var cursor: String?
        repeat {
            let page = MCPSessionQuery.page(from: sessions, limit: 3, cursor: cursor)
            collected += page.sessions.map(\.uid)
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(collected, ["s7", "s6", "s5", "s4", "s3", "s2", "s1"])
    }

    func testPartialPageCarriesNoteAndCursor() {
        let sessions = (1...10).map { makeSession(uid: "s\($0)") }
        let page = MCPSessionQuery.page(from: sessions, limit: 4)
        XCTAssertEqual(page.sessions.count, 4)
        XCTAssertEqual(page.nextCursor, "s7")
        XCTAssertNotNil(page.note)
        XCTAssertTrue(page.note?.contains("6 more") ?? false)
    }

    func testVanishedCursorRestartsFromTheTop() {
        let sessions = (1...3).map { makeSession(uid: "s\($0)") }
        let page = MCPSessionQuery.page(from: sessions, cursor: "gone")
        XCTAssertEqual(page.sessions.first?.uid, "s3")
    }

    func testLimitIsClamped() {
        let sessions = (1...200).map { makeSession(uid: "s\($0)") }
        let tooBig = MCPSessionQuery.page(from: sessions, limit: 5000)
        XCTAssertEqual(tooBig.sessions.count, MCPLimits.maxPageSize)
        let tooSmall = MCPSessionQuery.page(from: sessions, limit: 0)
        XCTAssertEqual(tooSmall.sessions.count, 1)
    }

    func testFilterByHostMethodAndStatusClass() {
        let sessions = [
            makeSession(uid: "a", host: "api.example.com", method: "GET", statusCode: 200),
            makeSession(uid: "b", host: "cdn.example.com", method: "GET", statusCode: 404),
            makeSession(uid: "c", host: "api.example.com", method: "POST", statusCode: 500),
            makeSession(uid: "d", host: "api.example.com", method: "get", statusCode: 201),
        ]
        let hostPage = MCPSessionQuery.page(from: sessions, filter: MCPSessionFilter(host: "API.example"))
        XCTAssertEqual(hostPage.sessions.map(\.uid).sorted(), ["a", "c", "d"])

        let methodPage = MCPSessionQuery.page(from: sessions, filter: MCPSessionFilter(method: "GET"))
        XCTAssertEqual(methodPage.sessions.map(\.uid).sorted(), ["a", "b", "d"])

        let classPage = MCPSessionQuery.page(from: sessions, filter: MCPSessionFilter(status: "2xx"))
        XCTAssertEqual(classPage.sessions.map(\.uid).sorted(), ["a", "d"])

        let exactPage = MCPSessionQuery.page(from: sessions, filter: MCPSessionFilter(status: "404"))
        XCTAssertEqual(exactPage.sessions.map(\.uid), ["b"])
    }

    func testFilterFromQueryItems() throws {
        let items = [
            URLQueryItem(name: "host", value: "example.com"),
            URLQueryItem(name: "status", value: "5xx"),
            URLQueryItem(name: "url_contains", value: "/login"),
            URLQueryItem(name: "app", value: "claude"),
            URLQueryItem(name: "pid", value: "9437"),
            URLQueryItem(name: "ignored", value: "x"),
        ]
        let filter = try MCPSessionFilter(queryItems: items)
        XCTAssertEqual(filter.host, "example.com")
        XCTAssertEqual(filter.status, "5xx")
        XCTAssertEqual(filter.urlContains, "/login")
        XCTAssertEqual(filter.app, "claude")
        XCTAssertEqual(filter.pid, 9437)
        XCTAssertNil(filter.method)
    }

    /// A non-numeric pid is REFUSED, not dropped — the same rule the stdio
    /// helper applies (`ReqResMCPServer.optionalPid`), now at the bridge too,
    /// for anything that speaks HTTP to it. A dropped filter would hand back
    /// an unfiltered page that reads as "no sessions from curl". The router
    /// turns this error into a 400 (`MCPBridgeRouterTests`).
    func testANonNumericPidInTheQueryStringIsRefused() {
        XCTAssertThrowsError(try MCPSessionFilter(queryItems: [URLQueryItem(name: "pid", value: "curl")])) { error in
            let refused = error as? MCPQueryParameterError
            XCTAssertEqual(refused?.parameter, "pid")
            XCTAssertTrue(refused?.message.contains("'pid' must be an integer") == true, refused?.message ?? "")
            XCTAssertTrue(refused?.message.contains("app") == true, "the message names the filter the agent probably meant")
        }
        // A numeric string with surrounding whitespace is still a pid; an
        // empty value is no filter at all (like every other empty parameter).
        XCTAssertEqual(try MCPSessionFilter(queryItems: [URLQueryItem(name: "pid", value: " 9437 ")]).pid, 9437)
        XCTAssertNil(try MCPSessionFilter(queryItems: [URLQueryItem(name: "pid", value: "")]).pid)
    }

    // MARK: - Attribution

    /// "claude" has to find the Claude app AND the claude-code CLI: the name is
    /// whatever the executable or bundle is called, and an agent does not know
    /// which spelling the capture layer saw.
    func testFilterByAppIsACaseInsensitiveSubstring() {
        let sessions = [
            makeSession(uid: "a", app: "Claude"),
            makeSession(uid: "b", app: "claude-code"),
            makeSession(uid: "c", app: "Safari"),
            makeSession(uid: "d", app: nil),
        ]
        let page = MCPSessionQuery.page(from: sessions, filter: MCPSessionFilter(app: "claude"))
        XCTAssertEqual(page.sessions.map(\.uid).sorted(), ["a", "b"])
    }

    /// An unattributed session is not "the app the agent asked for". Excluding
    /// it is correct now that the field is populated — the reason this filter
    /// was once removed was that NOTHING populated it, so every page was empty.
    func testFilterByAppExcludesUnattributedSessions() {
        let sessions = [
            makeSession(uid: "attributed", app: "curl"),
            makeSession(uid: "unknown", app: nil),
        ]
        let page = MCPSessionQuery.page(from: sessions, filter: MCPSessionFilter(app: "curl"))
        XCTAssertEqual(page.sessions.map(\.uid), ["attributed"])
        XCTAssertEqual(page.totalMatched, 1)
    }

    /// Three `claude` processes on one Mac is ordinary; the pid is what
    /// separates them, so it matches exactly and never as a substring.
    func testFilterByPidIsExact() {
        let sessions = [
            makeSession(uid: "a", app: "claude", pid: 9437),
            makeSession(uid: "b", app: "claude", pid: 94371),
            makeSession(uid: "c", app: "claude", pid: nil),
        ]
        let page = MCPSessionQuery.page(from: sessions, filter: MCPSessionFilter(pid: 9437))
        XCTAssertEqual(page.sessions.map(\.uid), ["a"])
    }

    func testAppAndPidCombineWithTheOtherFilters() {
        let sessions = [
            makeSession(uid: "a", host: "api.anthropic.com", statusCode: 200, app: "claude", pid: 1),
            makeSession(uid: "b", host: "api.anthropic.com", statusCode: 500, app: "claude", pid: 2),
            makeSession(uid: "c", host: "api.example.com", statusCode: 500, app: "claude", pid: 1),
        ]
        let page = MCPSessionQuery.page(
            from: sessions,
            filter: MCPSessionFilter(host: "anthropic", status: "5xx", app: "claude", pid: 2)
        )
        XCTAssertEqual(page.sessions.map(\.uid), ["b"])
    }

    func testCappedPreviewMarksTruncation() {
        let short = MCPSessionQuery.cappedPreview("hello")
        XCTAssertEqual(short.preview, "hello")
        XCTAssertFalse(short.truncated)

        let long = String(repeating: "a", count: MCPLimits.bodyPreviewMaxBytes + 100)
        let capped = MCPSessionQuery.cappedPreview(long)
        XCTAssertTrue(capped.truncated)
        XCTAssertTrue(capped.preview?.hasSuffix(MCPLimits.truncationMarker) ?? false)
        XCTAssertLessThan(capped.preview?.utf8.count ?? 0, long.utf8.count)

        let none = MCPSessionQuery.cappedPreview(nil)
        XCTAssertNil(none.preview)
        XCTAssertFalse(none.truncated)
    }

    // MARK: - Destination (destination-map UX spec §8.2)

    func testCountryFromTheQueryStringIsNormalised() throws {
        XCTAssertEqual(try MCPSessionFilter(queryItems: [URLQueryItem(name: "country", value: "us")]).country, "US")
        XCTAssertEqual(try MCPSessionFilter(queryItems: [URLQueryItem(name: "country", value: " De ")]).country, "DE")
        XCTAssertEqual(try MCPSessionFilter(queryItems: [URLQueryItem(name: "country", value: "MAC")]).country, "mac")
        XCTAssertEqual(try MCPSessionFilter(queryItems: [URLQueryItem(name: "country", value: "Local")]).country, "local")
        XCTAssertEqual(try MCPSessionFilter(queryItems: [URLQueryItem(name: "country", value: "unknown")]).country, "unknown")
        XCTAssertNil(try MCPSessionFilter(queryItems: [URLQueryItem(name: "country", value: "")]).country, "an empty value is no filter at all")
    }

    /// A name, or anything else that is neither a code nor a class word, is
    /// REFUSED with the message that says what to send instead — the `pid`
    /// precedent. A dropped filter would answer "where does claude send data
    /// in Germany" with every country.
    func testANameOrNonsenseCountryIsRefused() {
        for value in ["Germany", "USA", "u1", "this_mac", "localhost"] {
            XCTAssertThrowsError(try MCPSessionFilter(queryItems: [URLQueryItem(name: "country", value: value)]), value) { error in
                let refused = error as? MCPQueryParameterError
                XCTAssertEqual(refused?.parameter, "country")
                XCTAssertEqual(
                    refused?.message,
                    "'country' must be a two-letter ISO code (US), or local, mac or unknown — got '\(value)'. Names are not accepted; codes are."
                )
            }
        }
    }

    func testFilterByCountryComparesTheTokenExactly() {
        let sessions = [
            makeSession(uid: "a", country: "US"),
            makeSession(uid: "b", country: "DE"),
            makeSession(uid: "c", country: "mac"),
            makeSession(uid: "d", country: "local"),
            makeSession(uid: "e", country: nil),
        ]
        func uids(_ filter: MCPSessionFilter) -> [String] { sessions.filter(filter.matches).map(\.uid) }
        XCTAssertEqual(uids(MCPSessionFilter(country: "US")), ["a"])
        XCTAssertEqual(uids(MCPSessionFilter(country: "us")), ["a"], "a hand-built filter is normalised like a parsed one")
        XCTAssertEqual(uids(MCPSessionFilter(country: "mac")), ["c"])
        XCTAssertEqual(uids(MCPSessionFilter(country: "local")), ["d"])
        XCTAssertEqual(uids(MCPSessionFilter(country: "unknown")), ["e"], "unknown selects the sessions whose country is nil")
        XCTAssertEqual(uids(MCPSessionFilter(country: "Germany")), [], "a value that is not a token matches nothing")
        XCTAssertEqual(uids(MCPSessionFilter()).count, 5)
    }

    func testCountryIsANDedWithTheOtherFilters() {
        let sessions = [
            makeSession(uid: "a", app: "claude", country: "US"),
            makeSession(uid: "b", app: "claude", country: "DE"),
            makeSession(uid: "c", app: "Safari", country: "US"),
        ]
        XCTAssertEqual(sessions.filter(MCPSessionFilter(app: "claude", country: "US").matches).map(\.uid), ["a"])
    }

    /// The `list_destinations` heading echoes the filter as the agent sent
    /// it, so a report for `app=claude` cannot be mistaken for all traffic.
    func testSummaryTextEchoesTheFilterAsSent() {
        XCTAssertNil(MCPSessionFilter().summaryText)
        XCTAssertEqual(MCPSessionFilter(app: "claude").summaryText, "app=claude")
        XCTAssertEqual(
            MCPSessionFilter(host: "api", app: "claude", pid: 9437, country: "DE").summaryText,
            "host=api, app=claude, pid=9437, country=DE"
        )
    }
}
