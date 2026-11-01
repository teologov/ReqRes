//
//  BreakpointDecisionPanel.swift
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
//  The Paused Requests panel's window class. Why it is a non-activating panel
//  that can still become key — and how it differs from the MCP approval panel
//  — is in BreakpointWindowController.swift's header, which builds it.
//
//  Its own file because it needs AppKit only: its Escape can then be
//  exercised outside the app, without the core behind the panel.
//

import AppKit

final class BreakpointDecisionPanel: NSPanel {
    /// True, unlike `MCPApprovalPanel` — see BreakpointWindowController.swift's
    /// header. Paired with `becomesKeyOnlyIfNeeded`, which is what keeps it
    /// from taking focus merely by appearing.
    override var canBecomeKey: Bool { true }
    /// Never main: this is a utility over the user's work, not the app's
    /// primary window.
    override var canBecomeMain: Bool { false }

    /// Escape closes, and closing resumes everything untouched. The harmless
    /// answer is the one behind the escape key; Abort is never a keystroke.
    ///
    /// Except while a field is being edited: then the first Escape only ends
    /// the editing — the draft keeps what was typed and nothing is sent — and a
    /// second one closes. Otherwise an Escape meant to leave a header field
    /// would throw the panel away and release EVERY held request. (Until F14 no
    /// Escape reached this panel at all while the traffic list showed rows: its
    /// key monitor swallowed Escape in every window of the app.)
    ///
    /// Only a text view turns Escape into this message; an Escape pressed
    /// anywhere else in the panel arrives through `keyDown(with:)` below,
    /// which sends it here.
    override func cancelOperation(_ sender: Any?) {
        if Self.isEditingText(firstResponder) {
            makeFirstResponder(nil)
            return
        }
        performClose(nil)
    }

    /// An Escape no text view turned into `cancelOperation(_:)`. Pressed while
    /// the panel itself holds the keyboard — after the first Escape ended an
    /// edit, or after a click on a picker or a button — it goes up the
    /// responder chain as a plain keyDown and, with nothing to take it, ends
    /// in a beep. Before this override every such Escape did: the second
    /// Escape after an edit only beeped, and the keyboard closed the panel
    /// only while a read-only text held it (measured with real key events,
    /// 2026-09-30). With ⌘, ⌥ or ⌃ held it is someone else's key.
    ///
    /// A held Escape's auto-repeats are not a second press: closing resumes
    /// EVERY held request, so it takes a press of its own. They are kept and
    /// do nothing — passed on, they would only beep.
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == Self.escapeKeyCode,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat else { return }
        cancelOperation(nil)
    }

    /// A text being typed into: a header field (its field editor) or the body
    /// editor. Read-only text — the original body of a request the panel
    /// cannot edit — is not being edited, so Escape there closes.
    static func isEditingText(_ responder: NSResponder?) -> Bool {
        (responder as? NSText)?.isEditable == true
    }

    /// kVK_Escape: what `NSEvent.keyCode` carries for Escape, whatever the
    /// keyboard layout.
    static let escapeKeyCode: UInt16 = 0x35
}
