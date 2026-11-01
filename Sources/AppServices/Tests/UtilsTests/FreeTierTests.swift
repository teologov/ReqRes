//
//  FreeTierTests.swift
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
@testable import Utils

final class FreeTierTests: XCTestCase {
    /// A deliberate-change test, the same shape as the MCP tool-surface one.
    ///
    /// These three numbers are quoted to a person deciding whether to pay, on
    /// a screen that says "Free: 2 / Licensed: Unlimited". Changing the free
    /// tier is a pricing decision, so it should take an edit here — and a
    /// silent drift between what the paywall promises and what the app
    /// enforces is the failure this whole file exists to prevent.
    func testTheFreeTierIsExactlyWhatThePaywallClaims() {
        XCTAssertEqual(FreeTier.hostFilters, 2)
        XCTAssertEqual(FreeTier.overrideRules, 1)
        XCTAssertEqual(FreeTier.httpsSessionDetailsPerLaunch, 10)
    }

    /// The gates block the NEXT one, so the limit is reached AT the number,
    /// not past it. Off by one here means either a free user gets three host
    /// filters or a paying feature is refused to someone who has two.
    func testTheLimitIsReachedAtTheNumberNotAfterIt() {
        XCTAssertFalse(FreeTier.hostFilterLimitReached(existing: 0))
        XCTAssertFalse(FreeTier.hostFilterLimitReached(existing: FreeTier.hostFilters - 1))
        XCTAssertTrue(FreeTier.hostFilterLimitReached(existing: FreeTier.hostFilters))
        XCTAssertTrue(FreeTier.hostFilterLimitReached(existing: FreeTier.hostFilters + 5))

        XCTAssertFalse(FreeTier.overrideRuleLimitReached(existing: 0))
        XCTAssertTrue(FreeTier.overrideRuleLimitReached(existing: FreeTier.overrideRules))
    }

    /// The paywall renders these into "2", "1 in total" and "10 per launch".
    /// A zero or negative limit would render a sentence that means nothing.
    func testEveryLimitIsPositive() {
        XCTAssertGreaterThan(FreeTier.hostFilters, 0)
        XCTAssertGreaterThan(FreeTier.overrideRules, 0)
        XCTAssertGreaterThan(FreeTier.httpsSessionDetailsPerLaunch, 0)
    }

    // MARK: - The detail pane's gate (protocol-engine doc §S2)

    /// A relayed connection (no trusted ReqRes CA when it opened) has nothing
    /// inside it to inspect. It must never cost a free inspection, never hit
    /// the paywall, and never show "install the certificate" in place of the
    /// facts it DOES have — whatever the licence, the count, or the keychain.
    func testARelayIsNeverCountedPaywalledOrCertificateGated() {
        for licensed in [false, true] {
            for usedUp in [false, true] {
                for certificate in [false, true] {
                    XCTAssertEqual(
                        FreeTier.detailAccess(isRelay: true, isFailure: false, failureCarriesDecryptedBody: false, isHTTPS: true, certificateInstalled: certificate,
                                              licensed: licensed, inspectionsUsedUp: usedUp),
                        .relay,
                        "licensed=\(licensed) usedUp=\(usedUp) certificate=\(certificate)"
                    )
                }
            }
        }
    }

    func testAnUnlicensedHTTPSExchangeSpendsAnInspectionUntilTheyRunOut() {
        XCTAssertEqual(FreeTier.detailAccess(isRelay: false, isFailure: false, failureCarriesDecryptedBody: false, isHTTPS: true, certificateInstalled: true, licensed: false, inspectionsUsedUp: false),
                       .inspect(counted: true))
        XCTAssertEqual(FreeTier.detailAccess(isRelay: false, isFailure: false, failureCarriesDecryptedBody: false, isHTTPS: true, certificateInstalled: true, licensed: false, inspectionsUsedUp: true),
                       .limitReached)
    }

    func testTheCertificateGateComesBeforeTheLicence() {
        XCTAssertEqual(FreeTier.detailAccess(isRelay: false, isFailure: false, failureCarriesDecryptedBody: false, isHTTPS: true, certificateInstalled: false, licensed: true, inspectionsUsedUp: false),
                       .certificateRequired)
        XCTAssertEqual(FreeTier.detailAccess(isRelay: false, isFailure: false, failureCarriesDecryptedBody: false, isHTTPS: true, certificateInstalled: false, licensed: false, inspectionsUsedUp: true),
                       .certificateRequired)
    }

    func testLicensedHTTPSAndAnyPlainHTTPAreFreeToOpen() {
        XCTAssertEqual(FreeTier.detailAccess(isRelay: false, isFailure: false, failureCarriesDecryptedBody: false, isHTTPS: true, certificateInstalled: true, licensed: true, inspectionsUsedUp: true),
                       .inspect(counted: false))
        XCTAssertEqual(FreeTier.detailAccess(isRelay: false, isFailure: false, failureCarriesDecryptedBody: false, isHTTPS: false, certificateInstalled: false, licensed: false, inspectionsUsedUp: true),
                       .inspect(counted: false))
    }
}
