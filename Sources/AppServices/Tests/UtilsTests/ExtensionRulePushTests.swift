//
//  ExtensionRulePushTests.swift
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
//  Pins protocol PRD §1.5 / Phase 1a.1: a rule switched off in the Overrides
//  list must not reach the extension. The function is pure; the wiring into
//  `AppController.notifyExtensionRulesChanged` is pinned by reading the app's
//  source, because the app target has no test target of its own and a filter
//  nobody calls would pass every other test here.
//

import XCTest
@testable import Utils

final class ExtensionRulePushTests: XCTestCase {
    /// A stand-in for the core's `RuleCodable`, which this package cannot
    /// import: an id and the same `NSNumber` flag.
    private struct Rule: Equatable {
        let id: Int
        let enabled: NSNumber
    }

    func testADisabledRuleIsNotPushed() {
        let rules = [Rule(id: 1, enabled: 1), Rule(id: 2, enabled: 0)]

        XCTAssertEqual(ExtensionRulePush.rulesToPush(rules) { $0.enabled }.map(\.id), [1])
    }

    func testEveryRuleDisabledPushesAnEmptyListSoTheExtensionDropsTheOldOnes() {
        // The extension REPLACES its rule list with what it is sent, so the
        // last enabled rule being switched off has to push [] — not skip the
        // push — or that rule keeps applying.
        let rules = [Rule(id: 1, enabled: 0), Rule(id: 2, enabled: false)]

        XCTAssertEqual(ExtensionRulePush.rulesToPush(rules) { $0.enabled }, [])
    }

    func testEnabledRulesKeepTheirStoredOrder() {
        // The core applies the first matching rule; reordering would change
        // which mock answers.
        let rules = [3, 1, 4, 1, 5, 9, 2, 6].enumerated().map { Rule(id: $0.element * 10 + $0.offset, enabled: NSNumber(value: $0.offset % 3 != 0)) }
        let pushed = ExtensionRulePush.rulesToPush(rules) { $0.enabled }

        XCTAssertEqual(pushed, rules.filter { $0.enabled.boolValue })
        XCTAssertEqual(pushed.count, 5)
    }

    /// The flag is read the way the Overrides list's toggle reads it
    /// (`rule.enabled.boolValue`), so a rule is applied exactly when the
    /// toggle shows it on.
    func testTheFlagIsReadLikeTheToggle() {
        for value: NSNumber in [0, 1, 2, -1, true, false, NSNumber(value: 0.0), NSNumber(value: 0.5)] {
            XCTAssertEqual(ExtensionRulePush.isEnabled(value), value.boolValue, "\(value)")
        }
        XCTAssertFalse(ExtensionRulePush.isEnabled(0))
        XCTAssertTrue(ExtensionRulePush.isEnabled(1))
    }

    // MARK: - The wiring

    private static var appControllerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
            .appendingPathComponent("UI/Controllers/AppController.swift")
    }

    /// `notifyExtensionRulesChanged` is the one door every rule push goes
    /// through (the Overrides toggle, edits, deletes, agent writes and the
    /// status update after a tunnel start). The filter must be applied there,
    /// BEFORE the Map Local loop — which reads each rule's file from disk —
    /// and before the `.rulesChanged` message is built.
    func testAppControllerFiltersBeforeItReadsMapLocalFilesOrSends() throws {
        let source = try String(contentsOf: Self.appControllerURL, encoding: .utf8)
        let function = try XCTUnwrap(source.range(of: "func notifyExtensionRulesChanged(rules: [RuleCodable]) async"),
                                     "AppController.notifyExtensionRulesChanged not found — renamed? Update this test and keep the filter in it.")
        let body = source[function.upperBound...]
        let filter = try XCTUnwrap(body.range(of: "ExtensionRulePush.rulesToPush(rules) { $0.enabled }"),
                                   "the rules push no longer filters disabled rules")
        let mapLocalLoop = try XCTUnwrap(body.range(of: "for rule in rules {"))
        let send = try XCTUnwrap(body.range(of: "action: .rulesChanged"))

        XCTAssertLessThan(filter.lowerBound, mapLocalLoop.lowerBound, "filter before the Map Local loop reads files")
        XCTAssertLessThan(filter.lowerBound, send.lowerBound, "filter before the message is built")
        // The filtered list must SHADOW the parameter, so the loop and the
        // payload below cannot reach the unfiltered one by accident.
        XCTAssertTrue(body[..<filter.lowerBound].hasSuffix("let rules = "), "the filtered list must shadow `rules`")
    }
}
