//
//  MCPBridgeClientTests.swift
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

final class MCPBridgeClientTests: XCTestCase {
    private let handshake = MCPHandshake(port: 8123, token: "tok-123")

    private var client: MCPBridgeClient { MCPBridgeClient(handshake: handshake) }

    func testRequestTargetsLoopbackPortFromHandshake() {
        let url = client.url(path: "/v1/sessions", query: [URLQueryItem(name: "host", value: "api.example.com")])
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, 8123)
        XCTAssertEqual(url.path, "/v1/sessions")
        XCTAssertTrue(url.query?.contains("host=api.example.com") ?? false)
    }

    func testRequestCarriesBearerToken() {
        let request = client.request(path: "/v1/status")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
    }

    /// Every filter field has to reach the query string, or the router never
    /// sees it and the agent reads an unfiltered page as a filtered one — the
    /// `app` regression, one layer down. Mirror enumerates the REAL fields so
    /// a field added to `MCPSessionFilter` without a query item fails here
    /// instead of silently not filtering.
    func testSessionsQuerySerialisesEveryFilterField() throws {
        let filter = MCPSessionFilter(
            host: "api.example.com", method: "GET", status: "5xx", scheme: "https",
            urlContains: "/login", app: "claude", pid: 9437, country: "US", outcome: "failed", grpc: "error", proto: "h2"
        )
        let fieldCount = Mirror(reflecting: filter).children.count
        XCTAssertGreaterThan(fieldCount, 0, "Mirror found no fields on MCPSessionFilter")
        let allSet = Mirror(reflecting: filter).children.allSatisfy { child in
            // Every field is Optional; an unset one prints as "nil".
            String(describing: child.value) != "nil"
        }
        XCTAssertTrue(allSet, "This test must set every MCPSessionFilter field — a new field was added; set it here so its serialisation is checked.")

        let query = MCPBridgeClient.sessionsQuery(filter: filter, limit: 25, cursor: "s9")
        let byName = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["host"], "api.example.com")
        XCTAssertEqual(byName["method"], "GET")
        XCTAssertEqual(byName["status"], "5xx")
        XCTAssertEqual(byName["scheme"], "https")
        XCTAssertEqual(byName["url_contains"], "/login")
        XCTAssertEqual(byName["app"], "claude")
        XCTAssertEqual(byName["pid"], "9437")
        XCTAssertEqual(byName["country"], "US")
        XCTAssertEqual(byName["outcome"], "failed")
        XCTAssertEqual(byName["grpc"], "error")
        XCTAssertEqual(byName["proto"], "h2")
        XCTAssertEqual(byName["limit"], "25")
        XCTAssertEqual(byName["cursor"], "s9")
        // Filter items (everything but paging) must be one per field.
        XCTAssertEqual(query.count - 2, fieldCount, "A filter field is not being serialised into the /v1/sessions query.")

        // And the router reads back exactly what the client sent.
        let roundTripped = try MCPSessionFilter(queryItems: query)
        XCTAssertEqual(roundTripped, filter)
    }

    func testSessionsQueryOmitsUnsetFilters() {
        let query = MCPBridgeClient.sessionsQuery(filter: MCPSessionFilter(app: "curl"), limit: nil, cursor: nil)
        XCTAssertEqual(query.map(\.name), ["app"])
    }

    func testDecodeSurfacesUnauthorized() {
        XCTAssertThrowsError(try MCPBridgeClient.decode(MCPBridgeStatus.self, data: Data(), status: 401)) { error in
            XCTAssertEqual(error as? MCPBridgeClient.ClientError, .unauthorized)
        }
    }

    func testDecodeSurfacesBridgeErrorMessage() {
        let payload = MCPHTTPResponse.error(status: 404, code: "not_found", message: "No session with uid x")
        let body = try! XCTUnwrap(parseRawResponse(payload)).body
        XCTAssertThrowsError(try MCPBridgeClient.decode(MCPSessionDetail.self, data: body, status: 404)) { error in
            guard case .badResponse(let status, let message)? = error as? MCPBridgeClient.ClientError else {
                return XCTFail("expected badResponse")
            }
            XCTAssertEqual(status, 404)
            XCTAssertTrue(message.contains("No session with uid"))
        }
    }

    func testDecodeRoundTripsARealBridgePayload() throws {
        // Encode exactly as the router does, then decode as the client does.
        let page = MCPSessionPage(
            sessions: [makeSession(uid: "s1")],
            nextCursor: "s1",
            totalMatched: 4,
            note: "3 more"
        )
        let response = MCPHTTPResponse.json(status: 200, page)
        let body = try XCTUnwrap(parseRawResponse(response)).body
        let decoded = try MCPBridgeClient.decode(MCPSessionPage.self, data: body, status: 200)
        XCTAssertEqual(decoded.sessions.map(\.uid), ["s1"])
        XCTAssertEqual(decoded.totalMatched, 4)
        XCTAssertEqual(decoded.nextCursor, "s1")
    }

    func testHandshakeLookupPrefersAppGroupThenContainer() {
        let urls = MCPBridgeClient.defaultHandshakeURLs(
            appGroupIdentifier: "ZUP9ZNBCHM.com.oloapps.ReqRes",
            bundleIdentifier: "com.oloapps.ReqRes"
        )
        // Unsandboxed (this test) the system-resolved group container and the
        // home-based path coincide and collapse into one entry.
        XCTAssertTrue((2...3).contains(urls.count))
        XCTAssertTrue(urls[0].path.contains("Group Containers/ZUP9ZNBCHM.com.oloapps.ReqRes"))
        XCTAssertTrue(urls.last!.path.contains("Containers/com.oloapps.ReqRes/Data"))
        XCTAssertTrue(urls.allSatisfy { $0.lastPathComponent == MCPHandshakeFile.fileName })
        XCTAssertEqual(Set(urls.map(\.path)).count, urls.count, "no duplicates")
    }

    func testMissingHandshakeReportsAppNotRunning() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        XCTAssertThrowsError(try MCPBridgeClient.locateHandshake(in: [missing])) { error in
            guard case .appNotRunning? = error as? MCPBridgeClient.ClientError else {
                return XCTFail("expected appNotRunning")
            }
            // The message must tell the agent what a human has to do — and
            // where: the bridge is OFF by default, so "launch it" alone sent
            // first-time users looking at an app that was already running.
            let description = (error as? MCPBridgeClient.ClientError)?.errorDescription ?? ""
            XCTAssertTrue(description.contains("Settings → MCP"), description)
            XCTAssertTrue(description.contains("Enable the AI bridge"), description)
        }
    }

    func testLocateHandshakeFallsThroughToASecondCandidate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-client-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing.json")
        let present = dir.appendingPathComponent(MCPHandshakeFile.fileName)
        try MCPHandshakeFile.write(handshake, to: present)

        let found = try MCPBridgeClient.locateHandshake(in: [missing, present])
        XCTAssertEqual(found.port, 8123)
        XCTAssertEqual(found.token, "tok-123")
    }
}
