//
//  ConverterCheckTests.swift
//  AppServices
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
//  Runs the converter's --check against the committed resources: the binary
//  must be the canonical encoding of its own rows, the GeoJSON canonical and
//  2-decimal, the centroids what the outlines + hand tables produce, and
//  PROVENANCE.md must name the binary's data month. A hand edit to any
//  resource fails here.
//

import XCTest
@testable import GeoKit

final class ConverterCheckTests: XCTestCase {

    private var repoRoot: URL {
        // Tests/GeoKitTests/ConverterCheckTests.swift → repository root is five levels up.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    func testConverterCheckPasses() throws {
        let script = repoRoot.appendingPathComponent("Scripts/geo/build-geo-resources.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("converter not found at \(script.path)")
        }
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("python3 is not installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--check"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "build-geo-resources.py --check failed:\n\(text)")
        XCTAssertTrue(text.hasPrefix("ok:"), text)
        // The month the converter read back from the binary is the one the Swift reader sees.
        let table = try IPCountryTable.bundled()
        XCTAssertTrue(text.contains("data month \(table.dataMonth)"), text)
    }
}
