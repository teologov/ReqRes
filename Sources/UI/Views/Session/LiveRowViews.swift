//
//  LiveRowViews.swift
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
//  How an in-flight row looks (protocol-engine doc §S6): the table's phase —
//  a symbol AND a word, never colour alone — its elapsed time or bytes, and
//  the detail pane's growing response text. Each view observes ONE row's
//  `LiveRowModel`, so a progress message re-renders one cell and appends to
//  one text view; the table itself is never rebuilt for it. Every word is
//  `LiveRowCopy`'s (MCPKit), the same the agent reads.
//

import AppKit
import Combine
import MCPKit
import SwiftUI
import XReqResCore

// MARK: - Table

/// The Code column of an in-flight row: while waiting there is no status to
/// show, so the phase's symbol takes its place (grey, like a pending chip);
/// once streaming the real status is known and shows as usual. VoiceOver
/// reads the phase here, and its value changes only when the phase does.
struct LiveCodeCell: View {
    @ObservedObject var model: LiveRowModel
    let status: String?
    var isSelected = false

    var body: some View {
        Group {
            if model.phase == .streaming, status != nil {
                Chip(status: status)
            } else {
                Image(systemName: LiveRowCopy.symbol(model.phase))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 25, alignment: .center)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6).foregroundColor(Color.gray.opacity(0.75)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isSelected ? Color.white.opacity(0.8) : Color.clear, lineWidth: 1)
                    )
            }
        }
        .help(LiveRowCopy.accessibilityValue(phase: model.phase))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveRowCopy.word(model.phase))
        .accessibilityValue(LiveRowCopy.accessibilityValue(phase: model.phase))
    }
}

/// The URL cell of an in-flight row: `⏳ Waiting  https://…` or
/// `↓ Streaming 34.1 KB  https://…`. The lead comes first so a long URL
/// truncates before it does. The byte count changes with each flush and is
/// kept out of VoiceOver (the Code cell carries the phase).
struct LiveURLCell: View {
    @ObservedObject var model: LiveRowModel
    let url: String
    var isSelected = false

    var body: some View {
        let phase = model.phase
        (Text(Image(systemName: LiveRowCopy.symbol(phase)))
            .foregroundColor(isSelected ? .white : .secondary)
         + Text(verbatim: " " + LiveRowCopy.tableLead(phase: phase, responseBytes: model.state.responseBytes) + "  ")
            .fontWeight(.semibold)
            .foregroundColor(isSelected ? .white : .secondary)
         + Text(verbatim: url))
            .help(LiveRowCopy.accessibilityValue(phase: phase) + "\n" + url)
            .accessibilityLabel(url)
    }
}

/// The Duration cell of an in-flight row: time since the request started,
/// ticking at most once a second — and only while the row is on screen.
struct LiveElapsedCell: View {
    /// Extension wall clock, seconds since 1970.
    let startTime: TimeInterval
    var isSelected = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(verbatim: startTime > 0 ? LiveRowCopy.elapsed(context.date.timeIntervalSince1970 - startTime) : "—")
                .monospacedDigit()
                .foregroundColor(isSelected ? .white : .secondary)
        }
        .accessibilityHidden(true)
    }
}

/// A row that stopped being live without its final row: a question mark
/// where the status would be, "Ended" before the URL, and why in the tooltip.
struct EndedRowGlyph: View {
    let ended: LiveEndedRow
    var isSelected = false

    var body: some View {
        Image(systemName: LiveRowCopy.symbol(.ended))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 25, alignment: .center)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).foregroundColor(Color.gray.opacity(0.55)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.white.opacity(0.8) : Color.clear, lineWidth: 1)
            )
            .help(LiveRowCopy.endedExplanation(ended.reason))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LiveRowCopy.word(.ended))
            .accessibilityValue(LiveRowCopy.accessibilityValue(phase: .ended, endReason: ended.reason))
    }
}

enum EndedWord {
    static func text(isSelected: Bool) -> Text {
        Text(verbatim: LiveRowCopy.word(.ended))
            .fontWeight(.semibold)
            .foregroundColor(isSelected ? .white : .secondary)
            + Text(verbatim: "  ")
    }
}

// MARK: - Detail

/// The line above an in-flight response: the phase (symbol + words) and what
/// the live text is. Its accessibility value is the phase sentence, so it is
/// re-announced when the phase changes, not with every byte.
struct LiveDetailBanner: View {
    @ObservedObject var model: LiveRowModel

    var body: some View {
        let phase = model.phase
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: LiveRowCopy.symbol(phase))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: LiveRowCopy.detailLine(state: model.state, textHeld: model.textByteCount > 0))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveRowCopy.word(phase))
        .accessibilityValue(LiveRowCopy.accessibilityValue(phase: phase))
    }
}

/// The Body tab of an in-flight response: the text as it arrives, appended to
/// one NSTextView (never re-laid-out from the top), following the end while
/// the reader is at the end.
struct LiveResponseBodyView: View {
    let model: LiveRowModel

    var body: some View {
        VStack(spacing: 0) {
            LiveDetailBanner(model: model)
            Divider()
            LiveTextView(model: model)
        }
    }
}

private struct LiveTextView: NSViewRepresentable {
    let model: LiveRowModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.textColor = .labelColor
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.setAccessibilityLabel("Response text so far")
        }
        context.coordinator.attach(scroll, to: model)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.attach(nsView, to: model)
    }

    final class Coordinator {
        private weak var scroll: NSScrollView?
        private var attachedID: UUID?
        private var subscription: AnyCancellable?

        func attach(_ scroll: NSScrollView, to model: LiveRowModel) {
            self.scroll = scroll
            guard attachedID != model.rowID else { return }
            attachedID = model.rowID
            let text = scroll.documentView as? NSTextView
            text?.string = ""
            append(model.text)
            subscription = model.textAppended
                .receive(on: DispatchQueue.main)
                .sink { [weak self] pieces in self?.append(pieces.map(\.text).joined()) }
        }

        private func append(_ piece: String) {
            guard !piece.isEmpty, let scroll, let text = scroll.documentView as? NSTextView,
                  let storage = text.textStorage else { return }
            // Follow the end only when the reader is already there.
            let clip = scroll.contentView
            let atEnd = clip.bounds.maxY >= text.frame.maxY - 24
            storage.append(NSAttributedString(string: piece, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]))
            if atEnd { text.scrollToEndOfDocument(nil) }
        }
    }
}

/// Above the detail of a row that ended without its final row: what that
/// means and why the response is missing.
struct EndedRowBanner: View {
    let ended: LiveEndedRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: LiveRowCopy.symbol(.ended))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Ended without its final row")
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: LiveRowCopy.endedExplanation(ended.reason))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
