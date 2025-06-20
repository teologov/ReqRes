//
//  VPNToolbarControl.swift
//  ReqRes
//
//  Created by OloApps on 1/21/25.
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
import NetworkExtension
import XReqResCore

struct VPNToolbarControl: ToolbarContent {
    @ObservedObject private var appState = AppState.shared
    @State private var showingPermissionAlert = false
    @State private var showingRestartAlert = false
    @State private var showError = false
    @State private var errorMessage: String?
    // @State private var extensionStatus: ExtensionSetupStatus = .ready
    
    var body: some ToolbarContent {
        // Main VPN control button
        ToolbarItem {
            Button(action: handleVPNToggle) {
                HStack(spacing: 4) {
                    // Status icon with loading animation
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                        .contentTransition(.symbolEffect(.replace))
                    
                    // Optional: Add a small loading indicator
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .onAppear {
                // Check status when toolbar appears, but don't show alerts automatically
                // checkExtensionStatus(showAlerts: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: ExtensionStatusManager.extensionStatusChanged)) { notification in
                AppLog.shared.debug("[VPNToolbarControl] .extensionStatusChanged")
                
                // Get status from notification if available
                /*if let statusRawValue = notification.userInfo?["status"] as? String,
                   let status = ExtensionSetupStatus(rawValue: statusRawValue) {
                    self.extensionStatus = status
                } else if let _ = notification.userInfo?["isEnabled"] as? Bool {
                    // Fallback for backward compatibility
                    // Refresh full status asynchronously without showing alerts
                    checkExtensionStatus(showAlerts: false)
                }*/
            }
            .help(mainButtonText)
            .disabled(isButtonDisabled)
        }
        
        // Separate status indicator button (only shown when there's an issue)
        if appState.extensionStatus != .ready {
            ToolbarItem {
                Button(action: showAppropriateAlert) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
                .help(appState.extensionStatus.description)
                // Alert for system permissions
                .alert("Enable Network Extension", isPresented: $showingPermissionAlert) {
                    Button("Open System Settings") {
                        openSystemSettings()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    let instructions = [
                        "To use this feature:",
                        "",
                        "1. Go to System Settings → Privacy & Security →\nExtensions.",
                        "2. Scroll down to 'System Extensions'.",
                        "3. Find ReqRes.app in the list and\nenable it.",
                        "",
                        "Note: A Mac restart may be required\nafter enabling the extension for the first\ntime."
                    ].joined(separator: "\n")
                    
                    Text(instructions)
                        .multilineTextAlignment(.center)
                }
                // Alert for restart recommendation
                .alert("Restart Recommended", isPresented: $showingRestartAlert) {
                    Button("Restart Now") {
                        restartComputer()
                    }
                    Button("Later", role: .cancel) {}
                } message: {
                    Text("Your network extension is now configured, but a restart is required to fully activate it. Would you like to restart now?")
                        .multilineTextAlignment(.center)
                }
                // Alert for errors
                .alert("Error", isPresented: $showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "An unknown error occurred")
                }
            }
        }
    }
    
    // MARK: - Action Handlers
    
    private func handleVPNToggle() {
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
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to check extension status: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }
    
    private func showAppropriateAlert() {
        switch appState.extensionStatus {
        case .notInstalled:
            break
        case .extensionDisabled:
            showingPermissionAlert = true
        case .needsRestart:
            showingRestartAlert = true
        case .configurationMissing:
            errorMessage = "VPN configuration needs to be installed. Try clicking the start button to create it."
            showError = true
        case .ready:
            // No alert needed
            break
        }
    }
    
//    private func checkExtensionStatus(showAlerts: Bool = false) {
//        Task {
//            do {
//                let status = try await ExtensionStatusManager.shared.checkCompleteStatus()
//                
//                // Update on main thread
//                await MainActor.run {
//                    self.extensionStatus = status
//                    
//                    if showAlerts {
//                        showAppropriateAlert()
//                    }
//                }
//            } catch {
//                AppLog.shared.error("[VPNToolbarControl] Error checking extension status: \(error.localizedDescription)")
//            }
//        }
//    }
    
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
            // macOS 13 (Ventura) and earlier, not used really just to avoid the compiler error
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Extensions")
        }
        
        // Open the system settings
        if let url = url {
            NSWorkspace.shared.open(url)
            AppLog.shared.debug("[VPNToolbarControl] Opening system settings URL: \(url.absoluteString)")
        } else {
            // Fallback to the Security & Privacy pane if the URL fails
            let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
            NSWorkspace.shared.open(fallbackURL)
            AppLog.shared.debug("[VPNToolbarControl] Opening fallback system settings URL: \(fallbackURL.absoluteString)")
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
                AppLog.shared.error("[VPNToolbarControl] Error restarting: \(error)")
            }
        }
    }
    
    // MARK: - Helper Properties
    
    private var isLoading: Bool {
        switch appState.vpnStatus {
        case .connecting, .disconnecting, .reasserting:
            return true
        case .invalid, .disconnected, .connected:
            return false
        @unknown default:
            return false
        }
    }
    
    private var isButtonDisabled: Bool {
        // Only disable during loading states
        isLoading
    }
    
    private var statusIcon: String {
        switch appState.vpnStatus {
        case .invalid, .disconnected:
            return "play.fill"
        case .connecting:
            return "arrow.clockwise"
        case .connected:
            return "pause.fill"
        case .reasserting:
            return "arrow.triangle.2.circlepath"
        case .disconnecting:
            return "stop.fill"
        @unknown default:
            return "play.fill"
        }
    }
    
    private var statusColor: Color {
        switch appState.vpnStatus {
        case .invalid, .disconnected:
            return .secondary
        case .connecting:
            return .secondary
        case .connected:
            return .secondary
        case .reasserting:
            return .yellow
        case .disconnecting:
            return .gray
        @unknown default:
            return .secondary
        }
    }
    
    private var mainButtonText: String {
        switch appState.vpnStatus {
        case .invalid, .disconnected:
            return "Start monitoring"
        case .connecting:
            return "Connecting to VPN..."
        case .connected:
            return "Pause monitoring"
        case .reasserting:
            return "Reconnecting..."
        case .disconnecting:
            return "Stopping VPN..."
        @unknown default:
            return "Start monitoring"
        }
    }
}

// MARK: - Toolbar Integration
extension View {
    func vpnToolbarControl() -> some View {
        self.toolbar {
            VPNToolbarControl()
        }
    }
}
