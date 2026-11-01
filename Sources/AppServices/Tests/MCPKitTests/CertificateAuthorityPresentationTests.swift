//
//  CertificateAuthorityPresentationTests.swift
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
//  Shell step S4 (protocol PRD 4 Phase 2.1): what the user is told about the
//  per-install CA, and when. The launch sheet is offered at every launch
//  while the 1.0.x shared CA is in the keychain, and once for an earlier
//  install's CA ("Not Now" is remembered by fingerprint); the Settings
//  banner stays until they are gone; the pane's state follows the core's
//  "installed AND trusted" rule; and Settings and Help print ONE sentence
//  about where the private key is. The last group reads the app's source,
//  because the SwiftUI views have no test target: it pins that Trust no longer
//  restarts capture and that both surfaces print the shared sentence.
//

import XCTest
@testable import MCPKit

final class CertificateAuthorityPresentationTests: XCTestCase {
    typealias P = CertificateAuthorityPresentation

    private let legacy = "82c25bf3" + String(repeating: "a", count: 52) + "7074"
    private let earlier = String(repeating: "e", count: 64)
    private let another = String(repeating: "f", count: 64)

    // MARK: - The pane's state

    func testInterceptionNeedsInstalledAndTrusted() {
        XCTAssertEqual(P.status(caAvailable: false, installed: true, trusted: true), .unavailable,
                       "no CA outranks whatever the keychain says")
        XCTAssertEqual(P.status(caAvailable: true, installed: false, trusted: false), .notInstalled)
        XCTAssertEqual(P.status(caAvailable: true, installed: false, trusted: true), .notInstalled,
                       "a trusted certificate that is not this install's is not this install's")
        XCTAssertEqual(P.status(caAvailable: true, installed: true, trusted: false), .installedNotTrusted)
        XCTAssertEqual(P.status(caAvailable: true, installed: true, trusted: true), .ready)
    }

    func testTheNextStepIsNamedByItsRealButtonTitle() throws {
        XCTAssertEqual(P.nextStep(for: .notInstalled), "Install CA certificate")
        XCTAssertEqual(P.nextStep(for: .installedNotTrusted), "Trust")
        XCTAssertNil(P.nextStep(for: .ready))
        XCTAssertNil(P.nextStep(for: .unavailable))
        // The diagnosis and capture_environment name the same buttons.
        XCTAssertEqual(P.installButton, "Install CA certificate")
        for status: P.Status in [.notInstalled, .installedNotTrusted] {
            let next = try XCTUnwrap(P.nextStep(for: status))
            XCTAssertTrue(P.summary(for: status).contains(next), "\(status) summary names its next step")
        }
    }

    func testTheSummarySaysWhatHappensToHTTPSInEveryState() {
        for status: P.Status in [.unavailable, .notInstalled, .installedNotTrusted] {
            XCTAssertTrue(P.summary(for: status).contains("relayed without being read"), "\(status)")
        }
        let ready = P.summary(for: .ready)
        XCTAssertTrue(ready.contains("new HTTPS connections are decrypted"))
        XCTAssertTrue(ready.contains("already open stay relayed"),
                      "trust applies to new connections only — Trust no longer restarts capture")
        XCTAssertFalse(ready.lowercased().contains("restart"))
    }

    // MARK: - Where the key is

    func testTheCustodySentenceSaysGeneratedHereKeptOwnerOnlyHandedInMemoryAndNeverSent() {
        let text = P.custody
        XCTAssertTrue(text.contains("on your Mac the first time it ran"))
        XCTAssertTrue(text.contains("different on every Mac"))
        XCTAssertTrue(text.contains("ReqRes's own container"))
        XCTAssertTrue(text.contains("only your user account can open"), "0600 files in a 0700 directory")
        XCTAssertTrue(text.contains("in memory when capture starts"), "the extension gets it in the start options")
        XCTAssertTrue(text.contains("never sent anywhere else"))
        // The Phase 0.5 interim wording, and the 1.0.x claim that was false.
        XCTAssertFalse(text.contains("same on every Mac"))
        XCTAssertFalse(text.contains("never leaves"), "it does leave the app process — to the extension")
    }

    func testFingerprintsPrintTheWayKeychainAccessPrintsThem() {
        let hex = "3f2a9c41d07e5b88a1c6e2f904b7d35a6c19e8f2b04d7a3c5e81f6092ab4c7d1"
        let shown = P.displayFingerprint(hex)
        XCTAssertTrue(shown.hasPrefix("3F 2A 9C 41 "))
        XCTAssertTrue(shown.hasSuffix(" C7 D1"))
        XCTAssertEqual(shown.split(separator: " ").count, 32)
        XCTAssertEqual(shown.replacingOccurrences(of: " ", with: "").lowercased(), hex, "nothing lost")
        XCTAssertEqual(P.displayFingerprint(" \(hex)\n"), shown)
        let lines = P.displayFingerprintLines(hex)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.joined(separator: " "), shown, "two lines of 16 pairs, nothing lost")
        XCTAssertEqual(lines.map { $0.split(separator: " ").count }, [16, 16])
        XCTAssertEqual(P.displayFingerprintLines("abc"), ["abc"])
        // Not a SHA-256: shown as it is, never padded or guessed.
        XCTAssertEqual(P.displayFingerprint("abc"), "abc")
        XCTAssertEqual(P.displayFingerprint(String(repeating: "z", count: 64)), String(repeating: "z", count: 64))
    }

    // MARK: - The launch sheet

    private func offer(_ outdated: [String], declined: [String]) -> Bool {
        P.shouldOfferAtLaunch(outdated: outdated, declined: declined, legacySharedFingerprint: legacy)
    }

    func testTheSheetIsOfferedOnlyForAnOlderCertificateNotAlreadyDeclined() {
        XCTAssertFalse(offer([], declined: []), "nothing to replace, nothing offered")
        XCTAssertTrue(offer([legacy], declined: []), "first launch of 1.1.0 over 1.0.x")
        XCTAssertTrue(offer([earlier], declined: []), "an earlier install's CA is offered once")
        // An earlier install's CA: "Not Now" is remembered.
        XCTAssertFalse(offer([earlier], declined: [earlier]))
        XCTAssertFalse(offer([earlier.uppercased()], declined: [" \(earlier) "]),
                       "fingerprints compare case- and whitespace-insensitively")
        // A certificate the user has not seen (a reset container left another
        // CA behind) is offered even after an earlier "Not Now".
        XCTAssertTrue(offer([earlier, another], declined: [earlier]))
        XCTAssertFalse(offer([""], declined: []), "an empty fingerprint is not a certificate")
    }

    /// S4 review (MEDIUM): the first S4 draft let one "Not Now" silence the
    /// launch sheet for the 1.0.x CA for good — a root trusted for every
    /// website whose private key is in every public download. C8 asked at
    /// every launch; so does this.
    func testTheSharedCertificateIsOfferedAtEveryLaunchEvenAfterNotNow() {
        XCTAssertTrue(offer([legacy], declined: [legacy]))
        XCTAssertTrue(offer([legacy.uppercased()], declined: [" \(legacy) "]),
                      "however the stored fingerprint is spelled")
        XCTAssertTrue(offer([legacy, earlier], declined: [legacy, earlier]),
                      "the shared one alone brings the sheet back")
        XCTAssertFalse(offer([earlier], declined: [legacy, earlier]),
                       "once the shared one is gone, a declined earlier CA stays declined")
    }

    func testDecliningRemembersEverythingOutdatedNowAndBefore() {
        let first = P.declining(outdated: [legacy.uppercased()], previously: [])
        XCTAssertEqual(first, [legacy])
        let second = P.declining(outdated: [earlier, legacy], previously: first + [another, ""])
        XCTAssertEqual(second, [legacy, earlier, another].sorted(), "deduplicated, sorted, no empties")
        XCTAssertFalse(offer([earlier, another], declined: second))
        XCTAssertTrue(offer([earlier, legacy], declined: second), "the shared CA is never silenced")
        XCTAssertEqual(P.declinedDefaultsKey, "CAMigrationDeclinedFingerprints",
                       "a stored key: renaming it re-offers the sheet to everyone who declined")
    }

    // MARK: - The banner: stays while anything older is in the keychain

    func testWhichBannerShowsForWhichCertificates() throws {
        XCTAssertEqual(P.outdated([], legacySharedFingerprint: legacy), .none)
        XCTAssertNil(P.banner(for: .none), "no banner without an older certificate")

        XCTAssertEqual(P.outdated([legacy.uppercased()], legacySharedFingerprint: legacy), .includesShared(count: 1))
        let shared = try XCTUnwrap(P.banner(for: .includesShared(count: 1)))
        XCTAssertTrue(shared.contains("ReqRes 1.0.x"))
        XCTAssertTrue(shared.contains("same on every Mac"))
        XCTAssertTrue(shared.contains("Remove it."))

        XCTAssertEqual(P.outdated([earlier, legacy], legacySharedFingerprint: legacy), .includesShared(count: 2))
        XCTAssertTrue(try XCTUnwrap(P.banner(for: .includesShared(count: 2))).hasPrefix("2 older"))

        XCTAssertEqual(P.outdated([earlier], legacySharedFingerprint: legacy), .earlierInstalls(count: 1))
        let earlierText = try XCTUnwrap(P.banner(for: .earlierInstalls(count: 1)))
        XCTAssertTrue(earlierText.contains("earlier installation"))
        XCTAssertFalse(earlierText.contains("1.0.x"), "an earlier install's key was never published — do not say it was")
        XCTAssertFalse(earlierText.contains("same on every Mac"))
    }

    func testTheBannerDoesNotDependOnWhetherTheSheetWasDeclined() {
        // Declining the sheet leaves the old CA, so the banner must still be
        // there: the banner is a function of the keychain alone.
        let outdated = P.outdated([legacy], legacySharedFingerprint: legacy)
        XCTAssertNotNil(P.banner(for: outdated))
        XCTAssertTrue(offer([legacy], declined: [legacy]))
        let earlierOnly = P.outdated([earlier], legacySharedFingerprint: legacy)
        XCTAssertNotNil(P.banner(for: earlierOnly))
        XCTAssertFalse(offer([earlier], declined: [earlier]), "declined, and the banner is still there")
    }

    // MARK: - The sheet's words

    func testTheSheetSaysWhyWhatHappensAndWhatNotNowLeaves() throws {
        XCTAssertNil(P.sheetReason(for: .none))
        let shared = try XCTUnwrap(P.sheetReason(for: .includesShared(count: 1)))
        XCTAssertTrue(shared.contains("same on every Mac"))
        XCTAssertTrue(shared.contains("not a secret"))
        let earlierReason = try XCTUnwrap(P.sheetReason(for: .earlierInstalls(count: 1)))
        XCTAssertFalse(earlierReason.contains("1.0.x"))

        // In order: trust off the old one, install + trust the new, restart.
        XCTAssertEqual(P.sheetSteps.count, 3)
        XCTAssertTrue(P.sheetSteps[0].contains("trust"), P.sheetSteps[0])
        XCTAssertTrue(P.sheetSteps[1].contains("Install and trust"))
        XCTAssertTrue(P.sheetSteps[2].contains("Restart capture"))
        XCTAssertTrue(P.sheetPasswordNote.contains("password"))
        for outdated: P.Outdated in [.includesShared(count: 1), .earlierInstalls(count: 1)] {
            let note = P.sheetDeclineNote(for: outdated)
            XCTAssertTrue(note.contains("removes nothing"), note)
            XCTAssertTrue(note.contains(MCPCaptureEnvironment.replaceOldCertificateButton), note)
        }
        // The note says whether the sheet comes back — and it must match
        // shouldOfferAtLaunch.
        XCTAssertTrue(P.sheetDeclineNote(for: .includesShared(count: 1)).contains("asks again at the next launch"))
        XCTAssertTrue(P.sheetDeclineNote(for: .earlierInstalls(count: 1)).contains("will not ask again"))
        XCTAssertEqual(P.declineButton, "Not Now")
        XCTAssertTrue(P.sheetCancelledNote.contains("stays removed"),
                      "a cancelled prompt may follow a removal that already happened — do not claim nothing changed")
    }

    // MARK: - The app's wiring (source text: the SwiftUI has no test target)

    private static func appSource(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/MCPKitTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
            .appendingPathComponent("UI/\(relative)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSettingsAndHelpPrintTheSameCustodySentence() throws {
        let pane = try Self.appSource("Views/Modals/CACertificateModal.swift")
        let help = try Self.appSource("Views/Help/HelpContent.swift")
        XCTAssertTrue(pane.contains("Copy.custody"), "Settings ▸ Certificate prints the shared sentence")
        XCTAssertTrue(help.contains("CertificateAuthorityPresentation.custody"), "Help prints the shared sentence")
        XCTAssertFalse(help.contains("its private key stays on this one"), "C8's interim wording is retired")
    }

    func testTrustNoLongerRestartsCapture() throws {
        let pane = try Self.appSource("Views/Modals/CACertificateModal.swift")
        XCTAssertFalse(pane.contains("restartCaptureIfRunning"),
                       "Trust pushes caStateChanged; the running extension intercepts new connections without a restart")
        let service = try Self.appSource("Services/CertificateAuthorityService.swift")
        let trust = try XCTUnwrap(service.range(of: "func trustCurrent()"))
        let body = service[trust.upperBound...].prefix(900)
        XCTAssertTrue(body.contains("CAStateSync.push()"), "Trust tells the running extension")
        XCTAssertFalse(body.contains("restartCaptureIfRunning"))
        let help = try Self.appSource("Views/Help/HelpContent.swift")
        XCTAssertFalse(help.contains("restarts the tunnel for you"), "Help no longer promises a restart on Trust")
    }

    func testNotNowIsRememberedAndTheLaunchOfferReadsIt() throws {
        let sheet = try Self.appSource("Views/Modals/CAMigrationSheet.swift")
        XCTAssertTrue(sheet.contains("service.declineOffer()"))
        let service = try Self.appSource("Services/CertificateAuthorityService.swift")
        XCTAssertTrue(service.contains("Presentation.shouldOfferAtLaunch("), "the launch offer goes through the tested rule")
        XCTAssertTrue(service.contains("Presentation.declining("))
    }

    /// S4 review (LOW ×3), pinned in source because the app has no test
    /// target: the pane's buttons wait for the first read of the CA; pushes
    /// and refreshes cannot land out of order; the replacement lets its
    /// spinner draw before the synchronous keychain work.
    func testThePaneAndTheServiceCannotActOnAStaleOrMissingRead() throws {
        let pane = try Self.appSource("Views/Modals/CACertificateModal.swift")
        XCTAssertEqual(pane.components(separatedBy: "service.fingerprint == nil)").count - 1, 2,
                       "Install and Trust are disabled until the CA has been read")
        let service = try Self.appSource("Services/CertificateAuthorityService.swift")
        let sync = try XCTUnwrap(service.range(of: "static func push(onlyIfChanged"))
        let pushBody = service[sync.upperBound...].prefix(400)
        XCTAssertTrue(pushBody.contains("queue.async"), "pushes go through one serial queue")
        XCTAssertFalse(pushBody.contains("Task.detached"), "one detached task per push can send out of order")
        XCTAssertTrue(service.contains("guard generation > appliedRefreshGeneration else { return }"),
                      "an older refresh never overwrites a newer one")
        let replace = try XCTUnwrap(service.range(of: "func replaceOutdated()"))
        let replaceBody = service[replace.upperBound...].prefix(600)
        XCTAssertTrue(replaceBody.contains("await Task.yield()"))
        for name in ["func installCurrent()", "func trustCurrent()"] {
            let start = try XCTUnwrap(service.range(of: name))
            XCTAssertTrue(service[start.upperBound...].prefix(200).contains("if certificate == nil { await refresh() }"), name)
        }
    }

    // MARK: - Relay copy agrees with C8/S4 (S4 review, MEDIUM)

    /// Since core C8 the extension decides per CONNECTION, from the state the
    /// app pushes, whether to decrypt; an installed-but-untrusted CA relays
    /// (it is never presented to apps); and Trust needs no capture restart.
    /// These phrases described the 1.0.x / pre-C8 engine and contradicted the
    /// Certificate topic in the same Help window.
    func testRelayCopyNoLongerDescribesThePreC8Engine() throws {
        let retired = ["when capture started", "when capture starts", "capture restarts",
                       "restarts capture", "apps refuse ReqRes"]
        // ("restart capture" alone is not retired: "no need to restart capture" is the fix.)
        let strings: [(String, String)] = [
            ("withoutCertificate", CaptureEngineFacts.withoutCertificate),
            ("relayExplanation", RecordedExchangeCopy.relayExplanation),
            ("relayRemedy", RecordedExchangeCopy.relayRemedy),
            ("relayCellHelp", RecordedExchangeCopy.relayCellHelp),
        ]
        for (name, text) in strings {
            for phrase in retired {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(phrase), "\(name) still says “\(phrase)”")
            }
        }
        XCTAssertTrue(CaptureEngineFacts.withoutCertificate.contains("installed and trusted"))
        XCTAssertTrue(RecordedExchangeCopy.relayExplanation.contains("installed and trusted"))
        XCTAssertTrue(RecordedExchangeCopy.relayRemedy.contains("no need to restart capture"))

        let help = try Self.appSource("Views/Help/HelpContent.swift")
        for phrase in ["when capture started", "apps refuse ReqRes", "capture restarts"] {
            XCTAssertFalse(help.contains(phrase), "Help still says “\(phrase)”")
        }
        // The agent-facing surfaces: SKILL.md and the relay detail text.
        let appServices = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skill = try String(contentsOf: appServices.appendingPathComponent("Sources/reqres-mcp/SKILL.md"), encoding: .utf8)
        for phrase in ["as capture started", "and restart capture"] {
            XCTAssertFalse(skill.contains(phrase), "SKILL.md still says “\(phrase)”")
        }
        let format = try String(contentsOf: appServices.appendingPathComponent("Sources/MCPKit/MCPTextFormat.swift"), encoding: .utf8)
        XCTAssertFalse(format.contains("and restarts capture"), "the relay detail still tells agents to restart capture")
    }
}
