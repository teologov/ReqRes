//
//  MCPApprovalWindow.swift
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
//  The approval request as its OWN floating panel, not a `.sheet` on the
//  main window: SwiftUI presents one sheet per view, and the main window
//  regularly has one up — the paywall at every free launch, the New Host and
//  New Override forms — during which a sheet-based approval would never show
//  and the agent's call would time out into a denial (measured 2026-09-17:
//  the probe captured the paywall where the approval should have been). A
//  panel also works with the main window closed or minimised, and it is
//  NON-ACTIVATING: it appears while the human is typing in the agent's client,
//  so it must not take the keyboard (there is no Return-to-approve either).
//

import AppKit
import SwiftUI

/// Non-activating: the request arrives while the human is working in the
/// agent's client, and a panel that grabs the keyboard would put their next
/// keystroke on a button that changes live traffic.
final class MCPApprovalPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MCPApprovalWindowController {
    static let shared = MCPApprovalWindowController()

    private var panel: MCPApprovalPanel?

    private init() {}

    /// The panel's width; the content declares the same, and the hosting view
    /// is constrained to it BEFORE it is measured — an unconstrained
    /// NSHostingView reports its ideal width (900pt here, measured) and the
    /// panel opened that wide.
    static let width: CGFloat = 460

    func show(_ group: MCPAgentActivity.PendingApprovalGroup) {
        let panel = self.panel ?? makePanel()
        let hosting = NSHostingView(rootView: MCPApprovalSheet(group: group))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting
        NSLayoutConstraint.activate([hosting.widthAnchor.constraint(equalToConstant: Self.width)])
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        panel.setContentSize(NSSize(width: Self.width, height: height))
        position(panel)
        panel.orderFrontRegardless()
        // The agent's client is frontmost; bounce the Dock rather than
        // stealing focus mid-keystroke.
        NSApp.requestUserAttention(.criticalRequest)
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> MCPApprovalPanel {
        // No close button: closing IS a decision. Deny is a click, like Allow:
        // no key ever reaches this panel — it can never become key — so
        // Escape does not deny (and Return does not allow).
        let panel = MCPApprovalPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "ReqRes"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .alertPanel
        self.panel = panel
        return panel
    }

    /// Centred over the main window when there is one, else on the main screen.
    private func position(_ panel: NSPanel) {
        if let main = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }) {
            let frame = main.frame
            let origin = NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2 + frame.height * 0.15
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
    }
}
