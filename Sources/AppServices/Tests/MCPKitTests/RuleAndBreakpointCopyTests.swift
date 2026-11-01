//
//  RuleAndBreakpointCopyTests.swift
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
//  What the rule and breakpoint tools tell an agent — and Help tells a
//  person — checked against what build 53 does: its core (95062d1) and the
//  shell's rule routes. Build 52's review found sentences true of neither
//  ("sending it back would store the mask", "a rule carries no response
//  headers unless you give them", a status text that said nothing of
//  map_local); build 53's core made more of them false: a rule's status 0
//  keeps the server's (an extend rule's default), a map_local whose file is
//  missing lets the server's response through unchanged (until F24, 2026-10-26:
//  since then ReqRes answers it with 500 and a note), a rule never changes
//  the framing of the app's own body, and an override without a body forwards
//  the app's request with the rule's headers set over it (not "replaced …,
//  Host kept"). Each assertion names the sentence it replaced. The held
//  body's sentences are HeldRequestCopyTests'.
//

import XCTest
@testable import MCPKit

final class RuleAndBreakpointCopyTests: XCTestCase {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private var server: String { get throws { try source("Sources/reqres-mcp/ReqResMCPServer.swift") } }
    private var help: String { get throws { try source("../UI/Views/Help/HelpContent.swift") } }

    /// SKILL.md as a reader takes it: wrapped lines joined, code quotes dropped.
    private var skill: String { get throws { flat(try source("Sources/reqres-mcp/SKILL.md")) } }

    private func flat(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Rules

    /// With the rules routes of build 52, a path sent back exactly as
    /// list_rules shows it keeps the stored one, and a path holding the mask
    /// any other way is refused (MCPWriteValidation) — the mask is never
    /// stored.
    func testNoRuleTextSaysTheMaskWouldBeStored() throws {
        let server = try server, skill = try skill
        for text in [server, skill] {
            XCTAssertFalse(text.contains("would store the mask"))
            XCTAssertFalse(text.contains("the mask would be stored"))
            XCTAssertFalse(text.contains("never send a path"))
        }
        XCTAssertTrue(server.contains("A path sent back to update_rule exactly as shown here keeps the stored one"))
        XCTAssertTrue(server.contains("sent back exactly as shown it keeps the stored path"))
        XCTAssertTrue(skill.contains("A path sent back to update_rule exactly as shown keeps the stored one"))
        XCTAssertTrue(server.contains("raw only for a host the user excepted from redaction"))
        XCTAssertTrue(skill.contains("raw only for a host the user excepted from redaction"))
    }

    /// A new override that names no Content-Type is given the JSON one (its
    /// response carries the rule's headers only); extend and map_local get none.
    func testAnOverridesDefaultContentTypeIsNamed() throws {
        let server = try server, skill = try skill
        for text in [server, skill] {
            XCTAssertFalse(text.contains("A rule carries no response headers unless you give them"))
            XCTAssertTrue(text.contains("A new override whose response_headers name no Content-Type is given Content-Type: application/json; charset=utf-8"))
        }
        XCTAssertFalse(server.contains("None by default, so the server's Content-Type"))
        XCTAssertTrue(server.contains("An override that names no Content-Type is given application/json; charset=utf-8; extend and map_local get none by default"))
    }

    /// Core 95062d1: a map_local answer with a readable file is always 200
    /// (`RuleResponses.localAnswer`), and one whose file is missing lets the
    /// server's response through unchanged (`responseRewrite`: the server's
    /// head, status included). Build 52's texts said the missing file
    /// answered with the rule's status in place of the server's.
    func testAMapLocalAnswersStatusIsSaid() throws {
        let server = try server, skill = try skill, help = try help
        XCTAssertFalse(server.contains("\"Status code to answer with (default 200). For extend it replaces the server's status, whatever it was\""))
        XCTAssertFalse(server.contains("response_status is not used while ReqRes can read the file"))
        XCTAssertFalse(server.contains("and with this in place of the server's status when the file is missing"))
        XCTAssertTrue(server.contains("and status 200 — response_status is not used."))
        XCTAssertTrue(server.contains("map_local: not used — its file answers 200, and a file ReqRes cannot read answers 500 with a note instead of forwarding"))
        XCTAssertTrue(server.contains("an override WITHOUT response_body FORWARDS the request to the server — the app's own request, with request_headers set over it — and its response comes back with the override's response_status in place of the server's; a map_local whose file ReqRes cannot read"))
        XCTAssertTrue(server.contains("it answers 200, so neither the captured status nor response_status is replayed"))
        XCTAssertFalse(skill.contains("its response_status is not used while ReqRes can read the file"))
        XCTAssertFalse(skill.contains("and each answers with the rule's response_status in place of the server's"))
        XCTAssertTrue(skill.contains("and status 200 — its response_status is not used."))
        XCTAssertTrue(skill.contains("an override answers with its response_status in place of the server's, an extend rule only when it names one. A map_local whose file ReqRes cannot read (moved, deleted, or chosen before ReqRes was last relaunched without a kept permission) never forwards: it answers 500 with a plain-text note naming the file, and the rule is marked in the Overrides list until the file is chosen again."))
        XCTAssertFalse(skill.contains("lets the server's response through unchanged"), "the pre-F24 claim")
        XCTAssertTrue(skill.contains("A map_local mock answers 200, so it does not replay the captured status"))
        XCTAssertFalse(help.contains("comes back with the rule's status (200) in place of the server's"))
        XCTAssertTrue(help.contains("a matching request is answered with 500 and a note saying so, never with the real server's response"), "F24: ReqRes answers an unreadable file itself")
    }

    /// Core 95062d1 (F17): an extend rule keeps the server's status unless
    /// it names a final one (`RuleResponses.ruleStatus`), and create_rule's
    /// extend starts at keep (`RuleResponseDefaults.status(forNewRuleIn:)`).
    /// Build 52 said every extend rule answered 200 in place of the server's.
    func testAnExtendRuleKeepsTheServersStatusUnlessItNamesOne() throws {
        let server = try server, skill = try skill, help = try help
        XCTAssertFalse(server.contains("it answers with response_status IN PLACE OF the server's status (200 unless you give one"))
        XCTAssertTrue(server.contains("mode=extend forwards the request and rewrites the real response: it keeps the server's status unless you give response_status (200–599), which then answers IN PLACE OF the server's — a 404 or a 500 included (0, like leaving it out, keeps the server's)"))
        XCTAssertTrue(server.contains("extend: leave it out, or send 0, to keep the server's status (the default)"))
        XCTAssertTrue(server.contains("override: the status it answers with (200 when left out); 0 is refused — keeping the server's status is extend's."))
        XCTAssertFalse(skill.contains("its status is not optional"))
        XCTAssertFalse(skill.contains("still sets the status of every response it matches"))
        XCTAssertTrue(skill.contains("It keeps the server's status unless you give response_status (200–599); one you give answers IN PLACE OF the server's"))
        XCTAssertTrue(skill.contains("An extend rule written only to add a request header leaves every response as the server sent it."))
        XCTAssertTrue(skill.contains("and answers with its own status — 200 unless you give one (200–599); 0 is refused, because keeping the server's status is extend's."))
        XCTAssertFalse(help.contains("200 unless the rule names another"))
        XCTAssertFalse(help.contains("back as 200, so keep the path to the requests you are tagging"), "the example's old last line")
        XCTAssertTrue(help.contains("the answer comes back with the server's own status — unless the rule's Status names one instead of \\(RuleResponseDefaults.keepServerStatusTitle), which then replaces it"))
        XCTAssertTrue(help.contains("otherwise unchanged, and so is every response."))
        XCTAssertTrue(help.contains("Its Status is the one it answers with — an override never keeps the server's."))
    }

    /// update_rule keeps a stored status through a change of mode, except a
    /// map_local rule's, which starts at the new mode's
    /// (`MCPWriteValidation.validate(_:currentMode:…)`); a kept "keep" is
    /// refused on an override (`validateKeptStatus`). The response_status
    /// parameter said nothing at all.
    func testUpdateRuleSaysWhatAModeChangeDoesToTheStatus() throws {
        let server = try server, skill = try skill
        XCTAssertFalse(server.contains("\"response_status\": (\"integer\", \"\")"), "update_rule's status had no description")
        XCTAssertTrue(server.contains("Change fields of an existing rule; only the fields given change, except that a map_local rule made extend or override takes that mode's status unless you send one (see response_status)."))
        XCTAssertTrue(server.contains("an extend rule that keeps the server's status cannot become an override without one (400)"))
        XCTAssertTrue(server.contains("A map_local rule has no status of its own"))
        XCTAssertTrue(skill.contains("update_rule keeps a rule's status the same way"))
        XCTAssertTrue(skill.contains("A map_local rule has no status of its own: made an override or extend rule without one, it starts as a new rule in that mode does"))
    }

    /// A mock that names no status replays the captured one, and the router
    /// refuses one no mock can answer with before anyone is asked
    /// (`MCPWriteValidation.validateReplayedStatus`).
    func testAMocksUnreplayableStatusIsNamed() throws {
        let server = try server, skill = try skill
        XCTAssertTrue(server.contains("needed when the captured one is not (a WebSocket's 101)"))
        XCTAssertTrue(server.contains("is refused for an override mock unless you give response_status; a map_local mock uses none."))
        XCTAssertTrue(skill.contains("an override mock of a capture whose status no mock can answer with (a WebSocket's 101, anything outside 200–599) needs a response_status."))
    }

    /// Core 95062d1 (since 5efe7aa): a forwarded request's Content-Length
    /// and Transfer-Encoding are the app's, whatever a rule set
    /// (`GlueHandler.framingOfTheAppsBody`); and since the release review
    /// (c7acefc) an override without a body forwards the app's headers with
    /// the rule's set over them (`applyHeaders`) — it no longer keeps only
    /// Host, which is what "replaced …, Host kept" described.
    func testARulesRequestHeadersAreDescribedAsTheCoreSetsThem() throws {
        let server = try server, skill = try skill, help = try help
        XCTAssertFalse(server.contains("Host kept"))
        XCTAssertFalse(skill.contains("(Host kept)"))
        XCTAssertFalse(skill.contains("with its headers replaced by the rule's request_headers"))
        XCTAssertTrue(server.contains("Not Content-Length or Transfer-Encoding: they describe the app's body, and the request keeps the app's own whatever the rule sets"))
        XCTAssertTrue(server.contains("Replaces the request headers; not Content-Length or Transfer-Encoding, which a forwarded request keeps as the app sent them"))
        XCTAssertTrue(skill.contains("request_headers are set on a request the rule forwards, over the app's own (one of the same name is replaced) — except Content-Length and Transfer-Encoding, which describe the app's body: the request keeps the app's own, whatever the rule sets."))
        XCTAssertTrue(help.contains("Request headers the rule sets replace the app's of the same name, all but Content-Length and Transfer-Encoding: they describe the app's own body, so they stay as the app sent them."))
    }

    /// Core 95062d1's one-time migration (`RuleFormDefaults`) reset only the
    /// extend rules with a request side and the form's untouched response,
    /// and took the header off map_local rules that had only it. SKILL.md
    /// said every rule an earlier form made still carried it.
    func testTheFormDefaultsMigrationIsDescribedAsItRan() throws {
        let skill = try skill
        XCTAssertFalse(skill.contains("carry that JSON Content-Type in every mode, which relabels every response they match"))
        XCTAssertTrue(skill.contains("This version's first launch reset the extend rules that set request headers and left the form's response untouched (status 200, that header alone, no body)"))
        XCTAssertTrue(skill.contains("so an older extend rule may still answer 200 in place of the server's status"))
        XCTAssertTrue(try server.contains("or → server's status for one that keeps the server's"), "list_rules says how a kept status reads")
    }

    // MARK: - Breakpoints while no ReqRes receives the capture

    /// Core 95062d1 (2950183): no NEW hold while no app is attached
    /// (`GlueHandler.mayHoldForBreakpoint`), and a reattach re-announces the
    /// requests still held (`MitmService.reattachGreeting`).
    func testNoHoldWhileNoAppReceivesTheCaptureIsSaid() throws {
        let server = try server, skill = try skill, help = try help
        XCTAssertTrue(server.contains("Nothing is held while no ReqRes is receiving the capture (capture_status's Delivery line says it is reconnecting, has not connected yet, or is NOT reaching ReqRes): a matching request then goes through unheld, and one held before ReqRes went away is listed again once it reconnects."))
        XCTAssertTrue(skill.contains("Nothing is held while no ReqRes is receiving the capture."))
        XCTAssertTrue(skill.contains("A request held before ReqRes went away is listed again once it reconnects, with what is left of its countdown."))
        XCTAssertTrue(help.contains("Requests are held only while ReqRes is receiving capture."))
        XCTAssertTrue(help.contains("A request held before ReqRes went away comes back to the panel once it reconnects, with what is left of its \\(Int(BreakpointRegistry.decisionTimeout)) seconds."))
        XCTAssertTrue(help.contains("Nothing is held either while ReqRes is reconnecting to a running capture, or says it isn't receiving it."))
    }
}
