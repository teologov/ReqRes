//
//  AppState.swift
//  ReqRes
//
//  Created by OloApps on 14.06.2021.
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
import Combine
import NetworkExtension
import XReqResCore

class AppState: ObservableObject {
    static let shared = AppState()
    
    // Add free HTTPS session inspection counter
    // Simply track the count during the current app session
    @Published var freeHttpsSessionsInspected: Int = 0
   
    // Maximum number of free HTTPS sessions that can be inspected
    let maxFreeHttpsSessions: Int = 10
   
    // Check if the user has reached the free HTTPS session limit
    var hasReachedFreeHttpsLimit: Bool {
        return freeHttpsSessionsInspected >= maxFreeHttpsSessions
    }
    
    // TODO: add indeterminate status
    @Published var vpnStatus: NEVPNStatus {
        didSet {
            AppLog.shared.debug("VPN Status set to: \(self.vpnStatus, privacy: .public)")
        }
    }
    
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
