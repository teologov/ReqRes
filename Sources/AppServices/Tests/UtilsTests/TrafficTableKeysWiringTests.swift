//
//  TrafficTableKeysWiringTests.swift
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
//  The app-side wiring of F14, read from the source: Sources/UI has no test
//  target, and the monitor these guard shipped in every 1.0.x taking Esc and
//  Delete from every window of the app. The decisions themselves — the
//  command, and the order in which where the keyboard is gets worked out —
//  are tested in TrafficTableKeysTests; these check the app still asks them,
//  with the event's own window and one AppKit question per fact. The arrows
//  (2026-10-01) are guarded the same way: the moves, the scrolling and the
//  detail pane's timing are decided in Utils (TrafficTableNavigation,
//  TrafficTableScroll, TrafficDetailDebounce), and these check the table asks.
//

import XCTest

final class TrafficTableKeysWiringTests: XCTestCase {
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
        let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    override func ",
                    "\n    @objc ", "\n    @MainActor", "\n    var body: some View {", "\n}\n"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }

    private func occurrences(of needle: String, in text: Substring) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private let sessionView = "UI/Views/Session/SessionView.swift"
    private let keyEvents = "UI/Views/Session/TrafficTableKeyEvents.swift"
    private let pausedPanel = "UI/Views/Breakpoints/BreakpointDecisionPanel.swift"

    // MARK: - The monitor

    /// Every key the monitor keeps is one `TrafficTableKeys` decided is the
    /// table's; anything else is returned untouched. It never reads a key code
    /// or the first responder itself, and never moves the keyboard: the two
    /// `makeFirstResponder(nil)` branches it had were what stopped the search
    /// field's own Escape from running.
    func testTheMonitorOnlyActsOnADecisionAndReturnsEverythingElse() throws {
        let monitor = try body(of: "func addKeyMonitor()", in: code(sessionView))
        XCTAssertTrue(monitor.contains("NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp])"))
        // A key's release is heard FIRST and always returned: only an arrow's
        // is acted on (the detail pane learns the key is up), and no release
        // ever reaches the press decisions — a Delete let go of must not
        // delete again.
        let release = try XCTUnwrap(monitor.range(of: "guard event.type == .keyDown else {\n                if TrafficTableKeyEvents.releasesArrow(event) { self.arrowReleased() }\n                return event\n            }"))
        let decision = try XCTUnwrap(monitor.range(of: "TrafficTableKeyEvents.command(for: event"))
        XCTAssertLessThan(release.lowerBound, decision.lowerBound)
        XCTAssertEqual(occurrences(of: "return event", in: monitor), 2)
        XCTAssertTrue(monitor.contains("TrafficTableKeyEvents.command(for: event, pane: self.paneAnchor.view"))
        XCTAssertFalse(monitor.contains("makeFirstResponder"), "the monitor moves the keyboard again")
        XCTAssertFalse(monitor.contains("keyCode"), "the monitor reads key codes itself again")
        XCTAssertFalse(monitor.contains("firstResponder"), "the monitor asks where the keyboard is itself again")
        XCTAssertFalse(monitor.contains("NSApp.keyWindow"))
        // Kept exactly four times — once per command, the table's key with
        // nothing selected included — and passed on otherwise.
        XCTAssertEqual(occurrences(of: "return nil", in: monitor), 4)
        XCTAssertEqual(occurrences(of: "case .clearSelection:", in: monitor), 1)
        XCTAssertEqual(occurrences(of: "case .deleteSelection:", in: monitor), 1)
        XCTAssertTrue(monitor.contains("case .moveSelection(let direction, let extending):\n                self.moveSelection(direction, extending: extending)\n                return nil"),
                      "↑ and ↓ move through moveSelection, with ⇧ as the decision said, and are kept")
        XCTAssertTrue(monitor.contains("case .nothingToDo:\n                return nil"),
                      "the table's key with nothing selected must be kept and do nothing")
        XCTAssertTrue(monitor.contains("case nil:\n                return event"))
    }

    /// The monitor finds its window and pane through the anchor in the table's
    /// own view tree — so two main windows each act for their own.
    func testTheTableCarriesItsAnchor() throws {
        let text = try code(sessionView)
        XCTAssertTrue(text.contains(".background(TrafficPaneAnchor(box: paneAnchor))"))
        XCTAssertTrue(text.contains("@State private var paneAnchor = TrafficPaneAnchor.Box()"))
    }

    /// No other event monitor in the app: one that is not scoped the way this
    /// one is would take keys from every window again. A tripwire — a new
    /// monitor that sees keys decides through `TrafficTableKeys`-style inputs
    /// (the event's own window first), and is then added here.
    func testNoOtherEventMonitor() throws {
        let ui = Self.sourcesRoot.appendingPathComponent("UI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        var monitors: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.components(separatedBy: "\n").map { line in
                line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
            }.joined(separator: "\n")
            monitors += Array(repeating: file.lastPathComponent,
                              count: code.components(separatedBy: "MonitorForEvents(").count - 1)
        }
        XCTAssertEqual(monitors, ["SessionView.swift"])
    }

    // MARK: - The mapping

    /// The inputs come from the EVENT's window, compared with the table's —
    /// never from `NSApp.keyWindow`, which is what let the old monitor act on
    /// keys pressed in Saved Sessions, sheets, alerts and panels.
    func testTheMappingAsksTheEventsOwnWindow() throws {
        let mapping = try body(of: "static func command(for event: NSEvent, pane: NSView?, hasSelection: Bool)",
                               in: code(keyEvents))
        XCTAssertTrue(mapping.contains("guard let pane, let window = pane.window else { return nil }"))
        XCTAssertTrue(mapping.contains("isTrafficWindow: event.window === window"))
        XCTAssertTrue(mapping.contains("hasAttachedSheet: window.attachedSheet != nil"))
        XCTAssertTrue(mapping.contains("modalRunning: NSApp.modalWindow != nil"))
        XCTAssertTrue(mapping.contains("responder(window.firstResponder, in: window, trafficPane: trafficPane(containing: pane))"))
        XCTAssertFalse(try code(keyEvents).contains("NSApp.keyWindow"))
    }

    /// Every flag AppKit sets maps to its own `TrafficTableKeys.Modifiers`
    /// flag — the arrows' numeric-pad and function flags included, which
    /// must reach the decision as themselves (and never block) — and nothing
    /// else is mapped.
    func testTheModifiersMapOneToOne() throws {
        let mapping = try body(of: "static func modifiers(_ flags: NSEvent.ModifierFlags) -> TrafficTableKeys.Modifiers", in: code(keyEvents))
        for flag in ["command", "option", "control", "shift", "function", "capsLock", "numericPad"] {
            XCTAssertTrue(mapping.contains("if flags.contains(.\(flag)) { modifiers.insert(.\(flag)) }"), flag)
        }
        XCTAssertEqual(occurrences(of: "modifiers.insert(", in: mapping), 7)
    }

    /// Where the keyboard is: the mapping only asks AppKit, one question per
    /// fact, and hands every answer to `TrafficTableKeys.responder`, whose
    /// ORDER (text first; a web view and a list before the traffic pane) is
    /// tested in TrafficTableKeysResponderTests. Placing anything itself would
    /// put the order back where no test sees it; a fact asked wrongly — a web
    /// view or a list no longer recognised, read-only text taken for text
    /// being edited — is caught here.
    func testTheMappingAsksAppKitOneQuestionPerFact() throws {
        let responder = try body(of: "static func responder(_ responder: NSResponder?", in: code(keyEvents))
        XCTAssertTrue(responder.contains("return TrafficTableKeys.responder("))
        // The one place it answers itself: no first responder at all.
        XCTAssertEqual(occurrences(of: "return .", in: responder), 1)
        XCTAssertTrue(responder.contains("guard let responder else { return .other }"))
        for fact in [
            "isWindow: responder === window || responder === window.contentView,",
            "isText: responder is NSText || responder is NSTextField,",
            "isEditable: (responder as? NSText)?.isEditable ?? (responder as? NSTextField)?.isEditable ?? false,",
            "isView: view != nil,",
            "isInWebView: view.map { sequence(first: $0, next: { $0.superview }).contains(where: { $0 is WKWebView }) } ?? false,",
            "isList: responder is NSTableView || responder is NSCollectionView,",
            "isInTrafficPane: isInTrafficPane,",
            "isInWindow: view?.window === window",
        ] {
            XCTAssertTrue(responder.contains(fact), "\(fact) — changed? Check the fact against AppKit before updating this test")
        }
        XCTAssertTrue(responder.contains("if let view, let trafficPane { isInTrafficPane = view.isDescendant(of: trafficPane) }"))
    }

    /// The traffic pane is the table's ancestor that is an arranged subview of
    /// the main window's split view (sidebar | overrides | traffic). Found any
    /// other way — the whole window, say — the sidebar's and the overrides
    /// pane's views would count as the traffic pane, and Delete there would
    /// delete traffic rows again.
    func testTheTrafficPaneIsTheSplitViewsChildThatHoldsTheTable() throws {
        let pane = try body(of: "static func trafficPane(containing view: NSView) -> NSView?", in: code(keyEvents))
        XCTAssertTrue(pane.contains("var current: NSView? = view"))
        XCTAssertTrue(pane.contains("if candidate.superview is NSSplitView { return candidate }"))
        XCTAssertTrue(pane.contains("current = candidate.superview"))
        // Only a window with no split view at all is all traffic pane.
        XCTAssertEqual(occurrences(of: "return ", in: pane), 2)
        XCTAssertTrue(pane.contains("return view.window?.contentView"))
    }

    /// A click on a row hands the keyboard to the window, which is the state
    /// the table's keys act in (`TrafficTableKeys.Responder.window`).
    func testARowClickHandsTheKeyboardToTheWindow() throws {
        let text = try code(sessionView)
        let tap = try XCTUnwrap(text.range(of: ".onTapGesture {"))
        let after = text[tap.upperBound...]
        let resign = try XCTUnwrap(after.range(of: "NSApp.keyWindow?.makeFirstResponder(nil)"))
        let select = try XCTUnwrap(after.range(of: "handleRowSelection(session.id)"))
        XCTAssertLessThan(resign.lowerBound, select.lowerBound)
    }

    // MARK: - The arrows

    /// ↑ and ↓ move by `TrafficTableNavigation`, over the rows the table SHOWS
    /// (not every captured row), by row ID. The detail pane waits for the
    /// debounce — the move never writes the pane's row itself — and the move
    /// asks the list to scroll to the row it reached. A key held at an end of
    /// the table, where nothing changes, writes nothing while the row is in
    /// view — every repeat would re-render the table — but the debounce
    /// still hears it.
    func testTheArrowsMoveThroughTheNavigationOverTheShownRows() throws {
        let move = try body(of: "func moveSelection(_ direction: TrafficTableNavigation.Direction, extending: Bool)", in: code(sessionView))
        XCTAssertTrue(move.contains("TrafficTableNavigation.move("))
        XCTAssertTrue(move.contains("rows: sessionState.filteredSessions.map(\\.id),"))
        XCTAssertTrue(move.contains("selection: selectedSessionIds,"))
        XCTAssertTrue(move.contains("cursor: selectionCursor"))
        let waits = try XCTUnwrap(move.range(of: "detailTiming.debounce.keyMoved(to: outcome.active)"))
        let selects = try XCTUnwrap(move.range(of: "selectedSessionIds = outcome.selection"))
        XCTAssertLessThan(waits.lowerBound, selects.lowerBound,
                          "the key move must be waiting before the selection changes, or onChange shows the row at once")
        let skips = try XCTUnwrap(move.range(of: "if outcome.selection == selectedSessionIds, outcome.cursor == selectionCursor,\n           tableGeometry.showsWhole(outcome.active) {\n            return\n        }"))
        let cursor = try XCTUnwrap(move.range(of: "selectionCursor = outcome.cursor"))
        XCTAssertLessThan(waits.lowerBound, skips.lowerBound, "the debounce must hear a key held at the end of the table")
        XCTAssertLessThan(skips.lowerBound, cursor.lowerBound)
        XCTAssertLessThan(cursor.lowerBound, selects.lowerBound, "the selection's onChange reads the cursor")
        XCTAssertEqual(occurrences(of: "return", in: move), 2, "the guard's, and the no-op's")
        XCTAssertTrue(move.contains("settleDetail(after: wake)"))
        XCTAssertTrue(move.contains("keyboardReveal = TrafficRowReveal(row: outcome.active, direction: direction"))
        XCTAssertFalse(move.contains("refreshDetail()"), "the pane takes the row at the debounce's wake-up, not at the key")
        XCTAssertFalse(move.contains("selectedSession ="))
        XCTAssertFalse(move.contains("sessionState.sessions"), "the rows the table shows, not every captured one")
    }

    /// A click goes through the same rules as ⇧↑/⇧↓ — one anchor, by row ID —
    /// and shows its row at once: never debounced.
    func testClicksShareTheNavigationAndShowTheirRowAtOnce() throws {
        let text = try code(sessionView)
        let click = try body(of: "func handleRowSelection(sessionId: UUID)", in: text)
        XCTAssertTrue(click.contains("TrafficTableNavigation.click("))
        XCTAssertTrue(click.contains("TrafficTableNavigation.Click(command: flags.contains(.command), shift: flags.contains(.shift))"))
        XCTAssertTrue(click.contains("rows: sessionState.filteredSessions.map(\\.id),"))
        XCTAssertTrue(click.contains("cursor: selectionCursor"))
        XCTAssertTrue(click.contains("detailTiming.debounce.show("))
        XCTAssertTrue(click.contains("refreshDetail()"))
        XCTAssertTrue(click.contains("keyboardReveal = nil"))
        // The index anchor is gone everywhere: it named another row once rows
        // arrived above it, and ran past a list filtered shorter.
        XCTAssertFalse(text.contains("lastSelectedIndex"))
        XCTAssertFalse(text.contains("filteredSessions[startIndex"))
    }

    /// The detail pane's row has ONE writer, which reads the debounce: so a
    /// row the arrows only passed over is never shown — and never spends an
    /// inspection, which is spent where an HTTPS row's detail is shown, once
    /// per row.
    func testTheDetailPaneShowsOnlyWhatTheDebounceSays() throws {
        let text = try code(sessionView)
        XCTAssertEqual(occurrences(of: "selectedSession = ", in: Substring(text)), 1)
        let refresh = try body(of: "func refreshDetail()", in: text)
        XCTAssertTrue(refresh.contains("let shown = detailTiming.debounce.shown"))
        XCTAssertTrue(refresh.contains("selectedSession = shown.flatMap"))
        // Every other change of the selection — Esc, Delete, the ✕ — goes
        // through the debounce, which shows it at once unless an arrow key
        // made it.
        XCTAssertTrue(text.contains("if detailTiming.debounce.selectionChanged(to: detailRow(for: selection, cursor: selectionCursor)) {\n                        refreshDetail()"))
        // A row updated in place refreshes the row the pane SHOWS, not the
        // selection's — which, mid-debounce, the pane does not show yet.
        XCTAssertTrue(text.contains("guard let shown = detailTiming.debounce.shown, ids.contains(shown) else { return }"))
        // The wake-up shows the row only when the debounce says so.
        let settle = try body(of: "private func settleDetail(after wake: TrafficDetailDebounce<UUID>.Wake)", in: text)
        XCTAssertTrue(settle.contains("switch self.detailTiming.debounce.settle(wake.serial)"))
        XCTAssertEqual(occurrences(of: "refreshDetail()", in: settle), 1)
        // The inspection: spent once, where the HTTPS detail is shown.
        XCTAssertEqual(occurrences(of: "incrementHttpsSessionCounter()", in: Substring(text)), 1)
        XCTAssertTrue(text.contains("if inspections.recordView(rowID: session.id, access: .inspect(counted: true)) {\n                                appState.incrementHttpsSessionCounter()"))
        // The pane opens with a row to show, not with the selection: an
        // arrow key's first row arrives after the debounce.
        XCTAssertTrue(text.contains(".hide(SideHolder(selectedSession == nil ? .secondary : nil))"))
    }

    /// A held arrow shows only the row it stops on: the table tells the
    /// debounce when an arrow key is let go of — any arrow's release,
    /// wherever it went — and the wait for a lost release follows this Mac's
    /// key repeat settings, read when a wake-up needs them.
    func testAnArrowsReleaseReachesTheDebounce() throws {
        let text = try code(sessionView)
        let released = try body(of: "func arrowReleased()", in: text)
        XCTAssertTrue(released.contains("if let wake = detailTiming.debounce.keyReleased() {\n            settleDetail(after: wake)"))
        let mapping = try body(of: "static func releasesArrow(_ event: NSEvent) -> Bool", in: code(keyEvents))
        XCTAssertTrue(mapping.contains("event.type == .keyUp && TrafficTableKeys.isArrow(event.keyCode)"))
        XCTAssertTrue(text.contains("var debounce = TrafficDetailDebounce<UUID>(holdLimit: {\n        TrafficDetailDebounce<UUID>.holdLimit(repeatDelay: NSEvent.keyRepeatDelay,\n                                              repeatInterval: NSEvent.keyRepeatInterval)\n    })"))
    }

    /// The list scrolls to the row the keys reached by `TrafficTableScroll`'s
    /// anchor — never by SwiftUI's own minimal scroll, which leaves a row
    /// under the pinned header — with the row's own UUID (the ForEach's id;
    /// an id of another type matches nothing), from where the row, the header
    /// and the visible area really are.
    func testTheListScrollsByThePlanFromMeasuredGeometry() throws {
        let text = try code(sessionView)
        let reveal = try body(of: "private func revealRow(_ reveal: TrafficRowReveal, geometry: TrafficTableGeometry, proxy: ScrollViewProxy)", in: text)
        XCTAssertTrue(reveal.contains("let frame = geometry.rows[reveal.row]"))
        XCTAssertTrue(reveal.contains("TrafficTableScroll.anchor("))
        XCTAssertTrue(reveal.contains("headerHeight: Double(geometry.headerBottom),"))
        XCTAssertTrue(reveal.contains("viewportHeight: Double(geometry.viewport),"))
        XCTAssertTrue(reveal.contains("proxy.scrollTo(reveal.row, anchor: UnitPoint(x: 0, y: y))"))
        XCTAssertFalse(text.contains("anchor: nil"))
        // The geometry, in the visible area's coordinates.
        XCTAssertTrue(text.contains(".coordinateSpace(.named(TrafficTableGeometry.space))"))
        XCTAssertTrue(text.contains(".onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TrafficTableGeometry.space)) } action: { frame in\n                                geometry.rows[session.id] = frame"))
        XCTAssertTrue(text.contains(".onDisappear { geometry.rows[session.id] = nil }"),
                      "a row the lazy stack lets go of must not leave a stale frame behind")
        XCTAssertTrue(text.contains(".onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TrafficTableGeometry.space)).maxY } action: {\n                            geometry.headerBottom = $0"))
        // Scrolled on each move.
        XCTAssertTrue(text.contains(".onChange(of: reveal) { _, reveal in\n                guard let reveal else { return }\n                revealRow(reveal, geometry: geometry, proxy: proxy)"))
        // When the visible area changes height under the row (the detail
        // pane opening), kept in view only if it WAS in view: planned like a
        // key move, a resize pulled the table back to a row the person had
        // scrolled away from.
        XCTAssertTrue(text.contains("let before = geometry.viewport\n                geometry.viewport = height\n                if let reveal { keepInView(reveal, viewportBefore: before, proxy: proxy) }"))
        let keep = try body(of: "private func keepInView(_ reveal: TrafficRowReveal, viewportBefore: CGFloat, proxy: ScrollViewProxy)", in: text)
        XCTAssertTrue(keep.contains("TrafficTableScroll.anchorAfterResize("))
        XCTAssertTrue(keep.contains("viewportBefore: Double(viewportBefore),"))
        XCTAssertTrue(keep.contains("viewportAfter: Double(geometry.viewport)"))
        XCTAssertTrue(keep.contains("proxy.scrollTo(reveal.row, anchor: UnitPoint(x: 0, y: y))"))
        XCTAssertFalse(keep.contains("revealRow("))
        XCTAssertEqual(occurrences(of: "revealRow(reveal", in: Substring(text)), 1, "only a key move plans like a key move")
        // The geometry is ONE reference, SessionView's — the list writes it,
        // the arrow keys read it too — and nothing renders from it.
        XCTAssertTrue(text.contains("@State private var tableGeometry = TrafficTableGeometry()"))
        XCTAssertTrue(text.contains("geometry: tableGeometry,"))
        XCTAssertTrue(text.contains("    let geometry: TrafficTableGeometry\n"))
        XCTAssertFalse(text.contains("@State private var geometry = TrafficTableGeometry()"))
        XCTAssertTrue(text.contains("final class TrafficTableGeometry {"))
        let shows = try body(of: "func showsWhole(_ row: UUID) -> Bool", in: text)
        XCTAssertTrue(shows.contains("guard let frame = rows[row] else { return false }"))
        XCTAssertTrue(shows.contains("TrafficTableScroll.isInView(rowTop: Double(frame.minY), rowBottom: Double(frame.maxY),\n                                           headerHeight: Double(headerBottom), viewportHeight: Double(viewport))"),
                      "in view means below the pinned header, and above the visible area's bottom edge")
    }

    // MARK: - The context menu

    /// Delete acts on the rows Save acts on — one rule, `TrafficRowTargets` —
    /// and its title counts them, with no ellipsis for a dialog that does not
    /// exist.
    func testTheMenusDeleteTargetsTheRowsSaveDoes() throws {
        let text = try code(sessionView)
        XCTAssertTrue(try body(of: "func sessionsToSave(startingFrom session: SessionCodable)", in: text)
            .contains("sessionsTargeted(from: session)"))
        XCTAssertTrue(try body(of: "func deleteLabel(for session: SessionCodable)", in: text)
            .contains("TrafficRowTargets.deleteTitle(count: sessionsTargeted(from: session).count)"))
        XCTAssertTrue(try body(of: "func deleteSessions(startingFrom session: SessionCodable)", in: text)
            .contains("sessionsTargeted(from: session)"))
        XCTAssertTrue(try body(of: "func sessionsTargeted(from session: SessionCodable)", in: text)
            .contains("TrafficRowTargets.rows(clicked: session, selection: selectedSessionIds"))
        XCTAssertTrue(text.contains("Label(deleteLabel(session), systemImage: \"trash\")"))
        XCTAssertFalse(text.contains("Delete session\\("), "the old label counted the selection, not the rows it deletes")
        XCTAssertFalse(text.contains("sessions...") || text.contains("session..."))
        // The list itself: its menu deletes what the item names, never "the
        // selection" whatever was clicked.
        let start = try XCTUnwrap(text.range(of: "struct SessionListView: View {"))
        let end = try XCTUnwrap(text.range(of: "struct SessionTableHeader: View {"))
        let list = text[start.upperBound..<end.lowerBound]
        XCTAssertTrue(list.contains("deleteSessions(session)"))
        XCTAssertFalse(list.contains("deleteSelectedSessions"))
    }

    // MARK: - The panels the monitor used to hide

    /// Paused Requests: the first Escape while a field is being edited only
    /// ends the editing; Escape with nothing being edited closes the panel,
    /// which resumes everything held.
    func testThePausedRequestsPanelEndsEditingBeforeItCloses() throws {
        let cancel = try body(of: "override func cancelOperation(_ sender: Any?)", in: code(pausedPanel))
        let editing = try XCTUnwrap(cancel.range(of: "if Self.isEditingText(firstResponder) {"))
        let endEditing = try XCTUnwrap(cancel.range(of: "makeFirstResponder(nil)\n            return\n        }"))
        let close = try XCTUnwrap(cancel.range(of: "performClose(nil)"))
        XCTAssertLessThan(editing.lowerBound, endEditing.lowerBound)
        XCTAssertLessThan(endEditing.lowerBound, close.lowerBound)
        XCTAssertEqual(occurrences(of: "performClose", in: cancel), 1)
    }

    /// …and the Escape that closes it has to reach it. Only a text view turns
    /// Escape into cancelOperation(_:); pressed while the panel itself holds
    /// the keyboard — right after the first Escape ended an edit — it arrives
    /// as a plain keyDown, and until the panel answered it there, it only
    /// beeped (measured with real events). A held Escape's repeats never
    /// close, and with ⌘⌥⌃ it is someone else's key.
    func testThePausedRequestsPanelAnswersAnEscapeNoTextTook() throws {
        let panel = try code(pausedPanel)
        let keyDown = try body(of: "override func keyDown(with event: NSEvent)", in: panel)
        let escape = try XCTUnwrap(keyDown.range(of: "guard event.keyCode == Self.escapeKeyCode,"))
        let shortcut = try XCTUnwrap(keyDown.range(of: "event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else {"))
        let passOn = try XCTUnwrap(keyDown.range(of: "super.keyDown(with: event)\n            return\n        }"))
        let repeats = try XCTUnwrap(keyDown.range(of: "guard !event.isARepeat else { return }"))
        let cancel = try XCTUnwrap(keyDown.range(of: "cancelOperation(nil)"))
        XCTAssertLessThan(escape.lowerBound, shortcut.lowerBound)
        XCTAssertLessThan(shortcut.lowerBound, passOn.lowerBound)
        XCTAssertLessThan(passOn.lowerBound, repeats.lowerBound)
        XCTAssertLessThan(repeats.lowerBound, cancel.lowerBound)
        XCTAssertEqual(occurrences(of: "cancelOperation(nil)", in: keyDown), 1)
        XCTAssertFalse(keyDown.contains("performClose"), "closing goes through cancelOperation(_:), which ends an edit first")
        XCTAssertTrue(panel.contains("static let escapeKeyCode: UInt16 = 0x35"))
    }

    /// The approval panel can never become key, so no key reaches it: it must
    /// not claim that Escape denies, nor declare a shortcut that never fires.
    func testTheApprovalPanelClaimsNoKey() throws {
        let window = try code("UI/Views/MCP/MCPApprovalWindow.swift")
        XCTAssertTrue(window.contains("override var canBecomeKey: Bool { false }"),
                      "the panel became key: re-read the approval panel's keyboard rules before changing this test")
        let sheet = try code("UI/Views/MCP/MCPApprovalSheet.swift")
        XCTAssertFalse(sheet.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertFalse(sheet.contains(".keyboardShortcut(.defaultAction)"))
        let comments = try String(contentsOf: Self.sourcesRoot.appendingPathComponent("UI/Views/MCP/MCPApprovalSheet.swift"), encoding: .utf8)
            + String(contentsOf: Self.sourcesRoot.appendingPathComponent("UI/Views/MCP/MCPApprovalWindow.swift"), encoding: .utf8)
        XCTAssertFalse(comments.contains("Escape denies"))
        XCTAssertFalse(comments.contains("Deny (Escape)"))
    }
}
