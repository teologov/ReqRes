//
//  MCPAgentActionPresentation.swift
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
//  What the approval panel decides, without the panel. Everything here used
//  to live inside MCPApprovalSheet (SwiftUI, in the app target, which has no
//  test target), so none of it was ever exercised by anything but a human
//  looking at the window — including the rule that a burst is titled by its
//  WORST action, which is exactly the kind of thing a refactor quietly flips.
//
//  SwiftUI stays out of MCPKit on purpose: this returns symbol NAMES and a
//  semantic tint, and the view is the only place that turns those into
//  `Image(systemName:)` and `Color`.

import Foundation

/// The weight a change carries, expressed as a case rather than a colour so
/// MCPKit never has to import SwiftUI to say "this one is dangerous."
public enum MCPAgentActionTint: Equatable, Sendable {
    case neutral
    case caution
    case destructive

    public init(severity: MCPAgentAction.Severity) {
        switch severity {
        case .routine: self = .neutral
        // An export changes nothing in the app but takes traffic out of it —
        // worth a second look, not an alarm.
        case .exportsData: self = .caution
        case .rewritesTraffic: self = .caution
        case .destructive: self = .destructive
        // The strongest tint available, because there is nothing stronger to
        // reserve it for: a replay is the only action on this surface whose
        // effect is outside the user's machine and outside their reach.
        case .actsOnThirdParty: self = .destructive
        }
    }
}

/// Everything the approval panel needs to render one burst of agent actions,
/// computed once from the actions themselves.
public struct MCPAgentActionPresentation: Equatable, Sendable {
    /// One action, presented: its own icon and tint (by ITS severity, not the
    /// burst's — a routine `add_host` sitting next to a delete stays neutral),
    /// plus the accessibility label that names the weight in words.
    public struct Row: Equatable, Sendable {
        public var symbolName: String
        public var tint: MCPAgentActionTint
        public var summary: String
        public var details: [String]
        public var accessibilityLabel: String
    }

    /// Titled by the burst's highest severity, singular/plural aware.
    public var title: String
    /// The one line stated once for the whole burst, at its highest severity.
    public var consequence: String
    public var consequenceSymbolName: String
    public var tint: MCPAgentActionTint
    public var rows: [Row]

    public init(actions: [MCPAgentAction]) {
        let severity = actions.highestSeverity
        // An exclusion shares a rule's severity but not its consequence: the
        // apps still receive the real response — it is the human (and the
        // agent) who stop seeing it. When exclusions are ALL the burst's
        // heaviest actions, the panel says that instead of "what these rules
        // say", which would be false (PRD 3.5's consent copy).
        let heaviest = actions.filter { $0.severity == severity }
        let onlyExclusions = !heaviest.isEmpty && heaviest.allSatisfy { $0.kind == .excludeHost }
        title = onlyExclusions
            ? Self.exclusionTitle(count: actions.count, exclusions: heaviest.count)
            : Self.makeTitle(count: actions.count, severity: severity)
        consequence = onlyExclusions ? Self.exclusionConsequence : severity.consequence
        consequenceSymbolName = Self.symbolName(forConsequence: severity)
        tint = MCPAgentActionTint(severity: severity)
        rows = actions.map { action in
            Row(
                symbolName: Self.symbolName(for: action.kind),
                tint: MCPAgentActionTint(severity: action.severity),
                summary: action.summary,
                details: action.details,
                accessibilityLabel: Self.makeAccessibilityLabel(for: action)
            )
        }
    }

    /// "Change ReqRes" is true of every action and therefore tells the reader
    /// nothing when the burst is about to delete their rules — so the title
    /// is keyed off the WORST action's severity, not the first or the last.
    private static func makeTitle(count: Int, severity: MCPAgentAction.Severity) -> String {
        switch severity {
        case .routine:
            return count == 1
                ? "An AI agent wants to change ReqRes"
                : "An AI agent wants to make \(count) changes"
        case .exportsData:
            return count == 1
                ? "An AI agent wants to save captured traffic to a file"
                : "An AI agent wants to make \(count) changes, including saving traffic to a file"
        case .rewritesTraffic:
            return count == 1
                ? "An AI agent wants to change what your apps receive"
                : "An AI agent wants to make \(count) changes to what your apps receive"
        case .destructive:
            return count == 1
                ? "An AI agent wants to delete something"
                : "An AI agent wants to make \(count) changes, including deletions"
        case .actsOnThirdParty:
            return count == 1
                ? "An AI agent wants to send a request to a real server"
                : "An AI agent wants to make \(count) changes, including sending a request to a real server"
        }
    }

    private static func exclusionTitle(count: Int, exclusions: Int) -> String {
        if count == 1 { return "An AI agent wants ReqRes to stop recording a host" }
        return exclusions == count
            ? "An AI agent wants ReqRes to stop recording \(count) hosts"
            : "An AI agent wants to make \(count) changes, including hosts ReqRes stops recording"
    }

    static let exclusionConsequence =
        "ReqRes will stop recording these hosts: their connections are passed straight through, and you will no longer see their traffic. Settings ▸ Capture puts a host back."

    private static func symbolName(forConsequence severity: MCPAgentAction.Severity) -> String {
        switch severity {
        case .routine: return "eye"
        case .exportsData: return "square.and.arrow.up"
        case .rewritesTraffic: return "arrow.triangle.branch"
        case .destructive: return "exclamationmark.triangle.fill"
        case .actsOnThirdParty: return "paperplane.fill"
        }
    }

    private static func symbolName(for kind: MCPAgentAction.Kind) -> String {
        switch kind {
        case .addHost: return "globe.badge.chevron.backward"
        case .removeHost: return "globe"
        case .createRule, .mockFromSession: return "arrow.triangle.branch"
        case .updateRule: return "pencil"
        case .deleteRule: return "trash"
        case .startCapture: return "record.circle"
        case .stopCapture: return "stop.circle"
        case .clearSessions: return "trash.slash"
        case .exportSessions: return "square.and.arrow.up"
        // Kept / un-kept, not another trash can: a saved session is a thing
        // the user curated, and the delete is of their collection, not of
        // captured traffic.
        case .saveSession: return "bookmark"
        case .deleteSavedSession: return "bookmark.slash"
        // Something leaving, not something being edited: the glyph should
        // read as "this goes out", which no other row on this surface does.
        case .replayRequest: return "paperplane"
        // A request let go, not one sent or edited: this row is always about
        // something that was already stopped and is now moving again — or
        // stopped for good.
        case .answerPausedRequest: return "play.pause"
        // Out of view, not rewritten: the glyph the exclusion list's own rows
        // would carry if they had one.
        case .excludeHost: return "eye.slash"
        }
    }

    /// The glyph beside a row is decorative; VoiceOver should read the change
    /// as one item with its weight named, so colour is never the only signal.
    private static func makeAccessibilityLabel(for action: MCPAgentAction) -> String {
        let weight: String
        switch action.severity {
        case .routine: weight = "Changes what ReqRes watches"
        case .exportsData: weight = "Writes captured traffic to a file"
        case .rewritesTraffic: weight = "Rewrites live traffic"
        case .destructive: weight = "Deletes data"
        case .actsOnThirdParty: weight = "Sends a real request to another server"
        }
        let spoken = action.kind == .excludeHost ? "Stops recording a host" : weight
        return ([spoken, action.summary] + action.details).joined(separator: ". ")
    }
}
