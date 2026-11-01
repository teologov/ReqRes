//
//  ProcessIdentity.swift
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
//  Per-process attribution (process-attribution UX spec §1.2): the process
//  that opened a captured connection, named by ONE rule.
//
//  The App column, the `app:` token, the detail pill, the saved-sessions
//  browser and the MCP helper's own identity header all show a process name,
//  and they have to show the SAME one: a Brave tab's traffic comes from
//  "Brave Browser Helper" three bundles deep inside Brave Browser.app, and a
//  user who reads "Brave Browser" in the table must find it with
//  `app:brave` and see it named the same way in the sidebar footer when Brave
//  is the MCP client. So the rule lives here, in MCPKit — which has no
//  dependencies, so the sandboxed helper can use it too — and nothing else
//  derives a display name from a path.
//
//  Pure Foundation, no AppKit: icons are the UI's business (`ProcessIconCache`
//  keys on `bundlePath ?? executablePath ?? name`), and the table's word for
//  "could not tell" is `unknownLabel`, pinned equal to the search token's.
//

import Foundation

/// What is known about the process behind a captured connection. All three
/// fields are nil when the capture layer could not attribute it; the name is
/// whatever the core reports ("Brave Browser Helper", "claude"), the path is
/// the executable's, and the display rules below derive everything else.
public struct ProcessIdentity: Hashable, Sendable {
    /// As the core reports it: "Brave Browser Helper", "claude".
    public let name: String?
    public let pid: Int?
    public let executablePath: String?

    /// Blank or whitespace-only strings collapse to nil, so "unattributed" has
    /// one spelling whatever the core sends for it.
    public init(name: String?, pid: Int?, executablePath: String?) {
        self.name = Self.collapsed(name)
        self.pid = pid
        self.executablePath = Self.collapsed(executablePath)
    }

    private static func collapsed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - The word for "could not tell"

    /// What every surface prints for an unattributed session. A test in
    /// UtilsTests asserts this equals `TrafficSearchAppMatch.unknown`, the
    /// one string that makes `app:unknown` select these sessions.
    public static let unknownLabel = "Unknown"

    /// Spec §2.3: the tooltip of an unattributed row and pill.
    public static let unknownTooltip =
        "ReqRes could not tell which process opened this connection — it had already closed when ReqRes looked, or its process could not be named. Nothing is inferred from headers."

    // MARK: - Derived

    /// Whether anything at all is known. A pid alone is not an identity: a
    /// number nobody can name is shown as Unknown, not as "pid 512".
    public var isKnown: Bool { name != nil || executablePath != nil }

    /// The OUTERMOST `.app` bundle on the executable path, or nil.
    ///
    /// Outermost, because a Chromium helper lives in
    /// `Brave Browser.app/…/Brave Browser Helper.app/…` and the app the user
    /// recognises is the first one. Only a path component that ENDS in `.app`
    /// counts (matched as `.app/` or a trailing `.app`): a folder named
    /// `Not.app.backup` is not a bundle, and neither is a bare `.app`.
    public var bundlePath: String? {
        guard let path = executablePath else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: Self.isBundleComponent) else { return nil }
        // Xcode ships a whole toolchain under Contents/Developer — git, python3,
        // swift, xcodebuild — and /usr/bin's shims exec into it. Those are tools
        // a terminal ran, not Xcode making a request; naming them "Xcode" with
        // its icon would hide exactly the processes the App column exists for.
        let rest = components[(index + 1)...]
        if rest.count >= 2, rest[rest.startIndex] == "Contents", rest[rest.startIndex + 1] == "Developer" { return nil }
        return components[...index].joined(separator: "/")
    }

    private static let bundleSuffix = ".app"

    private static func isBundleComponent(_ component: Substring) -> Bool {
        component.hasSuffix(bundleSuffix) && component.count > bundleSuffix.count
    }

    /// The bundle's file name without `.app`: "Brave Browser".
    private var bundleDisplayName: String? {
        guard let bundlePath, let last = bundlePath.split(separator: "/").last else { return nil }
        let stem = last.dropLast(Self.bundleSuffix.count)
        return stem.isEmpty ? nil : String(stem)
    }

    /// The last path component of the executable, else the reported name.
    public var executableName: String? {
        guard let path = executablePath else { return name }
        if let last = path.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return name
    }

    /// What a human reads: the bundle's name ▸ a known system service's
    /// friendly name ▸ the executable's last path component ▸ the reported
    /// name ▸ nil. Nil means "Unknown" — and only `ProcessLabel` in the UI
    /// turns that nil into the word.
    public var displayName: String? {
        if let bundleDisplayName { return bundleDisplayName }
        if let systemService { return systemService.displayName }
        return executableName
    }

    /// True for a process inside a bundle whose executable is not the bundle's
    /// own: "Brave Browser Helper" inside Brave Browser.app. Demoted in the
    /// display (the bundle's name is shown), never hidden (the tooltip names
    /// the helper and its full path).
    public var isHelper: Bool {
        bundlePath != nil && executableName != displayName
    }

    // MARK: - Well-known system services (errata 1)

    /// A system process that makes requests on other apps' behalf and shows up
    /// under its own name — which no user recognises. Safari's networking is
    /// the shared WebKit XPC service, not Safari, so it is named for what it
    /// IS rather than dressed up as Safari (its icon would be a lie: other
    /// WebKit apps share the same process).
    public struct SystemService: Hashable, Sendable {
        public let displayName: String
        /// One line for the tooltip, explaining whose traffic this carries.
        public let note: String
        /// SF Symbol the UI draws instead of an app icon.
        public let symbol: String

        public init(displayName: String, note: String, symbol: String) {
            self.displayName = displayName
            self.note = note
            self.symbol = symbol
        }
    }

    /// Keyed by executable name. Small on purpose: every entry is a process
    /// that was SEEN making an app's traffic, with a note that is true of it.
    public static let systemServices: [String: SystemService] = [
        "com.apple.WebKit.Networking": SystemService(
            displayName: "WebKit",
            note: "WebKit Networking — shared by Safari and other WebKit apps",
            symbol: "network"
        ),
        "nsurlsessiond": SystemService(
            displayName: "Background",
            note: "Background transfers (nsurlsessiond) — downloads and uploads an app handed to the system",
            symbol: "arrow.down.circle"
        ),
    ]

    /// The table entry for this process, or nil. A process INSIDE an app
    /// bundle is that app's helper, not a system service — a browser that
    /// ships its own WebKit names its networking process after itself.
    private var systemService: SystemService? {
        guard bundlePath == nil, let executableName else { return nil }
        return Self.systemServices[executableName]
    }

    public var isSystemService: Bool { systemService != nil }

    /// A named process outside any `.app` bundle that is not a known system
    /// service: curl, node, claude, git — the tools that read their trusted
    /// certificates from a FILE rather than the keychain, which is why a
    /// failure row offers them the CA export (protocol PRD 3.4). The same
    /// test Settings ▸ Capture's "command-line tools seen" line applies.
    public var isCommandLineTool: Bool {
        isKnown && bundlePath == nil && !isSystemService
    }
    public var systemServiceNote: String? { systemService?.note }
    public var systemServiceSymbol: String? { systemService?.symbol }

    // MARK: - Tooltip (spec §2.3)

    /// Line 1: `name · pid N`. Line 2: the bundle for a bundled app, the helper
    /// and its FULL path for a helper (demoted, never hidden), the path for a
    /// bare executable. A system service carries its note between them. An
    /// unattributed identity gets `unknownTooltip`.
    public var tooltip: String {
        guard isKnown else { return Self.unknownTooltip }
        var lines: [String] = []
        var first = displayName ?? executablePath ?? Self.unknownLabel
        if let pid { first += " · pid \(pid)" }
        lines.append(first)
        if let note = systemServiceNote { lines.append(note) }
        if let path = executablePath {
            if let bundlePath {
                if isHelper, let executableName {
                    lines.append("\(executableName) — \(path)")
                } else {
                    lines.append(bundlePath)
                }
            } else {
                lines.append(path)
            }
        }
        return lines.joined(separator: "\n")
    }
}
