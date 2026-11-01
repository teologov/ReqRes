//
//  TrafficTableKeyEvents.swift
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
//  The AppKit half of the traffic table's Esc, Delete and ↑ ↓ (F14): where a
//  key event went, mapped onto `TrafficTableKeys` (Utils), which decides.
//
//  `SessionView`'s key monitor is a LOCAL monitor, so it sees every key press
//  and release of every window of the app — a sheet's, an alert's, Saved
//  Sessions', the Paused Requests panel's. This file answers "was that key
//  meant for this table?" from four facts: the window the event went to,
//  whether that window has a sheet up or an alert is running modally, where
//  its keyboard is, and which modifiers were held. It only asks AppKit
//  questions; every decision, including the order in which the answers place
//  the keyboard, is `TrafficTableKeys`'.
//
//  Kept apart from SessionView on purpose: it needs AppKit, WebKit and Utils
//  only, so the mapping can be compiled on its own and driven with real posted
//  events outside the app — which is how F14 was checked, against a split
//  window, a sheet, a modal alert, other windows and a second main window.
//

import AppKit
import SwiftUI
import Utils
import WebKit

@MainActor
enum TrafficTableKeyEvents {
    /// The table's command for `event`, or nil to let it through untouched.
    ///
    /// `pane` is a view inside the traffic pane (`TrafficPaneAnchor`); its
    /// window is the table's window. Two main windows (File ▸ New Window) each
    /// have their own table and their own monitor, and each acts only for its
    /// own window.
    static func command(for event: NSEvent, pane: NSView?, hasSelection: Bool) -> TrafficTableKeys.Command? {
        // Not in a window yet (or any more): nothing is the table's.
        guard let pane, let window = pane.window else { return nil }
        return TrafficTableKeys.command(
            keyCode: event.keyCode,
            modifiers: modifiers(event.modifierFlags),
            isTrafficWindow: event.window === window,
            hasAttachedSheet: window.attachedSheet != nil,
            modalRunning: NSApp.modalWindow != nil,
            responder: responder(window.firstResponder, in: window, trafficPane: trafficPane(containing: pane)),
            hasSelection: hasSelection
        )
    }

    /// `event` is the release of ↑ or ↓ — wherever it went: the detail pane
    /// waits for a held arrow to be let go of (`TrafficDetailDebounce`), and
    /// the release can go to another window (a sheet that came up while the
    /// key was down). Only asked; the release is always passed on.
    static func releasesArrow(_ event: NSEvent) -> Bool {
        event.type == .keyUp && TrafficTableKeys.isArrow(event.keyCode)
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> TrafficTableKeys.Modifiers {
        var modifiers: TrafficTableKeys.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.function) { modifiers.insert(.function) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if flags.contains(.numericPad) { modifiers.insert(.numericPad) }
        return modifiers
    }

    /// The traffic pane's own view: the ancestor of `view` that is an
    /// arranged subview of the main window's NSSplitView (sidebar | overrides
    /// | traffic, `ReqResSplitHost`). Nothing between the table and that split
    /// view is an NSSplitView — the request | response split inside the pane
    /// is the SplitView package's, pure SwiftUI. A window without one (a probe
    /// hosting SessionView alone) is all traffic pane.
    static func trafficPane(containing view: NSView) -> NSView? {
        var current: NSView? = view
        while let candidate = current {
            if candidate.superview is NSSplitView { return candidate }
            current = candidate.superview
        }
        return view.window?.contentView
    }

    /// Where the keyboard is, as `TrafficTableKeys` needs it: each fact is ONE
    /// question asked of AppKit here, and `TrafficTableKeys.responder` reads
    /// the answers in the order that makes the rule — text before anything
    /// else, a web view and a list before the traffic pane — where every
    /// combination is tested. So a field being edited in a list row is text,
    /// a body being read gives Esc to the table and keeps Delete, and a list
    /// in the traffic pane keeps its own keys.
    ///
    /// The window's root content view (SwiftUI's hosting view for the whole
    /// window) holding the keyboard is the window itself: no pane has it.
    static func responder(_ responder: NSResponder?, in window: NSWindow, trafficPane: NSView?) -> TrafficTableKeys.Responder {
        guard let responder else { return .other }
        let view = responder as? NSView
        var isInTrafficPane = false
        if let view, let trafficPane { isInTrafficPane = view.isDescendant(of: trafficPane) }
        return TrafficTableKeys.responder(
            isWindow: responder === window || responder === window.contentView,
            isText: responder is NSText || responder is NSTextField,
            isEditable: (responder as? NSText)?.isEditable ?? (responder as? NSTextField)?.isEditable ?? false,
            isView: view != nil,
            isInWebView: view.map { sequence(first: $0, next: { $0.superview }).contains(where: { $0 is WKWebView }) } ?? false,
            isList: responder is NSTableView || responder is NSCollectionView,
            isInTrafficPane: isInTrafficPane,
            isInWindow: view?.window === window
        )
    }
}

/// A view inside the traffic pane, so the key monitor can tell which window
/// and which pane the table is in (`TrafficTableKeyEvents.trafficPane`). It
/// draws nothing and never takes a click.
struct TrafficPaneAnchor: NSViewRepresentable {
    /// Held in SessionView's state; the monitor reads the view through it.
    final class Box {
        weak var view: NSView?
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
