//
//  CountryPresentationTests.swift
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
//  Destination-map UX spec §1.3. The names come from Foundation's region
//  data, so the tests fix the locale and assert the RULES (exact beats
//  prefix, an ambiguous prefix is nil) rather than a table of our own.
//

import XCTest
@testable import MCPKit

final class CountryPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    // MARK: - Flags

    func testFlagIsTheRegionalIndicatorPair() {
        XCTAssertEqual(CountryPresentation.flag(for: "US"), "🇺🇸")
        XCTAssertEqual(CountryPresentation.flag(for: "de"), "🇩🇪", "case does not matter")
        XCTAssertEqual(CountryPresentation.flag(for: "UA"), "🇺🇦")
    }

    /// XK and ZZ are two letters but have no glyph — a pair of boxed letters
    /// is worse than the `flag` symbol the caller falls back to on "".
    func testCodesWithoutAFlagGiveAnEmptyString() {
        for code in ["XK", "ZZ", "EZ", "QO", "", "U", "USA", "1A", "mac", "local", "unknown"] {
            XCTAssertEqual(CountryPresentation.flag(for: code), "", code)
        }
    }

    // MARK: - Names

    func testNameIsLocalisedAndFallsBackToTheCode() {
        XCTAssertEqual(CountryPresentation.name(for: "DE", locale: english), "Germany")
        XCTAssertEqual(CountryPresentation.name(for: "DE", locale: german), "Deutschland")
        XCTAssertEqual(CountryPresentation.name(for: "de", locale: english), "Germany", "case does not matter")
        XCTAssertEqual(CountryPresentation.name(for: "XX", locale: english), "XX", "an unknown code is shown as itself, never invented")
    }

    // MARK: - Reverse lookup

    func testAnExactNameWins() {
        XCTAssertEqual(CountryPresentation.code(matchingName: "Germany", locale: english), "DE")
        XCTAssertEqual(CountryPresentation.code(matchingName: "  germany ", locale: english), "DE")
        XCTAssertEqual(CountryPresentation.code(matchingName: "Deutschland", locale: german), "DE")
        // "Niger" is also a prefix of "Nigeria"; exact wins over the ambiguity.
        XCTAssertEqual(CountryPresentation.code(matchingName: "Niger", locale: english), "NE")
    }

    func testAUniquePrefixResolvesAndAnAmbiguousOneDoesNot() {
        XCTAssertEqual(CountryPresentation.code(matchingName: "germ", locale: english), "DE")
        XCTAssertNil(CountryPresentation.code(matchingName: "united", locale: english), "United States, United Kingdom, United Arab Emirates…")
        XCTAssertEqual(CountryPresentation.code(matchingName: "united k", locale: english), "GB")
    }

    func testAUniqueSubstringResolvesWhenNoPrefixDoes() {
        XCTAssertEqual(CountryPresentation.code(matchingName: "zealand", locale: english), "NZ")
        XCTAssertNil(CountryPresentation.code(matchingName: "land", locale: english), "Finland, Iceland, Ireland, Poland…")
    }

    func testABlankOrNonsenseQueryIsNil() {
        XCTAssertNil(CountryPresentation.code(matchingName: "", locale: english))
        XCTAssertNil(CountryPresentation.code(matchingName: "   ", locale: english))
        XCTAssertNil(CountryPresentation.code(matchingName: "qzxv", locale: english))
    }

    // MARK: - Titles and symbols

    func testTitlesAreTheLocalisedNameOrTheClassLabel() {
        XCTAssertEqual(CountryPresentation.title(for: .country("US"), locale: english), "United States")
        XCTAssertEqual(CountryPresentation.title(for: .thisMac), "This Mac")
        XCTAssertEqual(CountryPresentation.title(for: .localNetwork), "Local Network")
        XCTAssertEqual(CountryPresentation.title(for: .unknown), "Unknown")
    }

    func testSymbolsExistOnlyForTheClasses() {
        XCTAssertNil(CountryPresentation.symbolName(for: .country("US")))
        XCTAssertEqual(CountryPresentation.symbolName(for: .thisMac), "desktopcomputer")
        XCTAssertEqual(CountryPresentation.symbolName(for: .localNetwork), "wifi.router")
        XCTAssertEqual(CountryPresentation.symbolName(for: .unknown), "questionmark.circle.dashed")
    }

    // MARK: - Plurals

    func testPluralGroupsDigitsAndAddsAnS() {
        XCTAssertEqual(CountryPresentation.plural(1, "request", locale: english), "1 request")
        XCTAssertEqual(CountryPresentation.plural(0, "host", locale: english), "0 hosts")
        XCTAssertEqual(CountryPresentation.plural(1204, "request", locale: english), "1,204 requests")
        XCTAssertEqual(CountryPresentation.plural(1204, "request", locale: german), "1.204 requests")
    }
}
