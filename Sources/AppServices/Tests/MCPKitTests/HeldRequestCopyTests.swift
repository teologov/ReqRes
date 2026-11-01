//
//  HeldRequestCopyTests.swift
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
//  What the breakpoint tools, SKILL.md and Help say about a held request's
//  body and framing, checked against what build 53's core (95062d1) does:
//
//   - core 35dd624 drains the rest of an original body after a replacement
//     (and after an abort): nothing of it reaches the server. Build 52 said
//     the rest "can still reach the server after yours" — true of 5de31eb,
//     false now, and gone with the sentences that said it.
//   - core 5efe7aa keeps the app's own Content-Length and Transfer-Encoding
//     when its own body follows, frames a replacement itself, and answers an
//     HTTP/1 TRACE carrying a body 502 — a replacement, or the app's own.
//
//  Each sentence is said once, in MCPKit, and these check the four places
//  that print it still do.
//

import XCTest
@testable import MCPKit

final class HeldRequestCopyTests: XCTestCase {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/MCPKitTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.sourcesRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private var server: String { get throws { try source("AppServices/Sources/reqres-mcp/ReqResMCPServer.swift") } }
    private var help: String { get throws { try source("UI/Views/Help/HelpContent.swift") } }

    /// SKILL.md as a reader takes it: wrapped lines joined, code quotes dropped.
    private var skill: String { get throws { flat(try source("AppServices/Sources/reqres-mcp/SKILL.md")) } }

    private func flat(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - The rest of the original

    /// Nothing promises the old behaviour any more, anywhere: build 52's two
    /// sentences are gone from MCPKit and from every place that printed them.
    func testNothingSaysTheRestOfTheOriginalCanStillFollow() throws {
        let files = [
            "AppServices/Sources/MCPKit/HeldRequestBody.swift",
            "AppServices/Sources/reqres-mcp/ReqResMCPServer.swift",
            "AppServices/Sources/reqres-mcp/SKILL.md",
            "UI/Views/Help/HelpContent.swift",
            "UI/Views/Breakpoints/BreakpointRequestEditors.swift",
            "UI/Views/Breakpoints/BreakpointPanel.swift",
        ]
        for file in files {
            let text = flat(try source(file))
            XCTAssertFalse(text.contains("unfinishedUploadNote"), file)
            XCTAssertFalse(text.contains("can still reach the server after yours"), file)
            XCTAssertFalse(text.contains("resume such a request without body"), file)
        }
    }

    /// The new truth, in the one sentence all four share — stating its own
    /// condition, because each place prints it beside "without a replacement
    /// the original goes" (Help: "until you type something, the original
    /// goes."), where an unconditional "None of the original goes to the
    /// server" read as the opposite (review of b280cf2).
    func testEveryPlaceSaysNoneOfTheOriginalGoes() throws {
        XCTAssertEqual(HeldRequestBody.originalDroppedNote,
                       "With a replacement, none of the original goes to the server: what has arrived of it, and whatever the app still sends, is read and dropped.")
        XCTAssertTrue(try server.contains(#"\(HeldRequestBody.originalDroppedNote)"#), "answer_paused_request")
        XCTAssertTrue(try skill.contains(flat(HeldRequestBody.originalDroppedNote)), "SKILL.md")
        XCTAssertTrue(try help.contains(#"\(HeldRequestBody.originalDroppedNote)"#), "Help ▸ Breakpoints")
        XCTAssertTrue(try server.contains("none of the original, which is not shown, reaches the server"), "the body parameter")
    }

    /// Nowhere is the drained original said without its condition: not in
    /// MCPKit's sentence, and not written out inline in a place that prints
    /// it. The two places that say the original goes on when nothing replaces
    /// it are followed by the conditional sentence, never the bare one.
    func testTheDrainedOriginalIsNeverSaidUnconditionally() throws {
        for (name, text) in [("ReqResMCPServer.swift", flat(try server)), ("SKILL.md", try skill), ("HelpContent.swift", flat(try help))] {
            XCTAssertFalse(text.contains("None of the original goes to the server"), name)
        }
        let help = try help
        XCTAssertTrue(help.contains(#"until you type something, the original goes. \(HeldRequestBody.originalDroppedNote)"#),
                      "Help states the original going first, then the conditional sentence")
        XCTAssertTrue(HeldRequestBody.originalDroppedNote.hasPrefix("With a replacement, "))
    }

    // MARK: - Framing and TRACE

    func testTheFramingRuleIsSaidWhereAnAgentAndAPersonMeetIt() throws {
        let server = try server, skill = try skill, help = try help
        XCTAssertTrue(server.contains(#"\(HeldRequestFraming.agentRule)"#), "answer_paused_request")
        XCTAssertTrue(skill.contains(flat(HeldRequestFraming.agentRule)), "SKILL.md")
        XCTAssertTrue(server.contains("Not Content-Length or Transfer-Encoding (refused): ReqRes sets those"), "set_headers")
        XCTAssertTrue(server.contains("Header names to drop before resuming. Not Content-Length or Transfer-Encoding (refused)"), "remove_headers")
        XCTAssertTrue(help.contains("Content-Length and Transfer-Encoding are shown but cannot be edited"), "Help ▸ Breakpoints")
    }

    func testATraceIsSaidToTakeNoBody() throws {
        let server = try server, skill = try skill, help = try help
        XCTAssertTrue(server.contains("A TRACE takes no body: body is refused for one,"), "answer_paused_request")
        XCTAssertTrue(server.contains("Refused for a TRACE, which may not carry a body"), "the body parameter")
        XCTAssertTrue(skill.contains("A TRACE takes no body: body is refused for one, because over HTTP/1.1 ReqRes answers a TRACE with a body 502 instead of forwarding it."))
        XCTAssertTrue(help.contains("A TRACE request, which may not carry a body, is not offered one,"))
    }

    /// Resume does not send a TRACE carrying a body of its own "unchanged":
    /// over HTTP/1.1 the core answers it 502 (core 5efe7aa). Each place that
    /// says resuming without a body sends the original unchanged says so too
    /// (review of b280cf2).
    func testATraceArrivingWithABodyIsSaidToGetThe502() throws {
        let server = try server, skill = try skill, help = try help
        XCTAssertTrue(server.contains("A TRACE takes no body: body is refused for one, and over HTTP/1.1 a TRACE that arrives with a body of its own is answered 502 by ReqRes when resumed (its body line says so) — abort that one instead."), "answer_paused_request")
        XCTAssertTrue(server.contains("and resuming without a body sends the original unchanged, except a TRACE that arrives with a body of its own, which over HTTP/1.1 ReqRes answers 502 instead of forwarding it (its body line says so)."), "list_paused_requests")
        XCTAssertTrue(skill.contains("Over HTTP/1.1 a TRACE that arrives with a body of its own gets that 502 when resumed too (its body: line says so): abort it instead."), "SKILL.md")
        XCTAssertTrue(help.contains("over HTTP/1.1 one that arrives with a body of its own is answered 502 by ReqRes when resumed instead of being forwarded — its Body tab says so."), "Help ▸ Breakpoints")
    }

    // MARK: - What a body line can say

    /// list_paused_requests' description and SKILL.md name every kind of
    /// body line the listing prints, "empty" among them (core 35dd624's
    /// `bodyExpected == false`).
    func testTheListingsBodyLinesAreDescribed() throws {
        let server = try server, skill = try skill
        XCTAssertTrue(server.contains("Each request's body line says what its head declares instead — empty (no body follows), a size (Content-Length), a body sent in chunks (Transfer-Encoding) or of a size it does not declare (HTTP/2), or, when the head cannot say (an HTTP/2 GET without content-length, say), that a body can still follow"))
        XCTAssertTrue(skill.contains("body: line for every held request with what its head DECLARES: empty (no body follows"))
        XCTAssertFalse(server.contains("gives only the size the request declares"), "an empty body has no size to give")
    }

    // MARK: - Help ▸ Breakpoints

    /// Turning off (or deleting) the last armed breakpoint releases
    /// everything held (`BreakpointService.persistAndPush` → `resumeAll()`),
    /// so Help may not say turning one off never releases a request.
    func testHelpSaysWhatTurningTheLastBreakpointOffDoes() throws {
        let help = try help
        XCTAssertFalse(help.contains("Turning the breakpoint off, or deleting it, does not release a request already being held."))
        XCTAssertTrue(help.contains("With none left armed, everything held is released, unchanged."))
        let service = try source("UI/Services/BreakpointService.swift")
        XCTAssertTrue(service.contains("if !isArmed, !pending.isEmpty {\n            resumeAll()"), "the behaviour Help describes")
    }

    /// The core asks `BreakpointRegistry.shouldPause` at every request head,
    /// on whatever connection it arrives — not once per connection.
    func testHelpSaysABreakpointAppliesToRequestsNotConnections() throws {
        let help = try help
        XCTAssertFalse(help.contains("It applies to connections made after it"))
        XCTAssertTrue(help.contains("It applies to requests that start after it, on new connections and open ones alike"))
    }
}
