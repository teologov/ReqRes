//
//  HeldRequestFramingTests.swift
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
//  Content-Length and Transfer-Encoding on a held request are ReqRes's to set
//  (core 5efe7aa): the app's own go with the app's own body whatever an edit
//  says, and a replacement body is framed by the core. The panel offers them
//  for no edit and refuses a row that would set one; the bridge refuses an
//  agent's patch naming one. These pin that rule and the words it uses.
//

import XCTest
@testable import MCPKit

private func header(_ name: String, _ value: String) -> MCPHeaderPair {
    MCPHeaderPair(name: name, value: value)
}

final class HeldRequestFramingTests: XCTestCase {
    func testTheTwoFramingHeadersAreMatchedWithoutCase() {
        for name in ["Content-Length", "content-length", "CONTENT-LENGTH", " Content-Length ",
                     "Transfer-Encoding", "transfer-encoding", "\tTransfer-Encoding"] {
            XCTAssertTrue(HeldRequestFraming.isFramingHeader(name), name)
        }
        // `TE` is about the response, and every gRPC request carries it.
        for name in ["TE", "Content-Type", "Content-Encoding", "Content-Length-X", "X-Content-Length", ""] {
            XCTAssertFalse(HeldRequestFraming.isFramingHeader(name), name)
        }
    }

    // MARK: - The panel's note

    /// What goes up in their place: the request's own while its body
    /// follows, and a Content-Length counted in UTF-8 bytes — the core's
    /// `BreakpointBodyFraming.contentLength` — for a replacement.
    func testTheNoteSaysWhatGoesUpForThem() {
        let length = [header("Content-Type", "application/json"), header("Content-Length", "76")]
        let chunked = [header("Transfer-Encoding", "chunked")]
        let both = [header("transfer-encoding", "chunked"), header("content-length", "76")]
        let neither = [header("Accept", "*/*"), header("TE", "trailers")]

        XCTAssertNil(HeldRequestFraming.note(arrived: neither, replacementBody: nil), "nothing to say")
        XCTAssertNil(HeldRequestFraming.note(arrived: [], replacementBody: nil))
        XCTAssertEqual(HeldRequestFraming.note(arrived: length, replacementBody: nil),
                       "Content-Length describes the body the app is sending, so it goes as the app sent it and cannot be edited here.")
        XCTAssertEqual(HeldRequestFraming.note(arrived: chunked, replacementBody: nil),
                       "Transfer-Encoding describes the body the app is sending, so it goes as the app sent it and cannot be edited here.")
        XCTAssertEqual(HeldRequestFraming.note(arrived: both, replacementBody: nil),
                       "Content-Length and Transfer-Encoding describe the body the app is sending, so they go as the app sent them and cannot be edited here.")

        XCTAssertEqual(HeldRequestFraming.note(arrived: length, replacementBody: #"{"sku":"B-2"}"#),
                       "With the replacement body, ReqRes sends Content-Length: 13.")
        XCTAssertEqual(HeldRequestFraming.note(arrived: chunked, replacementBody: "é"),
                       "With the replacement body, ReqRes sends Content-Length: 2 and no Transfer-Encoding.", "bytes, not characters")
        XCTAssertEqual(HeldRequestFraming.note(arrived: neither, replacementBody: ""),
                       "With the replacement body, ReqRes sends Content-Length: 0.")
    }

    // MARK: - The panel's refusal

    /// A framing row left as it arrived goes up (as the app sent it, or
    /// replaced by the core for a replacement body); a row that would SET
    /// one — added, renamed to one, or changed — is refused.
    func testARowThatWouldSetFramingIsRefused() {
        let arrived = header("Content-Length", "76")

        XCTAssertNil(HeldRequestFraming.refusal(name: "Content-Length", value: "76", arrived: arrived), "left as it arrived")
        XCTAssertNil(HeldRequestFraming.refusal(name: "content-length", value: "76", arrived: header("content-length", "76")),
                     "HTTP/2's lowercase, as it arrived")
        XCTAssertNil(HeldRequestFraming.refusal(name: "Content-Length", value: "76", arrived: header(" Content-Length", "76")),
                     "the editor trims names")

        let changed = HeldRequestFraming.refusal(name: "Content-Length", value: "5", arrived: arrived)
        XCTAssertEqual(changed, "“Content-Length” cannot be set here: Content-Length and Transfer-Encoding describe the body, "
                       + "so ReqRes sets them — the app's own go with the app's own body, and a replacement body gets a "
                       + "Content-Length counted from it.")
        XCTAssertNotNil(HeldRequestFraming.refusal(name: "Content-Length", value: "76", arrived: nil), "added")
        XCTAssertNotNil(HeldRequestFraming.refusal(name: "Content-Length", value: "76", arrived: header("X-Length", "76")), "renamed to it")
        let added = HeldRequestFraming.refusal(name: " transfer-encoding ", value: "chunked", arrived: nil)
        XCTAssertTrue(added?.hasPrefix("“transfer-encoding” cannot be set here") ?? false, added ?? "nil")
        XCTAssertNotNil(HeldRequestFraming.refusal(name: "Transfer-Encoding", value: "gzip, chunked",
                                                   arrived: header("Transfer-Encoding", "chunked")))

        for (name, value) in [("Content-Type", "text/plain"), ("TE", "trailers"), ("X-Content-Length", "5")] {
            XCTAssertNil(HeldRequestFraming.refusal(name: name, value: value, arrived: nil), name)
        }
    }

    // MARK: - The agent

    func testAnAgentsPatchNamingFramingIsRefusedWithWhatToDo() {
        XCTAssertNil(HeldRequestFraming.agentRefusal(setHeaders: nil, removeHeaders: nil))
        XCTAssertNil(HeldRequestFraming.agentRefusal(setHeaders: ["X-Debug": "1", "TE": "trailers"], removeHeaders: ["Cookie"]))

        XCTAssertEqual(HeldRequestFraming.agentRefusal(setHeaders: ["Content-Length": "5"], removeHeaders: nil),
                       "set_headers names Content-Length. " + HeldRequestFraming.agentRule)
        XCTAssertEqual(HeldRequestFraming.agentRefusal(setHeaders: nil, removeHeaders: ["transfer-encoding"]),
                       "remove_headers names transfer-encoding. " + HeldRequestFraming.agentRule)
        XCTAssertEqual(HeldRequestFraming.agentRefusal(setHeaders: ["Transfer-Encoding": "chunked", "content-length": "5", "X": "1"],
                                                       removeHeaders: [" Content-Length "]),
                       "set_headers names Transfer-Encoding, content-length and remove_headers names Content-Length. "
                       + HeldRequestFraming.agentRule)
        XCTAssertEqual(HeldRequestFraming.agentRule,
                       "Content-Length and Transfer-Encoding are not yours to set or remove: ReqRes sends the app's own with the app's own body, "
                       + "and gives a replacement `body` a Content-Length counted from it, with no Transfer-Encoding. "
                       + "Leave them out of set_headers and remove_headers.")
    }

    /// `MCPBreakpointValidation` applies it to every resume, before anything
    /// is sent — with a body or without, since in neither case would the
    /// value reach the server.
    func testTheDecisionValidationRefusesAPatchNamingFraming() {
        let refusals: [MCPBreakpointDecision] = [
            MCPBreakpointDecision(id: "a", action: .resume, setHeaders: ["Content-Length": "5"]),
            MCPBreakpointDecision(id: "a", action: .resume, setHeaders: ["Content-Length": "2"], body: "{}"),
            MCPBreakpointDecision(id: "a", action: .resume, removeHeaders: ["Transfer-Encoding"]),
            MCPBreakpointDecision(id: "a", action: .resume, removeHeaders: ["transfer-encoding"], body: "{}"),
        ]
        for decision in refusals {
            XCTAssertThrowsError(try MCPBreakpointValidation.validate(decision), "\(decision)") { error in
                guard case MCPWriteError.invalid(let message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.hasSuffix(HeldRequestFraming.agentRule), message)
            }
        }
        XCTAssertNoThrow(try MCPBreakpointValidation.validate(
            MCPBreakpointDecision(id: "a", action: .resume, setHeaders: ["Content-Type": "application/json", "TE": "trailers"],
                                  removeHeaders: ["Cookie"], body: "{}")
        ))
    }
}
