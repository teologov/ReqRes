//
//  AppView.swift
//  ReqRes
//
//  Created by OloApps on 14.06.2023.
//  example apps https://github.com/donarb/swiftui-macos
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

import NetworkExtension
import SwiftUI
import Utils
import XReqResCore

let FEEDBACK_URL = "https://github.com/OloApps/ReqRes/issues/new/choose"

struct AppView: View {
    var appController: AppController = AppController.shared
    @ObservedObject var appStateModel: AppState = AppState.shared
    @ObservedObject private var licenseManager = LicenseManager.shared
    @ObservedObject private var certificateAuthority = CertificateAuthorityService.shared
    /// Who opened the ReqRes Pro sheet, and which limit did.
    @ObservedObject private var paywall = PaywallPresentation.shared

    @State private var showingAddHost = false
    @State private var showingNewOverride = false
    /// Whether the ReqRes Pro sheet is up in this window. Raised when
    /// LicenseManager asks for it (`shouldShowPurchaseWindow` turning true),
    /// and only in the one window PaywallPresentation picks; lowered only by
    /// the sheet itself (Continue with Free Version, Done): LicenseManager
    /// turns its flag off whenever Pro is granted, and an activation made in
    /// the sheet must leave it up as the licensed sheet with Done.
    @State private var paywallShown = false
    /// This window, to PaywallPresentation: with several main windows (File ▸
    /// New Window), exactly one shows the ReqRes Pro sheet.
    @State private var windowToken = UUID()

    @State private var viewDidLoad = false
    /// One AppKit toolbar per window — see `ReqResToolbarController`.
    @State private var toolbar = ReqResToolbarController()

    var body: some View {
        // A real NSSplitViewController, not `NavigationSplitView`: the
        // toolbar's tracking separators need an actual NSSplitView to anchor
        // to, and on macOS 26 `NavigationSplitView` is not NSSplitView-backed.
        ReqResSplitHost(
            toolbar: toolbar,
            toolbarSlots: {
                ReqResToolbarController.SlotViews(
                    host: AnyView(HostSwitcherSlot()),
                    capture: AnyView(CaptureToolbarSlot()),
                    tools: AnyView(TrafficToolsSlot()),
                    inspections: AnyView(InspectionsGaugeSlot())
                )
            },
            sidebar: AnyView(HostSidebarView()),
            overrides: AnyView(RulesListWrap()),
            traffic: AnyView(SessionContentView())
        )
        // The split view owns the whole window: the sidebar material runs
        // full-height under the titlebar, and AppKit gives the panes their
        // content insets.
        .ignoresSafeArea()
        // No window title, ever: pinned to "" so SwiftUI never falls back to
        // the app name. AppKit's title view has a 160pt floor and cannot
        // overflow, which broke the toolbar's section anchoring whenever the
        // sidebar was collapsed. The selected host is the toolbar's host chip;
        // its request count is the sidebar row's badge.
        .navigationTitle("")
        .onAppear(perform: boostrapApp)
        .onDisappear(perform: onDisappear)
        // The ＋ menu, its overflow row and the File menu all post the same
        // notifications, so every path lands here. Both forms are SHEETS on
        // this window (snipperapp's only form pattern) — not title-less
        // windows of their own.
        .onReceive(NotificationCenter.default.publisher(for: ReqResToolbarController.addHostFilter)) { _ in
            showingAddHost = true
        }
        .onReceive(NotificationCenter.default.publisher(for: ReqResToolbarController.createOverride)) { _ in
            showingNewOverride = appStateModel.selectedHost != nil
        }
        .sheet(isPresented: $showingAddHost) {
            AddHostModal()
        }
        .sheet(isPresented: $showingNewOverride) {
            if let host = appStateModel.selectedHost {
                RuleModal(selectedHost: host)
            }
        }
        // The ReqRes Pro sheet: at launch without a license, and whenever a
        // person opens it (a limit's Upgrade…, the inspector's limit, the
        // toolbar gauge, the sidebar badge, through PaywallPresentation).
        // Return is Buy only when a person opened it.
        .sheet(isPresented: $paywallShown, onDismiss: paywallDismissed) {
            SubscriptionSettingsView(isInPreferences: false, planSheet: .reqres,
                                     reachedGainID: paywall.reached?.rawValue,
                                     returnKeyBuys: paywall.openedByPerson)
        }
        // Only ever raises the sheet, and only in the window that owns it:
        // the one a person opened it from, else the key or frontmost main
        // window (PaywallPresentation). LicenseManager turns the flag off on
        // every grant and on every activation attempt once the free version
        // is unlocked, failed ones included; lowering the sheet then would
        // take the licensed sheet or the activation's error with it.
        .onChange(of: licenseManager.shouldShowPurchaseWindow, initial: true) { _, shows in
            if shows && paywall.claimSheet(for: windowToken) {
                paywallShown = true
            }
        }
        // The owner changed while the flag is up: a person opened the sheet
        // from this window, or the window that showed it closed and the
        // sheet moves to one still open.
        .onChange(of: paywall.sheetOwner) { _, _ in
            if licenseManager.shouldShowPurchaseWindow && paywall.claimSheet(for: windowToken) {
                paywallShown = true
            }
        }
        // How PaywallPresentation finds this window: through its toolbar,
        // held weakly, so a closed window's controller is not kept alive.
        .onAppear {
            let controller = toolbar
            paywall.register(windowToken) { [weak controller] in controller?.hostWindow }
        }
        // An older "ReqRes CA" is still in the keychain (the 1.0.x shared
        // one, whose key is public): offered at every launch until replaced.
        // Held back while the ReqRes Pro sheet is up — a window presents one
        // sheet at a time, and the second request would be dropped.
        .sheet(isPresented: Binding(
            get: { certificateAuthority.migrationOffered && !paywallShown },
            set: { if !$0 { certificateAuthority.migrationOffered = false } }
        )) {
            CAMigrationSheet()
        }
        .task { await certificateAuthority.offerAtLaunch() }
        // Capture could not start: another program holds the proxy's port.
        // Asked, never hopped silently — shell profiles pin the number.
        .alert(
            appStateModel.proxyPortConflict.map { ProxyPortSetting.conflictTitle(port: $0.port) } ?? "",
            isPresented: Binding(get: { appStateModel.proxyPortConflict != nil },
                                 set: { if !$0 { appStateModel.proxyPortConflict = nil } }),
            presenting: appStateModel.proxyPortConflict
        ) { conflict in
            if let suggestion = conflict.suggestion {
                Button(ProxyPortSetting.useButton(suggestion)) {
                    UserDefaults.standard.set(suggestion, forKey: ProxyPortSetting.defaultsKey)
                    appStateModel.proxyPortConflict = nil
                    // A start, never a toggle: if capture was started another
                    // way while this alert stood open (the menu bar, ⌘⇧C, an
                    // agent), a toggle would have stopped it. `startCapture`
                    // shows a running tunnel instead of stopping it (F11).
                    if appStateModel.vpnStatus == .disconnected || appStateModel.vpnStatus == .invalid {
                        AppController.shared.startCapture()
                    }
                }
            }
            Button("Cancel", role: .cancel) { appStateModel.proxyPortConflict = nil }
        } message: { conflict in
            Text(verbatim: ProxyPortSetting.conflictMessage(port: conflict.port, holder: conflict.holder, suggestion: conflict.suggestion))
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
                    // Screenshot mode seeds a believable capture IN MEMORY —
                    // Debug and Release share one app group, so nothing here
                    // may touch the store.
                    if ScreenshotMocks.isEnabled {
                        foundHosts.append(contentsOf: ScreenshotMocks.hosts())
                    }
                    await MainActor.run {
                        appStateModel.selectedHost = foundHosts[0]
                        if ScreenshotMocks.isEnabled {
                            appStateModel.rules = ScreenshotMocks.rules()
                            for session in ScreenshotMocks.sessions() {
                                SessionState.shared.addSession(session: session)
                            }
                        } else {
                            addMockSessions()
                        }
                    }
                    #endif
                    
                    await MainActor.run {
                        appStateModel.hosts = foundHosts
                        appStateModel.selectedHost = appStateModel.hosts.first
                        viewDidLoad = true
                    }
                    #if DEBUG
                    if ScreenshotMocks.isEnabled {
                        // Selecting a host reloads rules from the store, which
                        // would wipe the in-memory seed; re-apply once that has
                        // settled, and clear the launch paywall so the capture
                        // shows the app rather than the price list.
                        // The sheet follows LicenseManager's flag only up,
                        // so it is lowered here as well.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            appStateModel.rules = ScreenshotMocks.rules()
                            LicenseManager.shared.dismissPurchaseWindow()
                            paywallShown = false
                        }
                    }
                    #endif
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
    
    /// This window has closed: PaywallPresentation forgets it, and if it
    /// showed the ReqRes Pro sheet, a window still open takes the sheet (its
    /// `sheetOwner` change).
    func onDisappear() {
        paywall.windowClosed(windowToken)
    }

    /// The ReqRes Pro sheet has gone from this window, however it went. Only
    /// the window that showed it answers for it: LicenseManager forgets the
    /// request, and the next sheet starts with no limit reached, opened by
    /// nobody and owned by no window.
    private func paywallDismissed() {
        guard paywall.ownsSheet(windowToken) else { return }
        licenseManager.dismissPurchaseWindow()
        paywall.reset()
    }
}

// MARK: - Panes
//
// Each pane is plain SwiftUI hosted inside an `NSSplitViewItem`. There are NO
// header rows: the selected host is the toolbar's chip, request counts are
// the sidebar rows' badges, and the licence badge lives in the sidebar footer
// — the arrangement this app settled on. A header band
// across the panes reads as a second toolbar line.

/// Sidebar: "All traffic" plus the user's host filters, over a footer that
/// carries the licence state.
struct HostSidebarView: View {
    @ObservedObject var appStateModel = AppState.shared

    /// OPAQUE, and the exact value AppKit's own divider measures at.
    ///
    /// `NSColor.separatorColor` is translucent white in dark mode; over the
    /// sidebar's vibrancy it composited to `#FFFEFF` in a window capture —
    /// a glaring white line, and one this app's instruments cannot judge,
    /// because `cacheDisplay` flattens that vibrancy.
    /// An opaque grey removes the compositing from the question: sampling
    /// the divider AppKit DOES draw, between the overrides and traffic
    /// panes, gives `#434343` in dark mode and `#EAEAEA` in light, so this
    /// matches it and the window has one separator value rather than two.
    /// As rendered it measures `#545454` dark / `#DDDDDD` light — a shade
    /// stronger than AppKit's in both, which is the right direction for the
    /// edge that was invisible in the first place.
    static let paneDivider = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x43 / 255, green: 0x43 / 255, blue: 0x43 / 255, alpha: 1)
            : NSColor(srgbRed: 0xD6 / 255, green: 0xD6 / 255, blue: 0xD6 / 255, alpha: 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $appStateModel.selectedHost) {
                if let allTraffic = appStateModel.hosts.first {
                    ListRowView(hostModel: allTraffic)
                        .tag(allTraffic)
                }
                // A plain string header takes the system sidebar-header
                // style; overriding the font fights it.
                Section("Filters") {
                    ForEach(appStateModel.hosts.dropFirst(), id: \.self) { host in
                        ListRowView(hostModel: host)
                            .tag(host)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            SidebarLicenseFooter()
        }
        // The sidebar draws its own trailing hairline, because AppKit does not.
        //
        // MEASURED in the running window rather than assumed: the split view
        // reports dividers at x=180 and x=381, and sampling those columns gives
        // `#434343` between the overrides and traffic panes — a real, visible
        // line — against `#0E0E0E` beside the sidebar, which is nothing. AppKit
        // leaves a `.sidebar` item's edge to the material, and in dark mode on
        // this Mac that material lands on the same value as the pane next to
        // it, so the two read as one block.
        //
        // Two fixes were tried and measured first, both worse:
        //  * Hiding the List's scroll background so the sidebar material shows
        //    through — the material is the thing that is not distinct here, so
        //    it changed nothing on screen.
        //  * Overriding `dividerColor` on an NSSplitView subclass — that means
        //    REPLACING the one NSSplitViewController builds for itself, and the
        //    replacement does not inherit its configuration: dividers came back
        //    9pt thick instead of 1pt and the sidebar collapsed to 10pt.
        //
        // Drawn on the SIDEBAR so it goes away with the pane when the sidebar
        // collapses, and in the same colour AppKit uses for the divider it does
        // draw, so the window has one separator style rather than two.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: Self.paneDivider))
                .frame(width: 1)
                // Up through the toolbar band as well. SwiftUI insets the
                // pane's content below the toolbar, so without this the line
                // started at y=60 and left the top strip unseparated — while
                // AppKit's own divider between the overrides and traffic panes
                // runs the full height, because its
                // `NSTrackingSeparatorToolbarItem` continues it there.
                // Measured at x=380: `#434343` from y=15 down.
                .ignoresSafeArea(.container, edges: .vertical)
                .accessibilityHidden(true)
        }
    }
}

struct RulesListWrap: View {
    @ObservedObject var appState = AppState.shared

    var body: some View {
        if appState.rules.isEmpty {
            EmptyStateView(
                title: "No Overrides",
                subtitle: "Create an override to start modifying requests and responses on the fly",
                iconName: "switch.2"
            )
        }
        else {
            RulesList()  // No need to pass rules anymore
        }
    }
}

struct RulesList: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var sessionState = SessionState.shared
    @State private var showDeleteConfirmation = false
    @State private var ruleToEdit: RuleCodable?
    // The key's spelling ships in every 1.0.x install, so it lives in
    // `SuppressibleConfirmations` rather than as a literal here — that is the
    // one place that knows which prompts a reset has to put back.
    @AppStorage(SuppressibleConfirmations.ruleDelete) private var skipDeleteConfirmation = false
    
    var body: some View {
        List(appState.rules, id: \.id) { rule in
            RuleView(rule: rule, ruleHost: appState.hosts.first(where: { host in
                if let hostDbId = host.hostDbId {
                    return rule.hostId.int64Value == hostDbId.int64Value
                }
                return false
            }) ?? nil, selectedHost: appState.selectedHost,
                     fileUnreadable: rule.ruleMode == .MAP_LOCAL && appState.unreadableMapLocalFiles.contains(rule.rspPath))
                .help("Modification rule for \(rule.path)")
                .id(rule.id)
                .contextMenu {
                    Button("Edit override...") {
                        ruleToEdit = rule
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
        .sheet(item: $ruleToEdit) { rule in
            RuleModal(selectedHost: host(for: rule) ?? appState.selectedHost ?? appState.hosts[0],
                      existingRule: rule)
        }
    }

    /// The host a rule belongs to, from the hosts already loaded; the
    /// virtual "All traffic" host has no database id and owns hostId-0 rules.
    private func host(for rule: RuleCodable) -> HostCodable? {
        appState.hosts.first { ($0.hostDbId?.int64Value ?? 0) == rule.hostId.int64Value }
    }
    
    func deleteRule(rule: RuleCodable) {
        guard let _ = rule.modelRealId else {
            AppLog.shared.error("Cannot delete rule without database ID")
            return
        }
        
        AppState.shared.deleteRule(rule)
    }
    
    /// Asks through the one confirmation alert. Delete with the box ticked
    /// turns the prompt off: the helper writes the key `skipDeleteConfirmation`
    /// reads, so the context menu above deletes without asking from then on.
    func showDeleteConfirmation(for rule: RuleCodable) {
        guard SuppressibleConfirmationAlert.confirm(
            title: "Delete Override",
            message: "Are you sure you want to delete this override?\n\nThis action cannot be undone.",
            actionTitle: "Delete",
            suppressionKey: SuppressibleConfirmations.ruleDelete
        ) else { return }
        deleteRule(rule: rule)
    }
}

/// A sidebar row: the host, with its live request count as a trailing badge
/// (Mail's arrangement). The count changes on every capture flush, and a
/// sidebar row is where that is cheap — the toolbar is not.
struct ListRowView: View {
    let hostModel: HostCodable
    @ObservedObject private var sessionState = SessionState.shared
    @AppStorage(SuppressibleConfirmations.hostDelete) private var skipHostDeleteConfirmation = false
    @AppStorage(CancelledRequestsSetting.defaultsKey) private var showCancelled = false

    private var isAllTraffic: Bool { hostModel.host == "All traffic" }
    /// The rows the list shows: client-cancelled requests hidden by D8 are
    /// not counted while they are hidden, or the badge and the list disagree.
    private var requestCount: Int {
        sessionState.visibleRequestCount(host: isAllTraffic ? nil : hostModel.host, showCancelled: showCancelled)
    }

    var body: some View {
        Label(hostModel.host, systemImage: isAllTraffic ? "square.grid.2x2" : "network")
            .font(.body)
            .truncationMode(.tail)
            .badge(requestCount > 0 ? Text("\(requestCount)").monospacedDigit() : nil)
            .accessibilityValue(requestCount == 1 ? "1 request" : "\(requestCount) requests")
        .contextMenu {
            if hostModel.host != "All traffic" {
                Button("Delete host...") {
                    if skipHostDeleteConfirmation {
                        AppState.shared.deleteHost(hostModel)
                    } else {
                        showDeleteConfirmation(for: hostModel)
                    }
                }
            }
        }
    }

    /// The ellipsis on "Delete host..." promised a dialog that was never
    /// built — the delete ran on the click. It is also the more destructive of
    /// the two deletions in this window: deleting ONE override asked, while
    /// deleting the host filter took every override scoped to it with no
    /// prompt at all (`ReqResCoreModelBridge.deleteHost` deletes the rules
    /// first, and the `hostId` foreign key cascades besides).
    ///
    /// An NSAlert, like the override prompt beside it — the one confirmation
    /// alert (`SuppressibleConfirmationAlert`), never a SwiftUI `.alert`,
    /// which has nothing to anchor to from a sidebar row hosted in an
    /// NSSplitViewController.
    private func showDeleteConfirmation(for host: HostCodable) {
        // Says what is LOST. The rules going with the host is the part nobody
        // expects, so it is the sentence, not a footnote.
        guard SuppressibleConfirmationAlert.confirm(
            title: "Delete Host Filter",
            message: """
            “\(host.host)” and any override rules scoped to it are deleted. \
            A rule belongs to a host filter and cannot outlive it.

            This cannot be undone.
            """,
            actionTitle: "Delete",
            suppressionKey: SuppressibleConfirmations.hostDelete
        ) else { return }
        AppState.shared.deleteHost(host)
    }
}

// The sidebar toggle is now the system's own `.toggleSidebar` toolbar item,
// which drives the real NSSplitViewController directly.

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
    // The 1.1.0 core's shapes: a reused connection with two Set-Cookie, a
    // body kept only in part, a relayed connection (DataMocks.swift).
    SessionState.shared.addSession(session: SESSION_MOCK_REUSED)
    SessionState.shared.addSession(session: SESSION_MOCK_TRUNCATED)
    SessionState.shared.addSession(session: SESSION_MOCK_RELAY)
    // A streamed LLM answer (SSE): the response's Events tab.
    SessionState.shared.addSession(session: SESSION_MOCK_SSE)
    // gRPC-Web calls (protocol-engine doc §S8): a server stream (RPC tab) and
    // a NOT_FOUND under HTTP 200 (the table's "200 · NOT_FOUND").
    SessionState.shared.addSession(session: SESSION_MOCK_GRPC_WEB)
    SessionState.shared.addSession(session: SESSION_MOCK_GRPC_WEB_ERROR)
    // HTTP/2 (core C12) and native gRPC whose status is in its recorded
    // trailers (core C13): `proto:h2`, the Protocol row, a trailer section.
    SessionState.shared.addSession(session: SESSION_MOCK_H2)
    SessionState.shared.addSession(session: SESSION_MOCK_GRPC_NATIVE)
    // Requests that did not complete (core C6): the cancelled one stays
    // hidden until Settings ▸ Capture ▸ Show cancelled requests is on.
    SESSION_MOCKS_FAILURES.forEach { SessionState.shared.addSession(session: $0) }
    SessionState.shared.addSession(session: SessionCodable(
        startTime: NSNumber(value: mockNow),
        host: "reqresapp.com",
        localAddress: "127.0.0.1",
        method: "GET",
        uri: "/test2/test2/test2/test2/test2/test2/test2/test2/test2/test2/test2/test2/?test=1&debug=true",
        reqHTTPVersion: "1.0",
        userAgentProduct: "target",
        reqHeaders: """
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
        reqContentEncoding: "gzip",
        reqContentType: "application/json; charset=utf-8",
        // NOTE: some extra escaping is failing to decode the string as in the example below
        reqBody: """
        {"fields":["[data-id=\"97007832-07a6-45f1-b4f3-349fd2d66909\"]"]}
        """,
        rspHTTPVersion: "Http/1.1",
    rspStatus: "500",
        rspReasonPhrase: "ok",
        rspContentType: "application/json; charset=utf-8",
    rspHeaders: """
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
    connectStartTime: NSNumber(value: mockNow + 0.008),       // +8ms for queuing
    connectEndTime: NSNumber(value: mockNow + 0.009),     // +1ms for DNS
    tlsEndTime: NSNumber(value: mockNow + 0.147),  // +118ms for TCP
    reqEndTime: NSNumber(value: mockNow + 0.245),        // +98ms for TLS handshake
    requestBytes: NSNumber(value: 973),             // 973 bytes sent
    responseBytes: NSNumber(value: 1264),              // 1.2KB received
    downloadStartTime: NSNumber(value: mockNow + 0.285), // +9ms after rspStartTime for server processing
    downloadEndTime: NSNumber(value: mockNow + 0.309),  // Same as rspEndTime (download completes)
    // A Brave tab: the helper three bundles deep, shown as "Brave Browser"
    // (UX spec §12.7, errata 1 — the mock data's browser row).
    processName: "Brave Browser Helper",
    processID: 4127,
    processPath: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/140.1.83.109/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper",
    // A Frankfurt address (destination-map UX spec §10): the row the map
    // places in Germany. A bare IP, as the core records it.
    remoteAddress: "3.120.12.34"
    ))
    SessionState.shared.addSession(session: SessionCodable(
        startTime: NSNumber(value: mockNow),
        host: "reqresapp.com",
        localAddress: "127.0.0.1",
        method: "GET",
        uri: "/test/img",
        reqHTTPVersion: "1.0",
        userAgentProduct: "target",
        reqHeaders: """
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
        reqContentEncoding: "",
        reqContentType: "",
        reqBody: "",
        rspHTTPVersion: "Http/1.1",
        rspStatus: "400",
        rspReasonPhrase: "ok",
        rspContentType: "image/vnd.microsoft.icon",
        rspHeaders: """
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
        connectStartTime: NSNumber(value: mockNow + 0.008),       // +8ms for queuing
        connectEndTime: NSNumber(value: mockNow + 0.009),     // +1ms for DNS
        tlsEndTime: NSNumber(value: mockNow + 0.147),  // +118ms for TCP
        reqEndTime: NSNumber(value: mockNow + 0.245),        // +98ms for TLS handshake
        requestBytes: NSNumber(value: 973),             // 973 bytes sent
        responseBytes: NSNumber(value: 1264),              // 1.2KB received
        downloadStartTime: NSNumber(value: mockNow + 0.285), // +9ms after rspStartTime for server processing
        downloadEndTime: NSNumber(value: mockNow + 0.309),  // Same as rspEndTime (download completes)
        // A bare executable: no bundle, named by its last path component.
        processName: "curl",
        processID: 51234,
        processPath: "/usr/bin/curl",
        // curl against a box on the office network: the map's Local Network
        // pill, never a dot.
        remoteAddress: "192.168.1.20"
    ))
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: {
        SessionState.shared.addSession(session: SessionCodable(
            startTime: NSNumber(value: mockNow),
            host: "reqresapp.com",
            localAddress: "127.0.0.1",
            method: "GET",
            uri: "/test",
            reqHTTPVersion: "1.0",
            userAgentProduct: "target",
            reqHeaders: """
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
            reqContentEncoding: "gzip",
            reqContentType: "application/json; charset=utf-8",
            reqBody: """
            {
                "reqRes": true,
                "test": 1
            }
            """,
            rspHTTPVersion: "Http/1.1",
        rspStatus: "200",
            rspReasonPhrase: "ok",
            rspContentType: "application/json; charset=utf-8",
        rspHeaders: """
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
        connectStartTime: NSNumber(value: mockNow + 0.008),       // +8ms for queuing
        connectEndTime: NSNumber(value: mockNow + 0.009),     // +1ms for DNS
        tlsEndTime: NSNumber(value: mockNow + 0.147),  // +118ms for TCP
        reqEndTime: NSNumber(value: mockNow + 0.245),        // +98ms for TLS handshake
        requestBytes: NSNumber(value: 973),                 // 973 bytes sent
        responseBytes: NSNumber(value: 1264),                 // 1.2KB received
        downloadStartTime: NSNumber(value: mockNow + 0.285), // +9ms after rspStartTime for server processing
        downloadEndTime: NSNumber(value: mockNow + 0.309),   // Same as rspEndTime (download completes)
        // Unattributed on purpose — the row the table prints as Unknown. The
        // three fields stay at their nil defaults; spelled out so the intent
        // survives the next person who adds a field above.
        processName: nil,
        processID: nil,
        processPath: nil,
        // No address either — the row the Destinations window lists under
        // Unknown, and the state the whole feature reads with an old core.
        remoteAddress: nil
    ))
    })
}
