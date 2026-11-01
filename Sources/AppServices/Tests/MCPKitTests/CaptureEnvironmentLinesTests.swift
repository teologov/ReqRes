//
//  CaptureEnvironmentLinesTests.swift
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
//  Pins the block Settings ▸ Capture, Help and `capture_environment` all
//  render — ONE renderer, so these and the real shells and curl in
//  CaptureEnvironmentShellTests are the only tests the block needs — and
//  the one rule of the certificate export. Begun as 12 tests against the UI
//  copy of the type, then extended for the
//  line set the errata settled: NODE_USE_ENV_PROXY, the keychain step before
//  a first export, REQUESTS_CA_BUNDLE, and claims that are true — then for
//  F16: both spellings of every proxy variable, and a block with no comment
//  in it at all (what each line is for moved to `legend`, beside the block).
//

import XCTest
@testable import MCPKit

final class CaptureEnvironmentLinesTests: XCTestCase {
    // MARK: - Before an export

    /// The documented block, verbatim. The keychain step is in it because a
    /// shell is TCC-denied the PEM the app writes and this is the one way to
    /// get the CA as a file before Settings ▸ Capture has exported one.
    static let fingerprint = "5d41402abc4b2a76b9719d911017c592aa5d41402abc4b2a76b9719d911017c5"

    func testBeforeAnExportTheBlockIsExactlyTheDocumentedLines() {
        let lines = CaptureEnvironmentLines(proxyPort: 8034, caFingerprint: Self.fingerprint)

        XCTAssertEqual(lines.text, """
        export HTTPS_PROXY=http://127.0.0.1:8034 https_proxy=http://127.0.0.1:8034
        export HTTP_PROXY=http://127.0.0.1:8034 http_proxy=http://127.0.0.1:8034
        export NO_PROXY=localhost,127.0.0.1,::1
        export no_proxy=localhost,127.0.0.1,::1
        export NODE_USE_ENV_PROXY=1
        security find-certificate -a -Z -c "ReqRes CA" -p | awk -v f=5D41402ABC4B2A76B9719D911017C592AA5D41402ABC4B2A76B9719D911017C5 '/^SHA-256 hash:/{k=($3==f)} k&&/BEGIN CERT/{p=1} p{print} /END CERT/{p=0}' >| ~/reqres-ca.pem
        export NODE_EXTRA_CA_CERTS=~/reqres-ca.pem
        export SSL_CERT_FILE=~/reqres-ca.pem
        export REQUESTS_CA_BUNDLE=~/reqres-ca.pem
        """)
        XCTAssertFalse(lines.hasExportedCertificate)
        XCTAssertTrue(lines.hasKeychainStep)
        XCTAssertEqual(lines.lines.count, 9)
    }

    // MARK: - Two certificates called "ReqRes CA" (release review, 2026-09-29)

    /// After an upgrade the keychain holds the 1.0.x shared CA AND this
    /// install's, both "ReqRes CA"; `find-certificate -c … -p` without `-a`
    /// returns the one added first — the old one. No rendering may carry a
    /// name-only lookup.
    func testNoRenderingCarriesANameOnlyKeychainLookup() {
        let renderings = [
            CaptureEnvironmentLines(proxyPort: 8034),
            CaptureEnvironmentLines(proxyPort: 8034, caFingerprint: Self.fingerprint),
            CaptureEnvironmentLines(proxyPort: 8034, caFingerprint: "  "),
        ]
        for lines in renderings {
            for line in lines.lines where line.contains("find-certificate") {
                XCTAssertTrue(line.contains(" -a ") && line.contains(" -Z "), line)
                XCTAssertTrue(line.contains("f=\(CaptureEnvironmentLines.normalizedFingerprint(Self.fingerprint))"), line)
            }
        }
    }

    /// Without the fingerprint there is no keychain step at all — picking a
    /// "ReqRes CA" by name alone can pick the wrong one — and the certificate
    /// lines point at the placeholder an export writes. Saying "export first"
    /// is the surrounding text's job (Help's steps, the pane's caption,
    /// `capture_environment`'s note), not a comment line's.
    func testWithoutTheFingerprintThereIsNoKeychainStep() {
        let lines = CaptureEnvironmentLines(proxyPort: 8034)
        XCTAssertFalse(lines.hasKeychainStep)
        XCTAssertFalse(lines.text.contains("security "), lines.text)
        XCTAssertEqual(Array(lines.lines.suffix(3)), [
            "export NODE_EXTRA_CA_CERTS=~/reqres-ca.pem",
            "export SSL_CERT_FILE=~/reqres-ca.pem",
            "export REQUESTS_CA_BUNDLE=~/reqres-ca.pem",
        ])
        XCTAssertEqual(lines.lines.count, 8)
    }

    /// The fingerprint reaches the shell as uppercase hex only — the form
    /// `security -Z` prints — whatever form the app kept it in.
    func testTheFingerprintIsNormalisedAndNothingElseReachesTheShell() {
        XCTAssertEqual(CaptureEnvironmentLines.normalizedFingerprint("ab:cd:0f"), "ABCD0F")
        XCTAssertEqual(CaptureEnvironmentLines.normalizedFingerprint("ab'; rm -rf ~ #cd"), "ABFCD")
    }

    /// The command itself, run against listings shaped like `security -a -Z`
    /// prints them, old certificate first: it must write the NEW one.
    func testTheCommandPicksTheCertificateByFingerprintNotByOrder() throws {
        let listing = """
        SHA-256 hash: 82C25BF3D2E7DF11F92F050DCD4E10DDD7725E873D2F4598999DC087D90B7074
        SHA-1 hash: 6C158FC89A07A3AE9C710D10F4A4B0C36E300058
        -----BEGIN CERTIFICATE-----
        OLDOLDOLD
        -----END CERTIFICATE-----
        SHA-256 hash: 5D41402ABC4B2A76B9719D911017C592AA5D41402ABC4B2A76B9719D911017C5
        SHA-1 hash: 0000000000000000000000000000000000000000
        -----BEGIN CERTIFICATE-----
        NEWNEWNEW
        -----END CERTIFICATE-----

        """
        let command = CaptureEnvironmentLines.keychainCommand(fingerprint: Self.fingerprint)
        // Only the awk stage: `security` is replaced by the fixed listing.
        let awkStage = try XCTUnwrap(command.components(separatedBy: " | ").last?.components(separatedBy: " >| ").first)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", awkStage]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(listing.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let written = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(written, "-----BEGIN CERTIFICATE-----\nNEWNEWNEW\n-----END CERTIFICATE-----\n")
    }

    func testTheProxyPortIsTheOneHandedInAndAppearsOnBothProxyLines() {
        let lines = CaptureEnvironmentLines(proxyPort: 9999)
        // `_PROXY=http` — NODE_USE_ENV_PROXY=1 also ends in `_PROXY=` and is
        // not an address.
        let proxyLines = lines.lines.filter { $0.contains("_PROXY=http") }

        XCTAssertEqual(proxyLines.count, 2)
        XCTAssertTrue(proxyLines.allSatisfy { $0.hasSuffix("=http://127.0.0.1:9999") })
        XCTAssertFalse(lines.text.contains("8034"), "no second copy of the port may hide in the template")
    }

    func testTheTildePlaceholderIsNeverQuotedOrItWouldStopExpanding() {
        let lines = CaptureEnvironmentLines(proxyPort: 8034)

        XCTAssertEqual(lines.certificateArgument, "~/reqres-ca.pem")
        XCTAssertFalse(lines.text.contains("'~"))
    }

    func testABlankStoredPathCountsAsNoExport() {
        // What an unset @AppStorage String reads as, and what a stray space would be.
        XCTAssertFalse(CaptureEnvironmentLines(proxyPort: 8034, certificatePath: "").hasExportedCertificate)
        XCTAssertFalse(CaptureEnvironmentLines(proxyPort: 8034, certificatePath: "  \n").hasExportedCertificate)
        XCTAssertEqual(CaptureEnvironmentLines(proxyPort: 8034, certificatePath: "").text,
                       CaptureEnvironmentLines(proxyPort: 8034).text)
    }

    /// node ≥ 24's own fetch/https ignore HTTPS_PROXY without this (measured
    /// 2026-09-25: a fetch through HTTPS_PROXY=http://127.0.0.1:1 returned 200).
    /// It comes right after the proxy lines, so a reader sees the two facts
    /// together, and before any certificate line.
    func testNodeUseEnvProxyFollowsTheProxyLinesInBothStates() {
        for path in [nil, "/Users/dev/reqres-ca.pem"] {
            let rows = CaptureEnvironmentLines(proxyPort: 8034, certificatePath: path).lines
            XCTAssertEqual(rows[4], "export NODE_USE_ENV_PROXY=1", String(describing: path))
        }
    }

    // MARK: - Both spellings of every proxy variable (F16)

    /// curl takes a plain-HTTP proxy only from lowercase `http_proxy` (`man
    /// curl`, 8.7.1: "http_proxy is an exception as it is only available in
    /// lower case"): with the uppercase line alone, `curl http://…` and git's
    /// http:// went straight to the server (measured 2026-09-30). A lowercase
    /// variable already in the shell outranks the uppercase one in curl, git,
    /// Python and node, and Ruby reads only `HTTP_PROXY`/`http_proxy` — so
    /// every proxy variable is exported in both spellings, with one value, in
    /// every state; one line per scheme keeps the block its length.
    func testEveryProxyVariableIsExportedInBothSpellings() {
        for block in Self.everyState(proxyPort: 9034) {
            let exported = Self.assignments(in: block.lines)
            for name in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] {
                XCTAssertEqual(exported[name], "http://127.0.0.1:9034", "\(name), \(Self.describe(block))")
            }
            for name in ["NO_PROXY", "no_proxy"] {
                XCTAssertEqual(exported[name], CaptureEnvironmentLines.noProxyHosts, "\(name), \(Self.describe(block))")
            }
            XCTAssertEqual(exported["NODE_USE_ENV_PROXY"], "1", Self.describe(block))
            XCTAssertEqual(block.lines[0], "export HTTPS_PROXY=http://127.0.0.1:9034 https_proxy=http://127.0.0.1:9034")
            XCTAssertEqual(block.lines[1], "export HTTP_PROXY=http://127.0.0.1:9034 http_proxy=http://127.0.0.1:9034")
        }
        // The widest a proxy line gets — a five-digit port — still fits the pane.
        let widest = CaptureEnvironmentLines(proxyPort: 65535)
        XCTAssertLessThanOrEqual(widest.lines[0].count, 84, widest.lines[0])
    }

    // MARK: - Nothing in the block but commands (F16)

    /// Every line, in every state, is a command — no comment beside it, no
    /// line that is only a comment. The pane's box is selectable and Help's
    /// example has no Copy button, so whatever is shown gets pasted; and a
    /// Terminal paste reaches zsh as one buffer in which `#` is a plain word
    /// (`interactivecomments` is off by default): the first comment word
    /// `export` refused dropped every line after it (CaptureEnvironmentShellTests
    /// paste it the way Terminal does).
    func testNoLineIsOrCarriesAComment() {
        for block in Self.everyState() {
            for line in block.lines {
                XCTAssertFalse(line.contains("#"), "\(Self.describe(block)): \(line)")
            }
            XCTAssertEqual(block.text, block.lines.joined(separator: "\n"))
        }
    }

    /// What each line is for lives beside the block, and names every
    /// variable any state of the block exports — so a line cannot be added
    /// without its reason.
    func testTheLegendNamesEveryVariableTheBlockExports() {
        var names = Set<String>()
        for block in Self.everyState() {
            names.formUnion(Self.assignments(in: block.lines).keys)
        }
        XCTAssertEqual(names.count, 10, names.sorted().joined(separator: " "))
        for name in names {
            XCTAssertTrue(CaptureEnvironmentLines.legend.contains(name), "the legend never names \(name)")
        }
    }

    // MARK: - Loopback bypasses the proxy (protocol PRD §1.14)

    /// The lines came in while plain http:// through ReqRes reached only port
    /// 80, so `http://localhost:3000` sent through the proxy hung with no
    /// response and no row (PRD §1.7); they stay until the live matrix shows a
    /// local backend works through it (tech doc C5.7). The terminal this block
    /// sets up is where a developer runs their own backend, so loopback
    /// bypasses the proxy — in both spellings, because wget and some other
    /// tools read only `no_proxy`. Directly after the proxy lines, in both
    /// states, and never a line that routes loopback INTO the proxy.
    func testLoopbackBypassesTheProxyInBothSpellingsInBothStates() {
        for path in [nil, "/Users/dev/reqres-ca.pem", "/Users/dev/My Files/reqres-ca.pem"] {
            let rows = CaptureEnvironmentLines(proxyPort: 8034, certificatePath: path).lines
            XCTAssertEqual(rows[2], "export NO_PROXY=localhost,127.0.0.1,::1")
            XCTAssertEqual(rows[3], "export no_proxy=localhost,127.0.0.1,::1")
            XCTAssertEqual(rows.filter { $0.lowercased().hasPrefix("export no_proxy=") }.count, 2)
        }
        XCTAssertEqual(CaptureEnvironmentLines.noProxyHosts, "localhost,127.0.0.1,::1")
    }

    /// Every loopback spelling a client may resolve `localhost` to is listed,
    /// and nothing else — a wider list would silently hide real traffic.
    func testTheBypassListIsLoopbackOnly() {
        let hosts = CaptureEnvironmentLines.noProxyHosts.split(separator: ",").map(String.init)
        XCTAssertEqual(Set(hosts), ["localhost", "127.0.0.1", "::1"])
        XCTAssertFalse(CaptureEnvironmentLines.noProxyHosts.contains(" "), "a space ends the value in an unquoted export")
    }

    // MARK: - After an export

    /// Once the user has exported the CA, every certificate line points at
    /// THAT file and the keychain step is gone — it would write a second copy
    /// nothing reads.
    func testAfterAnExportEveryCertificateLineNamesTheRealPathAndTheKeychainStepIsGone() {
        let lines = CaptureEnvironmentLines(proxyPort: 8034, certificatePath: "/Users/dev/reqres-ca.pem")
        let rows = lines.lines

        XCTAssertTrue(lines.hasExportedCertificate)
        XCTAssertEqual(rows.count, 8)
        XCTAssertFalse(lines.hasKeychainStep)
        XCTAssertEqual(rows[5], "export NODE_EXTRA_CA_CERTS=/Users/dev/reqres-ca.pem")
        XCTAssertEqual(rows[6], "export SSL_CERT_FILE=/Users/dev/reqres-ca.pem")
        XCTAssertEqual(rows[7], "export REQUESTS_CA_BUNDLE=/Users/dev/reqres-ca.pem")
        XCTAssertFalse(lines.text.contains("~/reqres-ca.pem"))
        XCTAssertFalse(lines.text.contains("security find-certificate"), "no keychain export once a file is known")
    }

    /// The pane's monospaced box is about 84 columns wide. Every line but the
    /// keychain step (which wraps, as a long shell pipeline does) fits it —
    /// the proxy lines with a five-digit port, and the certificate lines with
    /// an export under a home folder.
    func testEveryLineButTheKeychainStepFitsThePane() {
        for block in Self.everyState(proxyPort: 65535) + [
            CaptureEnvironmentLines(proxyPort: 65535, certificatePath: "/Users/username/reqres-ca.pem"),
        ] {
            for line in block.lines where !line.hasPrefix("security ") {
                XCTAssertLessThanOrEqual(line.count, 84, "\(Self.describe(block)): \(line)")
            }
        }
    }

    func testAPathWithASpaceIsSingleQuotedAndAnApostropheIsEscaped() {
        XCTAssertEqual(CaptureEnvironmentLines.shellQuoted("/Users/dev/reqres-ca.pem"), "/Users/dev/reqres-ca.pem")
        XCTAssertEqual(CaptureEnvironmentLines.shellQuoted("/Users/dev/My Files/reqres-ca.pem"),
                       "'/Users/dev/My Files/reqres-ca.pem'")
        XCTAssertEqual(CaptureEnvironmentLines.shellQuoted("/Users/dev/It's/reqres-ca.pem"),
                       "'/Users/dev/It'\\''s/reqres-ca.pem'")
        // Shell metacharacters that would otherwise expand or split.
        for hostile in ["/tmp/$HOME.pem", "/tmp/a;b.pem", "/tmp/a`b`.pem", "/tmp/a\"b.pem", "/tmp/a*.pem"] {
            XCTAssertTrue(CaptureEnvironmentLines.shellQuoted(hostile).hasPrefix("'"), hostile)
        }
    }

    // MARK: - The legend makes claims, and they have to be true

    /// Go on macOS ignores SSL_CERT_FILE (crypto/x509's root_unix.go excludes
    /// darwin; it verifies through the keychain), and Python requests ignores
    /// it too (it reads REQUESTS_CA_BUNDLE). A legend naming either as a
    /// reader of SSL_CERT_FILE would send someone debugging a TLS failure to
    /// the wrong variable.
    func testTheLegendNamesOnlyToolsThatReadEachCertificateVariable() throws {
        let legend = CaptureEnvironmentLines.legend
        func clause(_ variable: String) throws -> String {
            // The readers named just before each variable: "… to X in VAR".
            let end = try XCTUnwrap(legend.range(of: " in \(variable)"), variable)
            let before = legend[..<end.lowerBound]
            let start = try XCTUnwrap(before.range(of: " to ", options: .backwards), variable)
            return String(before[start.upperBound...])
        }
        XCTAssertEqual(try clause("NODE_EXTRA_CA_CERTS"), "node and Claude Code")
        XCTAssertEqual(try clause("SSL_CERT_FILE"), "curl, Python’s urllib and httpx and OpenSSL-based tools")
        XCTAssertEqual(try clause("REQUESTS_CA_BUNDLE"), "Python requests")
        XCTAssertFalse(legend.contains("Go"), "Go on darwin verifies through the keychain, not the file")
    }

    /// Every line is one shell command a paste can run: no indentation, no
    /// blank lines, no line break inside.
    func testEveryLineIsAPasteableCommand() {
        for block in Self.everyState() {
            for line in block.lines {
                XCTAssertFalse(line.hasPrefix(" "), line)
                XCTAssertFalse(line.isEmpty)
                XCTAssertFalse(line.contains("\n"))
                XCTAssertTrue(line.hasPrefix("export ") || line.hasPrefix("security "), line)
            }
        }
    }

    // MARK: - One renderer

    /// `MCPCaptureEnvironment.shellLines` IS this type: the agent and the pane
    /// print byte-identical blocks for the same port and path.
    func testTheMCPToolRendersTheSameLinesAsThePane() {
        for path in [nil, "/Users/dev/reqres-ca.pem", "/Users/dev/My Files/reqres-ca.pem"] {
            XCTAssertEqual(
                MCPCaptureEnvironment.shellLines(proxyPort: 8034, certificatePath: path),
                CaptureEnvironmentLines(proxyPort: 8034, certificatePath: path).lines,
                "\(String(describing: path))"
            )
        }
        XCTAssertEqual(MCPCaptureEnvironment.shellLines(proxyPort: 8034), CaptureEnvironmentLines(proxyPort: 8034).lines)
    }

    /// The constants the tool's prose uses are the type's, so a renamed file
    /// or CN changes the command and the sentence about it together.
    func testTheMCPConstantsAreTheTypes() {
        XCTAssertEqual(MCPCaptureEnvironment.pemPath, CaptureEnvironmentLines.fallbackCertificatePath)
        XCTAssertEqual(MCPCaptureEnvironment.certificateCommonName, CaptureEnvironmentLines.certificateCommonName)
        XCTAssertTrue(CaptureEnvironmentLines.keychainCommand(fingerprint: Self.fingerprint).contains("-c \"\(CaptureEnvironmentLines.certificateCommonName)\""))
    }

    // MARK: - Constants the pane and Help share

    func testTheSavePanelNameMatchesThePlaceholderAndTheKeychainCommand() {
        XCTAssertEqual(CaptureEnvironmentLines.fallbackCertificatePath, "~/\(CaptureEnvironmentLines.exportFilename)")
        XCTAssertTrue(CaptureEnvironmentLines.keychainCommand(fingerprint: Self.fingerprint)
            .hasSuffix(" >| ~/reqres-ca.pem"))
        XCTAssertEqual(CaptureEnvironmentLines.exportedPathDefaultsKey, "CaptureCAExportedPath",
                       "the app's status adapter reads this key; renaming it silently breaks capture_environment's path")
    }

    // MARK: - The export never carries a key

    private let certificate = """
    -----BEGIN CERTIFICATE-----
    MIIBszCCAVwCCQDbase64base64base64base64
    -----END CERTIFICATE-----
    """
    private let privateKey = """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ
    -----END PRIVATE KEY-----
    """

    func testACertificateAloneComesBackWholeWithOneTrailingNewline() {
        XCTAssertEqual(CACertificateExport.certificateOnly(certificate), certificate + "\n")
        XCTAssertEqual(CACertificateExport.certificateOnly(certificate + "\n\n"), certificate + "\n")
    }

    func testAKeyMixedInIsStrippedWhicheverSideItIsOn() {
        for pem in [certificate + "\n" + privateKey, privateKey + "\n" + certificate] {
            let exported = CACertificateExport.certificateOnly(pem)
            XCTAssertEqual(exported, certificate + "\n")
            XCTAssertFalse(exported!.contains("PRIVATE KEY"))
        }
    }

    func testAKeyAloneOrGarbageExportsNothing() {
        XCTAssertNil(CACertificateExport.certificateOnly(privateKey))
        XCTAssertNil(CACertificateExport.certificateOnly(""))
        XCTAssertNil(CACertificateExport.certificateOnly("-----BEGIN CERTIFICATE-----\nno end marker"))
    }

    func testAChainKeepsEveryCertificate() {
        let second = certificate.replacingOccurrences(of: "MIIBszCC", with: "MIIBtzCC")
        let exported = CACertificateExport.certificateOnly(certificate + "\n" + second)

        XCTAssertEqual(exported, certificate + "\n" + second + "\n")
    }

    // MARK: - Helpers

    /// The block in each state it is shown in: the keychain step before an
    /// export, no fingerprint (Help's example), an export under a home folder,
    /// a short one, and a path a shell must quote.
    static func everyState(proxyPort: Int = 8034) -> [CaptureEnvironmentLines] {
        [
            CaptureEnvironmentLines(proxyPort: proxyPort, caFingerprint: fingerprint),
            CaptureEnvironmentLines(proxyPort: proxyPort),
            CaptureEnvironmentLines(proxyPort: proxyPort, certificatePath: "/Users/dev/reqres-ca.pem", caFingerprint: fingerprint),
            CaptureEnvironmentLines(proxyPort: proxyPort, certificatePath: "/a.pem"),
            CaptureEnvironmentLines(proxyPort: proxyPort, certificatePath: "/Users/dev/My Files/it's/reqres-ca.pem"),
        ]
    }

    static func describe(_ block: CaptureEnvironmentLines) -> String {
        if let path = block.certificatePath { return "exported to \(path)" }
        return block.caFingerprint == nil ? "no export, no fingerprint" : "no export"
    }

    /// NAME → VALUE for each word of an `export` command that assigns —
    /// enough for the unquoted values read here; `CaptureEnvironmentShellTests`
    /// has real shells read the rest.
    static func assignments(in commands: [String]) -> [String: String] {
        var exported: [String: String] = [:]
        for command in commands where command.hasPrefix("export ") {
            for word in command.dropFirst("export ".count).split(separator: " ") {
                guard let equals = word.firstIndex(of: "=") else { continue }
                exported[String(word[..<equals])] = String(word[word.index(after: equals)...])
            }
        }
        return exported
    }
}
