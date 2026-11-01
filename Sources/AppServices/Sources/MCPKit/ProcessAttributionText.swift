//
//  ProcessAttributionText.swift
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
//  The sentences the saved-sessions browser and Settings ▸ Capture build
//  from a `ProcessIdentity` (process-attribution UX spec §6 and §7.7), and
//  the one path rule those panes share. Pure Foundation so a plain
//  `swift test` pins each string: a tooltip that says "pid" for a process
//  that has none, or a status line that lists a system service as a
//  terminal tool, is the kind of defect a compile never sees.
//

import Foundation

extension ProcessIdentity {
    /// `Safari · pid 40213`, or the name alone when no pid is known. Nil for
    /// an unattributed identity — the caller decides what "Unknown" looks
    /// like on its surface, exactly as `displayName` leaves it to.
    public var nameWithPid: String? {
        guard let displayName else { return nil }
        guard let pid else { return displayName }
        return "\(displayName) · pid \(pid)"
    }

    /// Spec §6: the line under the URL in a saved row's tooltip —
    /// `App: Safari · pid 40213` / `App: Unknown`.
    public var savedRowTooltipLine: String {
        "App: " + (nameWithPid ?? Self.unknownLabel)
    }

    /// Spec §6: the saved detail pill's tooltip, which has to say WHEN the
    /// attribution was true — a saved row is a fact about the capture it
    /// came from, and the process may be long gone. Nil when unattributed,
    /// so the pill's own `unknownTooltip` stands rather than being covered.
    public var savedPillTooltip: String? {
        nameWithPid.map { "\($0), when this was captured" }
    }
}

/// Spec §7.7: the one sentence under the environment block that says which
/// command-line tools have reached ReqRes in this capture.
public enum CommandLineToolsStatus {
    /// - Parameters:
    ///   - tools: `SessionState.commandLineTools()` — display name and the
    ///     number of distinct processes seen under it, busiest first.
    ///   - attributionAvailable: `AppState.processAttribution` as a
    ///     three-state Bool (`MCPSetupFacts.processAttribution`'s shape):
    ///     nil while unreported, false when the socket table could not be
    ///     read — in which case no list is truthful and the sentence says so.
    public static func line(tools: [(name: String, processes: Int)], attributionAvailable: Bool?) -> String {
        if attributionAvailable == false {
            return "ReqRes cannot tell which process opens connections on this Mac right now, so it cannot say which tools have reached it."
        }
        guard !tools.isEmpty else {
            return "Nothing outside an app bundle has reached ReqRes in this capture."
        }
        let names = tools.map { tool -> String in
            tool.processes > 1 ? "\(tool.name) (\(tool.processes) processes)" : tool.name
        }
        return "Reached ReqRes from outside an app bundle in this capture: " + names.joined(separator: ", ") + "."
    }
}

/// `~/reqres-ca.pem` for a path under the user's home.
///
/// Not `NSString.abbreviatingWithTildeInPath`: inside the sandbox
/// `NSHomeDirectory()` is the app's container, so that method leaves a real
/// home path untouched (measured — Settings ▸ Storage rendered
/// `/Users/…/Library/Group Containers/…` in full). The caller passes the real
/// home (`getpwuid`), and this only does the string work.
public enum TildePath {
    public static func abbreviated(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        // `/Users/dev/x` is under `/Users/dev`; `/Users/developer/x` is not.
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
