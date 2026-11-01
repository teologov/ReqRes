//
//  PerInstallCAStatusTests.swift
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
//  Step C8's shell half (protocol PRD 4 Phase 2.1): every install now has its
//  own CA, so two things the app used to be able to ignore become states an
//  agent and the user must be told about — an OLDER "ReqRes CA" still in the
//  keychain (the 1.0.x shared one, whose private key is public), and a CA
//  file exported for command-line tools that holds a CA this Mac no longer
//  uses. `capture_environment` and `diagnose_setup` read both from the status.
//

import XCTest
@testable import MCPKit

final class PerInstallCAStatusTests: XCTestCase {
    private let current = String(repeating: "c", count: 64)
    private let older = String(repeating: "0", count: 64)

    private func status(exportedPath: String? = "/Users/dev/reqres-ca.pem",
                        exportOutdated: Bool? = nil,
                        outdatedInstalled: Int? = nil) -> MCPBridgeStatus {
        MCPBridgeStatus(
            captureActive: true,
            vpnStatus: "connected",
            extensionStatus: "ready",
            caCertificateInstalled: true,
            caCertificateTrusted: true,
            sessionCount: 5,
            appVersion: "1.1.0",
            caExportedPath: exportedPath,
            caExportedCertificateOutdated: exportOutdated,
            caOutdatedCertificatesInstalled: outdatedInstalled,
            caFingerprintSHA256: "5d41402abc4b2a76b9719d911017c592aa5d41402abc4b2a76b9719d911017c5"
        )
    }

    private func facts(_ status: MCPBridgeStatus) -> MCPSetupFacts {
        MCPSetupFacts(status: status, runningFromApplications: true, proxyPort: 8034, proxyPortListening: true,
                      freeInspectionsUsed: 0, freeInspectionsLimit: 10, licensed: false,
                      lastSessionAt: Date(timeIntervalSince1970: 1_700_000_000),
                      now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Export freshness

    func testAnExportIsCurrentOnlyWhenItsFingerprintIsTheInstallsCA() {
        typealias Lines = CaptureEnvironmentLines
        XCTAssertEqual(Lines.exportFreshness(exportedPath: nil, exportedFingerprint: nil, currentFingerprint: current), .none)
        XCTAssertEqual(Lines.exportFreshness(exportedPath: "  ", exportedFingerprint: current, currentFingerprint: current), .none)
        XCTAssertEqual(Lines.exportFreshness(exportedPath: "/a.pem", exportedFingerprint: current, currentFingerprint: current), .current)
        XCTAssertEqual(Lines.exportFreshness(exportedPath: "/a.pem", exportedFingerprint: current.uppercased(), currentFingerprint: current), .current)
        XCTAssertEqual(Lines.exportFreshness(exportedPath: "/a.pem", exportedFingerprint: older, currentFingerprint: current), .outdated)
        // Exported by a build that stored no fingerprint: before 1.1.0, i.e.
        // the 1.0.x shared certificate.
        XCTAssertEqual(Lines.exportFreshness(exportedPath: "/a.pem", exportedFingerprint: nil, currentFingerprint: current), .outdated)
        XCTAssertEqual(Lines.exportFreshness(exportedPath: "/a.pem", exportedFingerprint: "", currentFingerprint: current), .outdated)
        // No CA to compare with.
        XCTAssertEqual(Lines.exportFreshness(exportedPath: "/a.pem", exportedFingerprint: current, currentFingerprint: nil), .unknown)
        XCTAssertEqual(Lines.exportedFingerprintDefaultsKey, "CaptureCAExportedFingerprint",
                       "the app's pane and its MCP status adapter read this key; renaming it forgets every export")
    }

    /// A helper and an app of different builds still decode each other.
    func testAStatusWithoutTheNewFieldsStillDecodes() throws {
        let old = #"{"captureActive":true,"vpnStatus":"connected","extensionStatus":"ready","sessionCount":1,"appVersion":"1.0.5","bridgeVersion":2}"#
        let decoded = try JSONDecoder().decode(MCPBridgeStatus.self, from: Data(old.utf8))
        XCTAssertNil(decoded.caExportedCertificateOutdated)
        XCTAssertNil(decoded.caOutdatedCertificatesInstalled)
        let round = try JSONDecoder().decode(MCPBridgeStatus.self,
                                             from: JSONEncoder().encode(status(exportOutdated: true, outdatedInstalled: 2)))
        XCTAssertEqual(round.caExportedCertificateOutdated, true)
        XCTAssertEqual(round.caOutdatedCertificatesInstalled, 2)
    }

    // MARK: - capture_environment

    /// An outdated export is never printed as the certificate path: every
    /// tool pointed at it would fail TLS. The lines fall back to the
    /// keychain step, and a note names the file and says to export again.
    func testAnOutdatedExportIsNotPrintedAndTheUserIsToldToExportAgain() {
        let text = MCPCaptureEnvironment.render(status: status(exportOutdated: true))
        let lines = text.components(separatedBy: "\n")
        XCTAssertFalse(lines.contains { $0.hasPrefix("export NODE_EXTRA_CA_CERTS=/Users/dev/reqres-ca.pem") },
                       "the outdated file was printed as the CA: \(text)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("export NODE_EXTRA_CA_CERTS=~/reqres-ca.pem") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("security find-certificate") }, "no keychain step to fall back on")
        XCTAssertTrue(text.contains("/Users/dev/reqres-ca.pem, holds an older ReqRes CA"), text)
        XCTAssertTrue(text.contains("export it again from ReqRes ▸ Settings ▸ Capture"), text)

        // A current export is printed as before, with no such note.
        let fresh = MCPCaptureEnvironment.render(status: status(exportOutdated: false))
        XCTAssertTrue(fresh.components(separatedBy: "\n").contains { $0.hasPrefix("export NODE_EXTRA_CA_CERTS=/Users/dev/reqres-ca.pem") })
        XCTAssertFalse(fresh.contains("older ReqRes CA"))
    }

    func testAnOlderCAInTheKeychainIsNamedBeforeTheSecurityLineIsTrusted() {
        let text = MCPCaptureEnvironment.render(status: status(exportedPath: nil, outdatedInstalled: 1))
        XCTAssertTrue(text.contains("An older ReqRes CA is still in the login keychain"), text)
        XCTAssertTrue(text.contains("click Replace Old Certificate"), text)
        XCTAssertFalse(MCPCaptureEnvironment.render(status: status(exportedPath: nil, outdatedInstalled: 0)).contains("older ReqRes CA"))
    }

    // MARK: - diagnose_setup

    func testAnOlderCAInTheKeychainIsAWarningWithTheButtonToPress() {
        let report = MCPSetupDiagnosis.report(facts(status(exportedPath: nil, outdatedInstalled: 1)))
        let check = report.checks.first { $0.id == "certificate_outdated" }
        XCTAssertEqual(check?.state, .warning)
        XCTAssertTrue(check?.detail.contains("private key was published") == true, "\(String(describing: check?.detail))")
        XCTAssertEqual(check?.fix, "Ask the user to open ReqRes ▸ Settings ▸ Certificate and click Replace Old Certificate.")
        XCTAssertEqual(report.verdict, check?.detail, "a trusted public key is worth the verdict")
        XCTAssertNil(report.blockingCheckId, "capture itself works")

        let two = MCPSetupDiagnosis.report(facts(status(exportedPath: nil, outdatedInstalled: 2)))
        XCTAssertTrue(two.checks.first { $0.id == "certificate_outdated" }?.detail.hasPrefix("2 older ReqRes CA certificates") == true)

        for count in [nil, 0] as [Int?] {
            let report = MCPSetupDiagnosis.report(facts(status(exportedPath: nil, outdatedInstalled: count)))
            XCTAssertNil(report.checks.first { $0.id == "certificate_outdated" }, "count=\(String(describing: count))")
        }
    }

    func testAnOutdatedExportIsAWarningThatNeverBecomesTheVerdict() {
        let report = MCPSetupDiagnosis.report(facts(status(exportOutdated: true)))
        let check = report.checks.first { $0.id == "certificate_export" }
        XCTAssertEqual(check?.state, .warning)
        XCTAssertTrue(check?.detail.contains("(/Users/dev/reqres-ca.pem)") == true, "\(String(describing: check?.detail))")
        XCTAssertTrue(check?.fix?.contains("export it again") == true)
        XCTAssertNotEqual(report.verdict, check?.detail, "a stale file for CLI tools is not what is wrong with capture")

        for outdated in [nil, false] as [Bool?] {
            XCTAssertNil(MCPSetupDiagnosis.report(facts(status(exportOutdated: outdated))).checks.first { $0.id == "certificate_export" })
        }
    }

    /// Both sit with the other CA checks, before the free tier and traffic.
    func testTheCAChecksStayTogether() {
        let ids = MCPSetupDiagnosis.report(facts(status(exportOutdated: true, outdatedInstalled: 1))).checks.map(\.id)
        let trusted = ids.firstIndex(of: "certificate_trusted")!
        XCTAssertEqual(Array(ids[trusted...].prefix(3)), ["certificate_trusted", "certificate_outdated", "certificate_export"])
        XCTAssertEqual(ids.last, "proxy_aware_clients")
    }
}
