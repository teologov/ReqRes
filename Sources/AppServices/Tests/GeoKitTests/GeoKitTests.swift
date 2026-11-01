//
//  GeoKitTests.swift
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

final class GeoKitTests: XCTestCase {

    func testAttributionIsTheLicenceCredit() {
        XCTAssertEqual(GeoKit.attribution,
                       "IP Geolocation by DB-IP (db-ip.com), CC BY 4.0. World outlines by Natural Earth (public domain).")
    }

    func testProvenanceNamesTheDataMonth() throws {
        let url = try GeoKit.resourceURL("PROVENANCE", extension: "md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let month = try XCTUnwrap(GeoKit.dataMonth)
        XCTAssertTrue(text.contains("Data month: \(month)"), "PROVENANCE.md must be updated with the table's month \(month)")
        XCTAssertTrue(text.contains("CC BY 4.0"))
        XCTAssertTrue(text.contains("dbip-country-lite-\(month).csv.gz"))
    }

    func testEveryResourceLoads() throws {
        XCTAssertNoThrow(try IPCountryTable.bundled())
        XCTAssertNoThrow(try WorldOutlines.bundled())
        XCTAssertNoThrow(try Centroids.bundled())
        XCTAssertGreaterThan(TimeZoneOrigin.rowCount, 0)
    }

    func testMissingResourceIsAnError() {
        XCTAssertThrowsError(try GeoKit.resourceURL("nope", extension: "bin")) { error in
            XCTAssertEqual(error as? GeoKitError, .resourceMissing("nope.bin"))
        }
    }
}
