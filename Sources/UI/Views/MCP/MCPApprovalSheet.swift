//
//  MCPApprovalSheet.swift
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
//  The human-in-the-loop prompt: an agent asked the bridge to change
//  something, and the bridge is waiting on this answer. Hosted in its own
//  floating panel (MCPApprovalWindow.swift).
//
//  ONE panel per burst, listing every change. An agent turn is normally several
//  writes — add the host, create the rule, start capture — and a panel each was
//  unusable. Approving is a deliberate click: there is no Return-to-approve,
//  and the buttons arm a moment after the panel appears.
//

import MCPKit
import SwiftUI

struct MCPApprovalSheet: View {
    let group: MCPAgentActivity.PendingApprovalGroup
    @ObservedObject private var activity = MCPAgentActivity.shared

    /// The buttons arm shortly after the panel appears, so a click aimed at
    /// whatever was under it cannot approve a change.
    @State private var armed = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var actions: [MCPAgentAction] { group.actions }

    private var secondsLeft: Int {
        max(0, Int(group.expiresAt.timeIntervalSince(now).rounded()))
    }

    /// One panel answers for the whole burst, so every decision below — the
    /// title, the consequence line, each row's icon and its VoiceOver label —
    /// is computed once, in MCPKit, from the actions themselves. See
    /// `MCPAgentActionPresentation` for why that logic isn't here anymore.
    private var presentation: MCPAgentActionPresentation { MCPAgentActionPresentation(actions: actions) }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(presentation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sent through the MCP bridge. Nothing happens until you answer.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            consequence

            changeList

            HStack(spacing: 6) {
                Text("Every agent action is listed in Settings → MCP, where you can also stop being asked.")
                Spacer(minLength: 0)
                // Silence is not consent, but it is also not indefinite: say so.
                Text("Expires in \(secondsLeft)s")
                    .monospacedDigit()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                // No `.cancelAction`: this panel can never become key
                // (MCPApprovalWindow.swift), so no key reaches it. An Escape
                // shortcut here would never fire — the one declared here
                // until F14 never did.
                Button(actions.count == 1 ? "Deny" : "Deny All") { activity.resolve(.deny) }
                Spacer()
                Button("Allow for This Session") { activity.resolve(.allowForSession) }
                    .help("Allow every agent change until ReqRes quits")
                    .disabled(!armed)
                // Deliberately NOT `.defaultAction`: this panel can appear
                // while the human is typing in the agent's chat window, and
                // Return is the key they are about to press. Every answer is
                // a click, Deny included.
                Button(actions.count == 1 ? "Allow" : "Allow All") { activity.resolve(.allow) }
                    .disabled(!armed)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 460)
        .onReceive(tick) { now = $0 }
        .onAppear {
            armed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { armed = true }
        }
    }

    /// What happens if this is approved, in one line, stated once. Repeating a
    /// warning per row teaches people to skip it; stating the consequence once,
    /// in the burst's own terms, is what someone deciding quickly can act on.
    private var consequence: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.consequenceSymbolName)
                .foregroundStyle(Self.color(for: presentation.tint))
            Text(presentation.consequence)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The changes themselves. A long burst scrolls rather than growing the
    /// panel past the screen.
    @ViewBuilder
    private var changeList: some View {
        let rowViews = VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(presentation.rows.enumerated()), id: \.offset) { _, row in
                self.row(for: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)

        if actions.count > 3 {
            ScrollView { rowViews }
                .frame(maxHeight: 280)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        } else {
            rowViews.background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(for row: MCPAgentActionPresentation.Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.symbolName)
                .foregroundStyle(Self.color(for: row.tint))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.summary)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ForEach(row.details, id: \.self) { detail in
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        // The glyph is decorative; VoiceOver should read the change as one
        // item, with its weight named rather than implied by colour.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }

    /// The only place MCPKit's semantic tint becomes an actual SwiftUI
    /// `Color` — three tints rather than two, because "rewrites your traffic"
    /// is neither routine nor a deletion, and it is the class people most
    /// need to notice. Colour is never the only signal: the title, the
    /// consequence line and the symbol all carry the same distinction.
    static func color(for tint: MCPAgentActionTint) -> Color {
        switch tint {
        case .neutral: return .secondary
        case .caution: return .orange
        case .destructive: return .red
        }
    }
}
