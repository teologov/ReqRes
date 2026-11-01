//
//  RecordedExchangeViews.swift
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
//  The views for what the 1.1.0 core records beyond a request and a response:
//
//    - `RelayConnectionDetailView` — a connection relayed without decrypting
//      it (no ReqRes CA installed and trusted when it opened). It is a CONNECTION,
//      so it gets no Request/Response tabs: there is nothing inside it to put
//      in them. Used by the live detail pane and the saved-sessions browser.
//    - `BodyRetentionNotice` — the strip above a body the extension kept only
//      in part (16 MB per exchange). A prefix shown with no notice reads as
//      the whole body, which is the one thing this must never do.
//
//  All words come from `RecordedExchangeCopy` (MCPKit); nothing here phrases
//  a fact of its own.
//

import MCPKit
import SwiftUI
import XReqResCore

/// A relayed connection's detail.
struct RelayConnectionDetailView: View {
    let session: SessionCodable
    /// Opens Settings ▸ Certificate; nil where the pane has no way to (a
    /// probe), and the button is then left out rather than drawn dead.
    var openCertificateSettings: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            // No title block: the detail header above already reads
            // "Not decrypted · host:port · ↑ … ↓ …", and the explanation
            // opens with the same words.
            VStack(alignment: .leading, spacing: 14) {
                Text(RecordedExchangeCopy.relayExplanation(scheme: session.scheme, pinnedBy: session.pinnedBy, appName: session.processIdentity.displayName))
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    fact("Endpoint", session.relayEndpoint, monospaced: true)
                    // The same Protocol row every exchange's Metrics tab has
                    // (doc §S9): "relay/tcp", which `proto:relay` finds.
                    fact("Protocol", session.protocolLabel, monospaced: true)
                    switch PinSource(pinnedBy: session.pinnedBy) {
                    case .macOS(let policy)?:
                        fact("SSL pinned by", "macOS — " + PinnedHostCopy.serviceAndPolicy(policy))
                    case .app(let domain)?:
                        fact("SSL pinned by", "\(session.processIdentity.displayName ?? "the app") — for \(domain)")
                    case nil:
                        EmptyView()
                    }
                    fact("Server", session.remoteAddressText ?? "—", monospaced: true)
                    fact("Sent", RecordedExchangeCopy.binaryBytes(session.requestBytes.int64Value))
                    fact("Received", RecordedExchangeCopy.binaryBytes(session.responseBytes.int64Value))
                    fact("Opened", Self.time(session.startTime.doubleValue))
                    fact("Closed", Self.time(session.rspEndTime.doubleValue))
                    fact("Open for", formatRequestTimes(session).requestDuration)
                }

                Divider()

                Text(RecordedExchangeCopy.relayRemedy(scheme: session.scheme, pinnedBy: session.pinnedBy))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // A `tcp` relay is not about the certificate (doc §S10), and
                // neither is a host macOS pins (live-run F5).
                if let openCertificateSettings, RecordedExchangeCopy.relayIsAboutTheCertificate(scheme: session.scheme, pinnedBy: session.pinnedBy) {
                    Button("Open Certificate Settings…", action: openCertificateSettings)
                }
                Text(RecordedExchangeCopy.relayIsFree)
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

    /// "14:02:31" — the core's timestamps are SECONDS since 1970.
    private static func time(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        return Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .standard)
    }
}

/// The header row of a relay's detail: what it is instead of a status chip, a
/// method and a URL it does not have. A relay that FAILED (its connect did
/// not go through, or ReqRes's idle limit closed it — C6.2(b)) carries the
/// failure's glyph and word first, so the default no-CA state shows a broken
/// connection as broken rather than as an ordinary relay.
struct RelayDetailHeaderRow: View {
    let session: SessionCodable

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let facts = session.failureFacts {
                FailureGlyph(facts: facts)
                Text(verbatim: FailureRowCopy.label(facts.outcome))
                    .fontWeight(.semibold)
                    .foregroundStyle(FailureTint.color(facts.outcome))
            } else {
                RelayGlyph(scheme: session.scheme, pinnedBy: session.pinnedBy, appName: session.processIdentity.displayName)
            }
            Text(RecordedExchangeCopy.relayTitle(scheme: session.scheme, pinnedBy: session.pinnedBy))
                .fontWeight(.medium)
            Divider()
            Text(verbatim: session.relayEndpoint)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: session.relayBytesText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The glyph a relay row carries where an exchange has its status chip: a
/// HOLLOW chip of `Chip`'s exact metrics (12pt, 3/6 padding, 25pt minimum),
/// so a relay row is as tall as its neighbours and reads as "no status"
/// rather than as a status of some colour.
struct RelayGlyph: View {
    /// The row's scheme: a `tcp` relay is explained without the certificate.
    var scheme: String? = nil
    /// Why an SSL-pinned relay is pinned (`PinSource`): the glyph is a pin
    /// instead of the crossed-out lock.
    var pinnedBy: String? = nil
    /// The row's app, which an app's pin names in the tooltip.
    var appName: String? = nil
    var isSelected = false

    var body: some View {
        HStack {
            Image(systemName: pinnedBy == nil ? "lock.slash" : "pin")
                .font(.system(size: 12))
                .frame(minWidth: 25, alignment: .center)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.5), lineWidth: 1)
        )
        .help(RecordedExchangeCopy.relayCellHelp(scheme: scheme, pinnedBy: pinnedBy, appName: appName))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RecordedExchangeCopy.relayCellHelp(scheme: scheme, pinnedBy: pinnedBy, appName: appName))
    }
}

/// The strip above a body the extension kept only in part.
struct BodyRetentionNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "scissors")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

/// A body tab with its retention notice on top, when there is one.
struct RetainedBodyContainer<Content: View>: View {
    let notice: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if let notice {
                BodyRetentionNotice(text: notice)
                Divider()
            }
            content()
        }
    }
}
