//
//  HelpWindowController.swift
//  ReqRes
//
//  Created by OloApps on 21.09.2026.
//
//  Copyright © 2026 Andrey Teologov. All rights reserved.
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
//  The in-app Help window, hosted the way MCPApprovalWindow.swift hosts its
//  approval sheet: an AppKit window wrapping an NSHostingView, not a SwiftUI
//  `Window` scene (this app's forms are `.sheet`s on the main window for the
//  same reason a hand-built `Window` scene was rejected there).
//
//  Unlike the approval panel, Help is something the person opens on purpose
//  and reads for a while, so it is the OPPOSITE shape of MCPApprovalPanel:
//  a normal, ACTIVATING, closable, resizable NSWindow — not a non-activating
//  NSPanel that must never steal the keyboard. It keeps its title, remembers
//  where it was left between opens (a reference window is more useful where
//  you last put it), and is retained rather than rebuilt on every reopen so
//  scroll position survives closing and reopening it within a session.
//

import AppKit
import SwiftUI
import Utils
import XReqResCore

@MainActor
final class HelpWindowController {
    static let shared = HelpWindowController()

    private var window: NSWindow?

    private init() {}

    /// The one entry point every caller (a Help menu item, an onboarding
    /// link, a future "Learn more" button) should use. Building the window
    /// lazily means opening Help costs nothing for the large majority of
    /// launches that never do.
    func show() {
        let window = self.window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingView(rootView: HelpWindow())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ReqRes Help"
        window.contentView = hosting
        window.minSize = NSSize(width: 640, height: 420)
        // Not released on close: `show()` reuses this instance, so the
        // window (and the SwiftUI state inside it, including scroll
        // position) survives being closed and reopened.
        window.isReleasedWhenClosed = false
        window.center()
        // Restores the saved frame if one exists (a returning reader put
        // this window where they wanted it); otherwise keeps the centred
        // frame set just above.
        window.setFrameAutosaveName("ReqResHelpWindow")
        self.window = window
        return window
    }
}

#if DEBUG
// MARK: - Layout probe
//
// `REQRES_UI_PROBE=help|redaction` renders the view in a plain hosted window,
// PNGs it and exits. A freshly painted hosting view DOES rasterise through
// `cacheDisplay` (unlike the long-lived panes), so this
// is the one instrument that shows this app's SwiftUI layout headlessly.
extension HelpWindowController {
    static func runLayoutProbeIfRequested() {
        guard let target = ProcessInfo.processInfo.environment["REQRES_UI_PROBE"] else { return }
        let env = ProcessInfo.processInfo.environment
        let isDestinations = target.hasPrefix("destinations")
        let height = env["REQRES_UI_PROBE_HEIGHT"].flatMap(Double.init) ?? (target == "help" || isDestinations ? 640 : 620)
        let isSessionProbe = target.hasPrefix("session-") || target.hasPrefix("live-") || target.hasPrefix("websocket-") || target == "traffic-rows" || target == "traffic-failures" || target == "traffic-rpc" || target == "traffic-h2" || target.hasPrefix("traffic-columns")
        let isSheet = target.hasPrefix("ca-migration")
        let size = isSheet
            ? NSSize(width: 440, height: env["REQRES_UI_PROBE_HEIGHT"].flatMap(Double.init) ?? 470)
            : NSSize(width: env["REQRES_UI_PROBE_WIDTH"].flatMap(Double.init)
                        ?? (target == "help" || target == "saved" || isDestinations || isSessionProbe ? 1000 : target == "help-protocols" || target == "help-certificate" ? 770 : 700),
                     height: height)
        let view: AnyView
        switch target {
        case "help": view = AnyView(HelpWindow())
        // One topic on its own, top-aligned, at the reading width — the
        // whole topic in one capture with REQRES_UI_PROBE_HEIGHT (doc §S10).
        case "help-protocols", "help-certificate":
            view = AnyView(
                helpContent(for: target == "help-certificate" ? .certificate : .protocols)
                    .padding(24)
                    .frame(maxWidth: HelpStyle.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        case "capture": view = AnyView(CaptureSettingsView())
        case "saved": view = AnyView(SavedSessionsWindow())
        // The Destinations window at its default size (destination-map UX
        // spec §10): the mocks with server addresses, the same mocks with
        // unparseable ones (spec §7 state 3), or nothing at all (state 1).
        // `TZ=Europe/Amsterdam` moves the origin; the store is activated the
        // way the controller does it, so the first publish is the seed.
        case "destinations", "destinations-unknown":
            DestinationsProbe.seed(unparseable: target.hasSuffix("unknown"))
            DestinationsStore.shared.setActive(true)
            view = AnyView(DestinationsWindow())
        case "destinations-empty":
            DestinationsProbe.seedEmpty()
            DestinationsStore.shared.setActive(true)
            view = AnyView(DestinationsWindow())
        // What the 1.1.0 core records, on the DataMocks rows (protocol-engine
        // doc §S2): a reused connection (Metrics | response Headers), a body
        // kept only in part (Metrics | response Body), a relayed connection
        // (its own detail), and the three as table rows.
        case "session-reused", "session-reused-headers", "session-truncated", "session-relay", "session-relay-pinned", "session-relay-app-pinned", "traffic-rows":
            view = AnyView(RecordedExchangeProbe(target: target))
        // Requests that did not complete (protocol-engine doc §S3): the rows,
        // an app refusing ReqRes's certificate (app and CLI), a DNS failure
        // ReqRes answered 502, a server-cut download, and the exclusion's
        // confirmation (printed as a second PNG from the attached sheet).
        // A streamed response's Events tab (protocol-engine doc §S5): the
        // SSE mock (assembled answer closed / open) and the NDJSON mock.
        case "session-events", "session-events-assembled", "session-events-ndjson":
            view = AnyView(StreamEventsProbe(target: target))
        // gRPC-Web (protocol-engine doc §S8): the RPC tab of a server stream,
        // of a NOT_FOUND under HTTP 200, and both as table rows.
        case "session-rpc", "session-rpc-error", "traffic-rpc":
            view = AnyView(RPCProbe(target: target))
        // HTTP/2 and trailers (protocol-engine doc §S9): an h2 row's Metrics
        // (the Protocol row) beside its Headers; a native gRPC row's Headers
        // both sides (the trailer sections) or its RPC tab (the status read
        // from the trailers); and both as table rows.
        case "session-h2", "session-grpc", "session-grpc-rpc", "traffic-h2":
            view = AnyView(ProtocolProbe(target: target))
        // Live rows (protocol-engine doc §S6), seeded through the REAL bus
        // decoder and ingest path: the table (waiting, streaming, ended,
        // finished) and a streaming row's Events or Body tab as it grows.
        // The table's exact and dragged column widths (2026-09-29).
        case "traffic-columns", "traffic-columns-resized":
            view = AnyView(ColumnsProbe(resized: target.hasSuffix("resized")))
        case "live-rows", "live-events", "live-body":
            LiveRowsProbe.seed()
            view = AnyView(LiveRowsProbe(target: target))
        // A WebSocket's Messages tab (protocol-engine doc §S7), seeded through
        // the REAL bus delegate: the 101 row, three batches (a gap the
        // extension counted, then the close), the JSON or binary message
        // selected, or a search typed.
        case "websocket-messages", "websocket-messages-binary", "websocket-messages-search":
            WebSocketMessagesProbe.seed()
            view = AnyView(WebSocketMessagesProbe(target: target))
        case "traffic-failures", "session-failed-tls", "session-failed-tls-cli", "session-failed-dns", "session-aborted", "session-failed-tls-confirm", "session-failed-relay":
            view = AnyView(FailureRowsProbe(target: target))
        // Settings ▸ Certificate and the launch sheet (protocol-engine doc
        // §S4), from a SEEDED state — the probe reads nothing from the
        // keychain and writes nothing: `certificate` (installed + trusted),
        // `certificate-outdated` (the 1.0.x CA still there, this Mac's not
        // yet trusted), `certificate-earlier` (an earlier install's CA),
        // `certificate-new` (nothing installed); `ca-migration` and
        // `ca-migration-earlier` are the sheet for the two kinds of older CA.
        // `…-explained` (shell step S12) opens the ? button's sheet over the
        // pane, printed as a second PNG (`-sheet`) with its text dumped.
        case "certificate", "certificate-outdated", "certificate-earlier", "certificate-new",
             "certificate-explained", "certificate-outdated-explained":
            let legacy = CertificateAuthority.legacySharedCAFingerprintSHA256
            let earlier = String(repeating: "e", count: 64)
            switch target.replacingOccurrences(of: "-explained", with: "") {
            case "certificate-outdated":
                CertificateAuthorityService.shared.seedForProbe(installed: true, trusted: false, outdated: [legacy])
            case "certificate-earlier":
                CertificateAuthorityService.shared.seedForProbe(installed: true, trusted: true, outdated: [earlier])
            case "certificate-new":
                CertificateAuthorityService.shared.seedForProbe(installed: false, trusted: false, outdated: [])
            default:
                CertificateAuthorityService.shared.seedForProbe(installed: true, trusted: true, outdated: [])
            }
            view = AnyView(SettingsPane { CertificateSettingsView() })
        case "ca-migration", "ca-migration-earlier":
            CertificateAuthorityService.shared.seedForProbe(
                installed: false, trusted: false,
                outdated: [target.hasSuffix("earlier") ? String(repeating: "e", count: 64) : CertificateAuthority.legacySharedCAFingerprintSHA256]
            )
            view = AnyView(
                CAMigrationSheet()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        case "storage": view = AnyView(StorageSettingsView())
        case "breakpoints": view = AnyView(BreakpointSettingsView())
        case "general": view = AnyView(GeneralSettingsView())
        // Settings ▸ License (`plans`) and the ReqRes Pro sheet as shown at
        // launch (`paywall`), both the core's own views on this app's words.
        // `paywall-limit` is the sheet a limit opened: Reached on Unlimited
        // HTTPS inspections, and Return is Buy, as for any sheet a person
        // opened.
        case "plans": view = AnyView(SubscriptionSettingsView(isInPreferences: true, planSheet: .reqres))
        case "paywall": view = AnyView(SubscriptionSettingsView(isInPreferences: false, planSheet: .reqres))
        case "paywall-limit":
            view = AnyView(SubscriptionSettingsView(isInPreferences: false, planSheet: .reqres,
                                                    reachedGainID: PaywallTrigger.httpsInspections.rawValue,
                                                    returnKeyBuys: true))
        case "breakpoint":
            // A synthetic held request: the extension cannot hold a real one
            // until the wedged sysext is cleared, and a panel about an empty
            // queue shows none of what matters.
            BreakpointService.shared.seedForProbe(autoResumed: 2)
            view = AnyView(BreakpointPanel())
        case "breakpoint-released":
            // Nothing held, and a reason why — the state the panel used to
            // hide itself in before anyone could read it.
            BreakpointService.shared.seedForProbe(
                autoResumed: 3,
                releaseNote: "1 request was resumed automatically — nobody answered in time."
            )
            view = AnyView(BreakpointPanel())
        default: view = AnyView(MCPSettingsView())
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        // Seeded so the exception list and its warning can be looked at, then
        // removed again below — this runs against the same container as an
        // installed copy, so the probe must leave no setting behind.
        let seeded = env["REQRES_UI_PROBE_SEED"].map { $0.components(separatedBy: ",") } ?? []
        seeded.forEach { MCPRedactionSettings.shared.except($0) }
        hosting.layoutSubtreeIfNeeded()
        print("[probe] \(target) fitting=\(hosting.fittingSize) frame=\(hosting.frame.size)")
        // The Destinations window is a MapKit map since the Apple Maps
        // rewrite: its tiles arrive over the network and are drawn by a
        // Metal layer `cacheDisplay` does not rasterise, so that probe waits
        // longer (`REQRES_UI_PROBE_WAIT` seconds, default 4) and ALSO prints
        // a composite assembled by `DestinationsProbe.capture` — see the
        // note there for exactly what it can and cannot show.
        let wait = env["REQRES_UI_PROBE_WAIT"].flatMap(Double.init) ?? (isDestinations ? 4 : 1.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    print("<<<PNG \(target)\n\(png.base64EncodedString())\nPNG>>>")
                }
            }
            // A SwiftUI `.alert` is an AppKit sheet on the window, outside the
            // hosting view — rasterise it separately when one is up.
            // `cacheDisplay` draws an alert's vibrant background as nothing,
            // so the sheet is also drawn through PDF (the text and buttons
            // do render that way) and its words are dumped as text.
            if let sheet = window.attachedSheet, let content = sheet.contentView {
                func dump(_ view: NSView, depth: Int = 0) {
                    if let field = view as? NSTextField, !field.stringValue.isEmpty {
                        print("[probe] sheet text: \(field.stringValue)")
                    } else if let button = view as? NSButton, !button.title.isEmpty {
                        print("[probe] sheet button: \(button.title)\(button.keyEquivalent == "\r" ? " (default)" : "")")
                    }
                    view.subviews.forEach { dump($0, depth: depth + 1) }
                }
                dump(content)
                // A SwiftUI sheet (S12's) is a freshly painted hosting view,
                // which `cacheDisplay` rasterises — unlike an alert's vibrant
                // background. Printed as `-sheet-hosted`; the PDF below stays
                // for alerts. Its accessibility tree carries the words.
                if !(content is NSVisualEffectView), content.className.contains("Hosting") || content.subviews.contains(where: { $0.className.contains("Hosting") }),
                   let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        print("<<<PNG \(target)-sheet-hosted\n\(png.base64EncodedString())\nPNG>>>")
                    }
                }
                let pdf = content.dataWithPDF(inside: content.bounds)
                if let image = NSImage(data: pdf) {
                    let size = NSSize(width: content.bounds.width * 2, height: content.bounds.height * 2)
                    let rendered = NSImage(size: size, flipped: false) { rect in
                        NSColor.windowBackgroundColor.setFill()
                        rect.fill()
                        image.draw(in: rect)
                        return true
                    }
                    if let tiff = rendered.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        print("<<<PNG \(target)-sheet\n\(png.base64EncodedString())\nPNG>>>")
                    }
                }
            }
            if isDestinations {
                Task { @MainActor in
                    // `REQRES_UI_PROBE_CLICK=DE`: a synthesized real click on
                    // that dot BEFORE the capture, so the composite shows the
                    // state a click produces, not a programmatic selection.
                    if let token = env["REQRES_UI_PROBE_CLICK"] {
                        await DestinationsProbe.click(token: token, hosting: hosting)
                    }
                    if let png = await DestinationsProbe.capture(hosting: hosting, appearance: hosting.effectiveAppearance) {
                        print("<<<PNG \(target)-composite\n\(png.base64EncodedString())\nPNG>>>")
                    }
                    finish()
                }
                return
            }
            finish()
        }
        func finish() {
            // Inline, never in a `defer`: `exit` does not unwind scopes, so a
            // deferred restore never runs (measured — the first version of
            // this probe left its seeded hosts persisted).
            seeded.forEach { MCPRedactionSettings.shared.removeException($0) }
            if env["REQRES_UI_PROBE_CLEAR"] != nil { MCPRedactionSettings.shared.removeAllExceptions() }
            print("[probe] exceptions left behind: \(MCPRedactionSettings.shared.policy.exceptedHosts)")
            fflush(stdout)
            exit(0)
        }
    }
}
#endif

#if DEBUG
/// The detail pane and the table for the 1.1.0 mock rows, as the traffic
/// window draws them — the same views, not look-alikes.
private struct RecordedExchangeProbe: View {
    let target: String

    /// `cacheDisplay` does not draw the window's own background, so the probe
    /// paints it — otherwise dark-mode text renders white on white.
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch target {
        case "traffic-rows":
            // A LazyVStack like the real list: in a plain VStack the rows'
            // Color dividers stretch every row to fill the window. The relay
            // appears twice, unselected and selected.
            ScrollView {
                LazyVStack(spacing: 0) {
                    SessionTableHeader(mode: .wide, showsApp: true)
                    ForEach(Array([SESSION_MOCK, SESSION_MOCK_REUSED, SESSION_MOCK_TRUNCATED, SESSION_MOCK_RELAY, SESSION_MOCK_RELAY, SESSION_MOCK_PINNED, SESSION_MOCK_PINNED, SESSION_MOCK_APP_PINNED].enumerated()), id: \.offset) { index, session in
                        TableRowView(session: session, isSelected: index == 4 || index == 6, isEvenRow: index % 2 == 0, mode: .wide,
                                     showsApp: true, attribution: .available, isAgent: false)
                    }
                }
            }
        case "session-relay", "session-relay-pinned", "session-relay-app-pinned":
            let relay = target == "session-relay-pinned" ? SESSION_MOCK_PINNED
                : target == "session-relay-app-pinned" ? SESSION_MOCK_APP_PINNED : SESSION_MOCK_RELAY
            VStack(alignment: .leading, spacing: 0) {
                SessionDetailHeaderView(session: relay, attribution: .available, onClose: {})
                RelayConnectionDetailView(session: relay, openCertificateSettings: {})
            }
        default:
            let session = target == "session-truncated" ? SESSION_MOCK_TRUNCATED : SESSION_MOCK_REUSED
            VStack(alignment: .leading, spacing: 0) {
                SessionDetailHeaderView(session: session, attribution: .available, onClose: {})
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        RequestToolbar(title: .Request, selection: .constant(.metrics))
                        Divider()
                        SessionRequestTabView(session: session, selectedTabRequest: .constant(.metrics))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        let tab: NetworkInspectorTabResponse = target == "session-reused-headers" ? .headers
                            : target == "session-truncated" ? .response : .headers
                        ResponseToolbar(title: .Response, selection: .constant(tab))
                        Divider()
                        SessionResponseTabView(session: session, selectedTabResponse: .constant(tab))
                    }
                }
            }
        }
    }
}

/// The Events tab as the detail pane draws it: request Headers beside the
/// response with Events selected — the same views.
private struct StreamEventsProbe: View {
    let target: String

    var body: some View {
        let session = target == "session-events-ndjson" ? SESSION_MOCK_TRUNCATED : SESSION_MOCK_SSE
        VStack(alignment: .leading, spacing: 0) {
            SessionDetailHeaderView(session: session, attribution: .available, onClose: {})
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    RequestToolbar(title: .Request, selection: .constant(.headers))
                    Divider()
                    SessionRequestTabView(session: session, selectedTabRequest: .constant(.headers))
                }
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ResponseToolbar(title: .Response, selection: .constant(.events),
                                    items: NetworkInspectorTabResponse.tabs(for: session))
                    Divider()
                    if target == "session-events-assembled" {
                        StreamEventsView(session: session, assembledInitiallyExpanded: true)
                    } else {
                        SessionResponseTabView(session: session, selectedTabResponse: .constant(.events))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The RPC tab as the detail pane draws it: request Headers beside the
/// response with RPC selected — the same views — or the rows in the table.
private struct RPCProbe: View {
    let target: String

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if target == "traffic-rpc" {
            let rows = [SESSION_MOCK, SESSION_MOCK_GRPC_WEB, SESSION_MOCK_GRPC_WEB_ERROR, SESSION_MOCK_GRPC_WEB_ERROR]
            ScrollView {
                LazyVStack(spacing: 0) {
                    SessionTableHeader(mode: .wide, showsApp: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        TableRowView(session: row, isSelected: index == rows.count - 1, isEvenRow: index % 2 == 0, mode: .wide,
                                     showsApp: true, attribution: .available, isAgent: false,
                                     rpc: RPCStatusCache.shared.facts(for: row))
                    }
                }
            }
        } else {
            let session = target == "session-rpc-error" ? SESSION_MOCK_GRPC_WEB_ERROR : SESSION_MOCK_GRPC_WEB
            VStack(alignment: .leading, spacing: 0) {
                SessionDetailHeaderView(session: session, attribution: .available, onClose: {})
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        RequestToolbar(title: .Request, selection: .constant(.headers))
                        Divider()
                        SessionRequestTabView(session: session, selectedTabRequest: .constant(.headers))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        ResponseToolbar(title: .Response, selection: .constant(.rpc),
                                        items: NetworkInspectorTabResponse.tabs(for: session))
                        Divider()
                        SessionResponseTabView(session: session, selectedTabResponse: .constant(.rpc))
                    }
                }
            }
        }
    }
}

/// HTTP/2 and native gRPC rows as the detail pane and the table draw them —
/// the same views.
private struct ProtocolProbe: View {
    let target: String

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if target == "traffic-h2" {
            let rows = [SESSION_MOCK, SESSION_MOCK_H2, SESSION_MOCK_GRPC_NATIVE, SESSION_MOCK_GRPC_NATIVE]
            ScrollView {
                LazyVStack(spacing: 0) {
                    SessionTableHeader(mode: .wide, showsApp: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        TableRowView(session: row, isSelected: index == rows.count - 1, isEvenRow: index % 2 == 0, mode: .wide,
                                     showsApp: true, attribution: .available, isAgent: false,
                                     rpc: RPCStatusCache.shared.facts(for: row))
                    }
                }
            }
        } else {
            let session = target == "session-h2" ? SESSION_MOCK_H2 : SESSION_MOCK_GRPC_NATIVE
            let requestTab: NetworkInspectorTabRequest = target == "session-grpc" ? .headers : .metrics
            let responseTab: NetworkInspectorTabResponse = target == "session-grpc-rpc" ? .rpc : .headers
            VStack(alignment: .leading, spacing: 0) {
                SessionDetailHeaderView(session: session, attribution: .available, onClose: {})
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        RequestToolbar(title: .Request, selection: .constant(requestTab))
                        Divider()
                        SessionRequestTabView(session: session, selectedTabRequest: .constant(requestTab))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        ResponseToolbar(title: .Response, selection: .constant(responseTab),
                                        items: NetworkInspectorTabResponse.tabs(for: session))
                        Divider()
                        SessionResponseTabView(session: session, selectedTabResponse: .constant(responseTab))
                    }
                }
            }
        }
    }
}

/// The failure mocks as the traffic window draws them — the same views.
private struct FailureRowsProbe: View {
    let target: String

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var session: SessionCodable {
        switch target {
        case "session-failed-tls-cli": return SESSION_MOCK_FAILED_TLS_CLIENT_CLI
        case "session-failed-dns": return SESSION_MOCK_FAILED_DNS
        case "session-aborted": return SESSION_MOCK_ABORTED
        default: return SESSION_MOCK_FAILED_TLS_CLIENT
        }
    }

    @ViewBuilder
    private var content: some View {
        if target == "traffic-failures" {
            // Every failure mock, the cancelled one included (the list would
            // hide it by default), then the first failure again, selected.
            let rows = [SESSION_MOCK] + SESSION_MOCKS_FAILURES + [SESSION_MOCK_FAILED_TLS_CLIENT]
            ScrollView {
                LazyVStack(spacing: 0) {
                    SessionTableHeader(mode: .wide, showsApp: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        TableRowView(session: row, isSelected: index == rows.count - 1, isEvenRow: index % 2 == 0, mode: .wide,
                                     showsApp: true, attribution: .available, isAgent: false)
                    }
                }
            }
        } else if target == "session-failed-relay" {
            // The live pane's `.relay` branch: the same view.
            VStack(alignment: .leading, spacing: 0) {
                SessionDetailHeaderView(session: SESSION_MOCK_FAILED_RELAY, attribution: .available, onClose: {})
                RelayDetailContent(session: SESSION_MOCK_FAILED_RELAY, openCaptureSettings: {}, openCertificateSettings: {})
            }
        } else if let facts = session.failureFacts {
            VStack(alignment: .leading, spacing: 0) {
                SessionDetailHeaderView(session: session, attribution: .available, onClose: {})
                if target == "session-failed-tls-confirm" {
                    FailureBanner(session: session, facts: facts, openCaptureSettings: {}, presentConfirmationForProbe: true)
                    Spacer()
                } else {
                    FailureDetailView(session: session, facts: facts, openCaptureSettings: {}) {
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                RequestToolbar(title: .Request, selection: .constant(.headers))
                                Divider()
                                SessionRequestTabView(session: session, selectedTabRequest: .constant(.headers))
                            }
                            Divider()
                            VStack(alignment: .leading, spacing: 0) {
                                ResponseToolbar(title: .Response, selection: .constant(.response))
                                Divider()
                                SessionResponseTabView(session: session, selectedTabResponse: .constant(.response))
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
