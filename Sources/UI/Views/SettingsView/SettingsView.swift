//
//  General.swift
//  ReqRes
//
//  Created by OloApps on 8/19/24.
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

import SwiftUI
import Utils
import Settings
import XReqResCore
import Sentry

struct SettingsView: View {
    @AppStorage("selectedSettingsTab") private var selectedSettingsTab: SettingsTab = .general
    
    @ObservedObject private var licenseManager = LicenseManager.shared
    
    var body: some View {
        TabView(selection: $selectedSettingsTab) {
            SettingsPane { GeneralSettingsView() }
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(SettingsTab.general)
            
            SettingsPane { CaptureSettingsView() }
                .tabItem {
                    Label("Capture", systemImage: "shield.lefthalf.filled")
                }
                .tag(SettingsTab.capture)

            SettingsPane { CertificateSettingsView() }
                .tabItem {
                    Label("Certificate", systemImage: "newspaper")
                }
                .tag(SettingsTab.certificate)
            
            // Settings ▸ License: the core's grouped Form, as Storage and
            // Breakpoints are, pinned to the top by the same SettingsPane. It
            // fits the 580pt viewport (529pt without a license, 450pt with
            // one, measured by the core's PaywallLayoutTests), so it does not
            // scroll; SettingsPane would scroll it if it ever grew taller.
            SettingsPane { SubscriptionSettingsView(isInPreferences: true, planSheet: .reqres) }
                .tabItem {
                    // "License": ReqRes is paid for once, never by
                    // subscription (PRD A4). The tab keeps its case,
                    // `.subscription`: its raw value is persisted.
                    Label("License", systemImage: "checkmark.seal")
                }
                .tag(SettingsTab.subscription)

            SettingsPane { MCPSettingsView() }
                .tabItem {
                    Label("MCP", systemImage: "cpu")
                }
                .tag(SettingsTab.mcp)

            SettingsPane { StorageSettingsView() }
                .tabItem {
                    Label("Storage", systemImage: "internaldrive")
                }
                .tag(SettingsTab.storage)

            SettingsPane { BreakpointSettingsView() }
                .tabItem {
                    Label("Breakpoints", systemImage: "pause.circle")
                }
                .tag(SettingsTab.breakpoints)
        }
        .scenePadding()
        
        // A FIXED size per tab, as snipperapp's settings do. `maxWidth`/
        // `maxHeight` only cap the size, and a `Form` has no intrinsic height
        // to push against them — so the MCP tab opened a few hundred points
        // tall with its content cut off.
        .frame(width: Self.windowWidth, height: Self.windowHeight)
    }

    /// The MCP tab is a grouped form with a config block and a log; the
    /// others fit the classic 450pt window.
    /// ONE size for every tab: a window that resizes as you click through the
    /// tabs is the jumpiest thing in a settings window.
    /// The widest and tallest tab (MCP) sets it; the short tabs simply have
    /// room to spare, as System Settings does.
    private static let windowWidth: CGFloat = 700
    private static let windowHeight: CGFloat = 620
    
}

/// Every settings pane in the same box: pinned to the top of the window and
/// scrolled when its content is taller. Without it a short pane floated in the
/// middle of the window (the License tab's "top padding") and a tall one
/// resized the window on every tab switch.
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollBounceBehavior(.basedOnSize)
    }
}

enum SettingsTab: Int {
    // Raw values are persisted in `selectedSettingsTab`, so new cases are
    // APPENDED — inserting one would reopen a different tab for everyone who
    // has ever changed it. For the same reason `subscription` keeps its
    // name: it is the tab labelled "License".
    case general, appearance, certificate, subscription, mcp, capture, storage, breakpoints
}

/// App-level behaviour that is not about traffic.
///
/// The dividing rule, so this tab does not become the drawer everything falls
/// into: **General holds appearance, the traffic list's columns, updates,
/// confirmations and telemetry. Anything that changes what the engine does to
/// a request belongs to Capture, Certificate, Breakpoints, MCP or Storage.**
struct GeneralSettingsView: View {
    @ObservedObject private var updates = SparkleViewModel.shared
    @AppStorage("selectedAppearance") private var storedAppearance: AppearanceMode = .system
    /// The one key the traffic list reads for its Destination column; the
    /// constant lives in Utils so the layout's tests and this toggle share it.
    @AppStorage(SessionTableLayout.destinationColumnDefaultsKey) private var showsDestinationColumn = true
    /// Not `@AppStorage`: the reset REMOVES keys rather than writing false, and
    /// the button's enablement has to reflect several keys at once.
    @State private var hasSuppressedPrompts = SuppressibleConfirmations.anySuppressed(in: .standard)
    @AppStorage(ReqResStatusItemController.visibilityDefaultsKey) private var showMenuBarItem = true
    /// Mirrors the group-suite flag for the control's own state; the write in
    /// `onChange` is what the extension actually reads.
    @State private var crashReportingEnabled = TelemetryConsent.groupDefaults(appGroupID: AppGroup.identifier)
        .map { TelemetryConsent.isEnabled(in: $0) } ?? true
    @State private var loginItemState = LoginItemController.shared.state
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Appearance") {
                AppearanceRow(storedAppearance: $storedAppearance)
            }

            Section("Traffic List") {
                Toggle("Show Destination column", isOn: $showsDestinationColumn)

                // What the column is, and the one thing the toggle does NOT
                // decide: at the 660pt pane minimum with the App column showing
                // the row has no room for it, and a column that is on but
                // absent needs the reason said here, not discovered.
                Text(DestinationColumnCopy.summary + " " + DestinationColumnCopy.hidesWhenNarrow)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.automaticallyChecksForUpdates = $0 }
                ))
                Toggle("Download updates automatically", isOn: Binding(
                    get: { updates.automaticallyDownloadsUpdates },
                    set: { updates.automaticallyDownloadsUpdates = $0 }
                ))
                .disabled(!updates.automaticallyChecksForUpdates)

                LabeledContent("Last checked") {
                    HStack(spacing: 10) {
                        Text(updates.lastUpdateCheckDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                            .foregroundStyle(.secondary)
                        Button("Check Now") { updates.checkForUpdates() }
                            .disabled(!updates.canCheckForUpdates)
                    }
                }

                // Worth stating: ReqRes updates itself, and people who leave a
                // capture tool running for days had a modal appear once a day
                // until this release.
                Text("ReqRes checks in the background and tells you when an update is ready. Check Now reports the result either way, including when there is nothing new.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Menu Bar") {
                Toggle("Show ReqRes in the menu bar", isOn: $showMenuBarItem)
                    .onChange(of: showMenuBarItem) { _, _ in
                        ReqResStatusItemController.shared.applyVisibilityPreference()
                    }

                // The one thing a missing icon cannot tell you is where to get
                // it back — so the pane says it, and says what the icon is FOR,
                // which is not "quick access".
                Text("The icon shows whether ReqRes is decrypting your traffic, and stops capture in one click. Removed it by dragging it out of the menu bar? Switch it back on here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Startup") {
                Toggle(LoginItemController.toggleTitle, isOn: Binding(
                    get: { loginItemState.isOn },
                    set: { setLoginItem($0) }
                ))

                // `state.summary` rather than a string here, because
                // `.requiresApproval` is neither on nor a failure — macOS is
                // waiting for the user in Login Items, and only the controller
                // knows which of the three it is.
                Text(loginItemState.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let title = loginItemState.settingsButtonTitle {
                    Button(title) { LoginItemController.shared.openLoginItemsSettings() }
                }

                if let error = loginItemError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The promise this must never break: capture is a deliberate
                // act. A Mac that silently began decrypting all TLS at login
                // would break the user's own builds — live capture MITMs
                // Apple's timestamp request and `codesign` then refuses, with
                // an error naming an unrelated framework.
                Text(LoginItemController.captureDisclaimer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Privacy") {
                Toggle("Share crash and performance reports", isOn: $crashReportingEnabled)
                    .onChange(of: crashReportingEnabled) { _, enabled in
                        // The GROUP suite, not standard: the extension is a
                        // separate root process and reads only the group. A
                        // standard-suite write would leave reporting on in the
                        // root process while this row said off.
                        if let defaults = TelemetryConsent.groupDefaults(appGroupID: AppGroup.identifier) {
                            TelemetryConsent.setEnabled(enabled, in: defaults)
                        }
                        // And act on it NOW for this process. Writing the flag
                        // alone left the app's own client running and sending
                        // for the rest of the session, while the row claimed
                        // it was off.
                        if enabled {
                            (NSApp.delegate as? AppDelegate)?.initSentry()
                        } else {
                            SentrySDK.close()
                        }
                    }

                // Says what is sent, and the one thing a user would otherwise
                // discover by being surprised: the extension picks this up
                // when capture next starts, because it reads the flag inside
                // startTunnel and keeps the client it already made.
                Text("Crash reports and a 10% sample of performance traces, sent to ReqRes's own Sentry. No captured traffic is included — network breadcrumbs are switched off in both ReqRes and the capture extension, because in a proxy the app’s “own” requests are the user’s traffic. Turning this off stops ReqRes reporting immediately; the capture extension stops the next time capture starts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Confirmations") {
                LabeledContent("Suppressed warnings") {
                    Button("Reset All Warnings") {
                        SuppressibleConfirmations.resetAll(in: .standard)
                        hasSuppressedPrompts = false
                    }
                    .disabled(!hasSuppressedPrompts)
                }

                // The reason this row exists at all: “Don’t ask again” was a
                // one-way door. Nothing in the app could clear it, so a
                // mis-tick meant a destructive action stopped asking forever.
                // The checkbox is quoted from the constant the alerts set as
                // its title, so the two cannot drift apart.
                Text("ReqRes asks before deleting a host filter or an override, and before clearing captured traffic. Each of those dialogs can be silenced with “\(SuppressibleConfirmations.checkboxTitle)”; this brings them all back.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            AppearanceSettingsView.apply(storedAppearance)
            hasSuppressedPrompts = SuppressibleConfirmations.anySuppressed(in: .standard)
            // macOS can change this behind the app's back — the user may
            // approve or revoke it in System Settings while this is open.
            loginItemState = LoginItemController.shared.state
        }
        // Settings stays on screen while a confirmation alert runs, so a
        // prompt turned off there — the box ticked, the action chosen — has
        // to enable Reset All Warnings now, not the next time this tab is
        // shown. The notice arrives on the thread that wrote: the alerts
        // write on main, and the hop covers any other writer.
        .onReceive(NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .receive(on: DispatchQueue.main)) { _ in
            let suppressed = SuppressibleConfirmations.anySuppressed(in: .standard)
            if suppressed != hasSuppressedPrompts { hasSuppressedPrompts = suppressed }
        }
    }

    /// Asks, then RE-READS. A successful `register()` does not mean the app
    /// will open at login: macOS may answer `.requiresApproval` and wait for
    /// the user in Login Items, and a toggle that snapped to "on" there would
    /// be claiming something untrue.
    private func setLoginItem(_ enabled: Bool) {
        loginItemError = nil
        do {
            try LoginItemController.shared.setEnabled(enabled)
        } catch let error as LoginItemError {
            loginItemError = [error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }.joined(separator: " ")
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemState = LoginItemController.shared.state
    }
}

/// The appearance control, extracted so General can place it under its own
/// header now that it has siblings — which is what the 2026-09-22 note in
/// `AppearanceSettingsView` said to do when that day came.
private struct AppearanceRow: View {
    @Binding var storedAppearance: AppearanceMode

    var body: some View {
        // A plain Picker, not a `Menu` with a hand-built label: the label drew
        // its own chevron and background INSIDE the menu's own bordered
        // control, so the row showed two chevrons and a stray dark pill.
        Picker(selection: $storedAppearance) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
            }
        } label: {
            Text("Appearance")
        }
        .pickerStyle(.menu)
        .onChange(of: storedAppearance) { _, mode in
            AppearanceSettingsView.apply(mode)
        }

        Text("System follows the macOS setting, including its automatic light/dark switch.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("selectedAppearance") private var storedAppearance: AppearanceMode = .system

    var body: some View {
        Form {
            Section {
                // A plain Picker, not a `Menu` with a hand-built label: the
                // label drew its own chevron and background INSIDE the menu's
                // own bordered control, so the row showed two chevrons and a
                // stray dark pill.
                Picker(selection: $storedAppearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                    }
                } label: {
                    Text("Appearance")
                }
                .pickerStyle(.menu)
                .onChange(of: storedAppearance) { _, mode in
                    Self.apply(mode)
                }
                Text("System follows the macOS setting, including its automatic light/dark switch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // No section header. It read "Appearance" directly above a row
            // labelled "Appearance" — the tab
            // is already called General, so the group needs no second name and
            // the row keeps the one macOS itself uses in System Settings. A
            // section that gains a sibling can take a header then; a lone
            // group at the top of a pane conventionally has none.
        }
        .formStyle(.grouped)
        .onAppear { Self.apply(storedAppearance) }
    }

    static func apply(_ mode: AppearanceMode) {
        switch mode {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}

enum AppearanceMode: String, CaseIterable, Codable {
    case light = "Light"
    case dark = "Dark"
    case system = "System"

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var symbolName: String {
        switch self {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .system: return "circle.lefthalf.filled"
        }
    }

    var icon: some View {
        Image(systemName: symbolName)
    }
}
 
struct CertificateSettingsView: View {
    var body: some View {
        CACertificateModal()
    }
}

#Preview {
    SettingsView()
}
