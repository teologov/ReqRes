//
//  MCPSessionQuery.swift
//  AppServices
//
//  Created by OloApps on 8/26/26.
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

import Foundation

/// Filtering + cursor pagination over an in-memory session snapshot.
/// Sessions arrive oldest-first from the provider; pages are served newest-first
/// (the "latest requests" shape agents ask for).
public enum MCPSessionQuery {
    public static func page(
        from sessions: [MCPSessionSummary],
        filter: MCPSessionFilter = MCPSessionFilter(),
        limit: Int? = nil,
        cursor: String? = nil,
        redactor: MCPRedactor? = nil
    ) -> MCPSessionPage {
        let pageSize = min(max(limit ?? MCPLimits.defaultPageSize, 1), MCPLimits.maxPageSize)
        let matched = sessions.reversed().filter { filter.matches($0, redactor: redactor) }

        var start = 0
        if let cursor, !cursor.isEmpty {
            if let cursorIndex = matched.firstIndex(where: { $0.uid == cursor }) {
                start = cursorIndex + 1
            } else {
                // The cursor session vanished (cleared/deleted). Restarting from the
                // top is the least-wrong behavior for a live, in-memory store.
                start = 0
            }
        }

        guard start < matched.count else {
            return MCPSessionPage(sessions: [], nextCursor: nil, totalMatched: matched.count, note: nil)
        }

        let end = min(start + pageSize, matched.count)
        let slice = Array(matched[start..<end])
        let remaining = matched.count - end
        let nextCursor = remaining > 0 ? slice.last?.uid : nil
        let note = remaining > 0
            ? "\(remaining) more matching sessions — pass cursor=\(nextCursor ?? "") or refine filters."
            : nil

        return MCPSessionPage(
            sessions: slice,
            nextCursor: nextCursor,
            totalMatched: matched.count,
            note: note
        )
    }

    /// Applies the preview cap to a body string, marking truncation explicitly
    /// so an agent knows the data is incomplete rather than short.
    public static func cappedPreview(_ body: String?, maxBytes: Int = MCPLimits.bodyPreviewMaxBytes) -> (preview: String?, truncated: Bool) {
        guard let body else { return (nil, false) }
        let utf8 = body.utf8
        guard utf8.count > maxBytes else { return (body, false) }
        var slice = String(decoding: Array(utf8.prefix(maxBytes)), as: UTF8.self)
        // Trim a partially-decoded trailing replacement character if the cut split a code point.
        if slice.hasSuffix("\u{FFFD}") { slice.removeLast() }
        return (slice + MCPLimits.truncationMarker, true)
    }
}
