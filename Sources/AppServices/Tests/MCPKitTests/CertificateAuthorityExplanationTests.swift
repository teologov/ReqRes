//
//  CertificateAuthorityExplanationTests.swift
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
//  Shell step S12: the certificate explained behind the ? in Settings ▸
//  Certificate, and in Help. Pins the facts the words state to a real
//  certificate — a fixture made with openssl the way the core makes an
//  install's CA (fixed dates and serial; its key was discarded). Also pins the
//  Terminal commands (by fingerprint, never by name), and that the words
//  describe only THIS Mac's certificate: the 1.0.x one is not mentioned.
//

import XCTest
@testable import MCPKit

final class CertificateAuthorityExplanationTests: XCTestCase {
    typealias E = CertificateAuthorityExplanation

    /// `O=ReqRes, OU=Generated for this installation on 2026-09-29, CN=ReqRes CA`,
    /// RSA-2048, SHA-256, serial 0A1B…F9, 2026-09-28 → 2036-09-26 UTC, CA:TRUE
    /// pathlen:0 — the shape `CertificateAuthority.generate` produces.
    static let fixtureDER = Data(base64Encoded: FIXTURE_B64)!

    // MARK: - An install's certificate, read

    func testAnInstallsCertificateIsReadNotAssumed() throws {
        let facts = try XCTUnwrap(CertificateAuthorityFacts.read(der: Self.fixtureDER))
        XCTAssertEqual(facts.commonName, "ReqRes CA")
        XCTAssertEqual(facts.organization, "ReqRes")
        XCTAssertEqual(facts.organizationalUnit, "Generated for this installation on 2026-09-29")
        XCTAssertEqual(facts.serialNumberHex, "0a1b2c3d4e5f60718293a4b5c6d7e8f9")
        XCTAssertEqual(facts.keySizeBits, 2048)
        XCTAssertEqual(facts.sha1, "26c34b2610043e1ba981f326fe6c9d48ceeb8849")
        XCTAssertEqual(facts.sha256, "221a0347e7109e82717a7c7356fc979f41e8be0dde8ae8ab8ba474506e654b53")
        XCTAssertEqual(facts.notBefore, ISO8601DateFormatter().date(from: "2026-09-28T00:00:00Z"))
        XCTAssertEqual(facts.notAfter, ISO8601DateFormatter().date(from: "2036-09-26T00:00:00Z"))
        XCTAssertNil(CertificateAuthorityFacts.read(der: Data([0x30, 0x03, 0x02, 0x01, 0x00])), "not a certificate")
    }

    func testTheInstallRowsComeFromTheCertificateAndLeaveOutTheSHA256() throws {
        let facts = try XCTUnwrap(CertificateAuthorityFacts.read(der: Self.fixtureDER))
        let rows = E.installFacts(facts, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(rows.map(\.label), ["Organizational unit", "Valid from", "Expires", "Key", "Serial number", "SHA-1"])
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        XCTAssertEqual(values["Organizational unit"], "Generated for this installation on 2026-09-29")
        XCTAssertEqual(values["Valid from"], "September 28, 2026")
        XCTAssertEqual(values["Expires"], "September 26, 2036")
        XCTAssertEqual(values["Key"], "RSA, 2,048 bits")
        XCTAssertEqual(values["Serial number"], "0A 1B 2C 3D 4E 5F 60 71 82 93 A4 B5 C6 D7 E8 F9")
        XCTAssertEqual(values["SHA-1"], "26 C3 4B 26 10 04 3E 1B A9 81 F3 26 FE 6C 9D 48 CE EB 88 49")
        XCTAssertFalse(rows.contains { $0.value.contains("22 1A 03 47") },
                       "the pane already prints the SHA-256; the sheet points at it instead")
        XCTAssertTrue(E.sha256Pointer.contains("Settings ▸ Certificate"))
    }

    func testARowTheCertificateDidNotAnswerIsLeftOut() {
        let bare = CertificateAuthorityFacts(commonName: nil, organization: nil, organizationalUnit: nil,
                                             notBefore: nil, notAfter: nil, serialNumberHex: "",
                                             keySizeBits: nil, sha1: String(repeating: "a", count: 40),
                                             sha256: String(repeating: "b", count: 64))
        XCTAssertEqual(E.installFacts(bare).map(\.label), ["SHA-1"])
    }

    // MARK: - The commands

    func testTheDeleteCommandIsByFingerprintNeverByName() throws {
        let current = try XCTUnwrap(E.deleteCommand(sha1Hex: "26 c3 4b 26 10 04 3e 1b a9 81 f3 26 fe 6c 9d 48 ce eb 88 49"))
        XCTAssertEqual(current, "security delete-certificate -t -Z 26C34B2610043E1BA981F326FE6C9D48CEEB8849 ~/Library/Keychains/login.keychain-db")
        XCTAssertFalse(current.contains("-c "), "by name matches every ReqRes certificate")
        XCTAssertTrue(current.contains(" -t "), "the user's trust in it goes with it")
        XCTAssertFalse(current.hasPrefix("sudo"))
        XCTAssertFalse(current.contains("System.keychain"))
        // The explanation says so in words too.
        XCTAssertTrue(E.terminalIntro.contains("by fingerprint, not by name"))
    }

    func testNoCommandIsBuiltAroundAGuess() {
        XCTAssertNil(E.deleteCommand(sha1Hex: ""))
        XCTAssertNil(E.deleteCommand(sha1Hex: "ReqRes CA"))
        XCTAssertNil(E.deleteCommand(sha1Hex: "221a0347e7109e82717a7c7356fc979f41e8be0dde8ae8ab8ba474506e654b53"),
                     "a SHA-256 is not what -Z is given here")
        XCTAssertNil(E.deleteCommand(sha1Hex: String(repeating: "g", count: 40)))
    }

    func testTheListCommandOnlyReads() {
        let list = E.listCommand()
        XCTAssertEqual(list, "security find-certificate -a -Z -c \"ReqRes CA\" ~/Library/Keychains/login.keychain-db | grep SHA-1")
        XCTAssertFalse(list.contains("delete"))
    }

    // MARK: - The words

    func testTheWordsSayWhatTheCoreDoes() {
        let policy = E.policy.joined(separator: " ")
        for fact in ["RSA 2,048-bit", "SHA-256", "ten years", "a day before", "90 days", "in memory",
                     "never writes it to disk", "cannot create another certificate authority"] {
            XCTAssertTrue(policy.contains(fact), "policy states: \(fact)")
        }
        XCTAssertTrue(E.policy.contains(CertificateAuthorityPresentation.custody),
                      "where the key is kept is the ONE sentence Settings and Help already print")
        XCTAssertTrue(E.whatItIs.contains("this installation"))
        XCTAssertTrue(E.whatItIsNot.contains("only for your user account"))
        XCTAssertTrue(E.whatItIsNot.contains("private key"))
        XCTAssertTrue(E.removeIntro.contains("Deleting ReqRes does not remove"))
        XCTAssertTrue(E.keychainSteps.joined().contains("Use System Defaults"),
                      "a certificate deleted with its trust left behind stays trusted")
        // The pane's one-line advice points at the steps, not at "delete
        // “ReqRes CA”" — after an upgrade two certificates share that name.
        XCTAssertTrue(CertificateAuthorityPresentation.removalAdvice.contains(E.removeHeading))
        XCTAssertFalse(CertificateAuthorityPresentation.removalAdvice.contains("delete “ReqRes CA”"))
        // Calm: no advisory language.
        for word in ["vulnerab", "attack", "CVE", "urgent", "compromis"] {
            XCTAssertFalse(Self.allWords.lowercased().contains(word.lowercased()), "no drama: \(word)")
        }
    }

    /// Every sentence the sheet and Help print from this type.
    static var allWords: String {
        ([E.title, E.whatItIs, E.whatItIsNot, E.detailsHeading, E.sha256Pointer, E.removeHeading, E.removeIntro,
          E.terminalIntro, E.listCommandCaption, E.currentCommandCaption, E.afterRemovingCurrent,
          CertificateAuthorityPresentation.removalAdvice] + E.policy + E.keychainSteps).joined(separator: " ")
    }

    /// The explanation is about THIS Mac's certificate. Why
    /// it replaced the 1.0.x one is of no use to a new user, and a user who
    /// still has that one is told by the launch sheet and the pane's banner.
    func testTheWordsDescribeOnlyThisMacsCertificate() {
        let words = Self.allWords.lowercased()
        for history in ["1.0", "1.1.0", "oloapps", "old one", "old certificate", "older", "earlier install",
                        "replaced", "replace old", "shared", "every copy", "tell them apart", "each one"] {
            XCTAssertFalse(words.contains(history), "no 1.0.x history in the explanation: \(history)")
        }
    }

    func testRemovedHistoryStaysRemoved() throws {
        let sheet = try Self.appSource("Views/Modals/CertificateExplanationSheet.swift")
        let help = try Self.appSource("Views/Help/HelpContent.swift")
        for surface in [sheet, help] {
            XCTAssertFalse(surface.contains("legacySharedCAFingerprintSHA256"), "no 1.0.x command is built")
            XCTAssertFalse(surface.contains("legacyInstalled"))
        }
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

    func testThePaneHasAHelpButtonAndTheSheetAndHelpPrintTheSameWords() throws {
        let pane = try Self.appSource("Views/Modals/CACertificateModal.swift")
        XCTAssertTrue(pane.contains("HelpLink"), "a standard macOS help button")
        XCTAssertTrue(pane.contains("CertificateExplanationSheet"))
        let sheet = try Self.appSource("Views/Modals/CertificateExplanationSheet.swift")
        let help = try Self.appSource("Views/Help/HelpContent.swift")
        for name in ["whatItIs", "whatItIsNot", "policy", "removeIntro", "keychainSteps", "terminalIntro",
                     "listCommand", "afterRemovingCurrent"] {
            XCTAssertTrue(sheet.contains("Explained.\(name)") || sheet.contains("E.\(name)"), "the sheet prints \(name)")
            XCTAssertTrue(help.contains("CertificateAuthorityExplanation.\(name)"), "Help prints \(name)")
        }
        // This Mac's delete command is built from its own SHA-1, read from its DER.
        XCTAssertTrue(sheet.contains("Explained.deleteCommand(sha1Hex: sha1)"))
        XCTAssertFalse(sheet.contains("-c \\\"ReqRes CA\\\" ") && sheet.contains("delete-certificate"),
                       "no delete-by-name in the sheet")
    }
}

// swiftlint:disable line_length
private let FIXTURE_B64 = "MIIDqjCCApKgAwIBAgIQChssPU5fYHGCk6S1xtfo+TANBgkqhkiG9w0BAQsFADBdMQ8wDQYDVQQKDAZSZXFSZXMxNjA0BgNVBAsMLUdlbmVyYXRlZCBmb3IgdGhpcyBpbnN0YWxsYXRpb24gb24gMjAyNi0wOS0yOTESMBAGA1UEAwwJUmVxUmVzIENBMB4XDTI2MDkyODAwMDAwMFoXDTM2MDkyNjAwMDAwMFowXTEPMA0GA1UECgwGUmVxUmVzMTYwNAYDVQQLDC1HZW5lcmF0ZWQgZm9yIHRoaXMgaW5zdGFsbGF0aW9uIG9uIDIwMjYtMDktMjkxEjAQBgNVBAMMCVJlcVJlcyBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALptZbUKPNvysSMPykSPgQ5nnvbrf07854euxszcIwwllQAz8Ak7+x0Jab9QnrBec4QHJDjei5E5e9kZklEyyLWQn++xxqXf2uqej4AOnQVbispMGOoqcGRm1RCfXJzxJgRkYh3Zt8XlmZetr1i/wzbAqNXvJCys0pTc/EHdhu0QHB46//A0E7gx/6iXUOn/KQ42VC8B6o6dazpx96gOcjrxZeVmRmj+wBbdSN352kefHaxL2rgHLn+hG7EH+c4evhYqeUWnvwlch/GvhsjeLKEAndL8PgLaM9U2uy/7+t8mvQFyDgDGGke1AUQhqb87r0xUbKs78dS5f/cwaMuWdMECAwEAAaNmMGQwHQYDVR0OBBYEFGHgxiNVlvNokn3Ish1qV/8VJcJDMB8GA1UdIwQYMBaAFGHgxiNVlvNokn3Ish1qV/8VJcJDMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMA0GCSqGSIb3DQEBCwUAA4IBAQAISDs8U67q4W8HRfsCVoS1PndUtHwE0mnWB5+Z6alIfcCM1RumBNR0D2UNuhBMC7tH8bV+tKrbwtCS5tZDPRbmeMLHH9L06KSZ7d0ou7XyCCeSQBCBOBSZ/o4bLWf1uAN9AdXUjH+75deX1iJ5euiCqsrrEwLGGu6eFdbxYtmtS8Am5T9NKWAOJLC4P1KbNfL2D8r/iu+KebHxrE/FvFRo6ZjaRDaRLmh6rQ4lhEuWrsMy7o+ZFeeRVklpHbdGOpko7D3SINqIYj2xN2wraHZDqGGTrwKuJXCFHVNrkaLTSSaplE4gwQAxBKrd257zh7ofFsWbJAYOcNS+mbiOffiY"
