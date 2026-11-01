//
//  MCPCaptureEnvironmentTests.swift
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
//  The value of `capture_environment` is that an agent can paste what it
//  prints and have its own traffic appear. So the tests are about the lines
//  being exactly runnable, and about the two states in which printing them
//  would send the agent into a TLS failure or a silent proxy instead.
//

import XCTest
@testable import MCPKit

final class MCPCaptureEnvironmentTests: XCTestCase {
    static let fingerprint = "5d41402abc4b2a76b9719d911017c592aa5d41402abc4b2a76b9719d911017c5"

    private func status(capture: Bool = true, caInstalled: Bool? = true, exportedPath: String? = nil,
                        trusted: Bool?? = .none, fingerprint: String? = MCPCaptureEnvironmentTests.fingerprint) -> MCPBridgeStatus {
        MCPBridgeStatus(
            captureActive: capture,
            vpnStatus: capture ? "connected" : "disconnected",
            extensionStatus: "ready",
            caCertificateInstalled: caInstalled,
            caCertificateTrusted: trusted ?? (caInstalled == true ? true : nil),
            sessionCount: 3,
            caExportedPath: exportedPath,
            caFingerprintSHA256: fingerprint
        )
    }

    private var exportLines: [String] {
        MCPCaptureEnvironment.shellLines(proxyPort: 8034, caFingerprint: Self.fingerprint).filter { $0.hasPrefix("export ") }
    }

    /// Whether the rendered text contains a shell COMMAND — a line that starts
    /// with one — as opposed to the word "export" in a sentence.
    private func containsShellLine(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { $0.hasPrefix("export ") || $0.hasPrefix("security ") }
    }

    // MARK: - The lines

    func testShellLinesPointAtTheProxyPortAndTheExportedPEM() {
        let lines = MCPCaptureEnvironment.shellLines(proxyPort: 8034, caFingerprint: Self.fingerprint)
        // Both spellings (F16): curl reads a plain-HTTP proxy only from the
        // lowercase name.
        XCTAssertEqual(lines.first, "export HTTPS_PROXY=http://127.0.0.1:8034 https_proxy=http://127.0.0.1:8034")
        XCTAssertEqual(lines[1], "export HTTP_PROXY=http://127.0.0.1:8034 http_proxy=http://127.0.0.1:8034")
        XCTAssertTrue(lines.contains { $0.hasPrefix("export NODE_EXTRA_CA_CERTS=~/reqres-ca.pem") }, "node needs the CA as a file")
        XCTAssertTrue(lines.contains { $0.hasPrefix("export SSL_CERT_FILE=~/reqres-ca.pem") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("export REQUESTS_CA_BUNDLE=~/reqres-ca.pem") }, "Python requests reads its own variable, not SSL_CERT_FILE")
    }

    /// The certificate line is what makes the rest work: the PEM the app
    /// writes is in a container a shell is TCC-denied to read, and the login
    /// keychain is the one place a shell CAN get the CA from. It must name the
    /// CN the CA is installed under, print PEM (-p), and land where the
    /// variables point.
    func testTheCertificateLineExportsFromTheLoginKeychainToWhereTheVariablesPoint() throws {
        let lines = MCPCaptureEnvironment.shellLines(proxyPort: 8034, caFingerprint: Self.fingerprint)
        let certificateLine = try XCTUnwrap(lines.first { $0.hasPrefix("security find-certificate") })
        XCTAssertTrue(certificateLine.contains("-c \"ReqRes CA\""), certificateLine)
        XCTAssertTrue(certificateLine.contains(" -p "), "must print PEM, not the binary certificate")
        // `>|`: a shell with noclobber set still rewrites an earlier file.
        XCTAssertTrue(certificateLine.hasSuffix(" >| ~/reqres-ca.pem"), certificateLine)
        for line in exportLines where line.contains("CA") {
            XCTAssertTrue(line.contains("=~/reqres-ca.pem"), "every CA variable must point at the exported file: \(line)")
        }
        // The export has to run BEFORE the variables that read the file.
        let certificateIndex = try XCTUnwrap(lines.firstIndex(of: certificateLine))
        for (index, line) in lines.enumerated() where line.contains("reqres-ca.pem") && line.hasPrefix("export") {
            XCTAssertGreaterThan(index, certificateIndex, "\(line) reads a file that is written later")
        }
    }

    func testTheProxyPortIsNotHardcoded() {
        let lines = MCPCaptureEnvironment.shellLines(proxyPort: 9999)
        XCTAssertEqual(lines.first, "export HTTPS_PROXY=http://127.0.0.1:9999 https_proxy=http://127.0.0.1:9999")
        XCTAssertFalse(lines.joined().contains("8034"))
    }

    /// Every line must be one shell command: no leading indentation that a
    /// paste would carry, no blank lines, and no comment — an agent hands
    /// these to a person, and zsh does not read a pasted `#` as one (F16).
    func testEveryLineIsAPasteableCommand() {
        for line in MCPCaptureEnvironment.shellLines(proxyPort: 8034, caFingerprint: Self.fingerprint) {
            XCTAssertFalse(line.hasPrefix(" "), line)
            XCTAssertFalse(line.isEmpty)
            XCTAssertFalse(line.contains("\n"))
            XCTAssertFalse(line.contains("#"), line)
        }
    }

    // MARK: - The rendered answer

    func testAWorkingSetupPrintsTheLinesAndWhoNeedsThem() {
        let text = MCPCaptureEnvironment.render(status: status())
        XCTAssertTrue(containsShellLine(text))
        for line in MCPCaptureEnvironment.shellLines(proxyPort: MCPLimits.proxyPort, caFingerprint: Self.fingerprint) {
            XCTAssertTrue(text.contains(line), "missing: \(line)")
        }
        XCTAssertTrue(text.contains(MCPCaptureEnvironment.systemProxyClients))
        XCTAssertTrue(text.contains(MCPCaptureEnvironment.environmentOnlyClients))
        XCTAssertTrue(text.contains("restart it"), "a tool already running never sees a later export")
        XCTAssertFalse(text.contains("STOPPED"))
        XCTAssertFalse(text.contains("could not read the keychain"))
    }

    /// Nothing below the first line matters until capture is on, so that is
    /// what an agent reading only the first line has to be told — and WHY:
    /// with capture off nothing listens on the proxy port, so a shell that
    /// exports HTTPS_PROXY anyway gets connection refused on every request.
    /// The lines are printed, but only after that warning.
    func testCaptureStoppedIsSaidFirstWithTheReason() throws {
        let text = MCPCaptureEnvironment.render(status: status(capture: false))
        let firstLine = text.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(firstLine.contains("Capture is STOPPED"), firstLine)
        XCTAssertTrue(firstLine.contains("start capture first"), firstLine)
        XCTAssertTrue(firstLine.contains("start_capture"), firstLine)
        XCTAssertTrue(firstLine.contains("connection refused"), firstLine)
        XCTAssertTrue(firstLine.contains("127.0.0.1:\(MCPLimits.proxyPort)"), firstLine)
        XCTAssertFalse(text.contains("take effect once capture is running"), "the old sentence implied the lines were harmless while capture is off")

        let warning = try XCTUnwrap(text.range(of: "Capture is STOPPED"))
        let lines = try XCTUnwrap(text.range(of: "export HTTPS_PROXY=http://127.0.0.1:\(MCPLimits.proxyPort)"))
        XCTAssertLessThan(warning.lowerBound, lines.lowerBound, "the lines come after the warning, never before")
    }

    /// With no CA there is nothing to export, and a tool sent through the
    /// proxy would only be relayed (core C3/C7: one row per connection, no
    /// requests). So: no lines, the install step instead, and where it is —
    /// naming the modal's REAL button.
    func testAMissingCAReplacesTheLinesWithTheInstallStep() {
        let text = MCPCaptureEnvironment.render(status: status(caInstalled: false))
        XCTAssertFalse(containsShellLine(text), text)
        XCTAssertTrue(text.contains("not installed"), text)
        XCTAssertTrue(text.contains("Settings ▸ Certificate"), text)
        XCTAssertTrue(text.contains("click Install CA certificate"), "the button in CACertificateModal is 'Install CA certificate'")
        XCTAssertFalse(text.contains("Install CA Certificate"), "no button is labelled that way")
        XCTAssertTrue(text.contains("capture_environment again"), "the agent should know to come back")
        // Doc §S10: without the CA the proxy RELAYS HTTPS (core C3/C7); it
        // does not fail TLS, which is what this sentence used to claim.
        XCTAssertFalse(text.contains("fail TLS"), text)
        XCTAssertTrue(text.contains("only be relayed"), text)
    }

    // MARK: - One renderer with the pane (errata 3)

    /// The app records where the user exported the CA; the tool prints the
    /// certificate lines against THAT path, exactly as Settings ▸ Capture does
    /// — quoted when a shell needs it — and drops the keychain step, which
    /// would write a second file nothing reads.
    func testAnExportedPathIsPrintedExactlyAsThePaneDoes() {
        let path = "/Users/dev/My Files/reqres-ca.pem"
        let text = MCPCaptureEnvironment.render(status: status(exportedPath: path))
        let pane = CaptureEnvironmentLines(proxyPort: MCPLimits.proxyPort, certificatePath: path)

        XCTAssertTrue(text.contains(pane.text), "the block must be byte-identical to the pane's:\n\(pane.text)\n---\n\(text)")
        XCTAssertTrue(text.contains("export NODE_EXTRA_CA_CERTS='/Users/dev/My Files/reqres-ca.pem'"), text)
        XCTAssertFalse(text.contains("security find-certificate"), "no keychain export once a file is known")
        XCTAssertFalse(text.contains("~/reqres-ca.pem"))
        XCTAssertTrue(text.contains("point at \(path)"), "the note names the file the user exported")
        XCTAssertTrue(text.contains("Settings ▸ Capture"), "and where to export again if it is gone")
    }

    /// What an unset `@AppStorage` reads as: no export yet, so the keychain
    /// step is back and the placeholder path is used.
    func testABlankExportedPathFallsBackToTheKeychainStep() {
        for blank in ["", "   "] {
            let text = MCPCaptureEnvironment.render(status: status(exportedPath: blank))
            XCTAssertTrue(text.contains("security find-certificate"), text)
            XCTAssertTrue(text.contains("=~/reqres-ca.pem"), text)
            XCTAssertTrue(text.contains("No exported certificate is known"), text)
        }
    }

    /// The CA state could not be read AND a file is known: the security line
    /// is not printed, so "if the security command prints an error" would
    /// point at a command the agent never ran.
    func testAnUnknownCAStateWithAnExportedPathDoesNotMentionTheSecurityCommand() {
        let text = MCPCaptureEnvironment.render(status: status(caInstalled: nil, exportedPath: "/Users/dev/reqres-ca.pem"))
        XCTAssertTrue(text.contains("could not read the keychain"), text)
        XCTAssertFalse(text.contains("security command"), text)
        XCTAssertFalse(text.contains("security find-certificate"), text)
        XCTAssertTrue(text.contains("Settings ▸ Certificate"), text)
    }

    // MARK: - Corrected claims

    /// `SSL_CERT_FILE` REPLACES the trust store. A host on the exclusion list
    /// is relayed, not re-signed, so its real certificate no longer verifies
    /// from that shell — timestamp.apple.com is on the list by default, so
    /// this is not hypothetical.
    func testTheNotesWarnThatSSLCertFileReplacesTheTrustStore() {
        let text = MCPCaptureEnvironment.render(status: status())
        XCTAssertTrue(text.contains("SSL_CERT_FILE REPLACES"), text)
        XCTAssertTrue(text.contains("exclusion list"), text)
        XCTAssertTrue(text.contains("timestamp.apple.com"), text)
        XCTAssertTrue(text.contains("relayed untouched"), text)
    }

    /// Docker Desktop's daemon follows the system proxy; it is the processes
    /// INSIDE containers that need the variables.
    func testDockerIsDescribedAsContainersNotTheDaemon() {
        XCTAssertTrue(MCPCaptureEnvironment.environmentOnlyClients.contains("inside Docker containers"))
        XCTAssertTrue(MCPCaptureEnvironment.environmentOnlyClients.contains("Docker Desktop itself follows the system proxy"))
        XCTAssertFalse(MCPCaptureEnvironment.environmentOnlyClients.hasPrefix("Docker"))
        let text = MCPCaptureEnvironment.render(status: status())
        XCTAssertTrue(text.contains("Docker Desktop's own daemon follows the system proxy"), text)
    }

    /// Go on macOS reads the proxy variables and verifies through the
    /// keychain; Rust was never measured. Neither may be told to set a CA
    /// variable, and Rust is not named at all.
    func testGoNeedsOnlyTheProxyLinesAndRustIsNotClaimed() {
        XCTAssertTrue(MCPCaptureEnvironment.environmentOnlyClients.contains("Go binaries (the proxy lines only"))
        XCTAssertFalse(MCPCaptureEnvironment.environmentOnlyClients.contains("Rust"))
        XCTAssertFalse(MCPCaptureEnvironment.systemProxyClients.contains("Rust"))
        for line in MCPCaptureEnvironment.shellLines(proxyPort: 8034, caFingerprint: Self.fingerprint) where line.contains("CA") || line.contains("CERT") {
            XCTAssertFalse(line.contains("Go"), line)
        }
    }

    /// node's own fetch ignores HTTPS_PROXY without NODE_USE_ENV_PROXY=1; the
    /// client list says so beside node, and the block carries the line.
    func testNodesOptInIsNamedBesideNodeAndPrinted() {
        XCTAssertTrue(MCPCaptureEnvironment.environmentOnlyClients.contains("NODE_USE_ENV_PROXY=1"))
        let text = MCPCaptureEnvironment.render(status: status())
        XCTAssertTrue(text.contains("export NODE_USE_ENV_PROXY=1"), text)
    }

    /// curl and git are listed on the strength of libcurl's imports; until
    /// the Phase 0 matrix confirms it live, the sentence hedges rather than
    /// promising (errata 5).
    /// Measured in the 2026-09-29 live run: with capture on, Apple's curl and
    /// `git ls-remote` connected straight to the server (not captured), while
    /// Python's urllib read the system proxy and was captured. The hedge
    /// ("probably curl and git") is gone; they are environment-only clients.
    func testCurlAndGitAreEnvironmentOnlyClients() {
        XCTAssertFalse(MCPCaptureEnvironment.systemProxyClients.contains("curl"))
        XCTAssertFalse(MCPCaptureEnvironment.systemProxyClients.contains("git"))
        XCTAssertFalse(MCPCaptureEnvironment.systemProxyClients.contains("probably"))
        XCTAssertTrue(MCPCaptureEnvironment.systemProxyClients.contains("Python's urllib"))
        XCTAssertTrue(MCPCaptureEnvironment.environmentOnlyClients.hasPrefix("curl and git"))
    }

    func testAMissingCAWithCaptureStoppedSaysBothInThatOrder() {
        let text = MCPCaptureEnvironment.render(status: status(capture: false, caInstalled: false))
        let stopped = text.range(of: "Capture is STOPPED")
        let missing = text.range(of: "not installed")
        XCTAssertNotNil(stopped, text)
        XCTAssertNotNil(missing, text)
        if let stopped, let missing {
            XCTAssertLessThan(stopped.lowerBound, missing.lowerBound, "capture first, then the certificate")
        }
        XCTAssertFalse(containsShellLine(text), text)
    }

    /// The app could not read the keychain: the lines are still the right
    /// ones, but the agent is told how to recognise the CA being absent — the
    /// security command failing — rather than being left to debug a TLS error.
    func testAnUnknownCAStatePrintsTheLinesWithTheCaveat() {
        let text = MCPCaptureEnvironment.render(status: status(caInstalled: nil))
        XCTAssertTrue(text.contains("security find-certificate"))
        XCTAssertTrue(text.contains("could not read the keychain"), text)
        XCTAssertTrue(text.contains("fails"), text)
        XCTAssertTrue(text.contains("Settings ▸ Certificate"), text)
    }

    /// Two facts that cost real debugging time if left out: ReqRes decrypts
    /// only while the CA is installed AND trusted in the keychain — the file
    /// a tool trusts does not change that (release review, 2026-09-29: the
    /// note used to say the opposite) — and inside Docker 127.0.0.1 is the
    /// container.
    func testTheNotesCoverTrustAndDocker() {
        let text = MCPCaptureEnvironment.render(status: status())
        XCTAssertFalse(text.contains("does not need to be trusted"), text)
        XCTAssertTrue(text.contains("installed AND trusted"), text)
        XCTAssertTrue(text.contains("host.docker.internal:\(MCPLimits.proxyPort)"), text)
    }

    /// Installed but not trusted: the core relays every HTTPS connection, so
    /// the Trust step is named before the lines.
    func testAnUntrustedCANamesTheTrustStepFirst() throws {
        let text = MCPCaptureEnvironment.render(status: status(trusted: false))
        XCTAssertTrue(text.contains("installed but NOT trusted"), text)
        XCTAssertTrue(text.contains("relay"), text)
        let trust = try XCTUnwrap(text.range(of: "NOT trusted"))
        let firstLine = try XCTUnwrap(text.range(of: "export HTTPS_PROXY"))
        XCTAssertLessThan(trust.lowerBound, firstLine.lowerBound)
        XCTAssertFalse(MCPCaptureEnvironment.render(status: status()).contains("NOT trusted"))
    }

    /// No fingerprint (the app could not produce its CA): no keychain step,
    /// and the agent is told to have the user export instead.
    func testWithoutAFingerprintThereIsNoKeychainStep() {
        let text = MCPCaptureEnvironment.render(status: status(fingerprint: nil))
        XCTAssertFalse(text.contains("security find-certificate"), text)
        XCTAssertTrue(text.contains("Export CA Certificate"), text)
    }

    /// The reason to do any of this is to then find the tool's own traffic.
    func testTheAnswerPointsAtTheAttributionFilters() {
        let text = MCPCaptureEnvironment.render(status: status())
        XCTAssertTrue(text.contains("list_sessions"), text)
        XCTAssertTrue(text.contains("app=") && text.contains("pid="), text)
    }

    /// The diagnosis and this tool describe the same two client classes from
    /// the same constants, so they cannot disagree about who is captured.
    func testTheClientListsAreSharedWithTheDiagnosis() {
        let report = MCPSetupDiagnosis.report(MCPSetupFacts(status: status(), proxyPort: MCPLimits.proxyPort))
        let note = report.checks.first { $0.id == "proxy_aware_clients" }
        XCTAssertTrue(note?.detail.contains(MCPCaptureEnvironment.systemProxyClients) == true)
        XCTAssertTrue(note?.detail.contains(MCPCaptureEnvironment.environmentOnlyClients) == true)
    }
}
