//
//  CAMigrationSheet.swift
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
//  The launch offer to replace an older "ReqRes CA" (protocol PRD 4 Phase
//  2.1, shell step S4). A sheet on the main window, in the shape of the other
//  forms (13pt title, 11pt context line, Cancel · primary). It says why (one
//  sentence, chosen by what is actually in the keychain: the 1.0.x shared
//  certificate, or an earlier install's), what the button does in order, and
//  what "Not Now" leaves behind. Every word is
//  `CertificateAuthorityPresentation` (MCPKit, tested). The work is
//  `CertificateAuthorityService.replaceOutdated()`, which the Certificate
//  settings pane's banner also calls. Nothing is removed without the click.
//

import SwiftUI
import MCPKit
import Utils

struct CAMigrationSheet: View {
    typealias Copy = CertificateAuthorityPresentation

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = CertificateAuthorityService.shared
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(Copy.sheetTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(Copy.sheetSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                if let reason = Copy.sheetReason(for: service.outdated) {
                    Text(reason)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(MCPCaptureEnvironment.replaceOldCertificateButton) will:")
                    ForEach(Array(Copy.sheetSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).")
                                .monospacedDigit()
                                .frame(width: 14, alignment: .trailing)
                            Text(step)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(Copy.sheetPasswordNote)
                    .foregroundStyle(.secondary)
                Text(Copy.sheetDeclineNote(for: service.outdated))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(Copy.declineButton) {
                    service.declineOffer()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(service.isReplacing)
                Spacer()
                if service.isReplacing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Replacing the certificate")
                }
                Button(MCPCaptureEnvironment.replaceOldCertificateButton) { replace() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(service.isReplacing)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 440)
    }

    private func replace() {
        errorMessage = nil
        Task {
            switch await service.replaceOutdated() {
            case .done:
                dismiss()
            case .cancelled:
                errorMessage = Copy.sheetCancelledNote
            case .failed(let message):
                errorMessage = message
            }
        }
    }
}
