//
//  MCPHandshakeTests.swift
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

final class MCPHandshakeTests: XCTestCase {
    func testTokensAreUniqueAndURLSafe() throws {
        let first = try MCPHandshakeFile.generateToken()
        let second = try MCPHandshakeFile.generateToken()
        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 40)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(first.unicodeScalars.allSatisfy(allowed.contains))
    }

    func testWriteReadRoundtripAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpkit-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPHandshakeFile.fileName)

        let handshake = MCPHandshake(port: 8123, token: try MCPHandshakeFile.generateToken())
        try MCPHandshakeFile.write(handshake, to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)

        let read = try MCPHandshakeFile.read(from: url)
        XCTAssertEqual(read.port, handshake.port)
        XCTAssertEqual(read.token, handshake.token)
        XCTAssertEqual(read.version, 1)

        MCPHandshakeFile.remove(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReadFromMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertThrowsError(try MCPHandshakeFile.read(from: url))
    }
}
