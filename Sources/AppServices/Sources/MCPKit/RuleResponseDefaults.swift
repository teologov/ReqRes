//
//  RuleResponseDefaults.swift
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
//  The response a rule gives without anyone choosing it — its headers and its
//  status — the shell half of F17 (live e2e plan; verified 2026-09-30).
//
//  The override form started every rule with `Content-Type: application/json;
//  charset=utf-8` and saved it in every mode. The core applies a rule's
//  response headers with `replaceOrAdd` (`RuleResponses.apply`), so:
//   - an Extend rule — the form's default mode, and the shape of Help's own
//     example, a rule that only adds a request header — relabelled every
//     response on its path as JSON: an HTML page shown as text, a stylesheet
//     or module script refused, an image labelled JSON;
//   - a Map Local rule served its file as JSON: the rule's header replaces
//     the file's own type (`RuleResponses.localAnswer`).
//  Only an Override needs a Content-Type from the rule. Its response head is
//  built from the rule's headers alone — the server's Content-Type is dropped
//  whether the rule has a body (answered locally) or not (the server's body
//  forwarded) — so without one the app gets no Content-Type at all.
//
//  So the default belongs to Override and follows the mode: a new Override
//  starts with it, a new Extend or Map Local rule starts with none, and a
//  change of mode in the form adds or drops it — never a header the user
//  typed. The form shows a Map Local rule's response headers too (they are
//  sent with its file), so every mode stores what the form shows.
//
//  The status (core 95062d1). Every form until build 53 also started a rule
//  at 200 and the core answered with it, so the same header-only Extend rule
//  turned every 404 and 500 on its path into a 200. The core now reads a
//  stored status of 0 as "keep the server's" — and any other value outside
//  200…599 the same where the request is forwarded, as 200 where ReqRes
//  answers itself (`RuleResponses.ruleStatus`) — and never uses a Map Local
//  rule's status: a readable file answers 200, a missing one forwards the
//  server's response unchanged. Its one-time migration (`RuleFormDefaults`)
//  turned the form's untouched Extend rules that set a request header into
//  keep, with no response header. So the status follows the mode too:
//   - Extend starts at "Keep server's status" (stored 0), and may name one;
//   - Override answers with its own status (200 to start) and never keeps
//     the server's. With a body it answers itself and must have one; without
//     a body it forwards, and the core would keep the server's for a 0 — but
//     offering that would make a stored status mean one thing until a body
//     is added (in the form, or by update_rule) and another after it, and an
//     override that keeps the server's status and body while dropping every
//     server header is nothing the product describes. Keeping is Extend's;
//   - Map Local shows no status and stores 0, what its missing file does.
//


import Foundation

/// A response header as a rule editor holds it. The override form's
/// `HeaderEntry` conforms (the app target), so the form's decisions are these
/// functions, tested here, rather than view code no test can reach.
public protocol RuleHeaderEntry {
    var ruleHeaderName: String { get }
    var ruleHeaderValue: String { get }
    var ruleHeaderIsEnabled: Bool { get }
    /// A new, enabled header.
    static func ruleHeader(name: String, value: String) -> Self
}

/// A rule's status as the form and the agent tools choose it: the server's,
/// kept, or one the rule answers with.
public enum RuleStatus: Hashable, Sendable {
    /// Keep the server's status — stored as
    /// `RuleResponseDefaults.keepServerStatus` (0).
    case keep
    /// Answer with this final status (`RuleResponseDefaults.answeringStatuses`).
    case code(Int)

    /// The `rspCode` this is stored as.
    public var stored: Int {
        switch self {
        case .keep: return RuleResponseDefaults.keepServerStatus
        case .code(let code): return code
        }
    }
}

/// One section of the override form's Status menu.
public struct RuleStatusMenuGroup: Hashable, Sendable {
    /// The section's heading; nil for the "Keep server's status" section.
    public let title: String?
    public let statuses: [RuleStatus]

    public init(title: String?, statuses: [RuleStatus]) {
        self.title = title
        self.statuses = statuses
    }
}

public enum RuleResponseDefaults {
    public static let contentTypeName = "Content-Type"
    /// What an Override answers with when nobody named a type: the form's
    /// long-standing default, and what its body editor highlights as JSON.
    public static let contentTypeValue = "application/json; charset=utf-8"

    /// Whether a rule in `mode` carries a Content-Type nobody chose.
    ///
    /// - Override: yes — its response carries the rule's headers only.
    /// - Extend: no — the server's own Content-Type describes the server's
    ///   bytes; a rule's would relabel every response on the path (F17).
    /// - Map Local: no — the file's type is sent; a rule's would replace it.
    public static func addsContentType(_ mode: MCPRuleMode) -> Bool {
        mode == .override
    }

    // MARK: - The override form

    /// The response headers a new rule in `mode` starts with.
    public static func headers<Header: RuleHeaderEntry>(forNewRuleIn mode: MCPRuleMode) -> [Header] {
        addsContentType(mode) ? [defaultHeader()] : []
    }

    /// The form's headers after its mode changes from `old` to `new`: the
    /// default Content-Type follows the new mode — added when it is an
    /// Override that names no Content-Type, dropped (`isDefault`) when it is
    /// not — and every other header stays as the user left it, a Content-Type
    /// they typed included.
    ///
    /// Dropped between Extend and Map Local too: a rule saved by an earlier
    /// form carries the default in every mode, and neither mode wants it.
    public static func headers<Header: RuleHeaderEntry>(
        _ headers: [Header], changingModeFrom old: MCPRuleMode, to new: MCPRuleMode
    ) -> [Header] {
        guard old != new else { return headers }
        guard addsContentType(new) else { return headers.filter { !isDefault($0) } }
        return namesContentType(headers) ? headers : headers + [defaultHeader()]
    }

    /// The form's mode change, whole: the headers and the status follow the
    /// new mode (`headers(_:changingModeFrom:to:)`,
    /// `status(_:changingModeFrom:to:)`), then `mode` becomes `newMode`.
    ///
    /// One call for all three because the ORDER is the decision: the old mode
    /// has to be read before it is written, or every change is a change from
    /// the new mode to itself and no default is ever added or dropped.
    /// Generic over the form's own mode type; `ruleMode` maps it.
    public static func changeMode<Mode: Equatable, Header: RuleHeaderEntry>(
        _ mode: inout Mode, headers: inout [Header], status: inout RuleStatus, to newMode: Mode,
        as ruleMode: (Mode) -> MCPRuleMode
    ) {
        guard newMode != mode else { return }
        headers = self.headers(headers, changingModeFrom: ruleMode(mode), to: ruleMode(newMode))
        status = self.status(status, changingModeFrom: ruleMode(mode), to: ruleMode(newMode))
        mode = newMode
    }

    /// The headers the form shows for a rule stored with `stored` in `mode`,
    /// which is what it saves back.
    ///
    /// A Map Local rule's untouched default is left out: the form hid a Map
    /// Local rule's headers until now, so nobody chose it there, and it only
    /// ever replaced the file's own type (F17) — opening the rule and saving
    /// it drops it. Everything else is shown as stored: another header on a
    /// Map Local rule (an agent's, or one typed before a change of mode) is
    /// sent with the file, and an Extend or Override rule's headers are the
    /// ones its Headers row always showed.
    public static func headers<Header: RuleHeaderEntry>(seeding stored: [Header], mode: MCPRuleMode) -> [Header] {
        mode == .mapLocal ? stored.filter { !isDefault($0) } : stored
    }

    /// The default exactly as the form adds it: enabled, named Content-Type,
    /// holding `contentTypeValue`. A Content-Type with any other value is the
    /// user's (or an agent's) and is never taken away.
    public static func isDefault<Header: RuleHeaderEntry>(_ header: Header) -> Bool {
        header.ruleHeaderIsEnabled
            && isContentType(header.ruleHeaderName)
            && header.ruleHeaderValue.trimmingCharacters(in: .whitespaces) == contentTypeValue
    }

    /// Whether an enabled header names the Content-Type. A switched-off one
    /// does not count: the core applies enabled headers only.
    public static func namesContentType<Header: RuleHeaderEntry>(_ headers: [Header]) -> Bool {
        headers.contains { $0.ruleHeaderIsEnabled && isContentType($0.ruleHeaderName) }
    }

    // MARK: - The status

    /// What the core stores for "keep the server's status"
    /// (`RuleResponses.keepServerStatus`).
    public static let keepServerStatus = 0
    /// The statuses a rule answers with (`RuleResponses.ruleStatus`). The
    /// core reads any other stored value — 0, an interim 1xx, a value that
    /// did not parse — as "keep the server's" where the request is forwarded,
    /// and as 200 where ReqRes answers itself.
    public static let answeringStatuses = 200...599
    /// What the form's Status menu calls `.keep`.
    public static let keepServerStatusTitle = "Keep server's status"

    /// Whether a rule in `mode` uses a status at all. A Map Local rule's is
    /// never used: a file ReqRes can read answers 200, and a missing one
    /// forwards the server's response unchanged. The form shows it none.
    public static func usesStatus(_ mode: MCPRuleMode) -> Bool {
        mode != .mapLocal
    }

    /// Whether a rule in `mode` may keep the server's status.
    ///
    /// - Extend: yes — it forwards and rewrites the real response, and the
    ///   server's status is what it starts with.
    /// - Override: no — it answers with its own (see the file's header for
    ///   why an override without a body, which the core would let keep, is
    ///   not offered it).
    /// - Map Local: its status is not used; 0 is what it stores, and what its
    ///   missing file does.
    public static func canKeepServerStatus(_ mode: MCPRuleMode) -> Bool {
        mode != .override
    }

    /// The status a new rule in `mode` starts with — in the form, and in
    /// `create_rule` when the agent names none: keep the server's for Extend
    /// (and Map Local, which does not use it), 200 for an Override. Agents get
    /// it in two more places a rule has no status of its own to carry: a
    /// map_local rule `update_rule` makes extend or override without one, and
    /// a map_local mock (`mock_from_session`) that names none.
    public static func status(forNewRuleIn mode: MCPRuleMode) -> RuleStatus {
        mode == .override ? .code(200) : .keep
    }

    /// The status the form opens a rule stored with `stored` in `mode` with —
    /// what the core does with it, so opening and saving a rule changes
    /// nothing it does:
    /// - a final status (200…599) is itself — a 302 that `mock_from_session`
    ///   copied included (the old form opened every code its menus did not
    ///   list as 400, and saved that);
    /// - on an Extend rule anything else is "keep": 0, which the core's
    ///   migration gave the form's untouched Extend rules (build 52's form
    ///   opened it as 400), and a 1xx, which the core keeps too;
    /// - on an Override it is 200: what an override with a body answers
    ///   with for it. Only an agent of build 52 could store one (a 1xx);
    /// - a Map Local rule's is not used and not shown: "keep", stored 0.
    public static func status(seeding stored: Int, mode: MCPRuleMode) -> RuleStatus {
        guard usesStatus(mode) else { return .keep }
        if answeringStatuses.contains(stored) { return .code(stored) }
        return canKeepServerStatus(mode) ? .keep : status(forNewRuleIn: mode)
    }

    /// The `rspCode` the form saves for `status` in `mode`: what it shows.
    /// A Map Local rule shows none and stores 0; an Override never shows
    /// "keep", and would store its own default for it.
    public static func storedStatus(_ status: RuleStatus, mode: MCPRuleMode) -> Int {
        guard usesStatus(mode) else { return keepServerStatus }
        if status == .keep, !canKeepServerStatus(mode) { return self.status(forNewRuleIn: mode).stored }
        return status.stored
    }

    /// The form's status after its mode changes from `old` to `new`: the
    /// default follows the mode, as the Content-Type does — a status that is
    /// the old mode's default becomes the new mode's — and any other status
    /// stays.
    ///
    /// So an Override's untouched 200 never rides onto an Extend rule (F17:
    /// every response on its path answered 200), whether the click goes
    /// there directly or through Map Local, whose hidden status is "keep";
    /// and a status somebody chose (a 404, a 500) stays through a change of
    /// mode, Map Local included. A 200 chosen on an Extend rule and taken
    /// through Override comes back as "keep": on an Override it is the
    /// default, and the menu shows the change before anything is saved.
    /// "Keep" never reaches an Override: it is the default of every mode
    /// that has it, so it becomes the Override's 200.
    public static func status(_ status: RuleStatus, changingModeFrom old: MCPRuleMode, to new: MCPRuleMode) -> RuleStatus {
        guard old != new else { return status }
        return status == self.status(forNewRuleIn: old) ? self.status(forNewRuleIn: new) : status
    }

    /// The form's Status menu for a rule in `mode` whose status is `current`:
    /// "Keep server's status" alone at the top where the mode can keep it
    /// (Extend), then the final statuses by class — the `listed` codes the
    /// menu always offers, plus `current` and the status the rule `opened`
    /// with (`status(seeding:mode:)`) when the list lacks them, so a rule
    /// with a 302 opens showing its 302, saves it back, and still offers it
    /// after another is picked, as the Method menu keeps a stored method it
    /// does not list. Map Local: none.
    public static func statusMenu(
        for mode: MCPRuleMode, listing listed: [Int], current: RuleStatus, opened: RuleStatus? = nil
    ) -> [RuleStatusMenuGroup] {
        guard usesStatus(mode) else { return [] }
        var groups: [RuleStatusMenuGroup] = []
        if canKeepServerStatus(mode) {
            groups.append(RuleStatusMenuGroup(title: nil, statuses: [.keep]))
        }
        var codes = Set(listed.filter(answeringStatuses.contains))
        for case .code(let code)? in [current, opened] where answeringStatuses.contains(code) { codes.insert(code) }
        let classes: [(title: String, range: ClosedRange<Int>)] = [
            ("Success", 200...299), ("Redirection", 300...399), ("Client error", 400...499), ("Server error", 500...599),
        ]
        for (title, range) in classes {
            let inClass = codes.filter(range.contains).sorted()
            if !inClass.isEmpty {
                groups.append(RuleStatusMenuGroup(title: title, statuses: inClass.map(RuleStatus.code)))
            }
        }
        return groups
    }

    /// How a rule's stored status reads for an agent or in an approval panel:
    /// what the response gets, as the core decides it — "404", or "server's
    /// status" where the server's is kept, never a "0". nil for Map Local,
    /// which does not use it.
    ///
    /// An Override stored with something other than a final status (only an
    /// agent of build 52 could) answers 200 with a body, and forwards the
    /// server's status without one (`RuleResponses.ruleStatus`).
    public static func statusText(_ stored: Int, mode: MCPRuleMode, hasBody: Bool) -> String? {
        guard usesStatus(mode) else { return nil }
        if answeringStatuses.contains(stored) { return "\(stored)" }
        if mode == .override, hasBody { return "200" }
        return "server's status"
    }

    // MARK: - Agents

    /// The response headers `create_rule` stores: what the agent sent, and —
    /// for an Override whose headers name no Content-Type — the form's default
    /// added, so an agent's rule is the one a person would have made in the
    /// form, and its answer is never left without a type. Nothing is added
    /// for Extend or Map Local (`addsContentType`).
    ///
    /// The default does not depend on the body, as in the form: an agent
    /// answering with HTML or text names its own Content-Type (the tool text
    /// says so, and the approval panel lists the one the rule will carry).
    ///
    /// For NEW rules only. `update_rule` stores what it is sent, and keeps
    /// what is stored when it is sent none; `mock_from_session` copies the
    /// capture's headers, Content-Type or not; an undo puts back exactly what
    /// was there.
    public static func headers(forNewRule headers: [String: String], mode: MCPRuleMode) -> [String: String] {
        guard addsContentType(mode), !headers.keys.contains(where: isContentType) else { return headers }
        var result = headers
        result[contentTypeName] = contentTypeValue
        return result
    }

    // MARK: - Pieces

    private static func defaultHeader<Header: RuleHeaderEntry>() -> Header {
        Header.ruleHeader(name: contentTypeName, value: contentTypeValue)
    }

    private static func isContentType(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(contentTypeName) == .orderedSame
    }
}
