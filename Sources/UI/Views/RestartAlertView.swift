//
//  RestartAlertView.swift
//  ReqRes
//
//  Created by OloApps on 3/17/25.
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
import XReqResCore

struct RestartAlertView: View {
    @State private var showingAlert = false
    
    var body: some View {
        EmptyView()
            .onAppear {
                // Wait a moment before showing alert to avoid conflicts with system dialogs
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingAlert = true
                }
            }
            .alert("Restart Recommended", isPresented: $showingAlert) {
                Button("Restart Now") {
                    restartComputer()
                }
                Button("Later", role: .cancel) {}
            } message: {
                Text("Your network extension is now configured, but a restart is required to fully activate it. Would you like to restart now?")
                    .multilineTextAlignment(.center)
            }
    }
    
    private func restartComputer() {
        let script = """
        tell application "System Events"
            restart
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                AppLog.shared.error("[RestartAlertView] Error restarting: \(error)")
            }
        }
    }
}

// 3. Create a controller for showing the restart alert
class RestartAlertController {
    static let shared = RestartAlertController()
    
    private var hostingController: NSHostingController<RestartAlertView>?
    
    func showRestartAlert() {
        AppLog.shared.debug("[RestartAlertController] Showing restart alert")
        
        // Only show if we haven't shown it before
        if !AppPreferences.shared.hasShownRestartPrompt {
            AppPreferences.shared.hasShownRestartPrompt = true
            
            // Create the alert view as a standalone window
            let alertView = RestartAlertView()
            let hostingController = NSHostingController(rootView: alertView)
            self.hostingController = hostingController
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingController.view
            window.center()
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
