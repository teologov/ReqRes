//
//  SocketIncrementalSearchTests.swift
//  AppServices
//
//  Created by OloApps on 9/29/26.
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

/// The Messages tab's search tests only the messages a pull added, not every
/// kept message again (release review, 2026-09-29).
final class SocketIncrementalSearchTests: XCTestCase {
    private func items(_ range: Range<Int64>) -> [SocketMessagePresentation.Item] {
        range.map { seq in
            .message(StoredSocketMessage(ordinal: seq, message: SocketFixtures.text(
                seq, seq % 3 == 0 ? "{\"price\":\(seq),\"sym\":\"ACME\"}" : "{\"price\":\(seq),\"sym\":\"OTHER\"}")))
        }
    }

    func testAPullTestsOnlyTheMessagesItAdded() {
        var search = SocketMessagePresentation.IncrementalSearch(query: "acme")
        let first = search.shown(items(0..<2_000))
        XCTAssertEqual(search.tested, 2_000)
        XCTAssertEqual(first, SocketMessagePresentation.shown(items(0..<2_000), query: "acme"))

        // The ring moved on by 5: five new messages, five older ones gone.
        let second = search.shown(items(5..<2_005))
        XCTAssertEqual(search.tested, 2_005, "only the five new messages may be tested")
        XCTAssertEqual(second, SocketMessagePresentation.shown(items(5..<2_005), query: "acme"))
    }

    func testANewQueryStartsOverAndTypingOnKeepsTheNos() {
        var search = SocketMessagePresentation.IncrementalSearch(query: "ac")
        _ = search.shown(items(0..<300))
        XCTAssertEqual(search.tested, 300)
        search.setQuery("acm")
        let narrowed = search.shown(items(0..<300))
        XCTAssertEqual(search.tested, 400, "only the 100 that matched \"ac\" are asked again")
        XCTAssertEqual(narrowed, SocketMessagePresentation.shown(items(0..<300), query: "acm"))

        search.setQuery("other")
        let other = search.shown(items(0..<300))
        XCTAssertEqual(search.tested, 700)
        XCTAssertEqual(other, SocketMessagePresentation.shown(items(0..<300), query: "other"))
    }

    func testABlankQueryShowsEverythingIncludingGaps() {
        var search = SocketMessagePresentation.IncrementalSearch(query: "  ")
        let all = items(0..<3) + [.gap(count: 4, beforeSeq: 7)]
        XCTAssertEqual(search.shown(all), all)
        XCTAssertEqual(search.tested, 0)
    }
}
