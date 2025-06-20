//
//  AppView.swift
//  ReqRes
//
//  Created by OloApps on 14.06.2023.
//  example apps https://github.com/donarb/swiftui-macos
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
import XReqResCore
import SplitView

let FEEDBACK_URL = "https://github.com/OloApps/ReqRes/issues/new/choose"

struct AppView: View {
    var appController: AppController = AppController.shared
    @ObservedObject var appStateModel: AppState = AppState.shared
    @ObservedObject private var licenseManager = LicenseManager.shared
    
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) var openURL
    
    @State private var viewDidLoad = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $appStateModel.selectedHost) {
                // All traffic item (first item)
                if let allTraffic = appStateModel.hosts.first {
                    NavigationLink(value: allTraffic) {
                        Label("All traffic", systemImage: "square.grid.2x2")
                    }
                }
                
                // Collapsible Filters section
                // Filters section
                Section(header: Text("Filters").font(.caption).foregroundColor(.secondary)) {
                    ForEach(appStateModel.hosts.dropFirst(), id: \.self) { host in
                        ListRowView(hostModel: host)
                    }
                }
            }
            .listStyle(SidebarListStyle())
            .onDisappear(perform: onDisappear)
        } content: {
            RulesListWrap()
                .frame(minWidth: 220)
        } detail: {
            SessionContentView()
                .frame(minWidth: 600)
        }
        .onAppear(perform: boostrapApp)
        .onDisappear(perform: onDisappear)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("Add a host filter", action: addHost)
                    Button("Create an override", action: createRule)
                } label: {
                    Text(" ")
                    Image(systemName: "plus")
                    // note: the foregroundColor doesn't work here. https://stackoverflow.com/questions/75856718/swiftui-how-to-color-a-menu-button-icon-in-macos
                        .foregroundStyle(.primary, .primary)
                }
                .foregroundColor(.secondary)
                .buttonStyle(.borderless)
                .help("Add a host filter or create an override")
            }
            ToolbarItem(placement: .navigation) {
                Spacer()
            }
            ToolbarItem() {
                if licenseManager.hasValidationFinished && !licenseManager.checkLicense() {
                    HStack {
                        // Counter for remaining free inspections
                        FreeHttpsCounterView()
                        TrialBadgeButton(action: {
                            licenseManager.showPurchaseWindow()
                        })
                    }
                }
                else if licenseManager.hasValidationFinished && licenseManager.checkLicense() {
                    ProBadgeButton(action: {
//                        licenseManager.showPurchaseWindow()
                    })
                }
            }
            ToolbarItem() {
                Button(action: sendFeedback, label: {
                    Image(
                        systemName: "envelope.fill"
                    )
                    Text("Send Feedback")
                })
                .help("Send Feedback")
                .clipShape(Capsule())
                .buttonStyle(.borderless)
            }
            ToolbarItem() {
                // https://stackoverflow.com/a/78127540
                ToolbarSearchButton().focusSection()
            }
            ToolbarItem() {
                ToolbarDeleteButton()
            }
            VPNToolbarControl()
        }
        // Present the purchase window if no valid subscription is active.
        .sheet(isPresented: $licenseManager.shouldShowPurchaseWindow) {
            SubscriptionSettingsView(isInPreferences: false)
                .onDisappear {
                    licenseManager.dismissPurchaseWindow()
                }
        }
    }
    
    func boostrapApp() {
        self.appController.booststrap() {
            Task {
                do {
                    // Use bridge API to get all hosts
                    var foundHosts = try await ReqResCoreModelBridge.findAllHosts()
                    
                    // Create "All traffic" host using HostCodable
                    let allTraffic = HostCodable(
                        host: "All traffic",
                        port: NSNumber(value: 80),
                        hostDbId: nil, // No database ID for "All traffic"
                        requestProtocol: "HTTP",
                        modelRealId: nil, // No real model ID for virtual host
                    )
                    
                    foundHosts.insert(allTraffic, at: 0)
                    
                    #if DEBUG
                    await MainActor.run {
                        appStateModel.selectedHost = foundHosts[0]
                        addMockSessions()
                    }
                    #endif
                    
                    await MainActor.run {
                        appStateModel.hosts = foundHosts
                        appStateModel.selectedHost = appStateModel.hosts.first
                        viewDidLoad = true
                    }
                } catch {
                    // Handle error
                    AppLog.shared.error("Error loading hosts: \(error)")
                    await MainActor.run {
                        // Fallback: create just "All traffic" host
                        let allTraffic = HostCodable(
                            host: "All traffic",
                            port: NSNumber(value: 80),
                            hostDbId: nil,
                            requestProtocol: "HTTP",
                            modelRealId: nil,
                        )
                        appStateModel.hosts = [allTraffic]
                        appStateModel.selectedHost = appStateModel.hosts.first
                        viewDidLoad = true
                    }
                }
            }
        }
    }
    
    func onDisappear() {}
    
    func addHost() {
        openWindow(id: "new-host")
    }
    
    func createRule() {
        openWindow(id: "rule-modal")
    }
    
    func sendFeedback() {
        openURL(URL(string: FEEDBACK_URL)!)
    }
}

struct RulesListWrap: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var sessionState = SessionState.shared
    
    var body: some View {
        if appState.rules.isEmpty {
            EmptyStateView(
                title: "No Overrides",
                subtitle: "Create an override to start modifying requests and responses on the fly",
                iconName: "switch.2"
            )
            .navigationTitle(appState.selectedHost?.host ?? "ReqRes")
            .navigationSubtitle(sessionState.sessionsSubtitle)
        }
        else {
            RulesList()  // No need to pass rules anymore
                .navigationTitle(appState.selectedHost?.host ?? "ReqRes")
                .navigationSubtitle(sessionState.sessionsSubtitle)
        }
    }
}

struct RulesList: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var sessionState = SessionState.shared
    @State private var showDeleteConfirmation = false
    @AppStorage("skipRuleDeleteConfirmation") private var skipDeleteConfirmation = false
    
    var body: some View {
        List(appState.rules, id: \.id) { rule in
            RuleView(rule: rule, ruleHost: appState.hosts.first(where: { host in
                if let hostDbId = host.hostDbId {
                    return rule.hostId.int64Value == hostDbId.int64Value
                }
                return false
            }) ?? nil, selectedHost: appState.selectedHost)
                .help("Modification rule for \(rule.path)")
                .id(rule.id)
                .contextMenu {
                    Button("Edit override...") {
                        openEditWindow(for: rule)
                    }
                    Button("Delete override...") {
                        if skipDeleteConfirmation {
                            deleteRule(rule: rule)
                        } else {
                            showDeleteConfirmation(for: rule)
                        }
                    }
                }
        }
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 50)
    }
    
    func openEditWindow(for rule: RuleCodable) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.remove(.resizable)
        
        // Find the host using bridge API
        Task {
            do {
                let allHosts = try await ReqResCoreModelBridge.findAllHosts()
                if let host = allHosts.first(where: { $0.hostDbId?.int64Value == rule.hostId.int64Value }) {
                    await MainActor.run {
                        let contentView = RuleModal(selectedHost: host, existingRule: rule)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        window.contentView = NSHostingView(rootView: contentView)
                        
                        // Create window controller to manage the window
                        let windowController = DisposableWindowController(window: window)
                        windowController.showWindow(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        
                        // Keep a reference to the window controller
                        objc_setAssociatedObject(window, "windowControllerKey", windowController, .OBJC_ASSOCIATION_RETAIN)
                    }
                }
            } catch {
                AppLog.shared.error("Error finding host for rule: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    func deleteRule(rule: RuleCodable) {
        guard let _ = rule.modelRealId else {
            AppLog.shared.error("Cannot delete rule without database ID")
            return
        }
        
        AppState.shared.deleteRule(rule)
    }
    
    func showDeleteConfirmation(for rule: RuleCodable) {
            let alert = NSAlert()
            alert.messageText = "Delete Override"
            alert.informativeText = "Are you sure you want to delete this override?\n\nThis action cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            
            // Create checkbox for "Don't ask again"
            let checkbox = NSButton(checkboxWithTitle: "Don't ask again", target: nil, action: nil)
            checkbox.state = .off
            alert.accessoryView = checkbox
            
            // Show alert and handle response
            let response = alert.runModal()
            
            if response == .alertFirstButtonReturn {
                // User clicked Delete
                if checkbox.state == .on {
                    skipDeleteConfirmation = true
                }
                deleteRule(rule: rule)
            }
            // If Cancel, do nothing
        }
}

struct DeleteConfirmationView: View {
    let rulePath: String
    @Binding var dontAskAgain: Bool
    let onDelete: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.orange)
                .padding(.top, 20)
            
            Text("Delete Override")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Are you sure you want to delete this override? \(rulePath)")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Text("This action cannot be undone.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Toggle("Don't ask again", isOn: $dontAskAgain)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 40)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)
                
                Button("Delete") {
                    onDelete()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 400)
        .fixedSize()
    }
}

struct ListRowView: View {
    let hostModel: HostCodable

    var body: some View {
        VStack(alignment: .leading) {
            Label(hostModel.host, systemImage: hostModel.host == "All traffic" ? "square.grid.2x2" : "network")
                .font(.body)
                .truncationMode(.tail)
        }
        .contextMenu {
            if hostModel.host != "All traffic" {
                Button("Delete host...") {
                    AppState.shared.deleteHost(hostModel)
                }
            }
        }
    }
}

// Toggle Sidebar Function
func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
}

func toggleVpnTunnel() {
    AppController.shared.toggleVPNTunnel()
}

struct AppView_Previews: PreviewProvider {
    static var previews: some View {
        AppView()
    }
}

func addMockSessions() {
    SessionState.shared.addSession(session: SESSION_MOCK)
    SessionState.shared.addSession(session: SessionCodable(
        startTime: NSNumber(value: mockNow),
        host: "reqresapp.com",
        localAddress: "127.0.0.1",
        method: "GET",
        uri: "/test2/test2/test2/test2/test2/test2/test2/test2/test2/test2/test2/test2/?test=1&debug=true",
        reqHttpVersion: "1.0",
        target: "target",
        reqHeads: """
    {
    "Origin": "https://mail.superhuman.com",
    "sec-ch-ua-mobile": "?0",
    "Host": "content.googleapis.com",
    "Accept-Encoding": "gzip, deflate, br",
    "sec-ch-ua-platform": "",
    "Sec-Fetch-Site": "cross-site",
    "Connection": "keep-alive",
    "Sec-Fetch-Mode": "cors",
    "Authorization": "Bearer 123",
    "Accept-Language": "en-GB",
    "Accept": "*/*",
    "Sec-Fetch-Dest": "empty"
    }
    """,
        reqEncoding: "gzip",
        reqType: "application/json; charset=utf-8",
        // NOTE: some extra escaping is failing to decode the string as in the example below
        reqBody: """
        {"fields":["[data-id=\"97007832-07a6-45f1-b4f3-349fd2d66909\"]"]}
        """,
        rspHttpVersion: "Http/1.1",
    state: "500",
        rspMessage: "ok",
        rspType: "application/json; charset=utf-8",
    rspHeads: """
    {
    "Cache-Control": "max-age=0, private, must-revalidate",
    "Content-Encoding": "gzip",
    }
    """,
    rspBody: """
    {
        "rsp": true,
        "test": 1,
        "string": "my string",
        "array": ["one", "two", "three"]
    }
    """,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 0.01),
    reqBodyStartTime: NSNumber(value: mockNow + 0.02),
    rspStartTime: NSNumber(value: mockNow + 0.276),      // +31ms for request
    rspEndTime: NSNumber(value: mockNow + 0.309),        // +33ms for response
    connectTime: NSNumber(value: mockNow + 0.008),       // +8ms for queuing
    connectedTime: NSNumber(value: mockNow + 0.009),     // +1ms for DNS
    handshakeEndTime: NSNumber(value: mockNow + 0.147),  // +118ms for TCP
    reqEndTime: NSNumber(value: mockNow + 0.245),        // +98ms for TLS handshake
    uploadTraffic: NSNumber(value: 973),             // 973 bytes sent
    downloadFlow: NSNumber(value: 1264),              // 1.2KB received
    downloadStartTime: NSNumber(value: mockNow + 0.285), // +9ms after rspStartTime for server processing
    downloadEndTime: NSNumber(value: mockNow + 0.309)   // Same as rspEndTime (download completes)
    ))
    SessionState.shared.addSession(session: SessionCodable(
        startTime: NSNumber(value: mockNow),
        host: "reqresapp.com",
        localAddress: "127.0.0.1",
        method: "GET",
        uri: "/test/img",
        reqHttpVersion: "1.0",
        target: "target",
        reqHeads: """
            {
            "Origin": "https://mail.superhuman.com",
            "sec-ch-ua-mobile": "?0",
            "Host": "content.googleapis.com",
            "Accept-Encoding": "gzip, deflate, br",
            "sec-ch-ua-platform": "",
            "Sec-Fetch-Site": "cross-site",
            "Connection": "keep-alive",
            "Sec-Fetch-Mode": "cors",
            "Authorization": "Bearer 123",
            "Accept-Language": "en-GB",
            "Accept": "*/*",
            "Sec-Fetch-Dest": "empty"
            }
        """,
        reqEncoding: "",
        reqType: "",
        reqBody: "",
        rspHttpVersion: "Http/1.1",
        state: "400",
        rspMessage: "ok",
        rspType: "image/vnd.microsoft.icon",
        rspHeads: """
        {
        "Cache-Control": "max-age=0, private, must-revalidate",
        "Content-Encoding": "gzip",
        "Content-Length": "86534",
        "Content-Type": "image/vnd.microsoft.icon"
        }
        """,
        rspBody: "",
        rspBodyData: NSImage(named: NSImage.cautionName)!.tiffRepresentation,
        scheme: "https",
        reqStartTime: NSNumber(value: mockNow + 0.01),
        reqBodyStartTime: NSNumber(value: mockNow + 0.02),
        rspStartTime: NSNumber(value: mockNow + 0.276),      // +31ms for request
        rspEndTime: NSNumber(value: mockNow + 0.309),        // +33ms for response
        connectTime: NSNumber(value: mockNow + 0.008),       // +8ms for queuing
        connectedTime: NSNumber(value: mockNow + 0.009),     // +1ms for DNS
        handshakeEndTime: NSNumber(value: mockNow + 0.147),  // +118ms for TCP
        reqEndTime: NSNumber(value: mockNow + 0.245),        // +98ms for TLS handshake
        uploadTraffic: NSNumber(value: 973),             // 973 bytes sent
        downloadFlow: NSNumber(value: 1264),              // 1.2KB received
        downloadStartTime: NSNumber(value: mockNow + 0.285), // +9ms after rspStartTime for server processing
        downloadEndTime: NSNumber(value: mockNow + 0.309)   // Same as rspEndTime (download completes)
    ))
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: {
        SessionState.shared.addSession(session: SessionCodable(
            startTime: NSNumber(value: mockNow),
            host: "reqresapp.com",
            localAddress: "127.0.0.1",
            method: "GET",
            uri: "/test",
            reqHttpVersion: "1.0",
            target: "target",
            reqHeads: """
        {
        "Origin": "https://mail.superhuman.com",
        "sec-ch-ua-mobile": "?0",
        "Host": "content.googleapis.com",
        "Accept-Encoding": "gzip, deflate, br",
        "sec-ch-ua-platform": "",
        "Sec-Fetch-Site": "cross-site",
        "Connection": "keep-alive",
        "Sec-Fetch-Mode": "cors",
        "Authorization": "Bearer 123",
        "Accept-Language": "en-GB",
        "Accept": "*/*",
        "Sec-Fetch-Dest": "empty"
        }
        """,
            reqEncoding: "gzip",
            reqType: "application/json; charset=utf-8",
            reqBody: """
            {
                "reqRes": true,
                "test": 1
            }
            """,
            rspHttpVersion: "Http/1.1",
        state: "200",
            rspMessage: "ok",
            rspType: "application/json; charset=utf-8",
        rspHeads: """
        {
        "Cache-Control": "max-age=0, private, must-revalidate",
        "Content-Encoding": "gzip"
        }
        """,
        rspBody: """
        {
            "rsp": true,
            "test": 1,
            "string": "my string",
            "array": ["one", "two", "three"]
        }
        """,
        scheme: "https",
        reqStartTime: NSNumber(value: mockNow + 0.01),
        reqBodyStartTime: NSNumber(value: mockNow + 0.02),
        rspStartTime: NSNumber(value: mockNow + 0.276),      // +31ms for request
        rspEndTime: NSNumber(value: mockNow + 0.309),        // +33ms for response
        connectTime: NSNumber(value: mockNow + 0.008),       // +8ms for queuing
        connectedTime: NSNumber(value: mockNow + 0.009),     // +1ms for DNS
        handshakeEndTime: NSNumber(value: mockNow + 0.147),  // +118ms for TCP
        reqEndTime: NSNumber(value: mockNow + 0.245),        // +98ms for TLS handshake
        uploadTraffic: NSNumber(value: 973),                 // 973 bytes sent
        downloadFlow: NSNumber(value: 1264),                 // 1.2KB received
        downloadStartTime: NSNumber(value: mockNow + 0.285), // +9ms after rspStartTime for server processing
        downloadEndTime: NSNumber(value: mockNow + 0.309)    // Same as rspEndTime (download completes)
    ))
    })
}
