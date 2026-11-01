//
//  AppState.swift
//  ReqRes
//
//  Created by OloApps on 14.06.2021.
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
import Utils
import Combine
import NetworkExtension
import XReqResCore

class AppState: ObservableObject {
    static let shared = AppState()
    
    // Add free HTTPS session inspection counter
    // Simply track the count during the current app session
    @Published var freeHttpsSessionsInspected: Int = 0
   
    // Maximum number of free HTTPS sessions that can be inspected. Same
    // constant the paywall quotes — see FreeTier.
    let maxFreeHttpsSessions: Int = FreeTier.httpsSessionDetailsPerLaunch
   
    // Check if the user has reached the free HTTPS session limit
    var hasReachedFreeHttpsLimit: Bool {
        return freeHttpsSessionsInspected >= maxFreeHttpsSessions
    }
    
    // TODO: add indeterminate status
    @Published var vpnStatus: NEVPNStatus {
        didSet {
            AppLog.shared.debug("VPN Status set to: \(self.vpnStatus, privacy: .public)")
            // When capture started, for the menu bar's "Capturing — since
            // 14:02". Nothing recorded this before: the app knew capture was
            // ON but not since when, and "since" is the part that tells
            // someone they left it running two hours ago.
            //
            // Set HERE rather than in a view, because the status the menu bar
            // reads must be true whether or not a window exists.
            // Only for a transition THIS process watched happen. Stamping it
            // on any sighting of `.connected` would date a tunnel that was
            // already running when the app launched to the moment the app
            // noticed — "since 14:02" would be a lie told confidently.
            // `statusTitle` already falls back to a bare "Capturing" when the
            // time is unknown.
            if vpnStatus == .connected {
                if oldValue == .connecting { capturingSince = Date() }
            } else if vpnStatus == .disconnected || vpnStatus == .invalid {
                capturingSince = nil
                // Every request still open went down with the tunnel: its
                // live row ends as it stands (protocol-engine doc §S6),
                // rather than claiming to wait or stream forever.
                if oldValue != vpnStatus {
                    SessionState.shared.endAllInFlight(reason: .captureStopped)
                }
                // The attribution report is per tunnel start; the next start
                // re-checks. Guarded so a stop publishes nothing new to rows
                // that already read `.unreported`.
                if processAttribution != .unreported {
                    processAttribution = .unreported
                }
            }
        }
    }

    /// When the current capture run started, or nil when not capturing.
    /// Transitional states leave it alone — a reconnect is not a new run.
    @Published private(set) var capturingSince: Date?

    /// A status READ from the system — at launch, in a status notification,
    /// or when a capture request found the display wrong (F11). Main thread.
    ///
    /// Shown as `CaptureTunnelState.displayed`: `.invalid` reads as
    /// disconnected, so the capture button stays a usable Start. And when the
    /// tunnel is up with no start time yet — it was already running when this
    /// app launched — the time comes from the system's own record of the
    /// connection (`NEVPNConnection.connectedDate`), never from the moment
    /// the app noticed: "since 14:02" must be when capture started.
    func adoptTunnelStatus(_ status: NEVPNStatus, connectedDate: Date?) {
        let shown = NEVPNStatus(CaptureTunnelState(status).displayed)
        if vpnStatus != shown { vpnStatus = shown }
        if shown == .connected, capturingSince == nil, let connectedDate {
            capturingSince = connectedDate
        }
    }

    /// When the running capture started, as its extension reported it when
    /// it reattached to this app (build 53, core 95062d1) — what "Capturing —
    /// since 14:02" means, for a capture this app did not start. It replaces
    /// a time read from the tunnel's own record (`connectedDate`): the
    /// extension knows when ITS run began. Only while the tunnel reads
    /// connected — a report about a capture that has stopped dates nothing.
    /// Main thread.
    func adoptRunStart(_ startedAt: Date) {
        guard vpnStatus == .connected, capturingSince != startedAt else { return }
        capturingSince = startedAt
    }

    /// Whether the extension can tell which process opens connections on this
    /// Mac (UX spec §1.6). `.unreported` at launch; `AppController` sets it
    /// from the bus once per tunnel start, and a stopped tunnel resets it in
    /// `vpnStatus.didSet` — a verdict about the socket table the LAST tunnel
    /// read is not a claim about the next one. `SessionView` hands it to rows
    /// as a value; rows never observe this object.
    @Published var processAttribution: ProcessAttributionAvailability = .unreported

    /// Set when capture did not start because another program holds the
    /// proxy's port (`CaptureProxyPort.conflict`); `AppView` asks the user.
    @Published var proxyPortConflict: ProxyPortConflict?
    
    @Published var extensionStatus: ExtensionSetupStatus {
        didSet {
            AppLog.shared.debug("VPN Status set to: \(self.vpnStatus, privacy: .public)")
        }
    }
    
    @Published var selectedHost: HostCodable? = nil {
        didSet {
            lastHostChangedAt = Date.now
            DispatchQueue.main.async { [weak self] in
                Task {
                    await self?.selectedHostChanged()
                }
            }
        }
    }
    @Published var hosts = Array<HostCodable>()
    @Published var rules = Array<RuleCodable>()
    /// The stored paths of the Map Local rules whose file ReqRes could not read
    /// at the last rules push (F24): the Overrides list marks them, the rule form
    /// says so, and a matching request is answered with 500 and a note instead of
    /// the server's response. Written on the main thread by `AppController`.
    @Published var unreadableMapLocalFiles: Set<String> = []
    var lastHostChangedAt: Date = Date()
    
    init() {
        vpnStatus = .disconnected
        extensionStatus = .ready
    }
    
    @MainActor
    public func deleteHost(_ host: HostCodable) {
        Task {
            do {
                if let hostId = host.hostDbId?.int64Value {
                    try await ReqResCoreModelBridge.deleteHost(hostId)
                    
                    self.hosts.removeAll(where: { $0.hostDbId == host.hostDbId })
                    self.selectedHost = self.hosts.first
                }
            } catch {
                AppLog.shared.error("Failed to delete host: \(error)")
            }
        }
    }

    @MainActor
    public func deleteRule(_ rule: RuleCodable) {
        Task {
            do {
                try await ReqResCoreModelBridge.deleteRule(rule.modelRealId!)

                self.rules.removeAll(where: { $0.id == rule.id })
                // The extension replaces its rule list with what it is sent, so
                // without a push a deleted rule kept applying until the next edit
                // (found with F24, 2026-10-26).
                let allRules = try await ReqResCoreModelBridge.findAllRules()
                await AppController.shared.notifyExtensionRulesChanged(rules: allRules)
            } catch {
                AppLog.shared.error("Failed to delete rule: \(error)")
            }
        }
    }
    
    public func selectedHostChanged() async {
        guard let host = self.selectedHost else { return }
        
        do {
            // Get data from database operations
            let newRules: [RuleCodable]
            if let hostDbId = host.hostDbId, hostDbId.int64Value != 0 {
                newRules = try await ReqResCoreModelBridge.findRulesByHost(id: hostDbId.int64Value)
            } else {
                newRules = try await ReqResCoreModelBridge.findAllRules()
            }
            
            let allHosts = try await ReqResCoreModelBridge.findAllHosts()
            let allRules = try await ReqResCoreModelBridge.findAllRules()
            
            // Update UI properties on main thread
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.rules = newRules
                SessionState.shared.updateFilteredSessions(selectedHost: host)
            }
            
            AppController.shared.notifyExtension(
                message: ServerBusMessage(
                    action: .selectedHostChanged,
                    payload: ["data": host]
                )
            )
            
            AppController.shared.notifyExtension(
                message: ServerBusMessage(
                    action: .allHostsChanged,
                    payload: ["data": allHosts]
                )
            )
            
            await AppController.shared.notifyExtensionRulesChanged(rules: allRules)
            
        } catch {
            AppLog.shared.error("Failed to update selected host: \(error)")
        }
    }
    
    @MainActor
    public func upsertRule(_ rule: RuleCodable) {
        Task {
            do {
                try await ReqResCoreModelBridge.saveRule(rule)
                
                let newRules: [RuleCodable]
                if let selectedHost = self.selectedHost,
                   let hostDbId = selectedHost.hostDbId,
                   hostDbId.int64Value != 0 {
                    newRules = try await ReqResCoreModelBridge.findRulesByHost(id: hostDbId.int64Value)
                } else {
                    newRules = try await ReqResCoreModelBridge.findAllRules()
                }
                
                let allRules = try await ReqResCoreModelBridge.findAllRules()

                self.rules = newRules
                self.objectWillChange.send()
                
                await AppController.shared.notifyExtensionRulesChanged(rules: allRules)
                
            } catch {
                AppLog.shared.error("Failed to update rule: \(error)")
            }
        }
    }
    
    /// Rules changed outside the forms (the MCP bridge): refresh the list for
    /// the selected host and push the full set to the extension — the tail of
    /// `upsertRule`, without the save.
    public func reloadRulesAfterExternalChange() async {
        do {
            let allRules = try await ReqResCoreModelBridge.findAllRules()
            let selected = await MainActor.run { self.selectedHost }
            let newRules: [RuleCodable]
            if let hostDbId = selected?.hostDbId, hostDbId.int64Value != 0 {
                newRules = try await ReqResCoreModelBridge.findRulesByHost(id: hostDbId.int64Value)
            } else {
                newRules = allRules
            }
            await MainActor.run {
                self.rules = newRules
                self.objectWillChange.send()
            }
            await AppController.shared.notifyExtensionRulesChanged(rules: allRules)
        } catch {
            AppLog.shared.error("Failed to reload rules: \(error)")
        }
    }

    // Load initial data
    public func loadData() {
        Task {
            do {
                let allHosts = try await ReqResCoreModelBridge.findAllHosts()
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.hosts = allHosts
                    self.selectedHost = allHosts.first
                }
            } catch {
                AppLog.shared.error("Failed to load initial data: \(error)")
            }
        }
    }
    
    // Increment the free HTTPS session counter when a user inspects an HTTPS session
    func incrementHttpsSessionCounter() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Only increment if still under the limit
            if self.freeHttpsSessionsInspected < self.maxFreeHttpsSessions {
                self.freeHttpsSessionsInspected += 1
            }
        }
    }
    
    // For testing/debug purposes - reset the counter if needed
    func resetHttpsSessionCounter() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.freeHttpsSessionsInspected = 0
        }
    }
}
