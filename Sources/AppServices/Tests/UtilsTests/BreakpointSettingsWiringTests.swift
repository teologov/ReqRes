//
//  BreakpointSettingsWiringTests.swift
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
//  Settings ▸ Breakpoints' side of the F13 class, read from the source:
//  Sources/UI has no test target, and the change is a few lines — where the
//  note under the Add form comes from, and what Add records. The decisions
//  are tested in BreakpointRuleEntryTests; these check the pane and the
//  service still use them.
//

import XCTest

final class BreakpointSettingsWiringTests: XCTestCase {
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
        let ends = ["\n    func ", "\n    private func ", "\n    private var ", "\n    static func ", "\n    private static ",
                    "\n    #if ", "\n}\n"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }

    private static let settings = "UI/Views/SettingsView/BreakpointSettingsView.swift"
    private static let service = "UI/Services/BreakpointService.swift"

    /// The pane's bullet says what `persistAndPush` does: a request already
    /// held stays held while another breakpoint is armed, and turning off or
    /// removing the last armed one releases everything held, unchanged. The
    /// bullet used to say turning one off "never affects" a held request;
    /// Help said it right.
    func testThePaneSaysTheLastBreakpointOffReleasesWhatIsHeld() throws {
        let pane = try code(Self.settings)
        XCTAssertFalse(pane.contains("never affects a request already being held"))
        XCTAssertTrue(pane.contains("does not release a request it is already holding while another breakpoint is still armed. Answer it, or let it time out. With none left armed, everything held is released, unchanged."))
        let persist = try body(of: "private func persistAndPush()", in: try code(Self.service))
        XCTAssertTrue(persist.contains("if !isArmed, !pending.isEmpty {"), "the release the bullet describes")
        XCTAssertTrue(persist.contains("resumeAll()"))
    }

    /// The note is not stored: it is derived, on every render, from what Add
    /// refused (which any edit forgets) and the rules as they are now. The
    /// stored note outlived an edit of the path or the methods, and the
    /// removal of the rule it named.
    func testTheNoteIsDerivedNotStored() throws {
        let pane = try code(Self.settings)
        XCTAssertFalse(pane.contains("@State private var note"), "a stored note")
        let writes = pane.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("note = ") }
        XCTAssertEqual(writes, [], "anything that writes a note")
        XCTAssertTrue(pane.contains("@State private var form = BreakpointRuleForm()"))
        XCTAssertTrue(pane.contains("if let note = form.note(existing: service.rules.map(\\.spec)) {"))
    }

    /// Every field edits the form, which is what forgets the refusal — the
    /// Host field was the only one that cleared the note.
    func testEveryFieldEditsTheForm() throws {
        let pane = try code(Self.settings)
        XCTAssertTrue(pane.contains("TextField(\"\", text: $form.host,"))
        XCTAssertTrue(pane.contains("TextField(\"\", text: $form.path,"))
        XCTAssertTrue(pane.contains("Button(\"Any method\") { form.methods.removeAll() }"))
        XCTAssertTrue(pane.contains("if isOn { form.methods.insert(method) } else { form.methods.remove(method) }"))
        XCTAssertFalse(pane.contains("newHost"), "the old per-field state is gone")
        XCTAssertFalse(pane.contains("newPath"))
        XCTAssertFalse(pane.contains("newMethods"))
    }

    /// Add hands the form to the service and records the answer on the form.
    func testAddRecordsWhatWasRefused() throws {
        let pane = try code(Self.settings)
        let add = try body(of: "private func add() {", in: pane)
        XCTAssertTrue(add.contains("guard form.canSubmit else { return }"), String(add))
        XCTAssertTrue(add.contains("service.addRule(host: form.host, pathContains: form.pathContains, methods: methods)"), String(add))
        XCTAssertTrue(add.contains("form.submitted(accepted: refusal == nil)"), String(add))
    }

    /// One decision for the list and the note: the service's Add runs the
    /// same refusal the note is derived from, and nothing in the app has a
    /// second spelling of the rule text.
    func testTheServiceRefusesWithTheSameDecision() throws {
        let service = try code(Self.service)
        let add = try body(of: "func addRule(host rawHost: String, pathContains: String? = nil, methods: [String] = []) -> BreakpointRuleEntry.Refusal? {", in: service)
        XCTAssertTrue(add.contains("BreakpointRuleEntry.refusal("), String(add))
        XCTAssertTrue(add.contains("existing: rules.map(\\.spec)"), String(add))
        XCTAssertFalse(service.contains("static func canonicalHost"), "a second canonical host in the service")
        XCTAssertFalse(try code(Self.settings).contains("BreakpointHostEntry"), "the unused, drifted copy in the pane")
    }
}
