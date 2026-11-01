//
//  RuleResponseDefaultsTests.swift
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
//  F17, the shell half: the JSON Content-Type the override form gave every
//  new rule, in every mode, relabelled every response an Extend rule touched
//  and every file a Map Local rule served. It belongs to Override alone, and
//  follows the mode — in the form, and in what create_rule stores.
//

import XCTest
@testable import MCPKit

/// A header as a rule editor holds one.
private struct Header: RuleHeaderEntry, Equatable, CustomStringConvertible {
    var ruleHeaderName: String
    var ruleHeaderValue: String
    var ruleHeaderIsEnabled = true

    static func ruleHeader(name: String, value: String) -> Header {
        Header(ruleHeaderName: name, ruleHeaderValue: value)
    }

    var description: String { "\(ruleHeaderName): \(ruleHeaderValue)\(ruleHeaderIsEnabled ? "" : " (off)")" }
}

final class RuleResponseDefaultsTests: XCTestCase {
    private let json = Header(ruleHeaderName: "Content-Type", ruleHeaderValue: "application/json; charset=utf-8")
    private let debug = Header(ruleHeaderName: "X-Debug-Session", ruleHeaderValue: "1")
    private let html = Header(ruleHeaderName: "Content-Type", ruleHeaderValue: "text/html")

    // MARK: - A new rule in the form

    func testOnlyANewOverrideStartsWithAContentType() {
        XCTAssertEqual(RuleResponseDefaults.headers(forNewRuleIn: .extend) as [Header], [])
        XCTAssertEqual(RuleResponseDefaults.headers(forNewRuleIn: .mapLocal) as [Header], [])
        XCTAssertEqual(RuleResponseDefaults.headers(forNewRuleIn: .override) as [Header], [json])
        XCTAssertEqual(RuleResponseDefaults.contentTypeValue, "application/json; charset=utf-8",
                       "the form's long-standing default, which its body editor highlights as JSON")
    }

    // MARK: - Changing the mode

    func testLeavingOverrideDropsTheDefaultAndKeepsWhatTheUserTyped() {
        for mode in [MCPRuleMode.extend, .mapLocal] {
            XCTAssertEqual(RuleResponseDefaults.headers([json], changingModeFrom: .override, to: mode), [], "\(mode)")
            XCTAssertEqual(RuleResponseDefaults.headers([debug, json], changingModeFrom: .override, to: mode), [debug], "\(mode)")
        }
    }

    /// Only the default exactly as the form adds it goes: a Content-Type with
    /// any other value — or one switched off — is somebody's choice.
    func testAContentTypeSomebodyChoseIsNeverTakenAway() {
        let edited = Header(ruleHeaderName: "Content-Type", ruleHeaderValue: "application/json")
        let off = Header(ruleHeaderName: "Content-Type", ruleHeaderValue: "application/json; charset=utf-8", ruleHeaderIsEnabled: false)
        for headers in [[html], [edited], [off], [debug, html]] {
            XCTAssertEqual(RuleResponseDefaults.headers(headers, changingModeFrom: .override, to: .extend), headers)
            XCTAssertEqual(RuleResponseDefaults.headers(headers, changingModeFrom: .override, to: .mapLocal), headers)
        }
    }

    /// Names are matched as HTTP matches them; spaces around a value are not
    /// a different value.
    func testTheDefaultIsRecognisedWhateverItsCaseOrPadding() {
        XCTAssertTrue(RuleResponseDefaults.isDefault(Header(ruleHeaderName: " content-type ", ruleHeaderValue: "application/json; charset=utf-8 ")))
        XCTAssertFalse(RuleResponseDefaults.isDefault(Header(ruleHeaderName: "Content-Type", ruleHeaderValue: "application/json; charset=UTF-8")),
                       "another spelling of the value is somebody's")
        XCTAssertFalse(RuleResponseDefaults.isDefault(Header(ruleHeaderName: "X-Content-Type", ruleHeaderValue: "application/json; charset=utf-8")))
    }

    func testBecomingAnOverrideAddsTheDefaultUnlessAContentTypeIsNamed() {
        XCTAssertEqual(RuleResponseDefaults.headers([Header](), changingModeFrom: .extend, to: .override), [json])
        XCTAssertEqual(RuleResponseDefaults.headers([debug], changingModeFrom: .mapLocal, to: .override), [debug, json])
        XCTAssertEqual(RuleResponseDefaults.headers([html], changingModeFrom: .extend, to: .override), [html])
        let lower = Header(ruleHeaderName: "content-type", ruleHeaderValue: "text/plain")
        XCTAssertEqual(RuleResponseDefaults.headers([lower], changingModeFrom: .extend, to: .override), [lower])
        // A switched-off Content-Type is none: the core applies enabled headers only.
        let off = Header(ruleHeaderName: "Content-Type", ruleHeaderValue: "text/plain", ruleHeaderIsEnabled: false)
        XCTAssertEqual(RuleResponseDefaults.headers([off], changingModeFrom: .extend, to: .override), [off, json])
    }

    /// A rule an earlier form saved carries the default in every mode.
    /// Moving it between Extend and Map Local drops it: neither mode wants it.
    func testALeftoverDefaultIsDroppedBetweenExtendAndMapLocal() {
        XCTAssertEqual(RuleResponseDefaults.headers([json, debug], changingModeFrom: .extend, to: .mapLocal), [debug])
        XCTAssertEqual(RuleResponseDefaults.headers([json], changingModeFrom: .mapLocal, to: .extend), [])
    }

    func testTheSameModeChangesNothing() {
        for mode in MCPRuleMode.allCases {
            XCTAssertEqual(RuleResponseDefaults.headers([json, debug], changingModeFrom: mode, to: mode), [json, debug], "\(mode)")
            XCTAssertEqual(RuleResponseDefaults.headers([Header](), changingModeFrom: mode, to: mode), [], "\(mode)")
        }
    }

    /// Clicking through every mode and back ends where a new rule of the
    /// last mode starts — one default, never two.
    func testClickingThroughTheModesNeverStacksOrStrandsTheDefault() {
        var headers: [Header] = RuleResponseDefaults.headers(forNewRuleIn: .extend)
        for (from, to) in [(MCPRuleMode.extend, MCPRuleMode.override), (.override, .mapLocal), (.mapLocal, .override), (.override, .override)] {
            headers = RuleResponseDefaults.headers(headers, changingModeFrom: from, to: to)
        }
        XCTAssertEqual(headers, [json])
        headers = RuleResponseDefaults.headers(headers + [debug], changingModeFrom: .override, to: .extend)
        XCTAssertEqual(headers, [debug])
    }

    // MARK: - The mode change, whole

    /// The review's case: a mode change that writes the new mode before it
    /// reads the old one changes from the new mode to itself, and neither
    /// adds nor drops the default. The whole step is one call, in MCPKit.
    func testAModeChangeReadsTheOldModeBeforeWritingTheNewOne() {
        var mode = MCPRuleMode.override
        var headers = [debug, json]
        var status = RuleStatus.code(200)
        RuleResponseDefaults.changeMode(&mode, headers: &headers, status: &status, to: .extend, as: { $0 })
        XCTAssertEqual(mode, .extend)
        XCTAssertEqual(headers, [debug], "leaving Override drops its untouched default")
        XCTAssertEqual(status, .keep, "and its untouched 200 becomes Extend's keep")

        RuleResponseDefaults.changeMode(&mode, headers: &headers, status: &status, to: .override, as: { $0 })
        XCTAssertEqual(mode, .override)
        XCTAssertEqual(headers, [debug, json], "becoming an Override adds it")
        XCTAssertEqual(status, .code(200))

        RuleResponseDefaults.changeMode(&mode, headers: &headers, status: &status, to: .override, as: { $0 })
        XCTAssertEqual(headers, [debug, json], "the same mode changes nothing")
        XCTAssertEqual(status, .code(200))
    }

    /// The form's own mode type maps through `as:` — here a stand-in that is
    /// not `MCPRuleMode`, like the core's `RuleMode` in the form.
    func testAModeChangeMapsTheFormsOwnModeType() {
        enum FormMode: Equatable { case extend, override, mapLocal }
        func rule(_ mode: FormMode) -> MCPRuleMode {
            switch mode {
            case .extend: return .extend
            case .override: return .override
            case .mapLocal: return .mapLocal
            }
        }
        var mode = FormMode.extend
        var headers: [Header] = []
        var status = RuleStatus.keep
        RuleResponseDefaults.changeMode(&mode, headers: &headers, status: &status, to: .override, as: rule)
        XCTAssertEqual(mode, .override)
        XCTAssertEqual(headers, [json])
        XCTAssertEqual(status, .code(200))
        RuleResponseDefaults.changeMode(&mode, headers: &headers, status: &status, to: .mapLocal, as: rule)
        XCTAssertEqual(mode, .mapLocal)
        XCTAssertEqual(headers, [])
        XCTAssertEqual(status, .keep)
    }

    // MARK: - What the form shows, and so stores

    /// Every mode shows its response headers — Map Local's too, since they
    /// are sent with its file — and stores what it shows. Seeded from the
    /// rule, a Map Local rule's untouched default is left out: the form never
    /// showed it there, and it only ever replaced the file's own type.
    func testSeedingAMapLocalRuleLeavesOutTheOldDefaultAndShowsTheRest() {
        let cors = Header(ruleHeaderName: "Access-Control-Allow-Origin", ruleHeaderValue: "*")
        XCTAssertEqual(RuleResponseDefaults.headers(seeding: [json], mode: .mapLocal), [])
        XCTAssertEqual(RuleResponseDefaults.headers(seeding: [cors, json], mode: .mapLocal), [cors],
                       "an agent's header, or one typed before a change of mode, is sent with the file and shown")
        XCTAssertEqual(RuleResponseDefaults.headers(seeding: [cors, html], mode: .mapLocal), [cors, html],
                       "a Content-Type somebody chose is theirs")
    }

    /// An Extend or Override rule shows what its Headers row always showed.
    func testSeedingAnExtendOrOverrideRuleShowsWhatIsStored() {
        for mode in [MCPRuleMode.extend, .override] {
            XCTAssertEqual(RuleResponseDefaults.headers(seeding: [json, debug], mode: mode), [json, debug], "\(mode)")
            XCTAssertEqual(RuleResponseDefaults.headers(seeding: [Header](), mode: mode), [], "\(mode)")
        }
    }

    /// The review's data-loss case: an Extend rule's CORS header, switched to
    /// Map Local, was dropped at the save because the form hid it there. Now
    /// it stays in the form — and in the Headers row Map Local shows.
    func testAHeaderTypedBeforeASwitchToMapLocalStays() {
        let cors = Header(ruleHeaderName: "Access-Control-Allow-Origin", ruleHeaderValue: "*")
        var mode = MCPRuleMode.extend
        var headers = [cors]
        var status = RuleStatus.keep
        RuleResponseDefaults.changeMode(&mode, headers: &headers, status: &status, to: .mapLocal, as: { $0 })
        XCTAssertEqual(headers, [cors])
        mode = .override
        headers = [cors, json]
        RuleResponseDefaults.changeMode(&mode, headers: &headers, status: &status, to: .mapLocal, as: { $0 })
        XCTAssertEqual(headers, [cors], "the Override's default goes; the user's header stays")
    }

    // MARK: - create_rule

    func testAnAgentsNewOverrideNamesAContentType() {
        let contentType = [RuleResponseDefaults.contentTypeName: RuleResponseDefaults.contentTypeValue]
        XCTAssertEqual(RuleResponseDefaults.headers(forNewRule: [:], mode: .override), contentType)
        XCTAssertEqual(RuleResponseDefaults.headers(forNewRule: ["X-Mock": "1"], mode: .override),
                       contentType.merging(["X-Mock": "1"]) { kept, _ in kept })
        XCTAssertEqual(RuleResponseDefaults.headers(forNewRule: ["content-type": "text/html"], mode: .override), ["content-type": "text/html"],
                       "a Content-Type the agent names is kept as it named it")
    }

    func testAnAgentsNewExtendOrMapLocalRuleGetsNoHeader() {
        for mode in [MCPRuleMode.extend, .mapLocal] {
            XCTAssertEqual(RuleResponseDefaults.headers(forNewRule: [:], mode: mode), [:], "\(mode)")
            XCTAssertEqual(RuleResponseDefaults.headers(forNewRule: ["X-Debug": "1"], mode: mode), ["X-Debug": "1"], "\(mode)")
        }
    }

    func testValidatingANewRuleGivesItItsModesHeaders() throws {
        let override = try MCPWriteValidation.validateNewRule(MCPRuleDraft(hostId: 1, mode: .override, path: "/x", responseBody: "{}"))
        XCTAssertEqual(override.responseHeaders, [RuleResponseDefaults.contentTypeName: RuleResponseDefaults.contentTypeValue])
        // As in the form, the default does not depend on the body — which is
        // what create_rule's text promises ("A new override whose
        // response_headers name no Content-Type is given Content-Type:
        // application/json; charset=utf-8"). An HTML answer names its own.
        let page = try MCPWriteValidation.validateNewRule(MCPRuleDraft(hostId: 1, mode: .override, path: "/x", responseBody: "<h1>hi</h1>"))
        XCTAssertEqual(page.responseHeaders, [RuleResponseDefaults.contentTypeName: RuleResponseDefaults.contentTypeValue])
        let named = try MCPWriteValidation.validateNewRule(MCPRuleDraft(hostId: 1, mode: .override, path: "/x",
                                                                        responseHeaders: ["Content-Type": "text/html"], responseBody: "<h1>hi</h1>"))
        XCTAssertEqual(named.responseHeaders, ["Content-Type": "text/html"])
        let extend = try MCPWriteValidation.validateNewRule(MCPRuleDraft(hostId: 1, mode: .extend, path: "/*", requestHeaders: ["X-Debug-Session": "1"]))
        XCTAssertEqual(extend.responseHeaders, [:], "a header-only extend rule must not relabel every response on its path")
        let mapLocal = try MCPWriteValidation.validateNewRule(MCPRuleDraft(hostId: 1, mode: .mapLocal, path: "/logo.png", localFile: MCPLocalFile(content: "x", contentType: "image/png")))
        XCTAssertEqual(mapLocal.responseHeaders, [:], "a map_local rule is answered with its file's type")
    }

    /// `validate` alone — what mock_from_session calls on the draft it built
    /// from a capture — adds nothing: a mock copies the capture's headers,
    /// Content-Type or not.
    func testValidatingADraftAddsNoHeader() throws {
        let draft = try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, path: "/x", responseBody: "{}"))
        XCTAssertEqual(draft.responseHeaders, [:])
    }
}

/// F17's status, completed by core 95062d1: a stored 0 keeps the server's
/// status (anything outside 200…599 too where the request is forwarded; 200
/// where ReqRes answers itself), a Map Local rule's status is never used, and
/// the core migrated the form's untouched Extend rules to 0 at first launch.
/// Build 52's form opened that 0 as 400 and saved it; every form started an
/// Extend rule at 200, which answered every 404 and 500 on its path as 200.
final class RuleStatusDefaultsTests: XCTestCase {

    // MARK: - Per mode

    func testOnlyExtendKeepsTheServersStatusAndMapLocalUsesNone() {
        XCTAssertTrue(RuleResponseDefaults.canKeepServerStatus(.extend))
        XCTAssertFalse(RuleResponseDefaults.canKeepServerStatus(.override), "an override answers with its own status")
        XCTAssertTrue(RuleResponseDefaults.canKeepServerStatus(.mapLocal), "stored 0: what its missing file does")
        XCTAssertTrue(RuleResponseDefaults.usesStatus(.extend))
        XCTAssertTrue(RuleResponseDefaults.usesStatus(.override))
        XCTAssertFalse(RuleResponseDefaults.usesStatus(.mapLocal), "the core never uses a Map Local rule's status")
        XCTAssertEqual(RuleResponseDefaults.keepServerStatus, 0, "the core's RuleResponses.keepServerStatus")
        XCTAssertEqual(RuleResponseDefaults.answeringStatuses, 200...599, "the core's RuleResponses.ruleStatus")
    }

    func testANewRuleStartsWithItsModesStatus() {
        XCTAssertEqual(RuleResponseDefaults.status(forNewRuleIn: .extend), .keep)
        XCTAssertEqual(RuleResponseDefaults.status(forNewRuleIn: .override), .code(200))
        XCTAssertEqual(RuleResponseDefaults.status(forNewRuleIn: .mapLocal), .keep)
        XCTAssertEqual(RuleStatus.keep.stored, 0)
        XCTAssertEqual(RuleStatus.code(404).stored, 404)
    }

    // MARK: - What the form opens a rule with, and saves

    /// The core's migration gave the form's untouched Extend rules 0. Build
    /// 52's form opened it as 400 Bad Request and saved that.
    func testAMigratedExtendRuleOpensAsKeepAndSavesAsKeep() {
        let opened = RuleResponseDefaults.status(seeding: 0, mode: .extend)
        XCTAssertEqual(opened, .keep)
        XCTAssertEqual(RuleResponseDefaults.storedStatus(opened, mode: .extend), 0)
    }

    /// Opened as the core reads it, so opening and saving changes nothing it does.
    func testAStoredStatusOpensAsTheCoreReadsIt() {
        for mode in [MCPRuleMode.extend, .override] {
            for code in [200, 201, 204, 226, 302, 304, 404, 418, 499, 500, 599] {
                XCTAssertEqual(RuleResponseDefaults.status(seeding: code, mode: mode), .code(code), "\(mode) \(code)")
            }
        }
        // Extend: anything else is the server's status, kept (the core keeps it).
        for stored in [0, 100, 101, 103, 199, 600, -1, 99_999] {
            XCTAssertEqual(RuleResponseDefaults.status(seeding: stored, mode: .extend), .keep, "extend \(stored)")
        }
        // Override: never keeps — what an override with a body answers for it.
        for stored in [0, 101, 600, -1] {
            XCTAssertEqual(RuleResponseDefaults.status(seeding: stored, mode: .override), .code(200), "override \(stored)")
        }
        // Map Local: not used, not shown.
        for stored in [0, 200, 404] {
            XCTAssertEqual(RuleResponseDefaults.status(seeding: stored, mode: .mapLocal), .keep, "map local \(stored)")
        }
    }

    /// A 302 that mock_from_session copied opened as 400 in every earlier
    /// form, whose menus listed 2xx, 4xx and 5xx only.
    func testACodeTheMenuDoesNotListOpensAndSavesAsItself() {
        let opened = RuleResponseDefaults.status(seeding: 302, mode: .override)
        XCTAssertEqual(opened, .code(302))
        XCTAssertEqual(RuleResponseDefaults.storedStatus(opened, mode: .override), 302)
        let menu = RuleResponseDefaults.statusMenu(for: .override, listing: [200, 400, 500], current: opened)
        XCTAssertEqual(menu.flatMap(\.statuses), [.code(200), .code(302), .code(400), .code(500)])
        XCTAssertEqual(menu.first { $0.statuses.contains(.code(302)) }?.title, "Redirection")
    }

    func testTheSaveStoresWhatTheFormShows() {
        XCTAssertEqual(RuleResponseDefaults.storedStatus(.keep, mode: .extend), 0)
        XCTAssertEqual(RuleResponseDefaults.storedStatus(.code(404), mode: .extend), 404)
        XCTAssertEqual(RuleResponseDefaults.storedStatus(.code(201), mode: .override), 201)
        XCTAssertEqual(RuleResponseDefaults.storedStatus(.keep, mode: .override), 200,
                       "an override never shows keep; it would store its own start for it")
        XCTAssertEqual(RuleResponseDefaults.storedStatus(.code(404), mode: .mapLocal), 0,
                       "Map Local shows no status and stores 0, what its missing file does")
        XCTAssertEqual(RuleResponseDefaults.storedStatus(.keep, mode: .mapLocal), 0)
    }

    // MARK: - The mode change

    /// The default follows the mode, as the Content-Type does.
    func testTheStatusDefaultFollowsTheMode() {
        func change(_ status: RuleStatus, _ old: MCPRuleMode, _ new: MCPRuleMode) -> RuleStatus {
            RuleResponseDefaults.status(status, changingModeFrom: old, to: new)
        }
        XCTAssertEqual(change(.keep, .extend, .override), .code(200), "an override cannot keep: it answers with its own")
        XCTAssertEqual(change(.code(200), .override, .extend), .keep, "an override's untouched 200 never rides onto Extend")
        XCTAssertEqual(change(.code(200), .override, .mapLocal), .keep)
        XCTAssertEqual(change(.keep, .mapLocal, .override), .code(200))
        XCTAssertEqual(change(.keep, .mapLocal, .extend), .keep)
        XCTAssertEqual(change(.keep, .extend, .mapLocal), .keep)
        // A status somebody chose stays.
        XCTAssertEqual(change(.code(404), .extend, .override), .code(404))
        XCTAssertEqual(change(.code(500), .override, .extend), .code(500))
        XCTAssertEqual(change(.code(404), .extend, .mapLocal), .code(404), "hidden on Map Local, not lost")
        XCTAssertEqual(change(.code(404), .mapLocal, .extend), .code(404))
        // The same mode changes nothing.
        for mode in MCPRuleMode.allCases {
            XCTAssertEqual(change(.keep, mode, mode), .keep, "\(mode)")
            XCTAssertEqual(change(.code(200), mode, mode), .code(200), "\(mode)")
        }
    }

    /// Clicking a new rule through every mode and back to Extend ends at
    /// keep — through Map Local too, whose hidden status is keep — never at
    /// an Override's 200 (F17's 200 on every response of the path).
    func testClickingThroughTheModesNeverLeavesAnExtendRuleAt200() {
        var mode = MCPRuleMode.extend
        var headers: [Header] = RuleResponseDefaults.headers(forNewRuleIn: .extend)
        var status = RuleResponseDefaults.status(forNewRuleIn: .extend)
        var seen: [RuleStatus] = []
        for next in [MCPRuleMode.override, .mapLocal, .extend, .override, .extend] {
            RuleResponseDefaults.changeMode(&mode, headers: &headers, status: &status, to: next, as: { $0 })
            seen.append(status)
        }
        XCTAssertEqual(seen, [.code(200), .keep, .keep, .code(200), .keep],
                       "each Override shows its 200, each Extend keeps the server's")
        XCTAssertEqual(headers, [])
        XCTAssertEqual(RuleResponseDefaults.storedStatus(status, mode: mode), 0)
    }

    /// Whatever the clicks, the form never holds a status its Status menu
    /// cannot show — a menu whose selection matches none of its items shows
    /// nothing, and an Override's has no "keep". Every sequence of four mode
    /// changes, from every mode's start and from a status somebody chose.
    func testNoSequenceOfModeChangesLeavesAStatusTheMenuCannotShow() {
        let listed = [200, 404, 500]
        var sequences: [[MCPRuleMode]] = [[]]
        for _ in 0..<4 { sequences = sequences.flatMap { prefix in MCPRuleMode.allCases.map { prefix + [$0] } } }
        for start in MCPRuleMode.allCases {
            for chosen in [RuleResponseDefaults.status(forNewRuleIn: start), .code(404), .code(200)] {
                for sequence in sequences {
                    var mode = start
                    var headers: [Header] = []
                    var status = chosen
                    for next in sequence {
                        RuleResponseDefaults.changeMode(&mode, headers: &headers, status: &status, to: next, as: { $0 })
                        let shown = RuleResponseDefaults.statusMenu(for: mode, listing: listed, current: status).flatMap(\.statuses)
                        XCTAssertTrue(!RuleResponseDefaults.usesStatus(mode) || shown.contains(status),
                                      "\(start) \(chosen) → \(sequence): \(status) on \(mode)")
                    }
                }
            }
        }
    }

    // MARK: - The menu

    func testTheMenuOffersKeepFirstWhereTheModeKeepsIt() {
        let listed = [200, 201, 400, 404, 500]
        let extend = RuleResponseDefaults.statusMenu(for: .extend, listing: listed, current: .keep)
        XCTAssertEqual(extend.first, RuleStatusMenuGroup(title: nil, statuses: [.keep]))
        XCTAssertEqual(extend.map(\.title), [nil, "Success", "Client error", "Server error"])
        XCTAssertEqual(extend.flatMap(\.statuses), [.keep, .code(200), .code(201), .code(400), .code(404), .code(500)])

        let override = RuleResponseDefaults.statusMenu(for: .override, listing: listed, current: .code(200))
        XCTAssertFalse(override.flatMap(\.statuses).contains(.keep), "an override answers with its own status")
        XCTAssertEqual(override.flatMap(\.statuses), [.code(200), .code(201), .code(400), .code(404), .code(500)])

        XCTAssertEqual(RuleResponseDefaults.statusMenu(for: .mapLocal, listing: listed, current: .keep), [],
                       "Map Local shows no status")
    }

    /// The status a rule opened with stays offered after another is picked,
    /// as the Method menu keeps a stored method it does not list: picking 200
    /// on a mock's 302 and back is a menu click, not a Cancel.
    func testTheStatusARuleOpenedWithStaysOfferedAfterAnotherIsPicked() {
        let listed = [200, 400, 500]
        let opened = RuleResponseDefaults.status(seeding: 302, mode: .extend)
        let menu = RuleResponseDefaults.statusMenu(for: .extend, listing: listed, current: .code(200), opened: opened)
        XCTAssertEqual(menu.flatMap(\.statuses), [.keep, .code(200), .code(302), .code(400), .code(500)])
        // What a Map Local rule opened with is not a status (it is not used),
        // so a switch to Extend offers nothing extra.
        let mapLocal = RuleResponseDefaults.status(seeding: 404, mode: .mapLocal)
        XCTAssertEqual(RuleResponseDefaults.statusMenu(for: .extend, listing: [200], current: .keep, opened: mapLocal).flatMap(\.statuses),
                       [.keep, .code(200)])
        XCTAssertEqual(RuleResponseDefaults.statusMenu(for: .extend, listing: [200], current: .keep, opened: nil).flatMap(\.statuses),
                       [.keep, .code(200)], "a new rule")
    }

    func testTheMenuListsEachCodeOnceAndOnlyFinalOnes() {
        let menu = RuleResponseDefaults.statusMenu(for: .extend, listing: [500, 200, 200, 101, 600], current: .code(500))
        XCTAssertEqual(menu.flatMap(\.statuses), [.keep, .code(200), .code(500)],
                       "sorted, a listed or current code once, nothing outside 200…599")
        XCTAssertEqual(RuleResponseDefaults.statusMenu(for: .extend, listing: [200], current: .code(101)).flatMap(\.statuses),
                       [.keep, .code(200)])
    }

    // MARK: - What agents and the approval panel read

    func testAKeptStatusReadsAsTheServersNeverAsZero() {
        XCTAssertEqual(RuleResponseDefaults.statusText(0, mode: .extend, hasBody: false), "server's status")
        XCTAssertEqual(RuleResponseDefaults.statusText(0, mode: .extend, hasBody: true), "server's status",
                       "an extend body replaces the server's body, not its status")
        XCTAssertEqual(RuleResponseDefaults.statusText(101, mode: .extend, hasBody: false), "server's status", "the core keeps a 1xx")
        XCTAssertEqual(RuleResponseDefaults.statusText(404, mode: .extend, hasBody: false), "404")
        XCTAssertEqual(RuleResponseDefaults.statusText(500, mode: .override, hasBody: true), "500")
        // An override stored with a status the core does not answer with
        // (only build 52's agents could store one): 200 when it answers
        // itself, the server's when it forwards.
        XCTAssertEqual(RuleResponseDefaults.statusText(0, mode: .override, hasBody: true), "200")
        XCTAssertEqual(RuleResponseDefaults.statusText(101, mode: .override, hasBody: false), "server's status")
        XCTAssertNil(RuleResponseDefaults.statusText(404, mode: .mapLocal, hasBody: false), "not used")
    }

    /// list_rules, create_rule's and update_rule's replies: a migrated rule
    /// read "→ 0", a status no response ever has.
    func testARuleRowReadsItsStatusAsTheCoreAnswersIt() {
        func rule(_ mode: MCPRuleMode, _ status: Int, body: String? = nil, file: String? = nil) -> MCPRule {
            MCPRule(id: 4, hostId: 7, host: "api.example.com", enabled: true, mode: mode, matchType: .wildcard,
                    path: "/a", method: "", scheme: "https", responseStatus: status, responseBody: body, localFilePath: file)
        }
        let kept = MCPTextFormat.ruleRow(rule(.extend, 0))
        XCTAssertEqual(kept, "#4  on   extend  Any https://api.example.com/a  → server's status  [wildcard]")
        XCTAssertFalse(kept.contains("→ 0"))
        XCTAssertTrue(MCPTextFormat.ruleRow(rule(.extend, 404)).contains("  → 404  "))
        XCTAssertTrue(MCPTextFormat.ruleRow(rule(.override, 500, body: "{}")).contains("  → 500  "))
        XCTAssertTrue(MCPTextFormat.ruleRow(rule(.override, 0, body: "{}")).contains("  → 200  "),
                      "an override answering itself answers 200 for a status it cannot use")
        XCTAssertTrue(MCPTextFormat.ruleRow(rule(.mapLocal, 0, file: "/fixtures/flags.json")).contains("  → flags.json  "),
                      "a map_local rule shows its file, not a status it does not use")
        XCTAssertTrue(MCPTextFormat.rule(rule(.extend, 0)).hasPrefix(kept), "the full read starts with the row")
    }
}

/// create_rule and update_rule through the bridge: what is stored, and what
/// the human approving it is shown.
final class RuleResponseDefaultsRouteTests: XCTestCase {
    private let token = "rule-defaults-token"
    private var rules: StubRuleProvider!
    private var consent: StubConsent!
    private var audit: StubAudit!

    override func setUp() {
        super.setUp()
        rules = StubRuleProvider()
        consent = StubConsent()
        audit = StubAudit()
    }

    private func makeRouter() -> MCPBridgeRouter {
        let hosts = StubHostProvider()
        hosts.stored = [MCPHost(id: 7, host: "api.example.com", scheme: "https", port: 443)]
        return MCPBridgeRouter(
            token: token, sessions: StubSessionProvider(), status: StubStatusProvider(),
            writes: MCPWriteSeams(rules: rules, hosts: hosts, capture: StubCaptureController(), consent: consent, audit: audit)
        )
    }

    private func send(_ method: String, _ target: String, _ body: [String: Any]) throws -> ParsedResponse {
        var request = makeRequest(method: method, target: target, token: token)
        request.body = try JSONSerialization.data(withJSONObject: body)
        request.headers["content-type"] = "application/json"
        return try XCTUnwrap(parseRawResponse(makeRouter().respond(to: request)))
    }

    private var contentTypeLine: String { "Content-Type: \(RuleResponseDefaults.contentTypeValue)" }

    func testAnOverrideIsStoredWithTheDefaultContentTypeAndThePanelSaysSo() throws {
        let response = try send("POST", "/v1/rules", ["hostId": 7, "mode": "override", "path": "/users?*", "responseBody": "[]"])
        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(rules.created.first?.responseHeaders, [RuleResponseDefaults.contentTypeName: RuleResponseDefaults.contentTypeValue])
        let details = consent.asked.first?.details.joined(separator: "\n") ?? ""
        XCTAssertTrue(details.contains(contentTypeLine), "the human sees the Content-Type the rule will answer with: \(details)")
        let returned = try JSONDecoder().decode(MCPRule.self, from: response.body)
        XCTAssertEqual(returned.responseHeaders[RuleResponseDefaults.contentTypeName], RuleResponseDefaults.contentTypeValue)
    }

    /// Help's own Extend example — tag requests with a header — used to turn
    /// every response on the path into JSON (with the form's default).
    func testAHeaderOnlyExtendRuleAndAMapLocalRuleAreStoredWithNoResponseHeader() throws {
        XCTAssertEqual(try send("POST", "/v1/rules", ["hostId": 7, "mode": "extend", "path": "/*",
                                                      "requestHeaders": ["X-Debug-Session": "1"]]).status, 201)
        XCTAssertEqual(try send("POST", "/v1/rules", ["hostId": 7, "mode": "map_local", "path": "/logo.png",
                                                      "localFile": ["content": "x", "contentType": "image/png"]]).status, 201)
        XCTAssertEqual(rules.created.map(\.responseHeaders), [[:], [:]])
        for action in consent.asked {
            XCTAssertFalse(action.details.joined().contains("Content-Type"), "\(action.kind): \(action.details)")
        }
    }

    private func storeOverride(headers: [String: String]) {
        rules.stored = [MCPRule(
            id: 3, hostId: 7, host: "api.example.com", enabled: true, mode: .override, matchType: .wildcard,
            path: "/a", method: "", scheme: "https", responseHeaders: headers, responseBody: "{}"
        )]
    }

    /// update_rule never adds or drops a header on its own: sent none, it
    /// keeps what is stored — and when the mode changes, the panel names what
    /// is kept, because an override's Content-Type on an extend rule
    /// relabels every real response on the path.
    func testUpdateRuleSentNoHeadersKeepsWhatIsStoredAndSaysSoOnAModeChange() throws {
        storeOverride(headers: [RuleResponseDefaults.contentTypeName: RuleResponseDefaults.contentTypeValue])
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "extend"]).status, 200)
        XCTAssertEqual(rules.stored.first?.responseHeaders, [RuleResponseDefaults.contentTypeName: RuleResponseDefaults.contentTypeValue])
        let details = consent.asked.first?.details ?? []
        XCTAssertTrue(details.contains("Response headers kept — \(contentTypeLine)"), "\(details)")

        consent.asked = []
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["enabled": false]).status, 200)
        XCTAssertFalse(consent.asked.first?.details.joined().contains("kept") ?? true, "no mode change, nothing to point out")
    }

    func testUpdateRuleStoresTheHeadersItIsSentAndAddsNone() throws {
        storeOverride(headers: [RuleResponseDefaults.contentTypeName: RuleResponseDefaults.contentTypeValue])
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["responseHeaders": ["X-Mock": "1"]]).status, 200)
        XCTAssertEqual(rules.stored.first?.responseHeaders, ["X-Mock": "1"], "an override's headers replaced as sent: no default added on update")
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "extend", "responseHeaders": [String: String]()]).status, 200)
        XCTAssertEqual(rules.stored.first?.responseHeaders, [:], "sent with the mode change, {} drops them")
        let details = consent.asked.last?.details ?? []
        XCTAssertFalse(details.contains { $0.contains("Response headers kept") || $0.contains("Content-Type kept") },
                       "headers sent with the mode change are not kept ones: \(details)")
    }

    // MARK: - The review's cases: what the panel says the Content-Type does

    private let noContentType = "No Content-Type — an override's response carries the rule's headers only, so it goes out without one"

    /// update_rule keeps what is stored, so an extend rule made
    /// an override without response headers answers with no Content-Type —
    /// the form would have added the JSON one. The human approving it is told.
    func testMakingAnOverrideWithoutAContentTypeSaysSo() throws {
        rules.stored = [MCPRule(
            id: 3, hostId: 7, host: "api.example.com", enabled: true, mode: .extend, matchType: .wildcard,
            path: "/a", method: "", scheme: "https", responseHeaders: [:], responseBody: #"{"a":1}"#
        )]
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "override"]).status, 200)
        XCTAssertEqual(rules.stored.first?.responseHeaders, [:], "update_rule adds no header on its own")
        XCTAssertEqual(consent.asked.first?.details, ["Mode → override", noContentType])

        consent.asked = []
        rules.stored[0].mode = .extend
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "override", "responseHeaders": ["content-type": "text/plain"]]).status, 200)
        XCTAssertFalse(consent.asked.first?.details.contains(noContentType) ?? true, "a Content-Type sent with it is named in the headers line")
    }

    /// Kept onto an extend or map_local rule, an override's Content-Type
    /// relabels every real response, or the file (F17's own symptoms): the
    /// panel says so beside the headers it keeps.
    func testAContentTypeKeptThroughAModeChangeSaysWhatItDoes() throws {
        storeOverride(headers: [RuleResponseDefaults.contentTypeName: RuleResponseDefaults.contentTypeValue])
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "extend"]).status, 200)
        XCTAssertEqual(consent.asked.last?.details, [
            "Mode → extend",
            "Response headers kept — \(contentTypeLine)",
            "Content-Type kept: every response the rule matches is labelled \(RuleResponseDefaults.contentTypeValue)",
            // The override's status rides along too (update_rule keeps it):
            // `RuleStatusRouteTests`.
            "Status kept: every response the rule matches comes back as 200, in place of the server's",
        ])

        storeOverride(headers: [RuleResponseDefaults.contentTypeName: RuleResponseDefaults.contentTypeValue])
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "map_local", "localFile": ["content": "<p>x</p>", "contentType": "text/html"]]).status, 200)
        let details = consent.asked.last?.details ?? []
        XCTAssertTrue(details.contains("Content-Type kept: the file is sent as \(RuleResponseDefaults.contentTypeValue), not as its own type"), "\(details)")
    }

    /// New response headers on an override that name no Content-Type say so
    /// under the headers line; a patch that does not touch the mode or the
    /// headers says nothing about them.
    func testNewHeadersWithoutAContentTypeOnAnOverrideSaySo() throws {
        storeOverride(headers: [RuleResponseDefaults.contentTypeName: RuleResponseDefaults.contentTypeValue])
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["responseHeaders": ["X-Mock": "1"]]).status, 200)
        XCTAssertEqual(consent.asked.last?.details, ["Response headers → X-Mock: 1", noContentType])

        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["enabled": false]).status, 200)
        XCTAssertEqual(consent.asked.last?.details, ["Disable"])
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "override"]).status, 200)
        XCTAssertEqual(consent.asked.last?.details, ["Mode → override"], "the mode it already has decides nothing")
    }

}

/// The status through the bridge (core 95062d1): what create_rule,
/// update_rule and mock_from_session store and refuse, and what the human
/// approving it reads — "server's status", never "→ 0".
final class RuleStatusRouteTests: XCTestCase {
    private let token = "rule-status-token"
    private var rules: StubRuleProvider!
    private var consent: StubConsent!
    private var sessions: StubSessionProvider!

    override func setUp() {
        super.setUp()
        rules = StubRuleProvider()
        consent = StubConsent()
        sessions = StubSessionProvider()
    }

    /// A captured session mock_from_session can resolve, as the bridge's
    /// session seam reports it (`statusCode` is the row's state, parsed).
    private func capture(_ uid: String, status: Int?) {
        let summary = makeSession(uid: uid, statusCode: status)
        sessions.summaries.append(summary)
        sessions.details[uid] = MCPSessionDetail(summary: summary)
    }

    private func send(_ method: String, _ target: String, _ body: [String: Any]) throws -> ParsedResponse {
        let hosts = StubHostProvider()
        hosts.stored = [MCPHost(id: 7, host: "api.example.com", scheme: "https", port: 443)]
        let router = MCPBridgeRouter(
            token: token, sessions: sessions, status: StubStatusProvider(),
            writes: MCPWriteSeams(rules: rules, hosts: hosts, capture: StubCaptureController(), consent: consent, audit: StubAudit())
        )
        var request = makeRequest(method: method, target: target, token: token)
        request.body = try JSONSerialization.data(withJSONObject: body)
        request.headers["content-type"] = "application/json"
        return try XCTUnwrap(parseRawResponse(router.respond(to: request)))
    }

    private func message(_ response: ParsedResponse) -> String {
        ((response.json?["error"] as? [String: Any])?["message"] as? String) ?? ""
    }

    private func store(_ mode: MCPRuleMode, status: Int, body: String? = nil, headers: [String: String] = [:]) {
        rules.stored = [MCPRule(
            id: 3, hostId: 7, host: "api.example.com", enabled: true, mode: mode, matchType: .wildcard,
            path: "/a", method: "", scheme: "https", responseStatus: status, responseHeaders: headers, responseBody: body,
            localFilePath: mode == .mapLocal ? "/fixtures/a.json" : nil
        )]
    }

    // MARK: - create_rule

    /// The core's migration leaves an extend rule an agent stored at 200
    /// alone, so create_rule must stop defaulting one to 200 — the shape of
    /// Help's own Extend example: tag requests with a header.
    func testAnExtendRuleWithNoStatusKeepsTheServersAndThePanelSaysSo() throws {
        let response = try send("POST", "/v1/rules", ["hostId": 7, "mode": "extend", "path": "/*",
                                                      "requestHeaders": ["X-Debug-Session": "1"]])
        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(rules.created.first?.responseStatus, 0, "stored as keep")
        let summary = consent.asked.first?.summary ?? ""
        XCTAssertTrue(summary.hasSuffix("→ server's status"), summary)
        XCTAssertFalse(summary.contains("→ 0"), summary)
        XCTAssertEqual(response.json?["responseStatus"] as? Int, 0)
    }

    func testAnOverrideWithNoStatusAnswers200AndAMapLocalStoresKeep() throws {
        XCTAssertEqual(try send("POST", "/v1/rules", ["hostId": 7, "mode": "override", "path": "/a", "responseBody": "{}"]).status, 201)
        XCTAssertTrue(consent.asked.last?.summary.hasSuffix("→ 200") ?? false, consent.asked.last?.summary ?? "")
        XCTAssertEqual(try send("POST", "/v1/rules", ["hostId": 7, "mode": "map_local", "path": "/logo.png",
                                                      "localFile": ["content": "x", "contentType": "image/png"]]).status, 201)
        XCTAssertEqual(rules.created.map(\.responseStatus), [200, 0])
    }

    func testAStatusTheModeCannotAnswerWithIsRefusedBeforeAnyoneIsAsked() throws {
        let keep = try send("POST", "/v1/rules", ["hostId": 7, "mode": "override", "path": "/a", "responseStatus": 0])
        XCTAssertEqual(keep.status, 400)
        XCTAssertTrue(message(keep).contains("use mode extend"), message(keep))
        // A 1xx is never a final answer; the core used to crash on one.
        for (mode, status) in [("extend", 101), ("override", 100), ("extend", 600), ("map_local", 199)] {
            var body: [String: Any] = ["hostId": 7, "mode": mode, "path": "/a", "responseStatus": status]
            if mode == "map_local" { body["localFile"] = ["content": "x"] }
            XCTAssertEqual(try send("POST", "/v1/rules", body).status, 400, "\(mode) \(status)")
        }
        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertTrue(rules.created.isEmpty)
        // And one the mode answers with goes through.
        XCTAssertEqual(try send("POST", "/v1/rules", ["hostId": 7, "mode": "extend", "path": "/a", "responseStatus": 0]).status, 201)
        XCTAssertEqual(try send("POST", "/v1/rules", ["hostId": 7, "mode": "extend", "path": "/b", "responseStatus": 503]).status, 201)
        XCTAssertEqual(rules.created.map(\.responseStatus), [0, 503])
    }

    // MARK: - update_rule

    /// update_rule keeps a stored status unless sent one — through a change
    /// of mode too, checked against the mode the rule will have.
    func testAKeptStatusIsCheckedAgainstTheNewMode() throws {
        store(.extend, status: 0)
        let refused = try send("PATCH", "/v1/rules/3", ["mode": "override"])
        XCTAssertEqual(refused.status, 400)
        XCTAssertTrue(message(refused).contains("keeps the server's status"), message(refused))
        XCTAssertTrue(message(refused).contains("Send responseStatus"), message(refused))
        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertEqual(rules.stored.first?.mode, .extend)

        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "override", "responseStatus": 201]).status, 200)
        XCTAssertEqual(rules.stored.first?.mode, .override)
        XCTAssertEqual(rules.stored.first?.responseStatus, 201)

        // Kept on map_local, where it is not used, it stands.
        store(.extend, status: 0)
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "map_local", "localFile": ["content": "x"]]).status, 200)
        XCTAssertEqual(rules.stored.first?.responseStatus, 0)
    }

    /// A rule that stays an override cannot be told to keep the server's
    /// status; an extend rule can, and the panel says what it means.
    func testAStatusSentIsCheckedAgainstTheModeTheRuleWillHave() throws {
        store(.override, status: 200, body: "{}")
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["responseStatus": 0]).status, 400)
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "extend", "responseStatus": 0]).status, 200)
        XCTAssertEqual(rules.stored.first?.responseStatus, 0)
        XCTAssertEqual(consent.asked.last?.details, ["Mode → extend", "Status → server's status"])

        store(.extend, status: 404)
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["responseStatus": 0]).status, 200)
        XCTAssertEqual(consent.asked.last?.details, ["Status → server's status"])
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["responseStatus": 418]).status, 200)
        XCTAssertEqual(consent.asked.last?.details, ["Status → 418"])
    }

    /// The F17 trap through update_rule: an override's 200 kept on the
    /// extend rule it becomes answers every response on the path as 200.
    /// update_rule keeps it; the human approving it is told.
    func testAStatusKeptOntoAnExtendRuleSaysWhatItDoes() throws {
        let line = "Status kept: every response the rule matches comes back as 200, in place of the server's"
        store(.override, status: 200)
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "extend"]).status, 200)
        XCTAssertTrue(consent.asked.last?.details.contains(line) ?? false, "\(consent.asked.last?.details ?? [])")
        XCTAssertEqual(rules.stored.first?.responseStatus, 200, "kept as stored")
        // Nothing to point out: a status sent, or no mode change.
        store(.override, status: 200)
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "extend", "responseStatus": 0]).status, 200)
        XCTAssertFalse(consent.asked.last?.details.contains(line) ?? true)
        store(.override, status: 200)
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["enabled": false]).status, 200)
        XCTAssertEqual(consent.asked.last?.details, ["Disable"])
        // The mode the rule already has, re-sent: its status does not change,
        // so nothing is "kept" onto it — an extend rule at 200 included, and
        // whatever headers it carries (review of 261703b: the guard on the
        // rule's own mode had no test).
        store(.extend, status: 200, headers: [RuleResponseDefaults.contentTypeName: "text/plain"])
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "extend"]).status, 200)
        XCTAssertEqual(consent.asked.last?.details, ["Mode → extend"])
        XCTAssertEqual(rules.stored.first?.responseStatus, 200)
    }

    /// A map_local rule's status is not one it has — never used, never shown
    /// (list_rules prints its file) — so a map_local rule made extend or
    /// override starts with the new mode's status, as the form gives it,
    /// whatever was stored: build 53's 0 had the change to override refused
    /// as "this rule keeps the server's status", and an earlier form's 200
    /// was let through, and on extend answered every response with 200. The
    /// human approving it reads the status the rule will have.
    func testAMapLocalRuleTakesTheNewModesStatusNotAStoredOneNobodySees() throws {
        for stored in [0, 200, 404] {
            store(.mapLocal, status: stored)
            XCTAssertTrue(MCPTextFormat.ruleRow(rules.stored[0]).contains("→ a.json"), "what an agent is shown: the file")
            let override = try send("PATCH", "/v1/rules/3", ["mode": "override", "responseBody": "{}"])
            XCTAssertEqual(override.status, 200, "stored \(stored): \(message(override))")
            XCTAssertEqual(rules.stored.first?.responseStatus, 200, "stored \(stored): an override's start")
            XCTAssertTrue(consent.asked.last?.details.contains("Status → 200") ?? false, "\(consent.asked.last?.details ?? [])")

            store(.mapLocal, status: stored)
            XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "extend"]).status, 200)
            XCTAssertEqual(rules.stored.first?.responseStatus, 0, "stored \(stored): extend keeps the server's")
            let details = consent.asked.last?.details ?? []
            XCTAssertTrue(details.contains("Status → server's status"), "\(details)")
            XCTAssertFalse(details.contains { $0.hasPrefix("Status kept") }, "\(details)")
        }
        // A status sent with the change is the one checked and stored.
        store(.mapLocal, status: 0)
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "override", "responseStatus": 0]).status, 400)
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "extend", "responseStatus": 503]).status, 200)
        XCTAssertEqual(rules.stored.first?.responseStatus, 503)
    }

    /// A status sent to a map_local rule is not used, and the panel — whose
    /// lines the Activity log keeps — says so without printing it: "Status →
    /// 0" read as a status no response ever has (review of 261703b).
    func testAStatusSentToAMapLocalRuleIsShownAsNotUsedWithNoNumber() throws {
        let line = "Status: not used — a map_local rule answers 200 with its file"
        for status in [0, 404] {
            store(.mapLocal, status: 200)
            XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["responseStatus": status]).status, 200)
            XCTAssertEqual(consent.asked.last?.details, [line], "\(status)")
        }
        store(.extend, status: 0)
        XCTAssertEqual(try send("PATCH", "/v1/rules/3", ["mode": "map_local", "localFile": ["content": "x"], "responseStatus": 404]).status, 200)
        let details = consent.asked.last?.details ?? []
        XCTAssertTrue(details.contains(line), "\(details)")
        XCTAssertFalse(details.contains { $0.contains("404") || $0.contains("→ 0") }, "\(details)")
    }

    // MARK: - mock_from_session

    /// A mock answers itself: an override mock needs a final status, and a
    /// map_local mock answers 200 with its file whatever it is given.
    func testAMockIsCheckedAsTheRuleItMakes() throws {
        XCTAssertEqual(try send("POST", "/v1/rules/from-session", ["uid": "s1", "responseStatus": 0]).status, 400)
        XCTAssertEqual(try send("POST", "/v1/rules/from-session", ["uid": "s1", "responseStatus": 101]).status, 400)
        XCTAssertTrue(consent.asked.isEmpty)

        XCTAssertEqual(try send("POST", "/v1/rules/from-session", ["uid": "s1", "mode": "map_local", "responseStatus": 404]).status, 201)
        let details = consent.asked.last?.details ?? []
        XCTAssertTrue(details.contains("Status: not used — a map_local mock answers 200 with its file"), "\(details)")
        XCTAssertFalse(details.contains { $0.contains("replaces the captured") }, "\(details)")

        XCTAssertEqual(try send("POST", "/v1/rules/from-session", ["uid": "s1", "responseStatus": 503]).status, 201)
        XCTAssertTrue(consent.asked.last?.details.contains("Status: 503 (replaces the captured status)") ?? false,
                      "\(consent.asked.last?.details ?? [])")
    }

    /// Each tool refuses a status in its own words. A mock: left out, its
    /// status is the captured one, and it answers instead of the server, so
    /// there is no server status to keep — and no "use mode extend", which
    /// this route refuses. update_rule: left out, the rule keeps its current one.
    /// Neither says create_rule's "200 when you leave it out" (review of
    /// 261703b: they did).
    func testEachRouteRefusesAStatusInItsOwnWords() throws {
        capture("s1", status: 404)
        let keep = try send("POST", "/v1/rules/from-session", ["uid": "s1", "responseStatus": 0])
        XCTAssertEqual(keep.status, 400)
        XCTAssertEqual(message(keep), "A mock answers instead of the server, so it has no server status to keep: responseStatus must be a final HTTP status, 200–599; leave it out to replay the captured 404.")
        let interim = try send("POST", "/v1/rules/from-session", ["uid": "s1", "responseStatus": 101])
        XCTAssertEqual(message(interim), "responseStatus must be a final HTTP status, 200–599; leave it out to replay the captured 404.")

        store(.extend, status: 404)
        let extend = try send("PATCH", "/v1/rules/3", ["responseStatus": 101])
        XCTAssertEqual(extend.status, 400)
        XCTAssertTrue(message(extend).hasSuffix("; leave it out to keep the rule's current status."), message(extend))
        XCTAssertFalse(message(extend).contains("what an extend rule does when you leave it out"), message(extend))
        store(.override, status: 404, body: "{}")
        let override = try send("PATCH", "/v1/rules/3", ["responseStatus": 700])
        XCTAssertTrue(message(override).hasSuffix("; leave it out to keep the rule's current status."), message(override))
        XCTAssertFalse(message(override).contains("answers 200 when you leave it out"), message(override))
        let overrideKeep = try send("PATCH", "/v1/rules/3", ["responseStatus": 0])
        XCTAssertFalse(message(overrideKeep).contains("200 when you leave it out"), message(overrideKeep))
        XCTAssertTrue(message(overrideKeep).contains("Only an extend rule keeps the server's status"), message(overrideKeep))
        // Changing the mode, nothing is said of leaving it out.
        store(.extend, status: 0)
        let becoming = try send("PATCH", "/v1/rules/3", ["mode": "override", "responseStatus": 0])
        XCTAssertEqual(becoming.status, 400)
        XCTAssertFalse(message(becoming).contains("left out") || message(becoming).contains("leave it out"), message(becoming))
        XCTAssertTrue(consent.asked.isEmpty, "every refusal comes before anyone is asked")
    }

    /// A mock that names no status replays the captured one. A WebSocket's
    /// 101 is none a mock can answer with, and is refused before anyone is
    /// asked — not after, by the rule's validation, as a status the agent
    /// never sent. A map_local mock uses no status: it stores a map_local
    /// rule's 0, never the captured one. An override mock with a captured
    /// status it can answer with is left to replay it.
    func testAMockLeftWithoutAStatusIsCheckedOnTheCapturedOne() throws {
        capture("ws", status: 101)
        capture("ok", status: 404)
        let refused = try send("POST", "/v1/rules/from-session", ["uid": "ws", "responseBody": "{}"])
        XCTAssertEqual(refused.status, 400)
        XCTAssertTrue(message(refused).contains("Session ws's captured status, 101, is not one a mock can answer with"), message(refused))
        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertTrue(rules.mocked.isEmpty)
        // Given one, it goes through.
        XCTAssertEqual(try send("POST", "/v1/rules/from-session", ["uid": "ws", "responseBody": "{}", "responseStatus": 200]).status, 201)
        XCTAssertEqual(rules.mocked.last?.responseStatus, 200)

        // map_local: no status of its own, whatever was captured.
        for uid in ["ws", "ok"] {
            XCTAssertEqual(try send("POST", "/v1/rules/from-session", ["uid": uid, "mode": "map_local", "responseBody": "x"]).status, 201, uid)
            XCTAssertEqual(rules.mocked.last?.responseStatus, 0, "\(uid): a map_local rule's 0, not the captured status")
            XCTAssertFalse(consent.asked.last?.details.contains { $0.hasPrefix("Status") } ?? true, "\(uid): no status was sent, no line")
        }
        // An override, nothing sent: the capture's own is replayed.
        XCTAssertEqual(try send("POST", "/v1/rules/from-session", ["uid": "ok"]).status, 201)
        XCTAssertNil(rules.mocked.last?.responseStatus, "left to the adapter, which replays the captured 404")
    }
}

/// The form's wiring, read from the source: Sources/UI has no test target.
/// The decisions are tested above — the mode change whole, seeding, the new
/// rule's start — and the form's calls into them are one line each, pinned
/// here exactly, so the order of a mode change or what the save stores
/// cannot drift in view code no test reaches.
final class RuleModalDefaultsWiringTests: XCTestCase {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/MCPKitTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
    }

    /// The file with `//` comments dropped, so a comment that quotes the old
    /// code is not mistaken for it.
    private func code(_ relative: String) throws -> String {
        let text = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(relative), encoding: .utf8)
        return text.components(separatedBy: "\n").map { line in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    private let ruleModal = "UI/Views/Modals/RuleModal.swift"

    func testANewRuleStartsWithTheDefaultsOfTheFormsOpeningMode() throws {
        let form = try code(ruleModal)
        XCTAssertTrue(form.contains("@State private var ruleMode: RuleMode = .EXTEND"), "the form's opening mode moved — update the headers' start too")
        XCTAssertTrue(form.contains("@State private var rspHeaders: [HeaderEntry] = RuleResponseDefaults.headers(forNewRuleIn: .extend)"))
        XCTAssertFalse(form.contains("application/json; charset=utf-8"), "a Content-Type is hard-coded in the form again")
    }

    /// The body of `signature`'s braces, whitespace collapsed to single spaces.
    private func body(of signature: String, in form: String) throws -> String {
        let start = try XCTUnwrap(form.range(of: signature), "\(signature) is gone from the form")
        let open = try XCTUnwrap(form[start.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var index = open
        repeat {
            if form[index] == "{" { depth += 1 } else if form[index] == "}" { depth -= 1 }
            index = form.index(after: index)
        } while depth > 0 && index < form.endIndex
        return form[form.index(after: open)..<form.index(before: index)]
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The mode change is ONE call — the order (the old mode read before it
    /// is written) lives in `RuleResponseDefaults.changeMode`, tested above.
    func testTheModePickerChangesTheModeThroughOneCall() throws {
        let form = try code(ruleModal)
        XCTAssertTrue(form.contains(#"Picker("Mode", selection: Binding(get: { ruleMode }, set: { changeMode(to: $0) }))"#),
                      "the Mode picker writes ruleMode directly again: a change of mode leaves the old mode's default behind")
        XCTAssertFalse(form.contains("selection: $ruleMode"))
        XCTAssertEqual(try body(of: "private func changeMode(to newMode: RuleMode)", in: form),
                       "RuleResponseDefaults.changeMode(&ruleMode, headers: &rspHeaders, status: &status, to: newMode, as: MCPRuleAdapter.mcpMode)")
        XCTAssertTrue(form.contains("extension HeaderEntry: RuleHeaderEntry"))
    }

    /// The status (core 95062d1): ONE state, started, opened, offered and
    /// saved through `RuleResponseDefaults` — the decisions tested in
    /// `RuleStatusDefaultsTests`. Build 52's form opened a migrated rule's 0
    /// as 400 and saved it; every earlier one started Extend at 200.
    func testTheStatusIsStartedOpenedOfferedAndSavedThroughTheHelpers() throws {
        let form = try code(ruleModal)
        XCTAssertTrue(form.contains("@State private var status: RuleStatus = RuleResponseDefaults.status(forNewRuleIn: .extend)"),
                      "a new rule no longer starts with its opening mode's status")
        XCTAssertTrue(try body(of: "private func seedFromExistingRule()", in: form)
                        .contains("status = RuleResponseDefaults.status(seeding: rule.rspCode.intValue, mode: MCPRuleAdapter.mcpMode(rule.ruleMode))"),
                      "an existing rule's status is no longer opened as the core reads it")
        XCTAssertTrue(form.contains("rspCode: NSNumber(value: RuleResponseDefaults.storedStatus(status, mode: MCPRuleAdapter.mcpMode(ruleMode))),"),
                      "the save no longer stores what the Status menu shows")
        XCTAssertEqual(form.components(separatedBy: "rspCode:").count, 2, "one stored status, in save")
        XCTAssertTrue(try body(of: "private var responseRows: some View", in: form).contains(#"Picker("Status", selection: $status)"#))
        XCTAssertEqual(form.components(separatedBy: "selection: $status").count, 2, "one Status menu")
        XCTAssertEqual(try body(of: "private var statusMenu: [RuleStatusMenuGroup]", in: form),
                       "RuleResponseDefaults.statusMenu(for: MCPRuleAdapter.mcpMode(ruleMode), listing: Self.listedStatusCodes, current: status, opened: openedStatus)")
        XCTAssertEqual(try body(of: "private var openedStatus: RuleStatus?", in: form),
                       "existingRule.map { RuleResponseDefaults.status(seeding: $0.rspCode.intValue, mode: MCPRuleAdapter.mcpMode($0.ruleMode)) }",
                       "the menu keeps what the rule OPENED with, the way the seed reads it")
        XCTAssertFalse(try body(of: "private var localFileRows: some View", in: form).contains("Status"),
                       "Map Local shows no status: the core never uses it")
        XCTAssertTrue(form.contains("return RuleResponseDefaults.keepServerStatusTitle"))
        XCTAssertEqual(form.components(separatedBy: "rule.rspCode").count, 2, "the stored status is read once, to open it")
        for gone in ["responseOutcome", "statusCodeSuccess", "statusCodeFailure"] {
            XCTAssertFalse(form.contains(gone), "\(gone): a second status path is back in the form")
        }
    }

    /// Every mode shows its response headers — Map Local's too — and stores
    /// what it shows; an existing rule's are seeded through the helper.
    func testEveryModeShowsItsResponseHeadersAndStoresWhatItShows() throws {
        let form = try code(ruleModal)
        XCTAssertTrue(try body(of: "private var localFileRows: some View", in: form)
                        .contains(#"gridLabel("Headers") headersRow(count: rspHeaders.count, target: .response)"#),
                      "the Local File section no longer shows the response headers it stores")
        XCTAssertTrue(try body(of: "private var responseRows: some View", in: form)
                        .contains(#"gridLabel("Headers") headersRow(count: rspHeaders.count, target: .response)"#))
        XCTAssertTrue(form.contains("rspHeaders: encode(rspHeaders),"), "the save no longer stores what the form shows")
        XCTAssertEqual(form.components(separatedBy: "rspHeaders: encode(").count, 2, "one encoding of the response headers, in save")
        XCTAssertTrue(try body(of: "private func seedFromExistingRule()", in: form)
                        .contains("rspHeaders = RuleResponseDefaults.headers(seeding: headers, mode: MCPRuleAdapter.mcpMode(rule.ruleMode))"),
                      "an existing rule's response headers are no longer seeded through RuleResponseDefaults")
    }
}
