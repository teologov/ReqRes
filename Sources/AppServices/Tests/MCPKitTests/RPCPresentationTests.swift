//
//  RPCPresentationTests.swift
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

/// Every word of the table's RPC status and of the RPC tab (protocol-engine doc §S8).
final class RPCPresentationTests: XCTestCase {
    func testTheTableShowsTheRPCStatusOnlyWhenItSaysSomethingElse() {
        let notFound = RPCStatus(code: 5, message: "gone", source: .trailerFrame)
        let ok = RPCStatus(code: 0, source: .trailerFrame)
        XCTAssertEqual(RPCPresentation.statusText(httpStatus: 200, status: notFound), "200 · NOT_FOUND")
        XCTAssertEqual(RPCPresentation.statusText(httpStatus: 200, status: ok), "200", "an OK RPC under a 200 adds nothing")
        XCTAssertEqual(RPCPresentation.statusText(httpStatus: 503, status: RPCStatus(code: 14, source: .httpStatus)), "503 · UNAVAILABLE")
        XCTAssertEqual(RPCPresentation.statusText(httpStatus: 500, status: ok), "500 · OK", "odd, so shown")
        XCTAssertEqual(RPCPresentation.statusText(httpStatus: 200, status: nil), "200")
        XCTAssertEqual(RPCPresentation.symbolName(notFound), "exclamationmark.circle")
        XCTAssertEqual(RPCPresentation.symbolName(ok), "checkmark.circle")
        XCTAssertEqual(RPCPresentation.accessibilityLabel(protocol: .grpcWeb, httpStatus: 200, status: notFound), "HTTP 200, gRPC status NOT_FOUND")
        XCTAssertEqual(RPCPresentation.accessibilityLabel(protocol: .connectUnary, httpStatus: 404, status: notFound), "HTTP 404, Connect status NOT_FOUND")
    }

    func testTheHeaderAndStatusLines() throws {
        let rpc = try XCTUnwrap(RPCExchange.decode(RPCFixtures.grpcWeb(status: 5, message: "user%2042%20not%20found")))
        XCTAssertEqual(RPCPresentation.headerLine(rpc), "gRPC-Web · protobuf · helloworld.Greeter / SayHello")
        XCTAssertEqual(RPCPresentation.statusLine(rpc), "Status NOT_FOUND (5) — “user 42 not found” · from the trailer frame")
        XCTAssertEqual(RPCPresentation.countsLine(rpc), "1 request message · 0 response messages")
        var native = RPCFixtures.grpcWeb()
        native.requestHeaders = [RPCHeaderPair(name: "content-type", value: "application/grpc")]
        native.responseBody = Data(RPCFixtures.frame(RPCFixtures.helloReply))
        let line = try RPCPresentation.statusLine(XCTUnwrap(RPCExchange.decode(native)))
        XCTAssertTrue(line.hasPrefix("No RPC status — Native gRPC sends its status in HTTP/2 trailers"), line)
    }

    func testTheFieldTree() {
        let message = RPCMessage(direction: .response, number: 2, wireBytes: 1_300, compressed: true,
                                 content: .protobuf(ProtobufDecoder.decode(Data(RPCFixtures.user + PB.string(8, "say \"hi\"\n")))!))
        XCTAssertEqual(RPCPresentation.messageTitle(message), "Response 2 · 1.3 KB compressed")
        XCTAssertEqual(RPCPresentation.accessibilityLabel(message), "Response message 2, 1.3 KB, compressed")
        let lines = RPCPresentation.lines(message)
        XCTAssertEqual(lines.map { String(repeating: "  ", count: $0.depth) + $0.text }, [
            "1: 42",
            "2: \"Ann\"",
            "3 {",
            "  1: \"Amsterdam\"",
            "  2: 1011",
            "}",
            "4: <4 B> 01 02 ac 02",
            "5: <4 B> 00 ff fe 01",
            "6: 1065353216 (i32)",
            "7: 7 (i64)",
            "8: \"say \\\"hi\\\"\\n\"",
        ])
        XCTAssertNil(lines[0].secondary, "no zig-zag reading in the tab")
        XCTAssertNil(lines[3].secondary, "“also parses as a message” is for agents")
        XCTAssertEqual(lines[6].secondary, "packed: 1, 2, 300")
        XCTAssertEqual(lines[8].secondary, "float 1.0")
        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count, "ids are unique")
    }

    func testANegativeIntIsReadForAPerson() {
        let message = RPCMessage(direction: .request, number: 1, wireBytes: 11, compressed: false,
                                 content: .protobuf(ProtobufDecoder.decode(Data(PB.uint(1, UInt64(bitPattern: -5))))!))
        XCTAssertEqual(RPCPresentation.lines(message).first?.secondary, "int64 -5")
    }

    func testTheTreeIsCappedAndSaysSo() {
        var bytes: [UInt8] = []
        for i in 0 ..< 50 { bytes += PB.uint(1, UInt64(i)) }
        let message = RPCMessage(direction: .request, number: 1, wireBytes: bytes.count, compressed: false,
                                 content: .protobuf(ProtobufDecoder.decode(Data(bytes))!))
        let lines = RPCPresentation.lines(message, maxLines: 10)
        XCTAssertEqual(lines.count, 11)
        XCTAssertEqual(lines.last?.text, "… 40 more lines not shown")
    }

    func testJSONAndBytesMessages() {
        let json = RPCPresentation.lines(RPCMessage(direction: .request, number: 1, wireBytes: 9, compressed: false, content: .text(#"{"id":42}"#)))
        XCTAssertEqual(json.map(\.text), ["{", "  \"id\": 42", "}"])
        let bytes = RPCPresentation.lines(RPCMessage(direction: .request, number: 1, wireBytes: 3, compressed: true,
                                                     content: .bytes(Data([1, 2, 3]), reason: "Compressed with snappy, which ReqRes does not decode; shown as sent.")))
        XCTAssertEqual(bytes.first?.text, "Compressed with snappy, which ReqRes does not decode; shown as sent.")
        XCTAssertEqual(bytes.count, 2)
        XCTAssertTrue(bytes[1].text.hasPrefix("00000000  01 02 03"))
    }

    func testQuotedCutsOnACharacterBoundary() {
        XCTAssertEqual(RPCPresentation.quoted("héllo👋🏽world", max: 6), "\"héllo👋🏽…\"")
        XCTAssertEqual(RPCPresentation.quoted("a\\b\tc", max: 50), "\"a\\\\b\\tc\"")
    }
}
