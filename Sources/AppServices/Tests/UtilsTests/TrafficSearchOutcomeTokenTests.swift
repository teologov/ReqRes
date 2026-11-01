//
//  TrafficSearchOutcomeTokenTests.swift
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
//  The `outcome:` search token (protocol PRD 3.4, protocol-engine doc §S3)
//  and the free tier's rule for failure rows (decision D14).
//

import XCTest
import MCPKit
@testable import Utils

final class TrafficSearchOutcomeTokenTests: XCTestCase {
    private func matches(_ filter: TrafficSearchFilter, outcome: String?) -> Bool {
        filter.matches(host: "a.com", url: "https://a.com/", method: "GET", status: "502", app: nil, pid: nil, country: nil, outcome: outcome, grpcStatus: nil, proto: nil)
    }

    func testThePrefixParsesAndTheQueryNormalises() throws {
        let parsed = try XCTUnwrap(TrafficSearchTokenKind.parse("outcome: Timed-Out"))
        XCTAssertEqual(parsed.kind, .outcome)
        XCTAssertEqual(TrafficSearchToken.parse(kind: .outcome, query: parsed.query), .outcome("timed_out"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .outcome, query: "FAILED"), .outcome("failed"))
        XCTAssertNil(TrafficSearchToken.parse(kind: .outcome, query: "broken"), "unusable → free text, never a chip that matches nothing")
    }

    /// Utils cannot import MCPKit; the two spellings of the vocabulary are
    /// pinned equal here, where both are visible.
    func testTheVocabularyIsMCPKitsOutcomeTokens() {
        XCTAssertEqual(Set(TrafficSearchOutcomeMatch.all), Set(MCPSessionOutcome.tokens))
        for outcome in MCPSessionOutcome.allCases {
            XCTAssertEqual(TrafficSearchOutcomeMatch.normalize(outcome.rawValue), outcome.token, "the core's raw value \(outcome.rawValue)")
            XCTAssertEqual(TrafficSearchOutcomeMatch.displayName(forToken: outcome.token), FailureRowCopy.label(outcome))
        }
        XCTAssertEqual(TrafficSearchTokenKind.outcome.staticSuggestions.first, "failed", "nobody types outcome: to find what worked")
    }

    func testAnOutcomeChipSelectsThatOutcomeAndOlderRowsAreCompleted() {
        let failed = TrafficSearchFilter(outcomes: ["failed"])
        XCTAssertTrue(matches(failed, outcome: "failed"))
        XCTAssertFalse(matches(failed, outcome: "aborted"))
        XCTAssertFalse(matches(failed, outcome: nil), "a row an older core wrote is completed")
        XCTAssertTrue(matches(TrafficSearchFilter(outcomes: ["completed"]), outcome: nil))
        XCTAssertTrue(matches(TrafficSearchFilter(outcomes: ["failed", "timed_out"]), outcome: "timed_out"), "chips of one kind are OR-ed")
        XCTAssertTrue(matches(TrafficSearchFilter(), outcome: "failed"), "no chip, no constraint")
    }

    func testChipsAreNormalisedDeduplicatedRemovedAndCleared() {
        var filter = TrafficSearchFilter()
        filter.addToken(.outcome("Failed"))
        filter.addToken(.outcome("failed"))
        filter.addToken(.outcome("nonsense"))
        XCTAssertEqual(filter.outcomes, ["failed"])
        XCTAssertEqual(filter.tokens.last, .outcome("failed"))
        XCTAssertEqual(TrafficSearchToken.outcome("timed_out").displayName, "Timed out")
        XCTAssertTrue(filter.hasTokens)
        filter.removeToken(.outcome("FAILED"))
        XCTAssertTrue(filter.outcomes.isEmpty)
        filter.addToken(.outcome("aborted"))
        filter.clear()
        XCTAssertFalse(filter.hasTokens)
    }

    func testASingleTokenMatchesOnItsOwn() {
        XCTAssertTrue(TrafficSearchToken.outcome("aborted").matches(host: "a", url: "https://a/", method: "GET", status: nil, outcome: "aborted"))
        XCTAssertFalse(TrafficSearchToken.outcome("aborted").matches(host: "a", url: "https://a/", method: "GET", status: nil))
    }

    // MARK: - Free tier (D14)

    /// An aborted or timed-out row that recorded a decrypted body is an
    /// inspection like any exchange: counted, paywalled and certificate-gated
    /// exactly as if it had completed (the pane still shows its banner).
    /// Without this, "Show cancelled requests" listed every cut download and
    /// stream with its body, uncounted.
    func testAFailureRowCarryingADecryptedBodyIsAnInspection() {
        for licensed in [false, true] {
            for usedUp in [false, true] {
                for certificate in [false, true] {
                    for https in [false, true] {
                        let completed = FreeTier.detailAccess(isRelay: false, isFailure: false, failureCarriesDecryptedBody: false, isHTTPS: https,
                                                              certificateInstalled: certificate, licensed: licensed, inspectionsUsedUp: usedUp)
                        XCTAssertEqual(
                            FreeTier.detailAccess(isRelay: false, isFailure: true, failureCarriesDecryptedBody: true, isHTTPS: https,
                                                  certificateInstalled: certificate, licensed: licensed, inspectionsUsedUp: usedUp),
                            completed,
                            "licensed=\(licensed) usedUp=\(usedUp) certificate=\(certificate) https=\(https)"
                        )
                    }
                }
            }
        }
        XCTAssertEqual(FreeTier.detailAccess(isRelay: false, isFailure: true, failureCarriesDecryptedBody: true, isHTTPS: true,
                                             certificateInstalled: true, licensed: false, inspectionsUsedUp: false),
                       .inspect(counted: true))
        XCTAssertEqual(FreeTier.detailAccess(isRelay: true, isFailure: true, failureCarriesDecryptedBody: true, isHTTPS: true,
                                             certificateInstalled: true, licensed: false, inspectionsUsedUp: true),
                       .relay, "a relay has nothing decrypted inside it")
    }

    /// A failure row never costs an inspection and is never paywalled or
    /// certificate-gated — whatever the licence, the count or the keychain.
    /// A relay that failed is still a relay.
    func testAFailureRowIsNeverCountedPaywalledOrCertificateGated() {
        for licensed in [false, true] {
            for usedUp in [false, true] {
                for certificate in [false, true] {
                    for https in [false, true] {
                        XCTAssertEqual(
                            FreeTier.detailAccess(isRelay: false, isFailure: true, failureCarriesDecryptedBody: false, isHTTPS: https, certificateInstalled: certificate,
                                                  licensed: licensed, inspectionsUsedUp: usedUp),
                            .failure,
                            "licensed=\(licensed) usedUp=\(usedUp) certificate=\(certificate) https=\(https)"
                        )
                    }
                    XCTAssertEqual(
                        FreeTier.detailAccess(isRelay: true, isFailure: true, failureCarriesDecryptedBody: false, isHTTPS: true, certificateInstalled: certificate,
                                              licensed: licensed, inspectionsUsedUp: usedUp),
                        .relay
                    )
                }
            }
        }
    }
}
