//
//  AppController.swift
//  ReqRes
//
//  Created by OloApps on 15.06.2023.
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
import XReqResCore
@preconcurrency import NetworkExtension
import SystemExtensions
import os.log
import Combine
import Utils
import MCPKit
import AppKit

class AppController: NSObject {
    static let tcpServerBus: TCPServerBus = TCPServerBus()
    /// The database the core's bridge reads and writes (`ReqResCoreModelBridge`
    /// and the Storage pane both use `.shared`). This used to be a SECOND
    /// instance of the same file, opened by `booststrap` and never used again
    /// — two GRDB queues on one SQLite file in one process.
    let databaseManager: DatabaseManager = DatabaseManager.shared
    
    var appModel = AppState.shared
    fileprivate var isVpnRunningSubscription: AnyCancellable?
    /// `openCaptureChannel` and `booststrap` each run their work once per
    /// process; both are main-thread only.
    private var captureChannelOpened = false
    private var bootstrapped = false
    /// The first successful read of the tunnel's status — the one that can
    /// say capture was already running when this process launched.
    private var launchStatusRead = false
    /// This process has asked the tunnel to start. A tunnel found up after
    /// that is not one that outlived the last app, whatever order the launch
    /// read and the status notifications arrive in.
    private var startRequestedHere = false
    /// When this process last sent a start that the system has not reported
    /// yet — cleared by the first status notification that shows the tunnel
    /// moving (`CaptureControl.startInFlight`). Main thread.
    private var startSentAt: Date?
    /// A start this process sent is on its way and the system has not
    /// reported it moving: a "down" read now is the previous stop's late
    /// notification — the reattach logic does not end the run on it (build
    /// 53, `CaptureReattachFacts.startInFlight`). Main thread.
    var isStartInFlight: Bool {
        CaptureControl.startInFlight(sentAt: startSentAt, now: Date())
    }
    /// Counts every explicit request to change capture — a click, ⌘⇧C, the
    /// menu bar item, an agent's start_capture or stop_capture. A Restart
    /// Capture waiting between its stop and its start stands down when it
    /// moves: that request stands (`CaptureRestart.step`). Main thread.
    private var captureRequests = 0
    
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
    
    /// Everything the extension needs from this process before capture can
    /// be shown or touched (F11): the database, the message bus the extension
    /// delivers to, the tunnel's status notifications, and the tunnel's REAL
    /// status. Once per process, from `applicationDidFinishLaunching` —
    /// before the update reset, and before any window. Main thread.
    ///
    /// It used to run from `booststrap`, i.e. from the main window's
    /// `onAppear`: nothing listened on the bus until a window existed, every
    /// reappearing window added another status observer, and the launch check
    /// then wrote "disconnected" over whatever the tunnel was doing.
    @MainActor
    func openCaptureChannel() {
        guard !captureChannelOpened else { return }
        captureChannelOpened = true

        databaseManager.initializeDatabase()
        // `AppController.shared` has set itself as the bus's delegate by now
        // (init), so nothing the extension sends can arrive unheard.
        do {
            try AppController.tcpServerBus.start(port: MessageBusPort)
        } catch {
            AppLog.shared.error("Failed to start the TCPServerBus. Check if \(MessageBusPort) is available.")
        }
        bindListeners()
        CaptureDeliveryMonitor.shared.start()
        seedCaptureStatus()
    }

    /// The rest of startup, from the main window's `onAppear` — which runs
    /// again for every window, so everything here but `completion` runs once.
    @MainActor
    func booststrap(completion: @escaping () -> Void) {
        // A no-op after launch; here for a window that appears first.
        openCaptureChannel()

        if !bootstrapped {
            bootstrapped = true
            LiveCaptureEngineFacts.assertHelperDefaultsMatchCore()
            HTTP2CaptureSync.assertMatchesCore()
            Self.assertReattachReaderMatchesCore()

            // submitActivationNetworkExtensionRequest()
            bindSubscriptions()

            // Agent bridge (MCP). Opt-in and non-fatal: never blocks app startup.
            MCPServerService.shared.startIfEnabled()
        }

        completion()
    }

    /// Reads the tunnel's status from the saved configuration — without
    /// creating one — and shows it (F11). A tunnel that outlived the app (a
    /// crash, Force Quit, Xcode's Stop) is running when this runs, and macOS
    /// posts its status only when it CHANGES, so nothing else would ever say
    /// so. Safe to call again: it shows whatever the connection says now.
    func seedCaptureStatus() {
        VPNManager.shared.loadExistingManager { [weak self] manager, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    // Unknown is not off: the display is left as it is, and
                    // the next status check tries again.
                    AppLog.shared.error("[AppController] could not read capture's status at launch: \(error.localizedDescription, privacy: .public)")
                    return
                }
                let firstRead = !self.launchStatusRead
                self.launchStatusRead = true
                // From here the display is a reading, not the initial "off":
                // the reattach logic may decide from it (build 53) — and a
                // reattach the extension reported before this waits for it.
                CaptureDeliveryMonitor.shared.tunnelStatusRead()
                guard let manager else {
                    AppLog.shared.debug("[AppController] no capture configuration saved yet: capture is off")
                    return
                }
                let connection = manager.connection
                // Read here, on main, so a status notification handled
                // before this cannot be overwritten by an older reading.
                let state = CaptureTunnelState(connection.status)
                // Only the first reading, and only a tunnel this process has
                // not started, is one that outlived the last app.
                if firstRead, !state.isDown, !self.startRequestedHere {
                    // Before it is shown, so the delivery verdict for it
                    // already knows the run is not this process's.
                    CaptureDeliveryMonitor.shared.tunnelWasUpAtLaunch()
                    AppLog.shared.notice("[AppController] capture was already running at launch (\(connection.status.description, privacy: .public))")
                }
                self.appModel.adoptTunnelStatus(connection.status, connectedDate: connection.connectedDate)
            }
        }
    }
    
    deinit {}
}

// MARK: Network extension piece

extension AppController {
    // NOTE: not used
    public func submitActivationNetworkExtensionRequest() {
        guard let extensionIdentifier = extensionBundle.bundleIdentifier else {
            // No status write: a missing identifier says nothing about a
            // tunnel that may be running (F11).
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
            // No status write: an activation that completes after a reboot
            // does not stop a tunnel that is running now (F11).
            AppLog.shared.warning("Unexpected result for system extension request: \(result.rawValue, privacy: .public)")
            return
        }

        // initTunnel()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        AppLog.shared.critical("System extension request failed: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async {
            // No status write (F11): a failed activation request says nothing
            // about a tunnel already running; its notifications say that.
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
    /// The capture button — the toolbar, ⌘⇧C, the Capture menu, the menu bar
    /// item: starts what the user saw stopped and stops anything else they
    /// saw (F11). Main thread, so the display read here is the one the user
    /// acted on; the decision to start or stop is made from it BEFORE the
    /// checks below run, and the tunnel's real status can then only confirm
    /// it or cancel it — never turn a Start into a stop.
    func toggleVPNTunnel() {
        requestCapture(CaptureIntent.toggle(shown: CaptureTunnelState(appModel.vpnStatus)))
    }

    /// Starts capture. Never stops it: a tunnel already up is shown, not
    /// stopped. For callers that know they mean "start" — an agent's
    /// start_capture, "Start Monitoring", the busy-port alert's Use Port.
    func startCapture() {
        requestCapture(.start)
    }

    /// Stops capture. Never starts it.
    func stopCapture() {
        requestCapture(.stop)
    }

    /// Someone asked to change capture — noted AT the request, before any of
    /// the asynchronous checks that follow it, so a Restart Capture waiting
    /// out its stop sees it at its next look and leaves the capture to it.
    /// Main thread.
    func noteCaptureRequest() {
        captureRequests &+= 1
        // And the reattach logic (build 53): ReqRes does not restart capture
        // by itself in a stretch where someone asked for a start or a stop.
        if Thread.isMainThread {
            MainActor.assumeIsolated { CaptureDeliveryMonitor.shared.captureRequested() }
        } else {
            DispatchQueue.main.async { CaptureDeliveryMonitor.shared.captureRequested() }
        }
    }

    func requestCapture(_ intent: CaptureIntent) {
        noteCaptureRequest()
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
                    // Extension enabled but config not installed. A START
                    // continues below, where `loadManager` creates it and
                    // macOS asks the user — a click is one of the two places
                    // that may (with the setup checklist's Install VPN
                    // Configuration): the status checks only read, or every
                    // Don't Allow was followed by the prompt again two
                    // seconds later (F11 review). A stop has nothing to stop.
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
                    guard intent == .start else { return }

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
                
                VPNManager.shared.loadManager({ (manager, error) in
                    DispatchQueue.main.async {
                        // No status write on either failure (F11): a load
                        // that failed says nothing about the tunnel, and the
                        // display is left showing what it last knew.
                        if let error = error {
                            AppLog.shared.critical("VPNManager.shared.loadManager error: \(error.localizedDescription, privacy: .public)")
                            return
                        }
                        
                        guard let manager = manager else {
                            AppLog.shared.critical("No VPN manager available")
                            return
                        }
                        
                        // The one controller, by name: nothing here holds it
                        // across the asynchronous hops.
                        AppController.shared.act(on: intent, connection: manager.connection)
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
    
    /// Does what `intent` asks, if the tunnel's REAL status allows it
    /// (`CaptureControl`, Utils). Returns the error when the system refused
    /// a start it was sent — Restart Capture owes the person a reason; a
    /// start refused before it was sent (the bus, the port) has said so.
    @MainActor
    @discardableResult
    private func act(on intent: CaptureIntent, connection: NEVPNConnection) -> Error? {
        AppLog.shared.debug("Found manager with the connection status: \(connection.status, privacy: .public)")
        let inFlight = CaptureControl.startInFlight(sentAt: startSentAt, now: Date())
        switch CaptureControl.action(for: intent, real: CaptureTunnelState(connection.status), startInFlight: inFlight) {
        case .showRealStatus:
            // The request was made against a display that was wrong — capture
            // shown off while a tunnel that outlived the app ran on, or on
            // after it stopped. Doing the opposite of what was asked is what
            // F11 was; the truth is shown instead, and the user decides again.
            AppLog.shared.notice("[AppController] capture \(intent == .start ? "start" : "stop", privacy: .public) not sent: the tunnel is \(connection.status.description, privacy: .public)")
            appModel.adoptTunnelStatus(connection.status, connectedDate: connection.connectedDate)
        case .startAlreadySent:
            // A start from here is on its way and the system has not caught
            // up: a second one is not sent into it, and the display (already
            // "connecting") is not corrected to the stale "disconnected".
            AppLog.shared.notice("[AppController] capture start not sent: one is already on its way")
        case .start:
            return startTunnel(connection)
        case .stop:
            CaptureProxyPort.stopRequested()
            connection.stopVPNTunnel()
        }
        return nil
    }

    /// Returns the error when `startVPNTunnel` threw; nil otherwise.
    @MainActor
    private func startTunnel(_ connection: NEVPNConnection) -> Error? {
        // The bus the extension delivers to: a tunnel started without it
        // decrypts everything for nobody. Only a START needs it — a stop from
        // a copy of ReqRes without the bus still works.
        guard openMessageBus() else {
            let anotherCopy = CaptureDeliveryMonitor.anotherCopyRunning()
            AppLog.shared.critical("[AppController] capture not started: nothing listens on 127.0.0.1:\(MessageBusPort, privacy: .public) for the extension (another copy of ReqRes running: \(anotherCopy, privacy: .public))")
            // What the tunnel says (down), for a display that may have lagged.
            appModel.adoptTunnelStatus(connection.status, connectedDate: connection.connectedDate)
            TrafficCommands.presentCaptureChannelUnavailable(anotherCopyRunning: anotherCopy)
            return nil
        }

        // If this is the first time installing/enabling, mark it
        if !AppPreferences.shared.isFirstVPNConfigInstalled {
            AppPreferences.shared.isFirstVPNConfigInstalled = true
        }
        
        // A port another program holds: ask, naming the
        // holder — never hop to another port silently.
        let port = CaptureProxyPort.configured
        if let conflict = CaptureProxyPort.conflict(port: port) {
            AppLog.shared.error("[AppController] proxy port \(port, privacy: .public) is in use by \(conflict.holder ?? "another program", privacy: .public); capture not started")
            // What the tunnel says (down) — no longer a guessed "disconnected".
            appModel.adoptTunnelStatus(connection.status, connectedDate: connection.connectedDate)
            appModel.proxyPortConflict = conflict
            return nil
        }
        do {
            // The CA flag, the install's CA material and the
            // crash-reporting consent — one builder for every start.
            // Built only for a start: it records the port as the running
            // capture's, which a refused start or a stop must not.
            let options = VPNManager.tunnelStartOptions()
            appModel.vpnStatus = .connecting
            startRequestedHere = true
            try connection.startVPNTunnel(options: options)
            // On its way until the system reports the tunnel moving: a
            // request that finds it still reading down must not send another.
            startSentAt = Date()
            // A new run, this process's own, from the moment it is sent — not
            // from whenever a deferred look happens to see the tunnel down.
            CaptureDeliveryMonitor.shared.startSent()
            // Watched until it connects: the extension's
            // own bind is the last word on the port, and
            // a start it refuses is said (`vpnDidChange`).
            CaptureProxyPort.startRequested()
            return nil
        } catch {
            AppLog.shared.critical("Failed to start VPN tunnel: \(error.localizedDescription, privacy: .public)")
            // What the tunnel says now, not a guess.
            appModel.adoptTunnelStatus(connection.status, connectedDate: connection.connectedDate)
            return error
        }
    }

    /// Listens on the message bus unless this process already does; true
    /// when it does. Fails while another process holds 127.0.0.1:50001 —
    /// another copy of ReqRes, above all (the core binds that exact address
    /// without SO_REUSEPORT, so a second listener is refused).
    ///
    /// `quietly`: the reattach logic's retry every 5 s while another copy
    /// holds the bus (build 53) — a refusal there is the expected answer, not
    /// a failure worth a critical line each time.
    @discardableResult
    func openMessageBus(quietly: Bool = false) -> Bool {
        if AppController.tcpServerBus.isServerListening() { return true }
        do {
            try AppController.tcpServerBus.start(port: MessageBusPort)
            return true
        } catch {
            if quietly {
                AppLog.shared.debug("[AppController] the bus is still taken: \(error.localizedDescription, privacy: .public)")
            } else {
                AppLog.shared.critical("Failed to start TCP server: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// Stops capture and, once the tunnel reads down, starts it again from
    /// this app — which is what makes an extension that cannot reconnect by
    /// itself (one started outside ReqRes, or an earlier build's) connect to
    /// it (F11), and what a new port or certificate needs to take effect. Only
    /// a RUNNING tunnel is restarted: one already stopping was stopped by
    /// someone, and restarting it would undo that.
    /// `completion` runs on main once the start is sent or the restart ends
    /// without one; an ending the person did not ask for is then said
    /// (`CaptureRestartFailure`). Main thread.
    ///
    /// Waits for the tunnel to be down before starting it again: the 1.0.x
    /// version toggled after a fixed 2 s, and a tunnel still disconnecting
    /// then was STOPPED by the toggle instead of started. What it does at each
    /// look is `CaptureRestart.step` (Utils).
    ///
    /// `automatic` (build 53): the one restart the reattach logic makes by
    /// itself when a running capture cannot reattach. It is nobody's request —
    /// a person's restart is one, and stands down that logic for the stretch.
    /// It asks nothing before it acts, and how it ended goes to `completion`
    /// only (the pane's one line says it): no "Capture was not restarted"
    /// alert. Its start is a start like any other, though — one the port or
    /// the system then refuses is said as every start's is (the busy-port
    /// question, "Capture did not start"): by then capture is off.
    @MainActor
    func restartCapture(completion: ((CaptureRestartOutcome) -> Void)? = nil, automatic: Bool = false) {
        if !automatic { CaptureDeliveryMonitor.shared.captureRequested() }
        let finish: (CaptureRestartFailure?) -> Void = { failure in
            completion?(failure.map(CaptureRestartOutcome.failed) ?? .startSent)
            if !automatic, let failure { TrafficCommands.presentCaptureRestartFailed(failure) }
        }
        // The bus FIRST (F11 review): only the start needs it, and a copy that
        // cannot open it used to stop capture and then be refused — a restart
        // turned into a plain stop. Nothing is stopped unless the start after
        // it can go out.
        guard openMessageBus() else {
            let anotherCopy = CaptureDeliveryMonitor.anotherCopyRunning()
            AppLog.shared.error("[AppController] restart not begun: nothing can listen on 127.0.0.1:\(MessageBusPort, privacy: .public) here (another copy of ReqRes running: \(anotherCopy, privacy: .public))")
            finish(.channelUnavailable(anotherCopyRunning: anotherCopy))
            return
        }
        // Any request made after this click — a start or a stop, from
        // anywhere — stands, and the restart leaves the capture to it.
        let requestsAtClick = captureRequests
        VPNManager.shared.loadExistingManager { [weak self] manager, error in
            DispatchQueue.main.async {
                guard let self else {
                    completion?(.nothingToRestart)
                    return
                }
                if let error {
                    AppLog.shared.error("[AppController] restart not begun: the capture configuration could not be read: \(error.localizedDescription, privacy: .public)")
                    finish(.configurationUnreadable(error.localizedDescription))
                    return
                }
                // No configuration, or nothing running: nothing to restart.
                guard let manager else {
                    completion?(.nothingToRestart)
                    return
                }
                let connection = manager.connection
                let running: Set<NEVPNStatus> = [.connecting, .connected, .reasserting]
                guard self.captureRequests == requestsAtClick else {
                    completion?(.stoodDown)
                    return
                }
                guard running.contains(connection.status) else {
                    completion?(.nothingToRestart)
                    return
                }
                // Decided on "no extension on the bus" a hop ago: one that
                // reattached meanwhile (the redial can land at any moment)
                // would be cut by the stop. Nothing to restart then.
                if automatic && AppController.tcpServerBus.hasAuthenticatedExtension {
                    AppLog.shared.notice("[AppController] automatic restart not begun: the extension reattached meanwhile")
                    completion?(.noLongerNeeded)
                    return
                }
                AppLog.shared.notice("[AppController] restarting capture")
                // The same stop the capture button sends.
                CaptureProxyPort.stopRequested()
                connection.stopVPNTunnel()
                let stopSent = Date()
                Task { @MainActor in
                    var sawStopping = false
                    while true {
                        try? await Task.sleep(nanoseconds: UInt64(CaptureRestart.lookInterval * 1_000_000_000))
                        let tunnel = CaptureTunnelState(connection.status)
                        switch CaptureRestart.step(tunnel: tunnel, sawStopping: sawStopping,
                                                   requestedSince: self.captureRequests != requestsAtClick,
                                                   elapsed: Date().timeIntervalSince(stopSent)) {
                        case .wait:
                            if tunnel == .disconnecting { sawStopping = true }
                        case .start:
                            // Straight to the start: the extension was running
                            // a moment ago, so the setup checks a click goes
                            // through have nothing to add — and skipping them
                            // means the start is sent before `completion`
                            // says the restart is over.
                            let sentBefore = self.startSentAt
                            let refused = self.act(on: .start, connection: connection)
                            if let refused {
                                finish(.startRefused(refused.localizedDescription))
                            } else if let sent = self.startSentAt, sent != sentBefore {
                                finish(nil)
                            } else {
                                // Refused before it went out — the busy-port
                                // question, the bus — and already said.
                                completion?(.notSent)
                            }
                            return
                        case .standDown:
                            AppLog.shared.notice("[AppController] restart stood down: capture was asked for, or started, since it began")
                            completion?(.stoodDown)
                            return
                        case .giveUp:
                            AppLog.shared.error("[AppController] capture did not stop within \(Int(CaptureRestart.stopTimeout), privacy: .public) s; not restarting it")
                            finish(.didNotStop)
                            return
                        }
                    }
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
                    // The extension's setup state ONLY. This used to write
                    // "disconnected" into the capture status for every
                    // outcome, `.ready` included — which is what showed
                    // capture off after a relaunch while it ran (F11). The
                    // capture status is the tunnel's to say
                    // (`seedCaptureStatus`, `vpnDidChange`), and the button
                    // stays usable because `.invalid` is shown as disconnected.
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
                // The configuration is loaded by now; a launch read that
                // failed gets its second chance here.
                if status == .ready {
                    seedCaptureStatus()
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
    
    /// Once per process, from `openCaptureChannel`. It ran from `booststrap`
    /// — every time the main window appeared — and each run added another
    /// observer, so every status change was handled once per window ever
    /// opened.
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
       // A status notification is the system's report, as the launch read is.
       if Thread.isMainThread {
           MainActor.assumeIsolated { CaptureDeliveryMonitor.shared.tunnelStatusRead() }
       } else {
           DispatchQueue.main.async { CaptureDeliveryMonitor.shared.tunnelStatusRead() }
       }

       // A start this process sent is no longer on its way once the system
       // reports the tunnel moving. A notification saying "down" does not end
       // it: it may be the previous stop's, delivered after the start went out.
       if !CaptureTunnelState(newStatus).isDown {
           startSentAt = nil
       }

       // Update the app state — as the app shows a status it reads (F11):
       // `.invalid` as disconnected, and a start time from the connection
       // when this process did not watch the tunnel come up.
       appModel.adoptTunnelStatus(newStatus, connectedDate: tunnelPS.connectedDate)
       
       // The proxy-port preflight needs to know when the tunnel went down
       // (F10); and a start the app asked for that ended before it ever
       // connected is said, not left as capture flipping back off.
       if CaptureProxyPort.tunnelStatusChanged(to: newStatus) {
           reportStartThatNeverConnected(tunnelPS)
       }

       // Check for extension status but don't show alerts automatically
       if newStatus == .invalid {
           checkInvalidVPNStatusQuietly()
       }
   }

    /// The extension refused a start the app asked for — most often its own
    /// bind of the proxy's port, which is the last word: the preflight lets a
    /// port through when only closed connections linger on it (F10). The
    /// system's reason is logged and shown beside the port.
    private func reportStartThatNeverConnected(_ connection: NEVPNConnection) {
        let port = CaptureProxyPort.started ?? CaptureProxyPort.configured
        connection.fetchLastDisconnectError { error in
            if let error = error as NSError? {
                AppLog.shared.error("[AppController] capture on port \(port, privacy: .public) ended before it connected: \(error.domain, privacy: .public) \(error.code, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            } else {
                AppLog.shared.error("[AppController] capture on port \(port, privacy: .public) ended before it connected; the system gave no reason")
            }
            // The extension's own reason alone when it gave one — not about
            // the port (build 53, `TunnelStartFailure`); else the port's
            // message with the system's reason.
            let message = TunnelStartFailure.didNotStartMessage(port: port, error: error as NSError?)
            DispatchQueue.main.async {
                TrafficCommands.presentCaptureDidNotStart(message: message)
            }
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
        // NOTE: do NOT interpolate `message.payload` here. It is a
        // [String: AnyCodable] holding the whole session — headers and bodies —
        // and formatting it runs Dictionary.description + reflection over every
        // value for EVERY captured request. It showed up directly in the
        // 2026-09-06 hang report (Dictionary.description.getter -> _debugPrint
        // -> swift_dynamicCast) on the bus's event-loop thread.
        AppLog.shared.debug("[TCPServerBus] received \(message.action.rawValue, privacy: .public) (\(data.count, privacy: .public) bytes)")

        switch message.action {
        case .breakpointHit:
            // A request is held mid-flight in the extension and this is the
            // only side that can ask anyone about it. Decoding happens in the
            // service, defensively: a payload it cannot read is dropped rather
            // than left as a phantom row for a request that is really waiting.
            if let payload = message.payload as [String: AnyCodable]? {
                DispatchQueue.main.async {
                    BreakpointService.shared.handleBreakpointHit(payload: payload)
                }
            }

        case .sendSession:
            if let anyCodableDict = message.payload["data"]?.value as? [String: Any] {
                if let jsonData = try? JSONSerialization.data(withJSONObject: anyCodableDict, options: []) {
                    // Decode the data into SessionCodable
                    do {
                        let session = try JSONDecoder().decode(SessionCodable.self, from: jsonData)
                        // Counted toward a reattach's "captured while ReqRes
                        // was closed" (build 53), by exchange.
                        CaptureDeliveryMonitor.busRowArrived((session.exchangeID ?? session.id).uuidString)
                        SessionState.shared.addSession(session: session)
                    } catch {
                        // The row holds captured headers and bodies, so the
                        // log gets its size and the decoder's reason, never
                        // its text. An extension built before this app's
                        // core sends rows under the field names of its own
                        // core; they land here during the seconds of an
                        // extension swap and are dropped.
                        AppLog.shared.error("[TCPServerBus] could not decode a session row (\(jsonData.count, privacy: .public) bytes): \(String(describing: error), privacy: .public)")
                    }
                } else {
                    AppLog.shared.error("[TCPServerBus] failed to serialize to JSON data")
                }
            }
        // Live rows (protocol-engine doc §C10.3 / §S6 / §C14): an exchange
        // still open 250 ms after its request, or a streaming type at its
        // response head, then its progress. Both go through
        // the SAME ingest queue and 150 ms flush as `send_session`, which is
        // what keeps a started message ahead of its final row.
        case .sessionStarted:
            if let started = Self.decodeLivePayload(LiveSessionStarted.self, from: message) {
                CaptureDeliveryMonitor.busRowArrived(started.exchangeID.uuidString)
                SessionState.shared.addLiveStarted(started)
            }
        case .sessionProgress:
            if let progress = Self.decodeLivePayload(LiveSessionProgress.self, from: message) {
                SessionState.shared.addLiveProgress(progress)
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
            // A start's says {"status": "connected"}; a reattach's (build 53,
            // core 95062d1) carries what the extension delivered and kept —
            // the backlog's tally closes here, on the bus's thread, where the
            // rows it counted arrived in order before it.
            let capturedWhileDetached = CaptureDeliveryMonitor.busStatusUpdateArrived()
            let reattach = Self.reattachReport(fromStatusUpdate: data)
            DispatchQueue.main.async {
                CaptureDeliveryMonitor.shared.statusUpdateReceived(reattach: reattach, capturedWhileDetached: capturedWhileDetached)
            }
            // Answered with the whole state, a reattach's as a start's: an
            // extension that outlived the app knows only what it was last
            // told, and a fresh one only its start options.
            Task {
                if let selectedHost = AppState.shared.selectedHost {
                    self.notifyExtension(
                        message: ServerBusMessage(
                            action: .selectedHostChanged,
                            payload: ["data": selectedHost]
                        )
                    )
                }

                // The host filters and the rules, read from the database. A
                // read that fails is logged and skipped — never the reason the
                // rest is not pushed: a start no app answered relays every new
                // connection until the CA state below arrives (core 95062d1),
                // and one failed read used to skip everything after it.
                do {
                    let allHosts = try await ReqResCoreModelBridge.findAllHosts()
                    self.notifyExtension(message: ServerBusMessage(
                        action: .allHostsChanged,
                        payload: ["data": allHosts]
                    ))
                } catch {
                    AppLog.shared.error("[AppController] statusUpdate: the host filters could not be read: \(error.localizedDescription, privacy: .public)")
                }
                do {
                    let rules = try await ReqResCoreModelBridge.findAllRules()
                    await self.notifyExtensionRulesChanged(rules: rules)
                } catch {
                    AppLog.shared.error("[AppController] statusUpdate: the rules could not be read: \(error.localizedDescription, privacy: .public)")
                }

                // The extension is a separate process that starts with an
                // empty list, so this has to be pushed on every status
                // update as well as on every edit — an exclusion that only
                // applied until the next tunnel restart would be worse
                // than none, because the user would trust it.
                await ExcludedHostsSettings.shared.push()
                // And the apps that refused ReqRes's certificate (learned
                // pins): same reason — the extension forgets them.
                await LearnedPinsSettings.shared.push()
                // And the HTTP/2 switch (doc §S9): the start options carry
                // it, but a status update also follows a restart the app
                // did not start, and the push is one small message.
                HTTP2CaptureSync.push()
                // Same reasoning for breakpoints, with a sharper edge: a
                // rule the user believes is armed, silently not armed, is
                // a debugging session spent wondering why nothing stops.
                await MainActor.run { BreakpointService.shared.push() }
                // And the CA's state (step C8), LAST: installed and
                // trusted since the tunnel started, or removed — the
                // extension otherwise knows only what its start options
                // said. A start that found no app relays every new
                // connection until this arrives (core 95062d1), so
                // everything that decides what is intercepted — the
                // exclusions and learned pins above all — must be in
                // place first.
                CAStateSync.push()
            }
        // WebSocket messages (protocol-engine doc §C11.3 / §S7): a 101 row's
        // frames, in batches, after the row. Decoded straight into MCPKit's
        // mirror of the wire and kept by the message center — never through
        // the traffic table's ingest, so a busy socket re-renders no row.
        // Listed explicitly because this switch ends in `default: break`.
        case .websocketMessages:
            if let batch = Self.decodeLivePayload(SocketMessageBatch.self, from: message) {
                WebSocketMessageCenter.shared.ingest(batch)
            }
        case .hello:
            // An extension proved itself on the bus (the core passes its
            // hello on once it is authenticated): rows can arrive from now —
            // a reattach's backlog first, counted until its status_update.
            // Said at once rather than at the delivery monitor's next look, so
            // "Reconnecting…" and "Capture is on, but ReqRes isn't receiving
            // it" go the moment they stop being true (F11, build 53). Listed
            // explicitly: this switch ends in `default: break`. Each hello
            // begins an attachment (`CaptureReattach.extensionSaidHello`): a
            // second one in a run is a reconnection however quick, and an
            // attachment ends a stretch only once it has lasted.
            CaptureDeliveryMonitor.busExtensionProvedItself()
            DispatchQueue.main.async { CaptureDeliveryMonitor.shared.extensionSaidHello() }
        case .pinLearned:
            // An app refused ReqRes's certificate and the extension now
            // passes its connections to that domain through, marked SSL
            // pinned. The app keeps the list across tunnel starts and shows
            // it in Settings ▸ Capture. Listed explicitly: this switch ends in
            // `default: break`, which would swallow it with no compile error.
            if let record = LearnedPinRecord(busPayload: message.payload["data"]?.value) {
                DispatchQueue.main.async { LearnedPinsSettings.shared.learned(record) }
            } else {
                AppLog.shared.error("[TCPServerBus] pin_learned carried no pin under \"data\"")
            }

        case .attributionAvailabilityChanged:
            // Once per tunnel start, after the extension has checked the
            // kernel's socket table against its own socket (UX spec §1.6).
            // Listed explicitly because this switch ends in `default: break`:
            // a missing case would swallow the report with no compile error,
            // and the App column would never learn it should hide. Payload
            // shape is `.excludedHostsChanged`'s — the value under "data".
            let raw = message.payload["data"]?.value
            if let available = raw as? Bool ?? (raw as? NSNumber)?.boolValue {
                DispatchQueue.main.async {
                    AppState.shared.processAttribution = available ? .available : .unavailable
                }
            } else {
                AppLog.shared.error("[TCPServerBus] attributionAvailabilityChanged carried no Bool under \"data\"")
            }
        default:
            break
        }
    }
}

extension AppController {
    /// The reattach a status_update frame reports, or nil — a start's
    /// included (build 53). The core's own reader first: it owns the
    /// contract. Utils' lenient one after it, for a frame a different build of
    /// the extension wrote with a key this core's synthesized decoder
    /// requires — the two agree on this core's frames
    /// (`assertReattachReaderMatchesCore`, at launch).
    static func reattachReport(fromStatusUpdate data: Data) -> CaptureReattachReport? {
        if let status = BusReattachStatus.from(statusUpdateFrame: data) {
            return CaptureReattachReport(
                droppedRows: status.droppedRows,
                droppedMessages: status.droppedMessages,
                proxyPort: status.proxyPort,
                runStartedAt: status.runStartedAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        return CaptureReattachReport.from(statusUpdateFrame: data)
    }

    /// Where Utils' reader of the reattach disagrees with the embedded core's
    /// — on the core's own frame, and on a start's — each named. Utils cannot
    /// see the core, so this is the only check that the field names the
    /// extension writes are the ones the app reads.
    static var reattachReaderDrift: [String] {
        var drift: [String] = []
        if BusReattachStatus.statusValue != CaptureReattachReport.statusValue {
            drift.append("status value: core \(BusReattachStatus.statusValue), Utils \(CaptureReattachReport.statusValue)")
        }
        if ClientBusAction.statusUpdate.rawValue != CaptureReattachReport.action {
            drift.append("action: core \(ClientBusAction.statusUpdate.rawValue), Utils \(CaptureReattachReport.action)")
        }
        let status = BusReattachStatus(droppedRows: 3, droppedMessages: 5, proxyPort: 8036, runStartedAt: 1_790_000_000)
        guard let frame = ClientBusMessage(action: .statusUpdate, payload: status).toJSONData() else {
            return drift + ["the core's reattach frame did not encode"]
        }
        let expected = CaptureReattachReport(droppedRows: 3, droppedMessages: 5, proxyPort: 8036,
                                             runStartedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let read = CaptureReattachReport.from(statusUpdateFrame: frame)
        if read != expected {
            drift.append("the core's reattach frame reads as \(String(describing: read)), not \(expected)")
        }
        if let start = ClientBusMessage(action: .statusUpdate, payload: ["status": "connected"]).toJSONData(),
           CaptureReattachReport.from(statusUpdateFrame: start) != nil {
            drift.append("a start's status_update reads as a reattach")
        }
        return drift
    }

    /// Fatal in a Debug build, like the other core checks: both readers are
    /// compiled into this build, so a drift is found the first time it runs —
    /// it means a reattach the extension reports is read wrong, or not at all.
    static func assertReattachReaderMatchesCore() {
        #if DEBUG
        let drift = reattachReaderDrift
        if !drift.isEmpty {
            assertionFailure("CaptureReattachReport drifted from the embedded core's BusReattachStatus — update Utils/CaptureReattach.swift: " + drift.joined(separator: "; "))
        }
        #endif
    }

    /// The value under `"data"`, decoded as `type` — the `send_session` path's
    /// shape. A payload that does not decode is logged by size only (it holds
    /// captured text) and dropped; the final row still arrives.
    static func decodeLivePayload<T: Decodable>(_ type: T.Type, from message: ClientBusMessageNonGeneric) -> T? {
        guard let object = message.payload["data"]?.value as? [String: Any],
              let json = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            AppLog.shared.error("[TCPServerBus] \(message.action.rawValue, privacy: .public) carried no object under \"data\"")
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: json)
        } catch {
            AppLog.shared.error("[TCPServerBus] could not decode \(message.action.rawValue, privacy: .public) (\(json.count, privacy: .public) bytes): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func notifyExtensionRulesChanged(rules: [RuleCodable]) async { // Changed parameter type and made async
        // Only ENABLED rules reach the extension (protocol PRD §1.5). The core
        // matches by host and URL and never reads `enabled`, so a rule
        // switched off in the Overrides list used to keep rewriting traffic.
        // Every caller (the toggle, edits, deletes, agent writes, the status
        // update) funnels through here, so this is the one place to filter.
        // Filtering first also means a disabled Map Local rule's file is not
        // read. The free tier still counts every stored rule — see
        // `ExtensionRulePush`.
        let allRules = rules
        let rules = ExtensionRulePush.rulesToPush(rules) { $0.enabled }
        AppLog.shared.debug("[AppController] Preparing rules changed notification with \(rules.count) enabled rules")

        // F24: the files are read through the bookmarks the rule form kept, and a
        // file that cannot be read is answered by ReqRes with 500 and a note
        // instead of the rule falling back to the server (`MapLocalFileAccess`).
        // The push is the one place that sees every stored rule, so it also
        // prunes the bookmarks of files no rule names and publishes which files
        // cannot be read, for the Overrides list and the rule form.
        let fileAccess = MapLocalFileAccess.shared
        fileAccess.prune(keeping: allRules.filter { $0.ruleMode == .MAP_LOCAL }.map(\.rspPath))
        var unreadableFiles = Set<String>()
        var processedRules: [RuleCodable] = []

        for rule in rules {
            let pushed = fileAccess.ruleForPush(rule)
            if pushed.fileUnreadable { unreadableFiles.insert(rule.rspPath) }
            processedRules.append(pushed.rule)
        }
        // A disabled Map Local rule is not pushed and its file is not read, but
        // the list still says whether the file could be — an open, not a read.
        for rule in allRules where rule.ruleMode == .MAP_LOCAL && !ExtensionRulePush.isEnabled(rule.enabled) {
            if rule.rspPath.isEmpty || !fileAccess.canRead(path: rule.rspPath) { unreadableFiles.insert(rule.rspPath) }
        }
        let unreadable = unreadableFiles
        await MainActor.run { AppState.shared.unreadableMapLocalFiles = unreadable }

        AppLog.shared.debug("[AppController] Sending \(processedRules.count) rules to extension")
        
        self.notifyExtension(message: ServerBusMessage(
            action: .rulesChanged,
            payload: ["data": processedRules]
        ))
    }
}

class ExtensionStatusManager: NSObject {
    private(set) static var shared = ExtensionStatusManager()
    static let extensionStatusChanged = Notification.Name("extensionStatusChanged")
    
    // Track VPN configuration status
    private var vpnConfigurationStatus: Bool = false

    /// Polls while setup is INCOMPLETE. Without this the app only re-checks when
    /// it becomes active again, so a user who enables the extension in System
    /// Settings and comes straight back can sit on a stale "not enabled" screen
    /// and conclude the app is broken — the reported "nothing happens when I
    /// click Start Monitoring, until I relaunch".
    private var readinessPoll: Timer?
    private static let readinessPollInterval: TimeInterval = 2

    override init() {
        super.init()
        setupStatusCheck()
    }

    /// Begins converging on `.ready`. Safe to call repeatedly.
    func beginWatchingSetup() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.readinessPoll == nil else { return }
            self.readinessPoll = Timer.scheduledTimer(
                withTimeInterval: Self.readinessPollInterval,
                repeats: true
            ) { [weak self] _ in
                Task { await self?.checkAndNotifyStatus() }
            }
        }
        Task { await checkAndNotifyStatus() }
    }

    private func stopWatchingSetup() {
        DispatchQueue.main.async { [weak self] in
            self?.readinessPoll?.invalidate()
            self?.readinessPoll = nil
        }
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
                // Converge automatically: keep watching until setup completes,
                // then stop so we are not timing out forever in the background.
                if status == .ready {
                    self.stopWatchingSetup()
                } else {
                    self.beginWatchingSetup()
                }
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
    
    /// Whether a capture configuration is saved. READ-ONLY (F11 review): the
    /// readiness poll (every 2 s until setup is done), every app activation,
    /// the launch check and the traffic pane all ask this, and it used to
    /// CREATE one when there was none — so after the user chose Don't Allow,
    /// the next poll put macOS's "add VPN configurations" prompt up again,
    /// and again. Only a click creates one: Start (`requestCapture`) and the
    /// setup checklist's Install VPN Configuration (`installVPNConfiguration`).
    public func isVPNConfigurationInstalled() async -> Bool {
        return await withCheckedContinuation { continuation in
            VPNManager.shared.loadExistingManager { manager, error in
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

    /// Creates the capture configuration — macOS asks the user to allow it.
    /// For the setup checklist's Install VPN Configuration only, a click; the
    /// status checks never create one (`isVPNConfigurationInstalled`). True
    /// when a configuration is saved afterwards.
    @discardableResult
    public func installVPNConfiguration() async -> Bool {
        return await withCheckedContinuation { continuation in
            VPNManager.shared.loadManager { manager, error in
                if let error = error {
                    AppLog.shared.error("[ExtensionStatusManager] could not install the VPN configuration: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: manager?.protocolConfiguration != nil)
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
            // The delegate keeps ITSELF alive until the request resolves. It
            // used to be parked in one shared property while the request's
            // `delegate` is weak — and three status checks overlap at launch
            // (bootstrap, the traffic view's onAppear, the readiness poll), so
            // each overwrite deallocated the previous delegate with its
            // continuation never resumed ("getExtensionProperties() leaked its
            // continuation", twice per launch) and left that caller suspended
            // forever, its request reporting to a nil delegate.
            request.delegate = ExtensionDelegate(continuation)
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
                
                // One-shot and self-retaining, like the properties delegate.
                extensionRequest.delegate = ActivationDelegate {
                    continuation.resume(returning: ())
                }
                
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
private final class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
    private let completionHandler: () -> Void
    private let completion = OneShotCompletion()
    /// The request's `delegate` is weak; this is what keeps the delegate
    /// alive until the request reports back.
    private var retainedSelf: ActivationDelegate?

    init(_ completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
        super.init()
        retainedSelf = self
    }

    /// Runs the completion once, whichever callback gets there first.
    private func finish() {
        if completion.fire(completionHandler) {
            retainedSelf = nil
        }
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
        
        finish()
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
        
        finish()
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

/// Delegate for one properties request. Resolves its continuation EXACTLY
/// once — `foundProperties` wins; `didFinishWithResult` without properties
/// means no extension is installed; failure and a user-approval demand
/// resolve with an error; a safety timeout resolves a request sysextd never
/// answers — and keeps itself alive until then, because the request's
/// `delegate` is weak. Before this, two of the paths resumed the continuation
/// directly (a second resume traps) and `didFinishWithResult` never did.
private final class ExtensionDelegate: NSObject, OSSystemExtensionRequestDelegate {
    private let continuation: CheckedContinuation<[OSSystemExtensionProperties], Error>
    private let completion = OneShotCompletion()
    private var retainedSelf: ExtensionDelegate?
    private static let timeout: TimeInterval = 30

    init(_ continuation: CheckedContinuation<[OSSystemExtensionProperties], Error>) {
        self.continuation = continuation
        super.init()
        retainedSelf = self
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            self?.resolve(.failure(NSError(
                domain: "ExtensionStatusManager", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Timed out reading the network extension's status"])))
        }
    }

    private func resolve(_ result: Result<[OSSystemExtensionProperties], Error>) {
        let ran = completion.fire { continuation.resume(with: result) }
        if ran { retainedSelf = nil }
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        AppLog.shared.debug("Request for replacing extension received")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        AppLog.shared.debug("Request needs user approval")
        resolve(.failure(NSError(domain: "ExtensionStatusManager", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "Extension needs user approval"])))
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        AppLog.shared.debug("Request finished with result: \(result.rawValue, privacy: .public)")
        // A no-op after `foundProperties`; on its own it means nothing is installed.
        resolve(.success([]))
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFailWithError error: Error) {
        AppLog.shared.debug("Request failed with error: \(error.localizedDescription, privacy: .public)")
        resolve(.failure(error))
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
        resolve(.success(properties))
    }
}
