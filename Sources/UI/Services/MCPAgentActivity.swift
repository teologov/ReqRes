//
//  MCPAgentActivity.swift
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
//  The human side of the MCP write surface: the approval request the app
//  shows, the standing grants, and the activity log.
//
//  Consent model: HYBRID. By default every agent write waits for the human —
//  Allow / Allow for this session / Deny. A Settings toggle ("Let agents change
//  rules and hosts without asking") makes writes immediate. Either way every
//  action lands in the log below.
//
//  Two rules hold the design together:
//   * the DECISION is made on the main thread, always; the bridge thread only
//     waits. A click and an expiry that raced would otherwise both "win" — the
//     user seeing their Allow accepted while the agent is told nobody
//     answered, and the write happening anyway.
//   * the standing grant is an in-memory flag, seeded from defaults at LAUNCH
//     and changed only through Settings. Consulting `UserDefaults` per request
//     would let an agent with a shell tool grant itself permission
//     (`defaults write …`) and never show a panel again.
//

import AppKit
import Combine
import Foundation
import MCPKit
import SwiftUI

final class MCPAgentActivity: ObservableObject {
    static let shared = MCPAgentActivity()

    /// Persisted for display and for the next launch; never consulted per
    /// request — see the header.
    static let writesWithoutAskingKey = "MCPAgentWritesWithoutAsking"
    private static let logKey = "MCPAgentActivityLog"
    private static let maxEntries = 200
    /// How long the human has before the agent is told nobody answered.
    static var approvalTimeout: TimeInterval { MCPLimits.consentTimeout }

    /// An agent action waiting for the human's answer.
    struct PendingApproval: Identifiable {
        let id = UUID()
        let action: MCPAgentAction
        /// When it expires, so the panel can say so.
        let expiresAt: Date
        fileprivate let resolve: (MCPConsentDecision) -> Void
    }

    /// What the panel shows: every request that arrived together, answered
    /// once. An agent turn is usually several writes (add a host, create the
    /// rule, start capture) and one panel per write was unusable.
    struct PendingApprovalGroup: Identifiable {
        let id = UUID()
        var approvals: [PendingApproval]

        var actions: [MCPAgentAction] { approvals.map(\.action) }
        var expiresAt: Date { approvals.map(\.expiresAt).min() ?? Date() }
    }

    /// How long a panel waits for more of the same burst before appearing.
    /// Long enough to collect an agent's parallel tool calls, short enough
    /// that a single change still feels immediate.
    private static let coalesceWindow: TimeInterval = 0.6

    enum Decision {
        case allow
        case allowForSession
        case deny
    }

    /// The batch the human is looking at. Shown in its own floating panel
    /// (`MCPApprovalWindowController`), never as a sheet on the main window.
    @Published private(set) var pending: PendingApprovalGroup? {
        didSet {
            MainActor.assumeIsolated {
                if let pending {
                    MCPApprovalWindowController.shared.show(pending)
                } else {
                    MCPApprovalWindowController.shared.hide()
                }
            }
        }
    }

    @Published private(set) var entries: [MCPAuditEntry] = []
    /// "Allow for this session": cleared when the app quits.
    @Published private(set) var sessionGrant = false
    /// Mirrors the persisted setting, for the Settings toggle.
    @Published private(set) var writesWithoutAsking: Bool

    /// Arrived, not yet shown: the current burst.
    private var queued: [PendingApproval] = []
    private var presentationScheduled = false

    #if DEBUG
    private static var sheetProbed = false
    #endif

    private init() {
        writesWithoutAsking = UserDefaults.standard.bool(forKey: Self.writesWithoutAskingKey)
        entries = Self.loadLog()
    }

    // MARK: - Grants (main thread)

    func setWritesWithoutAsking(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        writesWithoutAsking = enabled
        UserDefaults.standard.set(enabled, forKey: Self.writesWithoutAskingKey)
        if !enabled { sessionGrant = false }
    }

    func revokeSessionGrant() {
        DispatchQueue.main.async { self.sessionGrant = false }
    }

    // MARK: - Consent (called on a bridge connection queue, never on main)

    /// Blocks the caller until the human answers or the request expires.
    func authorize(_ action: MCPAgentAction) -> MCPConsentDecision {
        precondition(!Thread.isMainThread, "consent must not block the main thread")
        let semaphore = DispatchSemaphore(value: 0)
        let box = DecisionBox()
        let approval = PendingApproval(
            action: action,
            expiresAt: Date().addingTimeInterval(Self.approvalTimeout)
        ) { decision in
            box.value = decision
            semaphore.signal()
        }

        DispatchQueue.main.async { self.enqueue(approval) }

        if semaphore.wait(timeout: .now() + Self.approvalTimeout + 1) == .timedOut {
            // Expire on MAIN, so a click already in flight wins the race
            // instead of being silently dropped.
            DispatchQueue.main.sync { self.expire(approval.id) }
            semaphore.wait()
        }
        return box.value ?? .timedOut(reason: Self.timeoutReason)
    }

    /// Cancels everything waiting — the Settings kill switch.
    func cancelAll(reason: String) {
        precondition(Thread.isMainThread)
        let waiting = (pending?.approvals ?? []) + queued
        pending = nil
        queued = []
        for approval in waiting {
            approval.resolve(.denied(reason: reason))
        }
    }

    private static var timeoutReason: String {
        "Nobody answered the ReqRes approval panel within \(Int(approvalTimeout)) seconds."
    }

    // MARK: - Queue (main thread only)

    private func enqueue(_ approval: PendingApproval) {
        // Grants are checked HERE, on main, so "Allow for this session" also
        // covers requests that arrived while the panel was up.
        if grantCovers(approval) {
            approval.resolve(.allowed)
            return
        }
        queued.append(approval)
        schedulePresentation()
    }

    /// Whether a standing grant may answer for this one instead of the human.
    ///
    /// Two conditions, and the second is the one that matters: the user has
    /// granted something, AND the action is of a weight a grant is allowed to
    /// cover. `replay_request` is not — "let agents change rules and hosts
    /// without asking" is a statement about this app, and must not silently
    /// become "and send captured requests back out to other people's
    /// servers". The rule itself lives in MCPKit
    /// (`Severity.canBeCoveredByStandingGrant`) so it is tested, and so a new
    /// action of that weight inherits it rather than having to remember.
    private func grantCovers(_ approval: PendingApproval) -> Bool {
        (writesWithoutAsking || sessionGrant)
            && approval.action.canBeCoveredByStandingGrant
    }

    /// Resolves everything the standing grant covers and hands back what
    /// still needs a human. A burst is not all-or-nothing: an agent turn that
    /// adds a host AND replays a request under a standing grant lets the host
    /// through and still puts the replay in front of the user.
    private func drainGranted(_ approvals: [PendingApproval]) -> [PendingApproval] {
        var remaining: [PendingApproval] = []
        for approval in approvals {
            if grantCovers(approval) {
                approval.resolve(.allowed)
            } else {
                remaining.append(approval)
            }
        }
        return remaining
    }

    /// Collects the burst, then shows it as ONE panel.
    private func schedulePresentation() {
        guard pending == nil, !queued.isEmpty, !presentationScheduled else { return }
        presentationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceWindow) { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            self.present()
        }
    }

    private func present() {
        guard pending == nil, !queued.isEmpty else { return }
        // A grant may have arrived while the burst was collecting — it
        // releases what it covers and leaves the rest to be shown.
        queued = drainGranted(queued)
        guard !queued.isEmpty else { return }
        let group = PendingApprovalGroup(approvals: queued)
        queued = []
        pending = group
        debugAutoAnswerIfRequested(group)
    }

    private func expire(_ id: UUID) {
        if let group = pending, let approval = group.approvals.first(where: { $0.id == id }) {
            // One expiry ends the whole batch: they were shown together, and
            // the rest are within a second of expiring anyway.
            pending = nil
            group.approvals.forEach { $0.resolve(.timedOut(reason: Self.timeoutReason)) }
            _ = approval
            presentNext()
        } else if let index = queued.firstIndex(where: { $0.id == id }) {
            let dropped = queued.remove(at: index)
            dropped.resolve(.timedOut(reason: Self.timeoutReason))
        }
        // Otherwise it was already resolved and its own callback signalled.
    }

    /// The panel's buttons land here (main thread) and answer the WHOLE batch.
    func resolve(_ decision: Decision) {
        precondition(Thread.isMainThread)
        guard let group = pending else { return }
        pending = nil
        switch decision {
        case .allow:
            group.approvals.forEach { $0.resolve(.allowed) }
        case .allowForSession:
            // The grant covers what a grant may cover from here on; THIS
            // batch is allowed outright, replay included, because the user is
            // looking at it. The next replay asks again.
            sessionGrant = true
            group.approvals.forEach { $0.resolve(.allowed) }
        case .deny:
            group.approvals.forEach { $0.resolve(.denied(reason: "The user declined.")) }
        }
        presentNext()
    }

    /// Anything that arrived while the panel was up either rides a new
    /// standing grant or becomes the next panel.
    private func presentNext() {
        guard !queued.isEmpty else { return }
        queued = drainGranted(queued)
        guard !queued.isEmpty else { return }
        present()
    }

    private func debugAutoAnswerIfRequested(_ group: PendingApprovalGroup) {
        #if DEBUG
        // `REQRES_MCP_AUTO_CONSENT=allow|deny`: the headless checks answer for
        // the human. The panel is NOT left on screen for them — these runs
        // happen on a real desktop.
        guard let auto = ProcessInfo.processInfo.environment["REQRES_MCP_AUTO_CONSENT"] else { return }
        print("[mcp] approval panel: \(group.actions.count) change(s)")
        for action in group.actions {
            print("[mcp]   · \(action.summary)")
        }
        fflush(stdout)
        let wantsPNG = ProcessInfo.processInfo.environment["REQRES_MCP_PROBE_PNG"] != nil
        if !wantsPNG { MainActor.assumeIsolated { MCPApprovalWindowController.shared.hide() } }
        if wantsPNG, !Self.sheetProbed {
            Self.sheetProbed = true
            // The live panel does not rasterise through `cacheDisplay` (SwiftUI
            // content, RenderBox) — render the same view in a plain hosted
            // window instead. Its SIZE is the useful signal: it must be
            // `MCPApprovalWindowController.width` wide and grow with the batch.
            MainActor.assumeIsolated {
                let hosting = NSHostingView(rootView: MCPApprovalSheet(group: group))
                hosting.frame = NSRect(x: 0, y: 0, width: MCPApprovalWindowController.width, height: 600)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = hosting
                window.orderBack(nil)
                hosting.layoutSubtreeIfNeeded()
                let size = NSSize(width: MCPApprovalWindowController.width, height: hosting.fittingSize.height)
                hosting.frame = NSRect(origin: .zero, size: size)
                window.setContentSize(size)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                        hosting.cacheDisplay(in: hosting.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            print("<<<PNG approval-sheet\n\(png.base64EncodedString())\nPNG>>>")
                            fflush(stdout)
                        }
                    }
                    window.orderOut(nil)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wantsPNG ? 2.0 : 0.05)) {
            guard self.pending?.id == group.id else { return }
            self.resolve(auto == "allow" ? .allow : .deny)
        }
        #endif
    }

    // MARK: - Audit log

    func record(_ entry: MCPAuditEntry) {
        DispatchQueue.main.async {
            self.insert(entry)
            Self.saveLog(self.entries)
        }
    }

    /// Main thread only — `entries` is `@Published`. Split out of `record` so
    /// the undo below can add its entry and mark the original in ONE main-
    /// thread block: through `record`'s async hop the two land in separate
    /// turns, and anything reading the log in between sees a change that is
    /// half applied.
    private func insert(_ entry: MCPAuditEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    func clearLog() {
        entries = []
        Self.saveLog(entries)
    }

    // MARK: - Undo

    /// Reverses one logged change, on the user's click.
    ///
    /// No consent: consent puts a human between an AGENT and a change, and
    /// this IS the human, in ReqRes's own window. It is also why undo is not
    /// a bridge route — see MCPUndo. The work runs off the main thread
    /// because the adapters block on the core through `MCPSync`.
    ///
    /// `completion` receives nil on success or a message to show. The entry
    /// is marked undone only when the write actually happened, so a failure
    /// — or a refusal (`MCPUndo.refusal`) — leaves the button there to try
    /// again.
    func undo(_ entry: MCPAuditEntry, completion: @escaping (String?) -> Void = { _ in }) {
        guard let plan = MCPUndo.plan(for: entry) else {
            return completion("There is nothing recorded to put back for this change.")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let rules = MCPRuleAdapter()
            let hosts = MCPHostAdapter()
            var detail: String?
            var failure: String?
            do {
                switch plan {
                case .restoreRule(let rule):
                    let restored = try rules.updateRule(id: rule.id, patch: MCPUndo.patch(restoring: rule))
                    detail = "rule #\(restored.id)"
                case .recreateRule(let rule):
                    let created = try rules.createRule(MCPUndo.draft(recreating: rule))
                    detail = "rule #\(created.id) (was #\(rule.id))"
                case .deleteRule(let id):
                    try rules.deleteRule(id: id)
                    detail = "rule #\(id) deleted"
                case .restoreHost(let host):
                    let added = try hosts.addHost(MCPUndo.draft(restoring: host))
                    detail = "host #\(added.id) \(added.host)"
                case .removeHost(let id):
                    // Counted HERE, not in `MCPHostAdapter.removeHost`: that
                    // also serves the agent's remove_host, which is meant to
                    // take the rules and says so on its approval panel. An
                    // undo takes back the agent's filter and nothing else
                    // (F18); a refusal leaves the entry un-undone and logs why,
                    // naming the filter as the sidebar shows it. A filter that
                    // is gone already has no rules, and removing it throws
                    // not-found, handled below.
                    let name = try hosts.hosts().first { $0.id == id }?.host
                    let onHost = try rules.rules().filter { $0.hostId == id }.count
                    if let refusal = MCPUndo.refusal(for: plan, rulesOnHost: onHost, hostName: name) {
                        failure = refusal
                    } else {
                        try hosts.removeHost(id: id)
                        detail = name.map { "host #\(id) \($0) removed" } ?? "host #\(id) removed"
                    }
                case .removeExclusion(let host):
                    // Only that entry: anything the user changed on the list
                    // since the agent added it stays as they left it.
                    try MCPExclusionAdapter().include(host)
                    detail = "\(host) is recorded again"
                }
            } catch let error as MCPWriteError {
                // A removal whose target is already gone — a filter deleted
                // in the sidebar, as a refusal above advises, a rule deleted
                // in the Override list or with its filter, either by an agent
                // — has nothing left to do, and the entry is marked undone so
                // its button stops offering it (`MCPUndo.alreadyDone`). Any
                // other not-found is a failure: what was to be put back is gone.
                if case .notFound = error, let done = MCPUndo.alreadyDone(plan) {
                    detail = done
                } else {
                    failure = error.message
                }
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                if failure == nil, let index = self.entries.firstIndex(where: { $0.id == entry.id }) {
                    self.entries[index].undone = true
                }
                // Kept as every other entry is kept (`redactLogEntry`, what
                // the router records with): the undo's summary quotes the
                // rule's REAL path from the snapshot — "Put rule #3 back as it
                // was (override /get?access_token=…)" — and this row is saved
                // to UserDefaults and exported like the rest.
                let undone = MCPUndo.entry(for: plan, outcome: failure == nil ? .performed : .failed, detail: failure ?? detail)
                self.insert(MCPRedactionSettings.shared.currentRedactor.redactLogEntry(undone))
                Self.saveLog(self.entries)
                completion(failure)
            }
        }
    }

    private static func loadLog() -> [MCPAuditEntry] {
        guard let data = UserDefaults.standard.data(forKey: logKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = (try? decoder.decode([MCPAuditEntry].self, from: data)) ?? []
        // Every entry gets the treatment a new one gets when it is recorded,
        // whichever build wrote it: build 51 kept an answered held request's
        // URL raw in the result line (F15), token and all, where this list
        // showed it and Export… wrote it to a file. Applied at every launch
        // because a second pass changes nothing; written back only when this
        // one did.
        let redactor = MCPRedactionSettings.shared.currentRedactor
        let cleaned = stored.map(redactor.redactLogEntry)
        if cleaned != stored { saveLog(cleaned) }
        return cleaned
    }

    private static func saveLog(_ entries: [MCPAuditEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(entries.prefix(100))) {
            UserDefaults.standard.set(data, forKey: logKey)
        }
    }
}

/// Carries the decision from the main thread to the waiting bridge thread;
/// the semaphore is the happens-before edge.
private final class DecisionBox: @unchecked Sendable {
    var value: MCPConsentDecision?
}
