//
//  RuleModal.swift
//  ReqRes
//
//  Created by OloApps on 14.06.2023.
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
//  Create or edit an override rule.
//
//  A SHEET on the main window, laid out the way snipperapp's forms are: a
//  13pt semibold title with an 11pt context line, one label column (a Grid),
//  11pt secondary section captions over a Divider, inline validation under the
//  field it concerns, and Cancel · primary as the last row with the system
//  key equivalents. The pattern tester is a popover on the `?` beside the URL
//  field, bound to the rule's real pattern; the header editors are nested
//  sheets that edit a draft. This replaces a title-less resizable window whose
//  labels landed at four different x positions and whose helpers were
//  hand-built NSWindows positioned against the wrong window.
//

import SwiftUI
import Utils
import MCPKit
import XReqResCore

struct RuleModal: View {
    var selectedHost: HostCodable
    var existingRule: RuleCodable?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var licenseManager = LicenseManager.shared
    /// For `unreadableMapLocalFiles`: whether the existing rule's file can be read (F24).
    @ObservedObject private var appState = AppState.shared

    // Rule
    @State private var ruleMode: RuleMode = .EXTEND
    @State private var reqProtocol: RequestProtocolType = .HTTPS
    /// The stored method: `RuleMethod.any` ("") by default. The core honours
    /// a rule's method since 1.1.0, so the old GET default would make a new
    /// override silently skip the app's POSTs (and re-saving a migrated
    /// any-method rule used to write GET back).
    @State private var requestMethod: String = RuleMethod.any
    @State private var path = ""
    @State private var urlMatcherType: UrlMatcherType = .WILDCARD
    @State private var reqHeaders: [HeaderEntry] = []
    /// What a new rule in the form's opening mode (Extend) starts with: keep
    /// the server's status, stored 0 (core 95062d1). The 200 every form used
    /// to start with turned every 404 and 500 an Extend rule touched into a
    /// 200 (F17). An Override starts at 200; Map Local shows none and stores
    /// 0; a mode change carries the default with it — `RuleResponseDefaults`.
    @State private var status: RuleStatus = RuleResponseDefaults.status(forNewRuleIn: .extend)
    /// What a new rule in the form's opening mode (Extend) starts with: no
    /// response header. The JSON Content-Type this used to hold in every mode
    /// relabelled every response an Extend rule touched, and every file a Map
    /// Local rule served, as JSON (F17). Only an Override gets it, and a mode
    /// change adds or drops it — `RuleResponseDefaults`.
    @State private var rspHeaders: [HeaderEntry] = RuleResponseDefaults.headers(forNewRuleIn: .extend)
    @State private var includeRspBody = false
    @State private var responseBody = ""

    // Map Local
    @State private var selectedFileURL: URL?
    @State private var existingFileRemoved = false
    @State private var showingFilePicker = false
    @State private var fileError: String?

    // Presentation
    @State private var editingHeaders: HeaderEditorTarget?
    @State private var showingPatternTester = false
    @State private var freeLimitReached = false
    @State private var saveError: String?
    @FocusState private var pathFocused: Bool

    private enum HeaderEditorTarget: String, Identifiable {
        case request, response
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(existingRule == nil ? "New Override" : "Edit Override")
                    .font(.system(size: 13, weight: .semibold))
                Text(scopeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if freeLimitReached {
                limitNotice
            } else if !isRealHost {
                hostNotice
            }

            modeSection

            // ONE grid for every labelled row, so Request and Response share
            // a label column; the section captions span both columns.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                captionRow("Request")
                requestRows
                if ruleMode == .MAP_LOCAL {
                    captionRow("Local File")
                    localFileRows
                } else {
                    captionRow("Response")
                    responseRows
                }
            }

            if ruleMode != .MAP_LOCAL, includeRspBody {
                SyntaxTextEditor(text: $responseBody, rspHeaders: $rspHeaders)
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }

            if let message = validationMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let saveError {
                Text(saveError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(existingRule == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 480)
        .disabled(freeLimitReached || !isRealHost)
        .sheet(item: $editingHeaders) { target in
            switch target {
            case .request:
                HeaderEditorSheet(title: "Request Headers", headers: $reqHeaders)
            case .response:
                HeaderEditorSheet(title: "Response Headers", headers: $rspHeaders)
            }
        }
        .fileImporter(isPresented: $showingFilePicker,
                      allowedContentTypes: MapLocalConfig.supportedTypes,
                      allowsMultipleSelection: false, onCompletion: fileChosen)
        .onAppear {
            seedFromExistingRule()
            checkFreeLimit()
            pathFocused = true
        }
    }

    // MARK: - Sections

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            // Through `changeMode`, not `$ruleMode`: a change the USER makes
            // carries the response headers' default with it. Seeding an
            // existing rule sets `ruleMode` directly and changes no header.
            Picker("Mode", selection: Binding(get: { ruleMode }, set: { changeMode(to: $0) })) {
                ForEach(RuleMode.allCases) { mode in
                    Text(Self.title(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(modeDescription)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var requestRows: some View {
        GridRow {
            gridLabel("Protocol")
            Picker("Protocol", selection: $reqProtocol) {
                ForEach(RequestProtocolType.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        GridRow {
            gridLabel("Method")
            Picker("Method", selection: $requestMethod) {
                ForEach(RuleMethod.formChoices(forStored: existingRule?.reqMethod ?? RuleMethod.any), id: \.self) {
                    Text(RuleMethod.displayName($0)).tag($0)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        GridRow {
            gridLabel("URL")
            HStack(spacing: 6) {
                if isRealHost {
                    // No frame and no priority: HStack sizes this (the less flexible
                    // child) first at its natural width, the field takes the rest; a
                    // very long host truncates in the middle at about half the row.
                    Text(selectedHost.host)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TextField(urlPlaceholder, text: $path)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($pathFocused)
                Button {
                    showingPatternTester = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Test this pattern against a URL, and see the wildcard and regex rules")
                .popover(isPresented: $showingPatternTester, arrowEdge: .bottom) {
                    PatternTesterPopover(
                        path: storedPath,
                        scheme: reqProtocol.rawValue,
                        host: isRealHost ? selectedHost.host : nil,
                        matchType: urlMatcherType
                    )
                }
            }
        }
        GridRow {
            gridLabel("Match")
            Picker("Match", selection: $urlMatcherType) {
                ForEach(UrlMatcherType.allCases) { Text(Self.title(for: $0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        GridRow {
            gridLabel("Headers")
            headersRow(count: reqHeaders.count, target: .request)
        }
    }

    @ViewBuilder
    private var responseRows: some View {
        GridRow {
            gridLabel("Status")
            // ONE menu: "Keep server's status" first where the mode keeps it
            // (Extend), then the codes by class — plus the rule's own when
            // the list lacks it (a 302 a mock copied), so saving an unchanged
            // rule never changes its status. Flexible: a popup sized to its
            // longest title ("511 Network Authentication Required") is wider
            // than the row.
            Picker("Status", selection: $status) {
                ForEach(statusMenu, id: \.self) { group in
                    Section {
                        ForEach(group.statuses, id: \.self) { Text(Self.title(for: $0)).tag($0) }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        GridRow {
            gridLabel("Headers")
            headersRow(count: rspHeaders.count, target: .response)
        }
        GridRow {
            gridLabel("Body")
            Toggle("Add a response body", isOn: $includeRspBody)
                .toggleStyle(.checkbox)
        }
    }

    @ViewBuilder
    private var localFileRows: some View {
        GridRow {
            gridLabel("File")
            HStack(spacing: 8) {
                if let url = selectedFileURL {
                    fileLabel(name: url.lastPathComponent, size: fileSize(of: url))
                    Button {
                        selectedFileURL = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Remove")
                } else if let existingPath = existingFilePath {
                    fileLabel(name: (existingPath as NSString).lastPathComponent,
                              size: fileSize(of: URL(fileURLWithPath: existingPath)))
                    Button {
                        existingFileRemoved = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Remove")
                } else {
                    Text("No file selected")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(hasFile ? "Change…" : "Choose…") { showingFilePicker = true }
            }
        }
        GridRow {
            Color.clear.frame(width: 0, height: 0)
            Text("HTML, JSON, XML, JavaScript, CSS, text and images (JPEG, PNG, GIF, SVG), up to \(ByteCountFormatter.string(fromByteCount: MapLocalConfig.maxFileSize, countStyle: .file)).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let existingPath = existingFilePath, existingFileUnreadable {
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Label(MapLocalUnreadable.formMessage(fileName: (existingPath as NSString).lastPathComponent),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The file is sent with the rule's response headers (a CORS header,
        // say), so they are shown here like every other mode's — and a Map
        // Local rule stores what this row shows, no more (F17: the old form
        // hid them here and still saved its JSON Content-Type over the file's
        // own type). A new Map Local rule starts with none. No Status row:
        // the core never uses a Map Local rule's status — the file answers
        // 200, and a missing one forwards the server's response unchanged —
        // so it stores 0 (`RuleResponseDefaults.storedStatus`).
        GridRow {
            gridLabel("Headers")
            headersRow(count: rspHeaders.count, target: .response)
        }
    }

    /// Rules are keyed to a host row; "All traffic" has none, so saving here
    /// always failed a foreign-key check — silently, until 2026-09-17.
    private var hostNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Text("Overrides apply to one host. Select a host filter in the sidebar — or add one with ＋ — and create the override there.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var limitNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text("The free version includes one override. Upgrade for unlimited overrides.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // The sheet opens with Reached on this limit's row.
            Button("Upgrade…") {
                dismiss()
                PaywallPresentation.shared.show(.rules)
            }
            .disabled(false)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        // The notice must stay usable while the rest of the form is disabled.
        .disabled(false)
    }

    // MARK: - Row helpers

    private func captionRow(_ title: String) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            .gridCellColumns(2)
        }
    }

    private func gridLabel(_ title: String) -> some View {
        Text(title)
            .frame(minWidth: 64, alignment: .leading)
    }

    private func headersRow(count: Int, target: HeaderEditorTarget) -> some View {
        HStack(spacing: 8) {
            Button("Edit…") { editingHeaders = target }
            Text(count == 1 ? "1 header" : "\(count) headers")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func fileLabel(name: String, size: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let size {
                Text(size)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Derived

    /// A host filter has a database id; "All traffic" is the virtual host
    /// (`hostDbId == nil`). The old check `hostDbId?.int64Value != 0` was
    /// TRUE for nil, so every override created under "All traffic" was built
    /// as "https://All traffic/…", failed to parse, and was saved with an
    /// empty path.
    private var isRealHost: Bool {
        guard let id = selectedHost.hostDbId else { return false }
        return id.int64Value != 0
    }

    private var scopeDescription: String {
        isRealHost ? selectedHost.host : "Any host"
    }

    private var urlPlaceholder: String {
        urlMatcherType == .REGEX ? "/api/.*$" : "/path?*"
    }

    private var modeDescription: String {
        switch ruleMode {
        case .EXTEND: return "Matching requests and responses are extended with the items below."
        // Two behaviours, so two sentences (core c7acefc): with a body ReqRes
        // answers itself; without one the request is forwarded and only the
        // answer's status and headers are replaced — its body passes through.
        case .OVERRIDE: return "With a response body, ReqRes answers by itself and the server never sees the request. Without one, the request still goes to the server, and its answer gets the status and headers below."
        case .MAP_LOCAL: return "Matching requests are answered with a local file."
        }
    }

    private static func title(for mode: RuleMode) -> String {
        switch mode {
        case .EXTEND: return "Extend"
        case .OVERRIDE: return "Override"
        case .MAP_LOCAL: return "Map Local"
        }
    }

    private static func title(for type: UrlMatcherType) -> String {
        switch type {
        case .WILDCARD: return "Wildcard"
        case .REGEX: return "Regex"
        }
    }

    /// The Status menu for the form's mode and status (`RuleResponseDefaults
    /// .statusMenu`): the codes it always lists are the two enums', and the
    /// status the rule opened with stays offered after another is picked.
    private var statusMenu: [RuleStatusMenuGroup] {
        RuleResponseDefaults.statusMenu(for: MCPRuleAdapter.mcpMode(ruleMode), listing: Self.listedStatusCodes,
                                        current: status, opened: openedStatus)
    }

    /// What `seedFromExistingRule` opened the Status menu with; nil for a new rule.
    private var openedStatus: RuleStatus? {
        existingRule.map { RuleResponseDefaults.status(seeding: $0.rspCode.intValue, mode: MCPRuleAdapter.mcpMode($0.ruleMode)) }
    }

    private static let listedStatusCodes = HTTPSuccessStatus.allCases.map(\.rawValue) + HTTPFailureStatus.allCases.map(\.rawValue)

    /// "Keep server's status", the enums' "404 Not Found", or — for a code
    /// they do not list — the code and the system's name for it ("302 Found").
    private static func title(for status: RuleStatus) -> String {
        switch status {
        case .keep:
            return RuleResponseDefaults.keepServerStatusTitle
        case .code(let code):
            return HTTPSuccessStatus(rawValue: code)?.description
                ?? HTTPFailureStatus(rawValue: code)?.description
                ?? "\(code) \(HTTPURLResponse.localizedString(forStatusCode: code).capitalized)"
        }
    }

    private var existingFilePath: String? {
        guard let rspPath = existingRule?.rspPath, !rspPath.isEmpty, !existingFileRemoved else { return nil }
        return rspPath
    }

    private var hasFile: Bool { selectedFileURL != nil || existingFilePath != nil }

    /// The existing file is one ReqRes could not read at the last rules push (F24).
    private var existingFileUnreadable: Bool {
        guard let path = existingFilePath else { return false }
        return appState.unreadableMapLocalFiles.contains(path)
    }

    private func fileSize(of url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private var validationMessage: String? {
        let typed = path.trimmingCharacters(in: .whitespaces)
        if urlMatcherType == .REGEX, !typed.isEmpty {
            do { _ = try NSRegularExpression(pattern: typed) } catch {
                return "Not a valid regular expression."
            }
            // ReqRes matches `scheme://host` + this pattern, so an anchor here
            // would sit mid-string and the rule would never fire.
            if typed.hasPrefix("^") {
                return "Remove the ^: ReqRes puts the host in front of your pattern, so an anchored one never matches. Write \(typed.dropFirst()) instead."
            }
            if !typed.hasPrefix("/") {
                return "Start the pattern at the path, with /: ReqRes appends it directly after the host."
            }
        }
        if ruleMode == .MAP_LOCAL, !hasFile, !typed.isEmpty {
            return "Choose the file to answer with."
        }
        if let fileError { return fileError }
        return nil
    }

    private var canSave: Bool {
        guard !freeLimitReached, isRealHost, validationMessage == nil else { return false }
        let typed = path.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return false }
        if urlMatcherType == .REGEX, (try? NSRegularExpression(pattern: typed)) == nil { return false }
        if ruleMode == .MAP_LOCAL, !hasFile { return false }
        return true
    }

    // MARK: - Actions

    private func seedFromExistingRule() {
        guard let rule = existingRule else { return }
        path = rule.path
        requestMethod = RuleMethod.formSelection(forStored: rule.reqMethod)
        urlMatcherType = rule.isRegexp.boolValue ? .REGEX : .WILDCARD
        reqProtocol = RequestProtocolType(rawValue: rule.reqProtocol) ?? .HTTPS
        ruleMode = rule.ruleMode
        // As the core reads it: 0 (the core's migration of the form's
        // untouched Extend rules) opens as "Keep server's status" — build
        // 52's form opened it as 400 and saved that — and a code the menu
        // does not list (a mock's 302) opens as itself, not as 400.
        status = RuleResponseDefaults.status(seeding: rule.rspCode.intValue, mode: MCPRuleAdapter.mcpMode(rule.ruleMode))
        if !rule.rspBody.isEmpty {
            responseBody = rule.rspBody
            includeRspBody = true
        }
        // What the Headers row shows, and saves back: as stored, but a Map
        // Local rule's untouched JSON default is left out (F17 — it only ever
        // replaced the file's own type; `RuleResponseDefaults`).
        if let headers = Self.decodeHeaders(rule.rspHeaders) {
            rspHeaders = RuleResponseDefaults.headers(seeding: headers, mode: MCPRuleAdapter.mcpMode(rule.ruleMode))
        }
        if let headers = Self.decodeHeaders(rule.reqHeaders) {
            reqHeaders = headers
        }
    }

    /// The Mode picker's setter. The response headers and the status follow
    /// the new mode — the default Content-Type is an Override's alone, the
    /// default status is Extend's "keep" and Override's 200, and what the
    /// user chose stays — and then the mode changes: one call, so the old
    /// mode is read before it is written (`RuleResponseDefaults.changeMode`,
    /// tested in MCPKit).
    private func changeMode(to newMode: RuleMode) {
        RuleResponseDefaults.changeMode(&ruleMode, headers: &rspHeaders, status: &status, to: newMode, as: MCPRuleAdapter.mcpMode)
    }

    private static func decodeHeaders(_ raw: String) -> [HeaderEntry]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([HeaderEntry].self, from: data)
    }

    /// The free tier allows one override. Say so when the form OPENS, not
    /// after the whole thing has been filled in.
    private func checkFreeLimit() {
        guard existingRule == nil, !licenseManager.isProUser() else { return }
        Task {
            let count = (try? await ReqResCoreModelBridge.findAllRules().count) ?? 0
            await MainActor.run { freeLimitReached = FreeTier.overrideRuleLimitReached(existing: count) }
        }
    }

    private func fileChosen(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try MapLocalConfig.validateFile(at: url)
                // Keep the sandbox's grant for this file beyond this process (F24).
                MapLocalFileAccess.shared.remember(url)
                selectedFileURL = url
                fileError = nil
            } catch MapLocalError.fileTooLarge(let size) {
                fileError = "That file is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)); the limit is \(ByteCountFormatter.string(fromByteCount: MapLocalConfig.maxFileSize, countStyle: .file))."
            } catch MapLocalError.unsupportedFileType(let name) {
                fileError = "\(name) is not a supported file type."
            } catch {
                fileError = error.localizedDescription
            }
        case .failure(let error):
            fileError = error.localizedDescription
        }
    }

    /// The path as stored: pathname + query — see `OverridePattern.storedPath`
    /// for the rules (and the bug they fix).
    private var storedPath: String {
        OverridePattern.storedPath(path, isRegex: urlMatcherType == .REGEX)
    }

    private func save() {
        let rule = RuleCodable(
            id: existingRule?.id ?? UUID(),
            path: storedPath,
            hostId: selectedHost.hostDbId ?? NSNumber(value: 0),
            enabled: existingRule?.enabled ?? NSNumber(value: true),
            isRegexp: NSNumber(value: urlMatcherType == .REGEX),
            isWildCard: NSNumber(value: urlMatcherType == .WILDCARD),
            ruleMode: ruleMode,
            reqProtocol: reqProtocol.rawValue,
            reqMethod: requestMethod,
            reqHeaders: encode(reqHeaders),
            // What the Headers row shows, in every mode — Map Local's too.
            rspHeaders: encode(rspHeaders),
            // What the Status menu shows: 0 for "Keep server's status", and
            // for Map Local, which shows none and whose status is never used.
            rspCode: NSNumber(value: RuleResponseDefaults.storedStatus(status, mode: MCPRuleAdapter.mcpMode(ruleMode))),
            rspBody: ruleMode == .MAP_LOCAL ? "" : (includeRspBody ? responseBody.trimmingCharacters(in: .whitespaces) : ""),
            rspPath: ruleMode == .MAP_LOCAL ? (selectedFileURL?.path ?? existingFilePath ?? "") : "",
            modelRealId: existingRule?.modelRealId
        )
        AppState.shared.upsertRule(rule)
        dismiss()
    }

    /// Always valid JSON — the core skips a rule whose `reqHeaders` it cannot
    /// decode, and "" is not a decodable empty list.
    private func encode(_ headers: [HeaderEntry]) -> String {
        guard let data = try? JSONEncoder().encode(headers),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }
}

/// So the form's response-header decisions are `RuleResponseDefaults`'s.
extension HeaderEntry: RuleHeaderEntry {
    var ruleHeaderName: String { key }
    var ruleHeaderValue: String { value }
    var ruleHeaderIsEnabled: Bool { isEnabled }

    static func ruleHeader(name: String, value: String) -> HeaderEntry {
        HeaderEntry(key: name, value: value, isEnabled: true)
    }
}
