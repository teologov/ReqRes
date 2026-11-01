//
//  VPNManager.swift
//  ReqRes
//
//  Created by OloApps on 20.05.2021.
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

/// Utils' mirror of NEVPNStatus (`CaptureTunnelState`, same raw values), both
/// ways — the decisions about capture are made there, where `swift test`
/// reaches them.
extension CaptureTunnelState {
    /// A status a later SDK adds reads as `.invalid`, which is shown as
    /// disconnected.
    init(_ status: NEVPNStatus) {
        self = CaptureTunnelState(rawValue: status.rawValue) ?? .invalid
    }
}

extension NEVPNStatus {
    init(_ state: CaptureTunnelState) {
        self = NEVPNStatus(rawValue: state.rawValue) ?? .invalid
    }
}

class SFNETunnelProviderManager: NETunnelProviderManager {
    /// ReqRes's capture configuration, unsaved. Saving it is what makes macOS
    /// ask the user to allow a VPN configuration.
    class func makeDefault() -> SFNETunnelProviderManager {
        let bId = Bundle.main.infoDictionary!["CFBundleIdentifier"] as! String
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
        return manager
    }
}

class VPNManager {
    static let shared:VPNManager = VPNManager()
    var session: String = ""
    var vpnmanager: NEVPNManager = NEVPNManager.shared()

    /// The capture configuration, once loaded — ONE object for every caller,
    /// so the status every surface reads is one connection's. Read from any
    /// thread (the status checks run off main).
    var manager: NETunnelProviderManager? {
        managerLock.lock(); defer { managerLock.unlock() }
        return _manager
    }
    private var _manager: NETunnelProviderManager?
    private let managerLock = NSLock()

    /// Reading the saved configurations is a local read that answers in
    /// milliseconds; this only bounds a system that never answers.
    static let loadTimeout: TimeInterval = 10
    /// Creating one waits on a PERSON — macOS asks whether ReqRes may add a
    /// VPN configuration — so it gets far longer. The save still lands if the
    /// answer comes later, and the next load finds it.
    static let createTimeout: TimeInterval = 120

    /// Coalesced (F11): the status checks that overlap at launch — the launch
    /// check, the traffic pane's, the readiness poll, a click — share one
    /// read, and two clicks finding no configuration save one, not two.
    private let savedLoad = CoalescedLoad<[NETunnelProviderManager]>(timeout: VPNManager.loadTimeout)
    private let creation = CoalescedLoad<NETunnelProviderManager>(timeout: VPNManager.createTimeout)

    /// The capture configuration, creating it when there is none (macOS asks
    /// the user). ALWAYS calls back — with the manager, or with nil and the
    /// error. It used to call back only on success, so a failed load left its
    /// caller waiting forever: the status check behind every Start click, and
    /// the continuation of the one that decides whether setup is complete.
    ///
    /// For a CLICK only — a start, or the setup checklist's Install VPN
    /// Configuration. A refused save is not cached, so anything that called
    /// this on a schedule would put the prompt up again after every Don't
    /// Allow; the status checks read with `loadExistingManager` (F11 review).
    func loadManager(_ completionHandler: ((NETunnelProviderManager?, Error?) -> Void)?) {
        if let m = manager {
            completionHandler?(m, nil)
            return
        }
        loadSavedManagers { result in
            switch result {
            case .failure(let error):
                AppLog.shared.error("[VPNManager] could not load the capture configuration: \(error.localizedDescription, privacy: .public)")
                completionHandler?(nil, error)
            case .success(let managers):
                if let found = self.adopt(managers.first) {
                    completionHandler?(found, nil)
                    return
                }
                self.createManager { result in
                    switch result {
                    case .success(let created):
                        completionHandler?(self.adopt(created), nil)
                    case .failure(let error):
                        // Not cached: a configuration macOS refused to save
                        // is not one a later start can use (it used to be
                        // handed back as if it were).
                        AppLog.shared.error("[VPNManager] could not save the capture configuration: \(error.localizedDescription, privacy: .public)")
                        completionHandler?(nil, error)
                    }
                }
            }
        }
    }

    /// The saved capture configuration, or nil when there is none. NEVER
    /// creates one: the launch check and every status check only ask whether
    /// it exists or runs (F11), and creating a configuration puts macOS's
    /// "add VPN configuration" prompt in front of someone who has not asked
    /// to capture.
    func loadExistingManager(_ completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        if let m = manager {
            completion(m, nil)
            return
        }
        loadSavedManagers { result in
            switch result {
            case .success(let managers):
                completion(self.adopt(managers.first), nil)
            case .failure(let error):
                completion(nil, error)
            }
        }
    }

    private func loadSavedManagers(_ completion: @escaping CoalescedLoad<[NETunnelProviderManager]>.Completion) {
        savedLoad.load(completion) { finish in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(managers ?? []))
                }
            }
        }
    }

    private func createManager(_ completion: @escaping CoalescedLoad<NETunnelProviderManager>.Completion) {
        creation.load(completion) { finish in
            let manager = SFNETunnelProviderManager.makeDefault()
            manager.saveToPreferences { error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(manager))
                }
            }
        }
    }

    /// Keeps `found` unless another load got there first — that one stands.
    private func adopt(_ found: NETunnelProviderManager?) -> NETunnelProviderManager? {
        managerLock.lock(); defer { managerLock.unlock() }
        if _manager == nil { _manager = found }
        return _manager
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
    
    /// EVERY start of the tunnel passes these — the capture button
    /// (`AppController.toggleVPNTunnel`) and this manager's own toggle alike.
    /// Two call sites used to build their own dictionaries, and only one of
    /// them carried the crash-reporting consent, so an opt-out never reached
    /// the extension when capture started from the other (C8 review).
    ///
    /// Everything crosses in the start options because the extension runs as
    /// ROOT: it reads root's app-group defaults and root's group container,
    /// not the user's. Consent was first written to the app group and never
    /// arrived; the CA was first written to files and would never have
    /// arrived either.
    /// - the CA flag and the install's CA material
    ///   (`CertificateAuthority.tunnelStartOptions()`, step C8);
    /// - crash-reporting consent, read by `initSentry()` inside `startTunnel`;
    /// - the HTTP/2 capture switch (`HTTP2CaptureSetting`, off by default —
    ///   decision D11, doc §S9), read by the core's `HTTP2Capture` at start.
    ///   A running extension also hears changes over the bus
    ///   (`HTTP2CaptureSync`), so this only has to be right at each start.
    static func tunnelStartOptions() -> [String: NSObject] {
        var options: [String: NSObject] = CertificateAuthority.tunnelStartOptions()
        options[TelemetryConsent.startOptionKey] = NSNumber(value: TelemetryConsent.groupDefaults(appGroupID: AppGroup.identifier)
            .map { TelemetryConsent.isEnabled(in: $0) } ?? true)
        // The proxy's port (Settings ▸ Capture): the extension binds it and
        // points the system proxy at it. Recorded as the running capture's.
        let port = CaptureProxyPort.configured
        CaptureProxyPort.started = port
        options = ProxyPort.merging(into: options, port: port)
        return HTTP2CaptureSetting.merging(into: options, enabled: HTTP2CaptureSetting.isEnabled(in: .standard))
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
                    try m.connection.startVPNTunnel(options: Self.tunnelStartOptions())
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
            CaptureProxyPort.stopRequested()
            m.isEnabled = false
            m.connection.stopVPNTunnel()
        }
    }
}
