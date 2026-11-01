//
//  SavedSessionsWindowController.swift
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
//  The saved-sessions browser's window, built exactly like
//  HelpWindowController: an AppKit NSWindow around an NSHostingView rather
//  than a SwiftUI `Window` scene. Every window in this app that is not the
//  main one is hosted this way — a `Window` scene was tried for the forms and
//  rejected (this app's forms are sheets, never `Window` scenes).
//
//  Like Help, this is something the person opens on purpose and then works
//  in, so it is an ordinary activating, closable, resizable window that
//  remembers where it was left — not the non-activating panel shape the MCP
//  approval prompt needs.
//

import AppKit
import SwiftUI

@MainActor
final class SavedSessionsWindowController {
    static let shared = SavedSessionsWindowController()

    private var window: NSWindow?

    private init() {}

    /// The one entry point for every caller (the menu item the app wires up,
    /// a future "Saved" toolbar action). Built lazily: most launches never
    /// open this window, and building it would touch the database.
    func show() {
        let window = self.window ?? makeWindow()
        // Deliberately here rather than in a `.task` on the view. The window
        // is retained, so its view stays mounted between opens and a `.task`
        // would run exactly once per launch — reopening the browser after
        // saving something new would then show a list that predates it.
        Task { await SavedSessionsStore.shared.reload() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingView(rootView: SavedSessionsWindow())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Saved Sessions"
        window.contentView = hosting
        // The floor is what the detail pane needs to stay readable: the
        // request and response tab bars sit side by side, and the main
        // window measured them at ~620pt together —
        // below that the tab titles are cut off, plus the list pane.
        window.minSize = NSSize(width: 860, height: 440)
        // Not released on close: `show()` reuses this instance, so the
        // selection, the search text and the scroll position survive being
        // closed and reopened within a session.
        window.isReleasedWhenClosed = false
        window.center()
        // Restores the saved frame if there is one; otherwise keeps the
        // centred frame set above.
        window.setFrameAutosaveName("ReqResSavedSessionsWindow")
        self.window = window
        return window
    }
}
