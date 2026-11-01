//
//  ProcessAttributionPresentation.swift
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
//  The words and decisions the App column, the detail pill and the agent
//  popover need that are NOT a view's business (process-attribution UX spec
//  §2.3, §2.4, §5.1, §8.2, §8.3): the accessibility value a row reads, the
//  agent line prepended to a tooltip, which captured process is an agent's,
//  and what "Show its traffic" does for one connected client.
//
//  Pure on purpose. `ProcessLabel` and `AgentActivityPopover` render these;
//  they do not decide them, so a test can hold the rule ("a GUI agent is
//  matched by NAME only when the identity is a bundled app") without AppKit.
//

import Foundation

// MARK: - Words

extension ProcessIdentity {
    /// Spec §5.1: the pill's tooltip when attribution is unavailable on this
    /// Mac — a fact about the machine now, not about one request.
    public static let unavailableTooltip =
        "ReqRes cannot tell which process opens connections on this Mac right now — the socket table could not be read. Capture ▸ Diagnose Setup… has the details."

    /// Spec §2.4: `"Safari, process 40213"`, `"Brave Browser, via Brave Browser
    /// Helper, process 4127"`, `"Unknown"`; an agent's row appends
    /// `", from the connected agent Claude Code"`.
    public func accessibilityValue(agentName: String? = nil) -> String {
        guard isKnown else { return Self.unknownLabel }
        var value = displayName ?? executablePath ?? Self.unknownLabel
        if isHelper, let executableName {
            value += ", via \(executableName)"
        }
        if let pid {
            value += ", process \(pid)"
        }
        if let agentName {
            value += ", from the connected agent \(agentName)"
        }
        return value
    }

    /// Spec §2.3, last bullet: an agent-driven row's tooltip gets line 0
    /// `"Claude Code — the agent connected to ReqRes"` above the usual lines.
    public func tooltip(agentName: String?) -> String {
        guard let agentName else { return tooltip }
        return "\(agentName) — the agent connected to ReqRes\n\(tooltip)"
    }
}

// MARK: - Which rows are an agent's (spec §8.2)

/// The connected MCP clients, indexed the two ways a captured session can be
/// matched to one. Built from `MCPServerService.connectedClients` by the list
/// view once per render and handed to rows as a value — a row never observes
/// the service.
///
/// `processIDs` and `namesByDisplayName` are the spec's `agentProcessIDs` and
/// `agentNames`, derived here by the same rule so the badge, its tooltip and
/// its accessibility value (which need the client's NAME, not just a yes)
/// come from one place.
public struct MCPAgentAttribution: Equatable, Sendable {
    /// The clients' own pids — exact matches for command-line agents, whose
    /// requests come from the very process that spawned the helper.
    public let processIDs: Set<Int>
    /// Lower-cased client name → client name, for GUI agents (Cursor, Claude
    /// Desktop) whose requests come from helper pids inside the app bundle.
    public let namesByDisplayName: [String: String]
    private let namesByProcessID: [Int: String]

    public static let none = MCPAgentAttribution(clients: [])

    public init(clients: [MCPClient]) {
        var pids = Set<Int>()
        var byPid: [Int: String] = [:]
        var byName: [String: String] = [:]
        for client in clients {
            if let pid = client.processID {
                pids.insert(pid)
                // Two clients cannot share a pid; the first recorded wins so
                // the answer is stable across renders.
                if byPid[pid] == nil { byPid[pid] = client.name }
            }
            let key = client.name.lowercased()
            if byName[key] == nil { byName[key] = client.name }
        }
        processIDs = pids
        namesByProcessID = byPid
        namesByDisplayName = byName
    }

    public var isEmpty: Bool { processIDs.isEmpty && namesByDisplayName.isEmpty }

    /// The connected client this process belongs to, or nil.
    ///
    /// Spec §8.2: `pid ∈ agentProcessIDs` (exact — CLI agents) OR a BUNDLED
    /// identity whose display name is a connected client (GUI agents make
    /// traffic from helper pids; a second Cursor window is also marked —
    /// documented, not hidden). Never from the request itself: a bare
    /// executable named like a client is not that client.
    public func agentName(for identity: ProcessIdentity) -> String? {
        if let pid = identity.pid, let name = namesByProcessID[pid] {
            return name
        }
        guard identity.bundlePath != nil, let displayName = identity.displayName else { return nil }
        return namesByDisplayName[displayName.lowercased()]
    }
}

// MARK: - "Show its traffic" (spec §8.3)

/// What the button beside one connected client does: filter to its pid when
/// the capture index has that pid, else to its name when the index has that
/// app, else nothing — disabled, with the hint that says why and where to go.
public enum MCPAgentTrafficLink: Equatable, Sendable {
    case pid(Int)
    case app(String)
    case unavailable(hint: String)

    public static let title = "Show its traffic"

    /// `hasCapturedPid` / `hasCapturedApp` are the capture index's answers
    /// (`SessionState.pidCandidates` / `identity(forDisplayName:)`), injected
    /// so the decision is testable without a session store.
    public static func resolve(
        client: MCPClient,
        hasCapturedPid: (Int) -> Bool,
        hasCapturedApp: (String) -> Bool
    ) -> MCPAgentTrafficLink {
        if let pid = client.processID, hasCapturedPid(pid) {
            return .pid(pid)
        }
        if hasCapturedApp(client.name) {
            return .app(client.name)
        }
        return .unavailable(hint: unavailableHint(clientName: client.name))
    }

    /// Spec §8.3, verbatim.
    public static func unavailableHint(clientName: String) -> String {
        "No captured requests from \(clientName) yet. A command-line agent needs the environment in Settings ▸ Capture."
    }
}
