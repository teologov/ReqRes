//
//  AddHostModal.swift
//  ReqRes
//
//  Created by OloApps on 03.07.2023.
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

struct AddHostModal: View {
    @Environment(\.dismiss) var dismiss
    @State private var hostName: String = ""
    @State private var port: Int = 80
    @State private var reqProtocol: RequestProtocolType = .HTTPS
    @State private var showLimitAlert: Bool = false
    @ObservedObject private var licenseManager = LicenseManager.shared
    
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
    
    var disableForm: Bool {
        let trimmedHost = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
       
       
        if trimmedHost.isEmpty {
            return true
        }
       
        return !trimmedHost.isValidHostname
    }
    
    var body: some View {
        Form {
            Picker("Request Protocol", selection: $reqProtocol) {
                ForEach(RequestProtocolType.allCases) { option in
                    Text(option.rawValue)
                }
            }
            .frame(width: 200)
            TextField("Hostname", text: $hostName, prompt: Text("example.com"))
                .disableAutocorrection(true)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
//            TextField("Port", value: $port, formatter: Self.formatter)
//                .disableAutocorrection(true)
//                .textFieldStyle(RoundedBorderTextFieldStyle())
//                .disabled(true)
        }
        .padding()
        
        VStack {
            Spacer()
            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                
                Button {
                    handleSave()
                } label: {
                    Text("Save")
                }
                .disabled(disableForm)
            }
            .padding()
        }
        .alert("Free Version Limit", isPresented: $showLimitAlert) {
            Button("Upgrade") {
                // Add your upgrade navigation logic here
                dismiss()
                licenseManager.showPurchaseWindow()
            }
            Button("Cancel", role: .cancel) {
                // Do nothing, just dismiss the alert
            }
        } message: {
            Text("The free version is limited to 2 hosts. Please upgrade to add more hosts.")
        }
    }
    
    func handleSave() {
        // Check license limits using bridge API
        Task {
            do {
                let currentHosts = try await ReqResCoreModelBridge.findAllHosts()
                let currentHostCount = currentHosts.count
                let isProUser = licenseManager.isProUser()
                
                if currentHostCount >= 2 && !isProUser {
                    await MainActor.run {
                        showLimitAlert = true
                    }
                } else {
                    // Proceed with adding the host
                    await createHost()
                }
            } catch {
                AppLog.shared.error("Error checking host count: \(error)")
            }
        }
    }
    
    func createHost() async {
        do {
            let newHost = HostCodable(
                host: hostName.trimmingCharacters(in: .whitespacesAndNewlines),
                port: NSNumber(value: 80), // hardcode the port for now
                hostDbId: nil, // New host, so no database ID yet
                requestProtocol: reqProtocol.rawValue
            )
            
            // Save using bridge API
            let savedHost = try await ReqResCoreModelBridge.saveHost(newHost)
            AppState.shared.hosts.append(savedHost)
            
            let allHosts = try await ReqResCoreModelBridge.findAllHosts()
            
            await MainActor.run {
                AppController.shared.notifyExtension(message: ServerBusMessage(
                    action: .allHostsChanged,
                    payload: [
                        "data": allHosts
                    ]
                ))
                
                dismiss()
            }
        } catch {
            // Handle error
            AppLog.shared.error("Error creating host: \(error)")
        }
    }
}

