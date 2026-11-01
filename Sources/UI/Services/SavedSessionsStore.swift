//
//  SavedSessionsStore.swift
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
//  The app's view of sessions the user kept (1.1.0).
//
//  Captured traffic lives in memory and is dropped at SessionState's 5,000 cap,
//  which is minutes of ordinary machine traffic. Saving is the deliberate
//  exception: nothing is written to disk unless a human — or an agent they
//  approved — asks for this exchange to be kept. There is NO automatic save, by
//  design, because persisting everything would change what this app is without
//  anyone opting in.
//
//  The store itself is in the closed core (`ReqResCoreModelBridge`), which owns
//  the one GRDB in this process. This type is the seam: it keeps the list the
//  UI observes on the main thread and does every database call off it, the
//  same discipline MCPWriteAdapters follows.
//

import Foundation
import Utils
import XReqResCore

@MainActor
final class SavedSessionsStore: ObservableObject {
    static let shared = SavedSessionsStore()

    /// The page the browser shows, newest-saved first.
    @Published private(set) var sessions: [SavedSessionCodable] = []
    /// Everything stored, which can exceed what is loaded.
    @Published private(set) var totalCount = 0
    /// Bytes of bodies and headers across every saved session, for the
    /// settings screen that has to say what deleting them would free.
    @Published private(set) var byteSize: Int64 = 0
    @Published private(set) var isLoading = false
    /// The last failure, for a UI that must not fail silently.
    @Published private(set) var lastError: String?

    /// How many rows the browser holds at once. A saved list is something a
    /// person curates, not a capture buffer; if anyone ever passes this the
    /// answer is paging, not a bigger number.
    static let pageSize = 500

    private init() {}

    // MARK: - Reading

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await ReqResCoreModelBridge.savedSessions(limit: Self.pageSize, offset: 0)
            let count = try await ReqResCoreModelBridge.savedSessionCount()
            let bytes = try await ReqResCoreModelBridge.savedSessionByteSize()
            sessions = page
            totalCount = count
            byteSize = bytes
            lastError = nil
        } catch {
            lastError = "Could not read saved sessions: \(error.localizedDescription)"
            AppLog.shared.error("[SavedSessions] reload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func session(id: Int64) async -> SavedSessionCodable? {
        if let cached = sessions.first(where: { $0.id == id }) { return cached }
        return try? await ReqResCoreModelBridge.savedSession(id: id)
    }

    // MARK: - Writing

    /// Keeps `session`. Returns the row id.
    ///
    /// The stored copy is the REAL exchange, not a redacted one: the user asked
    /// to keep this, and a saved session full of «redacted» would be useless
    /// for the debugging they saved it for. Redaction stays where it belongs —
    /// on anything that LEAVES the app, which includes the MCP read path.
    @discardableResult
    func save(_ session: SessionCodable, note: String? = nil) async throws -> Int64 {
        let id = try await ReqResCoreModelBridge.saveSession(session, note: note)
        await reload()
        return id
    }

    @discardableResult
    func delete(id: Int64) async -> Bool {
        do {
            let deleted = try await ReqResCoreModelBridge.deleteSavedSession(id: id)
            await reload()
            return deleted
        } catch {
            lastError = "Could not delete: \(error.localizedDescription)"
            return false
        }
    }

    /// Deletes every saved session. Returns how many went, so the caller can
    /// say what happened rather than just that something did.
    @discardableResult
    func deleteAll() async -> Int {
        do {
            let count = try await ReqResCoreModelBridge.deleteAllSavedSessions()
            await reload()
            return count
        } catch {
            lastError = "Could not delete saved sessions: \(error.localizedDescription)"
            return 0
        }
    }
}
