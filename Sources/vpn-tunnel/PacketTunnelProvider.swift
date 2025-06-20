//
//  PacketTunnelProvider.swift
//  vpn-tunnel
//
//  Created by OloApps on 08.05.2021.
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

import NetworkExtension
import XReqResCore
import Reachability
import os.log
import Sentry
import Utils

let TUNNEL_HOSTNAME = "127.0.0.1"
let PORT = "8034"

final class VpnTunnelLog {
    var logger: Logger! = nil
    static let shared: Logger = {
        var logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ReqResVPNTunnel")
        return logger
    }()
    
    init(susbsystem: String, category: String) {
        self.logger = Logger(subsystem: susbsystem, category: category)
    }
}


class PacketTunnelProvider: NEPacketTunnelProvider {
    // MARK: Properties

    open var connection: NWTCPConnection!
    var mitmServer: MitmService!
    var reachability = try! Reachability()
    
    /// The completion handler to call when the tunnel is fully established.
    var pendingStartCompletion: ((Error?) -> Void)!
    
    /// The completion handler to call when the tunnel is fully disconnected.
    var pendingStopCompletion: (() -> Void)?
    
    // MARK: NEPacketTunnelProvider
    
    /// Begin the process of establishing the tunnel.
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        pendingStartCompletion = completionHandler
        initSentry()
        VpnTunnelLog.shared.info("[PacketTunnelProvider] starting tunnel")
        generateCertificatesMaybe()
        let isCACertificateInstalledInKeychain = options?["isCACertificateInstalledInKeychain"] as? NSNumber
        MitmService.prepare(isCACertificateInstalledInKeychain: isCACertificateInstalledInKeychain?.boolValue ?? false) { [weak self] server in
            if (server == nil) {
                VpnTunnelLog.shared.error("[PacketTunnelProvider] startTunnel() failed! Server was not returned from .prepare() func")
                self?.pendingStartCompletion(nil)
                return
            }
            self?.mitmServer = server
            self?.mitmServer.run({ (result) in
                switch result {
                case .success( _):
                    let endpoint = NWHostEndpoint(hostname: TUNNEL_HOSTNAME, port: PORT)
                    self?.connection = self?.createTCPConnection(to: endpoint, enableTLS:false, tlsParameters:nil, delegate:nil)
                    self?.startVPNWithOptions(options: nil) { (error) in
                        if error == nil {
                            VpnTunnelLog.shared.debug("[PacketTunnelProvider] startVPNWithOptions() success!")
                            self?.readPackets()
                            self?.pendingStartCompletion(nil)
                            
                        } else {
                            VpnTunnelLog.shared.error("[PacketTunnelProvider] startVPNWithOptions() failed! Error: \(error!.localizedDescription, privacy: .public)")
                            self?.pendingStartCompletion(error)
                        }
                    }
                case .failure(let error):
                    VpnTunnelLog.shared.error("[PacketTunnelProvider] failed to run! Error: \(error.localizedDescription, privacy: .public)")
                    SentrySDK.capture(error: error)
                    self?.pendingStartCompletion(error)
                    break
                }
            })
        }
    }
    
    func startVPNWithOptions(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: TUNNEL_HOSTNAME)
        networkSettings.mtu = 1500

        let proxySettings = NEProxySettings()
        proxySettings.httpServer = NEProxyServer(address: TUNNEL_HOSTNAME, port: Int(PORT)!)
        proxySettings.httpEnabled = true
        proxySettings.httpsServer = NEProxyServer(address: TUNNEL_HOSTNAME, port: Int(PORT)!)
        proxySettings.httpsEnabled = true
        proxySettings.matchDomains = [""]
        networkSettings.proxySettings = proxySettings

        let ipv4Settings = NEIPv4Settings(addresses: [networkSettings.tunnelRemoteAddress], subnetMasks: ["255.255.255.0"])
        networkSettings.ipv4Settings = ipv4Settings
        setTunnelNetworkSettings(networkSettings) { (error) in
            completionHandler(error)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        pendingStartCompletion = nil
        pendingStopCompletion = completionHandler
        mitmServer.close()
        completionHandler()
    }
    
    func readPackets() -> Void {
        packetFlow.readPackets { (packets, protocols) in
            for packet in packets {
                self.connection.write(packet, completionHandler: { (error) in
                    if let e = error {
                        VpnTunnelLog.shared.error("[PacketTunnelProvider] Write packet error: \(e.localizedDescription, privacy: .public)")
                    }
                })
            }
            self.readPackets()
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {}
    
    func generateCertificatesMaybe() {
        do {
            let fileManager = FileManager.default
            if let certDir = MitmService.getCertPath() {
                // Cert
                let cacertPath = certDir.appendingPathComponent("cacert.pem", isDirectory: false)
                let cacertDerPath = certDir.appendingPathComponent("cacert.der", isDirectory: false)
                let cakeyPath = certDir.appendingPathComponent("cakey.pem", isDirectory: false)
                let rsakeyPath = certDir.appendingPathComponent("rsakey.pem", isDirectory: false)
                VpnTunnelLog.shared.debug("[PacketTunnelProvider] Checking if cacert.pem exists at \(cacertPath.path, privacy: .public). Result: \(fileManager.fileExists(atPath: cacertPath.path), privacy: .public)")
                if !fileManager.fileExists(atPath: cacertPath.path) {
                    let fullCC = cc1 + cc2 + cc3
                    try fullCC.write(to: cacertPath, atomically: true, encoding: .utf8)
                    VpnTunnelLog.shared.info("[PacketTunnelProvider] Writing cacert.pem to \(cacertPath.path, privacy: .public)")
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
            VpnTunnelLog.shared.error("[PacketTunnelProvider] Error writing certificates! \(error.localizedDescription, privacy: .public)")
            SentrySDK.capture(error: error)
        }
    }
    
    func initSentry() {
        SentrySDK.start { options in
            options.dsn = "https://\(EnvironmentVars.sentryDsn)"
            // Set to 10%
            options.tracesSampleRate = 0.1
            // Network extension is executed only in prod
            options.environment = "production"
        }
    }
}
