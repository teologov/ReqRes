//
//  MCPHTTPTests.swift
//  AppServices
//
//  Created by OloApps on 8/26/26.
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

final class MCPHTTPTests: XCTestCase {
    func testParsesGetWithHeadersAndQuery() throws {
        let raw = "GET /v1/sessions?host=api.example.com&limit=5 HTTP/1.1\r\nHost: 127.0.0.1:8123\r\nAuthorization: Bearer tok\r\n\r\n"
        guard case .request(let request) = MCPHTTPParser.parse(Data(raw.utf8)) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/sessions")
        XCTAssertEqual(request.headers["host"], "127.0.0.1:8123")
        XCTAssertEqual(request.headers["authorization"], "Bearer tok")
        XCTAssertEqual(request.queryItems.first(where: { $0.name == "limit" })?.value, "5")
    }

    func testIncompleteHeadersAskForMoreData() {
        let raw = "GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1"
        XCTAssertEqual(MCPHTTPParser.parse(Data(raw.utf8)), .needMoreData)
    }

    func testBodyRespectsContentLength() throws {
        let body = #"{"a":1}"#
        let raw = "POST /v1/x HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .request(let request) = MCPHTTPParser.parse(Data(raw.utf8)) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)

        let partial = "POST /v1/x HTTP/1.1\r\nContent-Length: 100\r\n\r\n\(body)"
        XCTAssertEqual(MCPHTTPParser.parse(Data(partial.utf8)), .needMoreData)
    }

    func testMalformedRequestLineIsInvalid() {
        let raw = "TOTALLY BROKEN\r\n\r\n"
        guard case .invalid = MCPHTTPParser.parse(Data(raw.utf8)) else {
            return XCTFail("expected invalid")
        }
    }

    func testChunkedTransferIsRejected() {
        let raw = "POST /v1/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        guard case .invalid = MCPHTTPParser.parse(Data(raw.utf8)) else {
            return XCTFail("expected invalid")
        }
    }

    func testOversizedHeadersAreInvalidNotPending() {
        let raw = "GET / HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: MCPHTTPParser.maxHeaderBytes + 1)
        guard case .invalid = MCPHTTPParser.parse(Data(raw.utf8)) else {
            return XCTFail("expected invalid")
        }
    }

    func testResponseCarriesFramingHeaders() throws {
        struct Payload: Encodable { let ok: Bool }
        let data = MCPHTTPResponse.json(status: 200, Payload(ok: true))
        let parsed = try XCTUnwrap(parseRawResponse(data))
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.headers["connection"], "close")
        XCTAssertEqual(parsed.headers["content-type"], "application/json")
        XCTAssertEqual(parsed.headers["content-length"], String(parsed.body.count))
        XCTAssertEqual(parsed.json?["ok"] as? Bool, true)
    }

    func testErrorResponseShape() throws {
        let data = MCPHTTPResponse.error(status: 404, code: "not_found", message: "nope")
        let parsed = try XCTUnwrap(parseRawResponse(data))
        XCTAssertEqual(parsed.status, 404)
        let error = parsed.json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "not_found")
        XCTAssertEqual(error?["message"] as? String, "nope")
    }
}
