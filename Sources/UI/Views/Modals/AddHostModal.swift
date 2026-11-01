//
//  AddHostModal.swift
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
//  Add a host filter. A sheet in snipperapp's small-form shape: title and
//  context line, stacked caption-over-control groups, inline validation, and
//  Cancel · Add with the system key equivalents.
//

import SwiftUI
import Utils
import XReqResCore

struct AddHostModal: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var licenseManager = LicenseManager.shared
    @ObservedObject private var appState = AppState.shared

    @State private var hostName = ""
    @State private var reqProtocol: RequestProtocolType = .HTTPS
    @State private var freeLimitReached = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var hostFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("New Host Filter")
                    .font(.system(size: 13, weight: .semibold))
                Text("Traffic for this host gets its own entry in the sidebar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if freeLimitReached {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    Text("The free version includes two host filters. Upgrade for unlimited filters.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    // The sheet opens with Reached on this limit's row.
                    Button("Upgrade…") {
                        dismiss()
                        PaywallPresentation.shared.show(.hostFilters)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Protocol")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("Protocol", selection: $reqProtocol) {
                    ForEach(RequestProtocolType.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("Hostname")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("api.example.com", text: $hostName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($hostFocused)
                if let message = validationMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 340)
        .onAppear {
            hostFocused = true
            checkFreeLimit()
        }
    }

    // MARK: - Derived

    private var trimmedHost: String {
        hostName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var alreadyAdded: Bool {
        appState.hosts.contains { $0.host.lowercased() == trimmedHost }
    }

    private var validationMessage: String? {
        guard !trimmedHost.isEmpty else { return nil }
        if alreadyAdded { return "That host is already in the sidebar." }
        if !trimmedHost.isValidHostname { return "Enter a hostname such as api.example.com — no scheme, port or path." }
        return nil
    }

    private var canSave: Bool {
        !freeLimitReached && !isSaving && !trimmedHost.isEmpty && trimmedHost.isValidHostname && !alreadyAdded
    }

    // MARK: - Actions

    /// The free tier allows `FreeTier.hostFilters` host filters. Say so when
    /// the form OPENS — and read the number from the same constant the
    /// paywall quotes, so the two can never disagree.
    private func checkFreeLimit() {
        guard !licenseManager.isProUser() else { return }
        Task {
            let count = (try? await ReqResCoreModelBridge.findAllHosts().count) ?? 0
            await MainActor.run { freeLimitReached = FreeTier.hostFilterLimitReached(existing: count) }
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        let newHost = HostCodable(
            host: trimmedHost,
            port: NSNumber(value: 80), // the port is not configurable yet
            hostDbId: nil,
            requestProtocol: reqProtocol.rawValue
        )
        Task {
            do {
                let saved = try await ReqResCoreModelBridge.saveHost(newHost)
                let allHosts = try await ReqResCoreModelBridge.findAllHosts()
                await MainActor.run {
                    AppState.shared.hosts.append(saved)
                    AppController.shared.notifyExtension(message: ServerBusMessage(
                        action: .allHostsChanged,
                        payload: ["data": allHosts]
                    ))
                    dismiss()
                }
            } catch {
                AppLog.shared.error("Error creating host: \(error)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}
