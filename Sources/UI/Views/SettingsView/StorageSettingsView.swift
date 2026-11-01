//
//  StorageSettingsView.swift
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
//  Saved sessions (1.1.0): how many there are, where they are, and the one
//  button that gets rid of them.
//
//  Its own tab, like Capture, because this is the only feature that writes
//  captured traffic to disk. Everything else ReqRes holds is in memory and
//  gone when the app quits — a user who never saves anything should be able
//  to confirm that from here, and a user who does should be able to find out
//  what that means without reading the docs.
//
//  The honesty here is deliberate, not decoration. A saved session is the
//  REAL exchange, unredacted (that is why it is useful), and it sits in a
//  file any program running as this user can open. Saying so is the price of
//  offering the feature at all.
//

import AppKit
import SwiftUI
import Utils
import XReqResCore

struct StorageSettingsView: View {
    /// `5,000`, grouped for reading, from `SessionState.maxRetainedSessions`.
    private static var retentionText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: SessionState.maxRetainedSessions))
            ?? "\(SessionState.maxRetainedSessions)"
    }

    @ObservedObject private var store = SavedSessionsStore.shared
    @State private var confirmingDeleteAll = false
    /// What the last action did, shown for a moment. Deleting everything with
    /// no acknowledgement leaves the user wondering whether the click landed.
    @State private var note: String?

    var body: some View {
        Form {
            Section("Saved sessions") {
                // The number is READ FROM THE CONSTANT that enforces it, never
                // typed out — the same rule the Breakpoints pane follows for
                // the 60-second fuse. "Dropped as new traffic arrives" without
                // a number left the one question a user actually has ("how
                // much do I have?") unanswered, and saved sessions exist
                // precisely to answer it (PRD 2026-09-22, part B).
                //
                // "in each list" is not padding: `SessionState` caps the
                // global `sessions` array at this number AND caps every
                // `sessionsByHost` bucket at it separately, so a host filter
                // can still be showing a request that All traffic has already
                // dropped. Saying "the most recent 5,000 requests" implied one
                // global bound that does not exist.
                //
                // Stated, not adjustable — a deliberate choice, with a picker
                // (1,000 / 5,000 / 20,000) noted as a later extension. If it
                // ever ships there is NO "Unlimited" option: this cap is the
                // fix for a reproduced 40-second main-thread hang at 383 MB,
                // not a tuning knob.
                Text("Captured traffic lives in memory: ReqRes keeps the most recent \(Self.retentionText) requests in each list — All traffic, and each host filter — and drops older ones as new traffic arrives. A session you save is kept on disk until you delete it — so you can come back to a request tomorrow, or hand it to an AI agent to look at. Nothing is ever saved automatically: a session is stored only when you (or an agent you approve) ask for that one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Stored") {
                    HStack(spacing: 8) {
                        Text(SavedSessionSummary.storageSentence(count: store.totalCount, byteSize: store.byteSize))
                            .foregroundStyle(.secondary)
                        if store.isLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                Button("Delete All Saved Sessions…") { confirmingDeleteAll = true }
                    .disabled(store.totalCount == 0)

                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Where it is kept") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saved sessions go into ReqRes's app group container, in the same database the app already keeps its host filters and rules in.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let location = Self.storageLocation {
                        HStack(spacing: 8) {
                            Text(Self.displayPath(of: location))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button("Show in Finder") { revealStorage(location) }
                                .controlSize(.small)
                        }
                    }
                }

                Label("That file is not a vault. It is readable by anything running as you, and it is included in any backup of your home folder — so treat a saved session the way you would treat the traffic itself.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("What a saved session contains") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("The whole exchange as it happened, with its REAL values — headers, cookies, tokens and bodies are stored unmasked. That is the point: a saved session full of «redacted» would be useless for the debugging you saved it for.")
                    bullet("Redaction still applies to anything that LEAVES ReqRes. An AI agent reading a saved session over MCP gets the same masked view it gets of live traffic, unless you have listed that host under Settings ▸ MCP ▸ Redaction.")
                    bullet("Deleting is immediate and permanent — there is no trash to recover a saved session from, and nothing is kept elsewhere.")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await store.reload() }
        .confirmationDialog(
            // The count is in the question, not just in the pane behind it:
            // this is the only irreversible button in Settings.
            store.totalCount == 1
                ? "Delete the 1 saved session?"
                : "Delete all \(store.totalCount) saved sessions?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete \(store.totalCount == 1 ? "Session" : "All")", role: .destructive, action: deleteAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are removed from disk right away. This cannot be undone.")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deleteAll() {
        Task { @MainActor in
            let deleted = await store.deleteAll()
            // Reported from what the store actually removed, not from the
            // count the button was rendered with — a row saved by an agent
            // between the click and the answer would make the two differ.
            note = deleted == 0
                ? nil
                : "Deleted \(deleted) saved \(deleted == 1 ? "session" : "sessions")."
            let shown = note
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if note == shown { note = nil }
            }
        }
    }

    private func revealStorage(_ location: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([location])
    }

    /// The database file itself, asked of the core rather than reconstructed.
    ///
    /// Deriving it from the app group identifier was a guess: `AppController`
    /// passes the GROUP id, but the app's own container was as likely a home
    /// for the file, and both paths are TCC-blocked from a shell so neither
    /// could be checked from outside. The core opened the file and knows where
    /// it is; a "Show in Finder" button that reveals a directory nobody wrote
    /// to is worse than no button.
    private static var storageLocation: URL? {
        DatabaseManager.shared.dbFileUrl ?? DatabaseManager.shared.dbFolderURL
    }

    private static func displayPath(of url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

#Preview {
    StorageSettingsView()
        .frame(width: 700, height: 620)
}
