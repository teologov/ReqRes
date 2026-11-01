//
//  CACertificateModal.swift
//  ReqRes
//
//  Created by OloApps on 6/17/24.
//  Inspired by https://github.com/softnetics/dotlocal/blob/792f44fcb9fbcc291d6b1f9e2fd2523c672e6871/DotLocal/SettingsView.swift#L99
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
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
//  Settings ▸ Certificate (shell step S4). Since 1.1.0 the CA is this
//  install's own (core step C8), so the pane says so — where the key is kept
//  and where it goes, in `CertificateAuthorityPresentation.custody`, the same
//  sentence Help prints — shows its SHA-256 the way Keychain Access does, and
//  keeps a banner with the Replace Old Certificate action while an older
//  "ReqRes CA" is in the keychain (the launch sheet's decline leaves it here).
//  State comes from `CertificateAuthorityService`, read off main; the layout
//  probe seeds it (`REQRES_UI_PROBE=certificate…`).
//
//  The ? at the bottom opens `CertificateExplanationSheet` (shell step S12):
//  what this Mac's certificate is, its details and how to remove it by hand. It
//  says nothing about the 1.0.x certificate: the banner above and the launch
//  sheet are what tell a user who still has that one.
//
//  Install and Trust push the CA state to a running extension, which then
//  intercepts NEW connections — there is no capture restart any more.
//

import SwiftUI
import Foundation
import SecurityInterface
import MCPKit
import Utils
import XReqResCore

struct CACertificateModal: View {
    typealias Copy = CertificateAuthorityPresentation

    @ObservedObject private var service = CertificateAuthorityService.shared
    @State private var errorTitle = ""
    @State private var errorMessage: String?
    /// The ? button's sheet (shell step S12). The layout probe opens it
    /// (`REQRES_UI_PROBE=certificate…-explained`).
    @State private var showingExplanation = CACertificateModal.probeOpensExplanation

    #if DEBUG
    static var probeOpensExplanation: Bool {
        ProcessInfo.processInfo.environment["REQRES_UI_PROBE"]?.hasSuffix("-explained") == true
    }
    #else
    static let probeOpensExplanation = false
    #endif

    var body: some View {
        Form {
            if let banner = Copy.banner(for: service.outdated) {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text(banner).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.system(size: 12))
                        HStack(alignment: .center, spacing: 8) {
                            Text(Copy.sheetPasswordNote)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            if service.isReplacing {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Replacing the certificate")
                            }
                            Button(MCPCaptureEnvironment.replaceOldCertificateButton, action: replaceOutdated)
                                .disabled(service.isReplacing)
                        }
                    }
                }
            }

            Section("ReqRes CA") {
                LabeledContent("Keychain") {
                    HStack(spacing: 10) {
                        stateLabel(service.installed, on: "Installed", off: "Not installed")
                        // Disabled until the first refresh has read the CA:
                        // a click before it used to report "could not prepare
                        // this Mac's certificate" about a CA that was fine.
                        Button(Copy.installButton) { run { await service.installCurrent() } }
                            .disabled(service.installed || service.caUnavailable || service.fingerprint == nil)
                    }
                }
                LabeledContent("Trust") {
                    HStack(spacing: 10) {
                        stateLabel(service.trusted, on: "Trusted", off: "Not trusted")
                        Button(Copy.trustButton) { run { await service.trustCurrent() } }
                            .disabled(!service.installed || service.trusted || service.fingerprint == nil)
                    }
                }
                if let fingerprint = service.fingerprint {
                    // Its own row, label above value: 32 hex pairs do not fit
                    // beside a label, and Keychain Access prints them this way.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SHA-256")
                        Text(Copy.displayFingerprintLines(fingerprint).joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("SHA-256 fingerprint")
                    .accessibilityValue(fingerprint)
                }
                Text(Copy.summary(for: service.status))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Certificate Details…", action: showDetails)
                        .disabled(service.certificate == nil)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Copy.custody)
                    Text(Copy.removalAdvice)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Where its private key is")
            } footer: {
                // Shell step S12: the standard help button, bottom trailing
                // under the last group — where System Settings puts it. It
                // opens a SHEET (see CertificateExplanationSheet for why).
                HStack {
                    Spacer()
                    HelpLink { showingExplanation = true }
                        .help(CertificateAuthorityExplanation.title)
                        .accessibilityLabel(CertificateAuthorityExplanation.title)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingExplanation) {
            CertificateExplanationSheet(certificateDER: service.certificateDER)
        }
        .task { await service.refresh() }
        .alert(errorTitle, isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Text AND symbol, never colour alone.
    private func stateLabel(_ isOn: Bool, on: String, off: String) -> some View {
        Label {
            Text(isOn ? on : off)
        } icon: {
            Image(systemName: isOn ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isOn ? .green : .red)
        }
        .font(.system(size: 12))
    }

    private func run(_ action: @escaping () async -> CertificateAuthorityService.Outcome) {
        Task {
            if case .failed(let message) = await action() {
                errorTitle = "The ReqRes certificate could not be changed"
                errorMessage = message
            }
        }
    }

    private func replaceOutdated() {
        Task {
            switch await service.replaceOutdated() {
            case .done:
                break
            case .cancelled:
                errorTitle = "Not finished"
                errorMessage = Copy.sheetCancelledNote
            case .failed(let message):
                errorTitle = "Could not replace the old ReqRes CA"
                errorMessage = message
            }
        }
    }

    private func showDetails() {
        guard let certificate = service.certificate else { return }
        if let window = NSApp.keyWindow {
            SFCertificatePanel.shared().beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
                                                   certificates: [certificate], showGroup: false)
        } else {
            SFCertificatePanel.shared().runModal(forCertificates: [certificate], showGroup: false)
        }
    }
}

#Preview {
    CACertificateModal().frame(width: 700, height: 620)
}
