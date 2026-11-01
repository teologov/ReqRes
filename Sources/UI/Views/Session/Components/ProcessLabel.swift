//
//  ProcessLabel.swift
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
//  The one view that names a process (process-attribution UX spec §1.4): the
//  App column's cell, the detail header's pill, the saved row's bare icon.
//
//  It is also the ONLY view that renders the word "Unknown". Every other
//  surface passes a `ProcessIdentity` whose `displayName` may be nil and lets
//  this turn the nil into the word — so the table, the pill and the saved
//  browser can never disagree about what an unattributed request is called,
//  and `app:unknown` (the search token's spelling of the same word, pinned
//  equal by `ProcessIdentityLabelTests`) always selects what the column shows.
//

import AppKit
import MCPKit
import SwiftUI
import Utils

/// `@MainActor` because the helpers below ask `ProcessIconCache` (main-actor
/// isolated) for an icon; a View's `body` already is.
@MainActor
struct ProcessLabel: View {
    enum Style {
        /// 13pt like Method and URL, a 16pt icon, the agent badge when asked.
        case tableCell(isSelected: Bool, isAgent: Bool)
        /// The breakpoint queue's pill: `name · pid N ⌄`, ≤ 220pt.
        case pill(actions: PillActions)
        /// The icon alone, for a row whose text has no room for a name.
        case icon(size: CGFloat)
    }

    enum PillActions {
        /// A menu that filters the live traffic list and reaches the executable.
        case traffic
        /// No menu — the saved-sessions browser, where a filter would act on the
        /// live window behind it.
        case none
    }

    let identity: ProcessIdentity
    /// Passed down as a value, never observed here: a row that observed
    /// `AppState` re-rendered on every publish (the 40s hang of 2026-09-06).
    let availability: ProcessAttributionAvailability
    let style: Style
    /// Replaces the pill's own tooltip when a caller knows better — the saved
    /// browser's "…, when this was captured". Two `.help`s on one view let
    /// AppKit pick, and it picks the inner one.
    var tooltipOverride: String? = nil
    /// The connected agent this process belongs to, when `isAgent` — it names
    /// the badge in the tooltip and the accessibility value, since the badge
    /// itself is never the only signal.
    var agentName: String? = nil

    var body: some View {
        switch style {
        case .tableCell(let isSelected, let isAgent):
            tableCell(isSelected: isSelected, isAgent: isAgent)
        case .pill(let actions):
            pill(actions: actions)
        case .icon(let size):
            // No text beside it, so the glyph itself is the element.
            iconGlyph(size: size, isSelected: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("App")
                .accessibilityValue(identity.accessibilityValue())
        }
    }

    // MARK: - Words

    private var name: String { identity.displayName ?? ProcessIdentity.unknownLabel }

    /// What a hovering pointer reads. Unavailable attribution is a fact about
    /// this Mac now and outranks the per-row explanation.
    private var unknownTooltip: String {
        availability == .unavailable ? ProcessIdentity.unavailableTooltip : ProcessIdentity.unknownTooltip
    }

    // MARK: - Icon

    /// The process's icon from the cache, a system service's symbol, or the
    /// dashed placeholder for Unknown — hidden from accessibility because the
    /// text beside it carries the value.
    private func icon(size: CGFloat, isSelected: Bool) -> some View {
        iconGlyph(size: size, isSelected: isSelected)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func iconGlyph(size: CGFloat, isSelected: Bool) -> some View {
        Group {
            if let symbol = identity.systemServiceSymbol {
                // Errata 1: WebKit Networking is not Safari. A known system
                // service draws its symbol, never an app's icon.
                Image(systemName: symbol)
                    .font(.system(size: size - 2))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            } else if let image = ProcessIconCache.shared.icon(for: identity) {
                // Not tinted on selection: Finder and Mail leave icons alone.
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .font(.system(size: size - 2))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    /// Spec §2.2: `sparkles` at 8pt, accent (white when selected), on the icon's
    /// bottom-trailing corner, on a 1pt window-background ring so it reads
    /// against any icon.
    private func agentBadge(isSelected: Bool) -> some View {
        Image(systemName: "sparkles")
            .font(.system(size: 8))
            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            .padding(1)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
            .offset(x: 2, y: 2)
    }

    // MARK: - Table cell (spec §2.2–2.4)

    private func tableCell(isSelected: Bool, isAgent: Bool) -> some View {
        let agent = isAgent ? agentName : nil
        let textColor: Color = identity.isKnown
            ? (isSelected ? .white : .primary)
            : (isSelected ? .white.opacity(0.75) : .secondary)
        return HStack(spacing: 6) {
            icon(size: 16, isSelected: isSelected)
                .overlay(alignment: .bottomTrailing) {
                    if isAgent {
                        agentBadge(isSelected: isSelected)
                    }
                }
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(textColor)
        }
        .help(identity.isKnown ? identity.tooltip(agentName: agent) : unknownTooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("App")
        .accessibilityValue(identity.accessibilityValue(agentName: agent))
    }

    // MARK: - Pill (spec §5.1)

    @ViewBuilder
    private func pill(actions: PillActions) -> some View {
        let hasMenu = actions == .traffic && identity.isKnown
        if hasMenu {
            Menu {
                pillMenuItems
            } label: {
                pillContent(hasMenu: true)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help(identity.tooltip + "\nClick for filters.")
            .accessibilityLabel("App")
            .accessibilityValue(identity.accessibilityValue())
            .accessibilityHint("Filter or copy the process path")
        } else {
            pillContent(hasMenu: false)
                .help(tooltipOverride ?? (identity.isKnown ? identity.tooltip : unknownTooltip))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("App")
                .accessibilityValue(identity.accessibilityValue())
        }
    }

    /// The breakpoint queue pill's exact treatment (`BreakpointPanel.queuePill`):
    /// 10pt, 8/4 padding, `Color.secondary.opacity(0.12)` capsule. The name
    /// is the one child that truncates; the pid and the chevron are fixed so
    /// "pid 9437" is never what gives way.
    private func pillContent(hasMenu: Bool) -> some View {
        HStack(spacing: 5) {
            icon(size: 12, isSelected: false)
            Text(verbatim: name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(identity.isKnown ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if identity.isKnown, let pid = identity.pid {
                Text(verbatim: "·")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(verbatim: "pid \(pid)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if hasMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .frame(maxWidth: 220)
        .contentShape(Capsule())
    }

    /// Filters first, then the executable — "Show in Finder" and "Copy path"
    /// only when there is a path to act on. Spec §5.1; §11 keeps the path on
    /// screen only, which these two are.
    @ViewBuilder
    private var pillMenuItems: some View {
        Button("Show only requests from \(name)") {
            TrafficSearchState.shared.addToken(.app(name))
        }
        if let pid = identity.pid {
            Button("Show only this process (pid \(pid))") {
                TrafficSearchState.shared.addToken(.pid(pid))
            }
        }
        if let executablePath = identity.executablePath {
            Divider()
            Button("Show in Finder") {
                let path = identity.bundlePath ?? executablePath
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(executablePath, forType: .string)
            }
        }
    }
}
