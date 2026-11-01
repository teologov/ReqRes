//
//  CountryNamesTests.swift
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

final class CountryNamesTests: XCTestCase {

    func testFlags() {
        XCTAssertEqual(CountryNames.flag(for: "US"), "🇺🇸")
        XCTAssertEqual(CountryNames.flag(for: "de"), "🇩🇪")
        XCTAssertEqual(CountryNames.flag(for: "JP"), "🇯🇵")
        XCTAssertEqual(CountryNames.flag(for: "US")?.unicodeScalars.count, 2)
    }

    func testFlagRefusesNonCodes() {
        for code in ["", "U", "USA", "ZZ", "U1", "us-", "🇺🇸", "Ü1"] {
            XCTAssertNil(CountryNames.flag(for: code), code)
        }
    }

    func testLocalizedNames() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(CountryNames.name(for: "DE", locale: english), "Germany")
        XCTAssertEqual(CountryNames.name(for: "us", locale: english), "United States")
        XCTAssertEqual(CountryNames.name(for: "DE", locale: Locale(identifier: "de_DE")), "Deutschland")
        XCTAssertEqual(CountryNames.name(for: "XK", locale: english), "Kosovo")
        XCTAssertNotNil(CountryNames.name(for: "GB"))
    }

    func testNameRefusesNonCodes() {
        let english = Locale(identifier: "en_US")
        for code in ["", "ZZ", "USA", "1A", "zz"] {
            XCTAssertNil(CountryNames.name(for: code, locale: english), code)
        }
    }

    func testEveryTableCountryHasAFlagAndAName() throws {
        let table = try IPCountryTable.bundled()
        let english = Locale(identifier: "en_US")
        for code in table.countries where code != "ZZ" {
            XCTAssertNotNil(CountryNames.flag(for: code), code)
            XCTAssertNotNil(CountryNames.name(for: code, locale: english), "no English name for \(code)")
        }
    }
}
