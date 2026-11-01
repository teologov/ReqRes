//
//  TrafficSearchFilterTests.swift
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
@testable import Utils

final class TrafficSearchFilterTests: XCTestCase {

    // MARK: - Prefix parsing

    func testHostPrefixIsRecognisedCaseInsensitivelyWithSurroundingWhitespace() {
        let parsed = TrafficSearchTokenKind.parse("  Host: api.Example.com ")
        XCTAssertEqual(parsed?.kind, .host)
        XCTAssertEqual(parsed?.query, "api.Example.com")
    }

    func testBarePrefixHasAnEmptyQuery() {
        let parsed = TrafficSearchTokenKind.parse("host:")
        XCTAssertEqual(parsed?.kind, .host)
        XCTAssertEqual(parsed?.query, "")
    }

    func testFreeTextIsNotAToken() {
        XCTAssertNil(TrafficSearchTokenKind.parse("hostname"))
        XCTAssertNil(TrafficSearchTokenKind.parse("/api/users"))
        XCTAssertNil(TrafficSearchTokenKind.parse(""))
    }

    // MARK: - Tokens

    func testTokenIdentityIgnoresCaseButDisplayKeepsIt() {
        let token = TrafficSearchToken.host("API.example.com")
        XCTAssertEqual(token.id, TrafficSearchToken.host("api.example.com").id)
        XCTAssertEqual(token.displayName, "API.example.com")
        XCTAssertEqual(token.kind, .host)
    }

    // MARK: - Filter editing

    func testAddingTheSameHostTwiceKeepsOneChip() {
        var filter = TrafficSearchFilter()
        filter.addToken(.host("api.example.com"))
        filter.addToken(.host("API.EXAMPLE.COM"))
        filter.addToken(.host("  api.example.com "))
        XCTAssertEqual(filter.hosts, ["api.example.com"])
        XCTAssertEqual(filter.tokens, [.host("api.example.com")])
    }

    func testBlankHostIsNeverCommitted() {
        var filter = TrafficSearchFilter()
        filter.addToken(.host("   "))
        XCTAssertTrue(filter.isEmpty)
    }

    func testRemovingAHostIsCaseInsensitive() {
        var filter = TrafficSearchFilter(hosts: ["a.com", "b.com"])
        filter.removeToken(.host("A.COM"))
        XCTAssertEqual(filter.hosts, ["b.com"])
    }

    func testClearDropsTextAndTokens() {
        var filter = TrafficSearchFilter(freeText: "users", hosts: ["a.com"])
        filter.clear()
        XCTAssertTrue(filter.isEmpty)
    }

    func testWhitespaceOnlyFreeTextCountsAsEmpty() {
        XCTAssertTrue(TrafficSearchFilter(freeText: "   ").isEmpty)
        XCTAssertFalse(TrafficSearchFilter(freeText: " x ").isEmpty)
        XCTAssertFalse(TrafficSearchFilter(hosts: ["a.com"]).isEmpty)
        XCTAssertTrue(TrafficSearchFilter(hosts: ["a.com"]).hasTokens)
    }

    // MARK: - Matching

    private func matches(_ filter: TrafficSearchFilter,
                         host: String = "api.example.com",
                         url: String = "https://api.example.com/users?id=1",
                         method: String = "GET",
                         status: String? = "200") -> Bool {
        // No attribution in these tests: they predate the App column, and a
        // filter without an `app:`/`pid:` chip must answer the same for nil.
        filter.matches(host: host, url: url, method: method, status: status, app: nil, pid: nil, country: nil, outcome: nil, grpcStatus: nil, proto: nil)
    }

    func testEmptyFilterMatchesEverything() {
        XCTAssertTrue(matches(TrafficSearchFilter()))
        XCTAssertTrue(matches(TrafficSearchFilter(), status: nil))
    }

    func testHostTokenIsAnExactCaseInsensitiveMatch() {
        let filter = TrafficSearchFilter(hosts: ["API.example.com"])
        XCTAssertTrue(matches(filter, host: "api.example.com"))
        XCTAssertFalse(matches(filter, host: "cdn.api.example.com"), "a subdomain is a different host")
        XCTAssertFalse(matches(filter, host: "example.com"))
    }

    func testSeveralHostTokensAreOrEd() {
        let filter = TrafficSearchFilter(hosts: ["a.com", "b.com"])
        XCTAssertTrue(matches(filter, host: "a.com"))
        XCTAssertTrue(matches(filter, host: "b.com"))
        XCTAssertFalse(matches(filter, host: "c.com"))
    }

    func testFreeTextMatchesUrlMethodStatusOrHostAsASubstring() {
        XCTAssertTrue(matches(TrafficSearchFilter(freeText: "USERS")), "url, case-insensitive")
        XCTAssertTrue(matches(TrafficSearchFilter(freeText: "get")), "method")
        XCTAssertTrue(matches(TrafficSearchFilter(freeText: "20")), "status")
        XCTAssertTrue(matches(TrafficSearchFilter(freeText: "example")), "host")
        XCTAssertFalse(matches(TrafficSearchFilter(freeText: "orders")))
        XCTAssertFalse(matches(TrafficSearchFilter(freeText: "200"), status: nil), "no status to match")
    }

    func testHostTokenAndFreeTextAreAndEd() {
        let filter = TrafficSearchFilter(freeText: "users", hosts: ["api.example.com"])
        XCTAssertTrue(matches(filter))
        XCTAssertFalse(matches(filter, host: "other.com"), "right text, wrong host")
        XCTAssertFalse(matches(filter, url: "https://api.example.com/orders"), "right host, wrong text")
    }

    // MARK: - Suggestions

    private let candidates = ["api.example.com", "cdn.example.com", "example.com", "static.other.org", "Api.Example.com"]

    func testEmptyQueryOffersTheLeadingCandidatesInOrder() {
        let hosts = TrafficSearchSuggestions.hosts(matching: "", in: candidates, excluding: [], limit: 3)
        XCTAssertEqual(hosts, ["api.example.com", "cdn.example.com", "example.com"])
    }

    func testPrefixMatchesComeBeforeSubstringMatchesEachKeepingCandidateOrder() {
        let hosts = TrafficSearchSuggestions.hosts(matching: "ex", in: candidates, excluding: [])
        XCTAssertEqual(hosts, ["example.com", "api.example.com", "cdn.example.com"])
    }

    func testCommittedHostsAndDuplicatesAreExcluded() {
        let hosts = TrafficSearchSuggestions.hosts(matching: "api", in: candidates, excluding: ["API.EXAMPLE.COM"])
        XCTAssertEqual(hosts, [], "the only api host is already a chip (in another case)")
        let all = TrafficSearchSuggestions.hosts(matching: "", in: candidates, excluding: [])
        XCTAssertEqual(all.count, 4, "Api.Example.com collapses into api.example.com")
    }

    func testQueryIsCaseInsensitiveAndTrimmed() {
        let hosts = TrafficSearchSuggestions.hosts(matching: "  CDN ", in: candidates, excluding: [])
        XCTAssertEqual(hosts, ["cdn.example.com"])
    }

    func testLimitIsRespected() {
        let hosts = TrafficSearchSuggestions.hosts(matching: "", in: candidates, excluding: [], limit: 1)
        XCTAssertEqual(hosts, ["api.example.com"])
        XCTAssertEqual(TrafficSearchSuggestions.hosts(matching: "", in: candidates, excluding: [], limit: 0), [])
    }
}
