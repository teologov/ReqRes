//
//  GRPCWebTextStatusCostTests.swift
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

/// A grpc-web-text row's STATUS is read without framing its request and
/// without an allocation per base64 group (release review, 2026-09-29).
final class GRPCWebTextStatusCostTests: XCTestCase {
    /// A server-streaming grpc-web-text call near the retention cap: ~12 MB
    /// of base64 in the response (and as much in the request) — status 5.
    /// Measured in a DEBUG test build: 0.38 s after the fix, 2.3 s before.
    private func largeTextCall() -> RPCExchangeInput {
        let message = RPCFixtures.frame(Array(repeating: 0x41, count: 60_000))
        var response: [UInt8] = []
        for _ in 0..<150 { response += message }
        response += RPCFixtures.trailer("grpc-status: 5\r\ngrpc-message: gone\r\n")
        let responseText = Data(Data(response).base64EncodedString().utf8)
        return RPCExchangeInput(
            path: "/feed.Feed/Watch", httpStatus: 200,
            requestHeaders: RPCFixtures.headers([("content-type", "application/grpc-web-text"), ("x-grpc-web", "1")]),
            responseHeaders: RPCFixtures.headers([("content-type", "application/grpc-web-text")]),
            requestBody: responseText, responseBody: responseText
        )
    }

    func testTheStatusOfALargeTextCallIsCheap() throws {
        let input = largeTextCall()
        XCTAssertGreaterThan(input.responseBody?.count ?? 0, 11_000_000)
        let start = Date()
        let status = try XCTUnwrap(RPCExchange.status(of: input))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(status.code, 5)
        XCTAssertEqual(status.message, "gone")
        XCTAssertLessThan(elapsed, 1.2, "\(elapsed) s for the status alone")
    }

    /// The fast decoder gives the same bytes, validity and pending count as
    /// Foundation's base64 on every shape: whole, padded, split, broken.
    func testTheDecoderAgreesWithFoundation() {
        for length in 0..<40 {
            let bytes = (0..<length).map { UInt8(($0 * 37 + 11) & 0xFF) }
            let text = Data(bytes).base64EncodedString()
            let decoded = GRPCWebTextDecoder.decode(Data(text.utf8))
            XCTAssertEqual(decoded.bytes, Data(bytes))
            XCTAssertTrue(decoded.isValid)
            XCTAssertEqual(decoded.pendingCharacters, 0)
            // Split anywhere, with whitespace: the same.
            var decoder = GRPCWebTextDecoder()
            let cut = text.count / 2
            let head = decoder.append(Data((String(text.prefix(cut)) + "\r\n").utf8))
            let tail = decoder.append(Data(String(text.dropFirst(cut)).utf8))
            XCTAssertEqual(head + tail, Data(bytes))
        }
        XCTAssertFalse(GRPCWebTextDecoder.decode(Data("QQ=A".utf8)).isValid, "padding in the wrong place")
        XCTAssertFalse(GRPCWebTextDecoder.decode(Data("QU!B".utf8)).isValid, "not base64")
        XCTAssertEqual(GRPCWebTextDecoder.decode(Data("QUJD QQ".utf8)).pendingCharacters, 2)
    }

    /// Asking for the messages still reports the request side's notes first.
    func testMessagesStillDecodeBothSidesWithRequestNotesFirst() throws {
        var input = RPCFixtures.grpcWeb()
        input.requestBody = Data((input.requestBody ?? Data()) + [0x00, 0x00])
        let decoded = try XCTUnwrap(RPCExchange.decode(input, decodingMessages: true))
        XCTAssertFalse(decoded.notes.isEmpty)
        XCTAssertTrue(decoded.notes.first?.contains("request") ?? false, "\(decoded.notes)")
    }
}
