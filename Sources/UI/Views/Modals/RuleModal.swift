//
//  AddRuleModal.swift
//  ReqRes
//
//  Created by OloApps on 04.07.2023.
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
import XReqResCore

struct RuleModal: View {
    var selectedHost: HostCodable
    var existingRule: RuleCodable?
    
    @Environment(\.dismiss) var dismiss
    
    @State private var path: String = ""
    @State private var requestMethod: RequestMethodOption = .GET
    @State private var urlMatcherType: UrlMatcherType = .WILDCARD
    @State private var responseSelected: String = "Success"
    @State private var responseBody: String = ""
    @State private var statusCodeSuccess: HTTPSuccessStatus = .ok
    @State private var statusCodeFailure: HTTPFailureStatus = .badRequest
    @State private var rspHeaders: [HeaderEntry] = [
        HeaderEntry(key: "Content-Type", value: "application/json; charset=utf-8", isEnabled: true)
    ]
    @State private var ruleMode: RuleMode = .EXTEND
    @State private var reqHeaders: [HeaderEntry] = []
    @State private var reqProtocol: RequestProtocolType = .HTTPS
    @State private var includeRspBodyChecked: Bool = false
    // map local functionality
    @State private var showingFilePicker = false
    @State private var selectedFileURL: URL?
    @State private var fileError: String?
    @State private var showingErrorAlert = false
    @State private var existingFileRemoved: Bool = false
    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var showLimitAlert: Bool = false
    
    var disableForm: Bool {
        if path.isEmpty {
            return true
        }
        
        // For Map Local mode, require a file to be selected
        if ruleMode == .MAP_LOCAL {
            if let existingRule = existingRule {
                // For existing rule, either need existing path or new selection
                return existingRule.rspPath.isEmpty && selectedFileURL == nil
            } else {
                // For new rule, need a file selection
                return selectedFileURL == nil
            }
        }
        
        return false
    }
    
    init(selectedHost: HostCodable, existingRule: RuleCodable? = nil) { // Updated parameter types
        self.selectedHost = selectedHost
        self.existingRule = existingRule
        
        // Initialize state variables if editing an existing rule
        if let rule = existingRule {
            _path = State(initialValue: rule.path)
            _requestMethod = State(initialValue: RequestMethodOption(rawValue: rule.reqMethod) ?? .GET)
            _urlMatcherType = State(initialValue: rule.isRegexp.boolValue ? .REGEX : .WILDCARD)
            _reqProtocol = State(initialValue: RequestProtocolType(rawValue: rule.reqProtocol) ?? .HTTPS)
            _ruleMode = State(initialValue: rule.ruleMode)
            
            // Initialize response code and selection
            let rspCode = rule.rspCode.intValue
            if (200...299).contains(rspCode) {
                _responseSelected = State(initialValue: "Success")
                _statusCodeSuccess = State(initialValue: HTTPSuccessStatus(rawValue: rspCode) ?? .ok)
            } else {
                _responseSelected = State(initialValue: "Failure")
                _statusCodeFailure = State(initialValue: HTTPFailureStatus(rawValue: rspCode) ?? .badRequest)
            }
            
            // Initialize response body if exists
            if !rule.rspBody.isEmpty {
                _responseBody = State(initialValue: rule.rspBody)
                _includeRspBodyChecked = State(initialValue: true)
            }
            
            // Parse and set headers
            if !rule.rspHeaders.isEmpty,
               let rspHeadersData = rule.rspHeaders.data(using: .utf8),
               let headers = try? JSONDecoder().decode([HeaderEntry].self, from: rspHeadersData) {
                _rspHeaders = State(initialValue: headers)
            }
            
            if !rule.reqHeaders.isEmpty,
               let reqHeadersData = rule.reqHeaders.data(using: .utf8),
               let headers = try? JSONDecoder().decode([HeaderEntry].self, from: reqHeadersData) {
                _reqHeaders = State(initialValue: headers)
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {  // Set spacing to 0 to avoid extra space between scrollable content and footer
            // Header
            Text(existingRule != nil ? "Edit Override Rule" : "Create New Override Rule")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal, 10)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Rule Mode Picker
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("Mode", selection: $ruleMode) {
                            ForEach(RuleMode.allCases) { option in
                                Text(option.rawValue)
                            }
                        }
                        .frame(width: 200)
                        ruleModeDescription
                    }
                    .padding(.horizontal, 10)
                    
                    if ruleMode == .MAP_LOCAL {
                        // Map Local Section
                        Text("Map Static Local File")
                            .font(.headline)
                            .padding(.horizontal, 10)
                        
                        SectionWrapper {
                            Picker("Request Protocol", selection: $reqProtocol) {
                                ForEach(RequestProtocolType.allCases) { option in
                                    Text(option.rawValue)
                                }
                            }
                            .frame(width: 200)
                            VStack(alignment: .leading, spacing: 12) {
                                // URL Pattern and Method settings (reuse existing UI)
                                HStack {
                                    Text("URL")
                                    PrefixedTextField(prefix: selectedHost.host, text: $path, placeholder: selectedHost.host == "All traffic" ? "mysite.com/path?*" : "/path?*") { newValue in
                                        path = newValue
                                    }
                                    testPatternButton
                                }
                                
                                Picker("Method", selection: $requestMethod) {
                                    ForEach(RequestMethodOption.allCases) { option in
                                        Text(option.rawValue)
                                    }
                                }
                                .frame(width: 150)
                                
                                Picker("URL Matching Type", selection: $urlMatcherType) {
                                    ForEach(UrlMatcherType.allCases) { option in
                                        Text(option.rawValue)
                                    }
                                }
                                .frame(width: 250)
                                
                                // Local File Selection
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Response File")
                                        .font(.headline)
                                    
                                    // Show either selected file or existing rule path
                                    if let selectedURL = selectedFileURL {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                // File name
                                                Text(selectedURL.lastPathComponent)
                                                    .truncationMode(.middle)
                                                    .lineLimit(1)
                                                
                                                Spacer()
                                                
                                                // File size
                                                if let fileSize = try? selectedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                                    Text(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                                                        .foregroundColor(.secondary)
                                                        .font(.subheadline)
                                                }
                                                
                                                // Clear button
                                                Button(action: {
                                                    selectedFileURL = nil
                                                }) {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.gray)
                                                }
                                            }
                                        }
                                        .padding(8)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(6)
                                    } else if let rspPath = existingRule?.rspPath, !rspPath.isEmpty && !existingFileRemoved {
                                       VStack(alignment: .leading, spacing: 4) {
                                           HStack {
                                               // File name
                                               Text(rspPath)
                                                   .truncationMode(.middle)
                                                   .lineLimit(1)
                                               
                                               Spacer()
                                               
                                               // File size
                                               if let fileSize = try? URL(fileURLWithPath: rspPath).resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                                   Text(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                                                       .foregroundColor(.secondary)
                                                       .font(.subheadline)
                                               }
                                               
                                               // Clear button - Note: Can't mutate existingRule directly anymore
                                               Button(action: {
                                                   existingFileRemoved = true
                                               }) {
                                                   Image(systemName: "xmark.circle.fill")
                                                       .foregroundColor(.gray)
                                               }
                                           }
                                       }
                                       .padding(8)
                                       .background(Color(NSColor.controlBackgroundColor))
                                       .cornerRadius(6)
                                   }
                                    Button(action: {
                                        showingFilePicker = true
                                    }) {
                                        HStack {
                                            Image(systemName: "doc.badge.plus")
                                            Text(existingRule?.rspPath.isEmpty ?? true ? "Select File" : "Change File")
                                        }
                                    }
                                    .fileImporter(
                                        isPresented: $showingFilePicker,
                                        allowedContentTypes: MapLocalConfig.supportedTypes,
                                        allowsMultipleSelection: false
                                    ) { result in
                                        switch result {
                                        case .success(let urls):
                                            if let url = urls.first {
                                                do {
                                                    try MapLocalConfig.validateFile(at: url)
                                                    selectedFileURL = url
                                                    fileError = nil
                                                } catch MapLocalError.fileTooLarge(let size) {
                                                    fileError = "File is too large (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))). Maximum size is \(ByteCountFormatter.string(fromByteCount: MapLocalConfig.maxFileSize, countStyle: .file))."
                                                    showingErrorAlert = true
                                                } catch MapLocalError.unsupportedFileType(let filename) {
                                                    fileError = "Unsupported file type: \(filename)"
                                                    showingErrorAlert = true
                                                } catch {
                                                    fileError = "Failed to validate file: \(error.localizedDescription)"
                                                    showingErrorAlert = true
                                                }
                                            }
                                        case .failure(let error):
                                            fileError = "Error selecting file: \(error.localizedDescription)"
                                            showingErrorAlert = true
                                        }
                                    }
                                    .alert("File Error", isPresented: $showingErrorAlert) {
                                        Button("OK", role: .cancel) {}
                                    } message: {
                                        Text(fileError ?? "Unknown error occurred")
                                    }
                                    // Add this info section
                                    Text("Supported file types: HTML, JSON, XML, JavaScript, CSS, text files, and images (JPEG, PNG, GIF, SVG)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    + Text("\nMaximum file size: \(ByteCountFormatter.string(fromByteCount: MapLocalConfig.maxFileSize, countStyle: .file))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    // The rest
                    else {
                        // Request Section
                        Text("Request")
                            .font(.headline)
                            .padding(.horizontal, 10)
                        
                        SectionWrapper {
                            Picker("Request Protocol", selection: $reqProtocol) {
                                ForEach(RequestProtocolType.allCases) { option in
                                    Text(option.rawValue)
                                }
                            }
                            .frame(width: 200)
                            
                            HStack {
                                Text("URL")
                                PrefixedTextField(prefix: selectedHost.host, text: $path, placeholder: selectedHost.host == "All traffic" ? "mysite.com/path?*" : "/path?*") { newValue in
                                    path = newValue
                                }
                                testPatternButton
                            }
                            Picker("URL Matching Type", selection: $urlMatcherType) {
                                ForEach(UrlMatcherType.allCases) { option in
                                    Text(option.rawValue)
                                }
                            }
                            .frame(width: 250)
                            Picker("Method", selection: $requestMethod) {
                                ForEach(RequestMethodOption.allCases) { option in
                                    Text(option.rawValue)
                                }
                            }
                            .frame(width: 150)
                            
                            HStack {
                                Button("Edit Request Headers") {
                                    openPopup(headers: $reqHeaders)
                                }
            //                    Button("Advanced...") {}
                            }
                            .padding(.top)
                        }
                        
                        // Response Section
                        Text("Response")
                            .font(.headline)
                            .padding(.horizontal, 10)
                        
                        SectionWrapper {
                            HStack {
                                Picker("Status", selection: $responseSelected) {
                                    Text("Success").tag("Success")
                                    Text("Failure").tag("Failure")
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .frame(width: 250)
                            }
                            HStack {
                                if responseSelected == "Success" {
                                    Picker("Status Code", selection: $statusCodeSuccess) {
                                        ForEach(HTTPSuccessStatus.allCases, id: \.self) { option in
                                            Text(option.description)
                                        }
                                    }
                                    .frame(width: 250)
                                    .pickerStyle(MenuPickerStyle())
                                }
                                if responseSelected == "Failure" {
                                    Picker("Status Code", selection: $statusCodeFailure) {
                                        ForEach(HTTPFailureStatus.allCases, id: \.self) { option in
                                            Text(option.description)
                                        }
                                    }
                                    .frame(width: 250)
                                    .pickerStyle(MenuPickerStyle())
                                }
                            }
                            HStack {
                                Button("Edit Response Headers") {
                                    openPopup(headers: $rspHeaders)
                                }
            //                    Button("Advanced...") {}
                            }
                            .padding(.top)
                        }
                        
                        // Response Body Section
                        Toggle(isOn: $includeRspBodyChecked) {
                            Text("Add response body")
                        }
                        .toggleStyle(CheckboxToggleStyle())
                        .padding(.horizontal, 10)
                        
                        if includeRspBodyChecked {
                            SyntaxTextEditor(text: $responseBody, rspHeaders: $rspHeaders)
                                        .frame(height: 150)
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                        )
                                        .padding(.horizontal, 10)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            
            // Sticky footer
            VStack {
                Divider()
                
                HStack {
                    Spacer()
                    Button(existingRule == nil ? "Create override" : "Save changes") {
                        if existingRule != nil {
                            updateRule()
                        } else {
                            createRule()
                        }
                    }
                    .disabled(disableForm)
                    .padding(.horizontal, 10)
                }
                .padding()
            }
        }
        .alert("Free Version Limit", isPresented: $showLimitAlert) {
            Button("Upgrade") {
                dismiss()
                licenseManager.showPurchaseWindow()
            }
            Button("Cancel", role: .cancel) {
                // Do nothing, just dismiss the alert
            }
        } message: {
            Text("The free version is limited to 1 override. Please upgrade to add more overrides.")
        }
        .frame(minWidth: 500)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 700)
    }
    
    func openPopup(headers: Binding<[HeaderEntry]>) {
        let windowWidth: CGFloat = 500
        let windowHeight: CGFloat = 500
        
        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        
        popupWindow.isReleasedWhenClosed = false
        popupWindow.alphaValue = 0
        popupWindow.titleVisibility = .hidden
        popupWindow.titlebarAppearsTransparent = true
        popupWindow.styleMask.remove(.closable)
        popupWindow.styleMask.remove(.miniaturizable)
        popupWindow.styleMask.remove(.resizable)
        
        let popupViewController = NSHostingController(rootView: EditHeaderPopupContentView(headers: headers) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                popupWindow.animator().alphaValue = 0
            } completionHandler: {
                popupWindow.close()
                if let preferencesWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "rule-modal" }) {
                    preferencesWindow.makeKeyAndOrderFront(nil)
                }
            }
        })
        
        popupWindow.contentViewController = popupViewController
        
        if let parentWindow = NSApplication.shared.mainWindow {
            let parentFrame = parentWindow.frame
            let xPos = parentFrame.minX + (parentFrame.width - windowWidth) / 2
            let yPos = parentFrame.maxY - windowHeight
            popupWindow.setFrameOrigin(NSPoint(x: xPos, y: yPos))
        }
        
        popupWindow.makeKeyAndOrderFront(nil)
        
        popupWindow.animator().alphaValue = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            popupWindow.animator().setFrame(popupWindow.frame.insetBy(dx: 0, dy: 0), display: true)
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                popupWindow.animator().setFrame(popupWindow.frame.insetBy(dx: 0, dy: 0), display: true)
            }
        }
    }
    
    func createRule() {
        // Check license limits using bridge API
        Task {
            do {
                let currentRules = try await ReqResCoreModelBridge.findAllRules()
                let currentRulesCount = currentRules.count
                let isProUser = licenseManager.isProUser()
                let isLimited = currentRulesCount >= 1 && !isProUser
                
                if isLimited {
                    await MainActor.run {
                        showLimitAlert = true
                    }
                    return
                }
                
                // Create new RuleCodable
                let newRule = RuleCodable(
                    id: UUID(),
                    path: getPathnameAndQueryFromInputPath() ?? "",
                    hostId: selectedHost.hostDbId ?? NSNumber(value: 0), // Provide default value for optional
                    enabled: NSNumber(value: true),
                    isRegexp: NSNumber(value: urlMatcherType == .REGEX),
                    isWildCard: NSNumber(value: urlMatcherType == .WILDCARD),
                    ruleMode: ruleMode,
                    reqProtocol: reqProtocol.rawValue,
                    reqMethod: requestMethod.rawValue,
                    reqHeaders: encodeHeaders(reqHeaders),
                    rspHeaders: encodeHeaders(rspHeaders),
                    rspCode: responseSelected == "Success" ? NSNumber(value: statusCodeSuccess.rawValue) : NSNumber(value: statusCodeFailure.rawValue),
                    rspBody: includeRspBodyChecked ? responseBody.trimmingCharacters(in: .whitespaces) : "",
                    rspPath: selectedFileURL?.path ?? "",
                    modelRealId: nil, // New rule, so no database ID yet
                )
                
                AppState.shared.upsertRule(newRule)
                
                await MainActor.run {
                    resetFormState()
                    dismiss()
                }
            } catch {
                // Handle error
                AppLog.shared.error("Error creating rule: \(error)")
            }
        }
    }
    
    // Update function for existing rules
    func updateRule() {
        guard let existingRule = existingRule else { return }
        
        Task {
            do {
                // Create updated RuleCodable with existing modelRealId
                let updatedRule = RuleCodable(
                    id: existingRule.id, // Keep the same UUID
                    path: getPathnameAndQueryFromInputPath() ?? "",
                    hostId: selectedHost.hostDbId ?? NSNumber(value: 0), // Provide default value for optional
                    enabled: existingRule.enabled, // Keep existing enabled state
                    isRegexp: NSNumber(value: urlMatcherType == .REGEX),
                    isWildCard: NSNumber(value: urlMatcherType == .WILDCARD),
                    ruleMode: ruleMode,
                    reqProtocol: reqProtocol.rawValue,
                    reqMethod: requestMethod.rawValue,
                    reqHeaders: encodeHeaders(reqHeaders),
                    rspHeaders: encodeHeaders(rspHeaders),
                    rspCode: responseSelected == "Success" ? NSNumber(value: statusCodeSuccess.rawValue) : NSNumber(value: statusCodeFailure.rawValue),
                    rspBody: ruleMode == .MAP_LOCAL ? "" : (includeRspBodyChecked ? responseBody.trimmingCharacters(in: .whitespaces) : ""),
                    rspPath: ruleMode == .MAP_LOCAL ? (selectedFileURL?.path ?? (existingFileRemoved ? "" : existingRule.rspPath)) : "",
                    modelRealId: existingRule.modelRealId, // Keep the database ID
                )
                
                AppState.shared.upsertRule(updatedRule)
                
                await MainActor.run {
                    // Animate window close
                    if let window = NSApplication.shared.keyWindow {
                        NSAnimationContext.runAnimationGroup({ context in
                            context.duration = 0.25
                            window.animator().alphaValue = 0
                        }, completionHandler: {
                            window.close()
                        })
                    }
                }
            } catch {
                AppLog.shared.error("Error updating rule: \(error, privacy: .public)")
            }
        }
    }
    
    // Helper function to encode headers
    private func encodeHeaders(_ headers: [HeaderEntry]) -> String {
        guard let jsonData = try? JSONEncoder().encode(headers),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return ""
        }
        return jsonString
    }
    
    @ViewBuilder
    private var ruleModeDescription: some View {
        switch ruleMode {
        case .EXTEND:
            Text("Request and response will be extended with the items specificed below.").font(.subheadline)
        case .OVERRIDE:
            Text("Request and response will be completely replaced with the items specificed below.").font(.subheadline)
        case .MAP_LOCAL:
            Text("Choose a static local file to map as the response for your request.").font(.subheadline)
        }
    }
    
    @ViewBuilder
    private var testPatternButton: some View {
        Button(action: {
            openPatterMatchingTestPopup()
        }) {
            Label("Test", systemImage: "questionmark.circle")
                .font(.system(size: 14, weight: .medium)) // More refined font
//                .frame(maxWidth: .infinity) // Make the entire area tappable
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(height: 28) // Fixed height for consistency
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle()) // Clean base style
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.9)) // Slightly softer blue
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1) // Subtle shadow
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1) // Subtle inner glow
        )
        .foregroundColor(.white)
        .help("Test the URL pattern")
    }
    
    func getHostFromPath() -> String? {
        // for select hosts except "All traffic"
        if selectedHost.hostDbId?.int64Value != 0 { // Check if real host ID exists
            return selectedHost.host
        }
        // parse host from the input in case, it's "All traffic"
        if let url = URL(string: "\(reqProtocol.rawValue.lowercased())://\(path.trimmingCharacters(in: .whitespaces))"), let host = url.host {
            return host
        }
        return nil
    }
    
    func getPathnameAndQueryFromInputPath() -> String? {
        let _path = selectedHost.hostDbId?.int64Value != 0 ? "\(reqProtocol.rawValue.lowercased())://\(selectedHost.host)\(path)" : "\(selectedHost.requestProtocol.lowercased())://\(path)"
        if let url = URL(string: _path) {
            let path = url.path.trimmingCharacters(in: .whitespaces)
            let query = url.query?.trimmingCharacters(in: .whitespaces) ?? ""
            
            if !query.isEmpty {
                return "\(path)?\(query)"
            }
            return path
        }
        return nil
    }
    
    func resetFormState() {
        path = ""
        requestMethod = .GET
        urlMatcherType = .WILDCARD
        responseSelected = "Success"
        responseBody = ""
        statusCodeSuccess = .ok
        statusCodeFailure = .badRequest
        rspHeaders = [
            HeaderEntry(key: "Content-Type", value: "application/json; charset=utf-8", isEnabled: true)
        ]
        ruleMode = .EXTEND
        reqHeaders = []
        reqProtocol = .HTTPS
    }
    
    // yeah, copy-paste, I know
    func openPatterMatchingTestPopup() {
        let windowWidth: CGFloat = 500
        let windowHeight: CGFloat = 500
        
        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        
        popupWindow.isReleasedWhenClosed = false
        popupWindow.alphaValue = 0
        popupWindow.titleVisibility = .hidden
        popupWindow.titlebarAppearsTransparent = true
        popupWindow.styleMask.remove(.closable)
        popupWindow.styleMask.remove(.miniaturizable)
        popupWindow.styleMask.remove(.resizable)
        
        let popupViewController = NSHostingController(rootView: PatternMatchingPopupContentView() {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                popupWindow.animator().alphaValue = 0
            } completionHandler: {
                popupWindow.close()
                if let preferencesWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "rule-modal" }) {
                    preferencesWindow.makeKeyAndOrderFront(nil)
                }
            }
        })
        
        popupWindow.contentViewController = popupViewController
        
        if let parentWindow = NSApplication.shared.mainWindow {
            let parentFrame = parentWindow.frame
            let xPos = parentFrame.minX + (parentFrame.width - windowWidth) / 2
            let yPos = parentFrame.maxY - windowHeight
            popupWindow.setFrameOrigin(NSPoint(x: xPos, y: yPos))
        }
        
        popupWindow.makeKeyAndOrderFront(nil)
        
        popupWindow.animator().alphaValue = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            popupWindow.animator().setFrame(popupWindow.frame.insetBy(dx: 0, dy: 0), display: true)
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                popupWindow.animator().setFrame(popupWindow.frame.insetBy(dx: 0, dy: 0), display: true)
            }
        }
    }
}

struct EditHeaderPopupContentView: View {
    @Binding var headers: [HeaderEntry]
    let onClose: () -> Void
    
    var body: some View {
        VStack {
            HeaderListView(headers: $headers)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            HStack {
                Spacer()
                
                Button("Done") {
                    onClose()
                }
                .padding()
            }
        }
        .frame(width: 500, height: 500)
    }
}

struct PatternMatchingPopupContentView: View {
    let onClose: () -> Void
    
    var body: some View {
        VStack {
            PatternMatchingView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            HStack {
                Spacer()
                
                Button("Done") {
                    onClose()
                }
                .padding()
            }
        }
        .frame(width: 500, height: 650)
    }
}

struct RuleModal_Previews: PreviewProvider {
    
    static var previews: some View {
       AddRuleModalDemo()
    }
}

private struct AddRuleModalDemo: View {
    var host = HostCodable( // Updated to use HostCodable
        host: "example.com",
        port: NSNumber(value: 443),
        hostDbId: NSNumber(value: 1),
        requestProtocol: "HTTPS"
    )
    
    var body: some View {
        RuleModal(selectedHost: host)
    }
}

struct SectionWrapper<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 10) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8) // Rounded corners
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 10)
    }
}
