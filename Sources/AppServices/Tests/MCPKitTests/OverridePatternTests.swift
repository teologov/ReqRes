//
//  OverridePatternTests.swift
//  ReqRes
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
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

final class OverridePatternTests: XCTestCase {

    // MARK: - Stored path

    func testWildcardPathGainsALeadingSlashAndKeepsItsQuery() {
        XCTAssertEqual(OverridePattern.storedPath("path?*", isRegex: false), "/path?*")
        XCTAssertEqual(OverridePattern.storedPath("/api/*", isRegex: false), "/api/*")
        XCTAssertEqual(OverridePattern.storedPath(" /items?id=* ", isRegex: false), "/items?id=*")
    }

    func testWildcardPathUnderAnyHostIsNeverEmpty() {
        // The bug: "All traffic" overrides were built as "https://All traffic/…",
        // failed to parse, and were saved with "".
        XCTAssertEqual(OverridePattern.storedPath("test", isRegex: false), "/test")
        XCTAssertEqual(OverridePattern.storedPath("", isRegex: false), "/")
    }

    /// A space reaches the wire percent-encoded, and the proxy matches the raw
    /// URI — so the stored pattern encodes it too.
    func testWildcardPathIsEncodedTheWayTheWireCarriesIt() {
        XCTAssertEqual(OverridePattern.storedPath("/a b/*", isRegex: false), "/a%20b/*")
    }

    /// The proxy compares against the RAW request URI, so the stored pattern
    /// must keep its percent-encoding.
    func testWildcardPathKeepsPercentEncoding() {
        XCTAssertEqual(OverridePattern.storedPath("/files/my%20doc.pdf", isRegex: false), "/files/my%20doc.pdf")
        XCTAssertEqual(OverridePattern.storedPath("/search?q=a%2Bb", isRegex: false), "/search?q=a%2Bb")
    }

    func testRegexIsStoredVerbatim() {
        XCTAssertEqual(OverridePattern.storedPath("^/api/.*$", isRegex: true), "^/api/.*$")
        XCTAssertEqual(OverridePattern.storedPath(" ^/users/\\d+$ ", isRegex: true), "^/users/\\d+$")
    }

    // MARK: - Displayed pattern

    func testDisplayedPatternIsWhatTheProxyCompiles() {
        XCTAssertEqual(OverridePattern.displayed(scheme: "https", host: "api.example.com", path: "/users?*"), "https://api.example.com/users?*")
        XCTAssertEqual(OverridePattern.displayed(scheme: "HTTP", host: "api.example.com", path: "/users"), "http://api.example.com/users")
        XCTAssertEqual(OverridePattern.displayed(scheme: "https", host: nil, path: " /users?* "), "/users?*")
        XCTAssertEqual(OverridePattern.proxyPattern(scheme: "https", host: "a.com", path: "/x"), "https://a.com/x")
    }

    // MARK: - Matching (the proxy's algorithm, per XReqResCore's matchRule)

    private let url = "https://api.example.com/users?id=1"

    func testWildcardStarMatchesAnyRunIncludingNone() {
        XCTAssertTrue(OverridePattern.matches(url: url, path: "/users?*", isRegex: false))
        XCTAssertTrue(OverridePattern.matches(url: url, path: "/*", isRegex: false))
        XCTAssertTrue(OverridePattern.matches(url: "https://api.example.com/users", path: "/users*", isRegex: false))
        XCTAssertFalse(OverridePattern.matches(url: url, path: "/orders*", isRegex: false))
    }

    func testWildcardOtherCharactersAreLiteral() {
        XCTAssertFalse(OverridePattern.matches(url: url, path: "/users?id=.", isRegex: false), "a dot is not a wildcard")
        XCTAssertTrue(OverridePattern.matches(url: url, path: "/users?id=1", isRegex: false))
    }

    /// The pattern the proxy compiles carries the host, so a host written into
    /// the path is matched twice and can never fire.
    func testAHostInsideThePathNeverMatches() {
        XCTAssertFalse(OverridePattern.matches(url: url, path: "/api.example.com/users?*", isRegex: false))
        XCTAssertFalse(OverridePattern.matches(url: url, path: "/https://api.example.com/users", isRegex: false))
    }

    /// A regex path is compiled as `scheme://host + path` and SEARCHED for, so
    /// a leading ^ would have to anchor mid-string.
    func testRegexLeadingCaretNeverMatchesJustAsInTheProxy() {
        XCTAssertFalse(OverridePattern.matches(url: "https://api.example.com/users/42", path: "^/users/\\d+$", isRegex: true))
        XCTAssertTrue(OverridePattern.matches(url: "https://api.example.com/users/42", path: "/users/\\d+$", isRegex: true))
        XCTAssertFalse(OverridePattern.matches(url: "https://api.example.com/users/abc", path: "/users/\\d+$", isRegex: true))
    }

    func testRegexIsUnanchoredSoASubstringPathMatches() {
        XCTAssertTrue(OverridePattern.matches(url: url, path: "/users", isRegex: true))
        XCTAssertTrue(OverridePattern.matches(url: url, path: "/users\\?id=\\d", isRegex: true))
    }

    /// Since core ef40bdf (C5) plain HTTP runs on the HTTPS exchange engine
    /// and matches the origin-form URI WITH its query, exactly like HTTPS.
    /// Replaces `testOverPlainHttpTheQueryIsNotMatched`, which pinned the old
    /// pathname-only matcher; each assertion below is its inverse.
    func testOverPlainHttpTheQueryIsMatchedLikeHTTPS() {
        XCTAssertTrue(OverridePattern.matches(url: "http://api.example.com/search?q=x", path: "/search?q=*", isRegex: false),
                      "a pattern with a query now matches plain http://")
        XCTAssertFalse(OverridePattern.matches(url: "http://api.example.com/search?q=x", path: "/search", isRegex: false),
                       "an anchored path without the query no longer covers ?q=x over http:// — it never did over https://")
        XCTAssertTrue(OverridePattern.matches(url: "https://api.example.com/search?q=x", path: "/search?q=*", isRegex: false), "https keeps the query")
        XCTAssertFalse(OverridePattern.matches(url: "https://api.example.com/search?q=x", path: "/search", isRegex: false))
        XCTAssertTrue(OverridePattern.matches(url: "http://api.example.com/search", path: "/search", isRegex: false), "no query, exact path: still a match")
        XCTAssertTrue(OverridePattern.matches(url: "http://api.example.com/search?q=x", path: "/search\\?q=x$", isRegex: true), "regex sees the query too")
    }

    /// `mock_from_session`'s derived path keeps the query on plain HTTP too;
    /// the app used to drop it for http://, which since C5 would make a mock
    /// miss the request it was made from.
    func testTheMockPathKeepsTheQueryOnBothSchemesAndMatchesItsOwnRequest() {
        for url in ["http://api.example.com/search?q=a%20b", "https://api.example.com/search?q=a%20b"] {
            let path = OverridePattern.derivedPath(fromCapturedURL: url)
            XCTAssertEqual(path, "/search?q=a%20b", url)
            XCTAssertTrue(OverridePattern.matches(url: url, path: path, isRegex: false), url)
        }
        XCTAssertEqual(OverridePattern.derivedPath(fromCapturedURL: "http://api.example.com"), "/")
    }

    func testSchemeAndHostBothTakePart() {
        XCTAssertTrue(OverridePattern.matches(url: "http://api.example.com/users?id=1", path: "/users?*", isRegex: false),
                      "the same path under http keeps its query now, so this wildcard matches")
        XCTAssertTrue(OverridePattern.matches(url: "http://api.example.com/users", path: "/users", isRegex: false))
        XCTAssertFalse(OverridePattern.matches(url: "https://other.org/users?id=1", path: "/users?id=1", isRegex: false) == false,
                       "a different host still matches a path-only pattern — the host is on both sides")
    }

    func testInvalidRegexEmptyInputsAndNonUrlsMatchNothing() {
        XCTAssertFalse(OverridePattern.matches(url: url, path: "^(/users", isRegex: true))
        XCTAssertFalse(OverridePattern.matches(url: url, path: "", isRegex: false))
        XCTAssertFalse(OverridePattern.matches(url: "   ", path: "/users*", isRegex: false))
        XCTAssertFalse(OverridePattern.matches(url: "/users?id=1", path: "/users?*", isRegex: false), "a bare path is not a URL")
    }
}
