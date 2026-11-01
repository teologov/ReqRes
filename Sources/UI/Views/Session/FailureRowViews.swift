//
//  FailureRowViews.swift
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
//  The views for a request that did not complete (protocol PRD 3.4, decision
//  D8; core §C6 writes the rows, protocol-engine doc §S3 is this half):
//
//    - `FailureGlyph` — the table's Code cell for a failed / aborted / timed
//      out row: a chip of `Chip`'s exact metrics carrying the outcome's
//      SYMBOL — colour is never the only signal, and VoiceOver reads the
//      word and the cause. The URL cell stays plain (a red "Failed" before
//      the URL would repeat what the glyph already says).
//    - `FailureBanner` — the strip above the detail naming the cause in one
//      sentence and the one action that helps: "Exclude <host>…" for an app
//      refusing ReqRes's certificate (after a confirmation), "Export the CA
//      and the environment lines…" for a command-line tool.
//    - `FailureConnectionDetailView` — the detail of a row with no request
//      inside it (the app refused ReqRes's certificate before sending one).
//
//  Every word is `FailureRowCopy`'s (MCPKit), which the agent surface prints
//  too.
//

import MCPKit
import SwiftUI
import Utils
import XReqResCore

/// The tint of each outcome. Never the only signal: the chip carries a
/// symbol and the row a word.
enum FailureTint {
    static func color(_ outcome: MCPSessionOutcome) -> Color {
        switch outcome {
        case .completed: return Color(nsColor: Palette.green)
        case .failed: return .red
        case .aborted: return .gray
        case .timedOut: return .orange
        }
    }
}

/// The Code cell of a failure row: `Chip`'s metrics (12pt, 3/6 padding, 25pt
/// minimum) so the row keeps its neighbours' height, filled with the
/// outcome's tint, carrying its symbol.
struct FailureGlyph: View {
    let facts: FailureRowFacts
    var isSelected = false

    var body: some View {
        HStack {
            Image(systemName: FailureRowCopy.symbolName(facts.outcome))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 25, alignment: .center)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .foregroundColor(FailureTint.color(facts.outcome).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.white.opacity(0.8) : Color.clear, lineWidth: 1)
        )
        .help(FailureRowCopy.accessibilityLabel(facts))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FailureRowCopy.accessibilityLabel(facts))
    }
}

/// The header row of a failure's detail: the glyph and the word where an
/// exchange has its status chip, then the method and URL it did have.
struct FailureDetailHeaderRow: View {
    let session: SessionCodable
    let facts: FailureRowFacts

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            FailureGlyph(facts: facts)
            Text(verbatim: FailureRowCopy.label(facts.outcome))
                .fontWeight(.semibold)
                .foregroundStyle(FailureTint.color(facts.outcome))
            // A cut or timed-out exchange may have had a real status (a 200
            // cut mid-body is still a 200); a FAILED row's 502 is ReqRes's
            // own answer, which the banner explains instead.
            if facts.outcome != .failed, let status = session.rspStatus, !status.isEmpty {
                Chip(status: status)
            }
            if !session.method.isEmpty {
                Text(session.method)
                    .fontWeight(.medium)
            }
            Divider()
            Text(verbatim: session.fullUrl)
                .help(session.fullUrl)
                .truncationMode(.tail)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The strip above a failure's detail: the cause, what it means, and the one
/// action that helps. The exclusion goes through a confirmation that states
/// the consequence in the words the agent's consent panel uses.
struct FailureBanner: View {
    let session: SessionCodable
    let facts: FailureRowFacts
    /// Opens Settings ▸ Capture; nil where the pane cannot (a probe, the
    /// saved-sessions browser), and the export button is then left out.
    var openCaptureSettings: (() -> Void)? = nil
    /// The live traffic pane offers the exclusion; the saved browser, which
    /// shows a row from another run, does not.
    var offersExclusion = true
    /// DEBUG probes present the confirmation on first render.
    var presentConfirmationForProbe = false

    @ObservedObject private var exclusions = ExcludedHostsSettings.shared
    @ObservedObject private var learnedPins = LearnedPinsSettings.shared
    @State private var confirmingHost: String?

    /// The pin ReqRes learned from this refusal (or an earlier one for the
    /// same app and domain): the retry already passes through, so the banner
    /// says so and offers Forget instead of Exclude. The domain rule is the
    /// core's (`PinDomain.of`), the one the extension matched with.
    private var rememberedPin: LearnedPinRecord? {
        guard facts.phase == .tlsClient else { return nil }
        let domain = PinDomain.of(host)
        let app = session.processPath ?? session.processName ?? ""
        return learnedPins.list.records.first { $0.domain == domain && ($0.app.isEmpty || $0.app == app) }
    }

    private var host: String {
        // A tlsClient row is `CONNECT host` with no port for 443 (core C6).
        ExcludedHostList.canonicalEntry(session.host) ?? session.host
    }

    private var actions: [FailureRowAction] {
        FailureRowCopy.actions(
            facts,
            host: host,
            isCommandLineTool: session.processIdentity.isCommandLineTool,
            hostAlreadyExcluded: exclusions.list.excludes(host)
        ).filter { action in
            switch action {
            case .excludeHost: return offersExclusion && rememberedPin == nil
            case .exportCertificateAndEnvironment: return openCaptureSettings != nil
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: FailureRowCopy.symbolName(facts.outcome))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FailureTint.color(facts.outcome))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                (Text(verbatim: FailureRowCopy.label(facts.outcome) + ". ").fontWeight(.semibold)
                    + Text(verbatim: FailureRowCopy.cause(facts)))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ForEach(FailureRowCopy.notes(facts), id: \.self) { note in
                    Text(verbatim: note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let pin = rememberedPin {
                    Text(verbatim: PinnedHostCopy.rememberedNote(appName: session.processIdentity.displayName, domain: pin.domain))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if offersExclusion {
                        Button("Forget") { learnedPins.forget(id: pin.id) }
                            .controlSize(.small)
                    }
                }
                if facts.phase == .tlsClient, offersExclusion, exclusions.list.excludes(host) {
                    Text(verbatim: FailureRowCopy.alreadyExcluded(host))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(actions, id: \.self) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        if let explanation = FailureRowCopy.explanation(action, cause: FailureRowCopy.cause(facts)) {
                            Text(verbatim: explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(FailureRowCopy.buttonTitle(action)) { perform(action) }
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(FailureTint.color(facts.outcome).opacity(0.10))
        .accessibilityElement(children: .contain)
        .alert(
            FailureRowCopy.excludeConfirmationTitle(confirmingHost ?? host),
            isPresented: Binding(get: { confirmingHost != nil }, set: { if !$0 { confirmingHost = nil } }),
            presenting: confirmingHost
        ) { host in
            Button(FailureRowCopy.excludeConfirmButton(host)) {
                ExcludedHostsSettings.shared.exclude(host)
                confirmingHost = nil
            }
            Button("Cancel", role: .cancel) { confirmingHost = nil }
        } message: { host in
            Text(verbatim: FailureRowCopy.excludeConfirmation(host))
        }
        .onAppear {
            if presentConfirmationForProbe { confirmingHost = host }
        }
    }

    private func perform(_ action: FailureRowAction) {
        switch action {
        case .excludeHost(let host):
            confirmingHost = host
        case .exportCertificateAndEnvironment:
            openCaptureSettings?()
        }
    }
}

/// A failure's detail: the banner, then what the row recorded. A row with no
/// request inside it — the app refused ReqRes's certificate before sending
/// one — gets the connection's facts instead of two empty panes.
struct FailureDetailView<Content: View>: View {
    let session: SessionCodable
    let facts: FailureRowFacts
    var openCaptureSettings: (() -> Void)? = nil
    var offersExclusion = true
    @ViewBuilder let exchange: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FailureBanner(session: session, facts: facts, openCaptureSettings: openCaptureSettings, offersExclusion: offersExclusion)
            Divider()
            if facts.phase == .tlsClient {
                FailureConnectionFacts(session: session)
            } else {
                exchange()
            }
        }
    }
}

/// A relay's detail (the connection ReqRes passed through undecrypted). A
/// relay that FAILED — its connect did not go through, or the idle limit
/// closed it (C6.2(b)) — states its cause above the connection's facts, so
/// the default no-CA state shows a DNS typo or a refused connect as one.
/// Access is still decided as a relay's (`FreeTier.detailAccess`): never an
/// inspection, never behind the certificate gate.
struct RelayDetailContent: View {
    let session: SessionCodable
    var openCaptureSettings: (() -> Void)? = nil
    var openCertificateSettings: (() -> Void)? = nil
    var offersExclusion = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let facts = session.failureFacts {
                FailureBanner(session: session, facts: facts, openCaptureSettings: openCaptureSettings, offersExclusion: offersExclusion)
                Divider()
            }
            RelayConnectionDetailView(session: session, openCertificateSettings: openCertificateSettings)
        }
    }
}

/// The facts of a connection that never carried a request.
struct FailureConnectionFacts: View {
    let session: SessionCodable

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    fact("Host", session.host.isEmpty ? "—" : session.host, monospaced: true)
                    fact("App", session.processIdentity.displayName ?? ProcessIdentity.unknownLabel)
                    fact("When", Self.time(session.startTime.doubleValue))
                }
                Text("The app refused or dropped ReqRes's TLS connection before sending any request, so there is no request or response to show — and nothing reached the server.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Opening a row like this never uses one of the free version's HTTPS inspections.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(verbatim: value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        return Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .standard)
    }
}
