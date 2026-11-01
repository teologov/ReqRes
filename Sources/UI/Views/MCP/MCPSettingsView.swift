//
//  MCPSettingsView.swift
//  ReqRes
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
//  Settings → MCP: Server Status first (is it running, over what, from where),
//  then the server section with the configuration and a Copy button, then
//  numbered setup steps and the clients that work. It also has the bridge
//  toggle (the kill switch), the approval policy, and the log of what agents
//  have actually done.
//

import AppKit
import MCPKit
import SwiftUI
import UniformTypeIdentifiers

struct MCPSettingsView: View {
    @ObservedObject private var activity = MCPAgentActivity.shared
    @ObservedObject private var service = MCPServerService.shared

    @State private var bridgeEnabled = MCPServerService.shared.isEnabled
    @State private var bridgePort: UInt16? = MCPServerService.shared.port
    @State private var askBeforeChanges = !MCPAgentActivity.shared.writesWithoutAsking
    @State private var copied: String?
    @ObservedObject private var redaction = MCPRedactionSettings.shared
    /// The "Send unmasked" field and what Add last refused in it — not the
    /// sentence about it, which is derived (`ExceptionField.note`) so it
    /// cannot outlive the submission it answered or the list it was checked
    /// against (F13).
    @State private var exceptionField = MCPRedactionPolicy.ExceptionField()
    @State private var exportNote: String?
    @State private var undoNote: String?
    @State private var undoFailed = false

    /// The stdio server clients spawn, inside the app bundle.
    static var binaryPath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/reqres-mcp"
    }

    private var binaryExists: Bool {
        FileManager.default.isExecutableFile(atPath: Self.binaryPath)
    }

    /// Whether the path in the configuration will still be valid next launch.
    private var pathIsStable: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") && !path.contains("/AppTranslocation/")
    }

    private var configJSON: String {
        """
        {
          "mcpServers": {
            "reqres": {
              "command": "\(Self.binaryPath)",
              "args": []
            }
          }
        }
        """
    }

    /// `--scope user`: without it the CLI registers the server for whichever
    /// directory the command happened to run in.
    private var claudeCodeCommand: String {
        "claude mcp add --scope user reqres \"\(Self.binaryPath)\""
    }

    var body: some View {
        Form {
            serverStatusSection
            bridgeSection
            setupSection
            approvalSection
            redactionSection
            activitySection
            aboutSection
        }
        .formStyle(.grouped)
        .onAppear {
            bridgeEnabled = service.isEnabled
            bridgePort = service.port
            askBeforeChanges = !activity.writesWithoutAsking
        }
    }

    // MARK: - Server status

    private var serverStatusSection: some View {
        Section("Server Status") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                    Text(statusText)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                statusRow("Protocol", "Standard I/O (stdio) → loopback HTTP")
                statusRow("Binary", Self.binaryPath, monospaced: true)
                if !pathIsStable {
                    // From a DMG or a translocated copy the path changes on
                    // every launch, so a configuration copied now breaks later.
                    Label("Move ReqRes to your Applications folder before copying the configuration — this path changes on every launch. (The network extension needs /Applications anyway.)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusSymbol: String {
        if !binaryExists { return "xmark.circle.fill" }
        if service.lastStartError != nil, bridgeEnabled { return "xmark.circle.fill" }
        if bridgeEnabled, bridgePort != nil { return "checkmark.circle.fill" }
        if bridgeEnabled { return "clock.fill" }
        return "pause.circle.fill"
    }

    private var statusColor: Color {
        switch statusSymbol {
        case "checkmark.circle.fill": return .green
        case "xmark.circle.fill": return .red
        default: return .secondary
        }
    }

    private var statusText: String {
        if !binaryExists { return "Server binary not found in this build" }
        if let error = service.lastStartError, bridgeEnabled { return "Could not start: \(error)" }
        if bridgeEnabled, let port = bridgePort { return "Running — listening on 127.0.0.1:\(String(port))" }
        if bridgeEnabled { return "Starting…" }
        return "Turned off — assistants cannot reach ReqRes"
    }

    // MARK: - The bridge and its configuration

    private var bridgeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("MCP Server")
                    .font(.system(size: 13, weight: .semibold))

                Text("Lets AI assistants such as Claude read the traffic ReqRes captured and — with your approval — create rules and host filters, map local files and control capture. The bridge listens on this Mac only, only while ReqRes is running, and only a client that can read ReqRes's handshake file can reach it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable the AI bridge", isOn: $bridgeEnabled)
                    .onChange(of: bridgeEnabled) { _, enabled in
                        service.setEnabled(enabled) { bridgePort = service.port }
                    }

                configurationBox
            }
        }
    }

    private var configurationBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MCP Configuration")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                copyButton(configJSON, tag: "json")
            }
            GroupBox {
                Text(configJSON)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Add this to Claude Desktop's or your AI tool's MCP configuration file.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack {
                Text("Claude Code")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                copyButton(claudeCodeCommand, tag: "cc")
            }
            .padding(.top, 4)
            GroupBox {
                Text(claudeCodeCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func copyButton(_ text: String, tag: String) -> some View {
        Button {
            copy(text, tag: tag)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied == tag ? "checkmark" : "doc.on.doc")
                Text(copied == tag ? "Copied" : "Copy")
            }
            .font(.system(size: 10))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section("Setup Instructions") {
            VStack(alignment: .leading, spacing: 10) {
                instructionRow(1, "Copy the configuration above")
                instructionRow(2, "Claude Desktop → Settings → Developer → Edit Config")
                instructionRow(3, "Merge the \"reqres\" entry into \"mcpServers\", keeping any servers already there")
                instructionRow(4, "Quit Claude Desktop and open it again")
                instructionRow(5, "Ask it to call capture_status")
                Button("Reveal Claude Desktop Config in Finder") { revealClaudeConfig() }
                    .controlSize(.small)
                    .padding(.leading, 28)
            }
            .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 6) {
                clientRow("Claude Desktop", note: "the configuration above")
                clientRow("Claude Code", note: "the command above")
                clientRow("Cursor", note: "~/.cursor/mcp.json, same shape")
                clientRow("Windsurf and other MCP clients", note: "anything that spawns a stdio server")
            }
        }
    }

    // MARK: - Approval

    private var approvalSection: some View {
        Section("Approval") {
            Toggle("Ask before an agent changes rules, hosts or capture", isOn: $askBeforeChanges)
                .onChange(of: askBeforeChanges) { _, ask in
                    activity.setWritesWithoutAsking(!ask)
                }
            if activity.sessionGrant {
                LabeledContent("This session") {
                    HStack {
                        Text("Changes are allowed without asking until ReqRes quits")
                            .foregroundStyle(.secondary)
                        Button("Revoke") { activity.revokeSessionGrant() }
                            .controlSize(.small)
                    }
                }
            }
            Text(askBeforeChanges
                 ? "Everything an agent asks for in one turn appears in a single panel, which waits \(Int(MCPAgentActivity.approvalTimeout))s for your answer and then stops waiting — nothing changes, and the agent is told it timed out rather than that you refused. Reading never asks."
                 : "Agents change ReqRes immediately — except excluding a host from capture and replaying a request, which always ask. Every action still appears below.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Redaction

    private var redactionSection: some View {
        Section("Redaction") {
            Text("Credential-shaped headers, query values and body fields are replaced with \(MCPRedactor.placeholder) before anything reaches an agent. List a host here to send its traffic through unmasked — a staging API you know holds nothing real.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(redaction.policy.exceptedHosts, id: \.self) { host in
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .foregroundStyle(.orange)
                    Text(host)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Remove") { redaction.removeException(host) }
                        .controlSize(.small)
                        .accessibilityLabel("Redact \(host) again")
                }
            }

            // `prompt:`, not the title: a grouped Form promotes a TextField's
            // title to the row's LABEL column, which put the example host on
            // the left of the row and left the field itself unlabelled.
            LabeledContent("Send unmasked") {
                HStack(spacing: 8) {
                    TextField("", text: $exceptionField.text, prompt: Text("api.staging.example.com"))
                        .textFieldStyle(.roundedBorder)
                        // A Form's value column right-aligns text; a host
                        // typed from the right reads as a bug.
                        .multilineTextAlignment(.leading)
                        .onSubmit(addException)
                    Button("Add", action: addException)
                        .disabled(!exceptionField.canSubmit)
                }
            }

            // Re-derived on every render: an edit of the field hides it until
            // Add is pressed again, and removing the host it named from the
            // list above re-checks it.
            if let exceptionNote = exceptionField.note(for: redaction.policy) {
                Text(exceptionNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !redaction.policy.exceptedHosts.isEmpty {
                // Worth restating next to the list: the exception applies to
                // everything about those hosts — Authorization headers,
                // Set-Cookie, tokens in bodies — not only to the values that
                // happened to look uninteresting when it was added.
                Label("Agents see real values for these hosts, including anything credential-shaped.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        Section("Activity") {
            if let exports = exportedFileCount {
                // The folder is inside the app's container, which is not
                // somewhere anyone finds by browsing — the agent gets a path,
                // the user gets this.
                LabeledContent("Saved traffic") {
                    HStack(spacing: 8) {
                        Text("\(exports) HAR \(exports == 1 ? "file" : "files") an agent exported")
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") { revealExports() }
                            .controlSize(.small)
                    }
                }
            }
            if activity.entries.isEmpty {
                Text("No agent activity yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activity.entries.prefix(50)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: Self.symbol(for: entry.outcome))
                            .foregroundStyle(Self.color(for: entry.outcome))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.action.summary)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            // What the agent actually changed — a summary alone
                            // cannot tell "disabled" from "rewrote its headers".
                            if !entry.action.details.isEmpty {
                                Text(entry.action.details.joined(separator: " · "))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 6) {
                                Text(entry.date, format: .dateTime.day().month().hour().minute().second())
                                // The log is read as "what agents did", so an
                                // undo left unmarked reads as the agent having
                                // changed its mind.
                                Text(entry.byUser ? "by you" : entry.outcome.rawValue)
                                // A result ("rule #12") or a consent refusal's
                                // reason ("The user declined.") is short and
                                // stays on this line, whole in its tooltip
                                // when cut.
                                if let detail = entry.detail, entry.outcome != .failed {
                                    Text("· \(detail)")
                                        .lineLimit(1)
                                        .help(detail)
                                }
                                if entry.lateDecision {
                                    Text("· answered after the agent stopped waiting")
                                        .foregroundStyle(.orange)
                                }
                                if entry.undone { Text("· undone") }
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            // A failure's reason is the row's point, and it
                            // can be long: an undo that refused says what to
                            // do instead, and on the line after the date that
                            // instruction was cut off — whole only in the note
                            // below, for its 8 seconds. Its own line, wrapped.
                            if entry.outcome == .failed, let detail = entry.detail {
                                Text(detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        if let plan = MCPUndo.plan(for: entry) {
                            Button("Undo") { undo(entry, plan: plan) }
                                .controlSize(.small)
                                .help(MCPUndo.summary(for: plan))
                        }
                    }
                }
                if let undoNote {
                    Text(undoNote)
                        .font(.system(size: 11))
                        .foregroundStyle(undoFailed ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Export\u{2026}") { exportLog() }
                        .controlSize(.small)
                    Button("Clear Log") { activity.clearLog() }
                        .controlSize(.small)
                    if let exportNote {
                        Text(exportNote)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About MCP") {
            VStack(alignment: .leading, spacing: 8) {
                Text("MCP (Model Context Protocol) is how AI assistants talk to applications. Credential-shaped values — Authorization, Cookie, tokens — are redacted before anything leaves ReqRes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: URL(string: "https://modelcontextprotocol.io")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Learn more about MCP")
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    // MARK: - Rows

    private func statusRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func instructionRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .fontWeight(.medium)
                .frame(width: 20, alignment: .leading)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clientRow(_ name: String, note: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(name)
            Text("— \(note)")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    // MARK: - Actions

    private func addException() {
        guard exceptionField.canSubmit else { return }
        // Which refusal, and in what words, is the note's call — made again
        // on every render against the field and the list.
        let accepted = redaction.except(exceptionField.text)
        exceptionField.submitted(accepted: accepted)
    }

    /// Writes the log where the user points the save panel. Sandboxed, so the
    /// panel IS the permission — there is no path to write to without it.
    private func exportLog() {
        let panel = NSSavePanel()
        panel.title = "Export Agent Activity"
        panel.nameFieldStringValue = "reqres-agent-activity.txt"
        panel.allowedContentTypes = [.plainText, .json]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        // The file leaves the app, so it is redacted on the way out by the
        // same policy the bridge uses — a host the user excepted for agents
        // is not re-masked here, and every other host is redacted even though
        // the entries' snapshots hold the real values.
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let entries = activity.entries
        let redactor = redaction.currentRedactor
        let result = url.pathExtension.lowercased() == "json"
            ? MCPAuditExport.json(entries, redactor: redactor)
            : MCPAuditExport.text(entries, redactor: redactor)

        do {
            try Data(result.content.utf8).write(to: url, options: .atomic)
            exportNote = result.truncated
                ? "Exported the \(result.includedCount) most recent of \(result.totalCount) entries."
                : "Exported \(result.includedCount) \(result.includedCount == 1 ? "entry" : "entries")."
        } catch {
            exportNote = "Could not write the file: \(error.localizedDescription)"
        }
        let note = exportNote
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if exportNote == note { exportNote = nil }
        }
    }

    private func copy(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copied == tag { copied = nil }
        }
    }

    /// Nil when nothing has been exported, so the row stays absent rather
    /// than advertising an empty folder.
    private var exportedFileCount: Int? {
        guard let directory = try? MCPExportAdapter.exportsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              !files.isEmpty else { return nil }
        return files.count
    }

    /// Undo runs without a confirmation sheet, and it is final: the row it
    /// writes offers no undo of its own
    /// (`MCPUndoTests.testAnUndoEntryIsNotItselfOfferedAnUndo`). In place of
    /// a dialog, every button says what it will do before the click — its
    /// tooltip is `MCPUndo.summary` — and each acts only on what the agent's
    /// entry names: that rule, that host filter, that exclusion. The one that
    /// would reach past it, removing a host filter whose rules (anyone's)
    /// would go with it, refuses and says why (`MCPUndo.refusal`, F18); a
    /// removal whose filter or rule is already gone has nothing left to do
    /// and is marked done (`MCPUndo.alreadyDone`). What it did is stated
    /// afterwards too, because "recreated with a new id" is the part that
    /// surprises.
    private func undo(_ entry: MCPAuditEntry, plan: MCPUndoPlan) {
        undoNote = nil
        activity.undo(entry) { failure in
            undoFailed = failure != nil
            undoNote = failure.map { "Could not undo: \($0)" } ?? MCPUndo.summary(for: plan) + " — done."
            let note = undoNote
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if undoNote == note { undoNote = nil }
            }
        }
    }

    private func revealExports() {
        guard let directory = try? MCPExportAdapter.exportsDirectory() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func revealClaudeConfig() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    static func symbol(for outcome: MCPAuditOutcome) -> String {
        switch outcome {
        case .performed: return "checkmark.circle.fill"
        case .denied: return "hand.raised.fill"
        case .timedOut: return "clock.badge.xmark"
        case .failed: return "xmark.octagon.fill"
        }
    }

    static func color(for outcome: MCPAuditOutcome) -> Color {
        switch outcome {
        case .performed: return .green
        case .denied, .timedOut: return .orange
        case .failed: return .red
        }
    }
}

#Preview {
    MCPSettingsView()
        .frame(width: 700, height: 680)
}
