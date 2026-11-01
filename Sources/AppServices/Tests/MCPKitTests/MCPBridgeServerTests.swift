//
//  MCPBridgeServerTests.swift
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
import Network
@testable import MCPKit

/// End-to-end over a real loopback socket: proves the listener binds 127.0.0.1,
/// enforces auth, and serves live data through the full HTTP path.
final class MCPBridgeServerTests: XCTestCase {
    var server: MCPBridgeServer!

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testServesStatusOverLoopback() throws {
        let sessions = StubSessionProvider(summaries: [makeSession(uid: "s1")])
        let router = MCPBridgeRouter(token: "tok", sessions: sessions, status: StubStatusProvider())
        server = MCPBridgeServer(router: router)
        let port = try server.start()
        XCTAssertGreaterThan(port, 0)

        let response = try roundTrip(
            port: port,
            request: "GET /v1/status HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer tok\r\n\r\n"
        )
        let parsed = try XCTUnwrap(parseRawResponse(response))
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.json?["extensionStatus"] as? String, "ready")
    }

    func testRejectsUnauthenticatedOverLoopback() throws {
        let router = MCPBridgeRouter(token: "tok", sessions: StubSessionProvider(), status: StubStatusProvider())
        server = MCPBridgeServer(router: router)
        let port = try server.start()

        let response = try roundTrip(
            port: port,
            request: "GET /v1/status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )
        XCTAssertEqual(parseRawResponse(response)?.status, 401)
    }

    func testStopReleasesThePort() throws {
        let router = MCPBridgeRouter(token: "tok", sessions: StubSessionProvider(), status: StubStatusProvider())
        server = MCPBridgeServer(router: router)
        _ = try server.start()
        server.stop()
        XCTAssertNil(server.port)
    }

    // MARK: - Raw loopback client

    private func roundTrip(port: UInt16, request: String, timeout: TimeInterval = 5) throws -> Data {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let queue = DispatchQueue(label: "mcp-test-client")
        let done = expectation(description: "round trip")
        var received = Data()
        var failure: Error?

        func readLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data { received.append(data) }
                if let error { failure = error; done.fulfill(); return }
                if isComplete { done.fulfill(); return }
                readLoop()
            }
        }

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error { failure = error; done.fulfill(); return }
                    readLoop()
                })
            }
        }
        connection.start(queue: queue)

        wait(for: [done], timeout: timeout)
        connection.cancel()
        if let failure { throw failure }
        return received
    }

    /// A write blocks its connection while the human decides; a second client
    /// must still be served. (Before per-connection queues, every other
    /// request sat behind the approval and timed out.)
    func testASlowRequestDoesNotStallOtherConnections() throws {
        let slow = DispatchSemaphore(value: 0)
        let router = MCPBridgeRouter(
            token: "tok",
            sessions: StubSessionProvider(),
            status: BlockingStatusProvider(gate: slow)
        )
        let server = MCPBridgeServer(router: router)
        let port = try server.start()
        defer { server.stop() }

        // Request 1 blocks inside the router until `slow` is signalled.
        let blocked = expectation(description: "blocked request answered")
        DispatchQueue.global().async {
            _ = Self.get("http://127.0.0.1:\(port)/v1/status", token: "tok")
            blocked.fulfill()
        }
        // Request 2 must be answered while request 1 is still in the router.
        let free = expectation(description: "second client answered")
        DispatchQueue.global().async {
            let status = Self.get("http://127.0.0.1:\(port)/v1/health", token: nil)
            XCTAssertEqual(status, 200)
            free.fulfill()
        }
        wait(for: [free], timeout: 5)
        slow.signal()
        wait(for: [blocked], timeout: 5)
    }

    private static func get(_ url: String, token: String?) -> Int {
        var request = URLRequest(url: URL(string: url)!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 10
        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return status
    }
}

/// Stands in for a write waiting on the approval panel.
private final class BlockingStatusProvider: MCPStatusProviding {
    private let gate: DispatchSemaphore
    init(gate: DispatchSemaphore) { self.gate = gate }

    func bridgeStatus() -> MCPBridgeStatus {
        _ = gate.wait(timeout: .now() + 10)
        return MCPBridgeStatus(captureActive: false, vpnStatus: "disconnected", extensionStatus: "ready")
    }
}
