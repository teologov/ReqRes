//
//  TrafficSearchFieldCore.swift
//  ReqRes
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
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
//  The AppKit core of the toolbar search field: a STABLE NSTextField instance
//  plus a non-activating suggestions panel.
//
//  WHY APPKIT, WHY A STABLE INSTANCE: a SwiftUI `TextField` inside a toolbar
//  item loses the caret whenever SwiftUI replaces the item's hosting view,
//  which it does on model publishes — including the one fired by the field's
//  own debounced search landing. The window's shared field editor then stays
//  bound to an NSTextField that has left the view tree. Every app-side suspect
//  was exonerated one at a time, so the rebuild cannot be prevented — it has to
//  stop mattering. `StableSearchTextField` is created once (owned by
//  `TrafficSearchFieldModel`, which the toolbar controller holds) and handed to
//  SwiftUI by a representable that always returns the SAME instance. If a
//  rebuild detaches it mid-edit it reclaims first responder and the selection
//  one runloop turn later. The text lives on the instance, so it is never lost.
//
//  WHY A PANEL FOR THE SUGGESTIONS: an `.overlay` renders outside the toolbar
//  item's bounds where AppKit draws but does not hit-test (rows visible yet
//  unclickable); a `.popover` takes key and costs the caret. A borderless,
//  NON-ACTIVATING panel is the platform's completion-list idiom (Spotlight,
//  Xcode): its own hit-test root, and it never becomes key.
//

import AppKit
import SwiftUI

// MARK: - Stable text field

/// An `NSTextField` that survives SwiftUI tearing down its host: if it is
/// detached from the window while it owns the caret, it takes the caret back
/// (with the selection preserved) as soon as it is re-attached.
final class StableSearchTextField: NSTextField {

    /// Called when the field becomes first responder.
    var onFocusGained: (() -> Void)?

    /// Arms a one-shot focus claim for the next time the field lands in a
    /// window — focus can be requested (⌘F) while the item is folded into the
    /// overflow and the field is not attached.
    private var claimsFocusOnAttach = false

    private var restoresFocusOnAttach = false
    private var savedSelection: NSRange?

    func focusWhenAttached() {
        if let window {
            window.makeFirstResponder(self)
        } else {
            claimsFocusOnAttach = true
        }
    }

    /// Reclaims the caret after AppKit force-ended the editing session.
    ///
    /// A toolbar rebuild that removes a view containing the window's FIELD
    /// EDITOR makes `-[NSView removeFromSuperview]` call `endEditingFor:` —
    /// editing dies and first responder parks on the WINDOW before this field
    /// is detached, so `viewWillMove` never arms. One turn later, after the
    /// teardown, the caret is taken back IF AND ONLY IF nobody else claimed
    /// it. It converges because healing publishes nothing.
    func healFocus(restoring selection: NSRange?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let window = self.window else {
                self.claimsFocusOnAttach = true
                self.savedSelection = selection
                return
            }
            guard window.firstResponder === window else { return }
            let ok = window.makeFirstResponder(self)
            if ok, let selection, let editor = self.currentEditor() {
                let length = (self.stringValue as NSString).length
                editor.selectedRange = NSRange(location: min(selection.location, length), length: 0)
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let editor = currentEditor() {
            // Detached mid-edit: the field editor is about to be orphaned.
            restoresFocusOnAttach = true
            savedSelection = editor.selectedRange
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        guard restoresFocusOnAttach || claimsFocusOnAttach else { return }
        let selection = savedSelection
        restoresFocusOnAttach = false
        claimsFocusOnAttach = false
        savedSelection = nil
        // One turn later: the hierarchy mutation that brought us here may still
        // be in progress. Key events queue behind this block.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let ok = window.makeFirstResponder(self)
            if ok, let selection, let editor = self.currentEditor() {
                let length = (self.stringValue as NSString).length
                editor.selectedRange = NSRange(location: min(selection.location, length), length: 0)
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusGained?() }
        return ok
    }
}

// MARK: - Representable

/// Hands the model's one stable field to SwiftUI. Deliberately owns NOTHING:
/// creation, delegation and lifetime all live on the model, so a destroyed
/// and recreated representable reconnects to the same field, text and caret.
struct TrafficSearchFieldCoreView: NSViewRepresentable {
    let model: TrafficSearchFieldModel
    let availableWidth: CGFloat

    func makeNSView(context: Context) -> StableSearchTextField {
        model.availableWidth = availableWidth
        return model.field
    }

    func updateNSView(_ nsView: StableSearchTextField, context: Context) {
        model.availableWidth = availableWidth
        // Committed chips or the host list changed under an open panel.
        model.environmentDidChange()
    }
}

// MARK: - Suggestions panel

/// The dropdown's window mechanics. Content is a hosted SwiftUI view;
/// everything else is positioning and the non-activating behaviour that
/// keeps the caret in the field.
@MainActor
final class TrafficSearchSuggestionsPanel {

    /// A panel that can NEVER take key or main status — the hard guarantee
    /// that opening or clicking the list cannot move the caret out of the
    /// field. (`becomesKeyOnlyIfNeeded` alone still allows key status if
    /// something in the content asks for it.)
    private final class CompletionPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Rows must react to the FIRST click even though their window is never
    /// key — the default first-mouse behaviour would swallow it.
    private final class ClickThroughHostingView: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var resizeObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(below anchor: NSView, width: CGFloat, content: AnyView) {
        guard let window = anchor.window else { return }
        let panel = ensurePanel()
        guard let hosting else { return }
        hosting.rootView = AnyView(content.frame(width: width))
        var size = hosting.fittingSize
        size.width = width
        hosting.frame = NSRect(origin: .zero, size: size)

        // Left-aligned under the field's box. The field's leading chrome
        // (10pt padding + 14pt magnifier + 6pt gap) sits before the text
        // input, so shift by that much to align with the visible capsule.
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let origin = NSPoint(x: anchorRect.minX - 30, y: anchorRect.minY - size.height - 10)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)

        if resizeObserver == nil {
            // A live resize refolds the toolbar and moves the field; menus
            // dismiss on resize too.
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    func update(content: AnyView, width: CGFloat) {
        guard let panel, panel.isVisible, let hosting else { return }
        hosting.rootView = AnyView(content.frame(width: width))
        var size = hosting.fittingSize
        size.width = width
        hosting.frame = NSRect(origin: .zero, size: size)
        // Keep the TOP edge pinned while the row count changes.
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
    }

    #if DEBUG
    /// The panel's content rasterised — a freshly painted panel renders
    /// through `cacheDisplay`, unlike long-lived SwiftUI panes.
    func snapshotPNG() -> Data? {
        guard let hosting, isVisible,
              let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    #endif

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = CompletionPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        let hosting = ClickThroughHostingView(rootView: AnyView(EmptyView()))
        // Round the WINDOW's own surface, not just the card inside it, or the
        // hosting view's square corners peek out behind the card's rounded
        // ones. The panel's native shadow follows the rounded layer.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 10
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }
}
