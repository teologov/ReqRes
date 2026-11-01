//
//  CaptureSettingsView.swift
//  ReqRes
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
//  Roadmap item 14: the hosts ReqRes relays instead of intercepting.
//
//  This is its own tab rather than a section of General because it is the
//  first setting that changes what the ENGINE does to live traffic, and
//  because the thing it prevents — `codesign` failing with a message that
//  points at anything but the proxy — is worth a page someone can be sent to.
//
//  The first section (process-attribution PRD §5E, UX spec §7) is the other
//  page someone gets sent to: "why don't I see this tool?" Capture reaches an
//  app through the system proxy settings the extension publishes, and the
//  Claude Code CLI and most node HTTP libraries never read those. They read
//  HTTPS_PROXY, and node also wants the CA as a file — which lived in a
//  TCC-protected container nobody could copy out of. The save panel is how
//  it gets out. It comes FIRST because every deep link into this tab now
//  arrives from that question, and the tab scrolls.
//
//  The block itself is rendered by `CaptureEnvironmentLines` in MCPKit — the
//  ONE renderer the `capture_environment` tool and Help print from too — so
//  the pane can never show lines the agent does not.
//

import AppKit
import NetworkExtension
import MCPKit
import SwiftUI
import UniformTypeIdentifiers
import Utils
import XReqResCore

struct CaptureSettingsView: View {
    @ObservedObject private var settings = ExcludedHostsSettings.shared
    @ObservedObject private var learnedPins = LearnedPinsSettings.shared
    @ObservedObject private var appState = AppState.shared
    /// The proxy's port (Settings ▸ Capture ▸ Proxy port): stored as the
    /// number `ProxyPortSetting.current` reads; edited as text so a bad value
    /// can be refused with a reason instead of silently coerced.
    @AppStorage(ProxyPortSetting.defaultsKey) private var storedProxyPort = ProxyPortSetting.defaultPort
    @State private var proxyPortText = ""
    /// The texts Apply and Add refused, exactly as submitted (F13). The notes
    /// under the two fields are derived from them, the fields and the list on
    /// every render, never stored: a stored note outlived what it was about —
    /// "“example.net” is already excluded." stayed after the host was removed
    /// and the field emptied. An edit clears the submission, as
    /// Breakpoints' note clears on an edit, so retyping the same text does
    /// not bring a note back before the next Apply or Add.
    @State private var refusedPortText: String?
    @State private var newHost = ""
    @State private var refusedHost: String?

    /// The last export's path, so the block below can show the real one. Not
    /// verified against the disk on read: outside the sandbox `fileExists`
    /// answers false for a file that is there, and "not exported" over a
    /// successful export is the worse lie.
    @AppStorage(CaptureEnvironmentLines.exportedPathDefaultsKey) private var exportedCertificatePath = ""
    /// The SHA-256 of the certificate that export wrote (step C8). An export
    /// whose fingerprint is not this install's CA's — or that has none,
    /// because a build before 1.1.0 wrote it — holds a CA tools can no
    /// longer use, and the pane says to export again.
    @AppStorage(CaptureEnvironmentLines.exportedFingerprintDefaultsKey) private var exportedCertificateFingerprint = ""
    @State private var exportNote: String?
    @State private var exportFailed = false
    @State private var copiedEnvironment = false
    /// D8: client-cancelled requests are hidden from the traffic list unless
    /// this is on. Absent means off.
    @AppStorage(CancelledRequestsSetting.defaultsKey) private var showCancelled = false
    /// Decision D11 (doc §S9): HTTP/2 capture, a beta, OFF by default. The
    /// app's OWN defaults — the extension runs as root and would read root's
    /// copy of the app group's; the value crosses in the start options and
    /// the `http2Changed` bus action instead (`HTTP2CaptureSync`).
    @AppStorage(HTTP2CaptureSetting.defaultsKey) private var captureHTTP2 = false

    var body: some View {
        Form {
            Section("Capture a command-line tool") {
                // The "need nothing else" claim is hedged on the certificate
                // (HTTPS from those apps is unreadable until it is trusted).
                // curl and git are in the "do not" half: measured in the
                // 2026-09-29 live run, Apple's curl and `git ls-remote`
                // connected straight to the server with capture on.
                Text("ReqRes captures by publishing proxy settings for the whole Mac while capture runs. Safari, Mail, Xcode and Electron apps read them and, once the certificate is trusted, need nothing else. curl, git, the Claude Code CLI, node, Go programs and anything inside a Docker container do not — they need the lines below, and most of them also need the certificate as a file.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // General's "Last checked" shape: the state beside the button
                // that changes it.
                LabeledContent("CA certificate") {
                    HStack(spacing: 10) {
                        if exportFreshness == .outdated {
                            // The block below has already fallen back to the
                            // keychain line; this names the file that broke.
                            Label("\(Self.tildePath(exportedCertificatePath)) holds an older CA — export again",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help("ReqRes now creates a certificate authority of its own on every Mac. The file at \(exportedCertificatePath) holds an older one, so tools pointed at it fail TLS.")
                        } else if let path = environment.certificatePath {
                            Text(Self.tildePath(path))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(path)
                        } else {
                            Text("Not exported yet")
                                .foregroundStyle(.secondary)
                        }
                        Button("Export CA Certificate…", action: exportCertificate)
                            .accessibilityHint("Saves the ReqRes CA certificate as a PEM file")
                    }
                }

                // Storage's note shape: plain secondary text for success (no
                // success glyph anywhere in Settings), the orange warning
                // label for a failure.
                if let exportNote {
                    if exportFailed {
                        Label(exportNote, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(verbatim: exportNote)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                environmentBlock

                // Which tools have reached ReqRes — worded as what REACHED it:
                // a tool is listed once its traffic arrived, however it got
                // there (the lines above, or a proxy flag of its own). The index is a plain `var` read on demand, not a
                // publisher, so the line is re-read on a slow tick while the
                // pane is on screen: the person who pasted the lines and ran
                // the tool looks back here for exactly this sentence.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Text(verbatim: commandLineToolsStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }

            // The proxy's port: 8034 by default.
            // Applies at the next start; a running capture says so and offers
            // the restart. Every word is `ProxyPortSetting`'s.
            Section(ProxyPortSetting.settingsTitle) {
                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        TextField("", text: $proxyPortText, prompt: Text(verbatim: String(ProxyPortSetting.defaultPort)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit(applyProxyPort)
                            .onChange(of: proxyPortText) { _, _ in refusedPortText = nil }
                        Button("Apply", action: applyProxyPort)
                            .disabled(proxyPortText.trimmingCharacters(in: .whitespaces) == String(CaptureProxyPort.configured))
                        if CaptureProxyPort.configured != ProxyPortSetting.defaultPort {
                            Button("Use \(String(ProxyPortSetting.defaultPort))") {
                                proxyPortText = String(ProxyPortSetting.defaultPort)
                                applyProxyPort()
                            }
                        }
                    }
                }
                if let proxyPortProblem = ProxyPortSetting.problem(submitted: refusedPortText, current: proxyPortText) {
                    Text(proxyPortProblem)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if appState.vpnStatus == .connected,
                   let running = CaptureProxyPort.started, running != CaptureProxyPort.configured {
                    HStack(spacing: 8) {
                        Text(ProxyPortSetting.pendingNote(running: running, next: CaptureProxyPort.configured))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Restart Capture") { CertificateAuthorityService.restartCaptureIfRunning() }
                            .controlSize(.small)
                    }
                }
                Text(ProxyPortSetting.settingsExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { proxyPortText = String(CaptureProxyPort.configured) }

            // Decision D11: an opt-in beta, matched legs only (C12 never
            // bridges h2 to h1). Every word is `HTTP2CaptureCopy`'s, which
            // Help and diagnose_setup print too.
            Section("HTTP/2") {
                Toggle(HTTP2CaptureCopy.toggleTitle, isOn: $captureHTTP2)
                    .onChange(of: captureHTTP2) { _, _ in HTTP2CaptureSync.push() }
                Text(HTTP2CaptureCopy.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // A word joiner after the slash so "HTTP/1.1" never wraps
                // as "HTTP/" + "1.1" (seen in the render); display only.
                Text("\(HTTP2CaptureCopy.appliesTo) \(HTTP2CaptureCopy.mockedHostsNote)".replacingOccurrences(of: "HTTP/", with: "HTTP/\u{2060}"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Excluded from interception") {
                Text("ReqRes reads HTTPS by re-signing it with its own certificate. Some traffic must not pass through anyone: code signing asks Apple's timestamp service for a signed timestamp and can fail, with an error that points anywhere but here, while that request goes through ReqRes; an app that pins its certificate refuses ReqRes's outright. A host listed below is not recorded and no rule or breakpoint touches it: HTTPS to it is passed straight through, not decrypted; plain http:// is forwarded as any proxy forwards it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // ReqRes's license server first (pay-once A16): the engine
                // relays it in code whatever this list says, so its rows are
                // fixed — no Remove button, and Add refuses it as excluded.
                ForEach(ExcludedHostList.builtIn, id: \.self) { host in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(host)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Text(ExcludedHostList.builtInReason)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.tertiary)
                            .help("Always excluded; cannot be removed")
                            .accessibilityLabel("Always excluded; cannot be removed")
                    }
                }

                ForEach(settings.list.hosts, id: \.self) { host in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary)
                        Text(host)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        if let reason = ExcludedHostList.recommendedReason(for: host) {
                            Text(reason)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("Remove") { settings.stopExcluding(host) }
                            .controlSize(.small)
                            .accessibilityLabel("Capture \(host) again")
                    }
                }

                LabeledContent("Pass through") {
                    HStack(spacing: 8) {
                        TextField("", text: $newHost, prompt: Text("api.example.com or *.example.com"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onSubmit(add)
                            .onChange(of: newHost) { _, _ in refusedHost = nil }
                        Button("Add", action: add)
                            .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                // Re-checked against the list as it is now: removing the host
                // a note named takes the note away.
                if let note = settings.list.refusalNote(submitted: refusedHost, current: newHost) {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if settings.list.hosts.isEmpty {
                    Label("Nothing else is excluded. If code signing or a certificate-pinning app starts failing while capture is on, that is why.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Restore the recommended hosts") { settings.restoreRecommended() }
                        .controlSize(.small)
                } else if !settings.list.missingRecommended.isEmpty {
                    // A list stored before a recommended entry existed (the
                    // Apple Maps hosts arrived with the Destinations map).
                    // Offered, never applied: a removed entry stays removed.
                    Text("Not excluded: \(settings.list.missingRecommended.joined(separator: ", ")) — \(settings.list.missingRecommended.compactMap(ExcludedHostList.recommendedReason(for:)).joined(separator: "; ")).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Add the recommended hosts") {
                        settings.list.missingRecommended.forEach { settings.exclude($0) }
                    }
                    .controlSize(.small)
                }
            }

            // Apps that refused ReqRes's certificate (2026-09-29, WhatsApp's
            // media): remembered per app and domain, passed through, listed
            // in the traffic as SSL pinned. Forget one to try decrypting again.
            Section(PinnedHostCopy.settingsTitle) {
                Text(PinnedHostCopy.settingsExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if learnedPins.list.isEmpty {
                    Text(PinnedHostCopy.settingsEmpty)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(learnedPins.list.records) { record in
                        HStack(spacing: 6) {
                            Image(systemName: "pin")
                                .foregroundStyle(.secondary)
                            Text(record.app.isEmpty ? PinnedHostCopy.anyApp : (record.appName.isEmpty ? record.app : record.appName))
                            Text(record.domain)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                            Text(record.learnedAt, format: .relative(presentation: .named))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Forget") { learnedPins.forget(id: record.id) }
                                .controlSize(.small)
                                .accessibilityLabel("Decrypt \(record.domain) again for \(record.appName)")
                        }
                        .help(record.app)
                    }
                    Button("Forget All") { learnedPins.forgetAll() }
                        .controlSize(.small)
                }
            }

            // Protocol PRD 3.4 / decision D8: what a failure row is, and the
            // one switch — cancelled requests are noise by default.
            Section("Requests that did not complete") {
                Text(FailureRowCopy.settingsExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Show cancelled requests", isOn: $showCancelled)
                    .onChange(of: showCancelled) { _, _ in
                        SessionState.shared.updateFilteredSessions(selectedHost: AppState.shared.selectedHost)
                    }
                Text(FailureRowCopy.cancelledCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Destination-map UX spec §9.1: what the map knows, where it gets
            // it, and the one fact about the USER it derives — from the time
            // zone, never Location Services. Every sentence about what a
            // country means is `DestinationCopy`'s, so Help, the map and the
            // agent's note cannot drift from this pane.
            Section("Destinations") {
                Text("The Destinations window places each request in the country its server address belongs to, using a table bundled with ReqRes; the table stops at the country — no city, no coordinates. \(DestinationCopy.mapPrivacy) Your own Mac is placed from its time zone, never from Location Services.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(DestinationCopy.mapTilesInTraffic)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The same country reaches the traffic list as its Destination
                // column; the switch for that column is General's, so it is
                // pointed at rather than duplicated here.
                Text("\(DestinationColumnCopy.summary) The traffic list's Destination column shows it per request; Settings ▸ General ▸ Traffic List turns the column off.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Country table") {
                    switch DestinationResolver.shared.tableStatus {
                    case .success(let dataMonth):
                        Text("DB-IP Lite · \(dataMonth)")
                            .foregroundStyle(.secondary)
                            .help(DestinationResolver.shared.attribution)
                    case .failure(let error):
                        // Storage's orange warning label: the reason is in
                        // the tooltip, the diagnosis and the Unknown pill say
                        // the same thing.
                        Label("Could not be read", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(DestinationResolver.shared.tableFailureReason ?? error.localizedDescription)
                    }
                }

                LabeledContent("Your approximate location") {
                    Text(originText)
                        .foregroundStyle(.secondary)
                        .help(originHelp)
                }

                Text(DestinationCopy.whatACountryMeans)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("What this means") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("An excluded host's traffic does not appear in ReqRes at all, over https:// and plain http:// alike. HTTPS to it stays encrypted between your app and the real server with the server's own certificate; plain http:// is forwarded as any proxy forwards it (hop-by-hop headers removed), with no row. No rule or breakpoint applies to it.")
                    bullet("A wildcard covers subdomains only: *.example.com passes api.example.com through, but not example.com itself.")
                    bullet("For HTTPS the change applies to connections made after it — one already open keeps the shape it started with. Plain http:// follows it from the next request.")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            // What the engine does to the traffic it carries (protocol PRD
            // D5, D6, D7, D10) — the same sentences Help prints, with the
            // running core's numbers.
            Section("What capture changes, keeps and closes") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(LiveCaptureEngineFacts.sentences, id: \.self) { bullet($0) }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Command-line tool

    /// An outdated export is never printed as the certificate path: the
    /// block falls back to the keychain line until the user exports again.
    private var environment: CaptureEnvironmentLines {
        CaptureEnvironmentLines(
            // The port the NEXT capture uses — what a terminal set up now needs.
            proxyPort: CaptureProxyPort.configured,
            certificatePath: Self.probeCertificatePath ?? (exportFreshness == .outdated ? nil : exportedCertificatePath),
            // The keychain step picks this install's CA by fingerprint.
            caFingerprint: (try? CertificateAuthority.ensureInstallCA())?.fingerprintSHA256
        )
    }

    private var exportFreshness: CaptureEnvironmentLines.ExportFreshness {
        if Self.probeCertificatePath != nil { return .current }
        return CaptureEnvironmentLines.exportFreshness(
            exportedPath: exportedCertificatePath,
            exportedFingerprint: exportedCertificateFingerprint,
            currentFingerprint: (try? CertificateAuthority.ensureInstallCA())?.fingerprintSHA256
        )
    }

    /// The same shape as the MCP pane's configuration box: a caption row with
    /// the Copy button on the right, the text in a GroupBox underneath, and
    /// the instruction as the caption below the box.
    private var environmentBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Environment")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: copyEnvironment) {
                    HStack(spacing: 4) {
                        Image(systemName: copiedEnvironment ? "checkmark" : "doc.on.doc")
                        Text(copiedEnvironment ? "Copied" : "Copy")
                    }
                    .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Copy environment lines")
                .help("Copies the lines exactly as shown")
            }
            GroupBox {
                Text(verbatim: environment.text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Inside a grouped Form the box has no inset of its own
                    // — measured with the layout probe: the first glyph of
                    // each line sat on the box's edge and lost a pixel.
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            // What each line is for, beside the box and never in it: zsh does
            // not read a pasted `#` as a comment (F16), and the box is
            // selectable, so everything in it has to survive a paste.
            Text(CaptureEnvironmentLines.legend)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Paste into the terminal you will run the tool from, then start the tool there; add the lines to your shell profile to capture every run. They only work while capture is on — with it stopped the proxy address refuses connections, so unset them, or open a fresh terminal, when you are done.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if environment.hasKeychainStep {
                // Before an export the block's own `security` line writes the
                // CA out of the login keychain — which only works once the
                // certificate is INSTALLED there (Settings ▸ Certificate):
                // `security` looks it up by name and finds nothing otherwise.
                // The command itself is in the box above, so this says what
                // it needs rather than repeating it.
                Text("Until you export, the security line writes the certificate from your login keychain — it has to be installed there first (Settings ▸ Certificate). Export CA Certificate… does the same from inside the app and points the lines at the file you chose.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !environment.hasExportedCertificate {
                // No export and no fingerprint (the app could not read its
                // CA): there is no security line, and the certificate lines
                // point at the placeholder until an export is recorded.
                Text(verbatim: "Export CA Certificate… first: until ReqRes knows where you saved the certificate, the lines point at \(CaptureEnvironmentLines.fallbackCertificatePath).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Destinations

    /// `"Ukraine (from Europe/Kyiv)"`, or why there is none: `"Not available
    /// — your time zone (UTC) names no country"`. Read from the store on
    /// render, not observed: the store publishes its index at up to 1 Hz
    /// while the map is open, and this pane has no use for that.
    private var originText: String {
        if let origin = DestinationsStore.shared.origin {
            return "\(CountryPresentation.name(for: origin.isoCode)) (from \(origin.timeZoneIdentifier))"
        }
        return "Not available — your time zone (\(TimeZone.current.identifier)) names no country"
    }

    private var originHelp: String {
        if let origin = DestinationsStore.shared.origin {
            return DestinationCopy.origin(countryName: CountryPresentation.name(for: origin.isoCode), timeZone: origin.timeZoneIdentifier)
        }
        return DestinationCopy.originUnknown(timeZone: TimeZone.current.identifier)
    }

    /// Spec §7.7: the processes the index saw outside any app bundle (it
    /// already leaves out the well-known system services — nobody ran WebKit
    /// Networking from a terminal), and whether attribution works on this Mac
    /// at all, which outranks the list.
    private var commandLineToolsStatus: String {
        CommandLineToolsStatus.line(
            tools: SessionState.shared.commandLineTools(),
            attributionAvailable: AppState.shared.processAttribution.isAvailable
        )
    }

    /// Writes the CA certificate where the user points the save panel.
    /// Sandboxed, so the panel IS the permission — the same shape as the
    /// activity-log export in Settings ▸ MCP.
    private func exportCertificate() {
        let panel = NSSavePanel()
        panel.title = "Export CA Certificate"
        panel.nameFieldStringValue = CaptureEnvironmentLines.exportFilename
        panel.directoryURL = URL(fileURLWithPath: Self.homeDirectory, isDirectory: true)
        panel.canCreateDirectories = true
        if let pem = UTType(filenameExtension: "pem") {
            panel.allowedContentTypes = [pem]
        }
        panel.isExtensionHidden = false
        panel.message = "The certificate only — the file contains no private key."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            guard let authority = try? CertificateAuthority.ensureInstallCA(),
                  let certificate = CACertificateExport.certificateOnly(authority.certificatePEM) else {
                throw CertificateExportError.noCertificate
            }
            try Data(certificate.utf8).write(to: url, options: .atomic)
            exportedCertificatePath = url.path
            exportedCertificateFingerprint = authority.fingerprintSHA256
            exportFailed = false
            showExportNote("Exported to \(Self.tildePath(url.path)).")
        } catch {
            exportFailed = true
            showExportNote("Could not export the certificate: \(error.localizedDescription)")
        }
    }

    /// Storage's shape: the note clears itself after 8s, unless a newer one
    /// has replaced it in the meantime.
    private func showExportNote(_ text: String) {
        exportNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if exportNote == text { exportNote = nil }
        }
    }

    /// Exactly the text in the box: it carries no comment (F16 — zsh reads a
    /// pasted `#` as a word, and the first word `export` refuses stops the
    /// paste), so what is shown, what is copied and what a hand selection
    /// pastes are one.
    private func copyEnvironment() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(environment.text, forType: .string)
        copiedEnvironment = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedEnvironment = false
        }
    }

    /// The user's REAL home. Inside the sandbox `NSHomeDirectory()` — and so
    /// `FileManager.homeDirectoryForCurrentUser` and
    /// `abbreviatingWithTildeInPath` — answer with the app's container
    /// (measured: Settings ▸ Storage rendered a real-home path unabbreviated).
    /// A save panel opened in the container, or a path shown without its
    /// tilde, would both be wrong; `getpwuid` is what still knows the home.
    private static let homeDirectory: String = {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            return String(cString: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }()

    private static func tildePath(_ path: String) -> String {
        TildePath.abbreviated(path, home: homeDirectory)
    }

    #if DEBUG
    /// `REQRES_UI_PROBE_CA_PATH=/Users/…/reqres-ca.pem` renders the
    /// post-export state for the layout probe without writing a default into
    /// the container this build shares with an installed copy.
    private static let probeCertificatePath = ProcessInfo.processInfo.environment["REQRES_UI_PROBE_CA_PATH"]
    #else
    private static let probeCertificatePath: String? = nil
    #endif

    private enum CertificateExportError: LocalizedError {
        case noCertificate

        var errorDescription: String? {
            "ReqRes could not find a certificate to export."
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Stores the typed port, or keeps the text so the note under the field
    /// can say why it cannot be one.
    private func applyProxyPort() {
        guard ProxyPortSetting.problem(with: proxyPortText) == nil else {
            refusedPortText = proxyPortText
            return
        }
        refusedPortText = nil
        let port = Int(proxyPortText.trimmingCharacters(in: .whitespaces)) ?? ProxyPortSetting.defaultPort
        storedProxyPort = port
        proxyPortText = String(port)
    }

    /// Excludes the typed host, or keeps the text so the note under the field
    /// can say why it was refused (`ExcludedHostList.refusalNote`).
    private func add() {
        let raw = newHost
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if settings.exclude(raw) {
            newHost = ""
            refusedHost = nil
        } else {
            refusedHost = raw
        }
    }
}

#Preview {
    CaptureSettingsView()
        .frame(width: 700, height: 620)
}
