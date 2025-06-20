//
//  SessionView.swift
//  ReqRes
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

import Foundation
import AppKit
import SwiftUI
import XReqResCore
import SplitView
import WebKit
import Utils

private struct NetworkInspectorPreferences {
    @AppStorage("network-inspector-selected-tab-request")
    var selectedTab: NetworkInspectorTabRequest = .summary
}

private struct NetworkInspectorPreferencesResponse {
    @AppStorage("network-inspector-selected-tab-response")
    var selectedTab: NetworkInspectorTabResponse = .response
}

enum NetworkInspectorTabRequest: String, Identifiable, CaseIterable, CustomStringConvertible {
    case summary = "Summary"
    case request = "Body"
    case headers = "Headers"
    case metrics = "Metrics"
    case curl = "cURL"

    var id: NetworkInspectorTabRequest { self }
    var description: String { self.rawValue }
}

enum NetworkInspectorTabResponse: String, Identifiable, CaseIterable, CustomStringConvertible {
    case summary = "Summary"
    case response = "Body"
    case headers = "Headers"
    case metrics = "Metrics"

    var id: NetworkInspectorTabResponse { self }
    var description: String { self.rawValue }
}

enum SessionMode: String {
    case Request = "Request"
    case Response = "Response"
}

let mockNow = Date().timeIntervalSince1970 // Current Unix timestamp

struct SessionView: View {
    @AppStorage("selectedSettingsTab") private var selectedSettingsTab = SettingsTab.general
    @Environment(\.openSettings) private var openSettings
    
    @ObservedObject var appState: AppState = AppState.shared
    @ObservedObject var sessionState: SessionState = SessionState.shared
    @ObservedObject private var licenseManager = LicenseManager.shared
    
    @State private var viewLoaded = false
    @State private var selectedSessionIds: Set<UUID> = []
    @State private var selectedSession: SessionCodable?
    @State private var lastSelectedIndex: Int?
    
    @State private var maxColWidth: CGFloat = 300
    @State var selectedTabRequest: NetworkInspectorTabRequest
    @State var selectedTabResponse: NetworkInspectorTabResponse
    @State private var keyMonitor: Any?
    @State private var recentlyInspectedSessionIds: Set<String> = Set<String>()
    
    let layout = LayoutHolder(.horizontal)
    let hide = SideHolder()
    
    init(tab: NetworkInspectorTabRequest = NetworkInspectorPreferences().selectedTab) {
        self._selectedTabRequest = State(initialValue: tab)
        self._selectedTabResponse = State(initialValue: NetworkInspectorPreferencesResponse().selectedTab)
    }

    var body: some View {
        Split(
            primary: {
                SessionListView(
                    sessionState: sessionState,
                    selectedSessionIds: $selectedSessionIds,
                    lastSelectedIndex: $lastSelectedIndex,
                    onAppear: onAppear,
                    onDisappear: removeKeyMonitor,
                    deleteSelectedSessions: deleteSelectedSessions,
                    handleRowSelection: handleRowSelection
                )
            },
            secondary: {
                // Pass a wrapper function for openSettings that matches the expected signature
                let openSettingsAction: () -> Void = { self.openSettings() }
                
                SessionDetailView(
                    selectedSession: selectedSession,
                    selectedSessionIds: $selectedSessionIds,
                    selectedTabRequest: $selectedTabRequest,
                    selectedTabResponse: $selectedTabResponse,
                    recentlyInspectedSessionIds: $recentlyInspectedSessionIds,
                    layout: layout,
                    hide: hide,
                    selectedSettingsTab: $selectedSettingsTab,
                    openSettingsAction: openSettingsAction
                )
                .onAppear {
                    selectedSession = getSelectedRowData()
                }
                .onChange(of: selectedSessionIds) { _, _ in
                    selectedSession = getSelectedRowData()
                }
            }
        )
        .splitter { Splitter.invisible() }
        .layout(LayoutHolder(.vertical))
        .hide(SideHolder(!hasSelectedSession() ? .secondary : nil))
    }
    
    // MARK: - Event Functions
    
    func onAppear() -> Void {
        if (self.viewLoaded) {
            return
        }
        sessionState.updateFilteredSessions(selectedHost: nil)
        addKeyMonitor()
        viewLoaded = true
    }
    
    func addKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { (aEvent) -> NSEvent? in
            // keycodes: https://gist.github.com/swillits/df648e87016772c7f7e5dbed2b345066
            
            // Check if the focused element is the search bar (or any text field)
            if let focusedView = NSApp.keyWindow?.firstResponder {
                // Check if the focused view is NSTextView and editable
                if let textView = focusedView as? NSTextView, textView.isEditable {
                    // If Escape key is pressed while editing in NSTextView
                    if aEvent.keyCode == 0x35 {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        return nil
                    }
                    return aEvent // Let the key event pass through for other keys
                }
                
                // Check if the focused view is a WKWebView
                if let _ = focusedView as? WKWebView {
                    // If Escape key is pressed while focusing on WKWebView
                    if aEvent.keyCode == 0x35 {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        return nil
                    }
                    return aEvent // Let the key event pass through for other keys
                }
            }

            // if esc pressed
            if aEvent.keyCode == 0x35 {
                self.selectedSessionIds = []
                return nil // do not do "beep" sound
            }
            // if delete pressed
            if aEvent.keyCode == 0x33 {
                self.deleteSelectedSessions()
                return nil // do not do "beep" sound
            }
             
            return aEvent
        }
    }
    
    func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    
    func hasSelectedSession() -> Bool {
        return self.$selectedSessionIds.wrappedValue.count > 0
    }
  
    func getSelectedRowData() -> SessionCodable? {
        guard let lastSelectedId = selectedSessionIds.sorted(by: { $0.uuidString < $1.uuidString }).last else {
            return nil
        }
        return sessionState.sessions.first { sessionItem in
            return sessionItem.id == lastSelectedId
        }
    }
    
    // Detect key modifiers
    func handleRowSelection(sessionId: UUID, index: Int) {
        let commandPressed = NSEvent.modifierFlags.contains(.command)
        let shiftPressed = NSEvent.modifierFlags.contains(.shift)

        if commandPressed {
            // Command pressed - toggle selection without affecting other rows
            if selectedSessionIds.contains(sessionId) {
                selectedSessionIds.remove(sessionId)
            } else {
                selectedSessionIds.insert(sessionId)
            }
            lastSelectedIndex = index
        } else if shiftPressed, let lastSelectedIndex = lastSelectedIndex {
            // Shift pressed - select range of rows
            let startIndex = min(lastSelectedIndex, index)
            let endIndex = max(lastSelectedIndex, index)
            
            // Add all session IDs within the range
            let rangeSessions = sessionState.filteredSessions[startIndex...endIndex]
            selectedSessionIds.formUnion(rangeSessions.map { $0.id })
        } else {
            // No modifier pressed - single selection
            selectedSessionIds = [sessionId]
            lastSelectedIndex = index
        }
    }
    
    // Function to delete selected sessions
    func deleteSelectedSessions() {
        // Remove selected sessions from the session state
        sessionState.removeSession(sessionUids: selectedSessionIds)
        selectedSessionIds.removeAll() // Clear the selected sessions
        lastSelectedIndex = nil // Clear the last selected session
    }
}

struct SessionDetailView: View {
    var selectedSession: SessionCodable?
    @Binding var selectedSessionIds: Set<UUID>
    @Binding var selectedTabRequest: NetworkInspectorTabRequest
    @Binding var selectedTabResponse: NetworkInspectorTabResponse
    @Binding var recentlyInspectedSessionIds: Set<String>
    
    let layout: LayoutHolder
    let hide: SideHolder
    
    @Binding var selectedSettingsTab: SettingsTab
    let openSettingsAction: () -> Void
    
    @ObservedObject private var licenseManager = LicenseManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = selectedSession {
                SessionDetailHeaderView(session: session, onClose: {
                    selectedSessionIds = []
                })
                
                if session.scheme == "https" && CertHelper.getInstalledCertificate() == nil {
                    CertificateRequiredView(
                        selectedSettingsTab: $selectedSettingsTab,
                        openSettingsAction: openSettingsAction
                    )
                }
                else if session.scheme == "https" && !licenseManager.checkLicense() {
                    HttpsSessionDetailContent(
                        session: session,
                        selectedTabRequest: $selectedTabRequest,
                        selectedTabResponse: $selectedTabResponse,
                        recentlyInspectedSessionIds: $recentlyInspectedSessionIds,
                        layout: layout,
                        hide: hide
                    )
                }
                else if session.scheme != "https" || licenseManager.checkLicense() {
                    // Regular session detail content (for HTTP or Pro users)
                    SessionDetailContent(
                        session: session,
                        selectedTabRequest: $selectedTabRequest,
                        selectedTabResponse: $selectedTabResponse,
                        layout: layout,
                        hide: hide
                    )
                }
            }
        }
    }
}

// Component for the session detail header with URL and close button
struct SessionDetailHeaderView: View {
    let session: SessionCodable
    let onClose: () -> Void
    
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Chip(status: session.state)
            Text(session.method)
                .fontWeight(.medium)
            Divider()
            Text(verbatim: session.fullUrl)
                .help(session.fullUrl)  // Tooltip with full URL
                .truncationMode(.tail)  // Truncate text from the end if it's too long
                .lineLimit(1)           // Ensure it's a single line for truncation to work
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .imageScale(.medium)
                    .foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(minWidth: 0,
               maxWidth: .infinity,
               minHeight: 20,
               maxHeight: 20,
               alignment: .topLeading)
        .padding([.trailing], 15)
        .padding([.leading], 15)
        .padding([.vertical], 8)
        .background(Color.panelBodyBackground)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.gray).opacity(0.5), alignment: .top)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.gray).opacity(0.5), alignment: .bottom)
    }
}

// View shown when certificate is required
struct CertificateRequiredView: View {
    @Binding var selectedSettingsTab: SettingsTab
    let openSettingsAction: () -> Void
    
    var body: some View {
        PlaceholderView(
            imageName: "exclamationmark.circle",
            title: "Not Available",
            subtitle: "Install and trust the ReqRes CA Certificate to inspect HTTPS requests",
            buttonTitle: "Install CA Certificate",
            buttonAction: {
                selectedSettingsTab = .certificate
                openSettingsAction()
            }
        )
    }
}

// Toolbar for request/response tabs
struct SessionToolbar<T>: View where T: CaseIterable & Hashable & RawRepresentable & Identifiable, T.RawValue == String, T.AllCases: Collection, T.AllCases.Element == T {
    let title: SessionMode
    let tabItems: T.Type
    @Binding var selection: T
    
    var body: some View {
        HStack {
            Text(title.rawValue)
                .frame(minWidth: 0,
                       maxWidth: title == .Response ? 65 : 55,
                       minHeight: 20,
                       maxHeight: 20,
                       alignment: .center)
                .fontWeight(.semibold)
                .font(.system(size: 13))
                .padding([.horizontal], 10)
            
            InlineTabBar(items: Array(T.allCases), selection: $selection)
            Spacer()
        }
        .padding(.horizontal, 5)
        .offset(y: 0)
        .frame(height: 27, alignment: .center)
    }
}
struct SessionListView: View {
    @ObservedObject var sessionState: SessionState
    @Binding var selectedSessionIds: Set<UUID>
    @Binding var lastSelectedIndex: Int?
    
    let onAppear: () -> Void
    let onDisappear: () -> Void
    let deleteSelectedSessions: () -> Void
    let handleRowSelection: (UUID, Int) -> Void
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Section for header
                Section(header: SessionTableHeader()) {
                    // Table Rows
                    ForEach(Array(sessionState.filteredSessions.enumerated()), id: \.element.id) { index, session in
                        TableRowView(
                            session: session,
                            isSelected: selectedSessionIds.contains(session.id),
                            isEvenRow: index % 2 == 0
                        )
                        .onTapGesture {
                            // reset possible focused SearchToolbar text input
                            DispatchQueue.main.async {
                                NSApp.keyWindow?.makeFirstResponder(nil)
                            }
                            handleRowSelection(session.id, index)
                        }
                        .contextMenu {
                            Button(action: {
                                // context menu when no selected items
                                if selectedSessionIds.isEmpty {
                                    selectedSessionIds = [session.id]
                                }
                                deleteSelectedSessions()
                            }) {
                                Label("Delete session\(selectedSessionIds.count > 1 ? "s" : "")...", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .background(Color.panelHeaderBackground)
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
    }
}

// Table header component
struct SessionTableHeader: View {
    var body: some View {
        VStack {
            HStack {
                Text("Code")
                    .fontWeight(.regular)
                    .frame(minWidth: 40, idealWidth: 40, alignment: .center)
                    .foregroundColor(.primary)

                VerticalDivider(color: .gray.opacity(0.8))

                Text("Method")
                    .fontWeight(.regular)
                    .frame(minWidth: 60, idealWidth: 70, alignment: .center)
                    .foregroundColor(.primary)

                VerticalDivider(color: .gray.opacity(0.8))

                Text("URL")
                    .fontWeight(.regular)
                    .frame(minWidth: 200, idealWidth: 430, maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(.primary)

                VerticalDivider(color: .gray.opacity(0.8))

                Text("Time")
                    .fontWeight(.regular)
                    .frame(minWidth: 80, idealWidth: 80, alignment: .leading)
                    .foregroundColor(.primary)

                VerticalDivider(color: .gray.opacity(0.8))

                Text("Duration")
                    .fontWeight(.regular)
                    .frame(alignment: .leading)
                    .foregroundColor(.primary)
                    .frame(minWidth: 80, idealWidth: 80, alignment: .leading)
            }
            .padding([.trailing], 15)
            .padding([.leading], 15)
            .padding(.vertical, 8) // Add some padding to the headers
            .background(Color.panelHeaderBackground) // Background for headers
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(Color.gray.opacity(0.5))
                    .padding(.top, 40), // Add bottom border to header
                alignment: .bottom
            )
        }
    }
}

// Free HTTPS Counter View
struct FreeHttpsCounterView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var isHovering = false
    
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                // Only show the text when hovering
                //if isHovering {
                    Text("\(appState.maxFreeHttpsSessions - appState.freeHttpsSessionsInspected) free HTTPS inspections remaining")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: isHovering)
                //}
                // Progress bar showing usage
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .frame(width: 150, height: 6)
                        .foregroundColor(Color.gray.opacity(0.3))
                    
                    RoundedRectangle(cornerRadius: 3)
                        .frame(width: 150 * CGFloat(appState.freeHttpsSessionsInspected) / CGFloat(appState.maxFreeHttpsSessions), height: 6)
                        .foregroundColor(Color.blue)
                }
            }
            .padding(.horizontal)
            .onHover { hovering in
                isHovering = hovering
            }
            Spacer()
        }
    }
}

private struct TooltipView<Content>: View where Content: View {
    let content: () -> Content
    let tip: String
    let geometry: GeometryProxy

    init(_ tip: String, geometry: GeometryProxy, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.tip = tip
        self.geometry = geometry
    }

    var body: some View {
        Tooltip(tip, content: content)
            .frame(width: geometry.size.width, height: geometry.size.height)
    }
}

private struct Tooltip<Content: View>: NSViewRepresentable {
    typealias NSViewType = NSHostingView<Content>

    init(_ text: String?, @ViewBuilder content: () -> Content) {
        self.text = text
        self.content = content()
    }

    let text: String?
    let content: Content

    func makeNSView(context _: Context) -> NSHostingView<Content> {
        NSViewType(rootView: content)
    }

    func updateNSView(_ nsView: NSHostingView<Content>, context _: Context) {
        nsView.rootView = content
        nsView.toolTip = text
    }
}

extension View {
    func tooltip(_ tip: String) -> some View {
        ZStack {
            background(GeometryReader { childGeometry in
                TooltipView(tip, geometry: childGeometry) {
                    self
                }
            })
        }
    }
}

// View for HTTPS sessions with free tier limit
struct HttpsSessionDetailContent: View {
    let session: SessionCodable
    @Binding var selectedTabRequest: NetworkInspectorTabRequest
    @Binding var selectedTabResponse: NetworkInspectorTabResponse
    @Binding var recentlyInspectedSessionIds: Set<String>
    
    let layout: LayoutHolder
    let hide: SideHolder
    
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var licenseManager = LicenseManager.shared
    
    var body: some View {
        if appState.hasReachedFreeHttpsLimit {
            // Display paywall when limit reached
            PlaceholderView(
                imageName: "lock.fill",
                title: "Pro Feature",
                subtitle: "You've reached the limit of 10 free HTTPS inspections. Upgrade now to view unlimited session details.",
                buttonTitle: "Upgrade Now",
                buttonAction: {
                    licenseManager.showPurchaseWindow()
                }
            )
        } else {
            // Track session inspection and show details
            VStack(spacing: 0) {
                // Check if session needs counting and increment if needed
                if !recentlyInspectedSessionIds.contains(session.id.uuidString) {
                    // This Color.clear is a SwiftUI trick to execute code in a view
                    // without creating a visible element
                    Color.clear
                        .onAppear {
                            appState.incrementHttpsSessionCounter()
                            recentlyInspectedSessionIds.insert(session.id.uuidString)
                        }
                        .frame(width: 0, height: 0)
                }
                
                // Session details
                SessionDetailContent(
                    session: session,
                    selectedTabRequest: $selectedTabRequest,
                    selectedTabResponse: $selectedTabResponse,
                    layout: layout,
                    hide: hide
                )
            }
        }
    }
}

// Core session detail content (request/response split view)
struct SessionDetailContent: View {
    let session: SessionCodable
    @Binding var selectedTabRequest: NetworkInspectorTabRequest
    @Binding var selectedTabResponse: NetworkInspectorTabResponse
    
    let layout: LayoutHolder
    let hide: SideHolder
    
    var body: some View {
        Split(
            primary: {
                VStack(alignment: .leading, spacing: 0) {
                    RequestToolbar(title: .Request, selection: $selectedTabRequest)
                    Divider()
                    
                        SessionRequestTabView(session: session, selectedTabRequest: $selectedTabRequest)
                            .equatable()
                    
                }
                .onChange(of: selectedTabRequest) { _, newTab in
                    NetworkInspectorPreferences().selectedTab = newTab
                }
            },
            secondary: {
                VStack(alignment: .leading, spacing: 0) {
                    ResponseToolbar(title: .Response, selection: $selectedTabResponse)
                    Divider()
                    
                        SessionResponseTabView(session: session, selectedTabResponse: $selectedTabResponse)
                            .equatable()
                    
                }
                .onChange(of: selectedTabResponse) { _, newTab in
                    NetworkInspectorPreferencesResponse().selectedTab = newTab
                }
            }
        )
        .constraints(minPFraction: 0.2, minSFraction: 0.1)
        .layout(layout)
        .splitter { ThinSplitter(layout: layout, hide: hide) }
    }
}

// Specialized toolbar components to avoid generic issues
struct RequestToolbar: View {
    let title: SessionMode
    @Binding var selection: NetworkInspectorTabRequest
    
    var body: some View {
        HStack {
            Text(title.rawValue)
                .frame(minWidth: 0,
                       maxWidth: 55,
                       minHeight: 20,
                       maxHeight: 20,
                       alignment: .center)
                .fontWeight(.semibold)
                .font(.system(size: 13))
                .padding([.horizontal], 10)
            
            InlineTabBar(items: NetworkInspectorTabRequest.allCases, selection: $selection)
            Spacer()
        }
        .padding(.horizontal, 5)
        .offset(y: 0)
        .frame(height: 27, alignment: .center)
    }
}

struct ResponseToolbar: View {
    let title: SessionMode
    @Binding var selection: NetworkInspectorTabResponse
    
    var body: some View {
        HStack {
            Text(title.rawValue)
                .frame(minWidth: 0,
                       maxWidth: 65,
                       minHeight: 20,
                       maxHeight: 20,
                       alignment: .center)
                .fontWeight(.semibold)
                .font(.system(size: 13))
                .padding([.horizontal], 10)
            
            InlineTabBar(items: NetworkInspectorTabResponse.allCases, selection: $selection)
            Spacer()
        }
        .padding(.horizontal, 5)
        .offset(y: 0)
        .frame(height: 27, alignment: .center)
    }
}

// ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ----

func formatRequestTimes(_ session: SessionCodable) -> (requestStartTime: String, requestEndTime: String, requestDuration: String) {
    let startTime = session.startTime.doubleValue
    let endTime = session.rspEndTime.doubleValue
    
    var totalTime = (endTime) - (startTime)
    
    if totalTime < 0 { totalTime = 0 }
    var totalTimeStr = String(format: "%.2f s", totalTime)//"\(totalTime)s"
    if totalTime < 1 {
        totalTimeStr = "\(Int(totalTime*1000)) ms"
    }
    
    var startTimeStr = ""
    var endTimeStr = ""
    
    if startTime > 0 , endTime > 0 {
        let startDate = Date(timeIntervalSince1970: startTime)
        startTimeStr = startDate.CurrentStringTimeForCell
    }
    if endTime > 0 {
        let endDate = Date(timeIntervalSince1970: endTime)
        endTimeStr = endDate.CurrentStringTimeForCell
    }
    
    return (startTimeStr, endTimeStr, totalTimeStr)
}


struct TableRowView: View {
    var session: SessionCodable
    var isSelected: Bool
    var isEvenRow: Bool
    
    var body: some View {
        HStack {
            Chip(status: session.state)
                .frame(minWidth: 40, idealWidth: 40, alignment: .center)
            
            VerticalDivider(color: .clear)
            
            Text(session.method)
                .fontWeight(.medium)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(minWidth: 60, idealWidth: 70, alignment: .center)
            
            VerticalDivider(color: .clear)
            
            Text(session.fullUrl)
                .help(session.fullUrl)  // Tooltip with full URL
                .truncationMode(.tail)  // Truncate text from the end if it's too long
                .lineLimit(1)           // Ensure it's a single line for truncation to work
                .fixedSize(horizontal: false, vertical: true)  // Prevents expansion and enables truncation
                .foregroundColor(isSelected ? .white : .primary)
                .frame(minWidth: 200, idealWidth: 430, maxWidth: .infinity, alignment: .leading)
            
            VerticalDivider(color: .clear)
            
            Text(formatRequestTimes(session).requestStartTime)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(minWidth: 80, idealWidth: 80, alignment: .leading)
            
            VerticalDivider(color: .clear)
            
            Text(formatRequestTimes(session).requestDuration)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(minWidth: 80, idealWidth: 80, alignment: .leading)
        }
        .padding([.trailing], 15)
        .padding([.leading], 15)
        .padding(.vertical, 5)
        .background(isSelected ? Color(red: 0.23, green: 0.52, blue: 0.96) : (!isEvenRow ? Color.gray.opacity(0.05) : Color.clear)) // Lighter blue for selection and lighter alternating row color
        .contentShape(Rectangle()) // Ensure the whole row is clickable
    }
}

// use our own divider, because the native one doesn't support a clear color
struct VerticalDivider: View {
    
    let color: Color
    let width: CGFloat
    
    init(color: Color, width: CGFloat = 1.0) {
        self.color = color
        self.width = width
    }
    
    var body: some View {
        color
            .frame(width: width)
    }
}

struct SessionRequestTabView: View, Equatable {
    let session: SessionCodable
    @Binding var selectedTabRequest: NetworkInspectorTabRequest
    private var renderer: SessionDetailsRenderer { SessionDetailsRenderer() }
    
    var body: some View {
        switch selectedTabRequest {
            case .summary:
            RichSessionTextView(viewModel: .init(string: renderer.render(session, contentType: .requestSummary)))
            case .headers:
            RichSessionTextView(viewModel: .init(string: renderer.render(session, contentType: .requestHeaders)))
            case .request:
                if let contentType = ContentType(rawValue: session.reqType),
                   contentType.isJSON && !session.reqBody.isEmpty {
                    RichSessionTextView(viewModel: .init(string: renderer.render(session, contentType: .requestBody)))
                } else {
                   placeholder
                }
            case .metrics:
                NetworkMetricsView(session: session)
            case .curl:
            RichSessionTextView(viewModel: .init(string: renderer.renderPreformatted(session.cURL)))
            }
    }
    
    // this prevents rerenders when new session is added in the session state
    static func == (lhs: SessionRequestTabView, rhs: SessionRequestTabView) -> Bool {
        // Only re-render if the session ID changes
        return lhs.session.id == rhs.session.id && lhs.selectedTabRequest == rhs.selectedTabRequest
    }
    
    @ViewBuilder
    private var placeholder: some View {
        PlaceholderView(imageName: "exclamationmark.circle", title: "Not Available")
    }
}

struct SessionResponseTabView: View, Equatable {
    let session: SessionCodable
    @Binding var selectedTabResponse: NetworkInspectorTabResponse
    private var renderer: SessionDetailsRenderer { SessionDetailsRenderer() }
    
    var body: some View {
        GeometryReader { geometry in
            let maxSize = geometry.size
            
            switch selectedTabResponse {
            case .summary:
                RichSessionTextView(viewModel: .init(string: renderer.render(session, contentType: .responseSummary(attachmentSize: maxSize))))
            case .headers:
                RichSessionTextView(viewModel: .init(string: renderer.render(session, contentType: .responseHeaders)))
            case .response:
                RichSessionTextView(viewModel: .init(string: renderer.render(session, contentType: .responseBody(attachmentSize: maxSize))))
            case .metrics:
                NetworkMetricsView(session: session)
            }
        }
    }
    
    // this prevents rerenders when new session is added in the session state ^^,
    static func == (lhs: SessionResponseTabView, rhs: SessionResponseTabView) -> Bool {
        // Only re-render if the session ID changes
        return lhs.session.id == rhs.session.id && lhs.selectedTabResponse == rhs.selectedTabResponse
    }
    
    @ViewBuilder
    private var placeholder: some View {
        PlaceholderView(imageName: "exclamationmark.circle", title: "Not Available")
    }
}
