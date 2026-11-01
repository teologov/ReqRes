//
//  MCPSavedSessionModels.swift
//  AppServices
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
//  The agent surface for sessions the user kept (1.1.0).
//
//  ReqRes is built so an agent can do what the window can. The window gained
//  a way to keep a captured exchange past the end of the run; this is the
//  same thing over MCP, under the same consent rules.
//
//  Two properties of the store shape everything here:
//
//  1. The STORED copy is the real exchange, unredacted — the user kept it to
//     debug with. So every saved session that LEAVES the bridge goes through
//     `MCPRedactor` exactly like a live one does (see `MCPBridgeRouter`).
//     Without that, saving a session and reading it back would be a way to
//     launder a credential past the read surface's redaction.
//  2. A saved session outlives the capture run, and a live `uid` does not.
//     The durable handle is the row `id`, which is why every tool here takes
//     one and only `save_session` speaks in uids at all.
//

import Foundation

// MARK: - What leaves the bridge

/// One kept session as a list row.
public struct MCPSavedSessionSummary: Codable, Equatable {
    /// The durable handle. A captured session's `uid` is gone when the run
    /// ends; this survives, so `get_saved_session` and `delete_saved_session`
    /// take this and never a uid.
    public var id: Int64
    /// When the USER kept it, which is not when it was captured — the two can
    /// be days apart and the list is ordered by this one.
    public var savedAt: Date
    public var note: String?
    public var session: MCPSessionSummary

    public init(id: Int64, savedAt: Date, note: String?, session: MCPSessionSummary) {
        self.id = id
        self.savedAt = savedAt
        self.note = note
        self.session = session
    }
}

/// One kept session in full.
public struct MCPSavedSession: Codable, Equatable {
    public var id: Int64
    public var savedAt: Date
    public var note: String?
    public var session: MCPSessionDetail

    public init(id: Int64, savedAt: Date, note: String?, session: MCPSessionDetail) {
        self.id = id
        self.savedAt = savedAt
        self.note = note
        self.session = session
    }
}

/// A page of kept sessions, newest-saved first.
public struct MCPSavedSessionPage: Codable, Equatable {
    public var saved: [MCPSavedSessionSummary]
    /// Everything stored, which can exceed what this page carries — stated so
    /// an agent that asked for 30 of 400 does not report "you have 30 saved".
    public var totalCount: Int

    public init(saved: [MCPSavedSessionSummary], totalCount: Int) {
        self.saved = saved
        self.totalCount = totalCount
    }
}

/// What an agent sends to keep a captured session.
public struct MCPSaveSessionRequest: Codable, Equatable {
    /// A uid from `list_sessions` — a session in the CURRENT run.
    public var uid: String
    /// Why it was kept, shown in the app's list beside the row.
    public var note: String?

    public init(uid: String, note: String? = nil) {
        self.uid = uid
        self.note = note
    }
}

// MARK: - Validation

public enum MCPSavedSessionValidation {
    /// A note is a label, not a report. Bounded because it is rendered in the
    /// approval panel and then persisted in the app's own list.
    public static let maxNoteLength = 280

    /// The note, normalised, or a thrown `MCPWriteError.invalid`.
    ///
    /// Line breaks are rejected rather than stripped: the approval panel
    /// renders each detail as its own line, so a note containing newlines is
    /// how a prompt-injected agent would forge extra lines into the text the
    /// human is reading to decide.
    public static func note(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maxNoteLength else {
            throw MCPWriteError.invalid("note is limited to \(maxNoteLength) characters.")
        }
        guard !MCPWriteValidation.hasLineBreak(trimmed) else {
            throw MCPWriteError.invalid("note cannot contain a line break.")
        }
        return trimmed
    }

    /// Clamped rather than rejected: an agent asking for 5,000 rows wants
    /// "all of them", and failing the call teaches it nothing a capped page
    /// plus `totalCount` does not. Shares `MCPLimits` with the live listing so
    /// there is one answer to "how much fits in a tool result".
    public static func limit(_ raw: Int?) -> Int {
        guard let raw else { return MCPLimits.defaultPageSize }
        return min(max(raw, 1), MCPLimits.maxPageSize)
    }

    /// A uid, trimmed, or a thrown error naming where to get one.
    public static func uid(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MCPWriteError.invalid("uid is required: the id of a captured session, from list_sessions.")
        }
        // The router builds no path from this, but the seam looks it up by
        // exact string and a slash would only ever be a malformed id.
        guard !trimmed.contains("/") else {
            throw MCPWriteError.invalid("uid is malformed; take one from list_sessions.")
        }
        return trimmed
    }
}

// MARK: - The seam the app implements

/// The app's saved-session store, as the bridge sees it.
///
/// Deliberately NOT given a "delete everything" method. The window has that
/// button because a human can see what they are about to lose; one agent call
/// that empties a collection the user curated is a blast radius nothing else
/// on this surface has, and no debugging task needs it.
public protocol MCPSavedSessionProviding {
    /// Newest-saved first, with the total so a partial page can say so.
    func savedSessions(limit: Int) throws -> MCPSavedSessionPage
    func savedSession(id: Int64) throws -> MCPSavedSession?
    /// Keeps the session with this uid from the current run. Throws
    /// `.notFound` when it has already aged out.
    func saveSession(uid: String, note: String?) throws -> MCPSavedSessionSummary
    func deleteSavedSession(id: Int64) throws
}
