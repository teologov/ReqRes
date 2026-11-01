//
//  BreakpointRequestEditors.swift
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
//  The three things the middle of the breakpoint panel can show: the header
//  editor, the body (the original, read-only, or a replacement being
//  written), and the empty state.
//
//  The header editor is NOT `HeaderListView` from EditableTable.swift, which
//  is what the override form uses, and the reason is worth writing down.
//  That one is a `Table` pinned to a hardcoded 220pt, which cannot take the
//  slack when this panel is resized, and it has no way to show that a row has
//  been CHANGED. Under a 60-second clock, "which of these twelve headers am I
//  about to send differently?" is the question the editor exists to answer, so
//  it is answered here with a mark on the row. The data type is still
//  `HeaderEntry`, so nothing about the model diverges.
//
//  Content-Length and Transfer-Encoding rows are shown but locked: the core
//  sends the app's own with the app's own body and frames a replacement body
//  itself (core 5efe7aa), so an edit there would never reach the server. The
//  line under the list says what goes up in their place (`HeldRequestFraming`).
//

import AppKit
import MCPKit
import SwiftUI
import XReqResCore

// MARK: - Headers

struct BreakpointHeaderEditor: View {
    @Binding var headers: [HeaderEntry]
    /// The headers as they arrived. Rows share their `id` with these (both
    /// come out of one decode), so a row can be compared to its own original
    /// rather than guessed at by name.
    let original: [HeaderEntry]
    /// What goes up for Content-Length and Transfer-Encoding — the draft's
    /// `framingNote` — or nil when there is nothing to say.
    var framingNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach($headers) { $entry in
                        row($entry)
                    }
                    if headers.isEmpty {
                        Text("This request carries no headers.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
                .padding(7)
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

            HStack(spacing: 8) {
                Button {
                    headers.append(HeaderEntry(key: "", value: "", isEnabled: true))
                } label: {
                    Label("Add Header", systemImage: "plus")
                }
                .controlSize(.small)

                Text("Changed rows are marked. Removing a row removes the header.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let framingNote {
                Label(framingNote, systemImage: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ entry: Binding<HeaderEntry>) -> some View {
        // A framing header the request arrived with: shown, never edited or
        // removed (see the file header).
        let locked = BreakpointRequestDraft.isLocked(entry.wrappedValue, among: original)
        let changed = !locked && isChanged(entry.wrappedValue)
        return HStack(spacing: 6) {
            // A dot, not a colour on the text: the mark has to survive both
            // appearances and a colour-blind reader, and the tooltip says it
            // in words.
            Circle()
                .fill(changed ? Color.accentColor : Color.clear)
                .frame(width: 5, height: 5)
                .help(changed ? Self.changedTooltip : "")
                .accessibilityHidden(!changed)
                .accessibilityLabel("Changed")

            TextField("", text: entry.key, prompt: Text("Name"))
                .frame(width: 150)
                .multilineTextAlignment(.leading)
                .disabled(locked)

            TextField("", text: entry.value, prompt: Text("Value"))
                .multilineTextAlignment(.leading)
                .disabled(locked)

            if locked {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .help(HeldRequestFraming.lockedRowHelp)
                    .accessibilityLabel("\(entry.wrappedValue.key) is set by ReqRes")
            } else {
                Button {
                    headers.removeAll { $0.id == entry.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove this header from the request")
                .accessibilityLabel("Remove \(entry.wrappedValue.key)")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
    }

    /// A `String`, so the ternary at the call site cannot land on
    /// `LocalizedStringKey` and send an empty tooltip through localization.
    private static let changedTooltip = "Changed from what the request arrived with"

    private func isChanged(_ entry: HeaderEntry) -> Bool {
        guard let match = original.first(where: { $0.id == entry.id }) else {
            // No original with this id: the row was added here.
            return !entry.key.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return match.key != entry.key || match.value != entry.value
    }
}

/// The headers arrived in something that is not JSON. They are shown verbatim
/// and cannot be edited — re-encoding a blob we could not read would hand the
/// core a header block the server may reject, on a live request.
struct BreakpointUnreadableHeaders: View {
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(raw.isEmpty ? "(none)" : raw)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

            Label("ReqRes could not read these headers as JSON, so they cannot be edited here. Resuming sends them exactly as they arrived.",
                  systemImage: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Body

/// The held request's body: read-only, whatever the core sent (F19), with a
/// replacement the user has to ask for.
///
/// The core holds a request at its head and reports no body, so for nearly
/// every request there is nothing to show — and the old view, taking that for
/// an empty body, showed an empty EDITOR under "This request arrived with no
/// body", where typing replaced a body nobody had seen. The words here come
/// from `HeldRequestBody` / `HeldBodyEdit` (MCPKit, tested); this view only
/// lays them out.
struct BreakpointBodyView: View {
    @Binding var draft: BreakpointRequestDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.bodyEdit.isReplacing {
                replacementEditor
            } else {
                original
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: The original

    @ViewBuilder
    private var original: some View {
        switch draft.bodyEdit.held.shown {
        case .whole(let text):
            bodyText(text)
            Text(draft.bodyEdit.note)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .prefix(let text):
            bodyText(text)
            // Sending a prefix back as the body would cut the rest of the
            // upload off, which is why a replacement never starts from it.
            Label(draft.bodyEdit.note, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .nothing:
            // No box of blank lines: an empty box is exactly what read as
            // "this request has no body". The symbol is the helper's: an
            // eye struck through for a body not shown, an empty frame for
            // "Empty body" (`HeldRequestBody.headlineSymbol`).
            VStack(alignment: .leading, spacing: 6) {
                Label(draft.bodyEdit.held.headline, systemImage: draft.bodyEdit.held.headlineSymbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(draft.bodyEdit.note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .accessibilityElement(children: .combine)
        }

        if draft.bodyEdit.canReplace {
            Button("Replace Body…") { draft.startReplacingBody() }
                .controlSize(.small)
                .help("Write a body to send instead of this one. Until you type something, Resume sends the original.")
        } else if let refusal = draft.bodyEdit.replacementRefusal {
            // A TRACE may not carry a body: nothing to replace, and no
            // button that would offer one.
            Label(refusal, systemImage: "nosign")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bodyText(_ text: String) -> some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    // MARK: The replacement

    /// A NEW body — it starts empty unless the core reported the whole
    /// original — and nothing is replaced until something is typed.
    private var replacementEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `rspHeaders` is only read (`SyntaxTextEditor` picks a language
            // from it), so the highlighting follows the Content-Type the user
            // has just edited, not the one the request arrived with.
            SyntaxTextEditor(text: $draft.bodyEdit.text, rspHeaders: $draft.headers)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(draft.bodyEdit.note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Keep Original Body") { draft.keepOriginalBody() }
                    .controlSize(.small)
                    .help("Close the editor and send the body the request arrived with")
            }
        }
    }
}

// MARK: - Empty state

/// The panel opened with nothing held — from a menu, or after the last
/// decision was made somewhere else. A blank box would leave someone
/// wondering whether breakpoints are broken or simply idle, so it says which.
struct BreakpointEmptyState: View {
    /// Why the queue emptied, when it emptied by itself. The timer running out
    /// is the important one: the request the user was reading has already gone
    /// to the server untouched, and nothing else on screen would ever say so.
    var releaseNote: String?
    /// Matched requests let through unasked because the queue was full.
    var autoResumedCount: Int = 0

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: releaseNote == nil ? "pause.circle" : "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(releaseNote == nil ? "Nothing is paused" : "Nothing is held any more")
                .font(.system(size: 15, weight: .semibold))

            if let releaseNote {
                Text(releaseNote)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityAddTraits(.isStaticText)
            }

            if autoResumedCount > 0 {
                Text(autoResumedCount == 1
                     ? "1 other matching request was let through untouched — this panel holds \(BreakpointService.maxPending) at a time."
                     : "\(autoResumedCount) other matching requests were let through untouched — this panel holds \(BreakpointService.maxPending) at a time.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }

            Text("A breakpoint holds a matching request before it reaches the server. While it is held you can read it, change its headers or body and let it through — or answer it here with an error instead, without the server ever seeing it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            // Read from the core rather than typed out, so the number here
            // cannot drift away from the one that actually releases requests.
            Text("A held request waits \(Int(BreakpointRegistry.decisionTimeout))s for an answer and then resumes untouched, so a breakpoint you forget about cannot leave an app wedged.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            VStack(spacing: 4) {
                Button("Open Breakpoint Settings") { openSettings() }
                Text("Settings → Breakpoints")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The AppKit route, not `@Environment(\.openSettings)`: this view is
    /// hosted in a panel the app builds itself, outside the SwiftUI scene tree
    /// that provides that action. `ReqResToolbarSlots` opens Settings the same
    /// way, for the same reason.
    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
