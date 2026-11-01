//
//  HelpPatternExamplesTests.swift
//  AppServices
//
//  Created by OloApps on 21.09.2026.
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
//  These would fail against a plausible but wrong Help example: swap a
//  badPath and goodPath, mistype a slash, or forget that http drops the
//  query, and the claim in the app no longer matches what OverridePattern
//  (the proxy's real algorithm, already covered by OverridePatternTests)
//  actually does with that exact URL.
//

import XCTest
@testable import MCPKit

final class HelpPatternExamplesTests: XCTestCase {

    func testEveryTrapsBadPathNeverMatchesItsExample() {
        for example in HelpPatternExample.all {
            XCTAssertFalse(
                OverridePattern.matches(url: example.exampleURL, path: example.badPath, isRegex: example.isRegex),
                "\(example.id): the Help window says this never fires, but OverridePattern matched it"
            )
        }
    }

    func testEveryTrapsFixMatchesTheSameExample() {
        for example in HelpPatternExample.all {
            XCTAssertTrue(
                OverridePattern.matches(url: example.exampleURL, path: example.goodPath, isRegex: example.isRegex),
                "\(example.id): the Help window's suggested fix should match the URL its own example is about"
            )
        }
    }

    /// A leading-^ or missing-slash regex trap is also a validation error the
    /// app's own forms and the MCP bridge reject outright (MCPWriteValidation
    /// .normalizedPath) — not just a pattern that quietly never matches. The
    /// Help window's copy ("A regex path must not start with...") is close
    /// paraphrase of that real error message, so pin that the fixed path is
    /// something the form would actually accept.
    func testRegexFixesPassTheSameValidationTheFormsUse() {
        for example in HelpPatternExample.all where example.isRegex {
            XCTAssertNoThrow(
                try MCPWriteValidation.normalizedPath(example.goodPath, matchType: .regex),
                "\(example.id): the suggested fix should be a path the rule form would accept"
            )
        }
    }

    func testBadRegexPathsAreRejectedByTheSameValidation() {
        for example in HelpPatternExample.all where example.isRegex {
            XCTAssertThrowsError(
                try MCPWriteValidation.normalizedPath(example.badPath, matchType: .regex),
                "\(example.id): the form should reject this path outright, not silently save an unfireable rule"
            )
        }
    }

    /// The content a reader sees is this array rendered verbatim — a blank
    /// field would ship as a blank paragraph or a missing example, and a
    /// duplicate id would collide as a SwiftUI `ForEach` identity.
    func testEveryExampleIsWellFormed() {
        let ids = HelpPatternExample.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate example ids collide as ForEach identities")
        for example in HelpPatternExample.all {
            XCTAssertFalse(example.title.isEmpty)
            XCTAssertFalse(example.explanation.isEmpty)
            XCTAssertFalse(example.badPath.isEmpty)
            XCTAssertFalse(example.goodPath.isEmpty)
            XCTAssertNotEqual(example.badPath, example.goodPath, "\(example.id): the trap and its fix must differ")
            XCTAssertTrue(example.exampleURL.hasPrefix("http"))
        }
    }
}
