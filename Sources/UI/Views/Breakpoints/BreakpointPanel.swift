//
//  BreakpointPanel.swift
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
//  The panel where a held request is decided.
//
//  A breakpoint stops a real request in flight: somewhere a page is spinning
//  and a person is waiting on this window. Everything here is arranged around
//  how fast a correct decision can be made, in this order:
//
//   1. WHAT and HOW LONG — method, host, path and the countdown, readable at
//      a glance, at the top, before anything that needs reading.
//   2. The material — headers and body, for whoever actually needs them.
//   3. The two ways out — Resume (calm) and Abort (destructive, and it names
//      the status the client will get).
//
//  Three rules are inherited from the MCP approval panel
//  (`MCPApprovalSheet` / `MCPApprovalWindow`), which was designed for the same
//  situation — a window arriving unbidden over whatever the human was doing:
//
//   * Return is NOT bound to the affirmative action. This panel can appear
//     while someone is typing in a browser, and Return is the key they were
//     about to press.
//   * The buttons ARM a moment after the panel appears (and again whenever the
//     panel switches to a different held request), so a click aimed at what
//     used to be under the cursor cannot answer for a live request.
//   * The panel does not take the keyboard on its own. Unlike the approval
//     panel it CAN become key — editing headers means typing — but only when
//     the user clicks into a field (`becomesKeyOnlyIfNeeded`, see
//     BreakpointWindowController).
//
//  The countdown is not decoration. A held request auto-resumes after
//  `BreakpointRegistry.decisionTimeout`, and a panel that quietly stopped
//  mattering would be worse than no panel: when the clock reaches zero the
//  actions go dead rather than firing at an id the core has already released.
//

import AppKit
import SwiftUI
import XReqResCore

struct BreakpointPanel: View {
    @ObservedObject private var service = BreakpointService.shared

    /// The request being decided. A String id rather than an index: the queue
    /// changes underneath this view (things time out, new ones arrive) and an
    /// index would quietly retarget the decision at a different request.
    @State private var selectedID: String?
    /// Edits, kept per request so moving through the queue does not lose them.
    @State private var drafts: [String: BreakpointRequestDraft] = [:]
    @State private var detail: DetailTab = .headers
    @State private var abortStatus = BreakpointService.defaultAbortStatus
    @State private var armed = false
    @State private var armToken = 0

    // The clock, the abort statuses and the header encoding all used to exist
    // twice — once here and once in the service — and all three copies had
    // drifted: this view rounded the countdown a different way, offered 409 but
    // not 504 while the service offered the reverse and defaulted to 500, and
    // built its own header pairs beside a draft encoder nothing called. Each
    // now has one home. The clock is `BreakpointService.now`, which ticks at
    // 2 Hz only while something is actually held — a panel-owned timer would
    // run whenever this view existed and show a number half a second away from
    // the one the expiry logic uses.

    private enum DetailTab: Hashable { case headers, body }

    // MARK: - Body

    var body: some View {
        Group {
            if let request = current {
                content(for: request)
            } else {
                // What emptied the queue matters here: a request released by
                // the timer, a disarm or capture stopping is something that
                // happened TO the user, and the panel is the only place that
                // can say so.
                BreakpointEmptyState(releaseNote: service.lastReleaseNote,
                                     autoResumedCount: service.autoResumedCount)
            }
        }
        .frame(minWidth: 520, minHeight: 430)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { syncQueue() }
        .onChange(of: service.pending.map(\.id)) { _, ids in syncQueue(ids: ids) }
        // Re-arm on every change of subject, not just on appear: answering one
        // request slides the next one under a cursor that is already over the
        // Resume button, and a double click would otherwise answer both.
        // BOTH, and the first one is the one that matters: the window is built
        // lazily when the first request is held, so `current` is already set at
        // first render and `onChange` never fires for it. Without this, the
        // FIRST held request — the common case — showed both buttons disabled
        // forever, leaving the user nothing to do but close the panel or wait
        // out the timer. Caught by rendering the panel with a seeded request.
        .onAppear { arm() }
        .onChange(of: current?.id) { _, _ in
            arm()
            // The failure belonged to the request that was on screen when it
            // happened; carrying it onto the next one accuses the wrong edit.
            resumeError = nil
        }
    }

    private var current: PausedRequestCodable? {
        if let selectedID, let match = service.pending.first(where: { $0.id == selectedID }) { return match }
        return service.pending.first
    }

    // MARK: - One held request

    private func content(for request: PausedRequestCodable) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            summary(for: request)
            if service.autoResumedCount > 0 { overflowNote }
            if service.pending.count > 1 { queueStrip }
            Divider()
            detailSection(for: request)
            Divider()
            actions(for: request)
        }
    }

    // MARK: - 1. What, and how long

    /// The queue has a ceiling, and past it requests are let through without
    /// asking. Saying nothing would make those look like requests no rule ever
    /// matched — the user would conclude their breakpoint is broken, when in
    /// fact it fired and the app chose not to hold them.
    private var overflowNote: some View {
        Label(
            service.autoResumedCount == 1
                ? "1 more matched and was let through untouched — this panel holds \(BreakpointService.maxPending) at a time."
                : "\(service.autoResumedCount) more matched and were let through untouched — this panel holds \(BreakpointService.maxPending) at a time.",
            systemImage: "arrow.turn.down.right"
        )
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func summary(for request: PausedRequestCodable) -> some View {
        let left = secondsLeft(request)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MethodPill(method: request.method)
                Text(request.host)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                countdown(left)
            }

            Text(verbatim: draft(for: request).pathAndQuery)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(draft(for: request).displayURL)
                .frame(maxWidth: .infinity, alignment: .leading)

            timeBar(request, left: left)

            Text("Held before it reaches \(request.host). If the timer runs out it is resumed untouched.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func countdown(_ left: Int) -> some View {
        // Built as plain Strings: a ternary of two string literals is
        // ambiguous between `String` and `LocalizedStringKey` at these call
        // sites, and the seconds should be printed, not number-formatted.
        let label = left <= 0 ? "Resuming…" : "\(left)s"
        let spoken = left <= 0 ? "This request is resuming on its own"
                               : "Resumes on its own in \(left) seconds"
        return HStack(spacing: 5) {
            Image(systemName: "clock")
            Text(verbatim: label)
                .monospacedDigit()
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(urgency(left))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
        .help("A held request cannot wait forever — after \(Int(BreakpointRegistry.decisionTimeout))s the core resumes it untouched so nothing stays wedged.")
    }

    /// Drains rather than fills: the bar IS the time left, so it should shrink
    /// as the time does.
    private func timeBar(_ request: PausedRequestCodable, left: Int) -> some View {
        ProgressView(value: service.fractionRemaining(for: request))
            .progressViewStyle(.linear)
            .tint(urgency(left))
            // The countdown beside it already says this out loud; a second
            // reading of the same number is noise in VoiceOver.
            .accessibilityHidden(true)
    }

    /// Colour is never the only signal — the number beside it is falling, and
    /// at zero the label changes word. This just makes "nearly gone" visible
    /// from across the desk.
    private func urgency(_ left: Int) -> Color {
        if left <= 0 { return .secondary }
        if left <= 8 { return .red }
        if left <= 20 { return .orange }
        return .secondary
    }

    // MARK: - The queue

    private var queueStrip: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(service.pending.count) held")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(service.pending, id: \.id) { request in
                        queuePill(request)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func queuePill(_ request: PausedRequestCodable) -> some View {
        let isSelected = request.id == current?.id
        let edited = drafts[request.id]?.isEdited ?? false
        // A String variable, not a literal: a URL in a `LocalizedStringKey`
        // would be looked up as a translation key.
        let tooltip = "\(request.method) \(request.host)\(BreakpointRequestDraft.pathAndQuery(from: request.uri))"
        return Button {
            selectedID = request.id
        } label: {
            HStack(spacing: 5) {
                Text(request.method)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Text(BreakpointRequestDraft.shortLabel(for: request))
                    .font(.system(size: 10))
                    .lineLimit(1)
                // A pencil on a pill you are not looking at is the only way to
                // know you already edited that one before you get back to it.
                if edited {
                    Image(systemName: "pencil").font(.system(size: 8))
                }
                Text(verbatim: "\(secondsLeft(request))s")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel("\(request.method) \(request.host), \(secondsLeft(request)) seconds left")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - 2. The material

    private func detailSection(for request: PausedRequestCodable) -> some View {
        let current = draft(for: request)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $detail) {
                    Text(headersTabTitle(current)).tag(DetailTab.headers)
                    Text(bodyTabTitle(current)).tag(DetailTab.body)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 0)

                if current.isEdited {
                    Label("Edited", systemImage: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tint)
                    Button("Revert") { revert(request) }
                        .controlSize(.small)
                        .help("Put the headers and body back the way the request arrived")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Group {
                switch detail {
                case .headers: headersView(for: request)
                case .body: bodyView(for: request)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        // The detail area takes the slack, so growing the window grows the
        // editor rather than the padding — and switching tabs never changes
        // the panel's height. A window that resizes under the pointer while
        // someone is deciding is a misclick waiting to happen.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func headersTabTitle(_ draft: BreakpointRequestDraft) -> String {
        guard draft.headersEditable else { return "Headers" }
        return "Headers (\(draft.headers.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.count))"
    }

    /// Never "(none)" (F19): the core holds a request at its head and reports
    /// no body, so this printed "Body (none)" beside `Content-Length: 76`.
    /// What the request declares is the most anyone can say.
    private func bodyTabTitle(_ draft: BreakpointRequestDraft) -> String {
        draft.bodyEdit.tabTitle
    }

    @ViewBuilder
    private func headersView(for request: PausedRequestCodable) -> some View {
        let binding = draftBinding(for: request)
        let current = binding.wrappedValue
        if current.headersEditable {
            // The framing note follows the draft: with a replacement body
            // typed in the Body tab, it names the Content-Length that goes up.
            BreakpointHeaderEditor(headers: binding.headers, original: current.originalHeaders,
                                   framingNote: current.framingNote)
        } else {
            BreakpointUnreadableHeaders(raw: request.headers)
        }
    }

    @ViewBuilder
    private func bodyView(for request: PausedRequestCodable) -> some View {
        BreakpointBodyView(draft: draftBinding(for: request))
    }

    // MARK: - 3. The two ways out

    private func actions(for request: PausedRequestCodable) -> some View {
        let current = draft(for: request)
        let expired = secondsLeft(request) <= 0
        let problem = current.headerProblem
        // The button says what it will actually do. Hoisted to a `String` so
        // the ternary cannot land on `LocalizedStringKey`.
        let resumeTitle: String = current.isEdited ? "Resume with Changes" : "Resume"

        return VStack(alignment: .leading, spacing: 10) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The service refuses a resume it cannot send safely and returns
            // the reason precisely so it can be shown. Storing it and drawing
            // nothing left the user clicking a button that did nothing, with
            // the request still held and no idea why — the worst state this
            // panel can be in, because the clock is running the whole time.
            if let resumeError {
                Label(resumeError, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack(spacing: 8) {
                Button("Abort", role: .destructive) { abort(request) }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!armed || expired)
                Text("with")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $abortStatus) {
                    ForEach(BreakpointAbortPreset.all) { preset in
                        Text(verbatim: "\(preset.code) \(preset.label)").tag(preset.code)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 180)
                .disabled(expired)
                .accessibilityLabel("Status the client receives when aborted")

                Spacer(minLength: 12)

                if service.pending.count > 1 {
                    Button("Resume All") { resumeAllUntouched() }
                        .controlSize(.small)
                        .disabled(!armed)
                        .help("Let every held request through untouched")
                }

                // Deliberately NOT `.defaultAction`. See the file header: this
                // panel can appear mid-keystroke, and Return must not be the
                // thing that releases a request.
                Button(resumeTitle) { resume(request) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!armed || expired || problem != nil)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(outcomeNote(for: request, draft: current, expired: expired))
                Text("Closing this panel resumes everything held, untouched.")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Both outcomes in one sentence, built as a plain `String` so the status
    /// code is printed, not run through `LocalizedStringKey`'s number
    /// formatting — "409" must never come out as a grouped number.
    private func outcomeNote(for request: PausedRequestCodable,
                             draft: BreakpointRequestDraft,
                             expired: Bool) -> String {
        if expired {
            return "The timer ran out — the core is resuming this request untouched, so nothing here can still be sent."
        }
        // The helper's sentence: "sends it on", except a TRACE carrying a
        // body of its own, which ReqRes answers 502 over HTTP/1.1.
        let sent = draft.bodyEdit.held.resumeFooter(host: request.host, edited: draft.isEdited)
        return "\(sent) Abort answers \(abortStatus) here; the request never reaches the server."
    }

    // MARK: - Decisions

    /// Why a resume was refused (a header with a line break in it). Shown
    /// rather than swallowed: the service returns a message precisely so the
    /// user is not left clicking a button that appears to do nothing.
    ///
    /// Reachable only if the panel's own validation and the core's encoder
    /// ever disagree — today they overlap, and that is the point: this is the
    /// second of the two guards, not the only one. Seeded in DEBUG because a
    /// state nothing can produce is also a state nobody has looked at, and a
    /// two-line red message in this stack moves the buttons.
    @State private var resumeError: String? = {
#if DEBUG
        return ProcessInfo.processInfo.environment["REQRES_UI_PROBE_RESUME_ERROR"]
#else
        return nil
#endif
    }()

    private func resume(_ request: PausedRequestCodable) {
        let current = draft(for: request)
        // Belt and braces: the button is already disabled on a problem, but a
        // header carrying a line break must never reach the core because a
        // disabled state was computed a frame ago.
        guard current.canResume else { return }
        if current.isEdited {
            // `editedHeaders()` is the draft's single way out: nil means "send
            // the originals", not "send none", and the service turns the pairs
            // into the one wire shape the core can parse.
            if let message = service.resume(id: request.id,
                                            headers: current.editedHeaders(),
                                            body: current.bodyPayload()) {
                resumeError = message
                return
            }
        } else {
            service.resume(id: request.id)
        }
        resumeError = nil
        drafts[request.id] = nil
    }

    private func abort(_ request: PausedRequestCodable) {
        service.abort(id: request.id, status: abortStatus)
        drafts[request.id] = nil
    }

    /// What closing the panel does, and what "Resume All" does: the harmless
    /// answer for everything at once. It is the same outcome the timeout would
    /// produce, just sooner.
    private func resumeAllUntouched() {
        for request in service.pending { service.resume(id: request.id) }
        drafts.removeAll()
    }

    private func revert(_ request: PausedRequestCodable) {
        var current = draft(for: request)
        current.revert()
        drafts[request.id] = current
        resumeError = nil
    }

    // MARK: - Queue bookkeeping

    private func syncQueue(ids: [String]? = nil) {
        let ids = ids ?? service.pending.map(\.id)

        // Drop edits for requests that are gone. They are large (a whole
        // body), and keeping them risks an edit made for one request being
        // reused for another.
        drafts = drafts.filter { ids.contains($0.key) }
        for request in service.pending where drafts[request.id] == nil {
            drafts[request.id] = BreakpointRequestDraft(request: request)
        }

        if selectedID == nil || !(ids.contains(selectedID ?? "")) {
            selectedID = ids.first
        }
        // The release note is passed along because it decides whether the
        // panel may put itself away: emptying the queue by answering it is the
        // user saying they are done, but emptying it because the timer ran out
        // or capture stopped is news, and a window that vanishes as it arrives
        // delivers nothing.
        BreakpointWindowController.shared.queueDidChange(
            count: ids.count,
            releaseNote: service.lastReleaseNote
        )
    }

    private func draft(for request: PausedRequestCodable) -> BreakpointRequestDraft {
        drafts[request.id] ?? BreakpointRequestDraft(request: request)
    }

    private func draftBinding(for request: PausedRequestCodable) -> Binding<BreakpointRequestDraft> {
        Binding(
            get: { drafts[request.id] ?? BreakpointRequestDraft(request: request) },
            set: {
                drafts[request.id] = $0
                // Any edit makes the refusal stale — it was about the text as
                // it stood, and leaving it up would have the user fixing a
                // header while the panel still says it is broken.
                resumeError = nil
            }
        )
    }

    private func secondsLeft(_ request: PausedRequestCodable) -> Int {
        service.secondsRemaining(for: request)
    }

    private func arm() {
        armed = false
        armToken += 1
        let token = armToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Token-checked: two re-arms in quick succession (a request lands
            // while another is being answered) would otherwise let the older
            // timer arm the buttons early.
            if token == armToken { armed = true }
        }
    }
}

/// The method, colour-coded the way `Chip` colour-codes a status: the first
/// thing read on every row of this app's traffic table, in the same grammar.
struct MethodPill: View {
    let method: String

    var body: some View {
        Text(method.uppercased())
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("\(method) request")
    }

    private var color: Color {
        switch method.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return .gray
        }
    }
}
