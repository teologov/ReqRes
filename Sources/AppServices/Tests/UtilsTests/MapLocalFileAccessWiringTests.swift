//
//  MapLocalFileAccessWiringTests.swift
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
//  F24 (2026-10-26): a Map Local rule's file must stay readable after a relaunch
//  (a security-scoped bookmark kept by the rule form, resolved at the rules
//  push), and a file that cannot be read must be answered by ReqRes — 500 with a
//  note — and marked in the Overrides list, never forwarded to the server in
//  silence. Sources/UI has no test target; this reads the files.
//

import XCTest

final class MapLocalFileAccessWiringTests: XCTestCase {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.sourcesRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    func testTheRulesPushReadsThroughTheAccessAndNeverBuildsAFileURLByHand() throws {
        let controller = try source("UI/Controllers/AppController.swift")
        let function = try XCTUnwrap(controller.range(of: "func notifyExtensionRulesChanged(rules: [RuleCodable]) async"))
        let body = controller[function.upperBound...]
        XCTAssertTrue(body.contains("MapLocalFileAccess.shared"))
        XCTAssertTrue(body.contains(".ruleForPush(rule)"))
        XCTAssertTrue(body.contains("prune(keeping:"), "bookmarks of files no rule names are dropped at the push")
        XCTAssertTrue(body.contains("AppState.shared.unreadableMapLocalFiles = "), "the list learns which files cannot be read")
        // The old code built "file://" + path by hand: a path with a space made
        // URL(string:) nil, and the rule forwarded.
        XCTAssertFalse(controller.contains("\"file://\" + "))
        XCTAssertFalse(controller.contains("Data(contentsOf: fileURL)"))
    }

    func testAnUnreadableFileIsAnsweredByReqResNotForwarded() throws {
        let access = try source("UI/Services/MapLocalFileAccess.swift")
        XCTAssertTrue(access.contains("answer.ruleMode = .OVERRIDE"), "an Override with a body is answered locally (D3)")
        XCTAssertTrue(access.contains("NSNumber(value: MapLocalUnreadable.status)"))
        XCTAssertTrue(access.contains("MapLocalUnreadable.body(path: rule.rspPath)"))
        XCTAssertTrue(access.contains("answer.mapLocalData = nil"))
        XCTAssertTrue(access.contains(".withSecurityScope"), "the bookmark carries the sandbox grant")
        XCTAssertTrue(access.contains("startAccessingSecurityScopedResource()"))
        XCTAssertTrue(access.contains("URL(fileURLWithPath: path)"), "rules made before build 59 keep their plain path")
    }

    func testTheFormRemembersTheChosenFileAfterValidatingIt() throws {
        let form = try source("UI/Views/Modals/RuleModal.swift")
        let chosen = try XCTUnwrap(form.range(of: "private func fileChosen("))
        let afterChosen = form[chosen.upperBound...]
        let validate = try XCTUnwrap(afterChosen.range(of: "try MapLocalConfig.validateFile(at: url)"))
        let remember = try XCTUnwrap(afterChosen.range(of: "MapLocalFileAccess.shared.remember(url)"))
        XCTAssertLessThan(validate.lowerBound, remember.lowerBound, "a refused file is not remembered")
        XCTAssertTrue(form.contains("MapLocalUnreadable.formMessage(fileName:"), "the form says when the existing file cannot be read")
    }

    func testTheOverridesListMarksARuleWhoseFileCannotBeRead() throws {
        let row = try source("UI/Views/RuleView.swift")
        XCTAssertTrue(row.contains("var fileUnreadable: Bool = false"))
        XCTAssertTrue(row.contains("MapLocalUnreadable.listRowLabel"))
        XCTAssertTrue(row.contains("MapLocalUnreadable.listRowHelp(fileName:"))

        let list = try source("UI/Views/AppView.swift")
        XCTAssertTrue(list.contains("fileUnreadable: rule.ruleMode == .MAP_LOCAL && appState.unreadableMapLocalFiles.contains(rule.rspPath)"))

        let state = try source("UI/Models/AppState.swift")
        XCTAssertTrue(state.contains("@Published var unreadableMapLocalFiles: Set<String> = []"))
    }

    func testADeletedRuleIsPushedAway() throws {
        // The extension replaces its rule list with what it is sent; a delete that
        // pushed nothing left the rule applying until the next push (found with F24).
        let state = try source("UI/Models/AppState.swift")
        let delete = try XCTUnwrap(state.range(of: "public func deleteRule(_ rule: RuleCodable)"))
        let body = state[delete.upperBound...]
        let push = try XCTUnwrap(body.range(of: "notifyExtensionRulesChanged(rules: allRules)"), "deleteRule pushes the rules that are left")
        let nextFunction = try XCTUnwrap(body.range(of: "public func "))
        XCTAssertLessThan(push.lowerBound, nextFunction.lowerBound, "the push is inside deleteRule")
    }

    func testTheServiceIsInTheXcodeProject() throws {
        // Sources/UI is not a synchronized group: a file not in the pbxproj is not
        // compiled, and swift test cannot tell.
        let project = try source("ReqRes.xcodeproj/project.pbxproj")
        // Four lines name it: the file reference, the build file, the Services group
        // child and the Sources build phase (the first two name it twice each).
        let lines = project.components(separatedBy: "\n").filter { $0.contains("MapLocalFileAccess.swift") }
        XCTAssertEqual(lines.count, 4, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("isa = PBXFileReference") })
        XCTAssertTrue(lines.contains { $0.contains("isa = PBXBuildFile") })
    }

    func testHelpSaysWhatAnUnreadableFileDoes() throws {
        let help = try source("UI/Views/Help/HelpContent.swift")
        XCTAssertTrue(help.contains("a matching request is answered with 500 and a note saying so, never with the real server's response"))
        XCTAssertFalse(help.contains("the request goes on to the real server"), "the pre-F24 claim")
    }
}
