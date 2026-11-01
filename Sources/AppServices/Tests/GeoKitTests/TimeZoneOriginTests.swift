//
//  TimeZoneOriginTests.swift
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
@testable import GeoKit

final class TimeZoneOriginTests: XCTestCase {

    func testCanonicalZones() {
        XCTAssertEqual(TimeZoneOrigin.country(for: "Europe/London"), "GB")
        XCTAssertEqual(TimeZoneOrigin.country(for: "America/New_York"), "US")
        XCTAssertEqual(TimeZoneOrigin.country(for: "Asia/Kolkata"), "IN")
        XCTAssertEqual(TimeZoneOrigin.country(for: "Europe/Berlin"), "DE")
        XCTAssertEqual(TimeZoneOrigin.country(for: "Europe/Kyiv"), "UA")
        XCTAssertEqual(TimeZoneOrigin.country(for: "Australia/Sydney"), "AU")
        XCTAssertEqual(TimeZoneOrigin.country(for: "Asia/Singapore"), "SG")
    }

    func testOneCountryPerZoneNotZone1970Groups() {
        // zone1970.tab folds these into Europe/Belgrade (RS, …); zone.tab keeps them.
        XCTAssertEqual(TimeZoneOrigin.country(for: "Europe/Ljubljana"), "SI")
        XCTAssertEqual(TimeZoneOrigin.country(for: "Europe/Zagreb"), "HR")
        XCTAssertEqual(TimeZoneOrigin.country(for: "Europe/Belgrade"), "RS")
        XCTAssertEqual(TimeZoneOrigin.country(for: "Europe/Vaduz"), "LI")
    }

    func testBackwardLinksResolve() {
        XCTAssertEqual(TimeZoneOrigin.country(for: "Asia/Calcutta"), "IN")
        XCTAssertEqual(TimeZoneOrigin.country(for: "Europe/Kiev"), "UA")
        XCTAssertEqual(TimeZoneOrigin.country(for: "US/Pacific"), "US")
        XCTAssertEqual(TimeZoneOrigin.country(for: "America/Buenos_Aires"), "AR")
        XCTAssertEqual(TimeZoneOrigin.country(for: "Asia/Saigon"), "VN")
    }

    func testZonesWithoutACountry() {
        for identifier in ["UTC", "Etc/UTC", "GMT", "Etc/GMT+5", "Zulu", "", "Mars/Olympus_Mons", "europe/london"] {
            XCTAssertNil(TimeZoneOrigin.country(for: identifier), identifier)
        }
    }

    func testTableSizeAndIntegrity() throws {
        XCTAssertGreaterThanOrEqual(TimeZoneOrigin.rowCount, 400)
        let centroids = try Centroids.bundled()
        for (zone, country) in TimeZoneOrigin.table {
            XCTAssertEqual(country.count, 2, zone)
            XCTAssertNotNil(centroids[country], "\(zone) → \(country) has no centroid")
        }
    }

    func testCoordinateGoesThroughTheCentroids() throws {
        let centroids = try Centroids.bundled()
        let outlines = try WorldOutlines.bundled()
        let london = try XCTUnwrap(TimeZoneOrigin.coordinate(for: "Europe/London", in: centroids))
        XCTAssertTrue(try XCTUnwrap(outlines.outline(for: "GB")).contains(london))
        let kolkata = try XCTUnwrap(TimeZoneOrigin.coordinate(for: "Asia/Kolkata", in: centroids))
        XCTAssertTrue(try XCTUnwrap(outlines.outline(for: "IN")).contains(kolkata))
        XCTAssertNil(TimeZoneOrigin.coordinate(for: "UTC", in: centroids))
    }

    func testCurrentDoesNotCrash() throws {
        let centroids = try Centroids.bundled()
        _ = TimeZoneOrigin.currentCountry
        _ = TimeZoneOrigin.current(in: centroids)
        // Whatever this Mac is set to, a country answer must carry a point.
        if let country = TimeZoneOrigin.currentCountry {
            XCTAssertNotNil(centroids[country])
        }
    }
}
