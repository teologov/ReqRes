//
//  SessionContentView.swift
//  ReqRes
//
//  Created by OloApps on 3/27/25.
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

import SwiftUI
import XReqResCore

struct SessionContentView: View {
    @ObservedObject var sessionState = SessionState.shared
    @ObservedObject var appState = AppState.shared
    
    // Track extension status
    // @State private var extensionStatus: ExtensionSetupStatus = .ready
    
    var body: some View {
        let completelyEmpty = sessionState.sessions.isEmpty
        let filteredSessionsEmpty = sessionState.filteredSessions.isEmpty
        let searchTextEmpty = sessionState.searchText.isEmpty
        
        Group {
            if appState.extensionStatus != .ready {
                // Extension status issues - prioritize these messages
                switch appState.extensionStatus {
                case .notInstalled:
                    EmptyStateView(
                        title: "Install Network Extension",
                        subtitle: "Click 'Install Network Extension' below to set up the monitoring system. This requires your permission to install a system extension.",
                        iconName: "shield.lefthalf.filled",
                        buttonTitle: "Install Network Extension",
                        buttonAction: handleStartOrInstallTunnel
                    )
                case .extensionDisabled:
                    // If the extension is disabled, show the "Install Network Extension" button
                    EmptyStateView(
                        title: "Activate Network Extension",
                        subtitle: "To use network monitoring, you need to activate the network extension in System Preferences.",
                        iconName: "shield.lefthalf.filled",
                        buttonTitle: "Activate Network Extension",
                        buttonAction: openSystemSettings
                    )
                case .needsRestart:
                    EmptyStateView(
                        title: "Restart App Recommended",
                        subtitle: "Your network extension is now configured, but you need to restart the app to fully activate it. In some cases, a system restart may be required.",
                        iconName: "arrow.counterclockwise",
                        buttonTitle: "Restart App",
                        buttonAction: restartApp
                    )
                case .configurationMissing:
                    EmptyStateView(
                        title: "Install VPN Configuration",
                        subtitle: "VPN configuration needs to be installed. Click the button below to create and install it.",
                        iconName: "gear.badge.questionmark",
                        buttonTitle: "Install VPN Configuration",
                        buttonAction: checkVPNConfigurationInstalled
                    )
                default:
                    EmptyStateView(
                        title: "Extension Error",
                        subtitle: "There's an issue with the network extension.",
                        iconName: "exclamationmark.triangle"
                    )
                }
            } else if completelyEmpty && appState.vpnStatus == .disconnected {
                // Tunnel not running, no sessions, extension ready
                // This is either first-time use or user has stopped monitoring
                
                // Only show "Start Monitoring" if the extension is fully ready AND has been attempted before
                let isExtensionFullyReady = appState.extensionStatus == .ready
                
                EmptyStateView(
                    title: "Start Network Monitoring",
                    subtitle:
                    "Click 'Start Monitoring' below or the play button in the top right corner to begin capturing and inspecting network traffic.",
                    iconName: "network",
                    buttonTitle: "Start Monitoring",
                    buttonAction: handleStartOrInstallTunnel
                )
            } else if completelyEmpty {
                // Regular empty state
                EmptyStateView(
                    title: "No Requests",
                    subtitle: "When ReqRes captures requests, they will appear here.",
                    iconName: "tray.and.arrow.down.fill"
                )
            } else if filteredSessionsEmpty && searchTextEmpty {
                EmptyStateView(
                    title: "No Requests",
                    subtitle: "ReqRes hasn't captured any requests for this host yet.",
                    iconName: "tray.and.arrow.down.fill"
                )
            } else if filteredSessionsEmpty && !searchTextEmpty {
                EmptyStateView(
                    title: "No Requests Found",
                    subtitle: "Requests matching your search query were not found.",
                    iconName: "rectangle.and.text.magnifyingglass"
                )
            } else {
                SessionView()
            }
        }
        .onAppear {
            checkExtensionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: ExtensionStatusManager.extensionStatusChanged)) { notification in
            // Get status from notification if available
            /*if let statusRawValue = notification.userInfo?["status"] as? String,
               let status = ExtensionSetupStatus(rawValue: statusRawValue) {
                self.extensionStatus = status
            } else if let _ = notification.userInfo?["isEnabled"] as? Bool {
                // Fallback for backward compatibility
                // Refresh full status asynchronously without showing alerts
                checkExtensionStatus()
            }*/
        }
    }
    
    // MARK: - Helper Functions
    
    /// Handles the initial start button click
    private func handleStartOrInstallTunnel() {
        // First check if we have proper permissions and config
        Task {
            do {
                let status = try await ExtensionStatusManager.shared.checkCompleteStatus()
                
                // Update on main thread
                await MainActor.run {
                    // Update our status internally, but don't show alerts
                    appState.extensionStatus = status
                    
                    // Don't block toggling, let the toggle function handle the result
                    do {
                        _ = try AppController.shared.toggleVPNTunnel()
                    } catch {
                        
                    }
                }
            } catch {
                await MainActor.run {
                    
                }
            }
        }
    }
    
    private func _handleVPNConfigurationInstall() {
        do {
            // Just call toggleVPNTunnel - it will handle creating the config
            _ = try AppController.shared.toggleVPNTunnel()
        } catch {
            AppLog.shared.error("[SessionContentView] Error installing VPN configuration: \(error.localizedDescription)")
        }
    }
    
    private func openSystemSettings() {
        // Create the appropriate URL based on OS version using #available
        let url: URL?
        
        if #available(macOS 15.0, *) {
            // macOS 15 (Sequoia) and later
            url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        } else if #available(macOS 14.0, *) {
            // macOS 14 (Sonoma)
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security")
        } else {
            // macOS 13 (Ventura) and earlier
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Extensions")
        }
        
        // Open the system settings
        if let url = url {
            NSWorkspace.shared.open(url)
        } else {
            // Fallback to the Security & Privacy pane if the URL fails
            let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
            NSWorkspace.shared.open(fallbackURL)
        }
    }
    
    private func checkVPNConfigurationInstalled() {
        Task {
            await ExtensionStatusManager.shared.isVPNConfigurationInstalled()
        }
    }
    private func restartApp() {
        // Create a URL to our app
        if let bundleId = Bundle.main.bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            
            // Log that we're going to restart
            AppLog.shared.debug("[SessionContentView] Restarting app")
            
            // Create a configuration for the app to launch
            let config = NSWorkspace.OpenConfiguration()
            
            // First terminate the app with a slight delay
            Task {
                // Schedule app launch after a brief delay
                Task.detached {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                }
                
                // Then terminate the current instance
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                NSApp.terminate(nil)
            }
        } else {
            AppLog.shared.error("[SessionContentView] Failed to get app URL for restart")
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
                AppLog.shared.error("[SessionContentView] Error restarting: \(error)")
            }
        }
    }
    
    private func startVPN() {
        do {
            // Just toggle the VPN tunnel (extension is already installed)
            _ = try AppController.shared.toggleVPNTunnel()
        } catch {
            AppLog.shared.error("[SessionContentView] Error starting VPN: \(error.localizedDescription)")
        }
    }
    
    private func checkExtensionStatus() {
        Task {
            do {
                let status = try await ExtensionStatusManager.shared.checkCompleteStatus()
                
                // Update on main thread
                await MainActor.run {
                    appState.extensionStatus = status
                }
            } catch {
                AppLog.shared.error("[SessionContentView] Error checking extension status: \(error.localizedDescription)")
            }
        }
    }
}
