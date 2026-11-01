//
//  TelemetryConsentTests.swift
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
//  Every test runs against a throwaway suite, never `UserDefaults.standard`
//  and never the real app group: the standard suite here is the DEVELOPER'S OWN
//  app container (Debug and the installed build share it), so a test writing
//  this key would silently change whether the developer's own build reports
//  crashes.
//

import XCTest
@testable import Utils

final class TelemetryConsentTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults()

    override func setUp() {
        super.setUp()
        suiteName = "TelemetryConsentTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The shipped behaviour: crash reporting is on in every 1.0.x install, so
    /// an install that has never seen the toggle must keep reporting.
    func testUnsetReadsAsEnabled() {
        XCTAssertNil(defaults.object(forKey: TelemetryConsent.key), "suite was not clean")
        XCTAssertTrue(TelemetryConsent.isEnabled(in: defaults))
    }

    func testRoundTrip() {
        TelemetryConsent.setEnabled(false, in: defaults)
        XCTAssertFalse(TelemetryConsent.isEnabled(in: defaults))

        TelemetryConsent.setEnabled(true, in: defaults)
        XCTAssertTrue(TelemetryConsent.isEnabled(in: defaults))
    }

    /// The one that matters: an opt-out must survive being read back, which it
    /// only does if `isEnabled` inspects the KEY. A `bool(forKey:)`-shaped
    /// implementation cannot tell an explicit false from never-answered, and
    /// since never-answered has to mean true, it would hand a user who opted
    /// out their crash reporting back on the next launch.
    func testAnExplicitOptOutIsNotMistakenForUnset() {
        TelemetryConsent.setEnabled(false, in: defaults)

        // Same suite name, fresh instance — the state has to come off disk,
        // not out of the object the test just wrote to.
        let reread = UserDefaults(suiteName: suiteName)!
        XCTAssertNotNil(reread.object(forKey: TelemetryConsent.key))
        XCTAssertFalse(TelemetryConsent.isEnabled(in: reread))
    }

    /// A released build should not be sending a trace for every transaction;
    /// the app's 1.0 was a development value. Pinning it here means changing it
    /// is a decision someone makes, not a drift.
    func testSampleRateIsTheReleaseValue() {
        XCTAssertEqual(TelemetryConsent.sampleRate, 0.1, accuracy: 0.0001)
    }
}
