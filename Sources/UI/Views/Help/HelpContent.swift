//
//  HelpContent.swift
//  ReqRes
//
//  Created by OloApps on 21.09.2026.
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
//  What people actually get stuck on, not a manual — this is the curated
//  quick reference, the full docs are one banner away. Every fact here is
//  read from the code that implements it, not guessed:
//   - capture steps: Views/Session/ExtensionSetupView.swift and
//     Toolbar/ReqResToolbarSlots.swift's `extensionInstructions`
//   - certificate flow: Views/Modals/CACertificateModal.swift +
//     SettingsView.swift's "Certificate" tab
//   - rule modes: Views/Modals/RuleModal.swift's `modeDescription`
//   - pattern traps: HelpPatternExample.all (MCPKit), checked against
//     OverridePattern — the proxy's own matcher — in HelpPatternExamplesTests
//   - saving sessions: Services/SavedSessionsStore.swift, the list's context
//     menu in Views/Session/SessionView.swift, and the disclosure in
//     Views/SettingsView/StorageSettingsView.swift
//   - MCP: Views/MCP/MCPSettingsView.swift and MCPAgentActivity.swift
//   - breakpoints: Views/SettingsView/BreakpointSettingsView.swift and the
//     core's BreakpointRule/BreakpointRegistry — the countdown is read from
//     `BreakpointRegistry.decisionTimeout`, never typed out, so the number
//     here cannot drift from the one the extension counts down
//   - the codesign interaction: `ExcludedHostList.recommended` (Utils), which
//     excludes timestamp.apple.com by default
//   - command-line tools: the client table in the process-attribution PRD
//     (§0.3, measured per client with `dyld_info`), the export in
//     Views/SettingsView/CaptureSettingsView.swift, and the block itself
//     rendered from `CaptureEnvironmentLines` (MCPKit) — the ONE renderer
//     the Settings pane and the capture_environment tool print from, so
//     Help can never quote lines the pane does not
//   - which app made a request: `ProcessIdentity` (MCPKit) for how a
//     process is named, Views/Session/Components/ProcessLabel.swift for how
//     Unknown is shown, and the `attribution` check in `MCPSetupDiagnosis`
//     for the degraded state. Safari is named for the process that does its
//     networking (WebKit Networking), which is what the column shows — the
//     UX spec's errata 1, measured, not the app icon a reader would expect.
//   - supported protocols: `ProtocolSupport` (MCPKit) — ONE table that
//     this topic, diagnose_setup's `supported_protocols` check and SKILL.md
//     all render; `ProtocolSupportTests` fails when any of the three drops
//     an entry (protocol-engine doc §S10)
//   - destinations: `DestinationClassifier` (MCPKit) for which addresses
//     are This Mac / Local Network / Unknown, `OriginEstimator` for the You
//     marker (the time zone, never Location Services), and every sentence
//     about what a country means quoted from `DestinationCopy` — the ONE
//     source the map, Settings ▸ Capture and the agent's list_destinations
//     note also print from, so Help cannot claim more than the table knows
//   - a capture that outlived the app (build 53): `CaptureReattach` and
//     `CaptureDeliveryCopy` (Utils) — the notice's title and its button are
//     quoted from the copy the traffic pane shows; the core (95062d1) keeps
//     the newest 512 messages while no app is attached, holds no new
//     breakpoint request then, and re-announces the ones it still holds
//

import MCPKit
import SwiftUI
import Utils
import XReqResCore

/// One entry in the sidebar and one `ScrollViewReader` target — the single
/// source for both so the two can never drift apart (a renamed topic that
/// forgot to update a hand-written scroll id would silently stop jumping).
enum HelpTopic: String, CaseIterable, Identifiable {
    case capture, certificate, protocols, commandLine, rules, patterns, breakpoints, saving, destinations, mcp, troubleshooting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: return "Setting Up Capture"
        case .certificate: return "Trusting the Certificate"
        case .protocols: return ProtocolSupport.helpTitle
        case .commandLine: return "Capturing Command-Line Tools and Coding Agents"
        case .rules: return "Rules"
        case .patterns: return "Pattern Syntax and Its Traps"
        case .breakpoints: return "Holding a Request with a Breakpoint"
        case .saving: return "Saving Sessions"
        case .destinations: return "Seeing Where Requests Go"
        case .mcp: return "Connecting an AI Agent"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    /// The sidebar is 200pt wide and its rows do not wrap, so one topic
    /// needs a shorter label than its heading. Measured, not guessed: at
    /// HelpStyle.body, "Pattern Syntax and Its Traps" truncates and every
    /// other title fits.
    var shortTitle: String {
        switch self {
        case .commandLine: return "Command-Line Tools"
        case .patterns: return "Pattern Syntax"
        case .breakpoints: return "Breakpoints"
        case .destinations: return "Destinations"
        default: return title
        }
    }

    var systemImage: String {
        switch self {
        case .capture: return "shield.lefthalf.filled"
        case .certificate: return "lock.shield"
        case .protocols: return "network"
        case .commandLine: return "terminal"
        case .rules: return "arrow.left.and.right.circle"
        case .patterns: return "text.magnifyingglass"
        case .breakpoints: return "pause.circle"
        case .saving: return "tray.and.arrow.down"
        case .destinations: return "map"
        case .mcp: return "cpu"
        case .troubleshooting: return "wrench.and.screwdriver.fill"
        }
    }
}

@ViewBuilder
func helpContent(for topic: HelpTopic) -> some View {
    switch topic {
    case .capture: captureTopic
    case .certificate: certificateTopic
    case .protocols: protocolsTopic
    case .commandLine: commandLineTopic
    case .rules: rulesTopic
    case .patterns: patternsTopic
    case .breakpoints: breakpointsTopic
    case .saving: savingTopic
    case .destinations: destinationsTopic
    case .mcp: mcpTopic
    case .troubleshooting: troubleshootingTopic
    }
}

// MARK: - 1. Setting up capture

/// The product's hardest UX and its number one support surface — the same
/// six steps `ExtensionSetupView` walks a user through live, reproduced here
/// as a standing reference for when the guided screen has already scrolled
/// out of view (or someone is reading Help before ever opening the app).
private var captureTopic: some View {
    helpTopic(HelpTopic.capture.title, systemImage: HelpTopic.capture.systemImage, id: HelpTopic.capture.id) {
        helpParagraph("ReqRes captures HTTP(S) traffic with a Network Extension that points the Mac's system proxy at ReqRes while capture runs — so every app that uses the system proxy is captured at once, with no per-app setting to turn on, and the setting is gone again when capture stops. The trade-off is that macOS makes you approve the extension yourself, in a place it does not make obvious.")

        helpHeading("The five steps") {
            helpNumberedList([
                "Click the capture button in the toolbar (▶). macOS asks permission to install the extension.",
                "Open System Settings ▸ General ▸ Login Items & Extensions. (On macOS 14 — Sonoma — this is Privacy & Security ▸ Extensions instead.)",
                "Scroll to “Network Extensions” and click the ⓘ button beside it — this is the step almost everyone misses. The toggle for ReqRes is one level deeper than it looks, behind that button, not on the row itself.",
                "Switch ReqRes on, then click Done.",
                "When macOS asks to add a VPN configuration, choose Allow. This is what routes traffic through the extension — no real VPN or third-party server is involved.",
            ])
        }

        helpTip("A restart is sometimes needed the first time only. ReqRes rechecks its own status every couple of seconds while setup is incomplete, so once you flip the switch the app's screen updates on its own — no need to relaunch it.")

        helpParagraph("HTTP traffic appears as soon as capture is running. HTTPS traffic needs one more step — see “Trusting the Certificate” below. Tools run from a terminal are the one kind of app that may need telling where ReqRes is — see “Capturing Command-Line Tools and Coding Agents”. What ReqRes does with each protocol — HTTP/2, WebSockets, streams, gRPC, HTTP/3 — is in “Supported Protocols”.")

        helpHeading("Starting and stopping it, from anywhere") {
            VStack(alignment: .leading, spacing: 4) {
                helpBullet("Capture ▸ Start Capturing, or ⌘⇧C. The toolbar button does the same thing; the shortcut works even when the window is narrow enough that the button has folded into the » menu.")
                helpBullet("The ReqRes icon in your menu bar shows whether capture is running — a filled dot while it is, a hollow one while it is not — and stops capture from its menu. That matters because closing the window does NOT stop capture: while it runs, ReqRes is decrypting your Mac's HTTPS traffic, and the menu bar is how you can tell without going looking for the app.")
                helpBullet("Quitting ReqRes stops capture. It asks first, and says what is lost.")
                helpBullet("Don't want the icon? Settings ▸ General ▸ Menu Bar turns it off, and you can drag it out of the menu bar like any other. The same setting brings it back.")
            }
        }

        helpHeading("Which app made a request") {
            helpParagraph("Every request shows the app that opened its connection — Brave, Xcode, curl, the claude command-line tool — with its icon, in the App column. Hover a row for the process id and the app's path; the request's detail header shows the id as well, and its menu filters the list to that app or that one process.")
            VStack(alignment: .leading, spacing: 4) {
                helpBullet("Type app: in the search field to see one app's requests, or pid: to follow one process. app:claude matches both Claude Desktop and the claude command-line tool; app:unknown shows the requests ReqRes could not attribute.")
                helpBullet("Several requests can share one connection (keep-alive), and a connection is attributed once — so they all name the same app.")
                helpBullet("Safari's requests appear as WebKit, not Safari: its networking runs in a system process that every WebKit app shares, and ReqRes names the process it actually sees.")
                helpBullet("Unknown means ReqRes could not tell. Background downloads and some system services make requests on an app's behalf, and ReqRes names what it sees rather than what it suspects.")
                helpBullet("An app that never reaches ReqRes — one that ignores the system proxy, sends its requests over QUIC (HTTP/3) instead of through the proxy, or runs inside a Docker container — is not in the list at all, not even as Unknown. See “Capturing Command-Line Tools and Coding Agents” and “Supported Protocols”.")
                helpBullet("Requests made by an AI agent connected to ReqRes carry a small ✦ on their icon, and the agent's entry in the sidebar footer has a Show its traffic button.")
            }
        }

        helpHeading(TrafficTableKeyCopy.heading) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(TrafficTableKeyCopy.helpBullets, id: \.self) { helpBullet($0) }
            }
        }

        helpHeading("What capture changes, keeps and closes") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(LiveCaptureEngineFacts.sentences, id: \.self) { helpBullet($0) }
                helpBullet("A request that went out on a connection an earlier request opened says so in its Metrics tab — “Reused connection · request 3 on it” — instead of drawing DNS, TCP and TLS phases it never had.")
            }
        }

        helpHeading("Requests that failed, were cut off or timed out") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(FailureRowCopy.helpBullets, id: \.self) { helpBullet($0) }
                helpBullet(RecordedExchangeCopy.relayExplanation + " Such a row is a connection, not a request, and never uses a free HTTPS inspection.")
                helpBullet(PinnedHostCopy.helpBullet)
            }
        }

        helpTip("If capture looks on but nothing is appearing, use Capture ▸ Diagnose Setup…. It runs the same ordered checks ReqRes gives an AI agent — where the app is installed, the extension, the tunnel, the proxy port, the certificate — and names the first thing that is actually broken, which is usually not the thing you noticed.")
        helpTip("ReqRes's proxy listens on 127.0.0.1:\(CaptureProxyPort.configured) — Settings ▸ Capture ▸ Proxy port changes it (8034 is the default). If another program already holds that port when capture starts, ReqRes names it and asks before using another port; it never moves by itself, because terminals set up with the environment lines point at the number.")
    }
}

// MARK: - 2. Trusting the certificate

private var certificateTopic: some View {
    helpTopic(HelpTopic.certificate.title, systemImage: HelpTopic.certificate.systemImage, id: HelpTopic.certificate.id) {
        helpParagraph("HTTPS is encrypted end to end, on purpose — your Mac and the server it's talking to agree not to let anyone in between read it, ReqRes included. To inspect it anyway, ReqRes generates its own local certificate authority (“ReqRes CA”) and asks your Mac to trust it, the same way a corporate network or a tool like Charles or Proxyman would.")

        helpWarning("\(CaptureEngineFacts.withoutCertificate) That's not a bug, it's the encryption doing its job — and opening one of those rows never uses a free HTTPS inspection. HTTP traffic (no “S”) is never affected; it's visible with no certificate at all.")

        helpHeading("Installing it") {
            helpNumberedList([
                "Open Settings ▸ Certificate.",
                "Click \(CertificateAuthorityPresentation.installButton) — this adds ReqRes's certificate to your login keychain. It does not trust it yet.",
                "Click \(CertificateAuthorityPresentation.trustButton) once it's installed. macOS will ask you to confirm — this is the step that actually lets ReqRes decrypt HTTPS.",
            ])
        }

        // Shell step S4: Trust no longer restarts capture. The app tells the
        // running extension (`caStateChanged`), which intercepts every NEW
        // connection from then on.
        helpTip("If capture is already running when you trust the certificate, it takes effect at once for new connections — no restart. A connection that was already open stays relayed, not decrypted, until the app that opened it reconnects; quit and reopen that app if you need it decrypted now.")

        // Protocol PRD §1.11 / 4 Phase 2.1 (core step C8, shell step S4): the
        // CA is generated per install. Where its key lives is ONE sentence,
        // `CertificateAuthorityPresentation.custody`, which Settings ▸
        // Certificate prints too. Shell step S12: everything else about the
        // certificate — what it is, its details, removing it by hand — is
        // `CertificateAuthorityExplanation`, the words the ? in Settings ▸
        // Certificate opens. Help says the same and adds where to find this
        // Mac's own values. Neither mentions the 1.0.x certificate; the
        // launch sheet and the pane's banner do that.
        helpHeading("What this certificate is") {
            VStack(alignment: .leading, spacing: 8) {
                helpParagraph(CertificateAuthorityExplanation.whatItIs)
                helpParagraph(CertificateAuthorityExplanation.whatItIsNot)
            }
        }

        helpHeading("Where its private key is") {
            VStack(alignment: .leading, spacing: 8) {
                helpParagraph(CertificateAuthorityPresentation.custody)
                helpParagraph(CertificateAuthorityPresentation.removalAdvice)
            }
        }

        helpHeading(CertificateAuthorityExplanation.detailsHeading) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(CertificateAuthorityExplanation.policy.filter { $0 != CertificateAuthorityPresentation.custody }, id: \.self) {
                    helpBullet($0)
                }
                helpParagraph("This Mac's own values — the date it was made, when it expires, its serial number and fingerprints — are in Settings ▸ Certificate: the SHA-256 under ReqRes CA, the rest behind the ? button at the bottom of that pane.")
            }
        }

        helpHeading(CertificateAuthorityExplanation.removeHeading) {
            VStack(alignment: .leading, spacing: 8) {
                helpParagraph(CertificateAuthorityExplanation.removeIntro)
                helpNumberedList(CertificateAuthorityExplanation.keychainSteps)
                helpParagraph(CertificateAuthorityExplanation.terminalIntro)
                // Help cannot print the removal command (it needs this Mac's
                // fingerprint), so say where it is right after the sentence
                // that describes it.
                helpParagraph("That command, with this Mac's fingerprint filled in, is behind the ? button in Settings ▸ Certificate.")
                helpParagraph(CertificateAuthorityExplanation.listCommandCaption)
                helpExample(CertificateAuthorityExplanation.listCommand())
                helpParagraph(CertificateAuthorityExplanation.afterRemovingCurrent)
            }
        }
    }
}

// MARK: - 3. Supported protocols

/// What this version does with each protocol, from `ProtocolSupport` — the
/// ONE table diagnose_setup and SKILL.md render too, so a person and an
/// agent read the same limits. Every row carries its status as a word and a
/// symbol; the tint only repeats what the word says.
private var protocolsTopic: some View {
    helpTopic(HelpTopic.protocols.title, systemImage: HelpTopic.protocols.systemImage, id: HelpTopic.protocols.id) {
        helpParagraph(ProtocolSupport.helpIntro)

        ForEach(ProtocolSupport.helpRows) { row in
            helpHeading(row.title) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: row.statusSymbol)
                            .foregroundStyle(protocolStatusTint(row.statusLabel))
                        Text(row.statusLabel)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                    .font(HelpStyle.body)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Status: \(row.statusLabel)")
                    helpParagraph(row.whatYouSee)
                    helpParagraph(row.whatToDo)
                }
            }
        }

        helpTip("An AI agent connected to ReqRes reads the same list — diagnose_setup returns it, and so do the instructions ReqRes gives agents — so it does not mistake a protocol ReqRes does not capture for a broken capture.")
    }
}

/// Repeats the status word in colour, never replaces it.
private func protocolStatusTint(_ label: String) -> Color {
    switch label {
    case ProtocolSupport.statusLabel(.supported): return .green
    case ProtocolSupport.statusLabel(.beta): return .orange
    case ProtocolSupport.statusLabel(.relayed): return .blue
    default: return .secondary
    }
}

// MARK: - 4. Capturing command-line tools and coding agents

/// The scope of "captures everything", stated where someone looks when a tool
/// is missing from the list. Capture reaches an app through the proxy
/// settings the extension publishes; the client table is the PRD's, measured
/// per binary. The block is rendered from `CaptureEnvironmentLines` — the
/// type behind the Settings pane — with no export known, so it shows the
/// placeholder path the way the pane does before a first export. It has no
/// Copy button, so it relies on the block carrying no comment (F16): a hand
/// selection of it pastes into zsh as it stands.
private var commandLineTopic: some View {
    helpTopic(HelpTopic.commandLine.title, systemImage: HelpTopic.commandLine.systemImage, id: HelpTopic.commandLine.id) {
        helpParagraph("Capture works by publishing proxy settings for the whole Mac while it runs: the extension puts ReqRes's address into the system network configuration, and macOS takes it back out when capture stops. Any program that honours the system proxy sends its traffic to ReqRes without being configured. Not every program does — and the ones that don't are exactly the ones a developer runs from a terminal.")

        helpHeading("Which tools read the system proxy") {
            VStack(alignment: .leading, spacing: 4) {
                // curl and git are in the "No" half: measured in the
                // 2026-09-29 live run — Apple's curl and `git ls-remote`
                // connected straight to the server with capture on.
                helpBullet("Yes, captured with no setup once the certificate is trusted: Safari, Mail, Xcode and everything else built on Apple's networking; Electron apps such as Claude Desktop, VS Code and the Chromium browsers; Python's urllib.")
                helpBullet("No, invisible until told where the proxy is: curl and git (Apple's included — they connect straight to the server), the Claude Code CLI and most node HTTP libraries, which read the proxy environment variables instead — and node's own fetch needs NODE_USE_ENV_PROXY=1 as well; processes inside Docker containers (Docker Desktop itself follows the system proxy); programs written in Go or Rust.")
                helpBullet("node also ignores the keychain. Trusting the ReqRes CA in Settings ▸ Certificate is enough for Safari; node needs the same certificate as a file, named in NODE_EXTRA_CA_CERTS, or it rejects every HTTPS response ReqRes has re-signed.")
            }
        }

        helpHeading("Setting one up") {
            helpNumberedList([
                "Open Settings ▸ Capture, click Export CA Certificate… and save it as \(CaptureEnvironmentLines.exportFilename) — your home folder is a fine place. The file holds the certificate only, never its key.",
                "Copy the environment lines from the same section and paste them into the terminal you will run the tool from. ReqRes fills in the path you exported to.",
                "Start capture, then run the tool from that terminal. Its requests appear in the traffic list like any other app's — named by its executable (claude, node) with its process id.",
            ])
            helpExample(CaptureEnvironmentLines(proxyPort: CaptureProxyPort.configured).text)
        }

        helpParagraph("The lines set each proxy variable in both spellings — HTTPS_PROXY and https_proxy, HTTP_PROXY and http_proxy: curl and git take the proxy for plain http:// only from the lowercase http_proxy, and a lowercase one already set in your shell would otherwise win over the uppercase one.")

        helpParagraph("NODE_USE_ENV_PROXY=1 makes node's own fetch and https honour the proxy variables (node 24 and later); the Claude Code CLI and most node HTTP libraries read them without it. NODE_EXTRA_CA_CERTS adds the certificate to node's built-in roots. SSL_CERT_FILE replaces a tool's trust store with the file — curl, Python's ssl module and most OpenSSL-based tools read it; Python's requests library does not, and wants the same path in REQUESTS_CA_BUNDLE instead.")

        helpParagraph("The proxy address in the lines is \(ProtocolSupport.proxyURL(port: CaptureProxyPort.configured)) — http://, even for HTTPS traffic: a tool given an https:// proxy address cannot talk to ReqRes at all. The lines also leave localhost, 127.0.0.1 and ::1 out of the proxy (NO_PROXY), so a local backend called from that terminal is not captured; run unset NO_PROXY no_proxy there if you want it in the list.")

        helpTip("Already installed the certificate in your keychain? Then you can skip the export: until ReqRes knows of one, the block in Settings ▸ Capture carries a security line that writes this Mac's certificate from your login keychain to \(CaptureEnvironmentLines.fallbackCertificatePath), picked by its fingerprint — an older certificate with the same name can sit beside it after an upgrade — and the lines point there.")

        helpWarning("These lines work only while capture is running. With capture stopped, the proxy address refuses connections and every request from that terminal fails until you unset them or open a fresh one. The same goes for a host you have excluded in Settings ▸ Capture: ReqRes relays that connection untouched, and a trust store replaced by SSL_CERT_FILE can no longer verify the real server.")

        helpParagraph("An AI agent connected over MCP can ask for the same lines with the capture_environment tool. It gets them with the path you exported to — or is told that the export is the step still missing — so an agent can set up capture of its own traffic without you pasting anything.")
    }
}

// MARK: - 5. Rules

private var rulesTopic: some View {
    helpTopic(HelpTopic.rules.title, systemImage: HelpTopic.rules.systemImage, id: HelpTopic.rules.id) {
        helpParagraph("A rule matches requests to one host filter and changes what happens to them. Every rule has a mode, and the mode is the whole difference between the three:")

        helpHeading("Override — replace the response entirely") {
            helpParagraph("With a response body, matching requests never reach the real server: ReqRes answers on its behalf with exactly what the rule specifies, so the mock works even with the server down, and the server never receives the request. An override with no body still sends the request, and replaces the status and headers of the real answer. Its Status is the one it answers with — an override never keeps the server's. Because an override's response carries only the rule's headers, a new override starts with Content-Type: application/json; charset=utf-8 among them — change it for anything but JSON.")
            helpExample("""
            Host: api.example.com
            Path: /orders  (Wildcard)
            Response status: 500
            Response body: {"error":"Service Unavailable"}

            → Any request to /orders now fails with a 500, without your
              backend needing to be down. Good for testing error handling.
            """)
        }

        helpHeading("Extend — add to the real response") {
            helpParagraph("The request still goes to the real server; the rule adds to what goes out, and the answer comes back with the server's own status — unless the rule's Status names one instead of \(RuleResponseDefaults.keepServerStatusTitle), which then replaces it, a 404 or a 500 included — and with the rule's response headers set over the server's. The body passes through unless the rule gives one. Request headers the rule sets replace the app's of the same name, all but Content-Length and Transfer-Encoding: they describe the app's own body, so they stay as the app sent them.")
            helpExample("""
            Host: api.example.com
            Path: /*  (Wildcard)
            Request headers added: X-Debug-Session: local

            → Every request you make gets tagged, so you can filter for
              your own traffic in a shared backend's logs. The request is
              otherwise unchanged, and so is every response.
            """)
        }

        helpHeading("Map Local — answer with a file") {
            helpParagraph("The request never reaches the real server — the mock works with the server down — and ReqRes answers with the contents of a file on disk instead, always as 200 OK, labelled with the file's own type. Response headers set on the rule (its Headers row — a CORS header, say) are sent with it, and a Content-Type among them replaces the file's. If ReqRes can't read the file — it was moved or deleted, or it was chosen in an earlier version of ReqRes and ReqRes has been relaunched since — the rule is marked in the Overrides list, and a matching request is answered with 500 and a note saying so, never with the real server's response. Edit the rule and choose the file again.")
            helpExample("""
            Host: api.example.com
            Path: /config.json  (Wildcard)
            Local file: ~/Desktop/flags-on.json

            → Try a feature-flag combination or a mocked payload without
              deploying anything or changing the real server's response.
            """)
        }

        helpTip("A rule needs a host filter to belong to — “All traffic” is a view, not a real filter, and can't hold a rule. Add the host first (sidebar ＋), then create the rule under it.")
    }
}

// MARK: - 6. Pattern syntax and its traps

/// The four examples come from `HelpPatternExample.all` (MCPKit) rather than
/// being typed out again here — `HelpPatternExamplesTests` checks each one
/// against `OverridePattern`, the proxy's real matcher, so a wrong claim
/// about what matches fails the test suite instead of shipping.
private var patternsTopic: some View {
    helpTopic(HelpTopic.patterns.title, systemImage: HelpTopic.patterns.systemImage, id: HelpTopic.patterns.id) {
        helpParagraph("A rule's path is the pathname and query only — never the host, ReqRes already knows that from the filter the rule belongs to. Wildcard mode treats * as “match anything here”; Regex mode compiles the path as a regular expression. Each trap below causes a rule to look correctly configured and simply never fire — no error, nothing in the list explains it.")

        helpParagraph("Use the ? button next to a rule's URL field to test a pattern against a real URL before saving — it shows exactly what ReqRes will compile, which is the fastest way to catch these.")

        ForEach(HelpPatternExample.all) { example in
            helpHeading(example.title) {
                helpParagraph(example.explanation)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("✗ Never fires")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                        helpExample(example.badPath)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("✓ Works")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                        helpExample(example.goodPath)
                    }
                }
            }
        }
    }
}

// MARK: - 7. Breakpoints

/// The only feature in the app that STOPS traffic, so the first thing it has
/// to say is what that costs — a held request is a stopped browser, and the
/// person reading this is quite possibly reading it because something is
/// hanging. The timeout is interpolated from `BreakpointRegistry
/// .decisionTimeout` rather than typed out, so the number here cannot drift
/// from the one the extension actually counts down.
private var breakpointsTopic: some View {
    helpTopic(HelpTopic.breakpoints.title, systemImage: HelpTopic.breakpoints.systemImage, id: HelpTopic.breakpoints.id) {
        helpParagraph("A rule changes a request every time it matches, without asking. A breakpoint does the opposite: it stops one matching request before it reaches the server and waits for you. You then send it on as it is, send it on with headers or a body you have changed, or fail it outright with a status code of your choosing — deciding, per request, what your app is about to see.")

        helpWarning("A held request is a stopped app. While ReqRes waits for your answer, whatever made that request is still waiting for its response — a page stays blank, a spinner keeps spinning, and a request with a short timeout of its own may give up before you answer. That is why nobody answering is a valid outcome: after \(Int(BreakpointRegistry.decisionTimeout)) seconds ReqRes stops waiting and sends the request on unchanged, exactly as if you had never been asked.")

        helpHeading("Aiming one") {
            helpNumberedList([
                "Open Settings ▸ Breakpoints.",
                "Type the host to hold — an exact host like api.example.com or localhost, or *.example.com for its subdomains (but not example.com itself, the same wildcard rule the exclusion list uses).",
                "Optionally narrow it: “Path contains” is plain text matched anywhere in the URL (/orders catches /v2/orders and /orders/42), and the method menu limits it to the verbs you pick. Leave both alone and every request to that host is held.",
                "Click Add Breakpoint. It applies to requests that start after it, on new connections and open ones alike — anything already in flight finishes the way it started.",
            ])
        }

        helpParagraph("Each rule has its own switch, so you can leave one aimed and disarmed between debugging sessions. The pane says at the top how many are armed, and has a Turn All Off button next to that count — the fastest way back to traffic flowing normally.")

        helpWarning("Breakpoints hold HTTPS and plain http:// requests alike. A host you have listed in Settings ▸ Capture is never held, by design — ReqRes relays those connections untouched, so it does not see the requests inside them at all.")

        helpHeading("When one fires") {
            VStack(alignment: .leading, spacing: 4) {
                helpBullet("ReqRes shows the held request in a panel with its method, URL and headers, and a clock counting down the \(Int(BreakpointRegistry.decisionTimeout)) seconds it has left. The request is held as soon as its headers arrive, and ReqRes does not show its body: the Body tab says what the request declares — an empty body, or one not shown, with its size when the request gives one — and Resume sends the body unchanged. Replace Body… sends one you type in its place; until you type something, the original goes. \(HeldRequestBody.originalDroppedNote)")
                helpBullet("Content-Length and Transfer-Encoding are shown but cannot be edited: they describe the body, so the request's own go with its own body, and a replacement body gets a Content-Length counted from it. A TRACE request, which may not carry a body, is not offered one, and over HTTP/1.1 one that arrives with a body of its own is answered 502 by ReqRes when resumed instead of being forwarded — its Body tab says so.")
                helpBullet("The panel does NOT take the keyboard, and no key is bound to sending the request on. It can appear while you are typing somewhere else, and a keystroke meant for your editor must never answer it — the buttons also stay inert for a moment after it opens for the same reason.")
                helpBullet("Several requests can be held at once — a page load matching a broad rule will do exactly that. They queue, each with its own countdown, and the panel says how many are waiting behind the one you are looking at.")
                helpBullet("Turning a breakpoint off, or deleting it, does not release a request it is already holding while another breakpoint is still armed — answer it, or let its clock run out. With none left armed, everything held is released, unchanged.")
                helpBullet("Requests are held only while ReqRes is receiving capture. While it reconnects to a capture that kept running without it — after it quit unexpectedly, say — or while the traffic list says it isn't receiving capture, a matching request goes through unheld, since nobody could answer it. A request held before ReqRes went away comes back to the panel once it reconnects, with what is left of its \(Int(BreakpointRegistry.decisionTimeout)) seconds.")
            }
        }

        helpHeading("Letting an AI agent answer one") {
            VStack(alignment: .leading, spacing: 4) {
                helpParagraph("A connected agent can always READ what is held. Answering is separate, off by default, and lives under Agents in the same Settings ▸ Breakpoints pane: with it on, an agent can resume a held request, change its headers or body first, or fail it — the same three choices you have in the panel.")
                helpBullet("Agents can never create a breakpoint. The rules are yours; an agent only ever acts on a request you already chose to stop.")
                helpBullet("This is the one agent change ReqRes does not ask you about each time. A held request is released after \(Int(BreakpointRegistry.decisionTimeout)) seconds and waiting for an approval could take longer than the request has, so the permission is granted once, here, instead of per decision.")
                helpBullet("Every decision an agent makes is written to Settings ▸ MCP ▸ Activity, with the header values it set. Turning the switch back off applies to the very next decision.")
                helpBullet("When an agent answers the last held request, the panel stays open and says so, rather than vanishing while you are reading it.")
            }
        }

        helpTip("Aim narrowly. A breakpoint on a host with no path or method set will hold every image, font and analytics ping that host serves, and you will spend the countdown reading the wrong request. One endpoint and one method is what this is for.")
    }
}

// MARK: - 8. Saving sessions

/// The only feature that writes captured traffic to disk, so the two
/// questions it has to answer up front are "what did I just keep?" and
/// "where did it go?" — the same disclosure `StorageSettingsView` makes, in
/// the place someone looks BEFORE saving their first one.
private var savingTopic: some View {
    helpTopic(HelpTopic.saving.title, systemImage: HelpTopic.saving.systemImage, id: HelpTopic.saving.id) {
        helpParagraph("Captured traffic lives in memory: it fills up as you browse, older requests are dropped to make room, and quitting ReqRes clears all of it. Saving a session is how you keep one past that — the request you want to come back to tomorrow, or hand to an AI agent to look at.")

        helpParagraph("Nothing is ever saved automatically. A session is written to disk only when you ask for that one, or when an agent asks and you approve it.")

        helpHeading("Saving and finding them again") {
            helpNumberedList([
                "Right-click a request in the traffic list and choose Save session. With several rows selected the menu says how many it will save, so it can't quietly take more than you meant.",
                "Open the Saved Sessions window from the menu bar to browse what you kept — newest first, with the full request and response exactly as they were captured.",
                "Delete one from that window, or all of them at once in Settings ▸ Storage, which also shows how many there are and how much space they use.",
            ])
        }

        helpWarning("A saved session keeps its REAL values — headers, cookies, tokens and bodies are stored unmasked, because a saved session full of «redacted» would be useless for the debugging you saved it for. It goes into ReqRes's app group container, next to the app's own database: an ordinary file in your home folder that anything running as you can read, and that any backup of your home folder includes. Settings ▸ Storage shows the exact location and has the button that deletes the lot.")

        helpTip("Redaction still applies to anything that LEAVES ReqRes: an AI agent reading a saved session over MCP gets the same masked view it gets of live traffic, unless you've listed that host under Settings ▸ MCP ▸ Redaction.")
    }
}

// MARK: - 9. Seeing where requests go

/// The map is the one surface that says something about a request the
/// request itself does not — where its server is — so the topic spends most
/// of its words on what that claim does and does not mean. Every sentence
/// about the country is `DestinationCopy`'s, the same one the map, Settings
/// and the agent's report print.
private var destinationsTopic: some View {
    helpTopic(HelpTopic.destinations.title, systemImage: HelpTopic.destinations.systemImage, id: HelpTopic.destinations.id) {
        helpParagraph("Window ▸ Destinations (⌘⇧D, or the map button in the toolbar) plots the countries your captured requests went to on an Apple Maps world map — the busiest as the largest dots — with a list beside it: requests, data, the hosts behind each destination and the apps that made them. Scroll or pinch to zoom, drag to pan, use the + and − controls, and the Fit button in the map's corner frames every destination again. Select one and click Show in Traffic, or double-click it, to filter the traffic list to it.")

        // The column is the destination surface most people meet first — it is
        // in the traffic list at every width — so the topic names it and where
        // its switch is. Its sentence is the column's own (`DestinationColumnCopy`).
        helpParagraph("\(DestinationColumnCopy.summary) The traffic list's Destination column says so on every row — a flag or symbol beside the URL, with the name when the column is wide enough and in the tooltip otherwise. Settings ▸ General ▸ Traffic List turns the column off. Any column but Code and URL can be resized by dragging its divider in the header; double-click the divider, or right-click the header and choose Reset Column Widths, to put it back.")

        helpHeading("What the map knows, and what it does not") {
            VStack(alignment: .leading, spacing: 4) {
                helpBullet(DestinationCopy.whatACountryMeans)
                helpBullet("\(DestinationCopy.mapPrivacy) The table stops at the country — no city, no coordinates. Without a network connection the map is blank; the dots and the list still work.")
                helpBullet(DestinationCopy.mapTilesInTraffic)
                helpBullet("Requests to this Mac (127.0.0.1) and to your local network (10.x, 172.16–31.x, 192.168.x) are listed under those names beside the map rather than plotted. Unknown means the address was missing or is not in the table — or no server was contacted at all, because a rule answered the request.")
                helpBullet("The You marker is approximate: it sits at the centre of the country your Mac's time zone belongs to. Location Services are never asked, and an AI agent is never told where you are.")
            }
        }

        helpHeading("From the map to the requests") {
            VStack(alignment: .leading, spacing: 4) {
                helpBullet("Type country: in the search field for the same filter — country:US, or a name, and country:local, country:mac and country:unknown for the three classes. Right-click a request for Show Destination on Map.")
                helpBullet("An agent gets the same picture from list_destinations — with app: it becomes where one tool sends data — and can filter list_sessions by country.")
            }
        }

        helpTip("A VPN does not hide the dots behind its exit: ReqRes records the address your Mac actually connected to. A CDN may still pick an edge near the VPN's exit, so those dots can move.")
    }
}

// MARK: - 10. Connecting an AI agent

private var mcpTopic: some View {
    helpTopic(HelpTopic.mcp.title, systemImage: HelpTopic.mcp.systemImage, id: HelpTopic.mcp.id) {
        helpParagraph("ReqRes runs a small MCP (Model Context Protocol) server so an AI assistant — Claude Desktop, Claude Code, or another MCP client — can read the traffic it captures and, with your approval, act on it: create rules and host filters, map a URL to a local file, or start and stop capture.")

        helpHeading("What makes this safe to leave on") {
            VStack(alignment: .leading, spacing: 4) {
                helpBullet("Loopback only — the server listens on 127.0.0.1, only while ReqRes is running. A client also needs to read ReqRes's own handshake file to connect at all.")
                helpBullet("Reads are redacted before they leave ReqRes — credential-shaped values (Authorization, Cookie, tokens, JWTs) never reach the assistant, even if you ask it to show you a header. If that gets in your way on a host you know holds nothing real, list it under Settings ▸ MCP ▸ Redaction and its traffic goes through unmasked. Only that host’s.")
                helpBullet("Writes ask first. Every change an agent proposes — in one turn, as a single batch — shows an approval panel in ReqRes with what would change; nothing happens until you answer Allow, Allow for This Session, or Deny. If you don’t answer within 45 seconds ReqRes stops waiting and nothing changes — the assistant is told the request timed out, not that you refused, so it may ask again.")
                helpBullet("The same free-tier limits as the app itself apply to an agent's writes: 2 host filters, 1 override rule. There's no separate, more generous quota for automation.")
            }
        }

        helpParagraph("The bridge is on by default. Turn it off entirely, or stop it asking before every change, in Settings ▸ MCP — that toggle is the kill switch, and Settings ▸ MCP also has the exact configuration to paste into your AI tool and a log of everything an agent has actually done.")
    }
}

// MARK: - 11. Troubleshooting

private var troubleshootingTopic: some View {
    helpTopic(HelpTopic.troubleshooting.title, systemImage: HelpTopic.troubleshooting.systemImage, id: HelpTopic.troubleshooting.id) {
        helpHeading("Nothing is being captured") {
            VStack(alignment: .leading, spacing: 4) {
                helpBullet("Check the toolbar's capture button is actually showing “running”, not just that the extension is installed — installing and starting are two different steps (see “Setting Up Capture”).")
                helpBullet("If the app's main window still shows the setup checklist instead of your traffic, the extension isn't fully approved yet — the checklist names the exact step you're on.")
                helpBullet("HTTPS rows show only a host and port, “not decrypted”, and the bytes each way? The certificate was not installed and trusted when those connections opened, so each was relayed, not read — see “Trusting the Certificate”. Installed but not yet trusted is the same: relayed, never refused. Trust it in Settings ▸ Certificate; connections opened after that are decrypted without restarting capture.")
                helpBullet("A host filter or search text can hide traffic that ReqRes IS capturing — check “All traffic” and clear the search field before assuming nothing arrived.")
                helpBullet("A tool run from a terminal — the Claude Code CLI, node, a Go program, anything inside a Docker container — never reads the system proxy, so it is not captured until told where ReqRes is. See “Capturing Command-Line Tools and Coding Agents”.")
                helpBullet("Some of a site's requests appear and others do not? The missing ones may be HTTP/3 (QUIC), which never passes through the proxy, or an app that refuses ReqRes's certificate. “Supported Protocols” lists what ReqRes captures and what to do about each of the rest.")
                helpBullet("If ReqRes quits unexpectedly while capturing, capture keeps running. Open ReqRes again: it reconnects, usually within a few seconds, and lists the most recent of what was captured meanwhile, with a line above the list saying how many requests that was and how many earlier ones, if any, were not kept. If it cannot reconnect — capture was started from System Settings, or its extension is from an earlier ReqRes build — ReqRes restarts capture once by itself and says why; if “\(CaptureDeliveryCopy.notReceivingTitle)” stays, click \(CaptureDeliveryCopy.restartButton) there. Quitting ReqRes normally still asks first, and stops capture.")
            }
        }

        helpHeading("A long download, stream or WebSocket stopped") {
            VStack(alignment: .leading, spacing: 4) {
                helpBullet(LiveCaptureEngineFacts.idleSentence)
                helpBullet("A body larger than 16 MB is still sent on in full; ReqRes keeps the first part for display and the Body tab says how much is not shown.")
                helpBullet(CaptureEngineFacts.http2RetentionSentence())
                helpBullet("A streamed response — server-sent events (text/event-stream) or JSON lines — has an Events tab beside Body: each complete event numbered, with its name and data, and for an Anthropic or OpenAI stream the answer put back together (text, tool calls, stop reason, tokens). An event cut off at the end is counted as pending, not shown as an event.")
                helpBullet("A gRPC-Web or Connect call has an RPC tab: the service and method, each request and response message decoded without its .proto (field numbers and values — a field is shown as text, a nested message or bytes, and the other readings that fit are named), and the call's own status. A gRPC-Web error arrives as HTTP 200, so the table shows the RPC status beside it — 200 · NOT_FOUND — and grpc:error in the search field finds every failed call. Native gRPC (HTTP/2) is read the same way: its status comes from the response trailers, or from the response head when the server answered with trailers only.")
                // Protocol-engine doc §S9: where HTTP/2 and trailers show.
                helpBullet("\(HTTP2CaptureCopy.toggleTitle) in Settings ▸ Capture is off by default. \(HTTP2CaptureCopy.caption) \(HTTP2CaptureCopy.appliesTo) The Metrics tab's Protocol row says what a request spoke — HTTP/1.1, HTTP/2, WebSocket or relay/tcp — and proto:h2 (or h1, ws, relay) in the search field finds them.")
                helpBullet("Trailers — header fields a server or app sends after the body, where native gRPC puts grpc-status — appear in the Headers tab under their own heading, on both sides.")
            }
        }

        helpHeading("A rule never fires") {
            VStack(alignment: .leading, spacing: 4) {
                helpBullet("Check the rule's own toggle in the Rules list — a disabled rule matches nothing.")
                helpBullet("Check the pattern against the four traps above — a leading ^, a path not starting with /, the host typed into the path, or a wildcard path that stops before the query (/search does not match /search?q=x — write /search*) are all silent, not errors.")
                helpBullet("Check the rule is under the host filter you're actually generating traffic to — a rule only applies to its own host, never to “All traffic” as a whole.")
            }
        }

        helpHeading("A breakpoint never fires, or everything has frozen") {
            VStack(alignment: .leading, spacing: 4) {
                helpBullet("Nothing held when you expected it? Check the breakpoint's switch in Settings ▸ Breakpoints (the pane says how many are armed), check its method and path match the rule, and check its host isn't on the Settings ▸ Capture exclusion list, which is relayed untouched. Nothing is held either while ReqRes is reconnecting to a running capture, or says it isn't receiving it.")
                helpBullet("Too much held? A rule with no path or method set holds every request to that host, images and analytics pings included. Turn All Off is beside the armed count; then narrow the rule and switch it back on.")
                helpBullet("A page hanging with ReqRes running and no panel in sight is usually a held request whose panel ended up behind the window you're working in — it deliberately does not come to the front and take your keyboard. Click ReqRes in the Dock to find it. Either way the hold ends on its own after \(Int(BreakpointRegistry.decisionTimeout)) seconds and the request goes through unchanged.")
            }
        }

        helpHeading("The App column is missing, or everything says Unknown") {
            helpBullet("ReqRes reads which process owns a connection from the kernel's socket table and checks that reading against its own socket every time capture starts. If the check fails — after a macOS update, most likely — the column is hidden rather than filled with guesses, and Capture ▸ Diagnose Setup… says so. Capture is unaffected. Please report it, with your macOS version.")
        }

        helpHeading("Everything on the map says Unknown") {
            helpBullet("Either the running extension predates the server-address field — stop and start capture, and if that does not change it, restart your Mac so macOS swaps in the new extension — or the country table inside the app could not be read. Capture ▸ Diagnose Setup… says which after a few dozen requests, and so does the Unknown pill's tooltip in the Destinations window.")
        }

        helpHeading("The map is blank, or goes blank while capturing") {
            helpBullet("The map tiles are Apple Maps and need a network connection; the Destinations window says so under the map when there is none. If the map is blank only while capture is running, check Settings ▸ Capture: *.ls.apple.com — Apple's map servers — should be in the excluded list, so the tile fetches are relayed untouched instead of intercepted. Stopping capture is the other way to confirm it.")
        }

        helpWarning("Running capture can break codesign. Code signing asks Apple's timestamp service for a signed timestamp, and it fails when that exchange does not come back exactly as Apple sent it — you'll see “A timestamp was expected but was not found” on something that has nothing to do with ReqRes. ReqRes excludes Apple’s timestamp service (timestamp.apple.com) from capture by default, over https:// and plain http:// alike, so its requests are not recorded and no rule touches them — HTTPS passes through untouched with Apple's own certificate, and plain http:// is forwarded as any proxy forwards it — Settings ▸ Capture is where that list lives, and where to add anything else that pins certificates. If signing still fails, stop capture while you run it.")

        helpWebDocsBanner("Full documentation at reqresapp.com/docs", url: "https://reqresapp.com/docs")
    }
}
