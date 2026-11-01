//
//  AboutView.swift
//  ReqRes
//
//  Created by OloApps on 6/9/25.
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

import SwiftUI

// MARK: - About Window View
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    
    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (Build \(build))"
    }
    
    var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App"
    }
    
    var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2025–2026 Andrey Teologov. All Rights Reserved"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // App Icon
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 128, height: 128)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .padding(.top, 30)
                .padding(.bottom, 20)
            
            // App Name
            Text(appName)
                .font(.system(size: 20, weight: .medium))
                .padding(.bottom, 10)
            
            // Version Info
            VStack(spacing: 2) {
                Text(appVersion)
                    .font(.system(size: 13))
            }
            .padding(.bottom, 20)
            
            Text(copyright)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            
            // Licenses Button
            Button("Licenses...") {
                openLicenses()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.bottom, 20)
        }
        .frame(width: 300, height: 360)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func openLicenses() {
        if let htmlPath = Bundle.main.path(forResource: "license-third-party", ofType: "html"),
            let url = URL(string: "file://\(htmlPath)") {
            NSWorkspace.shared.open(url)
        }
    }
}
