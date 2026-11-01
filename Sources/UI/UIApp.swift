//
//  UIApp.swift
//  UI
//
//  Created by OloApps on 14.06.2023.
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

import SwiftUI
import Combine
import XReqResCore

enum ReqResMainWindow {
    /// Wide enough for the sidebar, the overrides pane and a 660pt traffic pane
    /// with room to spare (the sidebar auto-collapses below 1082), inside the
    /// ~85% of a 14" display that macOS allows a default.
    /// `ReqResSplitHost.sizeThatFits` is what makes SwiftUI honour it.
    static let defaultSize = CGSize(width: 1250, height: 630)

    /// Stamped on the main window so anything outside the SwiftUI scene can
    /// find it again — the menu bar's "Open ReqRes" in particular, which
    /// cannot pick it out of `NSApp.windows` (unspecified order, and Settings
    /// is in there too).
    static let identifier = NSUserInterfaceItemIdentifier("ReqResMainWindow")
}

@main
struct UIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // No `id:` on this group: with one, SwiftUI opened NO window at launch
        // (measured — the process ran with zero windows). A saved frame still
        // wins over the default below; only fresh installs get it.
        WindowGroup {
            AppView()
        }
        .defaultSize(ReqResMainWindow.defaultSize)
        .commands {
            // Replace the default About menu item
            CommandGroup(replacing: .appInfo) {
                Button("About ReqRes") {
                    AboutWindowController.shared.showAboutWindow()
                }
            }
            // Replaces the default Help item, which opened a help book this
            // app does not ship and so did nothing at all.
            CommandGroup(replacing: .help) {
                Button("ReqRes Help") {
                    HelpWindowController.shared.show()
                }
                .keyboardShortcut("?", modifiers: .command)
            }
            // Saved sessions are reached from the same place the traffic they
            // came from is: the window menu, next to the main window.
            CommandGroup(after: .windowList) {
                Button("Saved Sessions") {
                    SavedSessionsWindowController.shared.show()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                // Where the traffic went, on a map (destination-map UX spec
                // §2.1): ⌘⇧S saved · ⌘⇧C capture · ⌘⇧N host · ⌘⇧R override ·
                // ⌘⇧D destinations.
                Button("Destinations") {
                    TrafficCommands.showDestinations()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
          MainMenu()
        }
        
        Settings {
            SettingsView()
        }
    }
}
