//
//  BreakpointWindowController.swift
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
//  The window around BreakpointPanel: an AppKit window hosting an
//  NSHostingView, like every window in this app that is not the main one
//  (see HelpWindowController and SavedSessionsWindowController — a SwiftUI
//  `Window` scene was tried for the forms and rejected).
//
//  WHICH shape, and why — this app already ships both:
//
//  MCPApprovalWindow is a non-activating NSPanel that can never become key.
//  HelpWindowController is an ordinary activating NSWindow you open on
//  purpose. A held request is the first case, not the second: it arrives
//  unannounced while the person is in a browser or a terminal, over whatever
//  they were doing, and it must not take the keystroke they were mid-way
//  through typing. So this is a floating, NON-ACTIVATING panel that hovers
//  above other apps and bounces the Dock instead of stealing focus.
//
//  It differs from the approval panel in exactly three ways, each forced by
//  what this panel is for:
//
//   * `becomesKeyOnlyIfNeeded = true`, and `canBecomeKey` is true. Editing a
//     header means typing, and a panel that can never be key cannot accept a
//     keystroke at all. This is the AppKit setting that threads the needle:
//     the panel does NOT take the keyboard when it appears — only when the
//     user clicks into a field in it. The guarantee the approval panel was
//     given (your next keystroke cannot answer this window) still holds,
//     because answering is a click and Return is bound to nothing. Once the
//     panel has the keyboard, Escape is the one key that answers — closing,
//     which resumes everything untouched — except that while a field is being
//     edited the first Escape only ends the editing, and a held Escape's
//     repeats never close it (BreakpointDecisionPanel.swift).
//   * It is CLOSABLE and RESIZABLE. The approval panel has no close button
//     because closing it would leave an agent's call unanswered; here closing
//     has an honest meaning — resume everything untouched, which is what the
//     timeout would do anyway — and the panel says so in its footer. Resizable
//     because a body editor in a fixed 460pt box is not an editor.
//   * It is not alert-shaped: it keeps a real title, so a panel pushed behind
//     something can be found in the Window menu, and it remembers where it
//     was put.
//

import AppKit
import SwiftUI
import XReqResCore

// The panel's class, and what its Escape does, are in
// BreakpointDecisionPanel.swift.

@MainActor
final class BreakpointWindowController: NSObject, NSWindowDelegate {
    static let shared = BreakpointWindowController()

    private var panel: BreakpointDecisionPanel?
    /// Used to tell "opened with nothing held" (leave it up, it is explaining
    /// what breakpoints are) from "the last held request was just answered"
    /// (close it, the person wants their browser back).
    private var lastKnownCount = 0
    private var isClosing = false

    private override init() { super.init() }

    /// The one entry point. Called when a request is held; idempotent, so a
    /// second hit while the panel is already up just raises it.
    func show() {
        let panel = self.panel ?? makePanel()
        let count = BreakpointService.shared.pending.count
        panel.title = Self.title(for: count)
        lastKnownCount = count
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the panel
        // appears over the frontmost app without pulling ReqRes forward.
        panel.orderFrontRegardless()
        // A request is stopped and someone is waiting on it, so the Dock icon
        // bounces — but only when the app is in the background, where that is
        // the only signal available.
        if !NSApp.isActive {
            NSApp.requestUserAttention(.criticalRequest)
        }
    }

    /// Put the panel away without touching what is held. `orderOut` on
    /// purpose: it does not run `windowShouldClose`, so this can never trip
    /// the resume-everything behaviour that the close BUTTON means.
    func hide() {
        panel?.orderOut(nil)
    }

    /// Told by the panel's view whenever the held-request list changes.
    ///
    /// Two jobs: keep the window's title honest (it is how this panel is found
    /// in the Window menu once it is behind something), and put the panel away
    /// once the last held request has been answered — an empty panel floating
    /// over someone's browser is clutter, and the click that emptied it was
    /// their way of saying they are done.
    ///
    /// `releaseNote` is what stops the second job from swallowing the first.
    /// The service only sets one when the queue drained WITHOUT the user
    /// answering it: the timer ran out, breakpoints were switched off, capture
    /// stopped. That is the one case where the panel has something to say as
    /// it empties, and hiding on the same frame would take a request that was
    /// released behind the user's back and make it look like nothing ever
    /// matched. So it stays up with the note, and closing it dismisses it.
    func queueDidChange(count: Int, releaseNote: String? = nil) {
        defer { lastKnownCount = count }
        panel?.title = Self.title(for: count)
        guard !isClosing else { return }
        if count == 0, lastKnownCount > 0, releaseNote == nil { hide() }
    }

    // MARK: - NSWindowDelegate

    /// Closing the panel answers everything it was holding, untouched.
    ///
    /// The alternative — close and leave requests held — is the failure this
    /// panel exists to prevent: a stopped request with nothing on screen
    /// explaining why, until a timeout the user cannot see. Resuming is the
    /// harmless answer and the same one the timeout produces, so closing just
    /// gets there sooner. The panel's footer states this before it happens.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        isClosing = true
        defer { isClosing = false }
        for request in BreakpointService.shared.pending {
            BreakpointService.shared.resume(id: request.id)
        }
        return true
    }

    // MARK: - Construction

    private func makePanel() -> BreakpointDecisionPanel {
        let panel = BreakpointDecisionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: BreakpointPanel())
        // The floor is what the decision needs to stay legible: the abort
        // status picker and the two buttons on one line, and a detail area
        // still worth reading. Matches the view's own `minWidth`/`minHeight`.
        panel.minSize = NSSize(width: 520, height: 430)
        // Floating: the request it describes is blocking an app in front of
        // this one, so the panel has to be visible from there.
        panel.level = .floating
        // Stays put when ReqRes is not frontmost — which is the normal case
        // for a breakpoint, and the default for `.utilityWindow` is the
        // opposite.
        panel.hidesOnDeactivate = false
        // Reused across hits, so the SwiftUI state inside it — the drafts for
        // requests still held, the selected tab — survives a close.
        panel.isReleasedWhenClosed = false
        // The needle from the file header: key only when a field is clicked.
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.center()
        // Restores the saved frame when there is one; someone who widened
        // this panel to read bodies wants it that way next time too.
        panel.setFrameAutosaveName("ReqResBreakpointPanel")
        self.panel = panel
        return panel
    }

    private static func title(for count: Int) -> String {
        switch count {
        case 0: return "Paused Requests"
        case 1: return "1 Paused Request"
        default: return "\(count) Paused Requests"
        }
    }
}
