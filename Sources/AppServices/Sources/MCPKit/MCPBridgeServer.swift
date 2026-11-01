//
//  MCPBridgeServer.swift
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

import Foundation
import Network

/// Loopback-only HTTP listener for the bridge. Binds 127.0.0.1 on an ephemeral
/// port (published via the handshake file), one short-lived connection per
/// request. This is a NEW listener — the 50001 extension bus is untouched.
public final class MCPBridgeServer {
    public enum ServerError: Error, Equatable {
        case startTimedOut
        case failed(String)
    }

    private let router: MCPBridgeRouter
    /// Owns `listener`, `connections` and `port`: every mutation happens here,
    /// whichever thread asked (Settings' toggle runs on its own queue).
    private let queue = DispatchQueue(label: "com.oloapps.ReqRes.mcp-bridge")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var boundPort: UInt16?

    /// A write BLOCKS its connection's queue while the human decides, so each
    /// connection gets its own — otherwise one pending approval stalls every
    /// other client's reads until they time out.
    private func makeConnectionQueue() -> DispatchQueue {
        DispatchQueue(label: "com.oloapps.ReqRes.mcp-connection", target: .global(qos: .userInitiated))
    }

    public var port: UInt16? { queue.sync { boundPort } }

    public init(router: MCPBridgeRouter) {
        self.router = router
    }

    /// Starts listening and returns the bound port. Blocks the calling thread
    /// briefly (call from a background queue, not the main thread).
    @discardableResult
    public func start(readyTimeout: TimeInterval = 5) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: parameters)
        self.listener = listener

        let readiness = DispatchSemaphore(value: 0)
        var startError: ServerError?

        listener.stateUpdateHandler = { [weak self] state in
            // Runs on `queue` — the listener was started on it.
            switch state {
            case .ready:
                self?.boundPort = listener.port?.rawValue
                readiness.signal()
            case .failed(let error):
                startError = .failed(String(describing: error))
                self?.tearDown()
                readiness.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard readiness.wait(timeout: .now() + readyTimeout) == .success else {
            stop()
            throw ServerError.startTimedOut
        }
        if let startError {
            stop()
            throw startError
        }
        guard let port = self.port else {
            stop()
            throw ServerError.failed("listener ready without a port")
        }
        return port
    }

    public func stop() {
        queue.sync { tearDown() }
    }

    /// Must run on `queue`.
    private func tearDown() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: makeConnectionQueue())
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch MCPHTTPParser.parse(buffer) {
            case .request(let request):
                self.send(self.router.respond(to: request), on: connection)
            case .invalid(let reason):
                self.send(MCPHTTPResponse.error(status: 400, code: "bad_request", message: reason), on: connection)
            case .needMoreData:
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
