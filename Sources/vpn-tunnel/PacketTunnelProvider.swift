//
//  PacketTunnelProvider.swift
//  vpn-tunnel
//
//  Created by OloApps on 08.05.2021.
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

import NetworkExtension
import XReqResCore
import Reachability
import os.log
import Sentry
import Utils

let TUNNEL_HOSTNAME = "127.0.0.1"

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
    /// The proxy of the capture under way: nil before a start has made one,
    /// and again once a stop or a failed start has closed it. It was a
    /// force-unwrapped `MitmService!`, and `stopTunnel` closed it blindly — a
    /// trap for a stop that came before any start had made one.
    var mitmServer: MitmService?
    /// The proxy's port for this start (`ProxyPort.from(options:)`).
    var proxyPort = ProxyPort.defaultPort
    var reachability = try! Reachability()
    
    /// The completion handler to call when the tunnel is fully established;
    /// nil once it has been called, and once a stop has come. A start that
    /// finishes after its stop reports nothing and runs nothing. It was
    /// force-unwrapped, and a stop that overtook a start left the start's
    /// own completion calling a nil handler — a trap in the extension.
    var pendingStartCompletion: ((Error?) -> Void)?
    
    /// The completion handler to call when the tunnel is fully disconnected.
    var pendingStopCompletion: (() -> Void)?

    /// Every change to the start's state, in order: `prepareCapture` answers
    /// on a task of its own, the proxy's `run` on a dispatch queue, the
    /// system proxy's settings on NetworkExtension's queue, and NetworkExtension
    /// calls `stopTunnel` on yet another. A stop that overtakes a start is
    /// then seen by whichever step comes after it.
    private let startQueue = DispatchQueue(label: "com.oloapps.ReqRes.vpn-tunnel.start")
    /// Bumped by every start and every stop of THIS provider, on
    /// `startQueue`: a step that belongs to an earlier one finds a different
    /// number and does nothing. Whether what an overtaken start made may be
    /// closed is the whole process's question (`CaptureStartLedger`).
    private var startGeneration: UInt64 = 0
    
    // MARK: NEPacketTunnelProvider
    
    /// Begin the process of establishing the tunnel.
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // This start's place among every start in the process — later
        // sessions get provider objects of their own (`CaptureStartLedger`).
        let processStart = CaptureStartLedger.process.begin()
        let generation: UInt64 = startQueue.sync {
            startGeneration &+= 1
            pendingStartCompletion = completionHandler
            return startGeneration
        }
        // The proxy's port, from the same options the core's listener reads
        // (`ProxyPort`): the system proxy must point where the listener is.
        proxyPort = ProxyPort.from(options: options)
        initSentry(consent: (options?[TelemetryConsent.startOptionKey] as? NSNumber)?.boolValue ?? true)
        VpnTunnelLog.shared.info("[PacketTunnelProvider] starting tunnel")
        // The CA flag AND the install's CA material arrive in the start
        // options (the app is their one writer). This process never writes or
        // generates a CA: without material it relays every CONNECT.
        //
        // Every 1.0.x extension wrote the SHARED CA — its private key
        // included — into this process's own group container (root's, not the
        // user's). Nothing reads those files any more; the core deletes them
        // only if they are that shared CA, so an install's own CA is never
        // touched wherever this runs.
        if let certDirectory = CertificateAuthority.storageDirectory(),
           CertificateAuthority.removeLegacySharedFiles(in: certDirectory) {
            VpnTunnelLog.shared.info("[PacketTunnelProvider] removed the 1.0.x shared CA files from this container")
        }
        // `prepareCapture`, not `prepare` (core 95062d1): the old entry point
        // maps every failure to nil, which this file then reported as a busy
        // port whatever the cause. A start with ReqRes's start options and no
        // app listening does not fail any more — capture runs, relaying, and
        // the bus looks for the app until one proves itself.
        MitmService.prepareCapture(tunnelOptions: options) { [weak self] result in
            guard let self else {
                // NetworkExtension let this provider go — after a stop. A
                // proxy the start made never ran; it is closed while no start
                // has begun in this process since (`discardOvertaken`).
                if case .success(let server) = result { PacketTunnelProvider.discardOvertaken(server, processStart: processStart) }
                return
            }
            self.startQueue.async { self.prepared(result, generation: generation, processStart: processStart) }
        }
    }

    /// Whether `generation` is still the start under way: no later start or
    /// stop has come since. On `startQueue`.
    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == startGeneration && pendingStartCompletion != nil
    }

    /// `prepareCapture` answered. On `startQueue`.
    private func prepared(_ result: Result<MitmService, MitmService.StartFailure>, generation: UInt64, processStart: UInt64) {
        guard isCurrent(generation) else {
            // A stop overtook this start (the core answers such a start
            // `.stoppedBeforeStart` when it sees the stop in time, and makes
            // no proxy). Nothing runs, and there is nothing to tell anyone:
            // the stop already cleared the completion.
            VpnTunnelLog.shared.notice("[PacketTunnelProvider] capture was stopped before this start was ready; nothing runs")
            if case .success(let server) = result { PacketTunnelProvider.discardOvertaken(server, processStart: processStart) }
            return
        }
        switch result {
        case .failure(let failure):
            let reason = Self.tunnelStartFailure(failure)
            VpnTunnelLog.shared.error("[PacketTunnelProvider] capture did not start: \(reason.message, privacy: .public)")
            // Reporting nil here would tell NetworkExtension the tunnel
            // STARTED: macOS and the app would both show "connected" with no
            // proxy behind them.
            if reason.isReportable { SentrySDK.capture(error: reason.error) }
            finishStart(reason.error)
        case .success(let server):
            mitmServer = server
            server.run { [weak self] result in
                guard let self else { return }
                self.startQueue.async { self.ran(result, server: server, generation: generation) }
            }
        }
    }

    /// The proxy a start made after its stop had come. Closed only when no
    /// start has begun in this PROCESS since — by this provider or by the one
    /// NetworkExtension made for a later session: closing calls
    /// `MitmService.captureStopped`, which is the whole process's, and would
    /// end a later start's search for the app or fail it as stopped. It
    /// never ran (no listener), so leaving it costs only its event loops.
    private static func discardOvertaken(_ server: MitmService, processStart: UInt64) {
        let closed = CaptureStartLedger.process.ifNoStartSince(processStart) { server.close() }
        if !closed {
            VpnTunnelLog.shared.notice("[PacketTunnelProvider] a later start is under way in this process; the overtaken start's proxy is left unopened")
        }
    }

    /// The proxy's `run` answered. On `startQueue`.
    private func ran(_ result: Result<Void, Error>, server: MitmService, generation: UInt64) {
        // Stopped meanwhile: `stopTunnel` closed it and cleared both.
        guard isCurrent(generation), mitmServer === server else { return }
        switch result {
        case .success:
            let endpoint = NWHostEndpoint(hostname: TUNNEL_HOSTNAME, port: String(proxyPort))
            connection = createTCPConnection(to: endpoint, enableTLS:false, tlsParameters:nil, delegate:nil)
            startVPNWithOptions(options: nil) { [weak self] error in
                guard let self else { return }
                self.startQueue.async { self.systemProxySet(error, server: server, generation: generation) }
            }
        case .failure(let error):
            VpnTunnelLog.shared.error("[PacketTunnelProvider] failed to run! Error: \(error.localizedDescription, privacy: .public)")
            SentrySDK.capture(error: error)
            // The proxy could not listen. The core already ended the bus's
            // search for an app; closing also frees the proxy's event loops.
            endCapture()
            finishStart(error)
        }
    }

    /// The system proxy's settings were applied, or not. On `startQueue`.
    private func systemProxySet(_ error: Error?, server: MitmService, generation: UInt64) {
        guard isCurrent(generation), mitmServer === server else { return }
        if let error {
            VpnTunnelLog.shared.error("[PacketTunnelProvider] startVPNWithOptions() failed! Error: \(error.localizedDescription, privacy: .public)")
            // The start fails after `prepareCapture` returned: end the capture
            // it began — the proxy, and the bus's search for an app
            // (`MitmService.captureStopped`). Left looking, the bus of a
            // capture that never ran would redial the app every 2 s and tell
            // it it was reattached.
            endCapture()
            finishStart(error)
            return
        }
        VpnTunnelLog.shared.debug("[PacketTunnelProvider] startVPNWithOptions() success!")
        readPackets()
        finishStart(nil)
    }

    /// Calls the start's completion, once. On `startQueue`.
    private func finishStart(_ error: Error?) {
        let completion = pendingStartCompletion
        pendingStartCompletion = nil
        completion?(error)
    }

    /// Ends the capture this provider runs or was starting. With a proxy,
    /// closing it ends everything — `close()` calls
    /// `MitmService.captureStopped()` itself. Without one (a stop during
    /// `prepareCapture`, or after a start that failed), the bus's search for
    /// an app is ended directly: it began at the start's connect. Never
    /// `tcpClientBus.stop()` (F9: the next start's connect would hang). On
    /// `startQueue`.
    private func endCapture() {
        if let server = mitmServer {
            mitmServer = nil
            server.close()
        } else {
            MitmService.captureStopped()
        }
    }

    /// The core's reason, worded for whoever reads it (`TunnelStartFailure`).
    /// `.stoppedBeforeStart` reaches this only for a start no stop of
    /// NetworkExtension's overtook — a capture stop made elsewhere in this
    /// process during its preparation. Said, rather than leaving
    /// NetworkExtension waiting for an answer that never comes.
    static func tunnelStartFailure(_ failure: MitmService.StartFailure) -> TunnelStartFailure {
        switch failure {
        case .startedOutsideReqRes: return .startedOutsideReqRes
        case .stoppedBeforeStart: return .interrupted
        @unknown default: return .failed(String(describing: failure))
        }
    }
    
    func startVPNWithOptions(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: TUNNEL_HOSTNAME)
        networkSettings.mtu = 1500

        let proxySettings = NEProxySettings()
        proxySettings.httpServer = NEProxyServer(address: TUNNEL_HOSTNAME, port: proxyPort)
        proxySettings.httpEnabled = true
        proxySettings.httpsServer = NEProxyServer(address: TUNNEL_HOSTNAME, port: proxyPort)
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
        startQueue.sync {
            // A start still on its way reports nothing and runs nothing now.
            startGeneration &+= 1
            pendingStartCompletion = nil
            pendingStopCompletion = completionHandler
            endCapture()
        }
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
    
    /// - Parameter consent: the user's answer, carried in the tunnel's START
    ///   OPTIONS by `VPNManager`.
    ///
    ///   It was first read from the app group here, which does not work: this
    ///   process runs as ROOT, so it reads root's copy of the group defaults
    ///   rather than the user's, and an opt-out never arrived. The options
    ///   dictionary is the channel that already crosses this boundary for the
    ///   CA flag, and it is available exactly here, inside `startTunnel`,
    ///   before the bus to the app exists. Missing ⇒ reporting on, the shipped
    ///   behaviour — an absent key is not consent to disable.
    func initSentry(consent consented: Bool) {
        guard consented else {
            // Never started, so nothing is initialised to send later: the
            // SentrySDK.capture calls elsewhere in this file are no-ops until
            // start() runs. Opting out has to mean no client exists, not a
            // client that is asked to stay quiet.
            VpnTunnelLog.shared.info("[PacketTunnelProvider] crash reporting is off by user choice")
            return
        }
        SentrySDK.start { options in
            options.dsn = "https://\(EnvironmentVars.sentryDsn)"
            // Sentry types this as NSNumber?; a literal bridged, a Double does not.
            options.tracesSampleRate = NSNumber(value: TelemetryConsent.sampleRate)
            // Captured traffic must never reach a crash report. The Settings
            // copy says request and response bodies are never included, and
            // these are what make that enforced rather than asserted: Sentry's
            // network breadcrumbs record the URLs an app requests, and this app
            // is a proxy — its "own" requests are the user's traffic.
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            // Network extension is executed only in prod
            options.environment = "production"
        }
    }
}
