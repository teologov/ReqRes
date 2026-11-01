//
//  RPCExchangeTests.swift
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

/// A row read as an RPC: detection, messages, and the status wherever each
/// protocol puts it (protocol-engine doc §S8).
final class RPCExchangeTests: XCTestCase {
    private typealias H = RPCHeaderPair

    // MARK: Detection

    func testDetection() {
        func detect(_ type: String?, connect: Bool = false) -> String? {
            RPCExchange.detect(contentType: type, connectHeader: connect).map { "\($0.0.rawValue)/\($0.1.rawValue)" }
        }
        XCTAssertEqual(detect("application/grpc"), "grpc/proto")
        XCTAssertEqual(detect("application/grpc+proto"), "grpc/proto")
        XCTAssertEqual(detect("application/grpc+json"), "grpc/json")
        XCTAssertEqual(detect("application/grpc-web+proto"), "grpc_web/proto")
        XCTAssertEqual(detect("Application/GRPC-Web; charset=utf-8"), "grpc_web/proto")
        XCTAssertEqual(detect("application/grpc-web-text"), "grpc_web_text/proto")
        XCTAssertEqual(detect("application/grpc-web-text+proto"), "grpc_web_text/proto")
        XCTAssertEqual(detect("application/grpc+thrift"), "grpc/other")
        XCTAssertEqual(detect("application/connect+proto"), "connect_streaming/proto")
        XCTAssertEqual(detect("application/connect+json"), "connect_streaming/json")
        XCTAssertEqual(detect("application/proto", connect: true), "connect_unary/proto")
        XCTAssertNil(detect("application/proto"), "a protobuf POST is not Connect without Connect-Protocol-Version")
        XCTAssertEqual(detect("application/json", connect: true), "connect_unary/json")
        XCTAssertNil(detect("application/json"), "a JSON POST is not Connect without Connect-Protocol-Version")
        XCTAssertNil(detect("application/grpcx"))
        XCTAssertNil(detect("text/event-stream"))
        XCTAssertNil(detect(nil))
    }

    /// A plain protobuf API (no Connect-Protocol-Version) once read as
    /// Connect unary: a 503 from it showed UNAVAILABLE in the table and
    /// matched `grpc:error`. It is not an RPC row now.
    func testAProtobufPOSTWithoutTheConnectHeaderIsNotAnRPC() {
        let plain = RPCExchangeInput(
            path: "/v1/items", httpStatus: 503,
            requestHeaders: [RPCHeaderPair(name: "content-type", value: "application/proto")],
            responseHeaders: [RPCHeaderPair(name: "content-type", value: "text/plain")],
            requestBody: Data([0x08, 0x01]), responseBody: Data("busy".utf8)
        )
        XCTAssertNil(RPCExchange.detect(plain))
        XCTAssertNil(RPCExchange.status(of: plain))
        var connect = plain
        connect.requestHeaders.append(RPCHeaderPair(name: "connect-protocol-version", value: "1"))
        XCTAssertEqual(RPCExchange.status(of: connect)?.name, "UNAVAILABLE")
    }

    func testServiceAndMethodFromThePath() {
        XCTAssertEqual(RPCExchange.serviceAndMethod(path: "/helloworld.Greeter/SayHello")?.0, "helloworld.Greeter")
        XCTAssertEqual(RPCExchange.serviceAndMethod(path: "/api/pkg.v1.Users/Get?x=1")?.1, "Get")
        XCTAssertNil(RPCExchange.serviceAndMethod(path: "/"))
    }

    // MARK: gRPC-Web

    func testGRPCWebUnaryOK() throws {
        let rpc = try XCTUnwrap(RPCExchange.decode(RPCFixtures.grpcWeb()))
        XCTAssertEqual(rpc.rpcProtocol, .grpcWeb)
        XCTAssertEqual(rpc.service, "helloworld.Greeter")
        XCTAssertEqual(rpc.method, "SayHello")
        XCTAssertEqual(rpc.status, RPCStatus(code: 0, source: .trailerFrame))
        XCTAssertEqual(rpc.trailers, [H(name: "x-trace", value: "abc")])
        XCTAssertEqual(rpc.requestMessages.count, 1)
        XCTAssertEqual(rpc.responseMessages.count, 1, "the trailer frame is not a message")
        guard case .protobuf(let reply) = rpc.responseMessages[0].content else { return XCTFail() }
        XCTAssertEqual(reply.fields.first?.value, .lengthDelimited(ProtoLengthDelimited(byteCount: 9, reading: .text("Hello Ann"), alsoParsesAsMessage: false)))
        XCTAssertTrue(rpc.notes.isEmpty, rpc.notes.joined())
    }

    func testAGRPCWebErrorUnderHTTP200() throws {
        let input = RPCFixtures.grpcWeb(status: 5, message: "user%2042%20not%20found")
        XCTAssertEqual(input.httpStatus, 200)
        let status = try XCTUnwrap(RPCExchange.status(of: input))
        XCTAssertEqual(status.code, 5)
        XCTAssertEqual(status.name, "NOT_FOUND")
        XCTAssertEqual(status.message, "user 42 not found")
        XCTAssertEqual(status.source, .trailerFrame)
        XCTAssertEqual(RPCExchange.decode(input)?.responseMessages.count, 0)
    }

    func testTheCheapStatusEqualsTheFullDecodesStatus() {
        for input in [RPCFixtures.grpcWeb(), RPCFixtures.grpcWeb(status: 14, message: "down")] {
            XCTAssertEqual(RPCExchange.status(of: input), RPCExchange.decode(input)?.status)
            XCTAssertEqual(RPCExchange.decode(input, decodingMessages: false)?.messageCount, 0)
        }
    }

    func testGRPCWebText() throws {
        let body = Data(RPCFixtures.frame(RPCFixtures.helloReply)).base64EncodedString()
            + Data(RPCFixtures.trailer("grpc-status: 7\r\ngrpc-message: no\r\n")).base64EncodedString()
        let input = RPCExchangeInput(
            path: "/helloworld.Greeter/SayHello", httpStatus: 200,
            requestHeaders: [H(name: "content-type", value: "application/grpc-web-text")],
            requestBody: Data(Data(RPCFixtures.frame(RPCFixtures.helloRequest)).base64EncodedString().utf8),
            responseBody: Data(body.utf8)
        )
        let rpc = try XCTUnwrap(RPCExchange.decode(input))
        XCTAssertEqual(rpc.rpcProtocol, .grpcWebText)
        XCTAssertEqual(rpc.status?.name, "PERMISSION_DENIED")
        XCTAssertEqual(rpc.requestMessages.count, 1)
        XCTAssertEqual(rpc.responseMessages.count, 1)
    }

    func testTrailersOnlyStatusInTheHead() throws {
        let input = RPCExchangeInput(
            path: "/a.B/C", httpStatus: 200,
            requestHeaders: [H(name: "content-type", value: "application/grpc-web+proto")],
            responseHeaders: [H(name: "grpc-status", value: "16"), H(name: "grpc-message", value: "token%20expired")],
            requestBody: Data(RPCFixtures.frame([])), responseBody: nil
        )
        XCTAssertEqual(RPCExchange.status(of: input), RPCStatus(code: 16, message: "token expired", source: .responseHead))
    }

    func testAMissingTrailerFrameIsSaid() throws {
        var input = RPCFixtures.grpcWeb()
        input.responseBody = Data(RPCFixtures.frame(RPCFixtures.helloReply) + Array(RPCFixtures.trailer("grpc-status: 0\r\n").prefix(7)))
        let rpc = try XCTUnwrap(RPCExchange.decode(input))
        XCTAssertNil(rpc.status)
        XCTAssertEqual(rpc.statusNote, "The response ended without a trailer frame and its head carries no grpc-status.")
        XCTAssertTrue(rpc.notes.contains { $0.hasPrefix("The response body ends inside a message: 2 of its 16 bytes arrived") }, rpc.notes.joined(separator: "|"))
        XCTAssertEqual(rpc.responseMessages.count, 1, "the whole message before the cut still reads")
    }

    func testANonOKHTTPStatusWithNoRPCStatusIsInferredAndSaysSo() {
        let input = RPCExchangeInput(path: "/a.B/C", httpStatus: 503,
                                     requestHeaders: [H(name: "content-type", value: "application/grpc-web")])
        XCTAssertEqual(RPCExchange.status(of: input), RPCStatus(code: 14, source: .httpStatus))
    }

    // MARK: Native gRPC (status only in the head until trailers are recorded)

    func testNativeGRPCWithoutTrailersHasNoStatusAndSaysWhy() throws {
        let input = RPCExchangeInput(
            path: "/a.B/C", httpStatus: 200,
            requestHeaders: [H(name: "content-type", value: "application/grpc")],
            requestBody: Data(RPCFixtures.frame(RPCFixtures.helloRequest)),
            responseBody: Data(RPCFixtures.frame(RPCFixtures.helloReply))
        )
        let rpc = try XCTUnwrap(RPCExchange.decode(input))
        XCTAssertNil(rpc.status)
        XCTAssertTrue(rpc.statusNote?.contains("HTTP/2 trailers") ?? false)
        XCTAssertEqual(rpc.responseMessages.count, 1)
        var trailersOnly = input
        trailersOnly.responseHeaders = [H(name: "grpc-status", value: "12")]
        trailersOnly.responseBody = nil
        XCTAssertEqual(RPCExchange.status(of: trailersOnly)?.name, "UNIMPLEMENTED")

        // Once the core records trailers (C13), they are passed in and read.
        var withTrailers = input
        withTrailers.responseTrailers = [H(name: "grpc-status", value: "8"), H(name: "grpc-message", value: "quota"), H(name: "x-cost", value: "3")]
        let recorded = try XCTUnwrap(RPCExchange.decode(withTrailers))
        XCTAssertEqual(recorded.status, RPCStatus(code: 8, message: "quota", source: .trailers))
        XCTAssertEqual(recorded.trailers, [H(name: "x-cost", value: "3")])
        XCTAssertNil(recorded.statusNote)
    }

    // MARK: Compression

    func testGzipPerMessageAndAnUnknownEncodingNamed() throws {
        var input = RPCFixtures.grpcWeb()
        input.requestHeaders.append(H(name: "grpc-encoding", value: "gzip"))
        input.requestBody = Data(RPCFixtures.frame(RPCFixtures.gzip(RPCFixtures.user), flags: 1))
        let rpc = try XCTUnwrap(RPCExchange.decode(input))
        let message = try XCTUnwrap(rpc.requestMessages.first)
        XCTAssertTrue(message.compressed)
        XCTAssertEqual(message.wireBytes, RPCFixtures.gzip(RPCFixtures.user).count)
        guard case .protobuf(let user) = message.content else { return XCTFail("inflated and decoded") }
        XCTAssertEqual(user.fields.count, 7)

        input.requestHeaders[input.requestHeaders.count - 1] = H(name: "grpc-encoding", value: "snappy")
        guard case .bytes(_, let reason) = try XCTUnwrap(RPCExchange.decode(input)).requestMessages[0].content else { return XCTFail() }
        XCTAssertEqual(reason, "Compressed with snappy, which ReqRes does not decode; shown as sent.")
    }

    // MARK: Connect

    func testConnectUnarySuccessAndError() throws {
        let ok = RPCExchangeInput(
            path: "/acme.v1.Users/Get", httpStatus: 200,
            requestHeaders: [H(name: "content-type", value: "application/proto"), H(name: "connect-protocol-version", value: "1")],
            responseHeaders: [H(name: "content-type", value: "application/proto")],
            requestBody: Data(PB.uint(1, 42)), responseBody: Data(RPCFixtures.user)
        )
        let rpc = try XCTUnwrap(RPCExchange.decode(ok))
        XCTAssertEqual(rpc.rpcProtocol, .connectUnary)
        XCTAssertEqual(rpc.status, RPCStatus(code: 0, source: .connectUnary))
        XCTAssertEqual(rpc.requestMessages.count, 1)
        XCTAssertEqual(rpc.responseMessages.count, 1)

        var failed = ok
        failed.httpStatus = 404
        failed.responseHeaders = [H(name: "content-type", value: "application/json")]
        failed.responseBody = Data(#"{"code":"not_found","message":"no user 42"}"#.utf8)
        let error = try XCTUnwrap(RPCExchange.decode(failed))
        XCTAssertEqual(error.status, RPCStatus(code: 5, message: "no user 42", source: .connectUnary))
        XCTAssertTrue(error.responseMessages.isEmpty, "an error's body is the error, not a message")

        let json = RPCExchangeInput(
            path: "/acme.v1.Users/Get", httpStatus: 200,
            requestHeaders: [H(name: "content-type", value: "application/json"), H(name: "connect-protocol-version", value: "1")],
            requestBody: Data(#"{"id":42}"#.utf8), responseBody: Data(#"{"name":"Ann"}"#.utf8)
        )
        XCTAssertEqual(RPCExchange.decode(json)?.requestMessages.first?.content, .text(#"{"id":42}"#))
    }

    func testConnectStreamingEndStreamError() throws {
        let end = #"{"error":{"code":"resource_exhausted","message":"slow down"},"metadata":{"retry-after":["3"]}}"#
        let input = RPCExchangeInput(
            path: "/acme.v1.Feed/Watch", httpStatus: 200,
            requestHeaders: [H(name: "content-type", value: "application/connect+proto")],
            requestBody: Data(RPCFixtures.frame(PB.uint(1, 1))),
            responseBody: Data(RPCFixtures.frame(RPCFixtures.user) + RPCFixtures.frame(RPCFixtures.user) + RPCFixtures.frame(Array(end.utf8), flags: 0x02))
        )
        let rpc = try XCTUnwrap(RPCExchange.decode(input))
        XCTAssertEqual(rpc.rpcProtocol, .connectStreaming)
        XCTAssertEqual(rpc.status, RPCStatus(code: 8, message: "slow down", source: .endStream))
        XCTAssertEqual(rpc.trailers, [H(name: "retry-after", value: "3")])
        XCTAssertEqual(rpc.responseMessages.count, 2, "the end-of-stream message is not a message")
        XCTAssertEqual(rpc.responseMessages.map(\.number), [1, 2])

        var fine = input
        fine.responseBody = Data(RPCFixtures.frame(Array("{}".utf8), flags: 0x02))
        XCTAssertEqual(RPCExchange.status(of: fine), RPCStatus(code: 0, source: .endStream))

        // Connect's own spelling of CANCELLED.
        XCTAssertEqual(RPCExchange.connectEndStream(Data(#"{"error":{"code":"canceled"}}"#.utf8)).status?.code, 1)
    }

    // MARK: Status vocabulary

    func testStatusNamesAndTheFilterVocabulary() {
        XCTAssertEqual(RPCStatusCode.names.count, 17)
        XCTAssertEqual(RPCStatusCode.displayName(5), "NOT_FOUND")
        XCTAssertEqual(RPCStatusCode.displayName(42), "code 42")
        XCTAssertEqual(RPCStatusCode.code(named: "not_found"), 5)
        XCTAssertEqual(RPCStatusCode.code(named: "NotFound"), 5)
        XCTAssertEqual(RPCStatusCode.code(named: "canceled"), 1)
        XCTAssertEqual(RPCStatusCode.code(named: "OK"), 0)
        XCTAssertNil(RPCStatusCode.code(named: "banana"))
        XCTAssertEqual(RPCStatusMatch.parse("error"), .error)
        XCTAssertEqual(RPCStatusMatch.parse("ok"), .code(0))
        XCTAssertEqual(RPCStatusMatch.parse("5"), .code(5))
        XCTAssertEqual(RPCStatusMatch.parse("unavailable"), .code(14))
        XCTAssertNil(RPCStatusMatch.parse("-1"))
        XCTAssertNil(RPCStatusMatch.parse("nope"))
        XCTAssertTrue(RPCStatusMatch.error.matches(5))
        XCTAssertFalse(RPCStatusMatch.error.matches(0))
        XCTAssertFalse(RPCStatusMatch.error.matches(nil), "a row that is not an RPC is not an RPC error")
        XCTAssertEqual(RPCStatusMatch.code(42).token, "42")
        XCTAssertEqual(RPCStatusMatch.parse(RPCStatusMatch.code(42).token), .code(42))
        XCTAssertEqual(RPCStatusCode.inferred(fromHTTPStatus: 401), 16)
        XCTAssertNil(RPCStatusCode.inferred(fromHTTPStatus: 200))
    }
}
