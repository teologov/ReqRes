//
//  SessionState.swift
//  ReqRes
//
//  Created by OloApps on 10/2/24.
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
import AppKit
import Combine
import XReqResCore

class SessionState: ObservableObject {
    static let shared = SessionState()
    
    @Published var sessions = [SessionCodable]()
    @Published var sessionsByHost: [String: [SessionCodable]] = [:]
    @Published var filteredSessions = [SessionCodable]()
    @Published var sessionsSubtitle = ""
    @Published var searchText: String = "" {
        didSet {
            updateFilteredSessions(selectedHost: AppState.shared.selectedHost)
        }
    }
    private let sessionQueue = OperationQueue() // Queue for session additions
    
    init() {
        sessionQueue.maxConcurrentOperationCount = 1
    }

    
    func addSession(session: SessionCodable) {
        let key = session.host
        sessionQueue.addOperation { [weak self] in
            guard let welf = self else { return }
            DispatchQueue.main.async {
                // Add to global session list
                welf.sessions.insert(session, at: 0)
                
                // Add to sessionsByHost
                //        if key != "" && key != "All traffic" {
                welf.sessionsByHost[key, default: []].insert(session, at: 0)
                //        }
                
                welf.updateFilteredSessions(selectedHost: AppState.shared.selectedHost)
            }
        }
    }
    
    func removeSession(sessionUids: Set<UUID>) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.sessions.removeAll {
                if sessionUids.contains($0.id) {
                    let host = $0.host
                    self.sessionsByHost[host, default: []].removeAll { sessionUids.contains($0.id) }
                    return true
                }
                return false
            }
            
            self.updateFilteredSessions(selectedHost: AppState.shared.selectedHost)
        }
    }
    
    func updateFilteredSessions(selectedHost: HostCodable?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Determine the filtering criteria
            let searchLowercased = searchText.lowercased()
            
            if let host = selectedHost?.host, host != "All traffic" {
                if searchLowercased.isEmpty {
                    filteredSessions = sessionsByHost[host] ?? []
                } else {
                    // Filter by host
                    filteredSessions = sessionsByHost[host]?.filter { session in
                        // Apply search if there's any text entered
                        searchLowercased.isEmpty || self.sessionMatchesSearch(session: session, searchText: searchLowercased)
                    } ?? []
                }
            } else {
                if searchLowercased.isEmpty {
                    filteredSessions = sessions
                } else {
                    // Show all sessions, filtered by search text
                    filteredSessions = sessions.filter { session in
                        searchLowercased.isEmpty || self.sessionMatchesSearch(session: session, searchText: searchLowercased)
                    }
                }
            }
            
            // Update the subtitle reflecting the filtered session count
            updateSessionsSubtitle()
        }
        
    }
    
    func clearAllSessionsForGroup() {
        DispatchQueue.main.async { [weak self] in
              guard let self = self else { return }
            if let host = AppState.shared.selectedHost?.host {
                if host == "All traffic" {
                    sessions = []
                    sessionsByHost = [:]
                } else {
                    sessionsByHost[host] = []
                }
                filteredSessions = []
                updateSessionsSubtitle()
            }
      }
    }
    
    func updateSessionsSubtitle() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sessionsSubtitle = "\(self.filteredSessions.count) \(self.filteredSessions.count == 1 ? "request" : "requests" )"
        }
    }
    
    // Helper function to determine if a session matches the search text
    private func sessionMatchesSearch(session: SessionCodable, searchText: String) -> Bool {
        return session.fullUrl.lowercased().contains(searchText) ||
               session.method.lowercased().contains(searchText) ||
               session.state?.lowercased().contains(searchText) ?? false ||
               session.host.lowercased().contains(searchText)
    }
}
