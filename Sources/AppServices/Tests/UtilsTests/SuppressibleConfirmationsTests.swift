//
//  SuppressibleConfirmationsTests.swift
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
//  Every test runs against a throwaway suite, never `UserDefaults.standard`:
//  the standard suite here is the DEVELOPER'S OWN app container (Debug and the
//  installed build share it), and a test that reset it would turn the
//  developer's real “Don’t ask again” answers back on — or, worse, off.
//

import XCTest
@testable import Utils

final class SuppressibleConfirmationsTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults()

    override func setUp() {
        super.setUp()
        suiteName = "SuppressibleConfirmationsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The shipped key's exact spelling. It is written by the delete-override
    /// alert in installs going back to 1.0.x, so renaming it would un-suppress
    /// the prompt for everyone who already answered — this test is the tripwire.
    func testTheShippedRuleDeleteKeyKeepsItsSpelling() {
        XCTAssertEqual(SuppressibleConfirmations.ruleDelete, "skipRuleDeleteConfirmation")
    }

    func testResetClearsEveryKey() {
        for key in SuppressibleConfirmations.all {
            defaults.set(true, forKey: key)
        }

        SuppressibleConfirmations.resetAll(in: defaults)

        for key in SuppressibleConfirmations.all {
            XCTAssertFalse(defaults.bool(forKey: key), "\(key) survived the reset")
            // Removed, not written false: the stored state goes back to
            // never-answered rather than answered-no.
            XCTAssertNil(defaults.object(forKey: key), "\(key) was written rather than removed")
        }
    }

    /// A reset must not depend on every key having been set. A user who
    /// suppressed one prompt and not the others is the common case.
    func testResetIsSafeWhenNothingWasSuppressed() {
        SuppressibleConfirmations.resetAll(in: defaults)

        XCTAssertFalse(SuppressibleConfirmations.anySuppressed(in: defaults))
    }

    func testResetLeavesUnrelatedDefaultsAlone() {
        defaults.set(true, forKey: SuppressibleConfirmations.ruleDelete)
        defaults.set("kept", forKey: "SomeUnrelatedPreference")

        SuppressibleConfirmations.resetAll(in: defaults)

        XCTAssertEqual(defaults.string(forKey: "SomeUnrelatedPreference"), "kept")
    }

    /// A duplicate would mean two prompts sharing one key — ticking “Don’t ask
    /// again” on one would silence the other, which is the copy-paste this
    /// list invites.
    func testTheKeyListHasNoDuplicates() {
        XCTAssertEqual(Set(SuppressibleConfirmations.all).count,
                       SuppressibleConfirmations.all.count,
                       "duplicate key in SuppressibleConfirmations.all: \(SuppressibleConfirmations.all)")
    }

    /// Every declared prompt is in `all`; a key that is not there is invisible
    /// to the reset, which is the whole point of the type.
    func testEveryDeclaredPromptIsListed() {
        for key in [SuppressibleConfirmations.ruleDelete,
                    SuppressibleConfirmations.hostDelete,
                    SuppressibleConfirmations.clearTraffic] {
            XCTAssertTrue(SuppressibleConfirmations.all.contains(key), "\(key) is missing from `all`")
        }
    }

    func testAnySuppressedReportsASingleTickedPrompt() {
        XCTAssertFalse(SuppressibleConfirmations.anySuppressed(in: defaults))

        defaults.set(true, forKey: SuppressibleConfirmations.hostDelete)

        XCTAssertTrue(SuppressibleConfirmations.anySuppressed(in: defaults))
    }

    // MARK: - The checkbox

    /// macOS 27's own words for the suppression button of an alert with two
    /// buttons or more, typographic apostrophe included — the app sets them
    /// because older macOS may word it otherwise (NSAlert.h: "Do not ask
    /// again" since macOS 11), and Settings quotes the same constant.
    func testTheCheckboxTitleIsMacOSsOwnWording() {
        XCTAssertEqual(SuppressibleConfirmations.checkboxTitle, "Don\u{2019}t ask again")
        XCTAssertEqual(SuppressibleConfirmations.checkboxTitle.unicodeScalars.map(\.value)[3], 0x2019)
        XCTAssertFalse(SuppressibleConfirmations.checkboxTitle.contains("'"), "a straight apostrophe")
    }

    /// The whole truth table: only the action chosen with the box ticked turns
    /// a prompt off. Cancel with the box ticked must leave the guard in place.
    func testOnlyTheActionChosenWithTheBoxTickedIsRemembered() {
        XCTAssertTrue(SuppressibleConfirmations.remembersChoice(confirmed: true, ticked: true))
        XCTAssertFalse(SuppressibleConfirmations.remembersChoice(confirmed: true, ticked: false),
                       "the action without the box")
        XCTAssertFalse(SuppressibleConfirmations.remembersChoice(confirmed: false, ticked: true),
                       "Cancel with the box ticked")
        XCTAssertFalse(SuppressibleConfirmations.remembersChoice(confirmed: false, ticked: false))
    }

    // MARK: - Clear Captured Traffic

    private let english = Locale(identifier: "en_US")
    /// Everything after the count, as the alert has always said it.
    private let afterTheCount = " will be discarded. Captured traffic is held in memory only — anything you have not saved cannot be recovered, and rerunning a request produces a different exchange.\n\nSaved sessions are not affected."

    func testOneRequestIsSingularAndTwoArePlural() {
        XCTAssertEqual(SuppressibleConfirmations.clearTrafficMessage(count: 1, locale: english),
                       "1 captured request" + afterTheCount)
        XCTAssertEqual(SuppressibleConfirmations.clearTrafficMessage(count: 2, locale: english),
                       "2 captured requests" + afterTheCount)
    }

    /// A screenshot read "1127 captured requests".
    func testTheCountIsGrouped() {
        XCTAssertEqual(SuppressibleConfirmations.clearTrafficMessage(count: 1127, locale: english),
                       "1,127 captured requests" + afterTheCount)
        XCTAssertEqual(SuppressibleConfirmations.clearTrafficMessage(count: 1_000_000, locale: english),
                       "1,000,000 captured requests" + afterTheCount)
    }

    /// The grouping is the locale's, not a hard-coded comma.
    func testTheCountIsGroupedTheLocalesWay() {
        XCTAssertEqual(SuppressibleConfirmations.clearTrafficMessage(count: 1127, locale: Locale(identifier: "de_DE")),
                       "1.127 captured requests" + afterTheCount)
    }

    /// Below a thousand nothing changed: the text is character for character
    /// what the alert built inline before (TrafficCommands.clearTraffic at
    /// 8ee16de), reproduced here the way it was written there.
    func testBelowAThousandTheTextIsWhatTheAlertAlwaysSaid() {
        for count in [0, 1, 2, 999] {
            let before = """
            \(count == 1 ? "1 captured request" : "\(count) captured requests") \
            will be discarded. Captured traffic is held in memory only — anything \
            you have not saved cannot be recovered, and rerunning a request \
            produces a different exchange.

            Saved sessions are not affected.
            """
            XCTAssertEqual(SuppressibleConfirmations.clearTrafficMessage(count: count, locale: english), before)
        }
    }
}
