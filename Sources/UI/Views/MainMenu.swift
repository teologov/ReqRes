//
//  MainMenu.swift
//  ReqRes
//
//  Created by OloApps on 6/17/24.
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

struct MainMenu: Commands {
    @AppStorage("selectedSettingsTab") private var selectedSettingsTab = SettingsTab.general
    @Environment(\.openSettings) private var openSettings
    // The one updater in the process — see `SparkleViewModel.shared`. Creating
    // it here made Settings unable to show update state without starting a
    // second one.
    @ObservedObject private var sparkleViewModel = SparkleViewModel.shared
    // The capture item retitles itself, so the menu has to observe the state
    // that decides the word.
    @ObservedObject private var appState = AppState.shared
    
    var body: some Commands {
        // Add the "Check for Updates..." command to the application menu
        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                sparkleViewModel.checkForUpdates()
            }
            .disabled(!sparkleViewModel.canCheckForUpdates)
            
            if let lastCheck = sparkleViewModel.lastUpdateCheckDate {
                Text("Last checked: \(lastCheck, format: .dateTime)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        // `SidebarCommands` sends `toggleSidebar:` up the responder chain,
        // which the real NSSplitViewController implements — so ⌃⌘S and the
        // toolbar's own toggle drive the same thing.
        SidebarCommands()
        // No `ToolbarCommands`: the toolbar is AppKit-owned with customization
        // disabled, so "Customize Toolbar…" would open an empty sheet.

        // The forms are sheets on the main window; these post the same
        // notifications the toolbar's ＋ menu does.
        CommandGroup(after: .newItem) {
            Button("New Host Filter…") {
                NotificationCenter.default.post(name: ReqResToolbarController.addHostFilter, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.shift, .command])
            Button("New Override…") {
                NotificationCenter.default.post(name: ReqResToolbarController.createOverride, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.shift, .command])
        }

        CommandGroup(after: .textEditing) {
            Button("Find") {
                NotificationCenter.default.post(name: ReqResToolbarController.focusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        // Capture is the app's primary verb and until now it had exactly ONE
        // reachable surface: a single toolbar button, which folds into the
        // overflow chevron at narrow widths and does not exist at all with no
        // window open. A menu command is also what gives it a keyboard
        // shortcut and what the menu bar item will route to.
        CommandMenu("Capture") {
            Button(appState.vpnStatus == .connected ? "Stop Capturing" : "Start Capturing") {
                TrafficCommands.toggleCapture()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            // Transitional states are not a decision point — the tunnel is
            // already doing one of the two things.
            // `.reasserting` counts too. The menu bar item treats all three as
            // transitional, and a ⌘⇧C that lands during a reassert reaches
            // stopVPNTunnel() on a tunnel that is mid-rebuild.
            .disabled(appState.vpnStatus == .connecting
                      || appState.vpnStatus == .disconnecting
                      || appState.vpnStatus == .reasserting)

            Divider()

            Button("Diagnose Setup…") {
                TrafficCommands.explainSetup()
            }
        }

        CommandMenu("Certificate") {
            Button("Install CA Certificate...") {
                selectedSettingsTab = .certificate
                openSettings()
            }
        }
    }
}
