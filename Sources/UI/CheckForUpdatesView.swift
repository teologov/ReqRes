//
//  CheckForUpdatesView.swift
//  ReqRes
//
//  Created by OloApps on 3/10/25.
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

import SwiftUI
import Sparkle
import XReqResCore

class SparkleViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController
    
    @Published var canCheckForUpdates = true
    @Published var lastUpdateCheckDate: Date?
    
    override init() {
        // Create the updater controller directly in the view model
        // This eliminates the need for AppDelegate code related to Sparkle
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil, // We'll set this after initialization
            userDriverDelegate: nil
        )
        
        super.init()
        
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        
        // Set up automatic update checking
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }
    
    func checkForUpdates() {
        canCheckForUpdates = false
        updaterController.checkForUpdates(nil)
        
        // Re-enable update checking after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.canCheckForUpdates = true
        }
    }
    
    // MARK: - SPUUpdaterDelegate Methods
    
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor appcastItem: SUAppcastItem?, error: Error?) {
        DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
            // Update the last check date
            self.lastUpdateCheckDate = Date()
        }
        
        if let error = error {
            AppLog.shared.error("Error checking for updates: \(error.localizedDescription, privacy: .public)")
        } else if let item = appcastItem {
            AppLog.shared.error("Update check completed successfully. Latest version: \(item.displayVersionString, privacy: .public)")
        } else {
            AppLog.shared.error("Update check completed. No new updates available.")
        }
    }
}
