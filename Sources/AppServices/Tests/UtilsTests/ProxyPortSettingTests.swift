//
//  ProxyPortSettingTests.swift
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

final class ProxyPortSettingTests: XCTestCase {
    /// The same numbers core `ProxyPortTests.testTheRule` pins.
    func testTheRuleMatchesTheCore() {
        XCTAssertEqual(ProxyPortSetting.defaultPort, 8034)
        XCTAssertEqual(ProxyPortSetting.busPort, 50001)
        XCTAssertTrue(ProxyPortSetting.isAllowed(1024))
        XCTAssertTrue(ProxyPortSetting.isAllowed(65535))
        XCTAssertFalse(ProxyPortSetting.isAllowed(1023))
        XCTAssertFalse(ProxyPortSetting.isAllowed(65536))
        XCTAssertFalse(ProxyPortSetting.isAllowed(50001))
        XCTAssertEqual(ProxyPortSetting.defaultsKey, "CaptureProxyPort")
    }

    func testTheStoredPortFallsBackToTheDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ProxyPortSettingTests-\(UUID().uuidString)"))
        XCTAssertEqual(ProxyPortSetting.current(in: defaults), 8034, "nothing stored")
        defaults.set(9034, forKey: ProxyPortSetting.defaultsKey)
        XCTAssertEqual(ProxyPortSetting.current(in: defaults), 9034)
        defaults.set(50001, forKey: ProxyPortSetting.defaultsKey)
        XCTAssertEqual(ProxyPortSetting.current(in: defaults), 8034, "a refused port is not used")
    }

    func testWhatTheFieldRefuses() {
        XCTAssertNil(ProxyPortSetting.problem(with: "9034"))
        XCTAssertNil(ProxyPortSetting.problem(with: " 9034 "))
        XCTAssertNotNil(ProxyPortSetting.problem(with: "80"))
        XCTAssertNotNil(ProxyPortSetting.problem(with: "70000"))
        XCTAssertNotNil(ProxyPortSetting.problem(with: "50001"))
        XCTAssertNotNil(ProxyPortSetting.problem(with: "abc"))
        XCTAssertNotNil(ProxyPortSetting.problem(with: "80.5"))
        XCTAssertNotNil(ProxyPortSetting.problem(with: "+9034"))
    }

    /// F13: the note under the field belongs to the text Apply refused — any
    /// edit hides it, and a text with no problem never has one.
    func testTheFieldsNoteBelongsToTheTextApplyRefused() {
        XCTAssertEqual(ProxyPortSetting.problem(submitted: "80", current: "80"), ProxyPortSetting.problem(with: "80"))
        XCTAssertNotNil(ProxyPortSetting.problem(submitted: "80", current: "80"))
        XCTAssertEqual(ProxyPortSetting.problem(submitted: "50001", current: "50001"),
                       "50001 is ReqRes's own port between the app and its extension.")
        XCTAssertNil(ProxyPortSetting.problem(submitted: "80", current: "8"), "the field edited")
        XCTAssertNil(ProxyPortSetting.problem(submitted: "80", current: ""), "the field emptied")
        XCTAssertNil(ProxyPortSetting.problem(submitted: "80", current: "8080"), "a new number, not yet applied")
        XCTAssertNil(ProxyPortSetting.problem(submitted: nil, current: "80"), "typing is not applying")
        XCTAssertNil(ProxyPortSetting.problem(submitted: "9034", current: "9034"))
    }

    /// A busy port is answered with the next free one, never the bus's.
    func testTheSuggestionSkipsBusyPortsAndTheBus() {
        XCTAssertEqual(ProxyPortSetting.suggestion(after: 8034) { $0 != 8035 }, 8036)
        XCTAssertEqual(ProxyPortSetting.suggestion(after: 50000) { _ in true }, 50002)
        XCTAssertEqual(ProxyPortSetting.suggestion(after: 65535) { _ in true }, 1024, "wraps")
        XCTAssertNil(ProxyPortSetting.suggestion(after: 8034, attempts: 3) { _ in false })
    }

    func testTheConflictNamesTheHolderAndTheOffer() {
        let named = ProxyPortSetting.conflictMessage(port: 8034, holder: "Charles", suggestion: 8035)
        XCTAssertTrue(named.hasPrefix("Charles is listening on 127.0.0.1:8034"), named)
        XCTAssertTrue(named.contains("Use port 8035 instead?"), named)
        let unnamed = ProxyPortSetting.conflictMessage(port: 8034, holder: nil, suggestion: nil)
        XCTAssertTrue(unnamed.hasPrefix("Another program is listening"), unnamed)
        XCTAssertTrue(unnamed.contains("choose another port in Settings ▸ Capture"), unnamed)
        XCTAssertEqual(ProxyPortSetting.useButton(8035), "Use Port 8035")
    }

    /// A start the preflight let through and the extension then refused.
    func testAStartThatNeverConnectedIsSaidWithThePort() {
        XCTAssertEqual(ProxyPortSetting.startFailedTitle, "Capture did not start")
        let plain = ProxyPortSetting.startFailedMessage(port: 8035, reason: nil)
        XCTAssertTrue(plain.contains("127.0.0.1:8035"), plain)
        XCTAssertTrue(plain.contains("choose another port in Settings ▸ Capture"), plain)
        XCTAssertFalse(plain.contains("The system reported"), plain)
        let reasoned = ProxyPortSetting.startFailedMessage(port: 8035, reason: "The VPN plugin died unexpectedly.")
        XCTAssertTrue(reasoned.hasPrefix(plain), reasoned)
        XCTAssertTrue(reasoned.hasSuffix("\n\nThe system reported: The VPN plugin died unexpectedly."), reasoned)
    }

    /// The extension's own error crosses without its words: the generic text
    /// left behind is kept out of the alert, a real description is shown.
    func testOnlyARealDescriptionIsShownAsTheReason() {
        let bare = NSError(domain: "vpn_tunnel.TunnelStartError", code: 0)
        XCTAssertNil(ProxyPortSetting.startFailedReason(for: bare), bare.localizedDescription)
        let described = NSError(domain: "NEVPNConnectionErrorDomain", code: 12,
                                userInfo: [NSLocalizedDescriptionKey: "The VPN plugin died unexpectedly."])
        XCTAssertEqual(ProxyPortSetting.startFailedReason(for: described), "The VPN plugin died unexpectedly.")
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE))
        XCTAssertEqual(ProxyPortSetting.startFailedReason(for: posix), posix.localizedDescription,
                       "a system domain describes itself: \(posix.localizedDescription)")
        let helper = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)
        XCTAssertEqual(ProxyPortSetting.startFailedReason(for: helper), helper.localizedDescription,
                       "a Cocoa code Foundation has words for: \(helper.localizedDescription)")
    }

    /// Foundation's generic text for its OWN domains abbreviates them, so the
    /// raw domain is not in it — the "error <code>" is.
    func testTheGenericTextOfAnAbbreviatedDomainIsNotShown() {
        let generic = [
            NSError(domain: NSOSStatusErrorDomain, code: -1),        // "(OSStatus error -1.)"
            NSError(domain: NSCocoaErrorDomain, code: 99999),        // "(Cocoa error 99999.)"
            NSError(domain: NSMachErrorDomain, code: 268435459),     // "(Mach error 268435459 - (ipc/send) …)"
            NSError(domain: NSURLErrorDomain, code: -1004),
        ]
        for error in generic {
            XCTAssertNil(ProxyPortSetting.startFailedReason(for: error), error.localizedDescription)
        }
    }
}
