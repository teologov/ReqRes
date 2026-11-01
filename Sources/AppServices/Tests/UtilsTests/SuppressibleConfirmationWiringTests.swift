//
//  SuppressibleConfirmationWiringTests.swift
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
//  The app side of the three “Don’t ask again” alerts, read from the source:
//  Sources/UI has no test target. On macOS 27 the checkbox those alerts added
//  as an `accessoryView` was never drawn when Clear Captured Traffic ran from
//  the toolbar's trash, a SwiftUI Button: the alert kept the checkbox's space
//  and showed nothing (seen in a screenshot, 2026-10-01; measured for that
//  path — the two context menus' alerts were not). NSAlert's own suppression
//  button draws there. These check that every such alert goes through
//  `SuppressibleConfirmationAlert`, straight from the action that asks for it;
//  that it uses the suppression button with the shared title; that it, and
//  nothing else, turns a prompt off, and only for the action chosen with the
//  box ticked; and that Settings and the toolbar's overflow row keep up with
//  it. The decisions are tested in SuppressibleConfirmationsTests.
//

import XCTest
import Utils

final class SuppressibleConfirmationWiringTests: XCTestCase {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
    }

    /// The text with every comment dropped — `//` to the end of the line and
    /// `/* … */`, nested as Swift nests them — so neither a comment that
    /// quotes the old code nor code switched off inside one passes for code.
    /// String literals are read as strings and their interpolations as code:
    /// the "*/*", "/api/*" and "https://…" in the app's strings start no
    /// comment. Line breaks are kept.
    private func stripComments(_ text: String) -> String {
        enum Context {
            case code(interpolation: Bool, depth: Int)
            case string(hashes: Int, multiline: Bool)
            case comment
        }
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var stack: [Context] = [.code(interpolation: false, depth: 0)]
        var i = 0
        func starts(_ literal: String, at j: Int) -> Bool {
            var k = j
            for scalar in literal.unicodeScalars {
                guard k < s.count, s[k] == scalar else { return false }
                k += 1
            }
            return true
        }
        func hashes(at j: Int) -> Int {
            var n = 0
            while j + n < s.count, s[j + n] == "#" { n += 1 }
            return n
        }
        func keep(_ count: Int) {
            let end = min(i + count, s.count)
            out.append(contentsOf: s[i..<end])
            i = end
        }
        while i < s.count {
            switch stack[stack.count - 1] {
            case .comment:
                if starts("/*", at: i) {
                    stack.append(.comment)
                    i += 2
                } else if starts("*/", at: i) {
                    stack.removeLast()
                    i += 2
                } else {
                    if s[i] == "\n" { out.append("\n") }
                    i += 1
                }
            case let .string(hashCount, multiline):
                let closing = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashCount)
                if starts(closing, at: i) {
                    keep(closing.unicodeScalars.count)
                    stack.removeLast()
                } else if s[i] == "\\", hashes(at: i + 1) >= hashCount {
                    // `\(` — `\#(` in a raw string — opens an interpolation;
                    // anything else after the backslash is an escape.
                    let after = i + 1 + hashCount
                    let interpolates = after < s.count && s[after] == "("
                    keep(after + 1 - i)
                    if interpolates { stack.append(.code(interpolation: true, depth: 0)) }
                } else {
                    // A one-line literal cannot cross a line; one left open ends there.
                    if s[i] == "\n", !multiline { stack.removeLast() }
                    keep(1)
                }
            case let .code(interpolation, depth):
                if starts("//", at: i) {
                    while i < s.count, s[i] != "\n" { i += 1 }
                } else if starts("/*", at: i) {
                    stack.append(.comment)
                    i += 2
                } else if s[i] == "#" || s[i] == "\"" {
                    let hashCount = hashes(at: i)
                    if i + hashCount < s.count, s[i + hashCount] == "\"" {
                        let multiline = starts("\"\"\"", at: i + hashCount)
                        keep(hashCount + (multiline ? 3 : 1))
                        stack.append(.string(hashes: hashCount, multiline: multiline))
                    } else {
                        keep(max(hashCount, 1))
                    }
                } else if interpolation, s[i] == "(" {
                    stack[stack.count - 1] = .code(interpolation: true, depth: depth + 1)
                    keep(1)
                } else if interpolation, s[i] == ")" {
                    if depth == 0 {
                        stack.removeLast()
                    } else {
                        stack[stack.count - 1] = .code(interpolation: true, depth: depth - 1)
                    }
                    keep(1)
                } else {
                    keep(1)
                }
            }
        }
        return String(out)
    }

    private func code(_ relative: String) throws -> String {
        stripComments(try String(contentsOf: Self.sourcesRoot.appendingPathComponent(relative), encoding: .utf8))
    }

    /// Every Swift file of the app, as (path under Sources/, code).
    private func appFiles() throws -> [(path: String, code: String)] {
        let ui = Self.sourcesRoot.appendingPathComponent("UI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the walk found the app's sources")
        return try files.map { file in
            (String(file.path.dropFirst(Self.sourcesRoot.path.count)),
             stripComments(try String(contentsOf: file, encoding: .utf8)))
        }
    }

    /// From `signature` to the next member declared at the same indentation
    /// (or the end of the type), whichever comes first.
    private func body(of signature: String, in text: String, file: StaticString = #filePath, line: UInt = #line) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found — renamed? Update this test.", file: file, line: line)
        let rest = text[start.upperBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    private static ",
                    "\n    @objc ", "\n    var body: some View {", "\n}\n"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }

    private func occurrences(of needle: String, in text: Substring) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The first capture group of every match of `pattern` in `text`.
    private func captures(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// How many times `pattern` matches in `text`.
    private func matches(_ pattern: String, in text: String) throws -> Int {
        try NSRegularExpression(pattern: pattern).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Nothing in `text` puts the alert off to later: a modal started inside a
    /// deferred main-queue block holds back every other main-queue block until
    /// it is answered.
    private func assertAsksAtOnce(_ text: Substring, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for deferral in ["DispatchQueue", "RunLoop", "perform(", "Task", "async", "beginSheetModal", "asyncAfter"] {
            XCTAssertFalse(text.contains(deferral), "\(what) defers the alert (\(deferral))", file: file, line: line)
        }
    }

    private let slots = "UI/Views/Toolbar/ReqResToolbarSlots.swift"
    private let controller = "UI/Views/Toolbar/ReqResToolbarController.swift"
    private let appView = "UI/Views/AppView.swift"
    private let settings = "UI/Views/SettingsView/SettingsView.swift"

    /// `SuppressibleConfirmationAlert.confirm`, from the end of its signature.
    private func helper() throws -> Substring {
        try body(of: "suppressionKey: String) -> Bool {", in: code(slots))
    }

    // MARK: - No alert carries its own checkbox

    /// No NSAlert in the app has an `accessoryView` — a hand-made checkbox
    /// (or anything else) in one is what macOS 27 left undrawn. An alert's
    /// "don't ask again" is its suppression button, through the helper.
    func testNoAlertInTheAppUsesAnAccessoryView() throws {
        var offenders: [String] = []
        var alertsFound = 0
        for (path, text) in try appFiles() {
            // Every name an NSAlert is bound to here: `let alert = NSAlert()`
            // (typed or not, `.init` or not), and a parameter or property
            // declared `: NSAlert`.
            let names = try captures(#"\b(?:let|var)\s+(\w+)\s*(?::\s*NSAlert\s*)?=\s*NSAlert\s*(?:\.init\s*)?\("#, in: text)
                + captures(#"\b(\w+)\s*:\s*NSAlert\b"#, in: text)
            alertsFound += names.count
            for name in Set(names) where text.range(of: #"\b\#(name)\s*\.\s*accessoryView\b"#, options: .regularExpression) != nil {
                offenders.append("\(path): \(name).accessoryView")
            }
            if text.range(of: #"NSAlert\s*\([^)]*\)\s*\.\s*accessoryView"#, options: .regularExpression) != nil {
                offenders.append("\(path): NSAlert().accessoryView")
            }
        }
        // The helper's alert and the app's three others (the extension
        // activation error, the quit prompt, `TrafficCommands.presentAlert`) —
        // so the pattern really finds alerts.
        XCTAssertGreaterThanOrEqual(alertsFound, 4)
        XCTAssertEqual(offenders, [], "an NSAlert with an accessory view: use SuppressibleConfirmationAlert")
    }

    /// Nothing in the app spells the checkbox's title out — neither ours nor
    /// one of AppKit's defaults: the helper and Settings both take
    /// `SuppressibleConfirmations.checkboxTitle`.
    func testNoCodeSpellsTheCheckboxTitleOut() throws {
        for (path, text) in try appFiles() {
            for spelled in ["Don't ask again", "Don\u{2019}t ask again", "Do not ask again", "Do not show this message again"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(spelled), "\(path) spells out “\(spelled)”")
            }
        }
    }

    // MARK: - The helper

    /// NSAlert's own suppression button, titled from the shared constant before
    /// the alert runs — never a button of our own.
    func testTheHelperShowsTheSuppressionButtonWithTheSharedTitle() throws {
        let confirm = try helper()
        let shows = try XCTUnwrap(confirm.range(of: "alert.showsSuppressionButton = true"), String(confirm))
        let titled = try XCTUnwrap(confirm.range(of: "alert.suppressionButton?.title = SuppressibleConfirmations.checkboxTitle"),
                                   String(confirm))
        let runs = try XCTUnwrap(confirm.range(of: "alert.runModal()"))
        XCTAssertLessThan(shows.lowerBound, titled.lowerBound,
                          "shown, then titled — macOS 27 takes either order; older macOS was not checked")
        XCTAssertLessThan(titled.lowerBound, runs.lowerBound, "the title is set before the alert runs")
        XCTAssertFalse(confirm.contains("accessoryView"))
        XCTAssertFalse(confirm.contains("NSButton("), "a checkbox of our own")
        XCTAssertTrue(try code(slots).contains("@MainActor\nenum SuppressibleConfirmationAlert {"))
    }

    /// The action is the first button (Return), Cancel the second (Esc), and
    /// the alert says what it is asked to say.
    func testTheHelperAsksWithTheActionFirstAndCancelOnEscape() throws {
        let confirm = try helper()
        XCTAssertTrue(confirm.contains("alert.messageText = title"))
        XCTAssertTrue(confirm.contains("alert.informativeText = message"))
        XCTAssertTrue(confirm.contains("alert.alertStyle = .warning"))
        let action = try XCTUnwrap(confirm.range(of: "alert.addButton(withTitle: actionTitle)"))
        let cancel = try XCTUnwrap(confirm.range(of: "alert.addButton(withTitle: \"Cancel\")"))
        XCTAssertLessThan(action.lowerBound, cancel.lowerBound, "the action is the default button")
        XCTAssertEqual(occurrences(of: "addButton(", in: confirm), 2)
        // Esc goes to the LAST button, so only once Cancel is that button:
        // set any earlier and the action trades Return for Esc, leaving the
        // alert with no default button.
        let escape = try XCTUnwrap(confirm.range(of: "alert.buttons.last?.keyEquivalent = \"\\u{1b}\""), String(confirm))
        XCTAssertLessThan(cancel.lowerBound, escape.lowerBound, "Esc is given before Cancel is added")
        XCTAssertEqual(occurrences(of: "keyEquivalent", in: confirm), 1)
    }

    /// The prompt is turned off only when the action was chosen with the box
    /// ticked — one write, inside that decision, after the alert has run; the
    /// answer returned is the action's. The box is only ever read: ticked
    /// before the alert runs, Return would turn the prompt off for good.
    func testTheHelperRemembersOnlyTheActionChosenWithTheBoxTicked() throws {
        let confirm = try helper()
        XCTAssertTrue(confirm.contains("let confirmed = alert.runModal() == .alertFirstButtonReturn"), String(confirm))
        XCTAssertTrue(confirm.contains("let ticked = alert.suppressionButton?.state == .on"), String(confirm))
        XCTAssertTrue(confirm.contains(
            "if SuppressibleConfirmations.remembersChoice(confirmed: confirmed, ticked: ticked) {\n"
            + "            UserDefaults.standard.set(true, forKey: suppressionKey)\n"
            + "        }\n"
            + "        return confirmed\n"), String(confirm))
        XCTAssertEqual(occurrences(of: "UserDefaults", in: confirm), 1, "a second write, outside the decision")
        XCTAssertEqual(occurrences(of: "forKey:", in: confirm), 1)
        XCTAssertEqual(occurrences(of: "runModal()", in: confirm), 1)
        XCTAssertEqual(occurrences(of: ".state", in: confirm), 1, "the box is set, or read twice")
        XCTAssertEqual(try matches(#"\bstate\s*=(?!=)"#, in: String(confirm)), 0, "the box is ticked for the person")
        for click in ["performClick", "setNextState"] {
            XCTAssertFalse(confirm.contains(click), "the box is ticked for the person (\(click))")
        }
        let runs = try XCTUnwrap(confirm.range(of: "alert.runModal()"))
        let reads = try XCTUnwrap(confirm.range(of: "alert.suppressionButton?.state"))
        XCTAssertLessThan(runs.lowerBound, reads.lowerBound, "the box is read after the person answered")
    }

    /// The alert runs where it is asked for, synchronously: a modal started
    /// inside a deferred main-queue block holds back every other main-queue
    /// block until it is answered.
    func testTheHelperAsksSynchronously() throws {
        assertAsksAtOnce(try helper(), "the helper")
    }

    /// The helper, and nothing else, turns a prompt off. No other code writes
    /// a suppression key — by its constant, by its raw name, or through the
    /// @AppStorage property a context menu reads: such a write after any
    /// Delete or Clear, ticked or not, would silence the prompt.
    func testOnlyTheHelperTurnsAPromptOff() throws {
        var offenders: [String] = []
        var stores: [String] = []
        var writesByParameter = 0
        for (path, text) in try appFiles() {
            // By constant, the app only ever READS a key (the clear's guard).
            if try matches(#"forKey:\s*SuppressibleConfirmations\."#, in: text)
                != matches(#"\.bool\(\s*forKey:\s*SuppressibleConfirmations\."#, in: text) {
                offenders.append("\(path): a suppression key written by its constant")
            }
            // The raw names live in Utils alone.
            for key in SuppressibleConfirmations.all where text.contains("\"\(key)\"") {
                offenders.append("\(path): \"\(key)\" spelled out")
            }
            // The helper's one write, by the key it is handed.
            writesByParameter += try matches(#"forKey:\s*suppressionKey\b"#, in: text)
            // A context menu's store: declared (`= false`), then only read.
            for name in try captures(#"@AppStorage\(SuppressibleConfirmations\.\w+\)\s*(?:private\s+)?var\s+(\w+)"#, in: text) {
                stores.append(name)
                if try matches(#"\b\#(name)\s*=(?!=)"#, in: text) != 1 {
                    offenders.append("\(path): \(name) assigned")
                }
                if try matches(#"\$\#(name)\b|\b_\#(name)\b|\b\#(name)\s*\.\s*toggle\s*\("#, in: text) != 0 {
                    offenders.append("\(path): \(name) bound or toggled")
                }
            }
        }
        XCTAssertEqual(stores.sorted(), ["skipDeleteConfirmation", "skipHostDeleteConfirmation"],
                       "the context menus' stores — so the scan really finds them")
        XCTAssertEqual(writesByParameter, 1, "a write by a key handed in, outside the helper")
        XCTAssertEqual(offenders, [])
    }

    // MARK: - The three alerts

    /// Clearing captured traffic: a prompt already turned off clears without
    /// asking; otherwise the helper asks, with the grouped count and the
    /// prompt's own key.
    func testClearingTrafficAsksThroughTheHelper() throws {
        let clear = try body(of: "static func clearTraffic() {", in: code(slots))
        XCTAssertTrue(clear.contains(
            "guard !UserDefaults.standard.bool(forKey: SuppressibleConfirmations.clearTraffic) else {\n"
            + "            _ = SessionState.shared.clearAllSessions()\n"
            + "            return\n"
            + "        }\n"), String(clear))
        XCTAssertTrue(clear.contains("guard SuppressibleConfirmationAlert.confirm("), String(clear))
        XCTAssertTrue(clear.contains("title: \"Clear Captured Traffic\","))
        XCTAssertTrue(clear.contains("message: SuppressibleConfirmations.clearTrafficMessage(count: count, locale: .current),"))
        XCTAssertTrue(clear.contains("actionTitle: \"Clear\","))
        XCTAssertTrue(clear.contains(
            "suppressionKey: SuppressibleConfirmations.clearTraffic\n"
            + "        ) else { return }\n"
            + "        _ = SessionState.shared.clearAllSessions()\n"), String(clear))
        XCTAssertFalse(clear.contains("NSAlert"), "an alert of its own")
        assertAsksAtOnce(clear, "clearTraffic")
    }

    /// Deleting an override: the context menu skips the prompt by the rule
    /// key, and otherwise asks there and then; the prompt is the helper's,
    /// with that key and the words it always had.
    func testDeletingAnOverrideAsksThroughTheHelper() throws {
        let app = try code(appView)
        XCTAssertTrue(app.contains("@AppStorage(SuppressibleConfirmations.ruleDelete) private var skipDeleteConfirmation = false"))
        XCTAssertTrue(app.contains(
            "Button(\"Delete override...\") {\n"
            + "                        if skipDeleteConfirmation {\n"
            + "                            deleteRule(rule: rule)\n"
            + "                        } else {\n"
            + "                            showDeleteConfirmation(for: rule)\n"
            + "                        }\n"
            + "                    }\n"), "a turned-off prompt deletes without asking; otherwise the menu asks at once")
        let ask = try body(of: "func showDeleteConfirmation(for rule: RuleCodable) {", in: app)
        XCTAssertTrue(ask.contains("guard SuppressibleConfirmationAlert.confirm("), String(ask))
        XCTAssertTrue(ask.contains("title: \"Delete Override\","))
        XCTAssertTrue(ask.contains(#"message: "Are you sure you want to delete this override?\n\nThis action cannot be undone.","#),
                      String(ask))
        XCTAssertTrue(ask.contains("actionTitle: \"Delete\","))
        XCTAssertTrue(ask.contains(
            "suppressionKey: SuppressibleConfirmations.ruleDelete\n"
            + "        ) else { return }\n"
            + "        deleteRule(rule: rule)\n"), String(ask))
        XCTAssertFalse(ask.contains("NSAlert"), "an alert of its own")
        assertAsksAtOnce(ask, "the override's showDeleteConfirmation")
    }

    /// Deleting a host filter: the same shape, with the host key — and the
    /// sentence that is the point of the prompt: the host's rules go with it.
    func testDeletingAHostFilterAsksThroughTheHelper() throws {
        let app = try code(appView)
        XCTAssertTrue(app.contains("@AppStorage(SuppressibleConfirmations.hostDelete) private var skipHostDeleteConfirmation = false"))
        XCTAssertTrue(app.contains(
            "Button(\"Delete host...\") {\n"
            + "                    if skipHostDeleteConfirmation {\n"
            + "                        AppState.shared.deleteHost(hostModel)\n"
            + "                    } else {\n"
            + "                        showDeleteConfirmation(for: hostModel)\n"
            + "                    }\n"
            + "                }\n"), "a turned-off prompt deletes without asking; otherwise the menu asks at once")
        let ask = try body(of: "private func showDeleteConfirmation(for host: HostCodable) {", in: app)
        XCTAssertTrue(ask.contains("guard SuppressibleConfirmationAlert.confirm("), String(ask))
        XCTAssertTrue(ask.contains("title: \"Delete Host Filter\","))
        XCTAssertTrue(ask.contains(
            "message: \"\"\"\n"
            + #"            “\(host.host)” and any override rules scoped to it are deleted. \"# + "\n"
            + "            A rule belongs to a host filter and cannot outlive it.\n"
            + "\n"
            + "            This cannot be undone.\n"
            + "            \"\"\",\n"), String(ask))
        XCTAssertTrue(ask.contains("actionTitle: \"Delete\","))
        XCTAssertTrue(ask.contains(
            "suppressionKey: SuppressibleConfirmations.hostDelete\n"
            + "        ) else { return }\n"
            + "        AppState.shared.deleteHost(host)\n"), String(ask))
        XCTAssertFalse(ask.contains("NSAlert"), "an alert of its own")
        assertAsksAtOnce(ask, "the host's showDeleteConfirmation")
    }

    /// Each prompt is asked through the helper exactly once, by its own key —
    /// and a prompt added to `SuppressibleConfirmations.all` without an alert
    /// fails here.
    func testEveryPromptIsAskedOnceByItsOwnKey() throws {
        var calls = 0
        var keys: [String] = []
        for (_, text) in try appFiles() {
            calls += text.components(separatedBy: "SuppressibleConfirmationAlert.confirm(").count - 1
            keys += try captures(#"suppressionKey:\s*SuppressibleConfirmations\.(\w+)"#, in: text)
        }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(keys.sorted(), ["clearTraffic", "hostDelete", "ruleDelete"])
        XCTAssertEqual(keys.count, SuppressibleConfirmations.all.count)
    }

    /// Every way into the three alerts calls them straight from its action —
    /// the toolbar's trash and its overflow row here, the two context menus in
    /// the tests above — and there is no other way in. A call put off with
    /// `DispatchQueue.main.async` (or a Task) at any of them would start the
    /// modal inside a main-queue job, holding back the traffic table's flush
    /// and the MCP bridge's `main.sync` reads until it is answered.
    func testEveryAlertIsAskedStraightFromItsAction() throws {
        XCTAssertTrue(try code(slots).contains("Button(action: TrafficCommands.clearTraffic) {"), "the toolbar's trash")
        XCTAssertTrue(try code(controller).contains("@objc private func menuClearTraffic() { TrafficCommands.clearTraffic() }"),
                      "the trash's overflow row")
        var clears = 0
        var deletes = 0
        for (_, text) in try appFiles() {
            clears += text.components(separatedBy: "TrafficCommands.clearTraffic").count - 1
            deletes += text.components(separatedBy: "showDeleteConfirmation(for: ").count - 1
        }
        XCTAssertEqual(clears, 2, "Clear Captured Traffic asked from somewhere no test pins")
        XCTAssertEqual(deletes, 2, "a delete confirmation asked from somewhere no test pins")
    }

    // MARK: - Settings and the overflow row

    /// Settings ▸ General ▸ Confirmations quotes the checkbox from the same
    /// constant the alerts use.
    func testSettingsQuotesTheCheckboxTitle() throws {
        let text = try code(settings)
        XCTAssertTrue(text.contains(#"Each of those dialogs can be silenced with “\(SuppressibleConfirmations.checkboxTitle)”; this brings them all back."#))
    }

    /// Settings stays on screen while an alert runs, so Reset All Warnings has
    /// to enable as soon as a prompt is turned off — not the next time the tab
    /// is shown, which is all `onAppear` covers.
    func testSettingsNoticesAPromptTurnedOffWhileItIsOpen() throws {
        let text = try code(settings)
        XCTAssertTrue(text.contains(
            ".onReceive(NotificationCenter.default\n"
            + "            .publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)\n"
            + "            .receive(on: DispatchQueue.main)) { _ in\n"
            + "            let suppressed = SuppressibleConfirmations.anySuppressed(in: .standard)\n"
            + "            if suppressed != hasSuppressedPrompts { hasSuppressedPrompts = suppressed }\n"
            + "        }\n"), "Reset All Warnings stays disabled until the tab is shown again")
    }

    /// The trash's overflow row is enabled exactly when the trash is — when
    /// there is traffic to clear — so it never asks to discard "0 captured
    /// requests" and offers to stop asking.
    func testTheOverflowRowIsEnabledLikeTheTrash() throws {
        let tools = try code(slots)
        let trash = try XCTUnwrap(tools.range(of: "Button(action: TrafficCommands.clearTraffic) {"))
        let next = tools.range(of: "Button(", range: trash.upperBound..<tools.endIndex)?.lowerBound ?? tools.endIndex
        XCTAssertTrue(tools[trash.upperBound..<next].contains(".disabled(sessionState.sessions.isEmpty)"), "the trash's own rule")
        let toolbar = try code(controller)
        XCTAssertTrue(toolbar.contains("final class ReqResToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate, NSMenuItemValidation {"))
        XCTAssertTrue(toolbar.contains("sub.addItem(commandRow(\"Clear Captured Traffic\", #selector(menuClearTraffic)))"))
        let validate = try body(of: "func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {", in: toolbar)
        XCTAssertTrue(validate.contains(
            "if menuItem.action == #selector(menuClearTraffic) {\n"
            + "            return !SessionState.shared.sessions.isEmpty\n"
            + "        }\n"
            + "        return true\n"), String(validate))
    }
}
