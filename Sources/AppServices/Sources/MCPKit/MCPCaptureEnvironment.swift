//
//  MCPCaptureEnvironment.swift
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
//  "Capture a command-line tool" (process-attribution PRD §5E).
//
//  ReqRes's tunnel routes no packets. It publishes proxy settings, and only a
//  client that READS the system proxy configuration ever reaches the proxy:
//  CFNetwork apps, Electron apps, Python's urllib. curl and git do not (measured
//  2026-09-29), and node does not
//  — so the Claude Code CLI is invisible to ReqRes
//  unless its shell exports HTTPS_PROXY. And exporting that alone fails TLS,
//  because node does not read the keychain either: it needs the ReqRes CA as
//  a PEM file, and the PEM the app writes sits in an app-group container a
//  shell is TCC-denied to read. The CA is also in the login keychain, which a
//  shell CAN read with `security find-certificate` — that is the line that
//  makes the rest work before the user has exported anything. Once they have
//  (Settings ▸ Capture ▸ Export CA Certificate…), the status carries the
//  path and the lines point at that file instead.
//
//  The lines themselves come from `CaptureEnvironmentLines`, the ONE renderer
//  the Settings pane and Help use too (errata 3); this file only decides what
//  to say around them, from facts the bridge already publishes through
//  `/v1/status`. Read-only: nothing here changes the app, so it asks no one.
//

import Foundation

public enum MCPCaptureEnvironment {
    /// The common name the CA is installed under in the login keychain, and
    /// therefore the `-c` argument `security find-certificate` needs.
    public static let certificateCommonName = CaptureEnvironmentLines.certificateCommonName

    /// Where the lines put the PEM when no export is known. In the home
    /// directory rather than a temp dir so it survives a reboot — the
    /// variables pointing at it may end up in a shell profile.
    public static let pemPath = CaptureEnvironmentLines.fallbackCertificatePath

    /// The label of the button that removes older "ReqRes CA" certificates
    /// (the Certificate settings and the migration sheet), so the text an
    /// agent reads out names what the user will see.
    public static let replaceOldCertificateButton = "Replace Old Certificate"

    /// Clients macOS points at ReqRes by itself while capture is on. Shared
    /// with `MCPSetupDiagnosis` so the two surfaces name the same list.
    /// Measured in the 2026-09-29 live run: Python's urllib reads the system
    /// proxy (`getproxies()` returns 127.0.0.1:8034) and was captured; Apple's
    /// curl and git were NOT — both connected straight to the origin although
    /// libcurl links System Configuration (it does not consult it for the
    /// proxy), so they moved to `environmentOnlyClients`.
    public static let systemProxyClients =
        "Safari and other CFNetwork apps, Electron apps (Claude, VS Code, Cursor), Python's urllib"

    /// Clients that ignore the system proxy and honour the proxy variables
    /// instead (curl and git take the proxy for plain http:// only from
    /// `http_proxy`).
    /// Docker Desktop's own daemon follows the system proxy; it is the
    /// processes INSIDE containers that need the variables. Go on macOS reads
    /// the proxy variables but verifies TLS through the keychain, so it wants
    /// the proxy lines and none of the certificate ones.
    public static let environmentOnlyClients =
        "curl and git (Apple's too — measured: they connect straight to the server), the Claude Code CLI and most node HTTP libraries (node's own fetch needs NODE_USE_ENV_PROXY=1 as well), processes inside Docker containers (Docker Desktop itself follows the system proxy), Go binaries (the proxy lines only — Go on macOS verifies through the keychain, so the CA must be trusted there, as for Safari)"

    /// The lines to paste, in the order they have to run: the proxy first,
    /// node's opt-in, then the certificate export (only while no exported
    /// file is known), then the variables that point at the file. One
    /// renderer with the Settings pane: `CaptureEnvironmentLines`.
    public static func shellLines(proxyPort: Int, certificatePath: String? = nil, caFingerprint: String? = nil) -> [String] {
        CaptureEnvironmentLines(proxyPort: proxyPort, certificatePath: certificatePath, caFingerprint: caFingerprint).lines
    }

    /// What an agent whose own traffic is missing needs, in the order it can
    /// act on it. Capture being off comes first because a shell that exports
    /// these lines while it is off cannot make ANY request — nothing listens
    /// on the proxy port, so every connection is refused; a missing CA
    /// replaces the lines entirely: there is no certificate to export, and
    /// without the CA every HTTPS connection through the proxy is relayed
    /// undecrypted (core C3/C7), so the lines would capture nothing readable.
    public static func render(status: MCPBridgeStatus, proxyPort requestedPort: Int? = nil) -> String {
        // The status's port (Settings ▸ Capture can change it), unless a caller
        // pins one.
        let proxyPort = requestedPort ?? status.effectiveProxyPort
        var paragraphs: [String] = []

        if !status.captureActive {
            paragraphs.append(
                "Capture is STOPPED — start capture first: call start_capture, or ask the user to press the capture button. "
                    + "With capture off nothing listens on 127.0.0.1:\(proxyPort), so a shell that has already exported HTTPS_PROXY gets connection refused on every request; nothing passes through. "
                    + "The lines below are the right ones, but run them only once capture is on — and unset them, or open a fresh terminal, whenever it is off."
            )
        }

        if status.caCertificateInstalled == false {
            paragraphs.append(
                "The ReqRes CA is not installed, so there is no certificate to export, and a tool sent through the proxy would only be relayed: each HTTPS connection one row with its endpoint and byte counts, and no requests, headers or bodies to read. "
                    + "Ask the user to open ReqRes ▸ Settings ▸ Certificate and click Install CA certificate — then call capture_environment again."
            )
            return paragraphs.joined(separator: "\n\n")
        }

        // An export that holds another CA (1.0.x's shared one, or an
        // earlier install's) is not printed: every tool pointed at it would
        // fail TLS. The lines fall back to the keychain step until the user
        // exports again, and a note says why.
        let staleExport = status.caExportedCertificateOutdated == true
            ? CaptureEnvironmentLines(proxyPort: proxyPort, certificatePath: status.caExportedPath).certificatePath
            : nil
        let exportedPath = staleExport == nil
            ? CaptureEnvironmentLines(proxyPort: proxyPort, certificatePath: status.caExportedPath).certificatePath
            : nil

        paragraphs.append(
            "While capture is on, macOS points system-proxy-aware clients at ReqRes by itself: \(systemProxyClients). "
                + "These do NOT read that setting and reach ReqRes only through the environment: \(environmentOnlyClients). "
                + "Run the lines below in the shell that starts the tool (a tool already running does not see them — restart it):"
        )
        // Installed but not trusted: ReqRes decrypts only while the CA is
        // installed AND trusted in the login keychain (core CertHelper.caState,
        // D7), so every HTTPS connection is relayed whatever file a tool
        // trusts. The lines are still the right ones; the Trust step comes first.
        if status.caCertificateTrusted == false {
            paragraphs.insert(
                "The ReqRes CA is installed but NOT trusted, so ReqRes relays every HTTPS connection without decrypting it — one relay row per connection (endpoint and byte counts, no requests, headers or bodies) — with or without the lines below. "
                    + "Ask the user to open ReqRes ▸ Settings ▸ Certificate and trust the CA first.",
                at: paragraphs.count - 1
            )
        }
        let fingerprint = status.caFingerprintSHA256
        paragraphs.append(shellLines(proxyPort: proxyPort, certificatePath: exportedPath, caFingerprint: fingerprint).joined(separator: "\n"))

        var notes: [String] = []
        if let staleExport {
            notes.append(
                "The file the user exported earlier, \(staleExport), holds an older ReqRes CA than the one this Mac now uses, so a tool pointed at it fails TLS. "
                    + "Ask the user to export it again from ReqRes ▸ Settings ▸ Capture (Export CA Certificate…)."
                    + (fingerprint == nil ? "" : " Until then the lines above write the current CA from the login keychain to \(pemPath) instead.")
            )
        }
        if (status.caOutdatedCertificatesInstalled ?? 0) > 0 {
            notes.append(
                "An older ReqRes CA is still in the login keychain beside this Mac's own (same name). The security line picks this Mac's by its SHA-256, but browsers and other apps may still trust the old one. Ask the user to open ReqRes ▸ Settings ▸ Certificate and click \(replaceOldCertificateButton)."
            )
        }
        if let exportedPath {
            notes.append(
                "The certificate lines point at \(exportedPath), the file the user exported from ReqRes ▸ Settings ▸ Capture (certificate only, never its key). If it has been moved or deleted, ask the user to export it again from the same place."
            )
        } else if fingerprint != nil {
            notes.append(
                "No exported certificate is known, so the security line writes this Mac's CA — picked by its SHA-256, since an older certificate with the same name can sit beside it — from the login keychain to \(pemPath), replacing any copy an earlier build wrote there. Settings ▸ Capture ▸ Export CA Certificate… does the same from inside the app and records the path, after which this tool prints that path instead."
            )
        } else {
            notes.append(
                "No exported certificate is known, and ReqRes could not read its CA's fingerprint, so there is no keychain step (picking a \"\(certificateCommonName)\" by name alone can pick an older one). Ask the user to export it from ReqRes ▸ Settings ▸ Capture ▸ Export CA Certificate… to \(pemPath), or call capture_environment again after they have."
            )
        }
        notes += [
            "These tools check ReqRes's certificates against the FILE, but ReqRes decrypts only while the CA is installed AND trusted in the login keychain — until then their HTTPS is relayed (one relay row per connection) even with these lines (diagnose_setup reports the trust).",
            "SSL_CERT_FILE REPLACES a tool's trust store with that one certificate. A host on the exclusion list in Settings ▸ Capture (timestamp.apple.com by default) is relayed untouched rather than re-signed by ReqRes, so from that shell its real certificate no longer verifies and the request fails — unset SSL_CERT_FILE for such a host, or remove it from the list while you need it.",
            "Inside a Docker container 127.0.0.1 is the container itself — point the proxy variables at host.docker.internal:\(proxyPort) there. Docker Desktop's own daemon follows the system proxy and needs none of this.",
            "Once the tool's requests appear in list_sessions, each row carries app=<name> pid=<pid> when ReqRes could attribute the connection (diagnose_setup's attribution check says whether it can), so app=… or pid=… narrows the list to it.",
        ]
        if status.caCertificateInstalled == nil {
            notes.insert(
                exportedPath == nil
                    ? "ReqRes could not read the keychain to confirm the CA is installed. If the export (or the security command, when the lines carry one) fails, it is not — ask the user to install it in ReqRes ▸ Settings ▸ Certificate."
                    : "ReqRes could not read the keychain to confirm the CA is installed. The exported file is what these tools trust, so their TLS succeeds either way — but until the CA is installed and trusted, ReqRes relays HTTPS without reading it, so capture still needs it; if the user's browsers show certificate errors, ask them to install it in ReqRes ▸ Settings ▸ Certificate.",
                at: 0
            )
        }
        paragraphs.append(notes.map { "- " + $0 }.joined(separator: "\n"))

        return paragraphs.joined(separator: "\n\n")
    }
}
