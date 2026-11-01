//
//  HelpWindow.swift
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
//  The window's own layout: a jump-to sidebar beside one continuous scroll,
//  not six separate panes. A reference document is read by scanning past
//  what you already know, and a single scroll lets that happen — a sidebar
//  that swapped panes would force a click for every section, and would lose
//  your place in whichever one you were just reading.
//
//  The sidebar is a plain VStack of Buttons rather than `List(selection:)` —
//  every row is then an ordinary, independently focusable control (Tab
//  cycles through them, Space/Return activates one), with no dependency on
//  a List selection binding's exact overload resolving the way intended.
//

import SwiftUI

struct HelpWindow: View {
    @State private var highlighted: HelpTopic = .capture

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        Divider()
                        ForEach(HelpTopic.allCases) { topic in
                            helpContent(for: topic)
                            if topic != HelpTopic.allCases.last {
                                Divider()
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: HelpStyle.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: highlighted) { _, newTopic in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newTopic.id, anchor: .top)
                    }
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 780, minHeight: 420, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("ReqRes Help")
                    .font(.system(size: 20, weight: .bold))
                    .textSelection(.enabled)
                Text("A quick reference for what people actually get stuck on — not a manual.")
                    .font(HelpStyle.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(HelpTopic.allCases) { topic in
                    sidebarRow(topic)
                }
            }
            .padding(10)
        }
        .frame(width: 200)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func sidebarRow(_ topic: HelpTopic) -> some View {
        let isHighlighted = topic == highlighted
        return Button {
            highlighted = topic
        } label: {
            HStack(spacing: 8) {
                Image(systemName: topic.systemImage)
                    .frame(width: 16)
                Text(topic.shortTitle)
                    .font(HelpStyle.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHighlighted ? Color.accentColor : Color.primary)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }
}

#Preview {
    HelpWindow()
}
