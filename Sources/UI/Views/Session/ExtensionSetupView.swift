//
//  ExtensionSetupView.swift
//  ReqRes
//
//  Created by OloApps on 9/6/26.
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

import SwiftUI

/// Guided setup for the Network Extension — the hardest part of using ReqRes.
///
/// Written from what actually happens on macOS 15+/26, where enabling a network
/// extension takes a step Apple does not make obvious: the list is behind an ⓘ
/// button inside Login Items & Extensions. Earlier copy sent people to
/// "Privacy & Security → Extensions" (removed in macOS 15) and then to a pane
/// with no visible ReqRes entry, which is why setup felt broken.
///
/// The view shows every step at once with the current one highlighted, so the
/// user can see where they are instead of being handed one instruction at a time.
struct ExtensionSetupView: View {
    let status: ExtensionSetupStatus
    let onPrimaryAction: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Image(systemName: status == .needsRestart ? "arrow.counterclockwise.circle" : "shield.lefthalf.filled")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .padding(.bottom, 14)

            Text(headline)
                .font(.title3.weight(.semibold))
                .padding(.bottom, 6)

            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    stepRow(number: index + 1, text: step, state: state(for: index))
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 460)

            if status == .extensionDisabled {
                // The app is watching; say so, or the user assumes it is stuck.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to enable it — this screen updates automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 14)
            }

            HStack(spacing: 10) {
                Button(primaryTitle, action: onPrimaryAction)
                    .buttonStyle(.borderedProminent)
                if status == .extensionDisabled || status == .notInstalled {
                    Button("Open System Settings", action: onOpenSettings)
                }
            }
            .padding(.top, 18)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Steps

    private static let steps = [
        "Install the extension — macOS will ask for permission.",
        "In System Settings ▸ General ▸ Login Items & Extensions, scroll to Network Extensions and click the ⓘ button beside it.",
        "Switch ReqRes on, then click Done.",
        "Allow ReqRes to add VPN configurations when macOS asks.",
        "Install and trust the ReqRes certificate to read HTTPS.",
    ]

    private enum StepState { case done, current, upcoming }

    /// Maps the setup state machine onto the visible checklist.
    private func state(for index: Int) -> StepState {
        let currentStep: Int
        switch status {
        case .notInstalled:        currentStep = 0
        case .extensionDisabled:   currentStep = 1
        case .needsRestart:        currentStep = 2
        case .configurationMissing: currentStep = 3
        case .ready:               currentStep = 4
        }
        if index < currentStep { return .done }
        if index == currentStep { return .current }
        return .upcoming
    }

    @ViewBuilder
    private func stepRow(number: Int, text: String, state: StepState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .current:
                    Image(systemName: "\(number).circle.fill").foregroundStyle(.tint)
                case .upcoming:
                    Image(systemName: "\(number).circle").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 15))

            Text(text)
                .font(.callout)
                .foregroundStyle(state == .upcoming ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
                .fontWeight(state == .current ? .medium : .regular)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Copy per state

    private var headline: String {
        switch status {
        case .notInstalled:         return "Set up traffic capture"
        case .extensionDisabled:    return "Enable ReqRes in System Settings"
        case .needsRestart:         return "Restart your Mac to finish"
        case .configurationMissing: return "Allow the VPN configuration"
        case .ready:                return "Ready to capture"
        }
    }

    private var explanation: String {
        switch status {
        case .notInstalled:
            return "ReqRes captures traffic with a network extension, so it sees every app on your Mac — no proxy settings to configure."
        case .extensionDisabled:
            return "The extension is installed but switched off. macOS keeps this switch two levels deep, so here is exactly where to look."
        case .needsRestart:
            // macOS said the new extension loads after a reboot (ActivationDelegate
            // .handleWillCompleteAfterReboot); relaunching the app only clears the
            // flag while the old extension keeps running (F21).
            return "The extension is enabled, but macOS loads the new version only after your Mac restarts. Restarting ReqRes alone does not."
        case .configurationMissing:
            return "macOS needs your permission for ReqRes to route traffic through itself. Choose Allow when the dialog appears."
        case .ready:
            return "Everything is set up."
        }
    }

    private var primaryTitle: String {
        switch status {
        case .notInstalled:         return "Install Network Extension"
        case .extensionDisabled:    return "Open Network Extensions"
        case .needsRestart:         return "Restart Now"
        case .configurationMissing: return "Install VPN Configuration"
        case .ready:                return "Start Monitoring"
        }
    }
}
