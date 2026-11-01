//
//  HeldRequestFraming.swift
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
//  Content-Length and Transfer-Encoding on a held request: ReqRes's to set,
//  never the decision's.
//
//  Core 5efe7aa (F19 review) stopped an edit from reframing the app's body:
//  when the app's own body follows a resumed head, the head goes up with the
//  app's own Content-Length and Transfer-Encoding whatever "Resume with
//  Changes" or a rule made of them (`GlueHandler.framingOfTheAppsBody`) — an
//  edited length had put the rest of the body on the wire raw, where the
//  origin read it as a request of its own. With a replacement body the core
//  frames it itself: Transfer-Encoding removed, Content-Length set to the
//  replacement's UTF-8 length (`BreakpointBodyFraming`). So in neither case
//  does a value typed for those two headers reach the server.
//
//  The panel and the bridge used to accept such an edit anyway: the panel
//  said "Resume with Changes" and the audit row "Headers set — Content-Length:
//  5" while the server got the app's own. Here, the header editor shows the
//  two as they arrived without offering them for editing, says what goes up
//  in their place, and refuses a row that would set one; an agent's
//  set_headers / remove_headers naming one is refused with what to do
//  instead. Refused rather than repaired, like every other check on this
//  surface: a decision quietly turned into a different one is the outcome
//  nobody asked for.
//

import Foundation

public enum HeldRequestFraming {
    /// The two names, lowercased: `Content-Length` and `Transfer-Encoding`.
    /// (`TE` is a different header, about the response, and stays editable.)
    public static let headerNames: [String] = ["content-length", "transfer-encoding"]

    /// True for Content-Length or Transfer-Encoding, matched without case and
    /// around whitespace, as HTTP compares names and the editor trims them.
    public static func isFramingHeader(_ name: String) -> Bool {
        headerNames.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    // MARK: - The panel

    /// The tooltip of a framing row, which the header editor shows as it
    /// arrived but does not let anyone edit or remove.
    public static let lockedRowHelp =
        "Set by ReqRes, not here: this header describes the body, so the app's own goes with the app's own body, "
        + "and a replacement body gets a Content-Length counted from it."

    /// The line under the header editor about these two headers — what goes
    /// up in their place — or nil when there is nothing to say (none arrived
    /// and no replacement is being sent).
    ///
    /// - Parameters:
    ///   - arrived: the request's headers as they arrived.
    ///   - replacementBody: the body Resume would send in place of the
    ///     original, or nil when the original follows.
    public static func note(arrived: [MCPHeaderPair], replacementBody: String?) -> String? {
        let present = framingNamesPresent(in: arrived)
        if let replacementBody {
            let withoutChunks = present.contains("Transfer-Encoding") ? " and no Transfer-Encoding" : ""
            return "With the replacement body, ReqRes sends Content-Length: \(replacementBody.utf8.count)\(withoutChunks)."
        }
        switch present.count {
        case 0:
            return nil
        case 1:
            return "\(present[0]) describes the body the app is sending, so it goes as the app sent it and cannot be edited here."
        default:
            return "Content-Length and Transfer-Encoding describe the body the app is sending, so they go as the app sent them "
                + "and cannot be edited here."
        }
    }

    /// Why a header row cannot be sent as it stands, or nil when it can: a
    /// row named Content-Length or Transfer-Encoding that did not arrive with
    /// the request exactly so — added, renamed to one of them, or changed.
    /// A framing row left as it arrived is fine: it goes as the app sent it,
    /// or ReqRes replaces it for a replacement body.
    ///
    /// - Parameter arrived: the row as the request carried it, or nil for a
    ///   row added in the editor.
    public static func refusal(name: String, value: String, arrived: MCPHeaderPair?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard isFramingHeader(trimmed) else { return nil }
        if let arrived, arrived.name.trimmingCharacters(in: .whitespaces) == trimmed, arrived.value == value { return nil }
        return "“\(trimmed)” cannot be set here: Content-Length and Transfer-Encoding describe the body, so ReqRes sets them — "
            + "the app's own go with the app's own body, and a replacement body gets a Content-Length counted from it."
    }

    // MARK: - The agent

    /// The 400 for `answer_paused_request` when `set_headers` or
    /// `remove_headers` names Content-Length or Transfer-Encoding, or nil.
    public static func agentRefusal(setHeaders: [String: String]?, removeHeaders: [String]?) -> String? {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        let set = (setHeaders ?? [:]).keys.filter(isFramingHeader).map(trim).sorted()
        let removed = (removeHeaders ?? []).filter(isFramingHeader).map(trim)
        guard !set.isEmpty || !removed.isEmpty else { return nil }
        var named: [String] = []
        if !set.isEmpty { named.append("set_headers names \(set.joined(separator: ", "))") }
        if !removed.isEmpty { named.append("remove_headers names \(removed.joined(separator: ", "))") }
        return named.joined(separator: " and ") + ". " + agentRule
    }

    /// What the agent is told, in the refusal and in the tool's text.
    public static let agentRule =
        "Content-Length and Transfer-Encoding are not yours to set or remove: ReqRes sends the app's own with the app's own body, "
        + "and gives a replacement `body` a Content-Length counted from it, with no Transfer-Encoding. "
        + "Leave them out of set_headers and remove_headers."

    // MARK: - Helpers

    /// "Content-Length" and/or "Transfer-Encoding", in that order, for those
    /// `headers` carry.
    static func framingNamesPresent(in headers: [MCPHeaderPair]) -> [String] {
        let names = Set(headers.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() })
        return [("content-length", "Content-Length"), ("transfer-encoding", "Transfer-Encoding")]
            .filter { names.contains($0.0) }
            .map(\.1)
    }
}
