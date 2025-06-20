//
//  General.swift
//  ReqRes
//
//  Created by OloApps on 8/19/24.
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
import Settings
import XReqResCore

struct SettingsView: View {
    @AppStorage("selectedSettingsTab") private var selectedSettingsTab: SettingsTab = .general
    @State private var currentHeight: CGFloat = 230
    
    @ObservedObject private var licenseManager = LicenseManager.shared
    
    var body: some View {
        TabView(selection: $selectedSettingsTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(SettingsTab.general)
            
            CertificateSettingsView()
                .tabItem {
                    Label("Certificate", systemImage: "newspaper")
                }
                .tag(SettingsTab.certificate)
            
            SubscriptionSettingsView(isInPreferences: true)
                .tabItem {
                    Label("Subscription", systemImage: "checkmark.seal")
                }
                .tag(SettingsTab.subscription)
        }
        .scenePadding()
        
        // 1) When the view first appears, set the correct height
        .onAppear {
            updateHeight(for: selectedSettingsTab)
        }
        
        // 2) When user switches tabs, update height
        .onChange(of: selectedSettingsTab) { _, newTab in
            updateHeight(for: newTab)
        }
        
        // 3) If user’s subscription status changes WHILE on Subscription tab, update height
        .onChange(of: licenseManager.hasValidLicense) { _, _ in
            if selectedSettingsTab == .subscription {
                updateHeight(for: .subscription)
            }
        }
        
        // Constrain the window size
        .frame(maxWidth: 450, maxHeight: currentHeight)
    }
    
    /// Decide how tall the window should be for each tab.
    /// For the Subscription tab, pick a taller height if unsubscribed, shorter if subscribed.
    private func updateHeight(for tab: SettingsTab) {
        switch tab {
        case .general, .certificate, .appearance:
            currentHeight = 230
        case .subscription:
            // If unsubscribed, show the full purchase UI (e.g. 700).
            // If subscribed, a smaller view (e.g. 420) is enough.
            currentHeight = licenseManager.hasValidLicense ? 420 : 775
        }
    }
}

enum SettingsTab: Int {
    case general, appearance, certificate, subscription
}

struct GeneralSettingsView: View {
    var body: some View {
        AppearanceSettingsView()
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("selectedAppearance") private var storedAppearance: AppearanceMode = .system
    @State private var selectedAppearance: AppearanceMode = .system

    var body: some View {
        VStack(alignment: .center) {
            Settings.Section(title: "Appearance:") {
                Menu {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Button(action: {
                            selectedAppearance = mode
                            storedAppearance = mode // Synchronize with AppStorage
                            applyAppearanceMode(mode)
                        }) {
                            HStack {
                                mode.icon
                                Text(mode.displayName)
                                Spacer()
                                if selectedAppearance == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        selectedAppearance.icon
                        Text(selectedAppearance.displayName)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(.horizontal)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
                .onAppear {
                    selectedAppearance = storedAppearance // Load stored value on appear
                }
            }
           
            Spacer() // Push content to the top
        }
    }

    private func applyAppearanceMode(_ mode: AppearanceMode) {
        switch mode {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil // Resets to the system's appearance
        }
    }
}

enum AppearanceMode: String, CaseIterable, Codable {
    case light = "Light"
    case dark = "Dark"
    case system = "System"

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var icon: some View {
        switch self {
        case .light:
            return Image(systemName: "sun.max.fill")
        case .dark:
            return Image(systemName: "moon.fill")
        case .system:
            return Image(systemName: "globe")
        }
    }
}
 
struct CertificateSettingsView: View {
    var body: some View {
        CACertificateModal()
    }
}

#Preview {
    SettingsView()
}
