//
//  IPCountryTableTests.swift
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
//  The IP → country table: fixed vectors, the address classes decided without
//  the table, the parser's refusals, and — the one that matters — 800 addresses
//  sampled from the CSV the binary was built from, so an off-by-one in the
//  delta decoder fails here rather than mislabelling a dot on the map.
//

import XCTest
@testable import GeoKit

final class IPCountryTableTests: XCTestCase {

    private static let table: IPCountryTable = {
        do { return try IPCountryTable.bundled() } catch { fatalError("bundled table: \(error)") }
    }()

    private var table: IPCountryTable { Self.table }

    // MARK: - Vectors

    func testWellKnownAddresses() {
        XCTAssertEqual(table.country(for: "8.8.8.8"), .country("US"))
        XCTAssertEqual(table.country(for: "1.1.1.1"), .country("AU"))
        XCTAssertEqual(table.country(for: "9.9.9.9"), .country("US"))
        XCTAssertEqual(table.country(for: "2a00:1450:4001::1"), .country("DE"))
        XCTAssertEqual(table.country(for: "2001:67c:2e8::1"), .country("NL"))
        XCTAssertEqual(table.country(for: "2620:0:2d0:200::7"), .country("US"))
        // Google Public DNS over IPv6. DB-IP Lite attributes 2001:4860::/32 to
        // Canada in the 2026-09 data, not the US one might expect — the map
        // shows what the data says, so this only asserts that it IS a country.
        // The data-exact vector lives in the sampled fixture.
        XCTAssertNotNil(table.country(for: "2001:4860:4860::8888").isoCode)
    }

    func testLoopbackIsThisMac() {
        XCTAssertEqual(table.country(for: "127.0.0.1"), .thisMac)
        XCTAssertEqual(table.country(for: "127.255.255.255"), .thisMac)
        XCTAssertEqual(table.country(for: "::1"), .thisMac)
        XCTAssertEqual(table.country(for: "::ffff:127.0.0.1"), .thisMac)
    }

    func testPrivateRangesAreLocalNetwork() {
        for address in ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255", "192.168.1.1",
                        "169.254.1.1", "100.64.0.1", "100.127.255.255",
                        "fe80::1", "fe80::1%en0", "febf::1", "fc00::1", "fd12:3456::1"] {
            XCTAssertEqual(table.country(for: address), .localNetwork, address)
        }
        // The neighbours of those ranges are ordinary space.
        for address in ["172.32.0.1", "172.15.255.255", "100.63.255.255", "100.128.0.1", "192.167.0.1", "fec0::1"] {
            XCTAssertNotEqual(table.country(for: address), .localNetwork, address)
            XCTAssertNotEqual(table.country(for: address), .thisMac, address)
        }
    }

    func testReservedSpaceIsUnknown() {
        for address in ["0.0.0.0", "0.1.2.3", "224.0.0.1", "239.255.255.255", "240.0.0.1", "255.255.255.255",
                        "192.0.0.1", "192.0.2.1", "198.18.0.1", "198.19.255.255", "198.51.100.7", "203.0.113.9",
                        "::", "ff02::1", "ff0e::1", "2001:db8::1", "2001:db8:ffff::1"] {
            XCTAssertEqual(table.country(for: address), .unknown, address)
        }
    }

    func testIPv4EmbeddedInIPv6() {
        XCTAssertEqual(table.country(for: "::ffff:8.8.8.8"), .country("US"))
        XCTAssertEqual(table.country(for: "::ffff:808:808"), .country("US"))
        XCTAssertEqual(table.country(for: "::ffff:10.0.0.1"), .localNetwork)
        XCTAssertEqual(table.country(for: "64:ff9b::808:808"), .country("US"))
    }

    func testGarbageIsUnknownAndNeverCrashes() {
        for address in ["", " ", "garbage", "example.com", "[2001:db8::1]:443", "[::1]:443", "1.2.3.4:443",
                        "8.8.8.8:53", "1.2.3", "1.2.3.4.5", "256.1.1.1", "8.8.8.8/24", "8.8.8.8 extra",
                        "::ffff:999.1.1.1", "2001:4860:4860::8888:", ":::", "1::2::3", "٨.٨.٨.٨", "8,8,8,8",
                        "0x08080808", "http://8.8.8.8", String(repeating: "8.", count: 200),
                        "\u{0}", "8.8.8.8\u{0}", "8.8.8.8\u{0}junk", "\u{0}8.8.8.8"] {
            XCTAssertEqual(table.country(for: address), .unknown, address.debugDescription)
        }
    }

    func testWhitespaceAndZoneAreTolerated() {
        XCTAssertEqual(table.country(for: " 8.8.8.8\n"), .country("US"))
        XCTAssertEqual(table.country(for: "\t2a00:1450:4001::1 "), .country("DE"))
        XCTAssertEqual(table.country(for: "fe80::1%utun3"), .localNetwork)
        XCTAssertEqual(table.country(for: "fe80::1%"), .localNetwork, "a dangling zone delimiter is dropped like a zone")
    }

    func testResolutionIsNeverZZ() {
        // ZZ is DB-IP's "unassigned"; the public type has .unknown for it.
        XCTAssertEqual(table.country(for: "0.0.0.0"), .unknown)
        XCTAssertEqual(table.rawCountry(.v4(0)), "ZZ")
        XCTAssertNil(GeoResolution.unknown.isoCode)
        XCTAssertEqual(GeoResolution.country("US").isoCode, "US")
    }

    // MARK: - The data it was built from

    func testSampledAddressesMatchTheSourceCSV() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ip-samples", withExtension: "csv", subdirectory: "Fixtures"),
                                "Fixtures/ip-samples.csv is missing from the test bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        var checked = 0
        var mismatches: [String] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: ",")
            guard columns.count == 2 else { continue }
            let address = String(columns[0])
            let expected = String(columns[1])
            let parsed = try XCTUnwrap(IPAddress.parse(address), address)
            let actual = table.rawCountry(parsed)
            if actual != expected { mismatches.append("\(address): expected \(expected), got \(actual ?? "nil")") }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 800, "the fixture should hold 400 IPv4 + 400 IPv6 samples")
        XCTAssertEqual(mismatches, [], "\(mismatches.count) of \(checked) samples disagree with the CSV")
    }

    func testMetadata() {
        XCTAssertEqual(table.dataMonth.count, 7)
        XCTAssertNotNil(table.dataMonth.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression))
        XCTAssertGreaterThan(table.ipv4RowCount, 100_000)
        XCTAssertGreaterThan(table.ipv6RowCount, 100_000)
        XCTAssertTrue((200...255).contains(table.countries.count), "\(table.countries.count) countries")
        XCTAssertTrue(table.countries.contains("US"))
        XCTAssertTrue(table.countries.contains("ZZ"))
        XCTAssertEqual(table.countries, table.countries.sorted())
        XCTAssertEqual(GeoKit.dataMonth, table.dataMonth)
        XCTAssertNotNil(IPCountryTable.shared)
    }

    // MARK: - Robustness

    func testMalformedDataThrows() throws {
        XCTAssertThrowsError(try IPCountryTable(data: Data()))
        XCTAssertThrowsError(try IPCountryTable(data: Data(count: 64)))
        XCTAssertThrowsError(try IPCountryTable(data: Data(repeating: 0xff, count: 4096)))

        let url = try GeoKit.resourceURL("dbip-country", extension: "bin")
        let whole = try Data(contentsOf: url)
        XCTAssertNoThrow(try IPCountryTable(data: whole))
        // Truncated: the header's length no longer matches.
        XCTAssertThrowsError(try IPCountryTable(data: whole.prefix(whole.count - 1)))
        // Wrong magic.
        var wrongMagic = whole
        wrongMagic[0] = 0x58
        XCTAssertThrowsError(try IPCountryTable(data: wrongMagic))
        // Wrong version.
        var wrongVersion = whole
        wrongVersion[4] = 0x09
        XCTAssertThrowsError(try IPCountryTable(data: wrongVersion))
    }

    func testCorruptStreamDoesNotCrash() throws {
        // Flip bytes in the index and delta streams (past the header and the
        // country table, which the loader validates): lookups may be wrong,
        // but must return, and must never read past the file.
        let url = try GeoKit.resourceURL("dbip-country", extension: "bin")
        var bytes = try Data(contentsOf: url)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let index = Int.random(in: 1024..<bytes.count, using: &generator)
            bytes[index] = 0xff
        }
        let corrupt = try IPCountryTable(data: bytes)
        for _ in 0..<5000 {
            _ = corrupt.country(for: "\(UInt8.random(in: 1...223)).\(UInt8.random(in: 0...255)).\(UInt8.random(in: 0...255)).1")
            _ = corrupt.resolve(.v6(UInt128Value(hi: UInt64.random(in: 0x2000_0000_0000_0000...0x3fff_ffff_ffff_ffff), lo: 0)))
        }
    }

    // MARK: - Speed

    func testLoadIsFast() throws {
        var worst: Double = 0
        for _ in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            let loaded = try IPCountryTable.bundled()
            _ = loaded.country(for: "8.8.8.8")
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            worst = max(worst, elapsed)
        }
        print("GeoKit: table load + first lookup, worst of 5: \(String(format: "%.2f", worst)) ms")
        XCTAssertLessThan(worst, 50, "loading the table took \(worst) ms")
    }

    func testLookupIsFast() {
        var addresses: [IPAddress] = []
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50_000 {
            addresses.append(.v4(UInt32.random(in: 0x0100_0000...0xdfff_ffff, using: &generator)))
            addresses.append(.v6(UInt128Value(hi: UInt64.random(in: 0x2000_0000_0000_0000...0x3fff_ffff_ffff_ffff, using: &generator),
                                              lo: UInt64.random(in: 0...UInt64.max, using: &generator))))
        }
        for address in addresses.prefix(1000) { _ = table.resolve(address) }   // warm the pages
        let started = DispatchTime.now().uptimeNanoseconds
        var countries = 0
        for address in addresses where table.resolve(address).isoCode != nil { countries += 1 }
        let perLookup = Double(DispatchTime.now().uptimeNanoseconds - started) / Double(addresses.count) / 1e3
        print("GeoKit: \(addresses.count) lookups, \(String(format: "%.2f", perLookup)) µs each, \(countries) resolved to a country")
        XCTAssertGreaterThan(countries, addresses.count / 4)
        #if DEBUG
        // An unoptimised build is roughly an order of magnitude slower than the
        // shipping one; the 5 µs target is for release.
        XCTAssertLessThan(perLookup, 60, "\(perLookup) µs per lookup in a debug build")
        #else
        XCTAssertLessThan(perLookup, 5, "\(perLookup) µs per lookup")
        #endif
    }

    // MARK: - 128-bit helper

    func testUInt128Value() {
        let one = UInt128Value(1)
        XCTAssertEqual(one.shiftedLeft(64), UInt128Value(hi: 1, lo: 0))
        XCTAssertEqual(one.shiftedLeft(127), UInt128Value(hi: 1 << 63, lo: 0))
        XCTAssertEqual(one.shiftedLeft(128), .zero)
        XCTAssertEqual(UInt128Value(hi: 1, lo: 0).shiftedRight(64), one)
        XCTAssertEqual(UInt128Value(hi: 1, lo: 0).shiftedRight(1), UInt128Value(hi: 0, lo: 1 << 63))
        XCTAssertEqual(UInt128Value(hi: 0, lo: .max).adding(one), UInt128Value(hi: 1, lo: 0))
        XCTAssertEqual(UInt128Value(hi: 0xabcd, lo: 0x1234).shiftedLeft(8).shiftedRight(8), UInt128Value(hi: 0xabcd, lo: 0x1234))
        XCTAssertTrue(UInt128Value(hi: 1, lo: 0) > UInt128Value(hi: 0, lo: .max))
        XCTAssertTrue(UInt128Value(hi: 1, lo: 5) > UInt128Value(hi: 1, lo: 4))
    }

    /// IANA has only ever allocated global unicast from 2000::/3. DB-IP's
    /// CSV carries junk tail rows that map reserved and deprecated site-local
    /// space to a country (2026-09: to CH); the resolver refuses anything
    /// outside 2000::/3 in code, because those rows change month to month.
    func testNothingOutsideGlobalUnicastResolvesToACountry() throws {
        let table = try XCTUnwrap(IPCountryTable.shared)
        for address in ["fec0::1", "fe00::1", "4000::1", "8000::1", "f000::1", "3ffe::1", "1::1"] {
            XCTAssertEqual(table.country(for: address), .unknown, address)
        }
        // and global unicast still resolves
        if case .country = table.country(for: "2a00:1450:4001::1") {} else { XCTFail("2a00:1450:4001::1 should resolve") }
    }
}
