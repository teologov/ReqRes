//
//  BreakpointBodyWiringTests.swift
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
//  The Paused Requests panel's side of F19, read from the source: Sources/UI
//  has no test target, and what a person meets there is a handful of lines —
//  where the Body tab's title comes from, what the body view lets them edit,
//  what the draft sends, which header rows it locks, what the DEBUG seed looks
//  like. The decisions are tested in HeldRequestBodyTests and
//  HeldRequestFramingTests; these check the panel still uses them.
//

import XCTest

final class BreakpointBodyWiringTests: XCTestCase {
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

    /// From `signature` to the next member declared at the same indentation
    /// (or the end of the type), whichever comes first.
    private func body(of signature: String, in text: String, file: StaticString = #filePath, line: UInt = #line) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found — renamed? Update this test.", file: file, line: line)
        let rest = text[start.upperBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    private var ", "\n    mutating func ", "\n    var ",
                    "\n    static func ", "\n    public static func ", "\n    private static ", "\n    #if ", "\n}\n"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }

    private static let panel = "UI/Views/Breakpoints/BreakpointPanel.swift"
    private static let draft = "UI/Views/Breakpoints/BreakpointRequestDraft.swift"
    private static let editors = "UI/Views/Breakpoints/BreakpointRequestEditors.swift"
    private static let service = "UI/Services/BreakpointService.swift"
    private static let adapter = "UI/Services/MCPBreakpointAdapter.swift"

    /// A screenshot showed "Body (none)" beside `Content-Length: 76`.
    /// The tab's title is the helper's, which never says "(none)".
    func testTheBodyTabTitleComesFromTheHelper() throws {
        let panel = try code(Self.panel)
        let title = try body(of: "private func bodyTabTitle(_ draft: BreakpointRequestDraft) -> String {", in: panel)
        XCTAssertTrue(title.contains("draft.bodyEdit.tabTitle"), String(title))
        for file in [Self.panel, Self.draft, Self.editors, Self.service] {
            XCTAssertFalse(try code(file).contains("Body (none)"), "\(file) prints “Body (none)” somewhere")
        }
    }

    /// The draft counted 0 == 0 as "the whole body, and it is empty" and let
    /// it be edited. Now only a replacement the user opened and typed into
    /// becomes a payload.
    func testTheDraftSendsABodyOnlyFromAReplacement() throws {
        let draft = try code(Self.draft)
        let payload = try body(of: "func bodyPayload() -> String? {", in: draft)
        XCTAssertEqual(payload.trimmingCharacters(in: .whitespacesAndNewlines), "bodyEdit.payload\n    }")
        XCTAssertFalse(draft.contains("bodyIsComplete"), "the 0 == 0 completeness test is gone")
        XCTAssertFalse(draft.contains("bodyEditable"))
        XCTAssertTrue(draft.contains("preview: request.bodyPreview,"))
        XCTAssertTrue(draft.contains("byteCount: request.bodyByteCount,"))
        XCTAssertTrue(draft.contains("previewIsPrefix: BreakpointService.isBodyTruncated(request),"))
        let revert = try body(of: "mutating func revert() {", in: draft)
        XCTAssertTrue(revert.contains("bodyEdit.keepOriginal()"), String(revert))
    }

    /// The Body tab's size comes from the headers the Headers tab shows, read
    /// ONCE by `HeldRequestHeaders` (MCPKit; the core's payload is read end to
    /// end in HeldRequestHeadersTests). The review's mutation — the draft
    /// handing the body no headers — printed "Body (not shown)" beside the
    /// request's own `Content-Length: 76` with every test green.
    func testTheBodyTabReadsTheHeadersTheHeadersTabShows() throws {
        let draft = try code(Self.draft)
        let initializer = try body(of: "init(request: PausedRequestCodable) {", in: draft)
        for line in [
            "let decoded = HeldRequestHeaders.decode(request.headers)",
            "self.headerFormat = decoded.format",
            "let entries = decoded.entries.map { HeaderEntry(key: $0.name, value: $0.value, isEnabled: $0.isEnabled) }",
            "self.originalHeaders = entries",
            "self.headers = entries",
            "decodedHeaders: decoded,\n",
        ] {
            XCTAssertTrue(initializer.contains(line), "\(line) — \(initializer)")
        }
        XCTAssertFalse(draft.contains("JSONSerialization"), "a second reader of the headers in the draft")
        XCTAssertFalse(draft.contains("func decodeHeaders"), "a second reader of the headers in the draft")
        XCTAssertTrue(draft.contains("typealias BreakpointHeaderFormat = HeldRequestHeaders.Format"))
    }

    /// Core 35dd624's reading of the head reaches both of the panel's
    /// readers: the draft (the Body tab) and the adapter (the agent's body
    /// line). Dropped in either, the labels fall back to the headers with
    /// every unit test still green — "Body (not shown)" for an HTTP/1.1 GET
    /// the core says has no body.
    func testThePanelAndTheBridgeCarryTheCoresBodyFields() throws {
        let draft = try code(Self.draft)
        let initializer = try body(of: "init(request: PausedRequestCodable) {", in: draft)
        for line in ["bodyExpected: request.bodyExpected,", "declaredBodyLength: request.declaredBodyLength\n",
                     "self.bodyEdit = HeldBodyEdit(HeldRequestBody(\n            method: request.method,\n"] {
            XCTAssertTrue(initializer.contains(line), "\(line) — \(initializer)")
        }

        let adapter = try code(Self.adapter)
        let paused = try body(of: "func pausedRequests() -> [MCPPausedRequest] {", in: adapter)
        XCTAssertTrue(paused.contains("bodyExpected: request.bodyExpected,"), String(paused))
        XCTAssertTrue(paused.contains("declaredBodyLength: request.declaredBodyLength,"), String(paused))
    }

    /// Content-Length and Transfer-Encoding rows are shown but locked — no
    /// field to type in, no button to remove them — the line under the list
    /// says what goes up for them, and a row that would set one is the
    /// draft's header problem (it disables Resume).
    func testTheEditorLocksTheFramingRows() throws {
        let editors = try code(Self.editors)
        let start = try XCTUnwrap(editors.range(of: "struct BreakpointHeaderEditor: View {"))
        let end = try XCTUnwrap(editors.range(of: "struct BreakpointUnreadableHeaders: View {"))
        let editor = editors[start.upperBound..<end.lowerBound]

        XCTAssertTrue(editor.contains("let locked = BreakpointRequestDraft.isLocked(entry.wrappedValue, among: original)"))
        XCTAssertEqual(editor.components(separatedBy: ".disabled(locked)").count - 1, 2, "the name and the value: \(editor)")
        let locked = try XCTUnwrap(editor.range(of: "if locked {"))
        let remove = try XCTUnwrap(editor.range(of: "headers.removeAll { $0.id == entry.wrappedValue.id }"))
        XCTAssertLessThan(locked.lowerBound, remove.lowerBound, "the remove button is the else branch")
        XCTAssertTrue(editor.contains(".help(HeldRequestFraming.lockedRowHelp)"))
        XCTAssertTrue(editor.contains("if let framingNote {"))

        let panel = try code(Self.panel)
        XCTAssertTrue(panel.contains("framingNote: current.framingNote)"), "the panel hands the editor the draft's note")

        let draft = try code(Self.draft)
        let problem = try body(of: "var headerProblem: String? {", in: draft)
        XCTAssertTrue(problem.contains("HeldRequestFraming.refusal(name: entry.key, value: entry.value, arrived: arrived)"), String(problem))
        let locks = try body(of: "static func isLocked(_ entry: HeaderEntry, among original: [HeaderEntry]) -> Bool {", in: draft)
        XCTAssertTrue(locks.contains("HeldRequestFraming.isFramingHeader(arrived.key)"), String(locks))
        let note = try body(of: "var framingNote: String? {", in: draft)
        XCTAssertTrue(note.contains("replacementBody: bodyPayload()"), String(note))
    }

    /// A TRACE is offered no replacement body: the button only when the edit
    /// can take one, the refusal's words where it would be — and the service,
    /// which both the panel and the bridge go through, refuses one too.
    func testATraceIsOfferedNoBody() throws {
        let editors = try code(Self.editors)
        XCTAssertTrue(editors.contains("if draft.bodyEdit.canReplace {\n            Button(\"Replace Body…\") { draft.startReplacingBody() }"))
        XCTAssertTrue(editors.contains("} else if let refusal = draft.bodyEdit.replacementRefusal {"))

        let service = try code(Self.service)
        let resume = try body(of: "func resume(id: String, headers: [BreakpointHeader]?, body: String?) -> String? {", in: service)
        let guardLine = try XCTUnwrap(resume.range(of: "let refusal = HeldRequestBody.replacementRefusal(method: held.method) {\n            return refusal\n        }"))
        let removal = try XCTUnwrap(resume.range(of: "guard remove(id) else { return nil }"))
        XCTAssertLessThan(guardLine.lowerBound, removal.lowerBound, "refused while the request is still held")
    }

    /// "Empty body" — every held HTTP/1.1 GET since core 35dd624 — was drawn
    /// under the eye struck through that means "hidden" (review of b280cf2).
    /// The symbol is the helper's, decided and tested in MCPKit.
    func testTheBodyViewTakesItsSymbolFromTheHelper() throws {
        let editors = try code(Self.editors)
        let start = try XCTUnwrap(editors.range(of: "struct BreakpointBodyView: View {"))
        let end = try XCTUnwrap(editors.range(of: "struct BreakpointEmptyState: View {"))
        let view = editors[start.upperBound..<end.lowerBound]

        XCTAssertTrue(view.contains("Label(draft.bodyEdit.held.headline, systemImage: draft.bodyEdit.held.headlineSymbol)"), String(view))
        XCTAssertFalse(view.contains("\"eye.slash\""), "a fixed symbol for every headline")
    }

    /// The panel's footer takes its Resume sentence from the helper, which
    /// knows a TRACE carrying a body of its own is answered 502 over HTTP/1.1
    /// instead of being "sent on unchanged" (review of b280cf2).
    func testThePanelFooterTakesItsResumeSentenceFromTheHelper() throws {
        let panel = try code(Self.panel)
        let note = try body(of: "private func outcomeNote(for request: PausedRequestCodable,", in: panel)
        XCTAssertTrue(note.contains("let sent = draft.bodyEdit.held.resumeFooter(host: request.host, edited: draft.isEdited)"), String(note))
        XCTAssertFalse(panel.contains("Resume sends it on to \\(request.host) unchanged."), "the footer's own fixed sentence")
    }

    /// The original body is never in an editor: the one editor in the view
    /// is the replacement's, opened by Replace Body… and closed by Keep
    /// Original Body.
    func testTheBodyViewNeverEditsTheOriginal() throws {
        let editors = try code(Self.editors)
        let start = try XCTUnwrap(editors.range(of: "struct BreakpointBodyView: View {"))
        let end = try XCTUnwrap(editors.range(of: "struct BreakpointEmptyState: View {"))
        let view = editors[start.upperBound..<end.lowerBound]

        XCTAssertEqual(view.components(separatedBy: "SyntaxTextEditor(").count - 1, 1, "one editor")
        XCTAssertTrue(view.contains("SyntaxTextEditor(text: $draft.bodyEdit.text, rspHeaders: $draft.headers)"))
        XCTAssertTrue(view.contains("if draft.bodyEdit.isReplacing {\n                replacementEditor"), "the editor shows only while replacing")
        XCTAssertTrue(view.contains("Button(\"Replace Body…\") { draft.startReplacingBody() }"))
        XCTAssertTrue(view.contains("Button(\"Keep Original Body\") { draft.keepOriginalBody() }"))
        XCTAssertFalse(editors.contains("arrived with no body"), "the note that invited typing over an unseen body")
        XCTAssertFalse(editors.contains("bodyEditable"))
    }

    /// The seed carried a 49-byte preview the core never sends, so every
    /// rendered probe of the panel showed a body while every real one said
    /// "Body (none)". By default it now has the core's shape.
    func testTheProbeSeedHasTheCoresShapeByDefault() throws {
        let service = try code(Self.service)
        let seed = try body(of: "func seedForProbe(", in: service)
        XCTAssertTrue(seed.contains(") ?? .length"), "the default is today's core: \(seed)")
        XCTAssertTrue(seed.contains("bodyPreview: body == .reported ? json : nil,"), String(seed))
        XCTAssertTrue(seed.contains("bodyByteCount: body == .reported ? json.utf8.count : 0,"), String(seed))
        XCTAssertTrue(seed.contains("case .length, .reported:\n            framing = #\",{\"Content-Length\":"), String(seed))
        XCTAssertTrue(seed.contains("(bodyExpected, declaredBodyLength) = (true, json.utf8.count)"), "and the core's reading of it: \(seed)")
        XCTAssertTrue(seed.contains("bodyExpected: bodyExpected,\n            declaredBodyLength: declaredBodyLength"), String(seed))
        // A TRACE with a body of its own, as the core reads it: (true, length).
        XCTAssertTrue(seed.contains("case .traceWithBody:\n            framing = #\",{\"Content-Length\":"), String(seed))
        XCTAssertTrue(seed.contains("method: body == .trace || body == .traceWithBody ? \"TRACE\" : \"POST\","), String(seed))
    }

    /// Nothing shown is not "a prefix": the flag the draft and the bridge read
    /// is false when there is no preview at all.
    func testATruncatedBodyNeedsAPreview() throws {
        let service = try code(Self.service)
        let truncated = try body(of: "static func isBodyTruncated(_ request: PausedRequestCodable) -> Bool {", in: service)
        XCTAssertTrue(truncated.contains("guard let preview = request.bodyPreview, !preview.isEmpty else { return false }"), String(truncated))
    }

    /// list_paused_requests prints the helper's line for every request, read
    /// from the whole request (`HeldRequestBody(_:)`, field for field in
    /// HeldRequestBodyTests) — its method included, which a TRACE's line
    /// depends on.
    func testTheListingPrintsTheHelpersBodyLine() throws {
        let format = try code("AppServices/Sources/MCPKit/MCPTextFormat.swift")
        let paused = try body(of: "public static func pausedRequests(_ page: MCPPausedRequestPage) -> String {", in: format)
        XCTAssertTrue(paused.contains("let body = HeldRequestBody(request)\n"), String(paused))
        XCTAssertTrue(paused.contains("for line in body.agentLines {"), String(paused))
        XCTAssertFalse(paused.contains("if let body = request.bodyPreview, !body.isEmpty {"), "a body line only when there was a preview")
    }
}
