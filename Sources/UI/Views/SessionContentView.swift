//
//  SessionContentView.swift
//  ReqRes
//
//  Created by OloApps on 3/27/25.
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

import MCPKit
import SwiftUI
import Utils
import XReqResCore

struct SessionContentView: View {
    @ObservedObject var sessionState = SessionState.shared
    @ObservedObject var appState = AppState.shared
    @ObservedObject var search = TrafficSearchState.shared
    /// Whether what capture records reaches this window (F11).
    @ObservedObject var delivery = CaptureDeliveryMonitor.shared
    /// For "Open Capture Settings" in the app-filter empty state (UX spec
    /// §8.4) — the same pair every other Settings deep link in the app uses.
    @AppStorage("selectedSettingsTab") private var selectedSettingsTab = SettingsTab.general
    @Environment(\.openSettings) private var openSettings

    // Track extension status
    // @State private var extensionStatus: ExtensionSetupStatus = .ready
    
    var body: some View {
        let completelyEmpty = sessionState.sessions.isEmpty
        let filteredSessionsEmpty = sessionState.filteredSessions.isEmpty
        let searchTextEmpty = search.filter.isEmpty
        // Capture on and nothing reaching this window (F11): the empty list
        // says why, and a list with rows in it gets a strip above it — the
        // rows are from before, and nothing new is coming.
        let notice = appState.extensionStatus == .ready ? CaptureDeliveryCopy.notice(for: delivery.delivery) : nil
        // The one-line note (build 53): what a reattach delivered, or that
        // ReqRes restarted capture by itself. Not shown while a notice that
        // needs attention is, nor while a restart is under way.
        let note = appState.extensionStatus == .ready && !delivery.isRestarting ? delivery.notice : nil
        #if DEBUG
        // Screenshot mode is a believable capture in memory, usually taken
        // while the installed app holds the real one — which this copy would
        // otherwise, truthfully, announce over the rows.
        let showsNotice = notice != nil && !ScreenshotMocks.isEnabled
        let showsNote = note != nil && !ScreenshotMocks.isEnabled
        #else
        let showsNotice = notice != nil
        let showsNote = note != nil
        #endif
        
        VStack(spacing: 0) {
            if showsNotice, let notice, !completelyEmpty {
                CaptureDeliveryBanner(title: notice.title, detail: bannerDetail(fallback: notice.detail),
                                      offersRestart: delivery.delivery.offersRestart,
                                      isRestarting: delivery.isRestarting,
                                      restart: delivery.restartCapture)
                Divider()
            } else if showsNote, !showsNotice, let note {
                CaptureNoteStrip(text: note.text(busPort: MessageBusPort),
                                 isProblem: note.isProblem,
                                 dismiss: delivery.dismissNotice)
                Divider()
            }
            Group {
                if appState.extensionStatus != .ready {
                    // One guided checklist for every incomplete state, so the user can
                    // see the whole path and where they are on it. Replaces five
                    // separate cards that each showed a single instruction.
                    ExtensionSetupView(
                        status: appState.extensionStatus,
                        onPrimaryAction: {
                            switch appState.extensionStatus {
                            case .extensionDisabled: openSystemSettings()
                            case .needsRestart: restartComputer()
                            case .configurationMissing: installVPNConfiguration()
                            default: handleStartOrInstallTunnel()
                            }
                        },
                        onOpenSettings: openSystemSettings
                    )
                } else if completelyEmpty && delivery.isRestarting {
                    // Stop, then start: without this the pane flashes "Start
                    // Network Monitoring" while the tunnel is briefly down.
                    // A restart ReqRes makes by itself says why (build 53).
                    EmptyStateView(
                        title: CaptureDeliveryCopy.restartingTitle,
                        subtitle: delivery.automaticRestartProblem.map(CaptureDeliveryCopy.automaticRestartingDetail(for:))
                            ?? CaptureDeliveryCopy.restartingDetail,
                        iconName: "arrow.clockwise"
                    )
                } else if completelyEmpty, showsNotice, let notice {
                    // Capture is on and this window is not receiving it. Restart
                    // is offered only when it helps — never to take the capture
                    // away from another copy of ReqRes that is receiving it.
                    if case .notReceiving(let problem) = delivery.delivery {
                        EmptyStateView(
                            title: notice.title,
                            // With what ReqRes's own restart already did in
                            // this stretch: the one-line note that says it is
                            // hidden while this shows (build 53).
                            subtitle: CaptureDeliveryCopy.emptyStateDetail(for: problem, restartTried: delivery.restartTried,
                                                                           busPort: MessageBusPort),
                            iconName: "exclamationmark.triangle",
                            buttonTitle: CaptureDeliveryCopy.restartButton,
                            buttonAction: delivery.restartCapture
                        )
                    } else {
                        EmptyStateView(
                            title: notice.title,
                            subtitle: notice.detail,
                            iconName: "macwindow.on.rectangle"
                        )
                    }
                } else if completelyEmpty && delivery.delivery == .reconnecting {
                    // A capture that outlived the app (or whose connection
                    // closed) is finding it again (build 53): what it captured
                    // meanwhile lands here in a moment.
                    EmptyStateView(
                        title: CaptureDeliveryCopy.reconnectingTitle,
                        subtitle: CaptureDeliveryCopy.reconnectingDetail,
                        iconName: "arrow.triangle.2.circlepath"
                    )
                } else if completelyEmpty && appState.vpnStatus == .disconnected {
                    // Tunnel not running, no sessions, extension ready
                    // This is either first-time use or user has stopped monitoring
                
                    // Only show "Start Monitoring" if the extension is fully ready AND has been attempted before
                    let isExtensionFullyReady = appState.extensionStatus == .ready
                
                    EmptyStateView(
                        title: "Start Network Monitoring",
                        subtitle:
                        "Click 'Start Monitoring' below or the play button in the top right corner to begin capturing and inspecting network traffic.",
                        iconName: "network",
                        buttonTitle: "Start Monitoring",
                        buttonAction: handleStartOrInstallTunnel
                    )
                } else if completelyEmpty {
                    // Regular empty state
                    // UX spec §8.5: browsers arrive on their own; a CLI does not.
                    EmptyStateView(
                        title: "No Requests",
                        subtitle: "When ReqRes captures requests, they will appear here. Browsers and most apps arrive on their own; a command-line tool such as the Claude Code CLI needs two lines first — Settings ▸ Capture.",
                        iconName: "tray.and.arrow.down.fill"
                    )
                } else if filteredSessionsEmpty && searchTextEmpty {
                    EmptyStateView(
                        title: "No Requests",
                        subtitle: "ReqRes hasn't captured any requests for this host yet.",
                        iconName: "tray.and.arrow.down.fill"
                    )
                } else if filteredSessionsEmpty && !searchTextEmpty {
                    if let destination = destinationFilterTitle {
                        // A `country:` chip matched nothing (destination-map UX
                        // spec §5.6). The likeliest reason is scope, not a typo:
                        // the Destinations window counts every retained request,
                        // the table only the sidebar's host.
                        EmptyStateView(
                            title: "No Requests Found",
                            subtitle: "Nothing captured in the current view has \(destination) as its destination. The Destinations window counts all captured traffic — pick All traffic in the sidebar to see everything.",
                            iconName: "rectangle.and.text.magnifyingglass"
                        )
                    } else if let subject = attributionFilterSubject {
                        // An `app:` or `pid:` chip matched nothing (UX spec §8.4).
                        // The likeliest reason is not a typo but a tool that never
                        // reached ReqRes because it ignores the system proxy, so
                        // the way out is Settings ▸ Capture, not the search field.
                        if appState.processAttribution == .unavailable {
                            EmptyStateView(
                                title: "No Requests Found",
                                subtitle: "No requests match. ReqRes cannot tell which app makes a request on this Mac right now, so app: matches nothing — Capture ▸ Diagnose Setup… has the details.",
                                iconName: "rectangle.and.text.magnifyingglass"
                            )
                        } else {
                            EmptyStateView(
                                title: "No Requests Found",
                                subtitle: "Nothing captured from \(subject). A command-line tool may not read the system proxy — set it up in Settings ▸ Capture.",
                                iconName: "rectangle.and.text.magnifyingglass",
                                buttonTitle: "Open Capture Settings",
                                buttonAction: openCaptureSettings
                            )
                        }
                    } else {
                        EmptyStateView(
                            title: "No Requests Found",
                            subtitle: "Requests matching your search query were not found.",
                            iconName: "rectangle.and.text.magnifyingglass"
                        )
                    }
                } else {
                    SessionView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            checkExtensionStatus()
            // Converge without a relaunch: while setup is incomplete the manager
            // re-checks on a timer, so enabling the extension in System Settings
            // advances this screen on its own.
            ExtensionStatusManager.shared.beginWatchingSetup()
        }
        .onReceive(NotificationCenter.default.publisher(for: ExtensionStatusManager.extensionStatusChanged)) { notification in
            // Get status from notification if available
            /*if let statusRawValue = notification.userInfo?["status"] as? String,
               let status = ExtensionSetupStatus(rawValue: statusRawValue) {
                self.extensionStatus = status
            } else if let _ = notification.userInfo?["isEnabled"] as? Bool {
                // Fallback for backward compatibility
                // Refresh full status asynchronously without showing alerts
                checkExtensionStatus()
            }*/
        }
    }
    
    // MARK: - Helper Functions

    /// The banner's detail over listed rows: while ReqRes restarts capture by
    /// itself, that it does and why — the spinner on a disabled Restart
    /// Capture otherwise read as the person's own click; else the reason with
    /// what that restart already did in this stretch (build 53).
    private func bannerDetail(fallback: String) -> String {
        if delivery.isRestarting, let problem = delivery.automaticRestartProblem {
            return CaptureDeliveryCopy.automaticRestartingDetail(for: problem)
        }
        if case .notReceiving(let problem) = delivery.delivery {
            return CaptureDeliveryCopy.notReceivingDetail(for: problem, restartTried: delivery.restartTried, busPort: MessageBusPort)
        }
        return fallback
    }

    /// What the destination empty state names: the first `country:` chip as
    /// its title — the localised country name, or This Mac / Local Network /
    /// Unknown — nil when the search has no country chip. A code the table
    /// does not know (`country:XX`) is named as itself, never invented.
    private var destinationFilterTitle: String? {
        guard let token = search.filter.countries.first else { return nil }
        guard let destination = TrafficDestination.parseToken(token) else { return token }
        return CountryPresentation.title(for: destination)
    }

    /// What the §8.4 empty state names: the first `app:` chip, else the first
    /// `pid:` chip as "pid N", else nil when the search has neither.
    private var attributionFilterSubject: String? {
        if let app = search.filter.apps.first { return app }
        if let pid = search.filter.pids.first { return "pid \(pid)" }
        return nil
    }

    private func openCaptureSettings() {
        selectedSettingsTab = .capture
        openSettings()
    }

    // The extension-approval pane moved in macOS 15 (Sequoia/Tahoe):
    // General → Login Items & Extensions; Sonoma keeps Privacy & Security.
    private var activateExtensionSubtitle: String {
        if #available(macOS 15.0, *) {
            return "To use network monitoring, enable the ReqRes extension in System Settings → General → Login Items & Extensions."
        } else {
            return "To use network monitoring, allow the ReqRes extension in System Settings → Privacy & Security."
        }
    }

    /// Handles the initial start button click
    private func handleStartOrInstallTunnel() {
        // First check if we have proper permissions and config
        Task {
            do {
                let status = try await ExtensionStatusManager.shared.checkCompleteStatus()
                
                // Update on main thread
                await MainActor.run {
                    // Update our status internally, but don't show alerts
                    appState.extensionStatus = status
                    
                    // A start, never a toggle: this button is only shown
                    // while capture reads off, and if it turns out to be
                    // running after all it is shown, not stopped (F11).
                    AppController.shared.startCapture()
                }
            } catch {
                await MainActor.run {
                    
                }
            }
        }
    }
    
    private func _handleVPNConfigurationInstall() {
        do {
            // Just call toggleVPNTunnel - it will handle creating the config
            _ = try AppController.shared.toggleVPNTunnel()
        } catch {
            AppLog.shared.error("[SessionContentView] Error installing VPN configuration: \(error.localizedDescription)")
        }
    }
    
    private func openSystemSettings() {
        // The extension-approval pane moved in macOS 15 (Sequoia/Tahoe):
        // General → Login Items & Extensions; Sonoma (the deployment floor)
        // keeps it under Privacy & Security.
        let urlString: String
        if #available(macOS 15.0, *) {
            urlString = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Install VPN Configuration: macOS asks the user to allow it. The status
    /// checks only read now (F11 review — they put the prompt up again after
    /// every Don't Allow), so this button is what creates it; the checklist
    /// then moves on from the fresh status.
    private func installVPNConfiguration() {
        Task {
            await ExtensionStatusManager.shared.installVPNConfiguration()
            checkExtensionStatus()
        }
    }
    private func restartComputer() {
        let script = """
        tell application "System Events"
            restart
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                AppLog.shared.error("[SessionContentView] Error restarting: \(error)")
            }
        }
    }
    
    private func startVPN() {
        do {
            // Just toggle the VPN tunnel (extension is already installed)
            _ = try AppController.shared.toggleVPNTunnel()
        } catch {
            AppLog.shared.error("[SessionContentView] Error starting VPN: \(error.localizedDescription)")
        }
    }
    
    private func checkExtensionStatus() {
        Task {
            do {
                let status = try await ExtensionStatusManager.shared.checkCompleteStatus()
                
                // Update on main thread
                await MainActor.run {
                    appState.extensionStatus = status
                }
            } catch {
                AppLog.shared.error("[SessionContentView] Error checking extension status: \(error.localizedDescription)")
            }
        }
    }
}

/// One line above the pane's content (build 53) — what a reattach delivered,
/// that ReqRes restarted capture by itself, or that it could not — until the
/// person dismisses it.
private struct CaptureNoteStrip: View {
    let text: String
    let isProblem: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isProblem ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background((isProblem ? Color.orange : Color.accentColor).opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}

/// The strip above captured rows while capture is on and nothing new reaches
/// this window (F11): what is wrong, why, and — unless another copy of ReqRes
/// is receiving the capture — the one action that fixes it.
private struct CaptureDeliveryBanner: View {
    let title: String
    let detail: String
    let offersRestart: Bool
    let isRestarting: Bool
    let restart: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: offersRestart ? "exclamationmark.triangle.fill" : "macwindow.on.rectangle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .fontWeight(.semibold)
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if offersRestart {
                // One fixed box: the spinner replaces the button's label, so
                // the strip never re-lays out mid-restart.
                Button(action: restart) {
                    ZStack {
                        Text(verbatim: CaptureDeliveryCopy.restartButton).opacity(isRestarting ? 0 : 1)
                        if isRestarting { ProgressView().controlSize(.small) }
                    }
                }
                .controlSize(.small)
                .disabled(isRestarting)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .accessibilityElement(children: .contain)
    }
}
