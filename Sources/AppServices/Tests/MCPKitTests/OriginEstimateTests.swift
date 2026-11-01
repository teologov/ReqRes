//
//  OriginEstimateTests.swift
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
//  Destination-map UX spec §1.5, with a stub table standing in for GeoKit's.
//

import XCTest
@testable import MCPKit

final class OriginEstimateTests: XCTestCase {
    /// What GeoKit's table would say, including the `backward` link the real
    /// table resolves for `Europe/Kiev`.
    private let table: [String: String] = [
        "Europe/Kyiv": "UA",
        "Europe/Kiev": "UA",
        "Europe/Amsterdam": "NL",
        "America/New_York": "us",
        "Antarctica/Troll": "ZZ",
    ]

    private func estimate(_ identifier: String) -> OriginEstimate? {
        guard let zone = TimeZone(identifier: identifier) else {
            XCTFail("Foundation does not know \(identifier)")
            return nil
        }
        return OriginEstimator.estimate(timeZone: zone, table: { self.table[$0] })
    }

    func testAZoneInTheTableGivesItsCountry() {
        XCTAssertEqual(estimate("Europe/Kyiv"), OriginEstimate(isoCode: "UA", timeZoneIdentifier: "Europe/Kyiv"))
        XCTAssertEqual(estimate("Europe/Kiev"), OriginEstimate(isoCode: "UA", timeZoneIdentifier: "Europe/Kiev"), "a backward link is the table's to resolve; the estimator passes the identifier through")
        XCTAssertEqual(estimate("Europe/Amsterdam")?.isoCode, "NL")
        XCTAssertEqual(estimate("America/New_York")?.isoCode, "US", "upper-cased whatever the table's spelling")
    }

    func testZonesThatBelongToNoCountryAreNil() {
        XCTAssertNil(estimate("UTC"))
        XCTAssertNil(estimate("GMT"))
        XCTAssertNil(estimate("Etc/GMT+2"))
        XCTAssertNil(estimate("Etc/UTC"))
    }

    func testAZoneTheTableLacksIsNil() {
        XCTAssertNil(estimate("Europe/Berlin"), "not in this stub table")
        XCTAssertNil(estimate("Antarctica/Troll"), "ZZ is not a country")
    }

    /// The estimator never consults the table for a zone it already knows is
    /// not a place — so a table that answers everything cannot invent one.
    func testTheTableIsNotAskedAboutUTC() {
        var asked: [String] = []
        let result = OriginEstimator.estimate(timeZone: TimeZone(identifier: "UTC")!, table: { asked.append($0); return "US" })
        XCTAssertNil(result)
        XCTAssertTrue(asked.isEmpty)
    }
}
