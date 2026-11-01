//
//  ReleaseVersionTests.swift
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

/// macOS replaces an approved system extension only when the new bundle's
/// version is HIGHER; an equal one keeps the old binary running behind the
/// new app. `Scripts/extension-version-check.sh` refuses an install that is
/// not; this pins the floor in the project itself. Raise the floor whenever
/// a build is installed.
final class ReleaseVersionTests: XCTestCase {
    /// Builds already installed: every later build of either target must be
    /// above them, or macOS keeps the installed extension running behind the
    /// new app.
    static let installedAppBuild = 61
    static let installedExtensionBuild = 25

    private struct Configuration { let bundleID: String; let build: Int; let marketing: String }

    private func configurations() throws -> [Configuration] {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ReqRes.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)
        return text.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst().compactMap { block in
            func value(_ key: String) -> String? {
                guard let line = block.components(separatedBy: "\n").first(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + " = ")
                }) else { return nil }
                return line.components(separatedBy: " = ").last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ;\"\t"))
            }
            guard let id = value("PRODUCT_BUNDLE_IDENTIFIER"),
                  let build = value("CURRENT_PROJECT_VERSION").flatMap(Int.init),
                  let marketing = value("MARKETING_VERSION") else { return nil }
            return Configuration(bundleID: id, build: build, marketing: marketing)
        }
    }

    func testTheExtensionIsAboveTheInstalledOne() throws {
        let tunnel = try configurations().filter { $0.bundleID == "com.oloapps.ReqRes.vpn-tunnel" }
        XCTAssertEqual(tunnel.count, 2, "Debug and Release")
        for config in tunnel {
            XCTAssertGreaterThan(config.build, Self.installedExtensionBuild,
                                 "macOS would keep the installed 1.1.0/\(Self.installedExtensionBuild) extension")
        }
        XCTAssertEqual(Set(tunnel.map(\.build)).count, 1, "Debug and Release must agree")
    }

    func testTheAppIsAboveTheInstalledOne() throws {
        let app = try configurations().filter { $0.bundleID == "com.oloapps.ReqRes" }
        XCTAssertEqual(app.count, 2, "Debug and Release")
        for config in app {
            XCTAssertGreaterThan(config.build, Self.installedAppBuild,
                                 "the post-update extension reset keys on CFBundleVersion changing")
        }
        XCTAssertEqual(Set(app.map(\.build)).count, 1)
    }

    func testTheAppAndItsExtensionShareAMarketingVersion() throws {
        let all = try configurations().filter { $0.bundleID.hasPrefix("com.oloapps.ReqRes") && !$0.bundleID.contains("Tests") }
        XCTAssertEqual(Set(all.map(\.marketing)).count, 1, "\(all.map(\.marketing))")
    }
}
