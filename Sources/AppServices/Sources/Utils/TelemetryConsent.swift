//
//  TelemetryConsent.swift
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
//  Whether crash reporting may run — the ONE answer both processes read.
//
//  Why the app-group suite and not `UserDefaults.standard`: crash reporting
//  starts TWICE, once in the app and once in the Network Extension, which is a
//  separate process running as root with its own container. The extension can
//  never see the app's standard defaults, and it starts Sentry inside
//  `startTunnel` — before the TCP message bus to the app exists — so the bus
//  cannot carry the answer either. The app group is the only channel already
//  readable at that moment; it is what the CA certificate files travel
//  through for exactly the same reason.
//
//  The group id itself is deliberately NOT written here. `Utils` is Foundation
//  only and is linked by both targets; the identifier lives in the core
//  (`AppGroup.identifier`), and the caller passes the suite in.
//

import Foundation

/// The user's crash-reporting choice, stored where both processes can read it.
///
/// Callers hand in the defaults to read — in the app and the extension that is
/// `UserDefaults(suiteName: AppGroup.identifier)`; in tests it is a throwaway suite.
public enum TelemetryConsent {
    /// The stored key. Absent means never answered, which reads as enabled.
    public static let key = "crashReportingEnabled"

    /// The Sentry traces sample rate a released build should send.
    ///
    /// The app has been starting Sentry at `tracesSampleRate = 1.0` since
    /// 1.0.x — a development value whose own comment said it "can be dropped
    /// to 0.1 (10%) in the future" and never was, so every shipped install
    /// sends a performance trace for every transaction. The extension already
    /// uses 0.1; this is that number, so the two processes stop disagreeing
    /// about how much they send.
    public static let sampleRate: Double = 0.1

    /// The key this consent travels under in the tunnel's start options.
    ///
    /// The app group cannot carry it: the extension runs as ROOT and would
    /// read root's copy of the group defaults, not the user's, so an opt-out
    /// never reached it. The start options are the channel that already
    /// crosses this boundary for the CA flag, and they arrive in `startTunnel`
    /// where `initSentry()` runs.
    public static let startOptionKey = "crashReportingEnabled"

    /// The defaults shared by the app and the extension.
    ///
    /// Returns nil only when the process is not a member of the group — which
    /// is a provisioning/entitlement failure, not a user state, so a caller
    /// should fall back to its own answer rather than treat nil as consent.
    public static func groupDefaults(appGroupID: String) -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// True when crash reports may be sent.
    ///
    /// Unset reads as TRUE on purpose: crash reporting is on in every shipped
    /// 1.0.x build, and this release adds the ability to turn it OFF. Defaulting
    /// an existing install to false would silently change behaviour for users
    /// who never made a choice — the opposite of what an opt-out means here.
    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        // `object(forKey:)`, not `bool(forKey:)`: the latter answers false for
        // both "the user opted out" and "nobody ever answered", and those two
        // states must not collapse into one.
        guard let stored = defaults.object(forKey: key) as? Bool else { return true }
        return stored
    }

    /// Records the user's choice.
    ///
    /// The value is written, not removed for `true`: an explicit yes is worth
    /// keeping distinct from never-asked if consent copy ever changes.
    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: key)
    }
}
