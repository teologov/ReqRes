//
//  PinnedRefusalCopyTests.swift
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
//  What ReqRes tells a person and an agent about an app that refused ReqRes's
//  certificate. Since learned pins (core cc97856, build 47) the refusal is
//  remembered with the app and the domain, and the app's later connections
//  there are passed through untouched as rows marked SSL pinned
//  (HandshakeCompletionHandler.reportRefusal → LearnedPins.learn), so the app
//  works on its next try; excluding the host only stops recording it. Until
//  this test, four texts still said such an app worked only once its host was
//  excluded: the tls_rejections fix in both voices, the exclude_host tool
//  description and SKILL.md. A command-line tool that refused because it lacked
//  the CA is remembered the same way, so once it has the CA its entry must be
//  forgotten.
//

import XCTest
@testable import MCPKit

final class PinnedRefusalCopyTests: XCTestCase {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private var server: String { get throws { try source("Sources/reqres-mcp/ReqResMCPServer.swift") } }

    /// SKILL.md as a reader takes it: wrapped lines joined, code quotes dropped.
    private var skill: String { get throws { flat(try source("Sources/reqres-mcp/SKILL.md")) } }

    private func flat(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func check() throws -> MCPSetupCheck {
        let report = MCPSetupDiagnosis.report(MCPSetupFacts(
            status: MCPBridgeStatus(captureActive: true, vpnStatus: "connected", extensionStatus: "ready",
                                    caCertificateInstalled: true, caCertificateTrusted: true, sessionCount: 40),
            runningFromApplications: true,
            proxyPort: MCPLimits.proxyPort,
            proxyPortListening: true,
            licensed: true,
            tlsRejections: [MCPTLSRejection(host: "media.whatsapp.net", app: "WhatsApp", count: 1)]
        ))
        return try XCTUnwrap(report.checks.first { $0.id == "tls_rejections" })
    }

    /// The agent's fix: the refusal is remembered and the app works on its
    /// next try; excluding the host only stops recording it; a tool given the
    /// CA must be forgotten under SSL-pinned apps.
    func testTheAgentFixSaysTheRefusalIsRemembered() throws {
        let check = try check()
        let fix = try XCTUnwrap(check.fix)
        XCTAssertFalse(fix.contains("If the user wants such an app to work while capturing, exclude its host"), fix)
        XCTAssertTrue(fix.contains("ReqRes remembers an app that refused its certificate, with the domain, and passes that app's later connections there through untouched, as rows marked SSL pinned: the app works on its next try"), fix)
        XCTAssertTrue(fix.contains("Settings ▸ Capture ▸ SSL-pinned apps lists what it remembered."), fix)
        XCTAssertTrue(fix.contains("To stop recording such a host at all, call exclude_host host=media.whatsapp.net"), fix)
        XCTAssertTrue(fix.contains("Once the tool has the CA, the user forgets the tool under SSL-pinned apps, or its connections to that domain stay passed through."), fix)
    }

    /// The person's fix (Capture ▸ Diagnose Setup…) says the same, in their
    /// words.
    func testTheHumanFixSaysTheRefusalIsRemembered() throws {
        let human = try XCTUnwrap(MCPSetupDiagnosis.humanFix(for: try check()))
        XCTAssertFalse(human.contains("To make such an app work while capturing"), human)
        XCTAssertTrue(human.contains("ReqRes remembers an app that refused its certificate, with the domain, and passes that app's later connections there through untouched, marked SSL pinned, so the app works when it tries again."), human)
        XCTAssertTrue(human.contains("Settings ▸ Capture ▸ SSL-pinned apps lists them."), human)
        XCTAssertTrue(human.contains("To stop recording such a host at all, open one of its Failed rows and click Exclude"), human)
        XCTAssertTrue(human.contains("Then forget the tool under SSL-pinned apps, so ReqRes decrypts its connections again."), human)
    }

    /// The detail no longer says the app's requests keep failing while
    /// capture runs: only the refused one did.
    func testTheDetailSaysTheRequestsFailedNotThatTheyKeepFailing() throws {
        let detail = try check().detail
        XCTAssertFalse(detail.contains("fail while capture runs"), detail)
        XCTAssertTrue(detail.contains("so their requests to these hosts failed: media.whatsapp.net by WhatsApp (once)."), detail)
    }

    func testExcludeHostNoLongerSaysAPinningAppNeedsIt() throws {
        let server = try server
        XCTAssertFalse(server.contains("apps that pin their certificate only work while capturing once their host is excluded"))
        XCTAssertTrue(server.contains("does not need it to keep working: ReqRes remembers the refusal and passes that app's later connections to the domain through untouched, as rows marked SSL pinned. Exclude a host to stop recording it at all"))
    }

    func testSkillNoLongerSaysAPinningAppNeedsAnExclusion() throws {
        let skill = try skill
        for old in ["Such an app does not work while capture runs.",
                    "an app that pins only works once its host is excluded",
                    "so an app that pins works again while capturing"] {
            XCTAssertFalse(skill.contains(old), old)
        }
        XCTAssertTrue(skill.contains("That request fails, and ReqRes remembers the app and the domain: the app's later connections there are passed through untouched, as rows marked SSL pinned, so it works on its next try"))
        XCTAssertTrue(skill.contains("once it has it, the user forgets the tool under SSL-pinned apps, or its connections to that domain stay passed through."))
        XCTAssertTrue(skill.contains("An app that pins does not need it: after its first refusal ReqRes passes that app's connections to the domain through untouched"))
    }
}
