//
//  LicenseOfferTests.swift
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
//  The paywall's offer, pinned word for word (pay-once S1, PRD A1 and A4; the
//  paywall design of 2026-10-06). The numbers mirror the website's
//  src/lib/pricing.ts: `UNIT_PRICE_USD` (60) and `MACS_PER_LICENSE` (2); the
//  sentences are its pricing page's (PricingHero.tsx, offer.ts `TAX_NOTE`).
//  A price or a sentence changed there fails here, and in
//  PaywallWebsiteParityTests, until this side follows. There is no volume
//  pricing in the app, and no price for a next version: a license covers
//  every version.
//

import XCTest
@testable import Utils

final class LicenseOfferTests: XCTestCase {
    private let nbsp = "\u{00A0}"

    func testTheNumbersMatchTheWebsitesPricing() {
        XCTAssertEqual(LicenseOffer.unitPriceUSD, 60, "pricing.ts UNIT_PRICE_USD")
        XCTAssertEqual(LicenseOffer.macsPerLicense, 2, "pricing.ts MACS_PER_LICENSE")
        XCTAssertEqual(LicenseOffer.refundDays, 14)
    }

    /// Every sentence, with its no-break spaces where the design's copy deck
    /// marks them.
    func testTheOfferSaysExactlyThis() {
        XCTAssertEqual(LicenseOffer.title, "ReqRes Pro")
        XCTAssertEqual(LicenseOffer.price, "$60")
        XCTAssertEqual(LicenseOffer.headline, "Pay once, use forever.")
        XCTAssertEqual(LicenseOffer.priceDetail,
                       "per person, for use on up to 2\u{00A0}Macs at\u{00A0}once, "
                           + "with\u{00A0}every\u{00A0}future\u{00A0}version\u{00A0}included.")
        XCTAssertEqual(LicenseOffer.taxNote, "USD, excl. VAT/sales tax.")
        XCTAssertEqual(LicenseOffer.licensedTerm,
                       "Yours permanently, with\u{00A0}every\u{00A0}future\u{00A0}version\u{00A0}included")
    }

    /// The Macs in the line beside the price follow the number: 1 Mac, 2 Macs.
    func testThePriceDetailFollowsTheNumberOfMacs() {
        XCTAssertEqual(LicenseOffer.priceDetail, LicenseOffer.priceDetail(macs: LicenseOffer.macsPerLicense))
        XCTAssertTrue(LicenseOffer.priceDetail(macs: 1).hasPrefix("per person, for use on up to 1\(nbsp)Mac at\(nbsp)once,"))
        XCTAssertTrue(LicenseOffer.priceDetail(macs: 2).hasPrefix("per person, for use on up to 2\(nbsp)Macs at\(nbsp)once,"))
        XCTAssertTrue(LicenseOffer.priceDetail(macs: 5).contains("5\(nbsp)Macs"))
    }

    /// Every number in a sentence is its constant, never a second copy.
    func testTheSentencesAreBuiltFromTheNumbers() {
        XCTAssertEqual(LicenseOffer.price, "$\(LicenseOffer.unitPriceUSD)")
        XCTAssertTrue(LicenseOffer.priceDetail.contains("\(LicenseOffer.macsPerLicense)\(nbsp)Macs"))
    }

    /// The old sheets' words and numbers, and the words the pay-once offer
    /// never uses. Restoring any of them fails here.
    func testNoSentenceCarriesAnOldOrForbiddenWord() {
        let forbidden = [
            "12 months from purchase", "free limits apply again",
            "$59.99", "$69.99", "$99.99", "$49.99", "$10 more",
            "Two Devices", "Single Device", "30%", "Renew", "Limited time",
            "perpetual",
            // The removed Activation row.
            "Activation", "offline", "serial number", "checked at each launch",
            // The sheet the 2026-10-06 design replaced.
            "Purchase License", "What's included", "What’s included", "Popular",
            // No volume pricing in the app.
            "Volume pricing", "% off",
            // A license covers every version: no
            // versions named, and no price or window for a next one.
            "1.x", "ReqRes 2", "next version", "upgrade", "within 12 months", "40%", "what you paid",
        ]
        for sentence in sentences {
            let plain = sentence.replacingOccurrences(of: nbsp, with: " ").lowercased()
            for word in forbidden {
                XCTAssertFalse(plain.contains(word.lowercased()), "'\(sentence)' contains '\(word)'")
            }
        }
    }

    /// "forever" is in the headline only, and the line beside the price and
    /// the licensed Term row say what it covers: every future version.
    func testForeverIsOnlyInTheHeadlineAndTheTermsSayWhatItCovers() {
        XCTAssertTrue(LicenseOffer.headline.contains("forever"))
        for sentence in sentences where sentence != LicenseOffer.headline {
            XCTAssertFalse(sentence.lowercased().contains("forever"), "'\(sentence)' says forever")
        }
        for sentence in [LicenseOffer.priceDetail, LicenseOffer.licensedTerm] {
            XCTAssertTrue(flat(sentence).contains("with every future version included"), "'\(sentence)'")
        }
    }

    /// The README sells the term the licensed sheet states (PRD A4: README,
    /// paywall and test change together).
    func testTheReadmeStatesTheLicensedTerm() throws {
        let readmeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
            .deletingLastPathComponent() // the repository root
            .appendingPathComponent("README.md")
        let readme = try String(contentsOf: readmeURL, encoding: .utf8)
        XCTAssertTrue(flat(readme).contains(flat(LicenseOffer.licensedTerm)),
                      "the README does not say '\(LicenseOffer.licensedTerm)'")
    }

    private var sentences: [String] {
        [LicenseOffer.title, LicenseOffer.price, LicenseOffer.headline, LicenseOffer.priceDetail,
         LicenseOffer.taxNote, LicenseOffer.licensedTerm]
    }

    /// Lowercased, every run of whitespace (U+00A0 included) one space.
    private func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
