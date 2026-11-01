//
//  CaptureSettingsWiringTests.swift
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
//  Settings ▸ Capture's side of F16 and F13, read from the source: Sources/UI
//  has no test target, and the change a person meets there is one line each —
//  what Copy puts on the pasteboard, where a refusal note comes from. The
//  block itself is tested in CaptureEnvironmentLinesTests and
//  CaptureEnvironmentShellTests, the notes in ExcludedHostListTests and
//  ProxyPortSettingTests; these check the pane still uses them.
//

import XCTest

final class CaptureSettingsWiringTests: XCTestCase {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
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

    /// From `signature` to the next member declared at the same indentation
    /// (or the end of the type), whichever comes first.
    private func body(of signature: String, in text: String, file: StaticString = #filePath, line: UInt = #line) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found — renamed? Update this test.", file: file, line: line)
        let rest = text[start.upperBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    private var ", "\n    private static ", "\n    #if ", "\n}\n"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }

    private static let settings = "UI/Views/SettingsView/CaptureSettingsView.swift"

    // MARK: - F16: what is shown is what is copied

    /// The box shows the block and Copy copies the same text — the block
    /// carries no comment, so a paste of either runs every line. Before, Copy
    /// had its own commands-only text and the box showed comments that, pasted
    /// by hand, stopped zsh partway (and reverting Copy failed no test).
    func testCopyPutsExactlyTheShownBlockOnThePasteboard() throws {
        let pane = try code(Self.settings)
        let copy = try body(of: "private func copyEnvironment()", in: pane)
        XCTAssertTrue(copy.contains("NSPasteboard.general.setString(environment.text, forType: .string)"), String(copy))
        XCTAssertEqual(pane.components(separatedBy: "setString(").count - 1, 1, "one thing is copied, and it is the block")
        XCTAssertTrue(pane.contains("Text(verbatim: environment.text)"), "the box shows the block")
        XCTAssertEqual(pane.components(separatedBy: "environment.text").count - 1, 2, "the box and Copy, nothing else")
        XCTAssertFalse(pane.contains("copyText"), "one text, shown and copied")
    }

    /// What each line is for is printed beside the box, from the type the
    /// tests hold to naming every variable the block exports.
    func testTheLegendIsPrintedBesideTheBlock() throws {
        let pane = try code(Self.settings)
        let box = try XCTUnwrap(pane.range(of: "Text(verbatim: environment.text)"))
        let legend = try XCTUnwrap(pane.range(of: "Text(CaptureEnvironmentLines.legend)"))
        XCTAssertLessThan(box.lowerBound, legend.lowerBound, "the legend follows the box")
    }

    /// The keychain caption speaks of "the security line" only when the block
    /// has one; with no export and no fingerprint there is none.
    func testTheSecurityLineIsNamedOnlyWhenTheBlockHasOne() throws {
        let pane = try code(Self.settings)
        let caption = try XCTUnwrap(pane.range(of: "the security line writes the certificate from your login keychain"))
        let condition = try XCTUnwrap(pane.range(of: "if environment.hasKeychainStep {", options: .backwards,
                                                 range: pane.startIndex..<caption.lowerBound))
        XCTAssertFalse(pane[condition.upperBound..<caption.lowerBound].contains("}"), "the caption sits in that branch")
    }

    // MARK: - F13: a note belongs to the text it was written for

    /// Neither note is stored: each is derived, on every render, from the
    /// text Add or Apply refused, the field as it is, and — for the exclusion
    /// list — the list as it is. A stored note outlived the host it named.
    func testTheRefusalNotesAreDerivedNotStored() throws {
        let pane = try code(Self.settings)
        XCTAssertFalse(pane.contains("@State private var note"), "a stored exclusion note")
        XCTAssertFalse(pane.contains("@State private var proxyPortProblem"), "a stored port note")
        XCTAssertTrue(pane.contains("if let note = settings.list.refusalNote(submitted: refusedHost, current: newHost) {"))
        XCTAssertTrue(pane.contains("if let proxyPortProblem = ProxyPortSetting.problem(submitted: refusedPortText, current: proxyPortText) {"))
    }

    /// An edit takes the submission back, as Breakpoints' note does, so a note
    /// never sits under text it was not written for.
    func testAnEditClearsTheRefusedText() throws {
        let pane = try code(Self.settings)
        XCTAssertTrue(pane.contains(".onChange(of: newHost) { _, _ in refusedHost = nil }"))
        XCTAssertTrue(pane.contains(".onChange(of: proxyPortText) { _, _ in refusedPortText = nil }"))
    }

    /// Add and Apply record what they refused, and forget it on success.
    func testAddAndApplyRecordWhatTheyRefused() throws {
        let pane = try code(Self.settings)
        let add = try body(of: "private func add()", in: pane)
        XCTAssertTrue(add.contains("if settings.exclude(raw) {"))
        XCTAssertTrue(add.contains("refusedHost = nil"))
        XCTAssertTrue(add.contains("refusedHost = raw"))
        let apply = try body(of: "private func applyProxyPort()", in: pane)
        XCTAssertTrue(apply.contains("guard ProxyPortSetting.problem(with: proxyPortText) == nil else {"))
        XCTAssertTrue(apply.contains("refusedPortText = proxyPortText"))
        XCTAssertTrue(apply.contains("refusedPortText = nil"))
    }

    // MARK: - Help

    /// Help's example has no Copy button, so it must print the same pasteable
    /// text the pane does.
    func testHelpPrintsTheSameBlock() throws {
        let help = try code("UI/Views/Help/HelpContent.swift")
        XCTAssertTrue(help.contains("helpExample(CaptureEnvironmentLines(proxyPort: CaptureProxyPort.configured).text)"))
        XCTAssertFalse(help.contains("Copy leaves out the comments"), "there are no comments to leave out")
    }
}
