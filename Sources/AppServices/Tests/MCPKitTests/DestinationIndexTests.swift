//
//  DestinationIndexTests.swift
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
//  Destination-map UX spec §1.4: the index the flush maintains. `remove` is
//  the exact inverse of `add` (the retention cap drops rows one at a time),
//  Unknown sorts last, and ties are broken so a render never reshuffles.
//

import XCTest
@testable import MCPKit

final class DestinationIndexTests: XCTestCase {

    func testAddThenRemoveLeavesNothingBehind() {
        var index = DestinationIndex()
        index.add(destination: .country("US"), host: "api.stripe.com", bytes: 100, app: "claude")
        index.add(destination: .country("US"), host: "api.stripe.com", bytes: 50, app: nil)
        index.add(destination: .thisMac, host: "localhost", bytes: 7, app: "node")
        XCTAssertEqual(index.totalRequests, 3)
        XCTAssertEqual(index.totalBytes, 157)

        index.remove(destination: .country("US"), host: "api.stripe.com", bytes: 100, app: "claude")
        XCTAssertEqual(index.entries[.country("US")]?.requests, 1)
        XCTAssertEqual(index.entries[.country("US")]?.bytes, 50)
        XCTAssertEqual(index.entries[.country("US")]?.hostsByCount, ["api.stripe.com": 1])
        XCTAssertEqual(index.entries[.country("US")]?.appsByCount, [DestinationIndex.unknownAppKey: 1])

        index.remove(destination: .country("US"), host: "api.stripe.com", bytes: 50, app: nil)
        index.remove(destination: .thisMac, host: "localhost", bytes: 7, app: "node")
        XCTAssertEqual(index.entries, [:])
        XCTAssertEqual(index.totalRequests, 0)
        XCTAssertEqual(index.totalBytes, 0)
        XCTAssertTrue(index.isEmpty)
        XCTAssertEqual(index, DestinationIndex())
    }

    func testARemovalWithNoMatchingAddIsIgnored() {
        var index = DestinationIndex()
        index.remove(destination: .country("US"), host: "a", bytes: 10, app: nil)
        XCTAssertEqual(index, DestinationIndex(), "counts never go negative")
    }

    func testSortedPutsUnknownLastAndOrdersTies() {
        var index = DestinationIndex()
        for _ in 0..<10 { index.add(destination: .unknown, host: "?", bytes: 1, app: nil) }
        for _ in 0..<3 { index.add(destination: .country("DE"), host: "a", bytes: 10, app: nil) }
        for _ in 0..<3 { index.add(destination: .country("US"), host: "a", bytes: 20, app: nil) }
        for _ in 0..<3 { index.add(destination: .thisMac, host: "localhost", bytes: 20, app: nil) }
        for _ in 0..<5 { index.add(destination: .localNetwork, host: "nas", bytes: 1, app: nil) }

        let tokens = index.sorted().map(\.destination.token)
        // local (5) first; then the three tied on 3 requests — US and mac tie
        // on bytes too and fall back to token order (`US` < `mac` in ASCII),
        // DE has fewer bytes; unknown last despite having the most requests.
        XCTAssertEqual(tokens, ["local", "US", "mac", "DE", "unknown"])
    }

    func testPlottableIsCountriesOnlyInTheSameOrder() {
        var index = DestinationIndex()
        index.add(destination: .thisMac, host: "localhost", bytes: 0, app: nil)
        index.add(destination: .country("US"), host: "a", bytes: 0, app: nil)
        index.add(destination: .country("US"), host: "a", bytes: 0, app: nil)
        index.add(destination: .country("DE"), host: "b", bytes: 0, app: nil)
        index.add(destination: .unknown, host: "?", bytes: 0, app: nil)
        XCTAssertEqual(index.plottable.map(\.destination), [.country("US"), .country("DE")])
    }

    func testMaxCountryRequestsIgnoresTheClasses() {
        var index = DestinationIndex()
        XCTAssertEqual(index.maxCountryRequests, 0)
        for _ in 0..<9 { index.add(destination: .thisMac, host: "localhost", bytes: 0, app: nil) }
        for _ in 0..<7 { index.add(destination: .unknown, host: "?", bytes: 0, app: nil) }
        XCTAssertEqual(index.maxCountryRequests, 0, "no country yet — nothing to scale dots against")
        for _ in 0..<2 { index.add(destination: .country("US"), host: "a", bytes: 0, app: nil) }
        index.add(destination: .country("DE"), host: "b", bytes: 0, app: nil)
        XCTAssertEqual(index.maxCountryRequests, 2)
    }

    func testTopHostsOfSevenReturnsFiveBusiestFirstThenByName() {
        var index = DestinationIndex()
        let counts = ["g": 1, "f": 2, "e": 3, "d": 4, "c": 5, "b": 6, "a": 6]
        for (host, count) in counts {
            for _ in 0..<count { index.add(destination: .country("US"), host: host, bytes: 1, app: "x") }
        }
        let entry = index.entries[.country("US")]!
        XCTAssertEqual(entry.hostCount, 7)
        let top = entry.topHosts(5)
        XCTAssertEqual(top.map(\.name), ["a", "b", "c", "d", "e"], "a and b tie on 6 and fall back to name order")
        XCTAssertEqual(top.map(\.requests), [6, 6, 5, 4, 3])
        XCTAssertEqual(index.topHosts(2).map(\.name), ["a", "b"], "the index-wide list ranks the same way")
    }

    func testTheNilAppBucketSortsLastWhateverItsCount() {
        var index = DestinationIndex()
        for _ in 0..<50 { index.add(destination: .country("US"), host: "a", bytes: 1, app: nil) }
        for _ in 0..<2 { index.add(destination: .country("US"), host: "a", bytes: 1, app: "claude") }
        for _ in 0..<3 { index.add(destination: .country("US"), host: "a", bytes: 1, app: "Safari") }
        let apps = index.entries[.country("US")]!.topApps(5)
        XCTAssertEqual(apps.map(\.name), ["Safari", "claude", nil])
        XCTAssertEqual(apps.map(\.requests), [3, 2, 50])
        XCTAssertEqual(index.topApps(1).map(\.name), ["Safari"])
        XCTAssertEqual(index.topApps(5).last?.name, nil)
    }

    func testAnEmptyOrBlankAppNameIsTheNilBucket() {
        var index = DestinationIndex()
        index.add(destination: .country("US"), host: "a", bytes: 1, app: "")
        index.add(destination: .country("US"), host: "a", bytes: 1, app: "   ")
        index.add(destination: .country("US"), host: "a", bytes: 1, app: nil)
        XCTAssertEqual(index.entries[.country("US")]?.appsByCount, [DestinationIndex.unknownAppKey: 3])
    }

    func testBytesSumPerDestinationAndInTotal() {
        var index = DestinationIndex()
        index.add(destination: .country("US"), host: "a", bytes: 1_000, app: nil)
        index.add(destination: .country("US"), host: "b", bytes: 2_000, app: nil)
        index.add(destination: .country("DE"), host: "c", bytes: 500, app: nil)
        XCTAssertEqual(index.entries[.country("US")]?.bytes, 3_000)
        XCTAssertEqual(index.entries[.country("DE")]?.bytes, 500)
        XCTAssertEqual(index.totalBytes, 3_500)
        XCTAssertEqual(index.totalRequests, 3)
    }

    func testEntryIdentityIsItsDestination() {
        let entry = DestinationEntry(destination: .localNetwork)
        XCTAssertEqual(entry.id, .localNetwork)
    }
}
