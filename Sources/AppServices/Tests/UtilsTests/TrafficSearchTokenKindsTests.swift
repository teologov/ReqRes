//
//  TrafficSearchTokenKindsTests.swift
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

import XCTest
@testable import Utils

final class TrafficSearchTokenKindsTests: XCTestCase {

    // MARK: - Prefix parsing, now on the one real token kind

    func testPrefixParsingRecognisesEveryKind() {
        // These prefixes used to be parsed by a second, duplicate parser that
        // shipped beside this one. Folding them in means a fix to prefix
        // handling has one home again.
        XCTAssertEqual(TrafficSearchTokenKind.parse("  Method: post ")?.kind, .method)
        XCTAssertEqual(TrafficSearchTokenKind.parse("  Method: post ")?.query, "post")
        XCTAssertEqual(TrafficSearchTokenKind.parse("STATUS:404")?.kind, .status)
        XCTAssertEqual(TrafficSearchTokenKind.parse("path:/v1/users")?.kind, .path)
        XCTAssertEqual(TrafficSearchTokenKind.parse("host:api.example.com")?.kind, .host)
    }

    func testPrefixParsingRejectsNearMisses() {
        XCTAssertNil(TrafficSearchTokenKind.parse("statuscode:200"),
                     "must match the prefix, not merely start with its letters")
        XCTAssertNil(TrafficSearchTokenKind.parse(""))
        XCTAssertNil(TrafficSearchTokenKind.parse("just free text"))
    }

    // MARK: - Status parsing: exact, class, range

    func testExactStatusCodeParses() {
        XCTAssertEqual(TrafficSearchStatusMatch.parse("404"), .exact(404))
        XCTAssertEqual(TrafficSearchStatusMatch.parse(" 200 "), .exact(200), "surrounding whitespace is trimmed")
    }

    func testStatusClassParsesToItsHundredRange() {
        XCTAssertEqual(TrafficSearchStatusMatch.parse("5xx"), .range(500...599))
        XCTAssertEqual(TrafficSearchStatusMatch.parse("2XX"), .range(200...299), "case-insensitive")
    }

    func testStatusRangeParses() {
        XCTAssertEqual(TrafficSearchStatusMatch.parse("400-499"), .range(400...499))
        XCTAssertEqual(TrafficSearchStatusMatch.parse("400 - 499"), .range(400...499), "spaces around the dash are tolerated")
    }

    // MARK: - Status parsing: the documented unparseable-input contract

    /// `TrafficSearchStatusMatch.parse` must return nil rather than a match
    /// that can never be true, so the caller falls back to free text.
    /// Enumerated rather than one test per case because they all assert the
    /// same contract and a table makes it obvious nothing was missed.
    func testUnparseableStatusQueriesReturnNilRatherThanAnAlwaysFalseMatch() {
        let unparseable = [
            "banana",           // not numeric, not an xx class
            "",                 // blank query, e.g. bare "status:"
            "99",               // below the valid HTTP status range
            "600",              // above the valid HTTP status range
            "6xx",              // not a real status class
            "500-400",          // backwards range
            "400-",             // missing upper bound
            "-499",             // missing lower bound
            "400-700",          // upper bound out of range
        ]
        for query in unparseable {
            XCTAssertNil(TrafficSearchStatusMatch.parse(query), "expected nil for '\(query)'")
        }
    }

    func testTokenParseRefusesAnUnparseableStatusSoItFallsBackToFreeText() {
        XCTAssertNil(TrafficSearchToken.parse(kind: .status, query: "banana"),
                     "the whole raw token text should be searched as free text instead of becoming a dead token")
        XCTAssertNotNil(TrafficSearchToken.parse(kind: .status, query: "404"))
    }

    func testTokenParseRefusesEmptyMethodOrPathQueries() {
        XCTAssertNil(TrafficSearchToken.parse(kind: .method, query: "  "))
        XCTAssertNil(TrafficSearchToken.parse(kind: .path, query: ""))
    }

    // MARK: - Status display text

    func testStatusDisplayTextShowsTheHundredsClassEvenForAnEquivalentTypedRange() {
        XCTAssertEqual(TrafficSearchStatusMatch.exact(404).displayText, "404")
        XCTAssertEqual(TrafficSearchStatusMatch.range(500...599).displayText, "5xx")
        XCTAssertEqual(TrafficSearchStatusMatch.range(400...499).displayText, "4xx",
                       "400-499 names exactly the 4xx class, so the chip collapses to the shorter spelling")
        XCTAssertEqual(TrafficSearchStatusMatch.range(400...450).displayText, "400-450",
                       "a range that is not a whole class keeps its typed bounds")
    }

    // MARK: - Token identity and display

    func testMethodTokenIdentityIgnoresCaseButDisplayIsUppercased() {
        let lower = TrafficSearchToken.method("get")
        let upper = TrafficSearchToken.method("GET")
        XCTAssertEqual(lower.id, upper.id)
        XCTAssertEqual(lower.displayName, "GET")
        XCTAssertEqual(lower.kind, .method)
    }

    func testPathTokenDisplayKeepsTypedCase() {
        let token = TrafficSearchToken.path("/Users")
        XCTAssertEqual(token.displayName, "/Users")
        XCTAssertEqual(token.kind, .path)
    }

    // MARK: - Single-token matching

    func testMethodTokenIsAnExactCaseInsensitiveMatch() {
        let token = TrafficSearchToken.method("get")
        XCTAssertTrue(token.matches(host: "api.example.com", url: "https://api.example.com/users", method: "GET", status: "200"))
        XCTAssertFalse(token.matches(host: "api.example.com", url: "https://api.example.com/users", method: "POST", status: "200"))
    }

    func testStatusTokenExactClassAndRangeMatching() {
        let exact = TrafficSearchToken.status(.exact(404))
        XCTAssertTrue(exact.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "404"))
        XCTAssertFalse(exact.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "400"))

        let fiveXX = TrafficSearchToken.status(.range(500...599))
        XCTAssertTrue(fiveXX.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "500"))
        XCTAssertTrue(fiveXX.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "599"))
        XCTAssertFalse(fiveXX.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "499"))
        XCTAssertFalse(fiveXX.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "600"))

        let range = TrafficSearchToken.status(.range(400...499))
        XCTAssertTrue(range.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "400"))
        XCTAssertTrue(range.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "499"))
        XCTAssertFalse(range.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "399"))
        XCTAssertFalse(range.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "500"))
    }

    func testStatusTokenNeverMatchesASessionWithNoNumericStatus() {
        let token = TrafficSearchToken.status(.exact(200))
        XCTAssertFalse(token.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: nil))
        XCTAssertFalse(token.matches(host: "api.example.com", url: "https://a.com", method: "GET", status: "pending"))
    }

    func testPathTokenIsACaseInsensitiveSubstringOfThePathOnly() {
        let token = TrafficSearchToken.path("/v1/users")
        XCTAssertTrue(token.matches(host: "api.example.com", url: "https://api.example.com/v1/users?id=1", method: "GET", status: "200"))
        XCTAssertTrue(TrafficSearchToken.path("USERS")
            .matches(host: "api.example.com", url: "https://api.example.com/v1/users", method: "GET", status: "200"), "case-insensitive")
        XCTAssertFalse(token.matches(host: "api.example.com", url: "https://api.example.com/v1/orders", method: "GET", status: "200"))
    }

    func testPathTokenDoesNotMatchTheHostOrTheQuery() {
        // "example" only appears in the host, and "id=1" only in the query —
        // neither is part of the path, so path: must not find them. Matching
        // the host here would duplicate what host: already does.
        let hostNeedle = TrafficSearchToken.path("example")
        XCTAssertFalse(hostNeedle.matches(host: "api.example.com", url: "https://api.example.com/v1/users?id=1", method: "GET", status: "200"))

        let queryNeedle = TrafficSearchToken.path("id=1")
        XCTAssertFalse(queryNeedle.matches(host: "api.example.com", url: "https://api.example.com/v1/users?id=1", method: "GET", status: "200"))
    }

    // MARK: - Path extraction

    func testPathExtractionDropsHostSchemeAndQuery() {
        XCTAssertEqual(TrafficSearchPath.extract(from: "https://api.example.com/v1/users?id=1"), "/v1/users")
        XCTAssertEqual(TrafficSearchPath.extract(from: "https://api.example.com"), "",
                       "a bare host has an empty path, and must not fall back to the full URL")
    }

    func testPathExtractionFallsBackToTheRawStringWhenItIsNotAUrlAtAll() {
        // A literal space is not valid in a URL string, so URLComponents
        // fails to parse it at all — that is the one case this falls back
        // for, distinct from a URL that legitimately has an empty path.
        XCTAssertEqual(TrafficSearchPath.extract(from: "not a url"), "not a url")
    }

    // MARK: - The real filter: OR within a kind, AND across kinds

    private func matches(
        _ filter: TrafficSearchFilter,
        host: String = "api.example.com",
        method: String = "GET",
        url: String = "https://api.example.com/v1/users?id=1",
        status: String? = "200"
    ) -> Bool {
        filter.matches(host: host, url: url, method: method, status: status, app: nil, pid: nil, country: nil, outcome: nil, grpcStatus: nil, proto: nil)
    }

    func testAnEmptyFilterMatchesEverything() {
        XCTAssertTrue(matches(TrafficSearchFilter()))
        XCTAssertTrue(matches(TrafficSearchFilter(), status: nil))
    }

    func testMethodTokenMatchesCaseInsensitively() {
        let filter = TrafficSearchFilter(methods: ["post"])
        XCTAssertTrue(matches(filter, method: "POST"))
        XCTAssertFalse(matches(filter, method: "GET"))
    }

    func testStatusTokenAcceptsExactClassAndRange() {
        XCTAssertTrue(matches(TrafficSearchFilter(statuses: [.exact(404)]), status: "404"))
        XCTAssertFalse(matches(TrafficSearchFilter(statuses: [.exact(404)]), status: "200"))
        XCTAssertTrue(matches(TrafficSearchFilter(statuses: [.range(500...599)]), status: "503"))
        XCTAssertFalse(matches(TrafficSearchFilter(statuses: [.range(500...599)]), status: "404"))
    }

    /// A request still in flight has no status. Showing it under a status
    /// token would be a quiet lie about what the filter did.
    func testAStatusTokenExcludesASessionWithNoStatusYet() {
        XCTAssertFalse(matches(TrafficSearchFilter(statuses: [.exact(200)]), status: nil))
        XCTAssertFalse(matches(TrafficSearchFilter(statuses: [.exact(200)]), status: ""))
    }

    /// Would have caught a `path:` implemented against the whole URL, where
    /// `path:api` would match every request to api.example.com.
    func testPathTokenMatchesThePathOnlyNotTheHost() {
        XCTAssertTrue(matches(TrafficSearchFilter(paths: ["/v1/users"])))
        XCTAssertFalse(
            matches(TrafficSearchFilter(paths: ["api.example"])),
            "the host must not satisfy a path token"
        )
    }

    func testTokensOfOneKindAreOred() {
        let filter = TrafficSearchFilter(methods: ["GET", "POST"])
        XCTAssertTrue(matches(filter, method: "GET"))
        XCTAssertTrue(matches(filter, method: "POST"))
        XCTAssertFalse(matches(filter, method: "DELETE"))
    }

    func testDifferentKindsAreAnded() {
        let filter = TrafficSearchFilter(methods: ["POST"], statuses: [.range(500...599)])
        XCTAssertTrue(matches(filter, method: "POST", status: "500"))
        XCTAssertFalse(matches(filter, method: "POST", status: "200"), "status must also hold")
        XCTAssertFalse(matches(filter, method: "GET", status: "500"), "method must also hold")
    }

    func testFreeTextIsAndedWithTokens() {
        let filter = TrafficSearchFilter(freeText: "users", methods: ["GET"])
        XCTAssertTrue(matches(filter))
        XCTAssertFalse(matches(filter, url: "https://api.example.com/v1/orders"))
    }

    // MARK: - Token round-tripping

    func testAddingAndRemovingEachTokenKind() {
        var filter = TrafficSearchFilter()
        filter.addToken(.method("get"))
        filter.addToken(.status(.range(400...499)))
        filter.addToken(.path("/v1"))
        filter.addToken(.host("api.example.com"))

        XCTAssertEqual(filter.tokens.count, 4)
        XCTAssertTrue(filter.hasTokens)
        XCTAssertFalse(filter.isEmpty)

        filter.addToken(.method("GET"))
        XCTAssertEqual(filter.methods.count, 1, "the same method in another case is not a second token")

        filter.removeToken(.status(.range(400...499)))
        XCTAssertTrue(filter.statuses.isEmpty)

        filter.clear()
        XCTAssertTrue(filter.isEmpty)
    }

    func testChipLabels() {
        XCTAssertEqual(TrafficSearchToken.method("get").displayName, "GET")
        XCTAssertEqual(TrafficSearchToken.status(.range(500...599)).displayName, "5xx")
        XCTAssertEqual(TrafficSearchToken.status(.exact(404)).displayName, "404")
        XCTAssertEqual(TrafficSearchToken.path("/v1/users").displayName, "/v1/users")
    }

    // MARK: - Suggestions

    func testEachKindOffersItsOwnVocabulary() {
        XCTAssertTrue(TrafficSearchTokenKind.method.staticSuggestions.contains("GET"))
        XCTAssertTrue(TrafficSearchTokenKind.status.staticSuggestions.contains("5xx"))
        XCTAssertTrue(TrafficSearchTokenKind.path.staticSuggestions.isEmpty, "paths come from the traffic")
        XCTAssertTrue(TrafficSearchTokenKind.host.staticSuggestions.isEmpty, "hosts come from the traffic")
    }
}
