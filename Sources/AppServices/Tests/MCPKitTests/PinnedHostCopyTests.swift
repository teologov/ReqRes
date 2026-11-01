//
//  PinnedHostCopyTests.swift
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
//  An SSL-pinned relay — a host macOS pins, or an app that refused ReqRes's
//  certificate — reads as "SSL pinned", never as "the certificate was not
//  trusted" (live-run F5 and WhatsApp's media, 2026-09-29).
//

import XCTest
@testable import MCPKit

final class PinnedHostCopyTests: XCTestCase {
    func testThePoliciesMeasuredLiveHaveNames() {
        XCTAssertEqual(PinnedHostCopy.serviceName(policy: "MMCS"), "iCloud")
        XCTAssertEqual(PinnedHostCopy.serviceName(policy: "Pallas"), "Software Update")
        XCTAssertEqual(PinnedHostCopy.serviceName(policy: "AMP"), "the App Store and Apple media")
        XCTAssertEqual(PinnedHostCopy.serviceName(policy: "SomethingNew"), "an Apple service")
        XCTAssertEqual(PinnedHostCopy.serviceAndPolicy("MMCS"), "iCloud (MMCS)")
    }

    /// With `pinnedBy`, every relay sentence is the pinned one — whatever the
    /// scheme; without it, nothing changes.
    func testPinnedByWinsOverTheSchemeAndItsAbsenceChangesNothing() {
        for scheme in ["https", "tcp", nil] as [String?] {
            XCTAssertEqual(RecordedExchangeCopy.relayTitle(scheme: scheme, pinnedBy: "MMCS"), "SSL pinned")
            XCTAssertEqual(RecordedExchangeCopy.relayRowWord(scheme: scheme, pinnedBy: "MMCS"), "SSL pinned by macOS · iCloud")
            XCTAssertEqual(RecordedExchangeCopy.relayExplanation(scheme: scheme, pinnedBy: "MMCS"), PinnedHostCopy.explanation(.macOS(policy: "MMCS"), appName: nil))
            XCTAssertEqual(RecordedExchangeCopy.relayRemedy(scheme: scheme, pinnedBy: "MMCS"), PinnedHostCopy.remedy(.macOS(policy: "MMCS")))
            XCTAssertEqual(RecordedExchangeCopy.relayCellHelp(scheme: scheme, pinnedBy: "MMCS"), PinnedHostCopy.cellHelp(.macOS(policy: "MMCS"), appName: nil))
            XCTAssertFalse(RecordedExchangeCopy.relayIsAboutTheCertificate(scheme: scheme, pinnedBy: "MMCS"))
        }
        XCTAssertEqual(RecordedExchangeCopy.relayRowWord(scheme: "https"), "not decrypted")
        XCTAssertEqual(RecordedExchangeCopy.relayRowWord(scheme: "tcp"), "not HTTP")
        XCTAssertTrue(RecordedExchangeCopy.relayIsAboutTheCertificate(scheme: "https", pinnedBy: nil))
        XCTAssertFalse(RecordedExchangeCopy.relayIsAboutTheCertificate(scheme: "tcp", pinnedBy: nil))
    }

    /// The pinned sentences never send the user to the certificate — which
    /// cannot help — and never claim the certificate was missing.
    func testThePinnedWordsDoNotBlameTheCertificate() {
        let words = [PinnedHostCopy.explanation(.macOS(policy: "AMP"), appName: nil), PinnedHostCopy.remedy(.macOS(policy: "AMP")),
                     PinnedHostCopy.cellHelp(.macOS(policy: "AMP"), appName: nil), PinnedHostCopy.helpBullet,
                     PinnedHostCopy.explanation(.app(domain: "whatsapp.net"), appName: "WhatsApp"), PinnedHostCopy.remedy(.app(domain: "whatsapp.net")),
                     PinnedHostCopy.settingsExplanation]
        for text in words {
            XCTAssertFalse(text.contains("not installed"), text)
            XCTAssertFalse(text.contains("Install and trust"), text)
        }
        XCTAssertTrue(PinnedHostCopy.explanation(.macOS(policy: "AMP"), appName: nil).contains("(AMP)"), "the policy is named")
    }

    /// An agent's row and detail say "SSL pinned by macOS", and the field survives
    /// the bridge's JSON; an app that predates it decodes as not pinned.
    func testTheAgentSeesThePinnedRow() throws {
        let summary = MCPSessionSummary(uid: "u1", host: "gateway.icloud.com", method: "CONNECT", url: "", scheme: "https",
                                        requestBodySize: 512, responseBodySize: 2048, kind: .relay, pinnedBy: "MMCS")
        let row = MCPTextFormat.relayRow(summary)
        XCTAssertTrue(row.contains("gateway.icloud.com:443"), row)
        XCTAssertTrue(row.contains("(SSL pinned by macOS · iCloud)"), row)
        XCTAssertFalse(row.contains("not decrypted"), row)

        let decoded = try JSONDecoder().decode(MCPSessionSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.pinnedBy, "MMCS")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        old.removeValue(forKey: "pinnedBy")
        XCTAssertNil(try JSONDecoder().decode(MCPSessionSummary.self, from: JSONSerialization.data(withJSONObject: old)).pinnedBy)
    }

    // MARK: - An app that pinned (learned pins)

    func testPinnedByReadsAsMacOSOrAnApp() {
        XCTAssertEqual(PinSource(pinnedBy: "MMCS"), .macOS(policy: "MMCS"))
        XCTAssertEqual(PinSource(pinnedBy: "app:whatsapp.net"), .app(domain: "whatsapp.net"))
        XCTAssertNil(PinSource(pinnedBy: nil))
        XCTAssertNil(PinSource(pinnedBy: ""))
    }

    /// Still in the table, but marked SSL pinned.
    func testAnAppsPinNamesTheAppAndTheDomain() {
        let pinnedBy = "app:whatsapp.net"
        XCTAssertEqual(RecordedExchangeCopy.relayTitle(scheme: "https", pinnedBy: pinnedBy), "SSL pinned")
        XCTAssertEqual(RecordedExchangeCopy.relayRowWord(scheme: "https", pinnedBy: pinnedBy, appName: "WhatsApp"), "SSL pinned by WhatsApp")
        XCTAssertEqual(RecordedExchangeCopy.relayRowWord(scheme: "https", pinnedBy: pinnedBy, appName: nil), "SSL pinned by the app")
        let explanation = RecordedExchangeCopy.relayExplanation(scheme: "https", pinnedBy: pinnedBy, appName: "WhatsApp")
        XCTAssertTrue(explanation.contains("WhatsApp refused ReqRes's certificate for whatsapp.net"), explanation)
        XCTAssertTrue(RecordedExchangeCopy.relayRemedy(scheme: "https", pinnedBy: pinnedBy).contains("SSL-pinned apps"))
        XCTAssertTrue(RecordedExchangeCopy.relayCellHelp(scheme: "https", pinnedBy: pinnedBy, appName: "WhatsApp").hasPrefix("SSL pinned by WhatsApp"))
        XCTAssertFalse(RecordedExchangeCopy.relayIsAboutTheCertificate(scheme: "https", pinnedBy: pinnedBy))

        let summary = MCPSessionSummary(uid: "u2", host: "media-dub4-1.cdn.whatsapp.net", method: "CONNECT", url: "", scheme: "https",
                                        app: "WhatsApp", kind: .relay, pinnedBy: pinnedBy)
        XCTAssertTrue(MCPTextFormat.relayRow(summary).contains("(SSL pinned by WhatsApp)"), MCPTextFormat.relayRow(summary))
        XCTAssertTrue(PinnedHostCopy.rememberedNote(appName: "WhatsApp", domain: "whatsapp.net").contains("WhatsApp's connections to whatsapp.net"))
    }
}
