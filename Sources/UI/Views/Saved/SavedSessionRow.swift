//
//  SavedSessionRow.swift
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
//  One row of the saved list.
//
//  Kept deliberately cheap: no GeometryReader, no per-row formatter objects,
//  no observation of any store. The list can hold `SavedSessionsStore.pageSize`
//  (500) rows and the live traffic table next door is the reason this app has
//  a 150ms batching layer at all — a row that re-measures itself is the shape
//  of that bug.
//
//  Both timestamps are shown because they answer different questions. "When
//  was it captured" is what the exchange means; "when did I save it" is how
//  you find it again ("the one from this morning"). A saved list that shows
//  only one of them makes the other unrecoverable.
//
//  The app that made the request is a 14pt icon at the trailing edge and
//  nothing more (UX spec §6): the 10pt metadata line already truncates at
//  the list's 280pt minimum, so the name lives in the tooltip, the search
//  and the detail pill instead. Its availability is always `.unreported` —
//  a saved Unknown is a fact about the capture it came from, never a claim
//  about this Mac now.
//

import MCPKit
import SwiftUI
import Utils
import XReqResCore

struct SavedSessionRow: View {
    let saved: SavedSessionCodable

    private var session: SessionCodable { saved.session }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let facts = session.failureFacts {
                    // A failed relay included: a broken connection reads as
                    // broken, not as an ordinary "not decrypted" relay.
                    FailureGlyph(facts: facts)
                } else if session.relayed {
                    RelayGlyph(scheme: session.scheme, pinnedBy: session.pinnedBy, appName: session.processIdentity.displayName)
                } else {
                    Chip(status: session.rspStatus)
                }
            }
            .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if !session.relayed {
                        Text(session.method)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    Text(session.relayed ? session.relayEndpoint : session.host)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // Truncated in the MIDDLE: the discriminating part of an API
                // path is usually its tail (/v1/users/42), which tail
                // truncation is exactly what hides. A relay has no path; its
                // second line is what it does have.
                Text(session.relayed ? "\(RecordedExchangeCopy.relayTitle(scheme: session.scheme, pinnedBy: session.pinnedBy)) · \(session.relayBytesText)" : Self.path(of: session))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Text("Captured")
                    Text(Self.captured(session), format: .dateTime.day().month().hour().minute())
                    Text("· Saved")
                    Text(saved.savedAt, format: .relative(presentation: .named))
                    // Per-row size, because the total in Settings ("using
                    // 36.9 MB") cannot say WHICH one is large — and one saved
                    // response can be almost all of it: an image or a download
                    // is stored whole, on purpose.
                    Text("· \(SavedSessionSummary.byteSizeText(Self.byteSize(of: session)))")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let note = saved.note, !note.isEmpty {
                    // The note is why this row is here at all, so it gets the
                    // accent and is never dropped to the secondary greys the
                    // metadata lines use.
                    HStack(spacing: 4) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 9))
                        Text(note)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                }
            }

            Spacer(minLength: 6)

            // Top-aligned with the method/host line, like the status chip.
            ProcessLabel(identity: session.processIdentity, availability: .unreported, style: .icon(size: 14))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help("\(session.fullUrl)\n\(session.processIdentity.savedRowTooltipLine)")
        .accessibilityElement(children: .combine)
    }

    // MARK: - Field derivation

    /// The path part of the request, whatever shape `uri` arrived in.
    ///
    /// Delegates to `SavedSessionSummary`, which is the shared formatter the
    /// agent's text output uses too. This file had its own copy for a day and
    /// the two already disagreed — on a percent-encoded path, and on a `uri`
    /// with no leading slash. The drift is invisible until someone reads a row
    /// in this window, asks the agent about it, and the two name different
    /// endpoints.
    static func path(of session: SessionCodable) -> String {
        SavedSessionSummary.displayPath(fromURI: session.uri)
    }

    /// What this one costs on disk, counted the same way the core's
    /// `savedSessionByteSize` sums it: the two bodies, the two header blobs
    /// and the raw response data. Computed here rather than asked of the
    /// database, because a per-row query for a list of 500 would be 500
    /// queries to say something each row already knows.
    static func byteSize(of session: SessionCodable) -> Int64 {
        Int64(session.reqBody.utf8.count
            + session.rspBody.utf8.count
            + session.reqHeaders.utf8.count
            + (session.rspHeaders?.utf8.count ?? 0)
            + (session.rspBodyData?.count ?? 0))
    }

    /// When the exchange happened. The core emits its timestamps in SECONDS
    /// since 1970, not milliseconds — reading them as ms put every rendered
    /// date in 1970 once already (RR-MCP-1 review, 2026-08-26).
    static func captured(_ session: SessionCodable) -> Date {
        Date(timeIntervalSince1970: session.startTime.doubleValue)
    }

    /// The row's searchable text. Host, path, method, the app and the note
    /// are what a person remembers about something they kept; the bodies are
    /// not, and scanning them for 500 rows on every keystroke would cost more
    /// than the feature is worth. The app is searched by its DISPLAY name —
    /// the same string the icon's tooltip and the traffic table show — with
    /// "Unknown" standing in for an unattributed row, so typing the word the
    /// browser shows finds the rows it shows it for.
    static func matches(_ saved: SavedSessionCodable, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let fields = [
            saved.session.host,
            path(of: saved.session),
            saved.session.method,
            saved.session.processIdentity.displayName ?? ProcessIdentity.unknownLabel,
            saved.note ?? "",
        ]
        return fields.contains { $0.range(of: needle, options: .caseInsensitive) != nil }
    }
}
