//
//  ReleaseReviewAgentSurfaceTests.swift
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

/// What agents are handed about binary bodies, mocks and replays (release
/// review, 2026-09-29).
final class ReleaseReviewAgentSurfaceTests: XCTestCase {
    // MARK: - Binary bodies

    private func detail(uid: String, request: String?, response: String?) -> MCPSessionDetail {
        var summary = makeSession(uid: uid, method: "POST")
        summary.contentType = "application/grpc-web+proto"
        return MCPSessionDetail(summary: summary,
                                requestHeaders: ["Content-Type": "application/grpc-web+proto"],
                                responseHeaders: ["Content-Type": "application/grpc-web+proto"],
                                requestBodyPreview: request, responseBodyPreview: response)
    }

    func testABinaryBodyIsDescribedWithItsSizeAndADigest() {
        let bytes = Data((0..<256).map { UInt8($0) })
        let text = MCPBinaryBody.description(contentType: "application/grpc-web+proto", bytes: bytes)
        XCTAssertTrue(text.contains("256 bytes"), text)
        XCTAssertTrue(text.contains("application/grpc-web+proto"), text)
        XCTAssertTrue(MCPBinaryBody.isDescription(text))
        XCTAssertNotEqual(text, MCPBinaryBody.description(contentType: "application/grpc-web+proto", bytes: Data(bytes.reversed())),
                          "two different bodies of one size must not read the same")
        let zstd = MCPBinaryBody.description(contentType: "application/json", bytes: bytes, undecodedEncoding: "zstd")
        XCTAssertTrue(zstd.contains("zstd"), zstd)
        XCTAssertTrue(MCPBinaryBody.isDescription(zstd))
        // The redactor leaves the description alone (the digest is short).
        XCTAssertEqual(MCPRedactor().redactBody(text), text)
    }

    func testDiffTellsTwoBinaryBodiesApart() {
        let a = detail(uid: "a", request: MCPBinaryBody.description(contentType: "application/proto", bytes: Data([1, 2, 3])),
                       response: nil)
        let b = detail(uid: "b", request: MCPBinaryBody.description(contentType: "application/proto", bytes: Data([1, 2, 4])),
                       response: nil)
        XCTAssertNotEqual(MCPSessionDiff.diff(a, b).requestBody, .identical)
        XCTAssertNotEqual(MCPSessionDiff.diff(a, b).requestBody, .bothEmpty)
    }

    func testAHARCarriesADescriptionAsACommentNotAsTheBody() throws {
        let request = MCPBinaryBody.description(contentType: "application/proto", bytes: Data([1, 2, 3]))
        let response = MCPBinaryBody.description(contentType: "application/proto", bytes: Data([9, 9]))
        let har = MCPHARExport.encode(sessions: [detail(uid: "s", request: request, response: response)],
                                      redactor: MCPRedactor(), creatorVersion: "test").data
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: har) as? [String: Any])
        let entry = try XCTUnwrap(((json["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first)
        let postData = try XCTUnwrap((entry["request"] as? [String: Any])?["postData"] as? [String: Any], "a binary request keeps its postData")
        XCTAssertNil(postData["text"])
        XCTAssertEqual(postData["comment"] as? String, request)
        let content = try XCTUnwrap((entry["response"] as? [String: Any])?["content"] as? [String: Any])
        XCTAssertNil(content["text"])
        XCTAssertEqual(content["comment"] as? String, response)
    }

    // MARK: - mock_from_session

    private typealias Captured = MCPMockFromSessionCheck.CapturedResponse

    func testAnEmptyBodyIsNotMockedAsAnOverrideThatWouldForward() throws {
        let empty = Captured(textBody: "", binaryByteCount: 0, notRetainedBytes: 0, undecodedEncoding: nil)
        let text = try XCTUnwrap(MCPMockFromSessionCheck.refusal(uid: "u", mode: .override, responseBody: nil, captured: empty))
        XCTAssertTrue(text.contains("FORWARDS"), text)
        XCTAssertNil(MCPMockFromSessionCheck.refusal(uid: "u", mode: .override, responseBody: "{}", captured: empty),
                     "a body from the agent makes it a real mock")
        XCTAssertNotNil(MCPMockFromSessionCheck.refusal(uid: "u", mode: .mapLocal, responseBody: nil, captured: empty))
    }

    func testABodyKeptInPartOrStillEncodedIsNotMocked() throws {
        let cut = Captured(textBody: "{\"a\":", binaryByteCount: 0, notRetainedBytes: 5_000, undecodedEncoding: nil)
        for mode in [MCPRuleMode.override, .mapLocal] {
            let text = try XCTUnwrap(MCPMockFromSessionCheck.refusal(uid: "u", mode: mode, responseBody: nil, captured: cut))
            XCTAssertTrue(text.contains("kept only in part"), text)
        }
        let zstd = Captured(textBody: "", binaryByteCount: 900, notRetainedBytes: 0, undecodedEncoding: "zstd")
        let text = try XCTUnwrap(MCPMockFromSessionCheck.refusal(uid: "u", mode: .mapLocal, responseBody: nil, captured: zstd))
        XCTAssertTrue(text.contains("zstd"), text)
        XCTAssertNil(MCPMockFromSessionCheck.refusal(uid: "u", mode: .mapLocal, responseBody: "{}", captured: zstd))
    }

    func testAWholeCapturedBodyIsMocked() {
        let whole = Captured(textBody: "{\"ok\":true}", binaryByteCount: 0, notRetainedBytes: 0, undecodedEncoding: nil)
        XCTAssertNil(MCPMockFromSessionCheck.refusal(uid: "u", mode: .override, responseBody: nil, captured: whole))
        let binary = Captured(textBody: "", binaryByteCount: 64, notRetainedBytes: 0, undecodedEncoding: nil)
        XCTAssertNil(MCPMockFromSessionCheck.refusal(uid: "u", mode: .mapLocal, responseBody: nil, captured: binary))
    }

    // MARK: - replay_request

    func testTheRouteSaysWhenAProxiedReplayWasOnlyRelayed() {
        XCTAssertEqual(MCPReplayRoute.decide(captureRunning: false, scheme: "https", excluded: false, caInstalledAndTrusted: true), .direct)
        XCTAssertEqual(MCPReplayRoute.decide(captureRunning: true, scheme: "https", excluded: false, caInstalledAndTrusted: true), .proxy)
        XCTAssertEqual(MCPReplayRoute.decide(captureRunning: true, scheme: "https", excluded: false, caInstalledAndTrusted: false), .relayedWithoutCertificate)
        XCTAssertEqual(MCPReplayRoute.decide(captureRunning: true, scheme: "http", excluded: false, caInstalledAndTrusted: false), .proxy,
                       "plain HTTP is read without a certificate")
        XCTAssertEqual(MCPReplayRoute.decide(captureRunning: true, scheme: "https", excluded: true, caInstalledAndTrusted: true), .relayedExcluded)
    }

    func testARelayedReplayNeverSaysRulesApplied() {
        for route in [MCPReplayRoute.relayedWithoutCertificate, .relayedExcluded, .direct] {
            let text = MCPTextFormat.replay(MCPReplayResult(session: detail(uid: "s", request: nil, response: nil),
                                                            route: route, replayedFrom: "s", redacted: true))
            XCTAssertFalse(text.contains("rules applied"), "\(route): \(text)")
            XCTAssertFalse(text.contains("the user's rules applied"), "\(route)")
        }
        let relayed = MCPTextFormat.replay(MCPReplayResult(session: detail(uid: "s", request: nil, response: nil),
                                                           route: .relayedWithoutCertificate, replayedFrom: "s", redacted: true))
        XCTAssertTrue(relayed.contains("RELAYED"), relayed)
        XCTAssertTrue(relayed.contains("NO rule applied"), relayed)
    }
}
