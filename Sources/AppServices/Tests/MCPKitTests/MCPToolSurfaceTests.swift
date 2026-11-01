//
//  MCPToolSurfaceTests.swift
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
//  A regression shipped once with nothing to catch it: `list_sessions`
//  advertised an `app` filter parameter that `MCPSessionFilter` had no field
//  for, so filtering by it silently returned an empty page every time and an
//  agent could conclude there was no traffic at all. This file is the test
//  that class of bug needed.
//
//  WHY SOURCE-TEXT EXTRACTION, NOT AN IMPORT: the tool list lives in
//  `Sources/reqres-mcp/ReqResMCPServer.swift`, an executable target whose
//  entry point is a bare `main.swift` (`ReqResMCPServer.main()`, which starts
//  a `RunLoop` and never returns). Linking that target into a test bundle
//  risks the test process itself running the MCP server's run loop instead
//  of the test, rather than failing cleanly — not a trade worth making just
//  to avoid a text scan. Duplicating the tool array into MCPKit was the
//  other option on the table, but a duplicate has no way to stay honest:
//  nothing would stop the real array and the copy from drifting apart, and a
//  drifted copy passes every assertion here while telling you nothing about
//  what ReqRes actually ships. So instead of a fixture, this reads ReqRes's
//  actual `ReqResMCPServer.swift` off disk and extracts the tool contract
//  from the literal Swift source — there is exactly one place the tool list
//  is defined, and every run of this file looks at today's version of it.
//
//  This makes the extraction closer to a linter than a unit test: it looks
//  for the specific, load-bearing source shapes the tools are written in
//  (`Tool(name: ..., description: ...)`, `"key": .object([`,
//  `MCPAgentAction.Kind.X.consentNote`) rather than evaluating Swift. If a
//  future rewrite changes those shapes, the extraction helpers below fail
//  LOUDLY (see the `ExtractionError` throws and the `XCTAssertFalse(...,
//  isEmpty, ...)` guards) instead of quietly finding zero tools and passing
//  every assertion that follows vacuously.
//

import Foundation
import XCTest
@testable import MCPKit

final class MCPToolSurfaceTests: XCTestCase {

    // MARK: - Extraction over the live source

    private struct ToolSourceEntry {
        let name: String
        let description: String
        /// The full `Tool(...)` literal for this entry, used only to pull out
        /// its declared parameter names.
        let block: String
    }

    private struct ExtractionError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// `Sources/reqres-mcp/ReqResMCPServer.swift`, located relative to this
    /// test file's own path so it works from any checkout of the repo.
    private static var serverSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/MCPKitTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .appendingPathComponent("Sources/reqres-mcp/ReqResMCPServer.swift")
    }

    private static func loadServerSource() throws -> String {
        do {
            return try String(contentsOf: serverSourceURL, encoding: .utf8)
        } catch {
            throw ExtractionError(
                "Couldn't read \(serverSourceURL.path): \(error.localizedDescription). " +
                "If reqres-mcp moved, update serverSourceURL's relative path."
            )
        }
    }

    /// Slices the `static var tools: [Tool] { [ ... ] }` array literal out of
    /// the server source, then splits it into one substring per `Tool(...)`
    /// entry — bounded by the next `Tool(` (or the end of the array), which
    /// avoids needing to balance parens/brackets through Swift string
    /// interpolation (`\(MCPAgentAction.Kind.x.consentNote)`, which itself
    /// contains parens) inside the descriptions.
    private static func extractToolEntries(from source: String) throws -> [ToolSourceEntry] {
        guard let arrayStart = source.range(of: "static var tools: [Tool] {") else {
            throw ExtractionError("Couldn't find `static var tools: [Tool] {` — ReqResMCPServer.swift's layout changed; update this test's extraction anchors.")
        }
        guard let helperStart = source.range(of: "private static func schema(", range: arrayStart.upperBound..<source.endIndex) else {
            throw ExtractionError("Couldn't find `private static func schema(` after the tools array — extraction anchors need updating.")
        }
        let arraySlice = String(source[arrayStart.upperBound..<helperStart.lowerBound])

        var starts: [String.Index] = []
        var searchStart = arraySlice.startIndex
        while let found = arraySlice.range(of: "Tool(", range: searchStart..<arraySlice.endIndex) {
            starts.append(found.lowerBound)
            searchStart = found.upperBound
        }
        guard !starts.isEmpty else {
            throw ExtractionError("Found no `Tool(` entries inside the tools array — extraction anchors need updating.")
        }

        var entries: [ToolSourceEntry] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : arraySlice.endIndex
            let block = String(arraySlice[start..<end])
            guard let name = firstMatch(#"name:\s*"([a-zA-Z0-9_]+)""#, in: block) else {
                throw ExtractionError("A `Tool(` entry has no `name: \"...\"` on its own line — extraction anchors need updating.\n\(block.prefix(160))")
            }
            guard let description = firstMatch(#"description:\s*"(.*)","#, in: block) else {
                throw ExtractionError("Tool '\(name)' has no single-line `description: \"...\",` — extraction anchors need updating.")
            }
            entries.append(ToolSourceEntry(name: name, description: description, block: block))
        }
        return entries
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captureRange])
        }
    }

    private static func snakeToCamel(_ snake: String) -> String {
        let parts = snake.split(separator: "_")
        guard let first = parts.first else { return snake }
        return parts.dropFirst().reduce(String(first)) { $0 + $1.prefix(1).uppercased() + $1.dropFirst() }
    }

    /// Every write tool, and the `MCPAgentAction.Kind` its description's
    /// consent note is expected to be reading from. Kept as a single table so
    /// `testEveryWriteToolReferencesItsOwnConsentNoteKind` and
    /// `testWriteToolConsentNotesEscalateWithSeverity` agree on it.
    private static let expectedKindByTool: [String: MCPAgentAction.Kind] = [
        "add_host": .addHost,
        "remove_host": .removeHost,
        "create_rule": .createRule,
        "update_rule": .updateRule,
        "delete_rule": .deleteRule,
        "mock_from_session": .mockFromSession,
        "start_capture": .startCapture,
        "stop_capture": .stopCapture,
        "clear_sessions": .clearSessions,
        "export_sessions": .exportSessions,
        "save_session": .saveSession,
        "delete_saved_session": .deleteSavedSession,
        "replay_request": .replayRequest,
        "answer_paused_request": .answerPausedRequest,
        "exclude_host": .excludeHost,
    ]

    // MARK: - Tests

    /// Makes adding or removing a tool a deliberate, visible change: this
    /// list has to be edited by hand for the test to pass again.
    func testToolSurfaceIsExactlyTheDocumentedSet() throws {
        let entries = try Self.extractToolEntries(from: Self.loadServerSource())
        let expectedNames: Set<String> = [
            "capture_status", "list_sessions", "query_session_body", "wait_for_session",
            "wait_for_sessions", "diff_sessions", "get_session",
            "list_hosts", "add_host", "remove_host", "list_rules", "create_rule",
            "update_rule", "delete_rule", "mock_from_session", "test_pattern",
            "start_capture", "stop_capture", "clear_sessions", "export_sessions",
            "diagnose_setup", "capture_environment",
            "save_session", "list_saved_sessions", "get_saved_session", "delete_saved_session",
            "replay_request",
            "list_paused_requests", "answer_paused_request",
            "list_destinations",
            "exclude_host",
            "list_messages", "wait_for_message",
        ]
        XCTAssertEqual(expectedNames.count, 33, "33 tools since list_messages and wait_for_message (protocol PRD Phase 4b, decision D17: 30 → 33 with exclude_host); a change here is a product decision")
        XCTAssertEqual(Set(entries.map(\.name)), expectedNames, "The MCP tool surface changed — update this set deliberately, and check the consent-note and filter-mapping assertions below for whatever changed.")
        // The Set-based check above would miss two tools sharing a name (a
        // duplicate collapses into the same element), so also check the count.
        XCTAssertEqual(entries.count, expectedNames.count, "Two tools appear to share a name.")
    }

    func testEveryToolHasANonEmptyDescription() throws {
        let entries = try Self.extractToolEntries(from: Self.loadServerSource())
        XCTAssertFalse(entries.isEmpty, "Extraction found no tools at all — see the file header for why this test reads source text instead of importing the module.")
        for entry in entries {
            XCTAssertFalse(
                entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Tool '\(entry.name)' has an empty description — an agent sees only this text to decide whether and how to call it."
            )
        }
    }

    /// A write tool's description is supposed to interpolate
    /// `MCPAgentAction.Kind.<x>.consentNote` for the specific kind that
    /// describes what it does — never a hardcoded string (which could go
    /// stale) and never the wrong kind (which would show the wrong severity).
    /// Read-only tools (list_hosts, list_rules, test_pattern) must NOT
    /// reference one at all.
    func testEveryWriteToolReferencesItsOwnConsentNoteKind() throws {
        let entries = try Self.extractToolEntries(from: Self.loadServerSource())
        let caseNameByIdentifier = Dictionary(uniqueKeysWithValues: MCPAgentAction.Kind.allCases.map { (String(describing: $0), $0) })
        // Sanity: every Kind must be claimed by exactly one tool in the table
        // above, or this test is stale relative to MCPWriteModels.
        XCTAssertEqual(
            Set(Self.expectedKindByTool.values), Set(MCPAgentAction.Kind.allCases),
            "expectedKindByTool must cover every MCPAgentAction.Kind exactly once — a Kind was added or removed without updating this test."
        )

        var toolsThatReferencedAKind: Set<String> = []
        for entry in entries {
            let referencedIdentifiers = Self.allMatches(#"MCPAgentAction\.Kind\.([a-zA-Z]+)\.consentNote"#, in: entry.description)
            guard let expectedKind = Self.expectedKindByTool[entry.name] else {
                XCTAssertTrue(referencedIdentifiers.isEmpty, "Tool '\(entry.name)' references a consent note but isn't in this test's write-tool table — is it a new write that needs a Kind, or does expectedKindByTool need updating?")
                continue
            }
            toolsThatReferencedAKind.insert(entry.name)
            XCTAssertEqual(referencedIdentifiers.count, 1, "Tool '\(entry.name)' should reference exactly one consentNote; found \(referencedIdentifiers.count).")
            guard let identifier = referencedIdentifiers.first, let referencedKind = caseNameByIdentifier[identifier] else {
                XCTFail("Tool '\(entry.name)' references an unrecognised Kind case '\(referencedIdentifiers.first ?? "<none>")'.")
                continue
            }
            XCTAssertEqual(referencedKind, expectedKind, "Tool '\(entry.name)' should read its consent note from .\(expectedKind), not .\(referencedKind).")
        }
        XCTAssertEqual(toolsThatReferencedAKind, Set(Self.expectedKindByTool.keys), "Every write tool must carry a consent note, and only write tools should.")
    }

    /// Restates the literal contract in terms of the tools themselves: the
    /// rule tools' notes must mention rewriting live traffic, and the
    /// destructive ones must mention that nothing can be undone. (The general
    /// Kind → wording contract has its own coverage in
    /// MCPAgentActionSeverityTests; this ties it to the specific tool-to-Kind
    /// wiring the previous test just verified, using the real consentNote
    /// implementation rather than a copy of its wording.)
    func testWriteToolConsentNotesEscalateWithSeverity() {
        for (toolName, kind) in Self.expectedKindByTool {
            let note = kind.consentNote
            switch kind.severity {
            case .routine:
                XCTAssertFalse(note.contains("rewrites live traffic"), "'\(toolName)' is routine; its consent note shouldn't read like a traffic rewrite.")
                XCTAssertFalse(note.contains("cannot be restored"), "'\(toolName)' is routine; its consent note shouldn't read like a destructive action.")
            case .exportsData:
                XCTAssertTrue(note.contains("writes captured traffic to a file"), "'\(toolName)' puts captured traffic on disk; an agent should be warned before calling it.")
            case .rewritesTraffic:
                XCTAssertTrue(note.contains("rewrites live traffic"), "'\(toolName)' rewrites live traffic; an agent should be warned before calling it.")
            case .destructive:
                XCTAssertTrue(note.contains("cannot be restored"), "'\(toolName)' is destructive; an agent should be warned before calling it.")
            case .actsOnThirdParty:
                XCTAssertTrue(note.contains("sends a real request"), "'\(toolName)' leaves this Mac; an agent should be warned before calling it.")
                XCTAssertTrue(note.contains("standing grant does not cover it"), "'\(toolName)' is never covered by the standing grant, and its own description has to say so.")
            }
        }
    }

    /// The regression this guards against, verbatim: `list_sessions` used to
    /// advertise an `app` filter parameter `MCPSessionFilter` had no field
    /// for, so filtering by it silently matched nothing, forever. This checks
    /// every parameter the session-listing tools declare against the REAL
    /// `MCPSessionFilter`'s fields (via Mirror, not a hand-kept list of field
    /// names — so a legitimately added filter field doesn't need this test
    /// edited, only a tool advertising one that doesn't exist does).
    func testSessionListingToolsOnlyDeclareFiltersMCPSessionFilterCanApply() throws {
        let entries = try Self.extractToolEntries(from: Self.loadServerSource())
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        let sessionListingTools = ["list_sessions", "wait_for_session", "wait_for_sessions"]
        // Parameters that steer HOW a listing/wait call behaves, not WHICH
        // sessions match — pagination and timing, not filter fields.
        // `include_failed` steers what a WAIT may resolve on, not which rows a
        // filter matches (a list returns failures regardless). `until` steers
        // how far a waited-for request must get (protocol-engine doc §S6);
        // the handler refuses a value it cannot parse rather than ignoring it.
        let nonFilterControlParams: Set<String> = ["limit", "cursor", "timeout_seconds", "max_count", "settle_seconds", "include_failed", "until"]

        let filterFieldNames = Set(Mirror(reflecting: MCPSessionFilter()).children.compactMap { $0.label })
        XCTAssertFalse(filterFieldNames.isEmpty, "Mirror found no MCPSessionFilter fields — reflection can't see them, or the type's shape changed; this test needs a different way to enumerate its fields.")

        for toolName in sessionListingTools {
            guard let entry = byName[toolName] else {
                XCTFail("Expected a '\(toolName)' tool; testToolSurfaceIsExactlyTheDocumentedSet should already have failed on this.")
                continue
            }
            // Every declared parameter in these three tools is written as
            // `"key": .object([...])`; "properties" itself matches that same
            // shape as the enclosing container, so it's excluded below.
            let declaredParams = Set(Self.allMatches(#""([a-zA-Z0-9_]+)":\s*\.object\(\["#, in: entry.block))
                .subtracting(["properties"])
            XCTAssertFalse(declaredParams.isEmpty, "Found no declared parameters for '\(toolName)' — extraction anchors need updating.")

            for param in declaredParams.subtracting(nonFilterControlParams) {
                let camel = Self.snakeToCamel(param)
                XCTAssertTrue(
                    filterFieldNames.contains(camel),
                    "Tool '\(toolName)' declares parameter '\(param)', but MCPSessionFilter has no '\(camel)' field to apply it with — an agent could pass it and quietly get unfiltered results. This is exactly the shape of the 'app' filter regression."
                )
            }
        }
    }

    /// `list_messages` and `wait_for_message` (protocol-engine doc §S7):
    /// every parameter either steers the call (paging, timing) or is a field
    /// `MCPMessageFilter` really applies — the `app`-filter regression's
    /// shape, for the message tools. Both are reads: no consent note.
    func testMessageToolsOnlyDeclareFiltersMCPMessageFilterCanApply() throws {
        let entries = try Self.extractToolEntries(from: Self.loadServerSource())
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        let filterFields = Set(Mirror(reflecting: MCPMessageFilter()).children.compactMap { $0.label })
        XCTAssertEqual(filterFields, ["uid", "host", "direction", "opcode", "contains"])
        let control: Set<String> = ["cursor", "limit", "timeout_seconds"]
        let expected: [String: Set<String>] = [
            "list_messages": ["uid", "direction", "opcode", "contains", "cursor", "limit"],
            "wait_for_message": ["uid", "host", "direction", "opcode", "contains", "timeout_seconds"],
        ]
        for (tool, params) in expected {
            let entry = try XCTUnwrap(byName[tool], "missing \(tool)")
            let declared = Set(Self.allMatches(#""([a-zA-Z0-9_]+)":\s*\.object\(\["#, in: entry.block)).subtracting(["properties"])
            XCTAssertEqual(declared, params, "\(tool)'s parameters changed")
            for param in declared.subtracting(control) {
                XCTAssertTrue(filterFields.contains(Self.snakeToCamel(param)), "\(tool) declares '\(param)' but MCPMessageFilter cannot apply it")
            }
            XCTAssertFalse(entry.block.contains("consentNote"), "\(tool) is a read; it must not carry a consent note")
            XCTAssertTrue(entry.description.contains("redact"), "\(tool)'s description must say its payloads are redacted")
        }
        XCTAssertTrue(try XCTUnwrap(byName["list_messages"]).block.contains(#""required": .array([.string("uid")])"#), "list_messages needs a uid")
    }

    /// The attribution axes are real again — restored WITH data behind them
    /// (`MCPSessionSummary.app`/`.pid`), so this is the previous test's
    /// un-gating made explicit: both fields exist on the filter, and the
    /// listing tools declare both. `country` (destination-map UX spec §8.2)
    /// joins them: the same shape, the same three tools.
    func testListingToolsDeclareTheAttributionFilters() throws {
        let filterFieldNames = Set(Mirror(reflecting: MCPSessionFilter()).children.compactMap { $0.label })
        XCTAssertTrue(filterFieldNames.isSuperset(of: ["app", "pid", "country"]), "MCPSessionFilter lost its attribution or destination fields: \(filterFieldNames)")

        let entries = try Self.extractToolEntries(from: Self.loadServerSource())
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        for toolName in ["list_sessions", "wait_for_session", "wait_for_sessions"] {
            let block = try XCTUnwrap(byName[toolName]).block
            let declaredParams = Set(Self.allMatches(#""([a-zA-Z0-9_]+)":\s*\.object\(\["#, in: block))
            XCTAssertTrue(declaredParams.contains("app"), "'\(toolName)' should declare an app filter")
            XCTAssertTrue(declaredParams.contains("pid"), "'\(toolName)' should declare a pid filter")
            XCTAssertTrue(declaredParams.contains("country"), "'\(toolName)' should declare a country filter")
        }
    }

    /// The converse of the check above: every field `MCPSessionFilter` can
    /// apply is DECLARED on the list and on both waits, or a schema-driven
    /// client cannot discover it — the waits honoured grpc and proto
    /// without declaring them (release review, 2026-09-29).
    func testSessionListingToolsDeclareEveryFilterField() throws {
        let filterFieldNames = Set(Mirror(reflecting: MCPSessionFilter()).children.compactMap { $0.label })
        let entries = try Self.extractToolEntries(from: Self.loadServerSource())
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        for toolName in ["list_sessions", "wait_for_session", "wait_for_sessions"] {
            let block = try XCTUnwrap(byName[toolName]).block
            let declared = Set(Self.allMatches(#""([a-zA-Z0-9_]+)":\s*\.object\(\["#, in: block).map(Self.snakeToCamel))
            XCTAssertTrue(declared.isSuperset(of: filterFieldNames),
                          "'\(toolName)' does not declare \(filterFieldNames.subtracting(declared).sorted())")
        }
    }

    /// `list_destinations` (tool 30) is read-only: no consent note, and it
    /// takes exactly `list_sessions`' filter set so "where does claude send
    /// data" is one call with one argument.
    func testListDestinationsIsReadOnlyAndTakesTheSessionFilters() throws {
        let entries = try Self.extractToolEntries(from: Self.loadServerSource())
        let entry = try XCTUnwrap(entries.first { $0.name == "list_destinations" })
        XCTAssertFalse(entry.description.contains("consentNote"), "list_destinations changes nothing and must not read as a write")
        let declared = Set(Self.allMatches(#""([a-zA-Z0-9_]+)":\s*\.object\(\["#, in: entry.block)).subtracting(["properties"])
        let filterFieldNames = Set(Mirror(reflecting: MCPSessionFilter()).children.compactMap { $0.label })
        XCTAssertEqual(Set(declared.map(Self.snakeToCamel)), filterFieldNames, "list_destinations must declare every MCPSessionFilter field and nothing else")
        XCTAssertFalse(entry.description.lowercased().contains("your location"), "the user's origin is never part of the agent report")
        XCTAssertTrue(entry.description.contains("never reported"))
    }

    /// get_session's description tells agents which reading of a
    /// length-delimited protobuf field wins. It once said "a nested message
    /// when it parses as one, else text" after the decoder had switched to
    /// text first, so an agent would have misread `text` +
    /// `alsoParsesAsMessage`. The wording is pinned to the decoder here.
    func testGetSessionDescribesTheDecodersReadingOrder() throws {
        let hi = try XCTUnwrap(ProtobufDecoder.decode(Data([0x0A, 0x02, 0x68, 0x69])))
        guard case .lengthDelimited(let field) = hi.fields[0].value else { return XCTFail("not length-delimited") }
        XCTAssertEqual(field.reading, .text("hi"), "the decoder's order changed; reword get_session and SKILL.md with it")
        XCTAssertTrue(field.alsoParsesAsMessage)

        let entries = try Self.extractToolEntries(from: Self.loadServerSource())
        let description = try XCTUnwrap(entries.first { $0.name == "get_session" }).description
        XCTAssertTrue(description.contains("a length-delimited field is printable text, else a nested message when it parses as one, else bytes"), description)
        XCTAssertTrue(description.contains("alsoParsesAsMessage flags text that also parses as a message"))
        XCTAssertFalse(description.contains("nested message when it parses as one, else text"))
    }

    /// The phrases a description may use to name a filter axis, and the
    /// `MCPSessionFilter` field each one means. A description that names an
    /// axis not in this table fails LOUDLY — adding the mapping is how a new
    /// axis is advertised deliberately — and every mapped field must exist.
    private static let filterAxisByPhrase: [String: String] = [
        "host": "host",
        "method": "method",
        "status": "status",
        "scheme": "scheme",
        "url substring": "urlContains",
        "originating app": "app",
        "pid": "pid",
        "destination country": "country",
        "outcome": "outcome",
        "grpc status": "grpc",
        "protocol": "proto",
    ]

    /// The `list_sessions` description once read "…or originating app" after
    /// the `app` parameter had been removed: an agent that believed it passed
    /// `app: "Xcode"`, the argument was dropped, and it received EVERY session
    /// believing the list was filtered. The schema test above cannot see that
    /// — prose is not a declared parameter. This one reads the words after
    /// "Filter by" in every listing tool's description and requires each named
    /// axis to be a real `MCPSessionFilter` field AND a parameter that same
    /// tool declares, so the prose, the schema and the model cannot drift
    /// apart again.
    func testListingToolDescriptionsAdvertiseOnlyFiltersTheModelHas() throws {
        let entries = try Self.extractToolEntries(from: Self.loadServerSource())
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        let filterFieldNames = Set(Mirror(reflecting: MCPSessionFilter()).children.compactMap { $0.label })

        // Every phrase in the table must point at a real field, or the table
        // itself would be the thing lying.
        for (phrase, field) in Self.filterAxisByPhrase {
            XCTAssertTrue(filterFieldNames.contains(field), "filterAxisByPhrase maps '\(phrase)' to '\(field)', which MCPSessionFilter does not have.")
        }

        var descriptionsWithAFilterClause = 0
        for toolName in ["list_sessions", "wait_for_session", "wait_for_sessions"] {
            let entry = try XCTUnwrap(byName[toolName])
            guard let axes = Self.advertisedFilterAxes(in: entry.description) else { continue }
            descriptionsWithAFilterClause += 1
            XCTAssertFalse(axes.isEmpty, "'\(toolName)' says \"Filter by\" but names no axis — the clause parser needs updating for its wording.")

            let declaredParams = Set(Self.allMatches(#""([a-zA-Z0-9_]+)":\s*\.object\(\["#, in: entry.block)).subtracting(["properties"])
            for axis in axes {
                guard let field = Self.filterAxisByPhrase[axis] else {
                    XCTFail("'\(toolName)' advertises filtering by '\(axis)', which this test does not know how to map to an MCPSessionFilter field. If it is a real axis, add it to filterAxisByPhrase; if it is not, the description is lying to agents.")
                    continue
                }
                XCTAssertTrue(filterFieldNames.contains(field), "'\(toolName)' advertises filtering by '\(axis)' but MCPSessionFilter has no '\(field)'.")
                let declared = declaredParams.contains { Self.snakeToCamel($0) == field }
                XCTAssertTrue(declared, "'\(toolName)' advertises filtering by '\(axis)' in prose but declares no parameter for '\(field)' — an agent has nowhere to pass it.")
            }
        }
        XCTAssertGreaterThan(descriptionsWithAFilterClause, 0, "No listing tool description contains \"Filter by\" any more — either reword this test's anchor or the agents lost the sentence that tells them what they can filter on.")
    }

    /// The axis phrases in a "Filter by …" clause: parentheticals removed
    /// FIRST (the status example "(e.g. '404' or '5xx')" holds both a full
    /// stop and an "or" that are not the clause's), then the text from
    /// "Filter by" to the next full stop, split on commas and a final "or",
    /// lowercased and trimmed. Nil when the description has no such clause.
    private static func advertisedFilterAxes(in description: String) -> [String]? {
        let withoutParentheticals = description.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        guard let clauseStart = withoutParentheticals.range(of: "Filter by ") else { return nil }
        let rest = withoutParentheticals[clauseStart.upperBound...]
        let clause = rest[rest.startIndex..<(rest.firstIndex(of: ".") ?? rest.endIndex)]
        return clause
            .replacingOccurrences(of: #"\bor\b"#, with: ",", options: .regularExpression)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}
