//
//  CertificateExplanationSheet.swift
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
//  What the ? in Settings ▸ Certificate opens (shell step S12): the certificate
//  explained — what it is, its details, and how to remove it by hand. Only THIS
//  Mac's certificate: the 1.0.x one it replaced is not mentioned —
//  `CAMigrationSheet` and the pane's banner tell a user who still has it. Every
//  sentence is `CertificateAuthorityExplanation` (MCPKit), which Help's
//  certificate topic prints too; this file only lays it out and fills in what
//  differs per install, READ from this Mac's certificate
//  (`CertificateAuthorityFacts`).
//
//  A SHEET, not a popover: the removal steps are carried out in Keychain
//  Access and Terminal, and a popover closes the moment the user switches to
//  either — taking the steps and the command with it. A sheet stays put.
//

import AppKit
import SwiftUI
import MCPKit

struct CertificateExplanationSheet: View {
    typealias Explained = CertificateAuthorityExplanation

    /// This install's CA, DER — nil until the pane's first refresh.
    let certificateDER: Data?

    @Environment(\.dismiss) private var dismiss

    private var facts: CertificateAuthorityFacts? {
        certificateDER.flatMap(CertificateAuthorityFacts.read(der:))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Explained.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("Settings ▸ Certificate")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("What it is") {
                        paragraph(Explained.whatItIs)
                        paragraph(Explained.whatItIsNot)
                    }
                    section(Explained.detailsHeading) {
                        if let facts {
                            factGrid(Explained.installFacts(facts))
                            caption(Explained.sha256Pointer)
                        }
                        ForEach(Explained.policy, id: \.self) { bullet($0) }
                    }
                    .id("details")
                    section(Explained.removeHeading) {
                        paragraph(Explained.removeIntro)
                        numbered(Explained.keychainSteps)
                        paragraph(Explained.terminalIntro)
                        CommandBlock(caption: Explained.listCommandCaption, command: Explained.listCommand())
                        if let sha1 = facts?.sha1, let current = Explained.deleteCommand(sha1Hex: sha1) {
                            CommandBlock(caption: Explained.currentCommandCaption, command: current)
                        }
                        caption(Explained.afterRemovingCurrent)
                            .id("end")
                    }
                    .id("remove")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if DEBUG
            .onAppear {
                // `REQRES_UI_PROBE_SHEET_SCROLL=details|remove|end`: the probe's view
                // of a part below the first screen (a sheet taller than the
                // screen is clamped, so height alone cannot show it all).
                guard let anchor = ProcessInfo.processInfo.environment["REQRES_UI_PROBE_SHEET_SCROLL"] else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo(anchor, anchor: anchor == "end" ? .bottom : .top) }
            }
            #endif
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: Self.height)
        // The sheet's own colour, painted: the same on screen, and the
        // probe's `cacheDisplay` does not draw a window background (dark text
        // on nothing reads as white on white).
        .background(Color(nsColor: .windowBackgroundColor))
    }

    #if DEBUG
    /// `REQRES_UI_PROBE_SHEET_HEIGHT`: the probe renders the whole sheet in
    /// one capture instead of its first screen.
    static var height: CGFloat {
        ProcessInfo.processInfo.environment["REQRES_UI_PROBE_SHEET_HEIGHT"].flatMap(Double.init).map { CGFloat($0) } ?? 560
    }
    #else
    static let height: CGFloat = 560
    #endif

    // MARK: - Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            paragraph(text)
        }
    }

    private func numbered(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    paragraph(item)
                }
            }
        }
    }

    /// One label column for every row (one `Grid`, the forms' rule).
    private func factGrid(_ facts: [CertificateAuthorityExplanation.Fact]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(facts) { fact in
                GridRow {
                    Text(fact.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(fact.value)
                        .font(fact.label == "SHA-1" || fact.label == "Serial number"
                              ? .system(size: 11, design: .monospaced) : .system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12))
    }
}

/// A command to paste into Terminal: selectable, with a Copy button.
private struct CommandBlock: View {
    let caption: String
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 8) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
                // Fixed width: "Copied" must not re-measure the row.
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .frame(width: 64)
                .accessibilityLabel(copied ? "Copied" : "Copy")
                .accessibilityHint(caption)
            }
        }
    }
}
