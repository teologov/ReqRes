//
//  UIApp.swift
//  UI
//
//  Created by OloApps on 14.06.2023.
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
import Combine
import XReqResCore

@main
struct UIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            AppView()
        }
        .defaultSize(CGSize(width: 1200, height: 600))
        .commands {
            // Replace the default About menu item
            CommandGroup(replacing: .appInfo) {
                Button("About ReqRes") {
                    AboutWindowController.shared.showAboutWindow()
                }
            }
          MainMenu()
        }
        
        Settings {
            SettingsView()
        }
        
        ModalsScene()
    }
}

struct ModalsScene: Scene {
    @ObservedObject var appStateModel: AppState = AppState.shared
    
    var body: some Scene {
        Window("Add new host", id: "new-host") {
            AddHostModal()
                .frame(minWidth: 375, minHeight: 150, alignment: .topLeading)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .keyboardShortcut("n", modifiers: [.shift, .command])
        .windowStyle(.hiddenTitleBar)
        
        Window("Add new override", id: "rule-modal") {
            if let host = appStateModel.selectedHost {
                RuleModal(selectedHost: host)
                    .frame(minWidth: 550, minHeight: 700, alignment: .topLeading)
                    .id(host.id)
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .keyboardShortcut("r", modifiers: [.shift, .command])
        .windowStyle(.hiddenTitleBar)
    }
}
