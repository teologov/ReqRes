//
//  UIAppDelegate.swift
//  UI
//
//  Created by OloApps on 14.06.2023.
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

import Cocoa
import Sentry
import Utils
import SystemExtensions
import Combine
import XReqResCore

// TODO: add toolbar app with list of rules
// the popup design here looks inpiring: https://blog.eidinger.info/til-swiftui-list-on-macos

class AppDelegate: NSObject, NSApplicationDelegate {
    
    // private lazy var systemExtensionInfo = Bundle.main.systemExtensions.first
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        initSentry()
        // Insert code here to initialize your application
        do {
            let fileManager = FileManager.default
            if let certDir = MitmService.getCertPath() {
                // Cert
                let cacertPath = certDir.appendingPathComponent("cacert.pem", isDirectory: false)
                let cacertDerPath = certDir.appendingPathComponent("cacert.der", isDirectory: false)
                let cakeyPath = certDir.appendingPathComponent("cakey.pem", isDirectory: false)
                let rsakeyPath = certDir.appendingPathComponent("rsakey.pem", isDirectory: false)
    //            let cc = try? String(contentsOf: cacertPath)
                AppLog.shared.debug("Checking if cacert.pem exists at \(cacertPath.path, privacy: .public). Result: \(fileManager.fileExists(atPath: cacertPath.path), privacy: .public)")
                if !fileManager.fileExists(atPath: cacertPath.path) {
                    let fullCC = cc1 + cc2 + cc3
                    try fullCC.write(to: cacertPath, atomically: true, encoding: .utf8)
                    AppLog.shared.debug("Writing cacert.pem to \(cacertPath.path, privacy: .public)")
                }
                if !fileManager.fileExists(atPath: cacertDerPath.path) {
                    let derData = Data(base64Encoded: ccDerBase64)
                    try derData?.write(to: cacertDerPath, options: Data.WritingOptions.atomic)
                }
                if !fileManager.fileExists(atPath: cakeyPath.path) {
                    let fullck = ck1 + ck2 + ck3
                    try fullck.write(to: cakeyPath, atomically: true, encoding: .utf8)
                }
                if !fileManager.fileExists(atPath: rsakeyPath.path) {
                    let fullrk = rk1 + rk2 + rk3
                    try fullrk.write(to: rsakeyPath, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            AppLog.shared.error("Error writing certificates! \(error.localizedDescription, privacy: .public)")
        }
        
        applySavedAppearance() // Apply appearance on app launch
        // Force reset extension if app was updated via Sparkle
         Task {
            await forceResetExtensionAfterUpdate()
             
            // Continue with normal status check
            AppController.shared.checkNetworkExtensionStatus()
         }
    }
    
    // Main function to reset extension after updates
    func forceResetExtensionAfterUpdate() async {
        // Check if version changed (indicating a Sparkle update)
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let lastVersion = UserDefaults.standard.string(forKey: "LastRunVersion") ?? ""
    
        AppLog.shared.info("[UIAppDelegate] currentVersion: \(currentVersion, privacy: .public), lastVersion: \(lastVersion, privacy: .public)")
        // Skip if version hasn't changed
        guard currentVersion != lastVersion else {
            AppLog.shared.info("[UIAppDelegate] App is running the same version. Returning.")
            return
        }
        
        AppLog.shared.info("[UIAppDelegate] App updated from \(lastVersion, privacy: .public) to \(currentVersion), forcing extension reset")
        
        // handle use case when an older version of extension is stuck after the successfull
        // update of the app
        do {
            // Step 1: Deactivate the extension
            AppLog.shared.info("[UIAppDelegate] Deactivating extension \(extensionBundleId, privacy: .public)")
            // might be good to check the result.
            // however, it doesn't matter as of now, and even if user declined the popup,
            // system terminates the older version of the extension and installs the new one
            // so essentially, the log is next
            // ReqRes [UIAppDelegate] Extension deactivation failed: The operation couldn’t be completed
            // ReqRes [UIAppDelegate] Activating extension com.oloapps.ReqRes.vpn-tunnel
            // ReqRes [UIAppDelegate] Extension activation completed successfully
            // ReqRes [UIAppDelegate] Extension reset sequence completed successfully
            let deactivationResult = await withCheckedContinuation { continuation in
                OSSystemExtensionManager.shared.deactivateExtensionWithIdentifier(extensionBundleId)
                    .sink(
                        receiveCompletion: { completion in
                            switch completion {
                            case .finished:
                                AppLog.shared.info("[UIAppDelegate] Extension deactivation completed successfully")
                                continuation.resume(returning: true)
                            case .failure(let error):
                                // Log but continue even if deactivation fails
                                AppLog.shared.warning("[UIAppDelegate] Extension deactivation failed: \(error.localizedDescription, privacy: .public)")
                                continuation.resume(returning: false)
                            }
                        },
                        receiveValue: { _ in }
                    )
                    .store(in: &cancellables)
            }
            
            // Step 2: Wait to ensure deactivation completes
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            // Step 3: Activate the extension
            AppLog.shared.info("[UIAppDelegate] Activating extension \(extensionBundleId, privacy: .public)")
            
            try await withCheckedThrowingContinuation { continuation in
                OSSystemExtensionManager.shared.activateExtensionWithIdentifier(extensionBundleId, approval: { needsApproval in
                    if needsApproval {
                        AppLog.shared.info("[UIAppDelegate] Extension activation requires user approval")
                    }
                })
                .sink(
                    receiveCompletion: { completion in
                        switch completion {
                        case .finished:
                            AppLog.shared.info("[UIAppDelegate] Extension activation completed successfully")
                            continuation.resume()
                        case .failure(let error):
                            AppLog.shared.error("[UIAppDelegate] Extension activation failed: \(error.localizedDescription, privacy: .public)")
                            continuation.resume(throwing: error)
                        }
                    },
                    receiveValue: { _ in }
                )
                .store(in: &cancellables)
            }
            
            // Store current version to ensure we only try once per version
            UserDefaults.standard.set(currentVersion, forKey: "LastRunVersion")
            
            AppLog.shared.info("[UIAppDelegate] Extension reset sequence completed successfully")
        } catch {
            AppLog.shared.error("[UIAppDelegate] Error during extension reset: \(error.localizedDescription)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Check if the tunnel is running
        if isTunnelRunning() {
            // Show a modal or alert to notify the user
            showTunnelRunningAlert()
            return .terminateCancel // Prevent app from terminating
        }
        return .terminateNow // Allow app to terminate
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        stopVPNTunnelIfRunning()
        AppController.tcpServerBus.stop()
        AppLog.shared.debug("TCPServerBus: server stopped successfully.")
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
    
    func applySavedAppearance() {
        let savedAppearance = UserDefaults.standard.string(forKey: "selectedAppearance") ?? "System"
        if let mode = AppearanceMode(rawValue: savedAppearance) {
            applyAppearanceMode(mode)
        }
    }
    
    func applyAppearanceMode(_ mode: AppearanceMode) {
        switch mode {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil // Resets to the system's appearance
        }
    }
}

extension AppDelegate {
    func stopVPNTunnelIfRunning() {
        if isTunnelRunning() {
            VPNManager.shared.stopVPNTunnel()
        }
    }
    
    private func isTunnelRunning() -> Bool {
        return AppState.shared.vpnStatus == .connected
    }
    
    private func showTunnelRunningAlert() {
        let alert = NSAlert()
        alert.messageText = "ReqRes tunnel is running"
        alert.informativeText = "Are you sure you want to quit?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
           if response == .alertFirstButtonReturn {
               // Quit the app
               NSApp.terminate(nil)
        }
    }
    
    func initSentry() {
        SentrySDK.start { options in
            options.dsn = "https://\(EnvironmentVars.sentryDsn)"
            // Set 100% for now. Can be dropped to 0.1 (10%) in the future.
            options.tracesSampleRate = 1.0
        }
    }
}
