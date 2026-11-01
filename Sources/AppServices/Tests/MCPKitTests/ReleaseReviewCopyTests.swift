//
//  ReleaseReviewCopyTests.swift
//  AppServices
//
//  Created by OloApps on 9/29/26.
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

import XCTest
@testable import MCPKit

/// Sentences an agent or a user acts on, checked against what the code does
/// (release review, 2026-09-29). Each assertion names the false sentence it
/// replaced.
final class ReleaseReviewCopyTests: XCTestCase {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private var skill: String { get throws { try source("Sources/reqres-mcp/SKILL.md") } }
    private var server: String { get throws { try source("Sources/reqres-mcp/ReqResMCPServer.swift") } }

    /// The standing grant exists: "every change asks" is false while it is on.
    func testNoUnqualifiedEveryChangeAsks() throws {
        let skill = try skill
        XCTAssertFalse(skill.contains("Every one of these asks the user first"))
        XCTAssertFalse(skill.contains("every change waits for the user to approve it in the ReqRes window."))
        let flat = skill.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        XCTAssertTrue(flat.contains("unless they have allowed agent changes without asking"))
        XCTAssertTrue(flat.contains("`exclude_host` and `replay_request` always ask"))
        let readme = try String(contentsOf: Self.packageRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertFalse(readme.contains("every change asks you first"))
        XCTAssertFalse(readme.contains("with your approval, every time"))
    }

    /// The README sells the term the paywall states (`LicenseOffer` in Utils):
    /// yours permanently, with every future version included (2026-10-31). It
    /// replaced "with every 1.x update included" (PRD A4), which replaced
    /// "12 months of the licensed limits and updates for one payment". The
    /// word "perpetual" stays out, as on the paywall, and so does any price
    /// or window for a next version.
    func testTheReadmeSellsTheTermThePaywallStates() throws {
        let readme = try String(contentsOf: Self.packageRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md"), encoding: .utf8)
        let flat = readme.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("yours permanently"))
        XCTAssertTrue(flat.contains("every future version included"))
        XCTAssertFalse(flat.contains("1.x update"))
        XCTAssertFalse(flat.contains("ReqRes 2"))
        XCTAssertFalse(flat.contains("within 12 months"))
        XCTAssertFalse(readme.lowercased().contains("perpetual"))
        XCTAssertFalse(flat.contains("12 months of the licensed limits"))
    }

    /// An override without a body forwards; a map_local whose file cannot be
    /// read is answered by ReqRes with 500 and a note (F24), never forwarded.
    func testMocksThatForwardAreNamed() throws {
        let skill = try skill
        XCTAssertFalse(skill.contains("and every `map_local`, answer the app from ReqRes"))
        let flat = skill.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("A `map_local` whose file ReqRes cannot read (moved, deleted, or chosen before ReqRes was last relaunched without a kept permission) never forwards: it answers 500 with a plain-text note naming the file"), "the unreadable-file answer (F24)")
        XCTAssertFalse(flat.contains("whose file is missing or unreadable still FORWARD"), "the pre-F24 claim")
        let server = try server
        XCTAssertTrue(server.contains("an override WITHOUT response_body FORWARDS the request to the server — the app's own request, with request_headers set over it — and its response comes back with the override's response_status in place of the server's; a map_local whose file ReqRes cannot read (moved, deleted, or chosen before ReqRes was last relaunched without a kept permission) answers 500 with a plain-text note naming the file, never forwards, and the rule is marked in the Overrides list."))
        XCTAssertTrue(server.contains("a response with no body (give response_body"))
    }

    /// Replay: rules apply only when the CA is installed AND trusted; an
    /// untrusted CA relays rather than failing TLS.
    func testReplayCopyMatchesTheRelayEngine() throws {
        let skill = try skill
        XCTAssertFalse(skill.contains("fails at TLS"))
        XCTAssertTrue(skill.contains("RELAYED without decrypting it"))
        let server = try server
        XCTAssertFalse(server.contains("so the user's rules apply to it and it lands in the traffic list; with capture stopped"))
        XCTAssertTrue(server.contains("only when the ReqRes CA is installed AND trusted and the host is not excluded"))
    }

    /// Matching ignores a rule's scheme; the parameter must not suggest a
    /// scope that does not exist.
    func testTheSchemeParameterSaysMatchingIgnoresIt() throws {
        XCTAssertTrue(try server.contains("matching ignores it, so a rule answers http:// and https:// requests to its host alike"))
    }

    /// Cookie is joined by "; " (`MCPRecordedHeaders.separator`).
    func testGetSessionNamesTheCookieSeparator() throws {
        XCTAssertEqual(MCPRecordedHeaders.dictionary(from: #"[{"Cookie":"a=1"},{"Cookie":"b=2"}]"#)["Cookie"], "a=1; b=2")
        XCTAssertTrue(try server.contains("Cookie by '; '"))
    }

    /// Browsers and Electron apps never proxy loopback.
    func testPlainHTTPEntryDoesNotPromiseLoopbackFromBrowsers() throws {
        let http = try XCTUnwrap(ProtocolSupport.all.first { $0.id == "http" })
        XCTAssertFalse(http.whatYouSee.contains("localhost:3000 included"))
        XCTAssertTrue(http.whatYouSee.contains("browsers and Electron apps never send localhost"))
        XCTAssertFalse(http.whatToDo.hasPrefix("Nothing for apps"))
    }

    /// A native gRPC call that got as far as a request is answered grpc-status
    /// 14, not a 502 — and the copy says only that (F22, 2026-10-26): a native
    /// gRPC client whose server cannot be reached while its connection is set
    /// up never sends a request; it is offered HTTP/1.1, closes the connection, and shows
    /// as a Failed row. The mTLS entry is that case too (the server's TLS
    /// refuses ReqRes at the eager dial), so it no longer promises a 14.
    func testFailureCopyNamesTheGRPCAnswer() throws {
        let bullet = try XCTUnwrap(FailureRowCopy.helpBullets.first { $0.contains("grpc-status 14") })
        XCTAssertTrue(bullet.contains("that got as far as a request"), bullet)
        XCTAssertTrue(bullet.contains("closes the connection, and the Failed row says so"), bullet)
        XCTAssertTrue(FailureRowCopy.settingsExplanation.contains("native gRPC call that got as far as a request, HTTP 200 with grpc-status 14"))
        XCTAssertTrue(FailureRowCopy.settingsExplanation.contains("it closes the connection, and one Failed row says so"))
        let mtls = try XCTUnwrap(ProtocolSupport.all.first { $0.id == "mtls" })
        XCTAssertFalse(mtls.whatYouSee.contains("grpc-status 14"), mtls.whatYouSee)
        XCTAssertTrue(mtls.whatYouSee.contains("names excluding the host as the fix"), mtls.whatYouSee)
    }
}
