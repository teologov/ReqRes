//
//  AppController.swift
//  ReqRes
//
//  Created by OloApps on 15.06.2023.
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

import Foundation
import XReqResCore
@preconcurrency import NetworkExtension
import SystemExtensions
import os.log
import Combine
import Utils
import AppKit

class AppController: NSObject {
    static let tcpServerBus: TCPServerBus = TCPServerBus()
    let databaseManager: DatabaseManager = DatabaseManager(appGroupID: GROUPNAME)
    
    var appModel = AppState.shared
    fileprivate var isVpnRunningSubscription: AnyCancellable?
    
    static let shared = AppController()
    
    override init() {
        super.init()
        AppController.tcpServerBus.delegate = self
    }
    
    // Get the Bundle of the system extension.
    lazy var extensionBundle: Bundle = {

        let extensionsDirectoryURL = URL(fileURLWithPath: "Contents/Library/SystemExtensions", relativeTo: Bundle.main.bundleURL)
        let extensionURLs: [URL]
        do {
            extensionURLs = try FileManager.default.contentsOfDirectory(at: extensionsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        } catch let error {
            fatalError("Failed to get the contents of \(extensionsDirectoryURL.absoluteString): \(error.localizedDescription)")
        }

        guard let extensionURL = extensionURLs.first else {
            fatalError("Failed to find any system extensions")
        }

        guard let extensionBundle = Bundle(url: extensionURL) else {
            fatalError("Failed to create a bundle with URL \(extensionURL.absoluteString)")
        }

        return extensionBundle
    }()
    
    func booststrap(completion: @escaping () -> Void) {
        do {
            try AppController.tcpServerBus.start(port: MessageBusPort)
        } catch {
            AppLog.shared.error("Failed to start the TCPServerBus. Check if \(MessageBusPort) is available.")
        }
        
        databaseManager.initializeDatabase()
        
        // submitActivationNetworkExtensionRequest()
        bindSubscriptions()
        bindListeners()
        
        completion()
    }
    
    deinit {}
}

// MARK: Network extension piece

extension AppController {
    // NOTE: not used
    public func submitActivationNetworkExtensionRequest() {
        guard let extensionIdentifier = extensionBundle.bundleIdentifier else {
            appModel.vpnStatus = .disconnected
            
            AppLog.shared.critical("Extension bundle identifier not found")
            return
        }

        // Start by activating the system extension
        let activationRequest = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        activationRequest.delegate = self
        OSSystemExtensionManager.shared.submitRequest(activationRequest)
    }
    
}

extension AppController: OSSystemExtensionRequestDelegate {

    // MARK: OSSystemExtensionActivationRequestDelegate

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {

        AppLog.shared.debug("Request completed with result: \(result.rawValue, privacy: .public)")
        
        guard result == .completed else {
            AppLog.shared.warning("Unexpected result for system extension request: \(result.rawValue, privacy: .public)")
            appModel.vpnStatus = .disconnected
            return
        }

        // initTunnel()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        AppLog.shared.critical("System extension request failed: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let welf = self else {
                return
            }
            // Ensure we're on main thread when updating UI state
            welf.appModel.vpnStatus = .disconnected
            // Optionally post a notification for the error
            NotificationCenter.default.post(name: .needsSystemPermission, object: error)
        }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        AppLog.shared.info("Extension \(request.identifier, privacy: .public) requires user approval")
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension extension: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {

        AppLog.shared.info("Replacing extension \(request.identifier, privacy: .public) version \(existing.bundleShortVersion, privacy: .public) with version \(`extension`.bundleShortVersion, privacy: .public)")
        return .replace
    }
}

// MARK: Tunnel state control (connect/disconnect)

extension AppController {
    func toggleVPNTunnel() {
        Task {
            do {
                // Get complete status instead of just enabled check
                let status = try await ExtensionStatusManager.shared.checkCompleteStatus()
                
                switch status {
                case .notInstalled:
                    // Extension not enabled - request activation but don't show permission alert
                    AppLog.shared.critical("Network Extension is not installed")
                    // Request extension activation silently
                    await ExtensionStatusManager.shared.requestSystemExtensionIfNeeded()
                    return
                case .extensionDisabled:
                    // Extension not enabled - request activation but don't show permission alert
                    AppLog.shared.critical("Network Extension is not properly enabled")
                    
                    // Request extension activation silently
                    await ExtensionStatusManager.shared.requestSystemExtensionIfNeeded()
                    
                    // Update status but don't show alerts
                    // The separate indicator button will show the status
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: ExtensionStatusManager.extensionStatusChanged,
                            object: nil,
                            userInfo: [
                                "isEnabled": false,
                                "status": ExtensionSetupStatus.extensionDisabled.rawValue
                            ]
                        )
                    }
                    return
                    
                case .configurationMissing:
                    // Extension enabled but config not installed
                    // We'll continue and let the VPN manager create it
                    AppLog.shared.debug("Network Extension enabled but VPN configuration missing - will create")
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: ExtensionStatusManager.extensionStatusChanged,
                            object: nil,
                            userInfo: [
                                "isEnabled": false,
                                "status": ExtensionSetupStatus.configurationMissing.rawValue
                            ]
                        )
                    }
                    return
                    
                case .needsRestart:
                    // Configuration complete but system restart needed
                    AppLog.shared.critical("System restart required to activate network extension")
                    
                    // Update status but don't show alerts
                    // The separate indicator button will show the status
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: ExtensionStatusManager.extensionStatusChanged,
                            object: nil,
                            userInfo: [
                                "isEnabled": true,
                                "status": ExtensionSetupStatus.needsRestart.rawValue
                            ]
                        )
                    }
                    return
                    
                case .ready:
                    // Everything is ready, proceed with VPN toggle
                    AppLog.shared.debug("Network Extension is properly enabled and configured")
                }
                
                // Rest of your existing VPN startup logic...
                if !AppController.tcpServerBus.isServerListening() {
                    do {
                        try AppController.tcpServerBus.start(port: MessageBusPort)
                    } catch {
                        AppLog.shared.critical("Failed to start TCP server: \(error.localizedDescription)")
                        
                        await MainActor.run {
                            self.appModel.vpnStatus = .disconnected
                        }
                        return
                    }
                }
                
                // Continue with VPN setup...
                // Now that we confirmed extension is enabled and TCP server is running,
                // proceed with VPN startup
                VPNManager.shared.loadManager({ [weak self] (manager, error) in
                    guard let self = self else { return }
                    
                    DispatchQueue.main.async {
                        if let error = error {
                            AppLog.shared.critical("VPNManager.shared.loadManager error: \(error.localizedDescription, privacy: .public)")
                            self.appModel.vpnStatus = .disconnected
                            return
                        }
                        
                        guard let manager = manager else {
                            AppLog.shared.critical("No VPN manager available")
                            self.appModel.vpnStatus = .disconnected
                            return
                        }
                        
                        // Now that we have a valid manager, try to start the tunnel
                        do {
                            let options: [String: NSObject] = [
                                "isCACertificateInstalledInKeychain": NSNumber(value: CertHelper.getInstalledCertificate() != nil)
                            ]
                            AppLog.shared.debug("Found manager with the connection status: \(manager.connection.status, privacy: .public)")
                            
                            if manager.connection.status == .disconnected || manager.connection.status == .invalid {
                                // If this is the first time installing/enabling, mark it
                                if !AppPreferences.shared.isFirstVPNConfigInstalled {
                                    AppPreferences.shared.isFirstVPNConfigInstalled = true
                                }
                                
                                self.appModel.vpnStatus = .connecting
                                try manager.connection.startVPNTunnel(options: options)
                            } else {
                                manager.connection.stopVPNTunnel()
                            }
                        } catch {
                            AppLog.shared.critical("Failed to start/stop VPN tunnel: \(error.localizedDescription, privacy: .public)")
                            self.appModel.vpnStatus = .disconnected
                        }
                    }
                })
            } catch {
                AppLog.shared.critical("Failed to check extension status: \(error.localizedDescription)")
                
                // Update status but don't show alerts directly
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: ExtensionStatusManager.extensionStatusChanged,
                        object: nil,
                        userInfo: [
                            "isEnabled": false,
                            "status": ExtensionSetupStatus.extensionDisabled.rawValue
                        ]
                    )
                }
            }
        }
    }
    
    func checkNetworkExtensionStatus() {
        AppLog.shared.debug("[AppController] Checking network extension status")
        
        Task {
            do {
                let status = try await ExtensionStatusManager.shared.checkCompleteStatus()
                
                await MainActor.run {
                    switch status {
                    case .notInstalled:
                        appModel.vpnStatus = .disconnected
                    case .extensionDisabled:
                        // Extension is not enabled, update app state
                        // But don't show alerts automatically
                        appModel.vpnStatus = .disconnected // Keep this .disconnected instead of .invalid to ensure button is clickable
                        
                    case .configurationMissing:
                        // Extension is enabled but config not installed
                        appModel.vpnStatus = .disconnected
                        
                    case .ready:
                        // Everything is ready
                        appModel.vpnStatus = .disconnected
                        
                    case .needsRestart:
//                        // Configuration complete but restart needed
//                        // But don't show alerts automatically
                        appModel.vpnStatus = .disconnected // Keep this .disconnected instead of .invalid
                    }
                    
                    appModel.extensionStatus = status
                    // Post notification to update toolbar status indicator
                    // but without triggering automatic alerts
                    NotificationCenter.default.post(
                        name: ExtensionStatusManager.extensionStatusChanged,
                        object: nil,
                        userInfo: [
                            "isEnabled": status != .extensionDisabled,
                            "status": status.rawValue
                        ]
                    )
                }
            } catch {
                AppLog.shared.error("[AppController] Error checking network extension status: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: Subscriptions
extension AppController {
    fileprivate func bindSubscriptions() {
        isVpnRunningSubscription = NotificationCenter.Publisher(center: .default, name: .toolbarControlVpnClicked, object: nil)
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] _ in
                self?.toggleVPNTunnel()
            })
    }
    
    fileprivate func bindListeners() {
        NotificationCenter.default.addObserver(self, selector: #selector(vpnDidChange(noti:)), name: NSNotification.Name.NEVPNStatusDidChange, object: nil)
    }
}

// MARK: Observer Handlers
extension AppController {
    @objc func vpnDidChange(noti: Notification) -> Void {
       guard let tunnelPS = noti.object as? NETunnelProviderSession else {
           AppLog.shared.error("Not the NETunnelProviderSession!")
           return
       }
       
       let newStatus = tunnelPS.status
       AppLog.shared.debug("[AppController] VPN status changed to: \(newStatus.description)")
       
       // Update the app state
       appModel.vpnStatus = newStatus
       
       // Check for extension status but don't show alerts automatically
       if newStatus == .invalid {
           checkInvalidVPNStatusQuietly()
       }
   }
    
    private func checkInvalidVPNStatusQuietly() {
        // This function silently checks extension status without showing alerts
        Task {
            do {
                let fullStatus = try await ExtensionStatusManager.shared.checkCompleteStatus()
                
                // Just log the status, don't show alerts
                AppLog.shared.debug("[AppController] Extension status after invalid VPN status: \(fullStatus.rawValue)")
                
                // Post notification that will update the toolbar status indicator
                // but won't show alerts automatically
                NotificationCenter.default.post(
                    name: ExtensionStatusManager.extensionStatusChanged,
                    object: nil,
                    userInfo: [
                        "isEnabled": fullStatus != .extensionDisabled,
                        "status": fullStatus.rawValue
                    ]
                )
            } catch {
                AppLog.shared.error("[AppController] Error checking status after invalid: \(error.localizedDescription)")
            }
        }
    }
}


// MARK: sender of message to the vpn tunnel

extension AppController {
    func notifyExtension<T>(message: ServerBusMessage<T>) {
        AppController.tcpServerBus.sendMessageToClient(message)
    }
}

extension AppController: TCPServerBusDelegate {
    func tcpServerBus(_ server: TCPServerBus, didReceiveMessage message: ClientBusMessageNonGeneric, data: Data) {
        AppLog.shared.info("[TCPServerBus] received a message from TCPClientBus: \(message.action.rawValue, privacy: .public). Payload: \(message.payload, privacy: .public)")

        switch message.action {
        case .sendSession:
            if let anyCodableDict = message.payload["data"]?.value as? [String: Any] {
                if let jsonData = try? JSONSerialization.data(withJSONObject: anyCodableDict, options: []) {
                    // Decode the data into SessionCodable
                    let jsonDecoder = JSONDecoder()
                    if let session = try? jsonDecoder.decode(SessionCodable.self, from: jsonData) {
                        SessionState.shared.addSession(session: session)
                    } else {
                        AppLog.shared.error("[TCPServerBus] Failed to decode SessionCodable with JSON data: \(jsonData, privacy: .public)")
                    }
                } else {
                    AppLog.shared.error("[TCPServerBus] failed to serialize to JSON data")
                }
            }
        // use ping to update all required data for network extension
//        case .ping:
//            if let selectedHost = AppState.shared.selectedHost {
//                self.notifyExtension(
//                    message: ServerBusMessage(
//                        action: .selectedHostChanged,
//                        payload: [
//                            "data": HostCodable(
//                                host: selectedHost.host,
//                                port: selectedHost.port as NSNumber,
//                                hostDbId: (selectedHost.id ?? 0) as NSNumber,
//                                requestProtocol: selectedHost.protocol
//                            )
//                        ]
//                    )
//                )
//            }
//            let rules: [HostRuleModel] = HostRuleModel.findAll()
//            self.notifyExtensionRulesChanged(rules: rules)
//            let allHosts: [HostModel] = HostModel.findAll()
//            self.notifyExtension(message: ServerBusMessage(
//                action: .allHostsChanged,
//                payload: [
//                    "data": allHosts.map {
//                        HostCodable(host: $0.host, port: $0.port as NSNumber, hostDbId: ($0.id ?? 0) as NSNumber, requestProtocol: $0.protocol)
//                    }
//                ]
//            ))
        case .statusUpdate:
            // Use bridge API to get selected host data
            Task {
                do {
                    if let selectedHost = AppState.shared.selectedHost {
                        self.notifyExtension(
                            message: ServerBusMessage(
                                action: .selectedHostChanged,
                                payload: ["data": selectedHost]
                            )
                        )
                    }
                    
                    // Use bridge API to get all hosts
                    let allHosts = try await ReqResCoreModelBridge.findAllHosts()
                    self.notifyExtension(message: ServerBusMessage(
                        action: .allHostsChanged,
                        payload: ["data": allHosts]
                    ))
                    
                    // Use bridge API to get all rules
                    let rules = try await ReqResCoreModelBridge.findAllRules()
                    await self.notifyExtensionRulesChanged(rules: rules)
                } catch {
                    AppLog.shared.error("[AppController] Error in statusUpdate: \(error.localizedDescription)")
                }
            }
        default:
            break
        }
    }
}

extension AppController {
    func notifyExtensionRulesChanged(rules: [RuleCodable]) async { // Changed parameter type and made async
        AppLog.shared.debug("[AppController] Preparing rules changed notification with \(rules.count) rules")
        
        // Process rules to add map local data
        var processedRules: [RuleCodable] = []
        
        for rule in rules {
            var ruleCodable = rule // Start with the existing RuleCodable
            
            // Handle map local data
            if rule.ruleMode == .MAP_LOCAL {
                AppLog.shared.debug("[AppController] Processing map local rule for path: \(rule.path, privacy: .public)")
                
                if rule.rspPath.isEmpty {
                    AppLog.shared.error("[AppController] Map local rule has empty rspPath")
                    processedRules.append(ruleCodable)
                    continue
                }
                
                let fileURLString = "file://" + rule.rspPath
                guard let fileURL = URL(string: fileURLString) else {
                    AppLog.shared.error("[AppController] Invalid file URL: \(fileURLString, privacy: .public)")
                    processedRules.append(ruleCodable)
                    continue
                }
                
                do {
                    let fileData = try Data(contentsOf: fileURL)
                    AppLog.shared.debug("[AppController] Read map local file data: \(fileData.count) bytes")
                    
                    let mapLocalFile = MapLocalFileCodable(
                        path: rule.path,
                        fileData: fileData,
                        mimeType: MapLocalConfig.mimeType(for: fileURL),
                        hostId: rule.hostId
                    )
                    
                    do {
                        let mapLocalData = try JSONEncoder().encode(mapLocalFile)
                        AppLog.shared.debug("[AppController] Encoded mapLocalFile: \(mapLocalData.count) bytes")
                        
                        if let mapLocalDict = try JSONSerialization.jsonObject(with: mapLocalData, options: []) as? [String: Any] {
                            // Create new RuleCodable with map local data (assuming RuleCodable has mapLocalData property)
                            // TODO: We may need to add mapLocalData property to RuleCodable or handle this differently
                            ruleCodable.mapLocalData = AnyCodable(mapLocalDict)
                            AppLog.shared.debug("[AppController] Successfully added map local data to rule")
                        } else {
                            AppLog.shared.error("[AppController] Failed to convert encoded map local data to dictionary")
                        }
                    } catch {
                        AppLog.shared.error("[AppController] Failed to encode map local file: \(error.localizedDescription, privacy: .public)")
                    }
                } catch {
                    AppLog.shared.error("[AppController] Failed to read map local file: \(error.localizedDescription, privacy: .public)")
                }
            }
            
            processedRules.append(ruleCodable)
        }
        
        AppLog.shared.debug("[AppController] Sending \(processedRules.count) rules to extension")
        
        self.notifyExtension(message: ServerBusMessage(
            action: .rulesChanged,
            payload: ["data": processedRules]
        ))
    }
}

class ExtensionStatusManager: NSObject {
    private(set) static var shared = ExtensionStatusManager()
    private var propertiesDelegate: ExtensionDelegate?
    private var activationDelegate: ActivationDelegate?
    static let extensionStatusChanged = Notification.Name("extensionStatusChanged")
    
    // Track VPN configuration status
    private var vpnConfigurationStatus: Bool = false
    
    override init() {
        super.init()
        setupStatusCheck()
    }
    
    private func setupStatusCheck() {
        // Check status periodically when app is active
        NotificationCenter.default.addObserver(self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func applicationDidBecomeActive() {
        Task {
            AppLog.shared.debug("ExtensionStatusManager.checkAndNotifyStatus()")
            // Check status when app becomes active
            await checkAndNotifyStatus()
        }
    }
    
    private func checkAndNotifyStatus() async {
        do {
            let status = try await checkCompleteStatus()
            AppLog.shared.debug("ExtensionStatusManager.checkAndNotifyStatus status: \(status.rawValue, privacy: .public)")
            DispatchQueue.main.async {
                AppState.shared.extensionStatus = status
                // Post combined notification with full status
                AppLog.shared.debug("ExtensionStatusManager.checkAndNotifyStatus notify the status")
                NotificationCenter.default.post(
                    name: Self.extensionStatusChanged,
                    object: nil,
                    userInfo: [
                        "isEnabled": status != .extensionDisabled,
                        "status": status.rawValue
                    ]
                )
            }
        } catch {
            AppLog.shared.error("Failed to check extension status: \(error.localizedDescription)")
        }
    }
    
    func checkStatus() async throws -> (Bool, Bool) {
        let properties = try await getExtensionProperties()
        
        // Sort by version number to get the latest one
        let latestProperty = properties
            .sorted { Int($0.bundleVersion) ?? 0 > Int($1.bundleVersion) ?? 0 }
            .first
        
        AppLog.shared.debug("Using latest version: \(latestProperty?.bundleVersion ?? "none", privacy: .public)")
        if latestProperty == nil {
            // installed - false
            // enabled - false
            return (false, false)
        }
        // installed - true
        return (true, latestProperty?.isEnabled ?? false)
    }
    
    // Check if the VPN configuration is installed
    public func isVPNConfigurationInstalled() async -> Bool {
        return await withCheckedContinuation { continuation in
            VPNManager.shared.loadManager { manager, error in
                if let error = error {
                    AppLog.shared.error("[ExtensionStatusManager] Error loading VPN manager: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: false)
                    return
                }
                
                guard let manager = manager else {
                    continuation.resume(returning: false)
                    return
                }
                AppLog.shared.debug("[ExtensionStatusManager] VPN manager: \(manager, privacy: .public)")
                // Check if configuration exists and is valid
                let isConfigured = manager.protocolConfiguration != nil
                AppLog.shared.debug("[ExtensionStatusManager] VPN configuration installed: \(isConfigured, privacy: .public)")
                self.vpnConfigurationStatus = isConfigured
                continuation.resume(returning: isConfigured)
            }
        }
    }
    
    // Check complete status
    func checkCompleteStatus() async throws -> ExtensionSetupStatus {
        AppLog.shared.debug("[ExtensionStatusManager.checkCompleteStatus] request")
        // Check extension status
        let (isInstalled, isExtensionEnabled) = try await checkStatus()
        
        if !isInstalled {
            return .notInstalled
        }
        if !isExtensionEnabled {
            AppLog.shared.debug("[ExtensionStatusManager.checkCompleteStatus] extensionDisabled")
            return .extensionDisabled
        }
        
        // Check VPN configuration
        let isConfigInstalled = await isVPNConfigurationInstalled()

        AppLog.shared.debug("[ExtensionStatusManager.checkCompleteStatus] isConfigInstalled: \(isConfigInstalled, privacy: .public)")
        
        if !isConfigInstalled {
            return .configurationMissing
        }
        
        AppLog.shared.debug("[ExtensionStatusManager.checkCompleteStatus] isReady")
        // All good
        return .ready
    }
    
    private func getExtensionProperties() async throws -> [OSSystemExtensionProperties] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = OSSystemExtensionRequest.propertiesRequest(
                forExtensionWithIdentifier: extensionBundleId,
                queue: .main
            )
            
            AppLog.shared.debug("Creating request...")
            propertiesDelegate = ExtensionDelegate(continuation)
            request.delegate = propertiesDelegate
            
            AppLog.shared.debug("Submitting request...")
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }
    
    // Request system extension installation if needed
    func requestSystemExtensionIfNeeded() async {
        // First check if extension is already enabled
        do {
            let (_, isEnabled) = try await checkStatus()
            if isEnabled {
                AppLog.shared.debug("[ExtensionStatusManager] Extension already enabled")
                return
            }
            
            // Extension not enabled, request activation
            _ = await withCheckedContinuation { continuation in
                let extensionRequest = OSSystemExtensionRequest.activationRequest(
                    forExtensionWithIdentifier: extensionBundleId,
                    queue: .main
                )
                
                // Use a separate activation delegate
                self.activationDelegate = ActivationDelegate {
                    continuation.resume(returning: ())
                }
                extensionRequest.delegate = self.activationDelegate
                
                AppLog.shared.debug("[ExtensionStatusManager] Requesting extension activation")
                OSSystemExtensionManager.shared.submitRequest(extensionRequest)
            }
            
        } catch {
            AppLog.shared.error("[ExtensionStatusManager] Error checking extension status: \(error.localizedDescription)")
        }
    }
}

// Status enum representing the complete setup state
enum ExtensionSetupStatus: String {
    // TODO: rename to extensionActivated
    case extensionDisabled    // System extension not enabled
    case configurationMissing // Extension enabled but VPN config not set up
    case ready                // Everything is ready to use
    case needsRestart         // Configuration complete but system restart required
    case notInstalled         // Not installed at all
    
    var description: String {
        switch self {
        case .extensionDisabled:
            return "Network Extension needs to be enabled in System Settings"
        case .configurationMissing:
            return "VPN configuration needs to be installed"
        case .ready:
            return "Network monitoring is ready to use"
        case .needsRestart:
            return "System restart required to activate network extension"
        case .notInstalled:
            return "Network Extension needs to be installed"
        }
    }
}

// Delegate for activation requests
private class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
    let completionHandler: () -> Void
    
    init(_ completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
        super.init()
    }
    
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        AppLog.shared.debug("[ActivationDelegate] Request for replacing extension received")
        return .replace
    }
    
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        AppLog.shared.debug("[ActivationDelegate] Request needs user approval")
        // User will be shown system dialog, but we won't get completion yet
    }
    
    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        AppLog.shared.debug("[ActivationDelegate] Request finished with result: \(result.rawValue, privacy: .public)")
        
        switch result {
        case .completed:
            AppLog.shared.debug("[ActivationDelegate] Extension activated successfully")
            
        case .willCompleteAfterReboot:
            AppLog.shared.debug("[ActivationDelegate] Extension will be activated after reboot")
            // Show restart prompt
            DispatchQueue.main.async {
                self.handleWillCompleteAfterReboot()
            }
            
        @unknown default:
            AppLog.shared.debug("[ActivationDelegate] Unknown result: \(result.rawValue)")
        }
        
        completionHandler()
    }
    
    func request(_ request: OSSystemExtensionRequest,
                 didFailWithError error: Error) {
        AppLog.shared.debug("[ActivationDelegate] Request failed with error: \(error.localizedDescription, privacy: .public)")
        
        // Check if error is user cancellation
        // Correctly check for user cancellation error
        let nsError = error as NSError
        if nsError.domain == OSSystemExtensionErrorDomain {
            // Check for user cancellation - code 1 is the user canceled error
            if nsError.code == 1 {
                AppLog.shared.debug("[ActivationDelegate] User canceled extension activation")
            } else {
                // Show error alert for other extension errors
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Extension Activation Error"
                    alert.informativeText = "Failed to activate the network extension: \(error.localizedDescription)"
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
        
        completionHandler()
    }
}

extension ActivationDelegate {
    func handleWillCompleteAfterReboot() {
        AppLog.shared.debug("[ActivationDelegate] Extension will be activated after reboot")
               
        // Reset the preference flag to ensure we can show the alert
        AppPreferences.shared.hasShownRestartPrompt = false
       
        // There are two options here:
       
        // Step 1: Use the RestartAlertController for a standalone alert
        // This will show a separate window alert immediately, regardless of user action
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            RestartAlertController.shared.showRestartAlert()
        }
       
        // Step 2: Update UI status and let user click the warning icon too
        DispatchQueue.main.async {
            // Post notification to update the toolbar status to show warning icon
            NotificationCenter.default.post(
                name: ExtensionStatusManager.extensionStatusChanged,
                object: nil,
                userInfo: [
                    "status": ExtensionSetupStatus.needsRestart.rawValue,
                    "isEnabled": true
                ]
        )
     }
    }
}

private class ExtensionDelegate: NSObject, OSSystemExtensionRequestDelegate {
    let continuation: CheckedContinuation<[OSSystemExtensionProperties], Error>
    private var hasCompleted = false  // Track completion state
    private let lock = NSLock()       // Thread safety
    
    init(_ continuation: CheckedContinuation<[OSSystemExtensionProperties], Error>) {
        self.continuation = continuation
        super.init()
    }
    
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        AppLog.shared.debug("Request for replacing extension received")
        return .replace
    }
    
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        AppLog.shared.debug("Request needs user approval")
        continuation.resume(throwing: NSError(domain: "ExtensionStatusManager",
                                           code: -1,
                                           userInfo: [NSLocalizedDescriptionKey: "Extension needs user approval"]))
    }
    
    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        AppLog.shared.debug("Request finished with result: \(result.rawValue, privacy: .public)")
    }
    
    func request(_ request: OSSystemExtensionRequest,
                 didFailWithError error: Error) {
        AppLog.shared.debug("Request failed with error: \(error.localizedDescription, privacy: .public)")
        continuation.resume(throwing: error)
    }
    
    func request(_ request: OSSystemExtensionRequest,
                 foundProperties properties: [OSSystemExtensionProperties]) {
        let propertiesLog = properties.map { prop in
            """
            Bundle ID: \(prop.bundleIdentifier)
            Version: \(prop.bundleVersion)
            Short Version: \(prop.bundleShortVersion)
            Is Enabled: \(prop.isEnabled)
            """
        }.joined(separator: "\n")
        
        AppLog.shared.debug("Found properties: Count: \(properties.count, privacy: .public) Properties: \(propertiesLog, privacy: .public)")
        
        safelyResume(returning: properties)
    }
    
    private func safelyResume(returning properties: [OSSystemExtensionProperties]? = nil, throwing error: Error? = nil) {
            lock.lock()
            defer { lock.unlock() }
            
            guard !hasCompleted else {
                AppLog.shared.debug("Ignoring attempt to resume continuation multiple times")
                return
            }
            
            hasCompleted = true
            
            if let error = error {
                continuation.resume(throwing: error)
            } else if let properties = properties {
                continuation.resume(returning: properties)
            }
        }
}

private class Delegate: NSObject {
    let continuation: CheckedContinuation<[OSSystemExtensionProperties], Never>

    init(_ continuation: CheckedContinuation<[OSSystemExtensionProperties], Never>) {
        self.continuation = continuation
    }
}

extension Delegate: OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        return .cancel
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {}

    func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: any Error
    ) {}

    func request(
        _ request: OSSystemExtensionRequest,
        foundProperties extensions: [OSSystemExtensionProperties]
    ) {
        self.continuation.resume(returning: extensions)
    }
}
