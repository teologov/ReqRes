//
//  SavedSessionDetailView.swift
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
//  The right-hand pane: a saved session rendered by the SAME viewers the
//  traffic table uses. `SessionRequestTabView` and `SessionResponseTabView`
//  take a plain `SessionCodable`, so a row read back out of the database
//  renders with no special case — and, more importantly, cannot drift away
//  from the live inspector as that gains abilities. A second viewer written
//  for saved sessions would be a second place for every rendering bug.
//
//  The request|response divider is a plain `HSplitView` rather than the
//  SplitView package's `Split` that `SessionDetailContent` uses: this pane
//  has no collapse affordance and no persisted layout to honour, so the
//  holders that come with `Split` would be state with nothing reading it.
//
//  The header carries the same process pill the live detail header does
//  (UX spec §6), minus its menu: a filter committed from here would act on
//  the live traffic window behind this one, which is not what a click on a
//  SAVED row's app means. Availability is `.unreported` — the attribution
//  was true when the exchange was captured, and the tooltip says so.
//

import MCPKit
import SwiftUI
import XReqResCore

struct SavedSessionDetailView: View {
    let saved: SavedSessionCodable

    // Not the `network-inspector-selected-tab-*` AppStorage keys the main
    // window uses. Reading a saved exchange and reading live traffic are
    // separate tasks, and making one silently retarget the other's tabs is
    // the kind of shared state nobody asks for.
    @State private var selectedTabRequest: NetworkInspectorTabRequest = .summary
    @State private var selectedTabResponse: NetworkInspectorTabResponse = .response

    private var session: SessionCodable { saved.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if session.relayed {
                // A relayed connection has no request or response to split.
                // No Settings button here: this is a record of a past
                // capture, and installing the certificate now changes nothing
                // about it.
                RelayDetailContent(session: session, offersExclusion: false)
            } else if let facts = session.failureFacts, facts.phase == .tlsClient {
                // A saved refusal of ReqRes's certificate: no request inside.
                // No exclusion from here — the row is from another run.
                FailureDetailView(session: session, facts: facts, offersExclusion: false) { EmptyView() }
            } else {
            if let facts = session.failureFacts {
                FailureBanner(session: session, facts: facts, offersExclusion: false)
                Divider()
            }
            HSplitView {
                // Written out rather than funnelled through a helper taking
                // `AnyView`: erasing the type would also erase the
                // `.equatable()` wrapper's effect, which is the whole reason
                // these viewers survive next door in the live table.
                VStack(alignment: .leading, spacing: 0) {
                    RequestToolbar(title: .Request, selection: $selectedTabRequest)
                    Divider()
                    SessionRequestTabView(session: session, selectedTabRequest: $selectedTabRequest)
                        .equatable()
                }
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 0) {
                    ResponseToolbar(title: .Response, selection: $selectedTabResponse,
                                    items: NetworkInspectorTabResponse.tabs(for: session, messages: false))
                    Divider()
                    SessionResponseTabView(session: session, selectedTabResponse: $selectedTabResponse)
                        .equatable()
                }
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            }
        }
        // Rebuild the tab state when a different saved session is selected,
        // so a Metrics tab left open on one row does not decide what the
        // next row opens on.
        .id(saved.id)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                if session.relayed {
                    RelayDetailHeaderRow(session: session)
                } else if let facts = session.failureFacts {
                    FailureDetailHeaderRow(session: session, facts: facts)
                } else {
                    Chip(status: session.rspStatus)
                    Text(session.method)
                        .fontWeight(.medium)
                    Divider()
                    Text(verbatim: session.fullUrl)
                        .help(session.fullUrl)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                processPill
            }
            .frame(minHeight: 20)

            HStack(spacing: 4) {
                Text("Captured")
                Text(SavedSessionRow.captured(session), format: .dateTime.day().month().year().hour().minute().second())
                Text("· Saved")
                Text(saved.savedAt, format: .dateTime.day().month().year().hour().minute())
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if let note = saved.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panelBodyBackground)
    }

    /// One tooltip, via `ProcessLabel`'s override: an attributed row reads
    /// "…, when this was captured"; an unknown one keeps
    /// `ProcessIdentity.unknownTooltip`, the one explanation of what Unknown
    /// means, rather than having it covered by a dated name.
    private var processPill: some View {
        let identity = session.processIdentity
        return ProcessLabel(identity: identity, availability: .unreported, style: .pill(actions: .none),
                            tooltipOverride: identity.savedPillTooltip)
    }
}
