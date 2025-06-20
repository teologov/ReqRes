//
//  AboutWindowManager.swift
//  ReqRes
//
//  Created by OloApps on 6/9/25.
//
//  Copyright © 2025 OloApps. All rights reserved.
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

import AppKit
import SwiftUI

// MARK: - Window Delegate
class AboutWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }
    
    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Alternative Approach: Singleton Pattern
class AboutWindowController {
    static let shared = AboutWindowController()
    private var aboutWindow: NSWindow?
    private var windowDelegate: AboutWindowDelegate?
    
    private init() {}
    
    func showAboutWindow() {
        // If window exists, activate it
        if let window = aboutWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor.controlBackgroundColor
        window.isReleasedWhenClosed = false  // Important: prevent auto-release
        
        // Set content
        window.contentView = NSHostingView(rootView: AboutView())
        
        // Set delegate
        windowDelegate = AboutWindowDelegate { [weak self] in
            self?.aboutWindow = nil
            self?.windowDelegate = nil
        }
        window.delegate = windowDelegate
        
        // Position and show
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        // Store reference
        aboutWindow = window
    }
}
