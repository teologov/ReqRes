//
//  MCPSavedSessionAdapter.swift
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
//  The app side of the saved-session seam (1.1.0).
//
//  Reads go straight to the core's store and writes go through
//  `SavedSessionsStore`. That split is deliberate, and it is the same one
//  `MCPHostAdapter` makes:
//
//  - A READ through the store would return whatever the window last loaded.
//    `SavedSessionsStore` is populated by the UI calling `reload()`, so on a
//    launch where nobody has opened the saved list yet its array is empty —
//    an agent would be told "nothing is saved" while the database holds rows.
//  - A WRITE has to go through the store, because that is what refreshes the
//    list the user is looking at. An agent's save must appear in their window
//    like their own does, not after the next reload.
//
//  Like the other write adapters, every method here runs on the bridge's
//  queue and blocks on async work — never call them from the main thread.
//

import Foundation
import MCPKit
import XReqResCore

struct MCPSavedSessionAdapter: MCPSavedSessionProviding {

    // MARK: - Reading

    func savedSessions(limit: Int) throws -> MCPSavedSessionPage {
        do {
            let rows = try MCPSync.wait { try await ReqResCoreModelBridge.savedSessions(limit: limit, offset: 0) }
            let total = try MCPSync.wait { try await ReqResCoreModelBridge.savedSessionCount() }
            return MCPSavedSessionPage(saved: rows.map(Self.summary), totalCount: total)
        } catch {
            throw MCPWriteError.failed("Could not read saved sessions: \(error.localizedDescription)")
        }
    }

    func savedSession(id: Int64) throws -> MCPSavedSession? {
        do {
            return try MCPSync.wait { try await ReqResCoreModelBridge.savedSession(id: id) }.map(Self.saved)
        } catch {
            throw MCPWriteError.failed("Could not read saved session #\(id): \(error.localizedDescription)")
        }
    }

    // MARK: - Writing

    /// No free-tier gate: the free tier meters host filters and rules, and the
    /// window's own save has no limit. An agent must not be stricter — or
    /// laxer — than the button sitting next to it.
    func saveSession(uid: String, note: String?) throws -> MCPSavedSessionSummary {
        guard let sessionId = UUID(uuidString: uid) else {
            throw MCPWriteError.invalid("uid is malformed; take one from list_sessions.")
        }
        // The live run is `@Published` state owned by the main thread.
        guard let session = MCPSync.onMain({ SessionState.shared.sessions.first { $0.id == sessionId } }) else {
            throw MCPWriteError.notFound("Session \(uid) is no longer in the current capture run.")
        }
        // A live row — in flight, or ended without its final row — is a
        // snapshot with part of a request body and no response: saving it
        // would keep half an exchange as if it were the whole, and a saved
        // row has no live state left to withhold its bodies by.
        if let refusal = LiveRowKeeping.refusal(
            uid: uid,
            live: MCPSync.onMain({ SessionState.shared.agentLiveState(for: session) }),
            purpose: "save it"
        ) {
            throw MCPWriteError.invalid(refusal)
        }
        let id: Int64
        do {
            id = try MCPSync.wait { try await SavedSessionsStore.shared.save(session, note: note) }
        } catch {
            throw MCPWriteError.failed("Could not save the session: \(error.localizedDescription)")
        }
        // Read back rather than synthesising the row: `savedAt` is the store's
        // to decide, and a timestamp invented here would be the one the agent
        // reports while the user's window shows another.
        guard let stored = try savedSession(id: id) else {
            throw MCPWriteError.failed("The session was saved as #\(id) but could not be read back.")
        }
        return MCPSavedSessionSummary(id: stored.id, savedAt: stored.savedAt, note: stored.note, session: stored.session.summary)
    }

    func deleteSavedSession(id: Int64) throws {
        // Through the store, so the saved list the user may be looking at
        // loses the row at the same moment the agent is told it is gone.
        let outcome = try MCPSync.wait { () -> (deleted: Bool, reason: String?) in
            let deleted = await SavedSessionsStore.shared.delete(id: id)
            return (deleted, await SavedSessionsStore.shared.lastError)
        }
        guard outcome.deleted else {
            // The router has already established the row existed, so a false
            // here is a failure, not a 404 — and the store kept the reason.
            throw MCPWriteError.failed(outcome.reason ?? "Could not delete saved session #\(id).")
        }
    }

    // MARK: - Core model → bridge model

    static func summary(_ saved: SavedSessionCodable) -> MCPSavedSessionSummary {
        MCPSavedSessionSummary(
            id: saved.id,
            savedAt: saved.savedAt,
            note: saved.note,
            session: MCPSessionAdapter.summary(from: saved.session)
        )
    }

    static func saved(_ saved: SavedSessionCodable) -> MCPSavedSession {
        MCPSavedSession(
            id: saved.id,
            savedAt: saved.savedAt,
            note: saved.note,
            session: detail(from: saved.session)
        )
    }

    /// The same mapping a live session gets (`MCPSessionAdapter.detail(from:)`)
    /// — one function, so an agent cannot tell a saved session from a live
    /// one by its shape. This used to be a hand-kept copy, and it had already
    /// drifted (no server address) before the 1.1.0 fields arrived.
    static func detail(from session: SessionCodable) -> MCPSessionDetail {
        MCPSessionAdapter.detail(from: session)
    }
}
