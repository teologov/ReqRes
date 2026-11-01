//
//  ProcessAttributionTextTests.swift
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
//  The strings the saved-sessions browser and Settings ▸ Capture render
//  from an identity (UX spec §6, §7.7), and the sandbox-safe tilde rule
//  behind the exported-certificate path.
//

import XCTest
@testable import MCPKit

final class ProcessAttributionTextTests: XCTestCase {
    private let safari = ProcessIdentity(name: "Safari", pid: 40213, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari")
    private let unknown = ProcessIdentity(name: nil, pid: nil, executablePath: nil)

    // MARK: - Saved row tooltip (§6)

    func testTheSavedRowLineNamesTheAppAndItsPid() {
        XCTAssertEqual(safari.savedRowTooltipLine, "App: Safari · pid 40213")
    }

    func testTheSavedRowLineForAnUnattributedSessionSaysUnknown() {
        XCTAssertEqual(unknown.savedRowTooltipLine, "App: Unknown")
        XCTAssertEqual(unknown.savedRowTooltipLine, "App: " + ProcessIdentity.unknownLabel,
                       "the browser's word for it is the column's")
    }

    /// A pid alone is not an identity (spec §1.2), so it never leaks into the
    /// line as "pid 512" beside Unknown; and a name without a pid is shown
    /// without inventing one.
    func testAPidWithoutANameIsStillUnknownAndANameWithoutAPidHasNoPid() {
        XCTAssertEqual(ProcessIdentity(name: nil, pid: 512, executablePath: nil).savedRowTooltipLine, "App: Unknown")
        XCTAssertEqual(ProcessIdentity(name: "claude", pid: nil, executablePath: nil).savedRowTooltipLine, "App: claude")
    }

    /// The saved browser names a helper by the same rule as the column: the
    /// outermost bundle, not the helper executable.
    func testAHelperIsNamedForItsApp() {
        let brave = ProcessIdentity(
            name: "Brave Browser Helper", pid: 4127,
            executablePath: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"
        )
        XCTAssertEqual(brave.savedRowTooltipLine, "App: Brave Browser · pid 4127")
    }

    // MARK: - Saved detail pill tooltip (§6)

    func testThePillTooltipDatesTheAttribution() {
        XCTAssertEqual(safari.savedPillTooltip, "Safari · pid 40213, when this was captured")
        XCTAssertEqual(ProcessIdentity(name: "curl", pid: nil, executablePath: "/usr/bin/curl").savedPillTooltip,
                       "curl, when this was captured")
    }

    /// Nil, not a sentence: an unattributed pill keeps `unknownTooltip`,
    /// which explains what Unknown means — a tooltip laid over it would hide
    /// the one explanation the browser has.
    func testAnUnattributedPillHasNoTooltipOfItsOwn() {
        XCTAssertNil(unknown.savedPillTooltip)
    }

    // MARK: - Settings ▸ Capture status line (§7.7)

    func testToolsAreListedBusiestFirstWithAProcessCountOnlyWhenThereAreSeveral() {
        let line = CommandLineToolsStatus.line(
            tools: [(name: "claude", processes: 2), (name: "curl", processes: 1)],
            attributionAvailable: true
        )
        XCTAssertEqual(line, "Reached ReqRes from outside an app bundle in this capture: claude (2 processes), curl.")
    }

    func testNoToolsIsSaidPlainly() {
        XCTAssertEqual(CommandLineToolsStatus.line(tools: [], attributionAvailable: true),
                       "Nothing outside an app bundle has reached ReqRes in this capture.")
        XCTAssertEqual(CommandLineToolsStatus.line(tools: [], attributionAvailable: nil),
                       "Nothing outside an app bundle has reached ReqRes in this capture.",
                       "unreported attribution (capture not started) is not the unavailable state")
    }

    /// The degraded state (spec §9): a list would be a lie, so the sentence
    /// replaces it whatever the index holds.
    func testUnavailableAttributionReplacesTheListEvenWhenToolsAreIndexed() {
        let expected = "ReqRes cannot tell which process opens connections on this Mac right now, so it cannot say which tools have reached it."
        XCTAssertEqual(CommandLineToolsStatus.line(tools: [], attributionAvailable: false), expected)
        XCTAssertEqual(CommandLineToolsStatus.line(tools: [(name: "claude", processes: 3)], attributionAvailable: false), expected)
    }

    func testASingleToolWithSeveralProcessesReadsAsOneEntry() {
        XCTAssertEqual(CommandLineToolsStatus.line(tools: [(name: "node", processes: 3)], attributionAvailable: true),
                       "Reached ReqRes from outside an app bundle in this capture: node (3 processes).")
    }

    // MARK: - Tilde paths

    func testAPathUnderHomeIsAbbreviated() {
        XCTAssertEqual(TildePath.abbreviated("/Users/dev/reqres-ca.pem", home: "/Users/dev"), "~/reqres-ca.pem")
        XCTAssertEqual(TildePath.abbreviated("/Users/dev/My Files/reqres-ca.pem", home: "/Users/dev/"),
                       "~/My Files/reqres-ca.pem", "a trailing slash on the home is tolerated")
        XCTAssertEqual(TildePath.abbreviated("/Users/dev", home: "/Users/dev"), "~")
    }

    /// `/Users/developer/…` merely starts with the characters of
    /// `/Users/dev`; it is not inside it.
    func testAPathThatOnlySharesHomesPrefixIsLeftAlone() {
        XCTAssertEqual(TildePath.abbreviated("/Users/developer/reqres-ca.pem", home: "/Users/dev"), "/Users/developer/reqres-ca.pem")
        XCTAssertEqual(TildePath.abbreviated("/Volumes/USB/reqres-ca.pem", home: "/Users/dev"), "/Volumes/USB/reqres-ca.pem")
    }

    func testAnEmptyOrRootHomeNeverAbbreviates() {
        XCTAssertEqual(TildePath.abbreviated("/etc/reqres-ca.pem", home: ""), "/etc/reqres-ca.pem")
        XCTAssertEqual(TildePath.abbreviated("/etc/reqres-ca.pem", home: "/"), "/etc/reqres-ca.pem")
    }
}
