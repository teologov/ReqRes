//
//  ProtocolSupportExclusionTests.swift
//  AppServices
//
//  Created by OloApps on 9/29/26.
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
//  The exclusion claims in Help, Settings ▸ Capture and the protocol table
//  (protocol-engine doc §S10), pinned to `ExcludedHostList` — the list the app
//  pushes to the extension. MCPKit cannot import Utils, so the check lives
//  here, where both are visible.
//

import XCTest
@testable import MCPKit
@testable import Utils

final class ProtocolSupportExclusionTests: XCTestCase {

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/UtilsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AppServices
    }

    private var excludedEntry: ProtocolSupportEntry? {
        ProtocolSupport.all.first { $0.id == "excluded" }
    }

    /// "timestamp.apple.com (code signing) and *.ls.apple.com (Apple Maps) are
    /// on it by default" — exactly the defaults, no more, no fewer.
    func testTheTableNamesExactlyTheDefaultExclusions() throws {
        let text = try XCTUnwrap(excludedEntry).whatToDo
        for host in ExcludedHostList.recommended {
            XCTAssertTrue(text.contains(host), "the table should name the default exclusion \(host)")
        }
        let named = ["timestamp.apple.com", "*.ls.apple.com"]
        XCTAssertEqual(Set(named), Set(ExcludedHostList.recommended), "a default was added or removed — say so in the table")

        // pay-once A16: the license server's fixed rows, named as fixed.
        XCTAssertTrue(text.contains("reqresapp.com and *.reqresapp.com, ReqRes's license server, are always excluded and cannot be removed."), text)
        XCTAssertEqual(ExcludedHostList.builtIn, ["reqresapp.com", "*.reqresapp.com"], "a built-in entry was added or removed — say so in the table")
        XCTAssertTrue(ExcludedHostList.builtInReason.hasPrefix("ReqRes's license server"), "the table and the Settings row give one reason")
        let list = ExcludedHostList(hosts: [])
        XCTAssertTrue(list.excludes("reqresapp.com") && list.excludes("api.reqresapp.com"), "the table's claim, with nothing listed")
        XCTAssertTrue(ExcludedHostList.builtIn.allSatisfy { list.removing($0).excludes($0 == "reqresapp.com" ? $0 : "api.reqresapp.com") },
                      "\"cannot be removed\"")
    }

    /// Help's codesign warning says timestamp.apple.com is excluded by default,
    /// over https:// and plain http:// alike (core C5 applies the list to plain
    /// requests by name, port stripped — the same normalisation as here).
    func testHelpsCodesignClaimIsTheDefaultList() throws {
        let list = ExcludedHostList()
        XCTAssertTrue(list.excludes("timestamp.apple.com"))
        XCTAssertTrue(list.excludes("timestamp.apple.com:80"), "a plain http:// Host header carries a port sometimes")
        XCTAssertTrue(list.excludes("TIMESTAMP.apple.com."), "matched without case or the FQDN dot")

        let help = try String(contentsOf: Self.packageRoot.appendingPathComponent("../UI/Views/Help/HelpContent.swift"), encoding: .utf8)
        XCTAssertTrue(help.contains("ReqRes excludes Apple’s timestamp service (timestamp.apple.com) from capture by default, over https:// and plain http:// alike"), "Help's codesign warning")
        XCTAssertFalse(help.contains("re-signs the response with the ReqRes CA"), "the old mechanism claim is unverified (PRD §5 Help :505) — do not bring it back")
        XCTAssertFalse(help.contains("pass through unread and unchanged"), "plain http:// is rewritten like any proxy does (core PlainHTTPFront)")
        XCTAssertTrue(help.contains("plain http:// is forwarded as any proxy forwards it"))
    }

    /// Settings ▸ Capture's caption says the same as the table: both schemes.
    func testTheSettingsCaptionSaysBothSchemes() throws {
        let settings = try String(contentsOf: Self.packageRoot.appendingPathComponent("../UI/Views/SettingsView/CaptureSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("does not appear in ReqRes at all, over https:// and plain http:// alike"))
        // Plain http:// to an excluded host still has its hop-by-hop headers
        // stripped (core PlainHTTPFront); "unchanged" is true of HTTPS only.
        XCTAssertFalse(settings.contains("passed on unread and unchanged"))
        XCTAssertFalse(settings.contains("not decrypted, not recorded, not changed"))
        XCTAssertTrue(settings.contains("plain http:// is forwarded as any proxy forwards it (hop-by-hop headers removed)"))
        XCTAssertTrue(try XCTUnwrap(excludedEntry).whatYouSee.contains("over https:// and plain http:// alike"))
    }
    /// pay-once A16: Settings ▸ Capture lists the license server's two
    /// entries first, from `ExcludedHostList.builtIn`, with their reason and
    /// no Remove button; the user's own rows follow, removable as before.
    func testTheSettingsPaneListsTheLicenseServerFirstAndFixed() throws {
        let settings = try String(contentsOf: Self.packageRoot.appendingPathComponent("../UI/Views/SettingsView/CaptureSettingsView.swift"), encoding: .utf8)
        let fixed = try XCTUnwrap(settings.range(of: "ForEach(ExcludedHostList.builtIn, id: \\.self) { host in"))
        let listed = try XCTUnwrap(settings.range(of: "ForEach(settings.list.hosts, id: \\.self) { host in"))
        XCTAssertLessThan(fixed.lowerBound, listed.lowerBound, "the fixed rows come first")
        let rows = settings[fixed.upperBound..<listed.lowerBound]
        XCTAssertTrue(rows.contains("Text(ExcludedHostList.builtInReason)"))
        XCTAssertTrue(rows.contains("Always excluded; cannot be removed"))
        XCTAssertFalse(rows.contains("Button"), "a built-in row has nothing to press")
        XCTAssertFalse(rows.contains("stopExcluding"))
        let userRows = settings[listed.upperBound...].prefix(900)
        XCTAssertTrue(userRows.contains("Button(\"Remove\") { settings.stopExcluding(host) }"), "the user's rows keep Remove")
        XCTAssertTrue(settings.contains("Nothing else is excluded."), "an emptied list still excludes the license server")
        XCTAssertFalse(settings.contains("Nothing is excluded."))
    }
}
