//
//  ReqResToolbarSlots.swift
//  ReqRes
//
//  Created by OloApps on 16.09.2026.
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
//  The SwiftUI content hosted inside the AppKit toolbar's clusters, plus the
//  sidebar footer that now carries the licence state the toolbar used to.
//
//  THE CARDINAL RULE for everything in the toolbar clusters: content must
//  never change the item's layout. An NSToolbarItem sizes itself to its hosted
//  view's fitting size, so a spinner that appears beside a glyph, or a label
//  that grows by a character, re-measures the item and shoves every neighbour
//  sideways. Every control here occupies a FIXED box and swaps its contents
//  inside that box.
//

import MCPKit
import SwiftUI
import NetworkExtension
import XReqResCore
import Utils

// MARK: - Shared metric

/// The icon-button metric for controls sitting on a system platter: a 16pt
/// symbol in a fixed hit area, rendered plain. The platter IS the chrome, so
/// the buttons inside it draw no border of their own — and the default
/// borderless style renders each button ~37pt wide, which is what used to
/// overflow the cluster.
struct ToolbarIconButtonStyle: ButtonStyle {
    /// A custom ButtonStyle bypasses the automatic disabled dimming, so a
    /// disabled control would otherwise render at full contrast and look live.
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: ReqResToolbarPlan.iconPointSize, weight: .regular))
            .frame(width: ReqResToolbarPlan.iconButtonSize.width,
                   height: ReqResToolbarPlan.iconButtonSize.height)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : (isEnabled ? 1 : 0.35))
    }
}

// MARK: - Commands
//
// The actions behind the toolbar's clusters live here, NOT in the cluster
// views, because a toolbar item that folds into the overflow chevron does not
// mount its hosted view. An action implemented as `.onReceive` inside a
// cluster would therefore stop working at exactly the window width where the
// overflow menu becomes the only way to reach it — silently.

/// Everything the capture and tools clusters can do, reachable whether the
/// item is on screen, in the overflow menu, or behind a keyboard shortcut.
@MainActor
enum TrafficCommands {

    static func toggleCapture() {
        // What the user SAW when they clicked (F11): the extension check below
        // is asynchronous, and the display can change under it — the launch
        // reading of a capture that outlived the last app landing, above all
        // — which must not turn the Start they clicked into a stop.
        let intent = CaptureIntent.toggle(shown: CaptureTunnelState(AppState.shared.vpnStatus))
        // Noted at the click, not after the check below: a Restart Capture
        // waiting out its stop leaves the capture to this click (F11 review).
        AppController.shared.noteCaptureRequest()
        Task {
            do {
                let status = try await ExtensionStatusManager.shared.checkCompleteStatus()
                await MainActor.run {
                    AppState.shared.extensionStatus = status
                    // Let the request itself report what went wrong; a stale
                    // status must not block the attempt.
                    AppController.shared.requestCapture(intent)
                }
            } catch {
                await MainActor.run {
                    presentAlert(title: "Could not check the extension",
                                 message: error.localizedDescription)
                }
            }
        }
    }

    /// Throws away every captured request, after asking.
    ///
    /// Two changes, both because this will also be reachable from the menu bar
    /// with no window on screen:
    ///
    ///  * It asks. Clearing the buffer is the most destructive thing in the
    ///    window — captured traffic exists only in memory, so anything not
    ///    saved is gone and cannot be recaptured by rerunning the request.
    ///    Deleting ONE override asked; this did not.
    ///  * It clears EVERYTHING. `clearAllSessionsForGroup()` does nothing at
    ///    all when no host is selected, clears only the selected host's bucket
    ///    otherwise, and leaves the ingest buffer undrained — the leak
    ///    `clearAllSessions()` was written to fix for the agent path. From a
    ///    menu with no window the user cannot see which host is selected, so
    ///    an item that clears "some of it, depending" cannot honestly say what
    ///    it does.
    static func clearTraffic() {
        guard !UserDefaults.standard.bool(forKey: SuppressibleConfirmations.clearTraffic) else {
            _ = SessionState.shared.clearAllSessions()
            return
        }

        let count = SessionState.shared.sessions.count
        guard SuppressibleConfirmationAlert.confirm(
            title: "Clear Captured Traffic",
            message: SuppressibleConfirmations.clearTrafficMessage(count: count, locale: .current),
            actionTitle: "Clear",
            suppressionKey: SuppressibleConfirmations.clearTraffic
        ) else { return }
        _ = SessionState.shared.clearAllSessions()
    }

    static func sendFeedback() {
        guard let url = URL(string: FEEDBACK_URL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the Destinations window (destination-map UX spec §2.1) — the
    /// Window menu, the toolbar's map button and its overflow row all land
    /// here. It opens a window and never changes a mode.
    static func showDestinations() {
        DestinationsWindowController.shared.show()
    }

    /// Explains why capture is not working, from the SAME engine that answers
    /// the `diagnose_setup` MCP tool.
    ///
    /// It used to switch on `extensionStatus` alone, which cannot see the worst
    /// state this product has: a connected tunnel with NOTHING listening on
    /// 127.0.0.1:8034 — the phantom-start shape. So an AI agent could diagnose
    /// the user's capture better than the user could, in a product whose whole
    /// pitch is that the human and the agent are equals. `MCPSetupDiagnosis`
    /// already ordered the checks causally (location → extension → tunnel →
    /// port → CA installed → CA trusted → free limit → traffic) and worded
    /// every failure as what the HUMAN does next; this just stops hiding it
    /// from them.
    static func explainSetup() {
        // Off main, always: `setupFacts()` reads the keychain, hops through
        // `DispatchQueue.main.sync` twice and opens a real loopback socket with
        // a 0.4s timeout. Called on main it would deadlock on its own hop.
        DispatchQueue.global(qos: .userInitiated).async {
            let report = MCPSetupDiagnosis.report(MCPStatusAdapter().setupFacts())
            DispatchQueue.main.async { presentDiagnosis(report) }
        }
    }

    private static func presentDiagnosis(_ report: MCPSetupReport) {
        // Everything that is not ok, in the order the engine put it — the
        // order is causal, so the first problem is the one to fix and the rest
        // are likely its symptoms. Each fix in the person's words
        // (`MCPSetupDiagnosis.humanFixText`): the engine writes them for the
        // agent that relays them.
        let notable = report.checks.filter { $0.state != .ok }
        let body = notable.isEmpty
            ? "Every check passed."
            : notable.map { check -> String in
                let fix = MCPSetupDiagnosis.humanFixText(for: check)
                    .map { "\n→ \($0)" } ?? ""
                return "\(check.title): \(check.detail)\(fix)"
            }.joined(separator: "\n\n")

        // The blocking check decides the button, so the alert offers the one
        // action that would actually unblock capture.
        var primary: (String, () -> Void)?
        switch report.blockingCheckId {
        case "extension": primary = ("Open System Settings", openSystemSettings)
        case "location": primary = ("Show in Finder", revealApp)
        // Capture on and nothing reaching this window (F11): the fix is one
        // click, so the alert offers it — never for another copy holding the
        // capture, where a restart would take it away from that copy.
        case MCPCaptureDelivery.checkId where MCPCaptureDelivery.offersRestart(in: report):
            primary = (CaptureDeliveryCopy.restartButton, { CaptureDeliveryMonitor.shared.restartCapture() })
        default:
            if AppState.shared.extensionStatus == .needsRestart {
                primary = ("Restart Now", restartComputer)
            }
        }
        // A short title, NOT `report.verdict`: the verdict is built from the
        // blocking check's detail and fix, so using it here printed the same
        // sentence twice — once in bold and once in the body underneath.
        let title = report.capturing
            ? "Capture is running"
            : (report.blockingCheckId == nil ? "Capture is not running" : "Capture is not working yet")
        presentAlert(title: title, message: body, primary: primary)
    }

    private static func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// A start the app asked for ended before capture connected — the
    /// extension refused it (`AppController.vpnDidChange`). The preflight
    /// only asks; the extension's own bind of the port is the last word, and
    /// since build 53 the extension also says when the start failed for
    /// another reason (`TunnelStartFailure.didNotStartMessage` words it).
    static func presentCaptureDidNotStart(message: String) {
        presentAlert(title: ProxyPortSetting.startFailedTitle, message: message)
    }

    /// A start refused before it began (F11): this copy of ReqRes could not
    /// listen where the extension delivers what it captures — another copy
    /// holds it, most often. It used to fail with nothing said.
    static func presentCaptureChannelUnavailable(anotherCopyRunning: Bool) {
        presentAlert(title: CaptureDeliveryCopy.channelUnavailableTitle,
                     message: CaptureDeliveryCopy.channelUnavailableMessage(busPort: MessageBusPort,
                                                                            anotherCopyRunning: anotherCopyRunning))
    }

    /// A Restart Capture that ended without its start going out, and why —
    /// including whether capture was left running (F11 review). It used to
    /// end in a log line, and the person saw the old notice come back.
    static func presentCaptureRestartFailed(_ failure: CaptureRestartFailure) {
        presentAlert(title: CaptureDeliveryCopy.restartFailedTitle,
                     message: CaptureDeliveryCopy.restartFailedMessage(failure, busPort: MessageBusPort))
    }

    /// AppKit alerts, anchored to the real window. A SwiftUI `.alert` attached
    /// to a view hosted inside a toolbar item presents from a ~32pt anchor and
    /// re-measures the item while it is up.
    private static func presentAlert(title: String, message: String,
                                     primary: (title: String, action: () -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if let primary {
            alert.addButton(withTitle: primary.title)
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { primary.action() }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // The extension-approval pane moved in macOS 15 (Sequoia/Tahoe):
    // General → Login Items & Extensions; Sonoma keeps Privacy & Security.
    private static var extensionInstructions: String {
        if #available(macOS 15.0, *) {
            return """
            1. Open System Settings ▸ General ▸ Login Items & Extensions.
            2. Scroll to Network Extensions and click the ⓘ button beside it.
            3. Switch ReqRes on, then click Done.

            A restart may be required the first time.
            """
        } else {
            return """
            1. Open System Settings ▸ Privacy & Security ▸ Extensions.
            2. Scroll down to System Extensions.
            3. Find ReqRes and enable it.

            A restart may be required the first time.
            """
        }
    }

    private static func openSystemSettings() {
        let urlString: String
        if #available(macOS 15.0, *) {
            urlString = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            AppLog.shared.debug("[TrafficCommands] Opening system settings URL: \(url.absoluteString)")
        }
    }

    private static func restartComputer() {
        let script = """
        tell application "System Events"
            restart
        end tell
        """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error {
                AppLog.shared.error("[TrafficCommands] Error restarting: \(error)")
            }
        }
    }
}

// MARK: - Confirmations

/// The alert for every action a person can tell ReqRes to stop asking about:
/// deleting an override or a host filter, and clearing captured traffic. The
/// callers keep their own check for a prompt already turned off (they act
/// without asking); this asks, remembers a ticked box, and says whether to go
/// ahead.
@MainActor
enum SuppressibleConfirmationAlert {
    /// The action is the first button (Return), Cancel the second (Esc). The
    /// box turns the prompt off only when the action was chosen with it ticked
    /// (`SuppressibleConfirmations.remembersChoice`): Cancel silences nothing.
    ///
    /// The box is NSAlert's own suppression button, never an `accessoryView`.
    /// On macOS 27 an AppKit button draws through a SwiftUI hosting view, and a
    /// checkbox made while a SwiftUI Button's action was still running — the
    /// toolbar's trash — never drew: the alert kept its space and showed
    /// nothing (measured 2026-10-01). Whether the context menus' alerts lost it
    /// too was not measured. The suppression button drew in every run, a
    /// simulated context-menu click included.
    ///
    /// Synchronous on purpose. Deferring the alert out of the action would draw
    /// a hand-made checkbox too, but not with `DispatchQueue.main.async`: a
    /// modal started inside a main-queue block holds back every other
    /// main-queue block until it is answered — the traffic table's flush and
    /// the MCP bridge's `main.sync` reads among them.
    static func confirm(title: String, message: String, actionTitle: String,
                        suppressionKey: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = SuppressibleConfirmations.checkboxTitle

        let confirmed = alert.runModal() == .alertFirstButtonReturn
        let ticked = alert.suppressionButton?.state == .on
        if SuppressibleConfirmations.remembersChoice(confirmed: confirmed, ticked: ticked) {
            UserDefaults.standard.set(true, forKey: suppressionKey)
        }
        return confirmed
    }
}

// MARK: - Host switcher chip

/// The selected host, as a menu chip that also switches hosts — the same
/// shape as snipperapp's workspace switcher, which carries its filter title.
///
/// Why a chip and not the window title: AppKit's native title view has a
/// 160pt floor and cannot overflow, which shoved the list separator off its
/// divider whenever the sidebar was collapsed. A hosted item overflows to the
/// chevron instead. And once the sidebar IS collapsed, this menu is the only
/// way left to change hosts.
///
/// The name is capped at `hostChipMaxWidth` and truncates inside the box; the
/// request count is NOT here — a number changing every 150ms would re-measure
/// the item. It lives in the sidebar rows as a badge.
/// How wide the host chip's label may be — set by the toolbar controller from
/// the geometry of the chip's section, read by the chip.
@MainActor
final class HostChipLayout: ObservableObject {
    static let shared = HostChipLayout()
    @Published var labelMaxWidth: CGFloat = ReqResToolbarPlan.hostChipMaxWidth
}

struct HostSwitcherSlot: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var layout = HostChipLayout.shared

    private var selectedName: String { appState.selectedHost?.host ?? "All traffic" }
    private var isAllTraffic: Bool { appState.selectedHost?.host ?? "All traffic" == "All traffic" }

    /// Below this budget a label is two letters and an ellipsis ("Al…" with the
    /// sidebar collapsed and the overrides pane at its minimum, where the
    /// toggle eats most of the section). Icon and chevron alone read better
    /// than that; the full name is in the menu and tooltip.
    private static let minimumLabelWidth: CGFloat = 44
    private var showsLabel: Bool { layout.labelMaxWidth >= Self.minimumLabelWidth }

    var body: some View {
        Menu {
            // A Picker inside a Menu renders as checkmarked rows.
            Picker("Host", selection: $appState.selectedHost) {
                ForEach(appState.hosts, id: \.self) { host in
                    Text(host.host).tag(Optional(host))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isAllTraffic ? "square.grid.2x2" : "network")
                if showsLabel {
                    Text(selectedName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The section's actual room, not a constant — see
                        // `ReqResToolbarController.updateHostChipBudget`.
                        .frame(maxWidth: layout.labelMaxWidth)
                }
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        // `fixedSize` so the item's intrinsic width is exactly this content —
        // which is already capped to the section by the label budget above.
        .fixedSize()
        .frame(height: ReqResToolbarPlan.iconButtonSize.height)
        .padding(.horizontal, 6)
        .help(showsLabel ? "Switch the host filter" : "\(selectedName) — switch the host filter")
        .accessibilityLabel("Host: \(selectedName)")
        .accessibilityIdentifier("toolbarHostSwitcher")
    }
}

// MARK: - Capture cluster

/// Start/pause capture — the app's primary action — plus a warning affordance
/// while the network extension is not ready.
///
/// Replaces the old `VPNToolbarControl` (a `ToolbarContent` that contributed
/// two separate SwiftUI toolbar items).
struct CaptureToolbarSlot: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        HStack(spacing: 2) {
            Button(action: TrafficCommands.toggleCapture) {
                // ONE fixed box. The busy spinner REPLACES the glyph rather
                // than sitting beside it, so the cluster's width never moves.
                ZStack {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: statusIcon)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .buttonStyle(ToolbarIconButtonStyle())
            .disabled(isBusy)
            .help(captureHelp)
            .accessibilityIdentifier("toolbarCaptureButton")

            if appState.extensionStatus != .ready {
                Button(action: TrafficCommands.explainSetup) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(ToolbarIconButtonStyle())
                .help(appState.extensionStatus.description)
                .accessibilityIdentifier("toolbarSetupWarning")
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: Derived state

    private var isBusy: Bool {
        switch appState.vpnStatus {
        case .connecting, .disconnecting, .reasserting: return true
        default: return false
        }
    }

    private var statusIcon: String {
        switch appState.vpnStatus {
        case .connected: return "pause.fill"
        default: return "play.fill"
        }
    }

    private var captureHelp: String {
        switch appState.vpnStatus {
        case .invalid, .disconnected: return "Start capturing traffic"
        case .connecting: return "Starting capture…"
        case .connected: return "Pause capturing traffic"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Stopping capture…"
        @unknown default: return "Start capturing traffic"
        }
    }
}

// MARK: - Tools cluster

/// Destinations · clear captured traffic · send feedback.
///
/// "Send Feedback" used to be a labelled text button in the toolbar, which is
/// what pushed the search field off the right edge. It keeps its place as an
/// icon, and its label lives in the tooltip and the overflow menu.
///
/// The map button OPENS a window (destination-map UX spec §2.1); it is not a
/// mode switch and it is always enabled — the window has its own empty
/// states. The cluster is one fixed box wider at design time and never
/// changes at runtime (the cardinal rule above).
struct TrafficToolsSlot: View {
    @ObservedObject private var sessionState = SessionState.shared

    var body: some View {
        HStack(spacing: 2) {
            Button(action: TrafficCommands.showDestinations) {
                Image(systemName: "map")
            }
            .buttonStyle(ToolbarIconButtonStyle())
            .help("Show where captured requests went")
            .accessibilityIdentifier("toolbarDestinationsButton")
            .accessibilityLabel("Destinations")

            Button(action: TrafficCommands.clearTraffic) {
                Image(systemName: "trash")
            }
            .buttonStyle(ToolbarIconButtonStyle())
            // Gated on what it CLEARS, which is now every captured session,
            // not the filtered view it used to empty.
            .disabled(sessionState.sessions.isEmpty)
            .help("Clear captured traffic")
            .accessibilityIdentifier("toolbarClearButton")

            Button(action: TrafficCommands.sendFeedback) {
                Image(systemName: "envelope")
            }
            .buttonStyle(ToolbarIconButtonStyle())
            .help("Send feedback")
            .accessibilityIdentifier("toolbarFeedbackButton")
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Free-tier inspection gauge

/// How many free HTTPS inspections are left this session — a count over a
/// progress bar, in a FIXED box so the digits changing never re-measures the
/// item. A click opens the ReqRes Pro sheet, with Reached on its HTTPS
/// inspections row once none is left. The old toolbar carried a 150pt bar
/// under a full sentence; this is the narrow form of the same thing.
struct InspectionsGaugeSlot: View {
    @ObservedObject private var appState = AppState.shared

    private var used: Int { appState.freeHttpsSessionsInspected }
    private var total: Int { max(appState.maxFreeHttpsSessions, 1) }
    private var remaining: Int { max(0, total - used) }

    var body: some View {
        #if DEBUG
        // A licensed user never sees this gauge; screenshot mode matches.
        if ScreenshotMocks.isEnabled {
            EmptyView()
        } else {
            gauge
        }
        #else
        gauge
        #endif
    }

    private var gauge: some View {
        Button {
            PaywallPresentation.shared.show(remaining == 0 ? .httpsInspections : nil)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(remaining)/\(total) free HTTPS inspections")
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                ProgressView(value: Double(min(used, total)), total: Double(total))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
            .frame(width: ReqResToolbarPlan.inspectionsGaugeWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: ReqResToolbarPlan.iconButtonSize.height)
        .padding(.horizontal, 6)
        // One offer now, not plans: the click opens the ReqRes Pro sheet.
        .help("\(remaining) of \(total) free HTTPS inspections left this session. Restarting ReqRes resets the count; HTTP is unlimited. Click to see \(LicenseOffer.title).")
        .accessibilityLabel("Free HTTPS inspections")
        .accessibilityValue("\(remaining) of \(total) left")
        .accessibilityIdentifier("toolbarInspectionsGauge")
    }
}

// MARK: - Sidebar footer

/// The licence state, at the bottom of the sidebar — the same place and
/// metrics as snipperapp's sidebar footer (`SyncStatusBarView`: 12pt
/// horizontal / 8pt vertical padding, a half-opacity window-background wash,
/// above a `Divider`). The inspection COUNT is not here: on its own, "10 left"
/// meant nothing — it is the toolbar's gauge, next to the controls it
/// concerns.
struct SidebarLicenseFooter: View {
    @ObservedObject private var licenseManager = LicenseManager.shared

    var body: some View {
        HStack(spacing: 6) {
            #if DEBUG
            // Screenshot mode presents the licensed state so marketing captures
            // do not carry free-tier chrome. Display only — no licence is faked
            // anywhere a gate is actually enforced.
            let screenshotPro = ScreenshotMocks.isEnabled
            #else
            let screenshotPro = false
            #endif
            if screenshotPro {
                ProBadgeButton(action: {})
                    .fixedSize()
                    .accessibilityIdentifier("licenseBadgePro")
            } else if licenseManager.hasValidationFinished {
                if licenseManager.checkLicense() {
                    ProBadgeButton(action: {})
                        .fixedSize()
                        .accessibilityIdentifier("licenseBadgePro")
                } else {
                    TrialBadgeButton(action: { PaywallPresentation.shared.show(nil) })
                        .fixedSize()
                        .accessibilityIdentifier("licenseBadgeFree")
                }
            }

            Spacer(minLength: 8)

            AgentActivitySlot()
        }
        .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }
}

// MARK: - Agent activity

/// Who is driving ReqRes through the MCP bridge, and the fastest way to stop
/// them.
///
/// The bridge ships on, so "an agent can change my traffic" has to be visible
/// somewhere that is not four clicks deep in Settings. This sits in the sidebar
/// footer beside the licence badge, which is the same place snipperapp puts its
/// sync status, and it follows that surface's rules: the glyph is always
/// mounted so the row never changes width, and the label appears only when
/// there is something to say.
struct AgentActivitySlot: View {
    @ObservedObject private var service = MCPServerService.shared
    @State private var showingDetail = false

    private var clients: [MCPClient] { service.connectedClients }

    private var isConnected: Bool { !clients.isEmpty }

    /// Shown only while an agent is actually active, so an idle Mac has a
    /// quiet footer rather than a permanent "0 agents".
    private var label: String? {
        guard isConnected else { return nil }
        return clients.count == 1 ? clients[0].name : "\(clients.count) agents"
    }

    var body: some View {
        Button {
            showingDetail.toggle()
        } label: {
            HStack(spacing: 5) {
                if let label {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: isConnected ? "sparkles" : "sparkles.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(isConnected ? Color.accentColor : .secondary)
                    .symbolEffect(.pulse, isActive: isConnected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("AI agent activity")
        .accessibilityValue(helpText)
        .accessibilityIdentifier("sidebarAgentActivity")
        .popover(isPresented: $showingDetail, arrowEdge: .top) {
            AgentActivityPopover(clients: clients)
        }
        // The label appears and disappears; animate the width change rather
        // than letting the footer jump under the pointer.
        .animation(.easeInOut(duration: 0.15), value: isConnected)
    }

    private var helpText: String {
        guard service.isEnabled else { return "The AI bridge is off. No agent can reach ReqRes." }
        guard isConnected else { return "The AI bridge is on. No agent has used it recently." }
        let names = clients.map(\.name).joined(separator: ", ")
        return clients.count == 1
            ? "\(names) is using ReqRes through the AI bridge."
            : "\(names) are using ReqRes through the AI bridge."
    }
}

/// The detail behind the footer glyph: who, how recently, and the switch that
/// ends it. The kill switch lives here because this is where someone looks the
/// moment they wonder what an agent is doing.
struct AgentActivityPopover: View {
    let clients: [MCPClient]
    @ObservedObject private var service = MCPServerService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI bridge")
                .font(.system(size: 13, weight: .semibold))

            if !service.isEnabled {
                Label("Off. No agent can reach ReqRes.", systemImage: "sparkles.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if clients.isEmpty {
                Label("On. No agent has used it recently.", systemImage: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(clients) { client in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(client.name)
                                    .font(.system(size: 11, weight: .medium))
                                Text(Self.lastSeen(client.lastSeen))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            // Name and recency read as one element, as before;
                            // the button stays its own so its action survives.
                            .accessibilityElement(children: .combine)
                            Spacer(minLength: 8)
                            showTrafficButton(for: client)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button("Open Settings") { AgentActivityPopover.openMCPSettings() }
                Spacer()
                if service.isEnabled {
                    Button("Turn Off Bridge", role: .destructive) {
                        service.setEnabled(false)
                    }
                    .help("Stops the bridge and cancels anything an agent is waiting to have approved")
                }
            }
            .font(.system(size: 11))
        }
        .padding(16)
        .frame(width: 260)
    }

    /// From the agent to its requests (UX spec §8.3): the pid when the capture
    /// index has that pid (a command-line agent), else the app name when it
    /// has that app (a GUI agent's helpers), else disabled — with the reason,
    /// because "nothing from Claude Code yet" almost always means the CLI was
    /// started without the proxy environment.
    ///
    /// The index is READ here, not observed: this popover is transient and a
    /// stale answer costs one click; observing `SessionState` from a footer
    /// popover would re-render it on every 150ms flush.
    @ViewBuilder
    private func showTrafficButton(for client: MCPClient) -> some View {
        let sessions = SessionState.shared
        let link = MCPAgentTrafficLink.resolve(
            client: client,
            hasCapturedPid: { pid in sessions.pidCandidates(restrictedTo: []).contains { $0.pid == pid } },
            hasCapturedApp: { name in sessions.identity(forDisplayName: name) != nil }
        )
        switch link {
        case .pid(let pid):
            Button(MCPAgentTrafficLink.title) {
                TrafficSearchState.shared.addToken(.pid(pid))
                dismiss()
            }
            .controlSize(.small)
            .help("Show only requests from pid \(pid)")
        case .app(let name):
            Button(MCPAgentTrafficLink.title) {
                TrafficSearchState.shared.addToken(.app(name))
                dismiss()
            }
            .controlSize(.small)
            .help("Show only requests from \(name)")
        case .unavailable(let hint):
            Button(MCPAgentTrafficLink.title) {}
                .controlSize(.small)
                .disabled(true)
                .help(hint)
        }
    }

    /// Relative, because "14:09:22" asks the reader to do arithmetic.
    static func lastSeen(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 5 { return "active now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func openMCPSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
