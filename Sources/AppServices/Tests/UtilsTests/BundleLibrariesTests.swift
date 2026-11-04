//
//  BundleLibrariesTests.swift
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
//  macOS runs the system extension from /Library/SystemExtensions/<UUID>/,
//  never from inside the app, so the extension loads only the libraries its
//  own bundle carries and the ones macOS provides. 1.1.0 (build 62) shipped an
//  extension whose core loads @rpath/libswiftCompatibilitySpan.dylib: macOS 26
//  and later provide it, macOS 14 and 15 do not, and Xcode copies it into an
//  app's bundle on its own but into a system extension's only when the target
//  asks. On macOS 14 and 15 the extension died at launch, so capture never
//  started. These tests pin the setting that makes Xcode copy it, the check
//  that refuses a build without it, and the release scripts that run that
//  check.
//

import XCTest

final class BundleLibrariesTests: XCTestCase {
    /// The repository root: this file is Sources/AppServices/Tests/UtilsTests/….
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static let check = root.appendingPathComponent("Scripts/bundle-libraries-check.sh")

    /// The build settings of every configuration of one target, by bundle id.
    private func settings(of bundleID: String) throws -> [[String: String]] {
        let project = Self.root.appendingPathComponent("Sources/ReqRes.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)
        return text.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst().compactMap { block in
            guard let body = block.components(separatedBy: "buildSettings = {").dropFirst().first?
                .components(separatedBy: "\n\t\t\t};").first else { return nil }
            var values: [String: String] = [:]
            for line in body.components(separatedBy: "\n") {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
                guard parts.count == 2 else { continue }
                values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " ;\"\t"))
            }
            return values["PRODUCT_BUNDLE_IDENTIFIER"] == bundleID ? values : nil
        }
    }

    func testTheSystemExtensionCarriesTheSwiftLibrariesItsCoreNeeds() throws {
        let tunnel = try settings(of: "com.oloapps.ReqRes.vpn-tunnel")
        XCTAssertEqual(tunnel.count, 2, "Debug and Release")
        for config in tunnel {
            XCTAssertEqual(config["ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES"], "YES",
                           "without it Xcode copies no Swift back-deployment library into the system extension, and on macOS 14 and 15 its core cannot load")
        }
    }

    func testTheCheckPassesItsSelftest() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") else {
            throw XCTSkip("the selftest builds its fixtures with clang")
        }
        let result = try run("/bin/bash", [Self.check.path, "--selftest"])
        XCTAssertEqual(result.status, 0, result.output)
        for line in ["a system extension cannot borrow the app's copy",
                     "a library found only outside the bundle (as in this Mac's /usr/lib/swift) is refused",
                     "a weak library may be absent"] {
            XCTAssertTrue(result.output.contains("ok    " + line), "missing or failing: \(line)\n\(result.output)")
        }
        XCTAssertTrue(result.output.contains(" 0 failed"), result.output)
    }

    func testEveryReleaseBuildRunsTheCheck() throws {
        for (script, calls) in [("Scripts/dev-install.sh", 1), ("Scripts/make-dmg.sh", 2)] {
            let text = try String(contentsOf: Self.root.appendingPathComponent(script), encoding: .utf8)
            let invocations = text.components(separatedBy: "\n").filter { line in
                let code = line.trimmingCharacters(in: .whitespaces)
                return !code.hasPrefix("#") && code.contains("bundle-libraries-check.sh\"")
            }
            XCTAssertEqual(invocations.count, calls, "\(script) must run bundle-libraries-check.sh \(calls)×: \(invocations)")
            for line in invocations {
                XCTAssertTrue(line.contains("\\"), "\(script): the check's failure must stop the script: \(line)")
            }
        }
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
