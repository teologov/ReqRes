//
//  VPNManager.swift
//  ReqRes
//
//  Created by OloApps on 20.05.2021.
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
import NetworkExtension
import XReqResCore
import Utils

extension NEVPNStatus: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .invalid: return "Invalid"
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .reasserting: return "Reconnecting"
        @unknown default:
            fatalError()
        }
    }
    public var titleForButton:String {
        switch self{
        case .disconnected:
            return "Connect"
        case .invalid:
            return "Invalid"
        case .connected:
            return "Disconnect"
        case .connecting:
            return "Connecting"
        case .disconnecting:
            return "Disconnecting"
        case .reasserting:
            return "Reasserting"
        @unknown default:
            fatalError()
        }
    }
}

class SFNETunnelProviderManager: NETunnelProviderManager {
    class func loadOrCreateDefaultWithCompletionHandler(_ completionHandler: ((NETunnelProviderManager?, Error?) -> Void)?) {
        self.loadAllFromPreferences { (managers, error) -> Void in
            if let error = error {
                AppLog.shared.error("Error: Could not load managers:  \(error.localizedDescription, privacy: .public)")
                if let completionHandler = completionHandler {
                    completionHandler(nil, error)
                }
                return
            }
            let bId = Bundle.main.infoDictionary!["CFBundleIdentifier"] as! String
            if let managers = managers {
                if managers.indices ~= 0 {
                    if let completionHandler = completionHandler {
                        var m:NETunnelProviderManager?
                        for mm in managers {
                            let _ = mm.protocolConfiguration as! NETunnelProviderProtocol
                        }
                        if m == nil {
                            m = managers[0]
                        }
                        AppLog.shared.debug("manager \(managers.count, privacy: .public) \(String(describing: m?.protocolConfiguration), privacy: .public)")
                        completionHandler(m, nil)
                    }
                    return
                }
            }
            
            var configInfo = [String:Any]()
            configInfo["App"] = bId
            configInfo["mtu"] = "1400"
            configInfo["dns"] = "8.8.8.8,8.4.4.4"
            
            let config = NETunnelProviderProtocol()
            config.providerConfiguration = configInfo
            // NOTE: This must match the bundle identifier of the app extension
            // containing packet tunnel provider.
            config.providerBundleIdentifier = extensionBundleId
            config.serverAddress = "reqres.local"
            
            let manager = SFNETunnelProviderManager()
            manager.protocolConfiguration = config
            manager.localizedDescription = "HTTP Packet Capture"
            
            manager.saveToPreferences(completionHandler: { (error) -> Void in
                if let completionHandler = completionHandler {
                    completionHandler(manager, error)
                }
            })
        }
    }
}

class VPNManager {
    static let shared:VPNManager = VPNManager()
    var manager: NETunnelProviderManager?
    var loading: Bool = false
    var session: String = ""
    var vpnmanager: NEVPNManager = NEVPNManager.shared()
    
    func loadManager(_ completionHandler: ((NETunnelProviderManager?, Error?) -> Void)?) {
        if let m = manager {
            if let handler = completionHandler {
                handler(m, nil)
            }
        } else {
            loading = true
            SFNETunnelProviderManager.loadOrCreateDefaultWithCompletionHandler { [weak self] (manager, error) -> Void in
                if let m = manager {
                    self!.manager = manager
                    if let handler = completionHandler{
                        self!.loading = false
                        handler(m, error)
                    }
                }
            }
        }
    }
    
    func enabledToggled(_ completion: @escaping ((_ error: Error?) throws -> Void)) {
        if let m = manager {
            m.isEnabled = true
            m.localizedDescription = "ReqRes HTTP(S) Packet Capture"
            m.saveToPreferences { error in
                do {
                    guard error == nil else {
                        AppLog.shared.error("[VPNManager] saveToPreferences error:\(error?.localizedDescription ?? "unknown", privacy: .public)")
                        try completion(error)
                        return
                    }
                    m.loadFromPreferences { error in
                        do {
                            guard error == nil else {
                                AppLog.shared.error("[VPNManager] loadFromPreferences error:\(error?.localizedDescription ?? "unknown", privacy: .public)")
                                try completion(error)
                                return
                            }
                            try completion(nil)
                        } catch {
                            NSLog(error.localizedDescription)
                        }
                    }
                } catch {
                    NSLog(error.localizedDescription)
                }
            }
        }
    }
    
    /// Handle the user toggling the "VPN" switch
    func startStopToggled() throws -> Bool {
        AppLog.shared.debug("[VPNManager] startStopToggled")
        guard let m = manager else { return false }
        
        if m.connection.status == .disconnected || m.connection.status == .invalid {
            enabledToggled { error in
                if let err = error {
                    AppLog.shared.error("[VPNManager] Failed to start the VPN: \(err.localizedDescription)")
                    AppState.shared.vpnStatus = .disconnected
                    return
                }
                
                do {
                    let options: [String: NSObject] = [
                        "isCACertificateInstalledInKeychain": NSNumber(value: CertHelper.getInstalledCertificate() != nil)
                    ]
                    try m.connection.startVPNTunnel(options: options)
                } catch {
                    AppLog.shared.error("\(error.localizedDescription)")
                    AppState.shared.vpnStatus = .disconnected
                }
            }
        } else {
            stopVPNTunnel()
        }
        return true
    }
    
    func stopVPNTunnel() {
        if let m = manager {
            AppLog.shared.debug("[VPNManager] stopping the tunnel")
            m.isEnabled = false
            m.connection.stopVPNTunnel()
        }
    }
}
