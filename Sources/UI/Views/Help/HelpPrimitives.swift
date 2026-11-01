//
//  HelpPrimitives.swift
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
//  The building blocks every Help topic is written with (topic/subsection/
//  paragraph/bullet/numbered-list/tip), sized to the type scale ReqRes already
//  uses in its own Settings window (MCPSettingsView.swift: 13pt semibold
//  sub-headings, 11pt body/secondary text, 10pt captions) — this window sits
//  next to Settings, not on its own, and should look like the same app.
//  `topicTitle` is the one size above that scale: six long sections need a
//  stronger anchor than a 13pt label to stay scannable.
//

import SwiftUI

enum HelpStyle {
    static let topicTitle: Font = .system(size: 16, weight: .bold)
    static let heading: Font = .system(size: 13, weight: .semibold)
    static let body: Font = .system(size: 11)
    static let caption: Font = .system(size: 10)

    /// Content stops widening past this. At the default 820pt window the
    /// unbounded text ran ~95 characters a line, which is past where the eye
    /// reliably finds the start of the next one; the window can still be
    /// dragged wider for the code examples without the prose following it.
    static let readingWidth: CGFloat = 720
}

/// A whole topic (what the sidebar links to): an icon + title, then its
/// content. `id` is what `ScrollViewReader.scrollTo` targets, kept separate
/// from the visible title so retitling a topic later can't silently break
/// the sidebar's jump-to behaviour.
@ViewBuilder
func helpTopic(_ title: String, systemImage: String, id: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
            Text(title)
                .font(HelpStyle.topicTitle)
                .textSelection(.enabled)
        }
        content()
    }
    .id(id)
    .accessibilityElement(children: .contain)
}

/// A labelled group inside a topic — "Trusting the certificate" might have
/// one of these per step, "Rules" one per mode.
@ViewBuilder
func helpHeading(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(HelpStyle.heading)
            .textSelection(.enabled)
        content()
    }
    .padding(.leading, 2)
}

/// Selectable so a step, a header name or a path pattern can be copied
/// straight into the form it describes — the whole point of a REFERENCE
/// rather than a one-time tutorial.
func helpParagraph(_ text: String) -> some View {
    Text(text)
        .font(HelpStyle.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
}

func helpBullet(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
        Text("•")
            .font(HelpStyle.body)
            .foregroundStyle(.secondary)
        Text(text)
            .font(HelpStyle.body)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

func helpNumberedList(_ items: [String]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1).")
                    .font(HelpStyle.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)
                Text(item)
                    .font(HelpStyle.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// A hint that isn't essential to follow the section but saves a support
/// message if it's read, in the familiar yellow-light association.
func helpTip(_ text: String) -> some View {
    calloutRow(text, systemImage: "lightbulb.fill", tint: .yellow)
}

/// A warning about a MISTAKE, not a hint — a rule that will silently never
/// fire, or an interaction (capture vs. codesign) that looks like a bug but
/// is the product working as designed. Visually distinct from `helpTip` so
/// the two are never confused while scanning.
func helpWarning(_ text: String) -> some View {
    calloutRow(text, systemImage: "exclamationmark.triangle.fill", tint: .orange)
}

private func calloutRow(_ text: String, systemImage: String, tint: Color) -> some View {
    HStack(alignment: .top, spacing: 8) {
        Image(systemName: systemImage)
            .font(HelpStyle.body)
            .foregroundStyle(tint)
        Text(text)
            .font(HelpStyle.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
}

/// A worked example: what to type, and what it does — the concrete case
/// every section above asks for ("one worked example each").
func helpExample(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 10, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
}

/// Deep-links out to the full website docs — a single top banner rather than
/// one per section: ReqRes's in-app Help is a short quick reference, not a set
/// of standalone chapters each needing its own escape hatch to the fuller docs.
func helpWebDocsBanner(_ text: String, url: String) -> some View {
    Group {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 13))
                    Text(text)
                        .font(HelpStyle.body)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
