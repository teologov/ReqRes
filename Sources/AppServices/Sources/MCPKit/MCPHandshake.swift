//
//  MCPHandshake.swift
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
import Security

/// The per-session rendezvous between the app's loopback bridge and the stdio
/// MCP binary: the app writes {port, token} to a 0600 file inside its container;
/// the client-spawned binary reads it. Same shape Proxyman and Xcode use.
public struct MCPHandshake: Codable, Equatable {
    public var version: Int
    public var port: UInt16
    public var token: String
    public var pid: Int32
    public var createdAt: Date

    public init(version: Int = 1, port: UInt16, token: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier, createdAt: Date = Date()) {
        self.version = version
        self.port = port
        self.token = token
        self.pid = pid
        self.createdAt = createdAt
    }
}

public enum MCPHandshakeFileError: Error, Equatable {
    case randomnessUnavailable
    case unreadable
}

public enum MCPHandshakeFile {
    public static let fileName = "mcp-handshake.json"

    /// 32 bytes of system randomness, base64url — the bearer token.
    public static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw MCPHandshakeFileError.randomnessUnavailable }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func write(_ handshake: MCPHandshake, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(handshake)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(from url: URL) throws -> MCPHandshake {
        guard let data = try? Data(contentsOf: url) else { throw MCPHandshakeFileError.unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MCPHandshake.self, from: data)
    }

    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
