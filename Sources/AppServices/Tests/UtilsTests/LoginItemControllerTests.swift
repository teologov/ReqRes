//
//  LoginItemControllerTests.swift
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
//  WHAT THESE TESTS COVER, AND WHAT THEY CANNOT.
//
//  Covered: the status → state mapping (every known case, plus an unknown
//  one), the raw values that mapping rests on, the error classification, the
//  user-facing strings, and the controller's own decisions with the
//  ServiceManagement calls injected.
//
//  NOT covered, deliberately: `SMAppService` itself. `register()` writes a
//  real login item into the user's real session and `status` reads it back, so
//  a test that called them would either change the machine it ran on or
//  report whatever that machine already happened to be set to. The default
//  closures in `LoginItemController.init` — the ones that reach the system —
//  are never executed here. What is tested is everything wrapped around them.
//
//  One guard is only half automatable. Swift cannot enumerate an imported C
//  enum: `SMAppService.Status(rawValue:)` accepts ANY integer (verified — it
//  returns a value for 4, 5, …) and every value prints the same way, so no
//  test can ask the runtime whether Apple has added a case. The real detector
//  is the `@unknown default` in `LoginItemState.init(status:)`, which makes
//  the compiler warn when a new case appears. What IS automatable is pinned
//  below: that the four known raw values still mean what the mapping assumes
//  (an inserted case would shift them and silently re-point every mapping),
//  and that an unrecognised status falls to `off` and never to `on`.
//

import XCTest
import ServiceManagement
@testable import Utils

final class LoginItemControllerTests: XCTestCase {

    // MARK: - Status → state

    func testEnabledIsOn() {
        XCTAssertEqual(LoginItemState(status: .enabled), .on)
        XCTAssertTrue(LoginItemState(status: .enabled).isOn)
    }

    func testNotRegisteredIsOff() {
        XCTAssertEqual(LoginItemState(status: .notRegistered), .off)
    }

    /// The case the whole type exists for. The user flipped the switch, macOS
    /// accepted the registration and is waiting for them in System Settings.
    /// Reported as `on` it promises a launch that will not happen; reported as
    /// a failure it invites a retry that changes nothing.
    func testRequiresApprovalIsNeitherOnNorOff() {
        let state = LoginItemState(status: .requiresApproval)

        XCTAssertEqual(state, .requiresApproval)
        XCTAssertNotEqual(state, .on)
        XCTAssertNotEqual(state, .off)
        XCTAssertFalse(state.isOn, "a pending approval must not read as enabled")
    }

    /// `.notFound` is not an error state here: whatever the system means by
    /// it, the app is not going to open at login, and that is what the user
    /// needs told.
    func testNotFoundIsOff() {
        XCTAssertEqual(LoginItemState(status: .notFound), .off)
    }

    /// Half of the new-case guard: the mapping is written against these four
    /// meanings, and the raw values are what the runtime actually hands over.
    /// A case inserted by a future SDK would shift them — `enabled` would stop
    /// being 1 — and every mapping would silently re-point without a single
    /// compile error. This fails first if that ever happens.
    func testTheKnownStatusRawValuesHaveNotMoved() {
        XCTAssertEqual(SMAppService.Status.notRegistered.rawValue, 0)
        XCTAssertEqual(SMAppService.Status.enabled.rawValue, 1)
        XCTAssertEqual(SMAppService.Status.requiresApproval.rawValue, 2)
        XCTAssertEqual(SMAppService.Status.notFound.rawValue, 3)
    }

    /// Every known case maps somewhere deliberate, read back by raw value so
    /// the table is checked against what the runtime produces rather than
    /// against the same symbols the mapping was written with.
    func testEveryKnownStatusMapsToADocumentedState() {
        let expected: [Int: LoginItemState] = [
            0: .off,               // notRegistered
            1: .on,                // enabled
            2: .requiresApproval,  // requiresApproval
            3: .off,               // notFound
        ]

        for (raw, state) in expected {
            guard let status = SMAppService.Status(rawValue: raw) else {
                return XCTFail("raw value \(raw) is no longer a status")
            }
            XCTAssertEqual(LoginItemState(status: status), state,
                           "status raw value \(raw) maps to the wrong state")
        }
    }

    /// The other half of the guard: anything unrecognised fails toward OFF.
    /// Never claim the app opens at login when we cannot tell.
    func testAnUnrecognisedStatusFailsToOff() {
        guard let future = SMAppService.Status(rawValue: 99) else {
            return XCTFail("could not construct an unrecognised status")
        }

        XCTAssertEqual(LoginItemState(status: future), .off)
        XCTAssertFalse(LoginItemState(status: future).isOn)
    }

    // MARK: - The strings the user reads

    /// The sentence this whole feature is constrained by. Capture is a
    /// separate, deliberate action, and the screen has to say so — a login
    /// that silently started decrypting TLS would break the user's own builds
    /// (`codesign` refuses a re-signed timestamp, naming an unrelated
    /// framework) with nothing to connect it to.
    func testTheCaptureDisclaimerSaysCaptureDoesNotStart() {
        let disclaimer = LoginItemController.captureDisclaimer.lowercased()

        XCTAssertTrue(disclaimer.contains("does not start capture"),
                      "the disclaimer no longer says capture does not start: "
                        + LoginItemController.captureDisclaimer)
    }

    /// The "on" line is where the promise would most easily be lost — it is
    /// the one read by someone who has just switched this on.
    func testTheOnSummarySaysCaptureStaysOff() {
        let summary = LoginItemState.on.summary.lowercased()

        XCTAssertTrue(summary.contains("capture stays off"),
                      "the on-state summary stopped saying capture stays off: "
                        + LoginItemState.on.summary)
    }

    /// No string may promise that capture starts. This is a blunt check on
    /// purpose: it should fail on any rewrite that reaches for those words,
    /// and a rewrite is exactly when the promise gets dropped.
    func testNoStringClaimsCaptureStartsAtLogin() {
        let forbidden = ["starts capture", "start capturing", "starts capturing",
                         "begins capture", "capture starts"]
        var strings = [LoginItemController.captureDisclaimer,
                       LoginItemController.toggleTitle,
                       LoginItemController.openSettingsButtonTitle]
        strings += LoginItemState.allCases.map(\.summary)
        strings += [LoginItemError.deniedByUser,
                    .notSigned,
                    .failed(code: 1, message: "x")]
            .flatMap { [$0.errorDescription, $0.recoverySuggestion].compactMap { $0 } }

        for string in strings {
            let lowered = string.lowercased()
            for phrase in forbidden {
                XCTAssertFalse(lowered.contains(phrase),
                               "\"\(string)\" implies capture starts at login")
            }
        }
    }

    /// The toggle's own label. "Open", not "start" — the app opens, nothing
    /// else does.
    func testTheToggleTitleIsAboutOpeningTheApp() {
        XCTAssertEqual(LoginItemController.toggleTitle, "Open ReqRes at login")
    }

    func testEveryStateVendsASummary() {
        for state in LoginItemState.allCases {
            XCTAssertFalse(state.summary.isEmpty, "\(state) has no summary")
        }
    }

    /// The button exists only where there is something to go and do. Offering
    /// "Open Login Items" beside a working toggle is noise; withholding it
    /// from a pending approval leaves the user stuck.
    func testOnlyThePendingApprovalStateOffersTheSettingsButton() {
        XCTAssertEqual(LoginItemState.requiresApproval.settingsButtonTitle,
                       LoginItemController.openSettingsButtonTitle)
        XCTAssertNil(LoginItemState.on.settingsButtonTitle)
        XCTAssertNil(LoginItemState.off.settingsButtonTitle)
    }

    // MARK: - Error classification

    private func smError(_ code: Int) -> NSError {
        NSError(domain: "SMAppServiceErrorDomain", code: code,
                userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
    }

    /// The case the UI must be able to act on: the user denied it, a retry
    /// changes nothing, and the only useful offer is the Login Items pane.
    func testADeniedRegistrationIsDistinguishable() {
        let failure = LoginItemError.classify(smError(kSMErrorLaunchDeniedByUser), requesting: true)

        XCTAssertEqual(failure, .deniedByUser)
        XCTAssertEqual(failure?.suggestsOpeningLoginItems, true)
        XCTAssertNotNil(failure?.errorDescription)
        XCTAssertNotNil(failure?.recoverySuggestion)
    }

    /// Already registered, and registering was what was asked for. The user
    /// has the state they wanted; an error alert here would be about nothing.
    func testAlreadyRegisteredIsNotAFailureWhenEnabling() {
        XCTAssertNil(LoginItemError.classify(smError(kSMErrorAlreadyRegistered), requesting: true))
    }

    /// The same code answering an UNREGISTER is a real failure — the request
    /// was to stop opening at login and the system says it is still on.
    func testAlreadyRegisteredIsAFailureWhenDisabling() {
        XCTAssertEqual(LoginItemError.classify(smError(kSMErrorAlreadyRegistered), requesting: false),
                       .failed(code: kSMErrorAlreadyRegistered, message: "Operation not permitted"))
    }

    func testJobNotFoundIsNotAFailureWhenDisabling() {
        XCTAssertNil(LoginItemError.classify(smError(kSMErrorJobNotFound), requesting: false))
    }

    func testJobNotFoundIsAFailureWhenEnabling() {
        XCTAssertEqual(LoginItemError.classify(smError(kSMErrorJobNotFound), requesting: true),
                       .failed(code: kSMErrorJobNotFound, message: "Operation not permitted"))
    }

    func testAnInvalidSignatureIsItsOwnCase() {
        XCTAssertEqual(LoginItemError.classify(smError(kSMErrorInvalidSignature), requesting: true),
                       .notSigned)
        XCTAssertEqual(LoginItemError.notSigned.suggestsOpeningLoginItems, false)
    }

    /// An unknown code keeps its number and message rather than collapsing
    /// into "something went wrong" — the code is what makes a bug report
    /// actionable.
    func testAnUnknownCodeKeepsItsDetail() {
        let failure = LoginItemError.classify(smError(4242), requesting: true)

        XCTAssertEqual(failure, .failed(code: 4242, message: "Operation not permitted"))
        XCTAssertEqual(failure?.errorDescription?.contains("4242"), true)
        XCTAssertEqual(failure?.suggestsOpeningLoginItems, false)
    }

    // MARK: - The controller's own decisions

    /// Single-threaded by construction: every test drives it inline.
    private final class Calls: @unchecked Sendable {
        var registers = 0
        var unregisters = 0
        var settingsOpens = 0
        var status: SMAppService.Status = .notRegistered
        var registerError: Error?
        var unregisterError: Error?
    }

    private func controller(_ calls: Calls) -> LoginItemController {
        LoginItemController(
            readStatus: { calls.status },
            register: {
                calls.registers += 1
                if let error = calls.registerError { throw error }
            },
            unregister: {
                calls.unregisters += 1
                if let error = calls.unregisterError { throw error }
            },
            openLoginItemsSettings: { calls.settingsOpens += 1 }
        )
    }

    func testStateAndIsEnabledFollowTheStatus() {
        let calls = Calls()
        let subject = controller(calls)

        calls.status = .enabled
        XCTAssertEqual(subject.state, .on)
        XCTAssertTrue(subject.isEnabled)

        calls.status = .requiresApproval
        XCTAssertEqual(subject.state, .requiresApproval)
        XCTAssertFalse(subject.isEnabled, "approval pending is not enabled")

        calls.status = .notRegistered
        XCTAssertEqual(subject.state, .off)
        XCTAssertFalse(subject.isEnabled)
    }

    /// Read every time, not cached: the user can revoke this in System
    /// Settings while the app is running.
    func testTheStatusIsReadEveryTime() {
        let calls = Calls()
        let subject = controller(calls)

        calls.status = .notRegistered
        XCTAssertFalse(subject.isEnabled)
        calls.status = .enabled
        XCTAssertTrue(subject.isEnabled)
    }

    func testSetEnabledRegistersAndUnregisters() throws {
        let calls = Calls()
        let subject = controller(calls)

        try subject.setEnabled(true)
        XCTAssertEqual(calls.registers, 1)
        XCTAssertEqual(calls.unregisters, 0)

        try subject.setEnabled(false)
        XCTAssertEqual(calls.registers, 1)
        XCTAssertEqual(calls.unregisters, 1)
    }

    func testSetEnabledRethrowsADenial() {
        let calls = Calls()
        calls.registerError = smError(kSMErrorLaunchDeniedByUser)
        let subject = controller(calls)

        XCTAssertThrowsError(try subject.setEnabled(true)) { error in
            XCTAssertEqual(error as? LoginItemError, .deniedByUser)
        }
    }

    /// The system was already in the state that was asked for. Nothing to
    /// report — a thrown error here would be a toggle that looks broken while
    /// working exactly as intended.
    func testSetEnabledSwallowsAnAlreadyInStateError() throws {
        let calls = Calls()
        calls.registerError = smError(kSMErrorAlreadyRegistered)
        calls.unregisterError = smError(kSMErrorJobNotFound)
        let subject = controller(calls)

        XCTAssertNoThrow(try subject.setEnabled(true))
        XCTAssertNoThrow(try subject.setEnabled(false))
    }

    func testOpenLoginItemsSettingsCallsThrough() {
        let calls = Calls()
        let subject = controller(calls)

        subject.openLoginItemsSettings()

        XCTAssertEqual(calls.settingsOpens, 1)
    }
}
