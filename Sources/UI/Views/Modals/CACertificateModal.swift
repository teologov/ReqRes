//
//  CACertificateModal.swift
//  ReqRes
//
//  Created by OloApps on 6/17/24.
//  Inspired by https://github.com/softnetics/dotlocal/blob/792f44fcb9fbcc291d6b1f9e2fd2523c672e6871/DotLocal/SettingsView.swift#L99
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
import Foundation
import SecurityInterface
import Settings
import Utils
import XReqResCore

struct CACertificateModal: View {
    @State var rootCertificate: CertHelper.Certificate?
    @State private var window: NSWindow?
    
    var body: some View {
        VStack(alignment: .center) {
            Settings.Section(title: "Root CA:") {
                if let rootCertificate = rootCertificate, let window = window {
                    CertificateView(
                        certificate: rootCertificate,
                        window: window,
                        reload: onAppear
                    )
                }
            }
            Spacer() // Push content to the top
        }
        .onAppear(perform: onAppear)
        .background(WindowAccessor(window: $window))
        .frame(maxWidth: .infinity, maxHeight: .infinity) // Fill available space
    }
    
    func onAppear() {
        Task {
           await loadCertificate()
        }
    }
    
    
    private func loadCertificate() async {
        do {
            rootCertificate = try await CertHelper.getRootCertificate()
        } catch {
            AppLog.shared.error("failed to load certificate: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#Preview {
    CACertificateModal().frame(minWidth: 375, minHeight: 150, alignment: .topLeading)
}

struct CertificateView: View {
    @State private var didError = false
    @State private var errorTitle = ""
    @State private var errorMessage = ""
    @State private var certificateInstalledInKeychain: Bool = false
    
    var certificate: CertHelper.Certificate
    var window: NSWindow
    var reload: () -> Void
    
    var body: some View {
        VStack(alignment: .leading) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    Button("Install CA certificate", action: installCertificate)
                        .disabled(self.certificateInstalledInKeychain)

                    if (self.certificateInstalledInKeychain) {
                        (Text(Image(systemName: "checkmark.circle.fill"))+Text(" Installed"))
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                    }
                    if (!self.certificateInstalledInKeychain) {
                        (Text(Image(systemName: "xmark.circle.fill"))+Text(" Not installed"))
                            .foregroundStyle(.red)
                            .font(.system(size: 12))
                    }
                }
                GridRow {
                    Button(action: {
                        let status = SecTrustSettingsSetTrustSettings(certificate.secCertificate, .user, [
                            [kSecTrustSettingsPolicy: SecPolicyCreateBasicX509()],
                            [kSecTrustSettingsPolicy: SecPolicyCreateSSL(true, nil)],
                        ] as CFTypeRef)
                        
                        guard status == errSecSuccess || status == errAuthorizationCanceled else {
                            errorTitle = "Failed to set trust settings for ReqRes CA certificate"
                            errorMessage = "\(status): " + (SecCopyErrorMessageString(status, nil)! as String)
                            didError = true
                            return
                        }
                        reload()
                        // programmatically restart Network Extension, if certificate was trusted,
                        // but user has the extension running
                        // might be better to wait until the manager.connection.status is disconnected
                        if let manager = VPNManager.shared.manager {
                            if manager.connection.status == .connecting ||  manager.connection.status == .connected {
                                VPNManager.shared.stopVPNTunnel()
                                // restart tunnel in 2 seconds
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    AppController.shared.toggleVPNTunnel()
                                }
                            }
                        }
                    }, label: {
                        Text("Trust")
                    })
                    .disabled(!self.certificateInstalledInKeychain || certificate.trusted)
                    
                    if certificate.trusted {
                        (Text(Image(systemName: "checkmark.circle.fill"))+Text(" Trusted"))
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                    } else {
                        (Text(Image(systemName: "xmark.circle.fill"))+Text(" Not trusted"))
                            .foregroundStyle(.red)
                            .font(.system(size: 12))
                    }
                }
                GridRow {
                    Button(action: {
                        SFCertificatePanel.shared().beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, certificates: [certificate.secCertificate], showGroup: false)
                    }, label: {
                        Text("Certificate Details")
                    })
                    .disabled(!self.certificateInstalledInKeychain)
                }
            }
            .padding([.leading], 10)
            .alert(
                errorTitle,
                isPresented: $didError,
                presenting: errorMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
        }
        .onAppear(perform: onAppear)
    }
    
    func onAppear() {
        self.certificateInstalledInKeychain = CertHelper.getInstalledCertificate() != nil
    }
    
    private func installCertificate() {
        let status = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate.secCertificate
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            errorTitle = "Failed to add certificate to Keychain"
            errorMessage = "\(status): " + (SecCopyErrorMessageString(status, nil)! as String)
            didError = true
            return
        }
        self.certificateInstalledInKeychain = true;
    }
}

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        // Use a repeating timer to check for the window
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if let nsWindow = view.window {
                DispatchQueue.main.async {
                    self.window = nsWindow
                    timer.invalidate() // Stop the timer once the window is assigned
                }
            }
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No changes needed in updateNSView for this approach
    }
}
