//
//  MCPRPCRouteTests.swift
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

/// `get_session view=rpc` and `list_sessions grpc=` through the real router
/// (protocol-engine doc §S8).
final class MCPRPCRouteTests: XCTestCase {
    private let token = "t"

    private func router(_ provider: StubRPCProvider, redactor: MCPRedactor = MCPRedactor()) -> MCPBridgeRouter {
        MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider(), redactor: redactor)
    }

    private func get(_ router: MCPBridgeRouter, _ target: String) throws -> ParsedResponse {
        try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: target, token: token))))
    }

    private func view(_ router: MCPBridgeRouter, _ target: String) throws -> MCPRPCView {
        let response = try get(router, target)
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        return try JSONDecoder().decode(MCPRPCView.self, from: response.body)
    }

    private func provider() -> StubRPCProvider {
        let p = StubRPCProvider()
        var input = RPCFixtures.grpcWeb(status: 5, message: "no%20such%20user")
        input.requestBody = Data(RPCFixtures.frame(RPCFixtures.user) + RPCFixtures.frame(PB.uint(1, 7)))
        p.rpc["rpc1"] = MCPSessionRPCFacts(host: "api.example.com", input: input)
        p.rpc["plain"] = MCPSessionRPCFacts(host: "api.example.com", input: RPCExchangeInput(
            path: "/v1/users", httpStatus: 200, requestHeaders: [RPCHeaderPair(name: "content-type", value: "application/json")]))
        p.rpc["live"] = MCPSessionRPCFacts(host: "api.example.com", isLive: true, input: input)
        p.rpc["relay"] = MCPSessionRPCFacts(host: "api.example.com", isRelay: true, input: input)
        return p
    }

    func testTheRPCView() throws {
        let v = try view(router(provider()), "/v1/sessions/rpc1/rpc")
        XCTAssertEqual(v.rpcProtocol, .grpcWeb)
        XCTAssertEqual(v.service, "helloworld.Greeter")
        XCTAssertEqual(v.method, "SayHello")
        XCTAssertEqual(v.httpStatus, 200)
        XCTAssertEqual(v.status, MCPRPCStatus(code: 5, name: "NOT_FOUND", message: "no such user", source: .trailerFrame))
        XCTAssertEqual(v.totalRequestMessages, 2)
        XCTAssertEqual(v.totalResponseMessages, 0)
        XCTAssertEqual(v.messages.map(\.number), [1, 2])
        let user = try XCTUnwrap(v.messages[0].fields)
        XCTAssertEqual(user.map(\.field), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(user[0].value, "42")
        XCTAssertEqual(user[0].wire, "varint")
        XCTAssertEqual(user[1].text, "Ann")
        XCTAssertEqual(user[2].message?.first?.text, "Amsterdam")
        XCTAssertNil(user[3].bytes, "a bytes reading is withheld while the host is redacted")
        XCTAssertNil(user[3].packed, "its packed reading IS its bytes, so it is withheld with them")
        XCTAssertNotNil(user[3].withheld)
        XCTAssertNil(user[4].bytes, "bytes are withheld while the host is redacted")
        XCTAssertEqual(user[4].withheld, "4 bytes not shown: binary cannot be redacted, and this host is redacted (Settings ▸ MCP).")
        XCTAssertEqual(user[5].alternatives, ["float 1.0"])
        XCTAssertEqual(v.redaction, MCPRPCEgress.redactionShapeOnly)
        XCTAssertTrue(v.redaction.contains("SHAPE only"))
        XCTAssertEqual(v.trailers, [RPCHeaderPair(name: "x-trace", value: "abc")])

        let text = MCPTextFormat.rpcView(v)
        XCTAssertTrue(text.contains("gRPC-Web · protobuf · helloworld.Greeter / SayHello · uid=rpc1"), text)
        XCTAssertTrue(text.contains("Status: NOT_FOUND (5) — no such user · from the trailer frame · HTTP 200"), text)
        XCTAssertTrue(text.contains("  3 {\n    1: \"Amsterdam\"   [also parses as a message]\n    2: 1011 (varint)"), text)
    }

    /// A withheld bytes field once came back in full through its packed
    /// reading: every byte below 0x80 is a one-byte varint, so
    /// `01 "hunter2-pass"` read as [1, 104, 117, …] — the secret, in
    /// decimal. While the host is redacted, neither `bytes` nor `packed`
    /// may carry it, in the view or in the text the stdio tool prints.
    func testAWithheldBytesFieldDoesNotLeakThroughItsPackedReading() throws {
        let secret: [UInt8] = [0x01] + Array("hunter2-pass".utf8)
        let p = StubRPCProvider()
        var input = RPCFixtures.grpcWeb()
        input.requestBody = Data(RPCFixtures.frame(PB.len(9, secret)))
        p.rpc["leak"] = MCPSessionRPCFacts(host: "api.example.com", input: input)

        let v = try view(router(p), "/v1/sessions/leak/rpc")
        let field = try XCTUnwrap(v.messages.first?.fields?.first)
        XCTAssertEqual(field.field, 9)
        XCTAssertEqual(field.byteCount, secret.count)
        XCTAssertNil(field.bytes)
        XCTAssertNil(field.packed)
        XCTAssertEqual(field.withheld, "13 bytes not shown: binary cannot be redacted, and this host is redacted (Settings ▸ MCP).")
        let decimal = secret.map(String.init)
        let body = String(decoding: try get(router(p), "/v1/sessions/leak/rpc").body, as: UTF8.self)
        XCTAssertFalse(body.contains(decimal.joined(separator: "\",\"")), body)
        XCTAssertFalse(body.contains("hunter2"), body)
        let text = MCPTextFormat.rpcView(v)
        XCTAssertFalse(text.contains(decimal.joined(separator: ", ")), text)
        XCTAssertFalse(text.contains("hunter2"), text)

        // Excepted from redaction, both readings are the user's to see.
        let open = MCPRedactor(enabled: true, policy: MCPRedactionPolicy(exceptedHosts: ["api.example.com"]))
        let shown = try XCTUnwrap(try view(router(p, redactor: open), "/v1/sessions/leak/rpc").messages.first?.fields?.first)
        XCTAssertEqual(shown.bytes, Data(secret).base64EncodedString())
        XCTAssertEqual(shown.packed, decimal)
    }

    func testPaging() throws {
        let r = router(provider())
        let first = try view(r, "/v1/sessions/rpc1/rpc?limit=1")
        XCTAssertEqual(first.messages.count, 1)
        XCTAssertEqual(first.nextFrom, 2)
        let second = try view(r, "/v1/sessions/rpc1/rpc?from=2&limit=1")
        XCTAssertEqual(second.messages.first?.number, 2)
        XCTAssertNil(second.nextFrom)
    }

    func testAnExceptedHostGetsTheBytes() throws {
        let redactor = MCPRedactor(enabled: true, policy: MCPRedactionPolicy(exceptedHosts: ["api.example.com"]))
        let v = try view(router(provider(), redactor: redactor), "/v1/sessions/rpc1/rpc")
        let user = try XCTUnwrap(v.messages[0].fields)
        XCTAssertEqual(user[4].bytes, Data([0x00, 0xFF, 0xFE, 0x01]).base64EncodedString())
        XCTAssertNil(user[4].withheld)
        XCTAssertEqual(user[3].packed, ["1", "2", "300"], "the packed reading is offered once redaction is off for the host")
        XCTAssertEqual(v.redaction, MCPRPCEgress.redactionOff)
    }

    func testRefusals() throws {
        let r = router(provider())
        XCTAssertEqual(try get(r, "/v1/sessions/nope/rpc").status, 404)
        XCTAssertEqual(try get(r, "/v1/sessions/relay/rpc").status, 404)
        let live = try get(r, "/v1/sessions/live/rpc")
        XCTAssertEqual(live.status, 409)
        XCTAssertTrue(String(decoding: live.body, as: UTF8.self).contains("in_flight"))
        let plain = try get(r, "/v1/sessions/plain/rpc")
        XCTAssertEqual(plain.status, 400)
        XCTAssertTrue(String(decoding: plain.body, as: UTF8.self).contains("not_an_rpc"))
    }

    func testAShortSecretInAProtobufStringIsNotRecognisedAndTheViewSaysSo() throws {
        // Characterises the stated limit: no field names, so a short value
        // under what the .proto calls `password` passes; a vendor key does not.
        let p = StubRPCProvider()
        var input = RPCFixtures.grpcWeb()
        input.requestBody = Data(RPCFixtures.frame(PB.string(1, "ann") + PB.string(2, "hunter2") + PB.string(3, "sk_live_" + "abcdef0123456789")))
        p.rpc["login"] = MCPSessionRPCFacts(host: "api.example.com", input: input)
        let v = try view(router(p), "/v1/sessions/login/rpc")
        let fields = try XCTUnwrap(v.messages[0].fields)
        XCTAssertEqual(fields[1].text, "hunter2")
        XCTAssertEqual(fields[2].text, MCPRedactor.placeholder)
        XCTAssertTrue(v.redaction.contains("a short secret in a protobuf string field is NOT recognised"))
    }

    // MARK: list_sessions grpc=

    func testTheGRPCFilter() throws {
        let p = StubRPCProvider()
        p.summaries = [
            MCPSessionSummary(uid: "a", host: "h", method: "POST", url: "https://h/a.B/C", scheme: "https", statusCode: 200, grpcStatus: 5),
            MCPSessionSummary(uid: "b", host: "h", method: "POST", url: "https://h/a.B/D", scheme: "https", statusCode: 200, grpcStatus: 0),
            MCPSessionSummary(uid: "c", host: "h", method: "GET", url: "https://h/", scheme: "https", statusCode: 200),
        ]
        let r = router(p)
        func uids(_ query: String) throws -> [String] {
            let response = try get(r, "/v1/sessions?\(query)")
            XCTAssertEqual(response.status, 200, query)
            return try JSONDecoder().decode(MCPSessionPage.self, from: response.body).sessions.map(\.uid).sorted()
        }
        XCTAssertEqual(try uids("grpc=error"), ["a"])
        XCTAssertEqual(try uids("grpc=ok"), ["b"])
        XCTAssertEqual(try uids("grpc=NOT_FOUND"), ["a"])
        XCTAssertEqual(try uids("grpc=not_found"), ["a"])
        XCTAssertEqual(try uids("grpc=5"), ["a"])
        XCTAssertEqual(try uids("grpc=14"), [])
        let bad = try get(r, "/v1/sessions?grpc=banana")
        XCTAssertEqual(bad.status, 400, "refused, never dropped")
        XCTAssertTrue(String(decoding: bad.body, as: UTF8.self).contains("'grpc' must be"))

        XCTAssertEqual(MCPSessionFilter(grpc: "NOT_FOUND").summaryText, "grpc=NOT_FOUND")
        XCTAssertEqual(MCPBridgeClient.sessionsQuery(filter: MCPSessionFilter(grpc: "error"), limit: nil, cursor: nil),
                       [URLQueryItem(name: "grpc", value: "error")])
        XCTAssertTrue(MCPTextFormat.row(p.summaries[0]).contains("grpc=NOT_FOUND"))
        XCTAssertTrue(MCPTextFormat.row(p.summaries[1]).contains("grpc=OK"))
        XCTAssertFalse(MCPTextFormat.row(p.summaries[2]).contains("grpc="))
        XCTAssertTrue(MCPTextFormat.detail(MCPSessionDetail(summary: p.summaries[0])).contains("RPC status: NOT_FOUND (5) — get_session view=rpc"))
        XCTAssertFalse(MCPTextFormat.detail(MCPSessionDetail(summary: p.summaries[2])).contains("RPC status"))
    }
}
