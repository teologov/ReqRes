//
//  MCPRedactionPolicyTests.swift
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
@testable import MCPKit

final class MCPRedactionPolicyTests: XCTestCase {

    // MARK: - Default behaviour

    func testDefaultPolicyRedactsAnyHost() {
        // Guards the "never the default" requirement: a freshly constructed
        // policy, before a user has excepted anything, must behave exactly
        // like the old single global switch did.
        let policy = MCPRedactionPolicy()
        XCTAssertTrue(policy.shouldRedact(host: "example.com"))
        XCTAssertTrue(policy.shouldRedact(host: "anything-at-all.test"))
    }

    func testExceptedHostIsNotRedacted() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["staging.example.com"])
        XCTAssertFalse(policy.shouldRedact(host: "staging.example.com"))
    }

    func testGlobalSwitchOffRedactsNothingEvenWithoutAnException() {
        let policy = MCPRedactionPolicy(isEnabled: false)
        XCTAssertFalse(policy.shouldRedact(host: "example.com"))
    }

    // MARK: - Empty / malformed hosts fail toward redaction

    func testNilHostRedacts() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["example.com"])
        XCTAssertTrue(policy.shouldRedact(host: nil))
    }

    func testEmptyHostRedacts() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["example.com"])
        XCTAssertTrue(policy.shouldRedact(host: ""))
    }

    func testWhitespaceOnlyHostRedacts() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["example.com"])
        XCTAssertTrue(policy.shouldRedact(host: "   "))
    }

    func testHostWithInteriorWhitespaceRedacts() {
        // Not a real host at all — failing to normalize it must not silently
        // fall through to an exact-match comparison that happens to be false
        // for the wrong reason.
        let policy = MCPRedactionPolicy(exceptedHosts: ["example.com"])
        XCTAssertTrue(policy.shouldRedact(host: "exa mple.com"))
    }

    func testUnclosedIPv6BracketRedacts() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["::1"])
        XCTAssertTrue(policy.shouldRedact(host: "[::1"))
    }

    // MARK: - Case, trailing dot, port normalization

    func testMatchIsCaseInsensitive() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["Staging.Example.COM"])
        XCTAssertFalse(policy.shouldRedact(host: "staging.example.com"))
        XCTAssertFalse(policy.shouldRedact(host: "STAGING.EXAMPLE.COM"))
    }

    func testTrailingDotOnCapturedHostIsIgnored() {
        // The FQDN form a resolver sometimes hands back.
        let policy = MCPRedactionPolicy(exceptedHosts: ["example.com"])
        XCTAssertFalse(policy.shouldRedact(host: "example.com."))
    }

    func testTrailingDotOnStoredExceptionIsIgnored() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["example.com."])
        XCTAssertFalse(policy.shouldRedact(host: "example.com"))
    }

    func testPortOnCapturedHostIsIgnored() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["example.com"])
        XCTAssertFalse(policy.shouldRedact(host: "example.com:8443"))
    }

    func testBareIPv6HostWithoutBracketsIsNotMistakenForHostPort() {
        // Multiple colons with no brackets: stripping "the last colon" as a
        // port would mutilate the address instead of leaving it alone.
        let policy = MCPRedactionPolicy(exceptedHosts: ["2001:db8::1"])
        XCTAssertFalse(policy.shouldRedact(host: "2001:db8::1"))
    }

    func testBracketedIPv6HostWithPortMatchesTheBareAddress() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["::1"])
        XCTAssertFalse(policy.shouldRedact(host: "[::1]:8080"))
    }

    // MARK: - Near misses still redact

    func testHostThatIsAStrictSupersetOfAnExceptionStillRedacts() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["example.com"])
        XCTAssertTrue(policy.shouldRedact(host: "example.com.evil.com"))
    }

    func testHostThatIsAPrefixMatchOfAnExceptionStillRedacts() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["example.com"])
        XCTAssertTrue(policy.shouldRedact(host: "notexample.com"))
    }

    func testUnrelatedHostStillRedacts() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["example.com"])
        XCTAssertTrue(policy.shouldRedact(host: "example.org"))
    }

    // MARK: - Wildcards

    func testWildcardExceptsSubdomains() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["*.staging.example.com"])
        XCTAssertFalse(policy.shouldRedact(host: "api.staging.example.com"))
        XCTAssertFalse(policy.shouldRedact(host: "web.staging.example.com"))
    }

    func testWildcardDoesNotExceptTheBareDomain() {
        // "*.example.com" is a promise about subdomains only; a user who also
        // wants the apex excepted has to say so.
        let policy = MCPRedactionPolicy(exceptedHosts: ["*.example.com"])
        XCTAssertTrue(policy.shouldRedact(host: "example.com"))
    }

    func testWildcardDoesNotMatchABareStringSuffix() {
        // The suffix-confusion case named in the PRD item: "*.example.com"
        // must not degrade into "ends with example.com".
        let policy = MCPRedactionPolicy(exceptedHosts: ["*.example.com"])
        XCTAssertTrue(policy.shouldRedact(host: "evil-example.com"))
    }

    func testWildcardDoesNotMatchAnUnrelatedDeeperDomain() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["*.example.com"])
        XCTAssertTrue(policy.shouldRedact(host: "api.evilexample.com"))
    }

    func testWildcardWithAnEmptySuffixMatchesNothing() {
        // Exercised on the matcher directly: `normalize` strips a stored
        // entry's trailing dot before `matches` ever sees it, so a plain
        // "*." can never survive to reach this guard through the public
        // `shouldRedact` path. The guard still has to hold on its own —
        // a future normalization change must not turn "*." into "match all".
        XCTAssertFalse(MCPRedactionPolicy.matches(pattern: "*.", host: "anything.test"))
    }

    func testWildcardWithADoubleTrailingDotStillMatchesNothing() {
        // `normalize` removes exactly one trailing dot, so a hand-typed
        // "*.." (a stray keystroke) reduces to "*." — this is the one
        // real-world input that reaches the guard above through the
        // public API rather than by calling `matches` directly.
        let policy = MCPRedactionPolicy(exceptedHosts: ["*.."])
        XCTAssertTrue(policy.shouldRedact(host: "anything.test"))
    }

    // MARK: - Codable

    func testRoundTripEncodingPreservesThePolicy() throws {
        let policy = MCPRedactionPolicy(isEnabled: true, exceptedHosts: ["a.example.com", "*.b.example.com"])
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(MCPRedactionPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
    }

    func testDecodingIgnoresUnknownFields() throws {
        let json = """
        {"isEnabled": true, "exceptedHosts": ["example.com"], "futureField": {"nested": 1}}
        """
        let decoded = try JSONDecoder().decode(MCPRedactionPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, MCPRedactionPolicy(isEnabled: true, exceptedHosts: ["example.com"]))
    }

    func testDecodingToleratesAMissingField() throws {
        // No `exceptedHosts` key at all — a policy saved by an older build.
        let json = #"{"isEnabled": false}"#
        let decoded = try JSONDecoder().decode(MCPRedactionPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, MCPRedactionPolicy(isEnabled: false, exceptedHosts: []))
    }

    func testDecodingToleratesAWrongTypedFieldByFallingBackSafely() throws {
        // `exceptedHosts` as a single string instead of an array must not
        // throw and must not turn into "every host is excepted".
        let json = #"{"isEnabled": true, "exceptedHosts": "not-an-array"}"#
        let decoded = try JSONDecoder().decode(MCPRedactionPolicy.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.shouldRedact(host: "example.com"))
    }

    func testDecodingGarbageBytesFailsClosed() {
        let garbage = Data([0xFF, 0x00, 0x13, 0x42])
        let policy = MCPRedactionPolicy.decoding(garbage)
        XCTAssertEqual(policy, .redactAll)
        XCTAssertTrue(policy.shouldRedact(host: "example.com"))
    }

    func testDecodingATopLevelArrayFailsClosed() {
        // Valid JSON, wrong shape: there is no keyed container to even read
        // `isEnabled` from.
        let notAnObject = Data("[1, 2, 3]".utf8)
        let policy = MCPRedactionPolicy.decoding(notAnObject)
        XCTAssertEqual(policy, .redactAll)
    }

    func testDecodingEmptyDataFailsClosed() {
        let policy = MCPRedactionPolicy.decoding(Data())
        XCTAssertEqual(policy, .redactAll)
    }

    // MARK: - Audit description

    func testDescriptionWhenNothingIsExcepted() {
        XCTAssertEqual(MCPRedactionPolicy().auditDescription, "Redaction is on for every host.")
    }

    func testDescriptionWhenGloballyOff() {
        XCTAssertEqual(MCPRedactionPolicy(isEnabled: false).auditDescription, "Redaction is off globally.")
    }

    func testDescriptionListsExceptedHostsSingular() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["a"])
        XCTAssertEqual(policy.auditDescription, "Redaction is off for 1 host: a")
    }

    func testDescriptionListsExceptedHostsPlural() {
        let policy = MCPRedactionPolicy(exceptedHosts: ["a", "b"])
        XCTAssertEqual(policy.auditDescription, "Redaction is off for 2 hosts: a, b")
    }
}

/// The editing surface a settings UI drives. An exception the user can see in
/// a list but that never fires is worse than a rejected one: it reads as
/// redaction being broken rather than as a typo.
final class MCPRedactionPolicyEditingTests: XCTestCase {
    func testCanonicalEntryAcceptsAHostAndALeadingWildcard() {
        XCTAssertEqual(MCPRedactionPolicy.canonicalEntry(" API.Example.com. "), "api.example.com")
        XCTAssertEqual(MCPRedactionPolicy.canonicalEntry("api.example.com:8443"), "api.example.com")
        XCTAssertEqual(MCPRedactionPolicy.canonicalEntry("*.Staging.example.com"), "*.staging.example.com")
    }

    func testCanonicalEntryRejectsWhatCouldNeverMatch() {
        for raw in ["", "   ", "*", "*.", "api.*.example.com", "two words", "ex*mple.com"] {
            XCTAssertNil(MCPRedactionPolicy.canonicalEntry(raw), "\(raw) can never except anything")
        }
    }

    func testAddingAnExceptionStoresTheCanonicalForm() throws {
        let policy = try XCTUnwrap(MCPRedactionPolicy.redactAll.addingException(" API.Example.com "))

        XCTAssertEqual(policy.exceptedHosts, ["api.example.com"])
        XCTAssertFalse(policy.shouldRedact(host: "api.example.com"))
        XCTAssertTrue(policy.shouldRedact(host: "other.example.com"))
    }

    /// Nil, not a silently unchanged policy: the UI needs to tell "that is not
    /// a host" apart from "you already added it".
    func testAddingRejectsUnusableAndDuplicateEntries() {
        XCTAssertNil(MCPRedactionPolicy.redactAll.addingException("*"))

        let once = MCPRedactionPolicy(isEnabled: true, exceptedHosts: ["api.example.com"])
        XCTAssertNil(once.addingException("API.example.com."), "same host, different spelling")
    }

    func testRemovingTakesEverySpellingOfTheHost() {
        let policy = MCPRedactionPolicy(
            isEnabled: true,
            exceptedHosts: ["API.example.com", "api.example.com.", "other.example.com"]
        )

        let updated = policy.removingException("api.example.com")

        XCTAssertEqual(updated.exceptedHosts, ["other.example.com"])
        XCTAssertTrue(updated.shouldRedact(host: "api.example.com"),
                      "a spelling left behind would keep excepting traffic the user thinks they removed")
    }

    /// A malformed row already in the list must be removable, or it sits there
    /// forever with no way to clear it.
    func testRemovingAnUnusableEntryStillWorks() {
        let policy = MCPRedactionPolicy(isEnabled: true, exceptedHosts: ["*", "api.example.com"])

        XCTAssertEqual(policy.removingException("*").exceptedHosts, ["api.example.com"])
    }

    func testARestoredPolicyMatchesTheOneThatWasSaved() throws {
        let policy = try XCTUnwrap(
            MCPRedactionPolicy.redactAll
                .addingException("api.example.com")?
                .addingException("*.staging.example.com")
        )

        let data = try JSONEncoder().encode(policy)
        let restored = MCPRedactionPolicy.decoding(data)

        XCTAssertEqual(restored, policy)
        XCTAssertFalse(restored.shouldRedact(host: "www.staging.example.com"))
    }
}
