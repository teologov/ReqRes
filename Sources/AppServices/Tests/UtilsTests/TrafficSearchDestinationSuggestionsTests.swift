//
//  TrafficSearchDestinationSuggestionsTests.swift
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
//  The `country:` panel's rows (destination-map UX spec §5.3): matched on
//  title AND token, prefix before substring, committed excluded, Unknown
//  last, and every row carrying the normalised token Return will commit.
//

import XCTest
@testable import Utils

final class TrafficSearchDestinationSuggestionsTests: XCTestCase {

    /// What `SessionState.countrySuggestions()` hands over: busiest first,
    /// Unknown already last.
    private let candidates: [TrafficSearchDestinationCandidate] = [
        (token: "US", title: "United States", requests: 1204),
        (token: "DE", title: "Germany", requests: 88),
        (token: "DK", title: "Denmark", requests: 40),
        (token: "NL", title: "Netherlands", requests: 31),
        (token: "IE", title: "Ireland", requests: 12),
        (token: "mac", title: "This Mac", requests: 412),
        (token: "local", title: "Local Network", requests: 7),
        (token: "unknown", title: "Unknown", requests: 12),
    ]

    private func tokens(_ query: String, excluding committed: [String] = [], limit: Int = 10,
                        in candidates: [TrafficSearchDestinationCandidate]? = nil) -> [String] {
        TrafficSearchSuggestions.destinations(matching: query, in: candidates ?? self.candidates, excluding: committed, limit: limit)
            .map(\.token)
    }

    func testEmptyQueryOffersEveryCandidateInOrderWithUnknownLast() {
        XCTAssertEqual(tokens(""), ["US", "DE", "DK", "NL", "IE", "mac", "local", "unknown"])
    }

    func testTheQueryMatchesTheTitleAndTheToken() {
        XCTAssertEqual(tokens("un"), ["US", "unknown"], "United States by title, Unknown by both — and Unknown stays last")
        XCTAssertEqual(tokens("de"), ["DE", "DK"], "Germany by its code, Denmark by its name, in candidate order")
        XCTAssertEqual(tokens("ger"), ["DE"])
        XCTAssertEqual(tokens("mac"), ["mac"], "the class token")
        XCTAssertEqual(tokens("this"), ["mac"], "the class title")
        XCTAssertEqual(tokens("loc"), ["local"])
    }

    func testPrefixMatchesComeBeforeSubstringMatchesEachKeepingCandidateOrder() {
        // Nothing starts with "land"; Netherlands and Ireland contain it, in candidate order.
        XCTAssertEqual(tokens("land"), ["NL", "IE"])
        // Netherlands starts with "ne"; Local Network merely contains it — prefix first.
        XCTAssertEqual(tokens("ne"), ["NL", "local"])
        // Substring only: Germany, Netherlands and Ireland all contain "an", candidate order kept.
        XCTAssertEqual(tokens("an"), ["DE", "NL", "IE"])
    }

    func testCommittedTokensAreExcludedCaseInsensitivelyAndDuplicatesCollapse() {
        XCTAssertEqual(tokens("", excluding: ["us", "MAC"]), ["DE", "DK", "NL", "IE", "local", "unknown"])
        let doubled: [TrafficSearchDestinationCandidate] = [
            (token: "us", title: "United States", requests: 3),
            (token: "US", title: "United States", requests: 2),
            (token: "DE", title: "Germany", requests: 1),
        ]
        XCTAssertEqual(tokens("", in: doubled), ["US", "DE"])
    }

    func testReturnedTokensAreNormalisedAndUnusableCandidatesAreDropped() {
        let raw: [TrafficSearchDestinationCandidate] = [
            (token: "us", title: "United States", requests: 3),
            (token: "Germany", title: "Germany", requests: 9),
            (token: "Local", title: "Local Network", requests: 1),
        ]
        let rows = TrafficSearchSuggestions.destinations(matching: "", in: raw, excluding: [])
        XCTAssertEqual(rows.map(\.token), ["US", "local"], "a name is not a token and can never commit, so it is not a row")
        XCTAssertEqual(rows.map(\.title), ["United States", "Local Network"])
        XCTAssertEqual(rows.map(\.requests), [3, 1])
    }

    func testUnknownIsLastEvenWhenItOutranksEverything() {
        let busyUnknown: [TrafficSearchDestinationCandidate] = [
            (token: "unknown", title: "Unknown", requests: 500),
            (token: "US", title: "United States", requests: 10),
            (token: "DE", title: "Germany", requests: 5),
        ]
        XCTAssertEqual(tokens("", in: busyUnknown), ["US", "DE", "unknown"])
        XCTAssertEqual(tokens("un", in: busyUnknown), ["US", "unknown"])
        XCTAssertEqual(tokens("unk", in: busyUnknown), ["unknown"], "alone it is still offered")
    }

    func testTheLimitIsAppliedBeforeUnknownIsMovedLast() {
        let busyUnknown: [TrafficSearchDestinationCandidate] = [
            (token: "unknown", title: "Unknown", requests: 500),
            (token: "US", title: "United States", requests: 10),
            (token: "DE", title: "Germany", requests: 5),
        ]
        XCTAssertEqual(tokens("", limit: 2, in: busyUnknown), ["US", "unknown"], "the `app:` panel's rule: limit, then Unknown to the end")
        XCTAssertEqual(tokens("", limit: 1), ["US"])
        XCTAssertEqual(tokens("", limit: 0), [])
    }

    func testTheQueryIsTrimmedAndCaseInsensitive() {
        XCTAssertEqual(tokens("  GER "), ["DE"])
        XCTAssertEqual(tokens("  Us "), ["US"])
        XCTAssertEqual(tokens("zzz"), [], "no invention when nothing matches")
    }
}
