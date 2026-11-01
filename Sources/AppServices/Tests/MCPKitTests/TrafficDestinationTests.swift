//
//  TrafficDestinationTests.swift
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
//  Destination-map UX spec §1.2: the classifier's ranges with a boundary on
//  both sides, the address forms it accepts and refuses, and the token
//  vocabulary the search field and the agent share.
//

import XCTest
@testable import MCPKit

final class TrafficDestinationTests: XCTestCase {

    /// A table that places everything public in one country, and records
    /// what it was asked, so a test can tell "classified locally" from
    /// "looked up".
    private final class Table {
        var asked: [String] = []
        var answer: String? = "US"
        func lookup(_ ip: String) -> String? {
            asked.append(ip)
            return answer
        }
    }

    private func classify(_ address: String?, table: Table = Table()) -> TrafficDestination {
        DestinationClassifier.classify(remoteAddress: address, lookup: table.lookup)
    }

    // MARK: - This Mac

    func testLoopbackIsThisMacAndNeverLookedUp() {
        let table = Table()
        XCTAssertEqual(classify("127.0.0.1", table: table), .thisMac)
        XCTAssertEqual(classify("127.255.255.254", table: table), .thisMac)
        XCTAssertEqual(classify("::1", table: table), .thisMac)
        XCTAssertEqual(classify("::ffff:127.0.0.1", table: table), .thisMac, "an IPv4 loopback seen through a dual-stack socket")
        XCTAssertTrue(table.asked.isEmpty, "loopback is decided locally")
    }

    // MARK: - Local Network, with a boundary on both sides of each range

    func testPrivateRangesAreLocalNetworkAtTheirBoundaries() {
        let table = Table()
        for address in [
            "10.0.0.0", "10.255.255.255",
            "172.16.0.0", "172.31.255.255",
            "192.168.0.0", "192.168.255.255",
            "169.254.0.0", "169.254.255.255",
            "100.64.0.0", "100.127.255.255",
            "fe80::1", "febf::1",
            "fc00::1", "fdff:ffff::1",
        ] {
            XCTAssertEqual(classify(address, table: table), .localNetwork, address)
        }
        XCTAssertTrue(table.asked.isEmpty)
    }

    func testTheAddressesJustOutsideThePrivateRangesAreLookedUp() {
        for address in [
            "9.255.255.255", "11.0.0.0",
            "172.15.255.255", "172.32.0.0",
            "192.167.255.255", "192.169.0.0",
            "169.253.255.255", "169.255.0.0",
            "100.63.255.255", "100.128.0.0",
            "fec0::1", "fe7f::1",
            "fb00::1", "fe00::1",
        ] {
            let table = Table()
            XCTAssertEqual(classify(address, table: table), .country("US"), address)
            XCTAssertEqual(table.asked.count, 1, address)
        }
    }

    // MARK: - Unknown without a lookup

    func testUnroutableAddressesAreUnknownAndNeverLookedUp() {
        let table = Table()
        for address in ["0.0.0.0", "0.255.255.255", "224.0.0.1", "239.255.255.255", "255.255.255.255", "::", "ff02::1", "ff00::"] {
            XCTAssertEqual(classify(address, table: table), .unknown, address)
        }
        XCTAssertTrue(table.asked.isEmpty)
    }

    func testMissingOrUnparseableAddressesAreUnknownAndNeverCrash() {
        let table = Table()
        for address in [nil, "", "   ", "garbage", "localhost", "api.example.com", "1.2.3", "1.2.3.4.5", "300.1.1.1", "fe80::1%en0"] {
            XCTAssertEqual(classify(address, table: table), .unknown, address ?? "nil")
        }
        XCTAssertTrue(table.asked.isEmpty, "a hostname is never handed to the table")
    }

    /// The core hands over a BARE literal. A stray `ip:port` or `[v6]:port`
    /// from anywhere else is tolerated by reading Unknown — not by guessing
    /// at the address inside it, and never by trapping.
    func testAnAddressWithAPortIsToleratedAsUnknown() {
        let table = Table()
        for address in ["127.0.0.1:3000", "[::1]:8034", "3.120.12.34:443", "[2001:db8::1]:443"] {
            XCTAssertEqual(classify(address, table: table), .unknown, address)
        }
        XCTAssertTrue(table.asked.isEmpty)
    }

    // MARK: - The lookup

    func testALookupAnswerBecomesAnUpperCasedCountry() {
        let table = Table()
        table.answer = "us"
        XCTAssertEqual(classify("8.8.8.8", table: table), .country("US"))
        XCTAssertEqual(table.asked, ["8.8.8.8"])
    }

    func testTheTableIsAskedWithACanonicalSpelling() {
        let table = Table()
        _ = classify("2001:DB8:0:0:0:0:0:1", table: table)
        XCTAssertEqual(table.asked, ["2001:db8::1"], "one cache key per address, however it was written")
        let mapped = Table()
        _ = classify("::ffff:8.8.8.8", table: mapped)
        XCTAssertEqual(mapped.asked, ["8.8.8.8"], "a v4-mapped address is looked up as the IPv4 it is")
    }

    func testANilOrZZLookupIsUnknown() {
        let missing = Table()
        missing.answer = nil
        XCTAssertEqual(classify("8.8.8.8", table: missing), .unknown)
        let zz = Table()
        zz.answer = "ZZ"
        XCTAssertEqual(classify("8.8.8.8", table: zz), .unknown, "ZZ is the table's own word for 'no country'")
        let junk = Table()
        junk.answer = "United States"
        XCTAssertEqual(classify("8.8.8.8", table: junk), .unknown, "a table that returns something other than a code is not trusted")
    }

    // MARK: - Tokens

    func testParseTokenAcceptsCodesAndClassWordsInAnyCase() {
        XCTAssertEqual(TrafficDestination.parseToken("Us"), .country("US"))
        XCTAssertEqual(TrafficDestination.parseToken(" de "), .country("DE"))
        XCTAssertEqual(TrafficDestination.parseToken("LOCAL"), .localNetwork)
        XCTAssertEqual(TrafficDestination.parseToken("Mac"), .thisMac)
        XCTAssertEqual(TrafficDestination.parseToken("unknown"), .unknown)
    }

    func testParseTokenRefusesNamesDigitsAndBlanks() {
        for text in ["USA", "u1", "", "  ", "Germany", "u", "us-en", "ü1"] {
            XCTAssertNil(TrafficDestination.parseToken(text), text)
        }
    }

    func testTokenRoundTripsAllFourCases() {
        for destination in [TrafficDestination.country("US"), .thisMac, .localNetwork, .unknown] {
            XCTAssertEqual(TrafficDestination.parseToken(destination.token), destination)
        }
        XCTAssertEqual(TrafficDestination.country("us").token, "US", "the token is always upper-cased")
    }

    func testSpecialTokensCanNeverCollideWithACode() {
        XCTAssertEqual(TrafficDestination.specialTokens, ["local", "mac", "unknown"])
        for token in TrafficDestination.specialTokens {
            XCTAssertNotEqual(token.count, 2, "a class word of two letters would shadow a country")
            XCTAssertEqual(token, token.lowercased())
        }
    }

    func testOnlyACountryIsPlottable() {
        XCTAssertTrue(TrafficDestination.country("DE").isPlottable)
        XCTAssertEqual(TrafficDestination.country("DE").isoCode, "DE")
        for destination in [TrafficDestination.thisMac, .localNetwork, .unknown] {
            XCTAssertFalse(destination.isPlottable)
            XCTAssertNil(destination.isoCode)
        }
    }

    func testDestinationIsCodable() throws {
        let all: [TrafficDestination] = [.country("US"), .thisMac, .localNetwork, .unknown]
        let data = try JSONEncoder().encode(all)
        XCTAssertEqual(try JSONDecoder().decode([TrafficDestination].self, from: data), all)
    }
}
