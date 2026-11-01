//
//  TunnelStartFailureTests.swift
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
//  Build 53 (core 95062d1): a start the extension refuses says why. The old
//  entry point mapped every failure to nil, and the extension called each one
//  a busy port — a start from System Settings with ReqRes closed (which used
//  to trap the extension) read "Another app may be using the port".
//

import XCTest
@testable import Utils

final class TunnelStartFailureTests: XCTestCase {
    private let all: [TunnelStartFailure] = [.startedOutsideReqRes, .settingsUnreadable("disk I/O error"), .interrupted,
                                             .failed("a reason from a later core")]

    /// Each says what to do first — start capture from ReqRes — and none
    /// blames a port, which none of them is about.
    func testEachStartsWithWhatToDoAndNoneBlamesAPort() {
        for failure in all {
            XCTAssertTrue(failure.message.hasPrefix("Start capture from ReqRes"), failure.message)
            XCTAssertTrue(failure.message.hasSuffix("."), failure.message)
            XCTAssertFalse(failure.message.lowercased().contains("port"), failure.message)
        }
        XCTAssertTrue(TunnelStartFailure.startedOutsideReqRes.message.contains("System Settings"))
        XCTAssertTrue(TunnelStartFailure.settingsUnreadable("disk I/O error").message.contains("(disk I/O error)"))
        XCTAssertEqual(TunnelStartFailure.settingsUnreadable("  ").message,
                       "Start capture from ReqRes again. Its extension could not read its capture settings. If it keeps failing, restart the Mac.")
    }

    /// The words travel as the error's description, set explicitly: a Swift
    /// error's own description stays in the extension's process, and the app
    /// then saw only Foundation's "The operation couldn't be completed."
    func testTheDescriptionTravelsWithTheError() {
        for failure in all {
            let error = failure.error
            XCTAssertEqual(error.domain, TunnelStartFailure.errorDomain)
            XCTAssertEqual(error.code, failure.code)
            XCTAssertEqual(error.userInfo[NSLocalizedDescriptionKey] as? String, failure.message)
            XCTAssertEqual(error.localizedDescription, failure.message)
            // The app's "Capture did not start" alert shows a reason only when
            // it is not Foundation's generic text (`ProxyPortSetting`).
            XCTAssertEqual(ProxyPortSetting.startFailedReason(for: error), failure.message)
        }
        XCTAssertEqual(Set(all.map(\.code)).count, all.count)
    }

    /// The person's own choice is not a fault for crash reporting.
    func testOnlyFaultsAreReported() {
        XCTAssertFalse(TunnelStartFailure.startedOutsideReqRes.isReportable)
        XCTAssertTrue(TunnelStartFailure.settingsUnreadable("x").isReportable)
        XCTAssertTrue(TunnelStartFailure.interrupted.isReportable)
        XCTAssertTrue(TunnelStartFailure.failed("x").isReportable)
    }

    // MARK: - Read back in the app (review of build 53)

    /// "Capture did not start" led with the busy-port advice whatever the
    /// extension said. Its own reason is said alone now — read from the
    /// description when NetworkExtension kept it, else from the code, which
    /// every NSError keeps.
    func testTheAlertSaysTheExtensionsReasonAlone() {
        for failure in all {
            let kept = TunnelStartFailure.didNotStartMessage(port: 8035, error: failure.error)
            XCTAssertEqual(kept, failure.message)
            XCTAssertFalse(kept.contains("8035"), kept)

            // The description lost on the way: Foundation's generic text.
            let bare = NSError(domain: TunnelStartFailure.errorDomain, code: failure.code)
            XCTAssertEqual(TunnelStartFailure(readBack: bare)?.code, failure.code)
            let fromCode = TunnelStartFailure.didNotStartMessage(port: 8035, error: bare)
            XCTAssertTrue(fromCode.hasPrefix("Start capture from ReqRes"), fromCode)
            XCTAssertFalse(fromCode.contains("8035"), fromCode)
            XCTAssertFalse(fromCode.contains(TunnelStartFailure.errorDomain), "never Foundation's text: \(fromCode)")
        }
        XCTAssertEqual(TunnelStartFailure.didNotStartMessage(port: 8035, error: NSError(domain: TunnelStartFailure.errorDomain, code: 1)),
                       TunnelStartFailure.startedOutsideReqRes.message)
    }

    /// Any other error, or none, keeps the port's message — with the system's
    /// reason when it is worth reading.
    func testOtherFailuresKeepThePortsMessage() {
        XCTAssertEqual(TunnelStartFailure.didNotStartMessage(port: 8035, error: nil),
                       ProxyPortSetting.startFailedMessage(port: 8035, reason: nil))
        let described = NSError(domain: "NEVPNErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "The VPN plugin died unexpectedly."])
        XCTAssertEqual(TunnelStartFailure.didNotStartMessage(port: 8035, error: described),
                       ProxyPortSetting.startFailedMessage(port: 8035, reason: "The VPN plugin died unexpectedly."))
        let generic = NSError(domain: "NEVPNErrorDomain", code: 1)
        XCTAssertEqual(TunnelStartFailure.didNotStartMessage(port: 8035, error: generic),
                       ProxyPortSetting.startFailedMessage(port: 8035, reason: nil))
        XCTAssertNil(TunnelStartFailure(readBack: NSError(domain: TunnelStartFailure.errorDomain, code: 99)), "a code this build does not know")
        XCTAssertNil(TunnelStartFailure(readBack: generic))
    }
}
