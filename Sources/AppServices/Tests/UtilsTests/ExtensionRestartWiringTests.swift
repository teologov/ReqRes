//
//  ExtensionRestartWiringTests.swift
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
//  F21 (2026-10-26): `ExtensionSetupStatus.needsRestart` is entered in one
//  place only — macOS saying the new extension loads after a reboot
//  (ActivationDelegate.handleWillCompleteAfterReboot) — and the Restart
//  Recommended alert and the toolbar's Restart Now restart the Mac. The setup
//  checklist said "Restart ReqRes" and its button relaunched the app, which
//  cleared the flag while the old extension kept running. Sources/UI has no
//  test target; this reads the two files.
//

import XCTest

final class ExtensionRestartWiringTests: XCTestCase {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.sourcesRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    func testTheSetupStepAsksForTheMacToRestart() throws {
        let view = try source("UI/Views/Session/ExtensionSetupView.swift")
        XCTAssertTrue(view.contains(#"case .needsRestart:         return "Restart your Mac to finish""#))
        XCTAssertTrue(view.contains("macOS loads the new version only after your Mac restarts. Restarting ReqRes alone does not."))
        XCTAssertTrue(view.contains(#"case .needsRestart:         return "Restart Now""#))
        XCTAssertFalse(view.contains("Restart ReqRes"))
        XCTAssertFalse(view.contains("Restart the app"))
    }

    func testTheStepsButtonRestartsTheMacNotTheApp() throws {
        let view = try source("UI/Views/SessionContentView.swift")
        XCTAssertTrue(view.contains("case .needsRestart: restartComputer()"))
        XCTAssertTrue(view.contains("private func restartComputer()"))
        XCTAssertFalse(view.contains("restartApp"), "a relaunch clears the flag and keeps the old extension")
    }
}
