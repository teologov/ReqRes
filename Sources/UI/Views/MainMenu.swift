//
//  MainMenu.swift
//  ReqRes
//
//  Created by OloApps on 6/17/24.
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

struct MainMenu: Commands {
    @AppStorage("selectedSettingsTab") private var selectedSettingsTab = SettingsTab.general
    @Environment(\.openSettings) private var openSettings
    // Create Sparkle view model
    @StateObject private var sparkleViewModel = SparkleViewModel()
    
    var body: some Commands {
        // Add the "Check for Updates..." command to the application menu
        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                sparkleViewModel.checkForUpdates()
            }
            .disabled(!sparkleViewModel.canCheckForUpdates)
            
            if let lastCheck = sparkleViewModel.lastUpdateCheckDate {
                Text("Last checked: \(lastCheck, format: .dateTime)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        SidebarCommands()
        ToolbarCommands()
       
        CommandMenu("Certificate") {
            Button("Install CA Certificate...") {
                selectedSettingsTab = .certificate
                openSettings()
            }
        }
    }
}
