//
//  MCPUndo.swift
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
//  Roadmap item 13: turning one activity-log entry back into the write that
//  reverses it. Pure, so the decision of WHAT undoing means can be tested
//  without a window or a database — the app only executes the plan.
//
//  Undo is deliberately NOT a bridge route and NOT a tool. Consent exists to
//  put a human between an agent and a change; an undo is the human, clicking
//  in ReqRes's own window. Exposing it to agents would hand them a second
//  write surface that asks nobody — an agent could create a rule, have it
//  approved, then "undo" something the user had approved earlier.
//

import Foundation

/// The write that reverses one logged action.
public enum MCPUndoPlan: Equatable, Sendable {
    /// Put a changed rule back the way it was. The rule still exists.
    case restoreRule(MCPRule)
    /// Recreate a rule that was deleted. It comes back with a NEW id — the
    /// row it had is gone — which the summary says out loud rather than
    /// letting the user believe #12 is back.
    case recreateRule(MCPRule)
    /// Delete a rule an agent created.
    case deleteRule(id: Int64)
    /// Re-add a host filter that was removed. Its rules do NOT come back:
    /// removing a host takes its rules with it and the log holds no copy of
    /// them, so promising otherwise would be a lie the user finds out about
    /// later.
    case restoreHost(MCPHost)
    /// Remove a host filter an agent added — only while no rule is scoped to
    /// it (`MCPUndo.refusal`): removing a filter deletes its rules, and by
    /// the time someone clicks Undo those can include rules they made by hand.
    case removeHost(id: Int64)
    /// Take a host an agent excluded back OFF Settings ▸ Capture's exclusion
    /// list, so ReqRes records it again. Only that entry — anything the user
    /// changed on the list since stays as they left it.
    case removeExclusion(host: String)
}

public enum MCPUndo {
    /// What undoing `entry` would do, or nil when there is nothing to undo.
    public static func plan(for entry: MCPAuditEntry) -> MCPUndoPlan? {
        guard entry.isReversible else { return nil }
        switch entry.action.kind {
        case .updateRule:
            guard case .rule(let rule)? = entry.previousState else { return nil }
            return .restoreRule(methodAsMatched(rule, in: entry))
        case .deleteRule:
            guard case .rule(let rule)? = entry.previousState else { return nil }
            return .recreateRule(methodAsMatched(rule, in: entry))
        case .removeHost:
            guard case .host(let host)? = entry.previousState else { return nil }
            return .restoreHost(host)
        case .createRule, .mockFromSession:
            guard case .rule(let id)? = entry.created else { return nil }
            return .deleteRule(id: id)
        case .addHost:
            guard case .host(let id)? = entry.created else { return nil }
            return .removeHost(id: id)
        case .excludeHost:
            guard case .exclusion(let snapshot)? = entry.previousState else { return nil }
            return .removeExclusion(host: snapshot.host)
        case .startCapture, .stopCapture, .clearSessions, .exportSessions,
             .saveSession, .deleteSavedSession, .replayRequest, .answerPausedRequest:
            // Saved sessions are managed in their own list, and `isReversible`
            // already refuses them — see MCPAuditEntry for why the activity
            // log deliberately holds no copy of a saved exchange. A replay
            // is refused for a different reason: what it changed is on
            // someone else's server. Answering a held request is refused for
            // a third: the request has already gone, or already been answered
            // without going, by the time anyone reads the row.
            return nil
        }
    }

    /// A snapshot taken before rules matched on method holds the "GET" the
    /// old form and MCP default stored for every rule, a value the matcher
    /// never read. Restored verbatim, the matcher of today would honour it
    /// and a POST mock would silently stop matching; the migration turned
    /// every stored rule's "GET" into any, and so does this.
    static func methodAsMatched(_ rule: MCPRule, in entry: MCPAuditEntry) -> MCPRule {
        guard !entry.rulesMatchMethod, rule.method.uppercased() == "GET" else { return rule }
        var rule = rule
        rule.method = RuleMethod.any
        return rule
    }

    /// What the button will do, in the user's terms, for a confirmation line.
    /// Says the part that surprises: a recreated rule has a new id, and a
    /// restored host does not bring its rules back.
    public static func summary(for plan: MCPUndoPlan) -> String {
        switch plan {
        case .restoreRule(let rule):
            return "Put rule #\(rule.id) back as it was (\(rule.mode.rawValue) \(rule.path))"
        case .recreateRule(let rule):
            return "Recreate the deleted rule (\(rule.mode.rawValue) \(rule.path)) — it comes back with a new id"
        case .deleteRule(let id):
            return "Delete rule #\(id)"
        case .restoreHost(let host):
            return "Add the host filter \(host.host) back — its rules are not restored"
        case .removeHost(let id):
            return "Remove the host filter this added (#\(id)) if it has no rules"
        case .removeExclusion(let host):
            return "Record \(host) again — take it off the exclusion list (connections already open stay as they are)"
        }
    }

    /// Why `plan` must not run now, or nil when it may. `rulesOnHost` is how
    /// many rules the plan's host filter has at the moment of the click, and
    /// `hostName` its name when the app could read it.
    ///
    /// Only removing a host is ever refused (F18). The filter was the agent's,
    /// but removing one deletes every rule scoped to it — the core deletes
    /// them first, and the foreign key cascades besides — and a rule cannot
    /// outlive its filter, so every rule on it now was added after the agent
    /// added the filter: the agent's own, and any the user made by hand in
    /// the Override form. The undo would delete those for good, with nothing
    /// in the log to bring them back. So it reverses what the agent did and
    /// no more — the filter while it is empty, like `removeExclusion`, which
    /// leaves the rest of the list as the user left it — and says where the
    /// deliberate version lives: "Delete host..." in the sidebar row's
    /// context menu, whose confirmation (unless the user switched it off)
    /// says the rules go with the filter.
    ///
    /// Written for the Activity row it is logged in, which shows it in full
    /// under the "Undo — …" line (a failure's reason wraps there): the row is
    /// written at the top of the log, away from the entry it undoes, so it
    /// names the filter as the sidebar shows it — by name, never by the
    /// database id the summary carries — and says how to reach the menu.
    public static func refusal(for plan: MCPUndoPlan, rulesOnHost: Int, hostName: String? = nil) -> String? {
        guard case .removeHost = plan, rulesOnHost > 0 else { return nil }
        let one = rulesOnHost == 1
        let filter = hostName.map { "The host filter \($0)" } ?? "This host filter"
        let row = hostName ?? "the filter"
        return "\(filter) has \(one ? "1 rule" : "\(rulesOnHost) rules") now, and removing the filter "
            + "would delete \(one ? "that rule too, whoever made it" : "those rules too, whoever made them"). "
            + "To delete the filter with \(one ? "its rule" : "its rules"), right-click \(row) in the sidebar "
            + "and choose Delete host..."
    }

    /// The result line for an undo whose target is already gone, or nil when
    /// a missing target means the undo cannot be done.
    ///
    /// Only a plan that REMOVES something can find its work done for it: a
    /// filter or rule deleted since — with "Delete host..." in the sidebar,
    /// where `refusal` sends people, from the Override list, or by an agent —
    /// is exactly what the undo would have left. Ids are never reused (the
    /// core's tables are AUTOINCREMENT), so nothing else answers to that id.
    /// The app marks the entry undone, and its button stops offering a click
    /// that could only fail with a message written for agents ("Use
    /// list_hosts to see the current ids."). Putting something BACK is
    /// different: a rule to restore that is gone, or a deleted rule whose
    /// filter is gone, cannot be put back, and that stays a failure.
    public static func alreadyDone(_ plan: MCPUndoPlan) -> String? {
        switch plan {
        case .deleteRule(let id):
            return "rule #\(id) was already gone"
        case .removeHost(let id):
            return "host #\(id) was already gone"
        case .restoreRule, .recreateRule, .restoreHost, .removeExclusion:
            // `removeExclusion` never finds its entry missing: taking a host
            // off the list that is not on it changes nothing and says nothing.
            return nil
        }
    }

    /// The patch that restores every field of `rule`. Every field is set, not
    /// only the ones that look changed: the log records what the rule WAS,
    /// not which fields the agent touched, so anything left nil here would
    /// silently keep the agent's value.
    public static func patch(restoring rule: MCPRule) -> MCPRulePatch {
        MCPRulePatch(
            enabled: rule.enabled,
            mode: rule.mode,
            matchType: rule.matchType,
            path: rule.path,
            method: rule.method,
            scheme: rule.scheme,
            requestHeaders: rule.requestHeaders,
            responseStatus: rule.responseStatus,
            responseHeaders: rule.responseHeaders,
            responseBody: rule.responseBody,
            localFile: rule.localFilePath.map { MCPLocalFile(path: $0) }
        )
    }

    /// The draft that recreates a deleted rule.
    public static func draft(recreating rule: MCPRule) -> MCPRuleDraft {
        MCPRuleDraft(
            hostId: rule.hostId,
            mode: rule.mode,
            matchType: rule.matchType,
            path: rule.path,
            method: rule.method,
            scheme: rule.scheme,
            requestHeaders: rule.requestHeaders,
            responseStatus: rule.responseStatus,
            responseHeaders: rule.responseHeaders,
            responseBody: rule.responseBody,
            localFile: rule.localFilePath.map { MCPLocalFile(path: $0) },
            enabled: rule.enabled
        )
    }

    public static func draft(restoring host: MCPHost) -> MCPHostDraft {
        MCPHostDraft(host: host.host, scheme: host.scheme, port: host.port)
    }

    /// The entry written for the undo itself, so the log explains why the
    /// rule came back. `byUser` is what keeps it from reading as the agent
    /// having changed its mind.
    public static func entry(for plan: MCPUndoPlan, outcome: MCPAuditOutcome, detail: String? = nil) -> MCPAuditEntry {
        MCPAuditEntry(
            action: MCPAgentAction(kind: kind(for: plan), summary: "Undo — \(summary(for: plan))"),
            outcome: outcome,
            detail: detail,
            byUser: true
        )
    }

    private static func kind(for plan: MCPUndoPlan) -> MCPAgentAction.Kind {
        switch plan {
        case .restoreRule: return .updateRule
        case .recreateRule: return .createRule
        case .deleteRule: return .deleteRule
        case .restoreHost: return .addHost
        case .removeHost: return .removeHost
        // No "include host" kind exists (agents cannot ask for one); the undo
        // is logged under the kind it reverses, marked `byUser`.
        case .removeExclusion: return .excludeHost
        }
    }
}
