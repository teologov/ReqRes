//
//  ReqResStatusMenuPlan.swift
//  AppServices
//
//  Created by OloApps on 22.09.2026.
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
//  The menu bar status item's GLYPH, ARRANGEMENT and WORDING, as pure data.
//
//  Same reasoning as ReqResToolbarPlan, one surface further out. A status
//  item is the part of ReqRes a user looks at while NOT looking at ReqRes:
//  the glyph is often the only thing telling them a proxy is intercepting
//  their machine's traffic, and the menu is the only way to stop it without
//  finding the window. Everything here therefore breaks silently — a wrong
//  glyph still compiles, a menu row that quietly stops appearing still runs,
//  and both are only noticed as "I didn't realise it was still capturing".
//  Pure data with no AppKit in it can be asserted in `swift test`, which is
//  the only test runner this repo actually has wired.
//
//  Menu, top to bottom:
//
//    Capturing — since 14:02          (status, never clickable; while a
//                                      capture that outlived the app
//                                      reconnects: "Reconnecting to the
//                                      running capture…" — build 53)
//    Stop Capturing
//    Restart Capture                  (only while capture is on but not
//                                      reaching ReqRes — F11)
//    ──────────
//    2 requests held — 41s left       (only while requests are held)
//    Resume All
//    Claude Code connected            (only while an agent is driving)
//    Turn Off Bridge                  (only while the bridge is on)
//    ──────────
//    Open ReqRes
//    Diagnose Setup…                  (only while setup is blocked)
//    Settings…
//    Quit ReqRes (stops capture)
//
//  NOTHING in this file reads the clock. `Date()` anywhere below would make
//  every assertion about "since 14:02" a statement about the afternoon it
//  was written — this repo has already paid for that once, in
//  `SavedSessionSummary.relativeAge`, where a function that politely took a
//  `now` parameter then called `calendar.isDateInYesterday`, which asks the
//  SYSTEM what today is. Times arrive here pre-formatted, through an
//  injected `DateFormatter`.
//

import Foundation

// MARK: - State

/// Everything the status item needs to draw itself, flattened to primitives.
///
/// Flattened deliberately: the real inputs live in `AppState`, `SessionState`,
/// the breakpoint queue and the MCP client registry — four `@Published`
/// sources in three different types, none of which this package can see.
/// One value type is also what makes an exhaustive test matrix possible.
public struct ReqResStatusState: Equatable, Sendable {
    /// The tunnel is up and traffic is being intercepted.
    public var capturing: Bool
    /// A blocking setup problem exists (extension not approved, CA not
    /// trusted, nothing listening on the proxy port) — the states
    /// `MCPSetupDiagnosis` reports a first failure for.
    public var setupBlocked: Bool
    /// Connecting or disconnecting. One Bool, because it is one fact the
    /// status item acts on; see `isDimmed(for:)` for why it never reaches
    /// the glyph's shape.
    public var transitional: Bool
    /// Breakpointed requests waiting for a human decision.
    public var heldRequestCount: Int
    /// Least time remaining across the held requests — the fuse that burns
    /// out FIRST, which is the only one a deadline is useful for.
    public var shortestFuseSeconds: Int?
    /// The MCP client currently driving, e.g. "Claude Code"; nil when none.
    public var activeAgentName: String?
    /// When capture started. Only ever rendered through an injected
    /// formatter — see the note at the top of this file.
    public var capturingSince: Date?
    /// The agent bridge is accepting connections.
    public var bridgeEnabled: Bool
    /// Whether what capture records reaches this app (F11) — only read while
    /// `capturing`: a verdict about a tunnel that is off says nothing.
    public var delivery: CaptureDelivery
    /// This copy of ReqRes holds the message bus. A copy without it stops
    /// capture when it quits only while no other copy runs
    /// (`CaptureControl.stopsCaptureOnQuit`), and the Quit row says
    /// "(stops capture)" exactly when it does (`quitStopsCapture`).
    public var holdsBus: Bool

    public init(
        capturing: Bool = false,
        setupBlocked: Bool = false,
        transitional: Bool = false,
        heldRequestCount: Int = 0,
        shortestFuseSeconds: Int? = nil,
        activeAgentName: String? = nil,
        capturingSince: Date? = nil,
        bridgeEnabled: Bool = false,
        delivery: CaptureDelivery = .notCapturing,
        holdsBus: Bool = true
    ) {
        self.capturing = capturing
        self.setupBlocked = setupBlocked
        self.transitional = transitional
        // A negative count can only be a bug upstream (a queue drained twice).
        // Clamped here so it can never render as "-1 requests held", which
        // would put that bug in the menu bar instead of in a log.
        self.heldRequestCount = max(0, heldRequestCount)
        self.shortestFuseSeconds = shortestFuseSeconds
        let trimmedAgent = activeAgentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty name is "no agent", not an agent called "". The registry
        // identifies a client by its parent process, which can come back
        // blank, and " connected" is not a menu row.
        self.activeAgentName = (trimmedAgent?.isEmpty ?? true) ? nil : trimmedAgent
        self.capturingSince = capturingSince
        self.bridgeEnabled = bridgeEnabled
        self.delivery = delivery
        self.holdsBus = holdsBus
    }

    /// Capture is on and nothing reaches this app: a problem the user fixes
    /// with Restart Capture. Another copy receiving it is not one — capture
    /// works, in the other window.
    public var capturingButNotReceiving: Bool {
        capturing && delivery.offersRestart
    }

    /// Capture is on and another copy of ReqRes holds its connection.
    public var capturingForAnotherCopy: Bool {
        capturing && delivery == .anotherCopy
    }

    /// Capture is on, it was running before this app could receive it (the
    /// app was relaunched, or the extension's connection closed), and its
    /// extension is reconnecting — the few seconds before what it captured
    /// meanwhile arrives (build 53). Nothing to fix and nothing to restart:
    /// the glyph stays "capturing", and the line says what is happening.
    public var capturingAndReconnecting: Bool {
        capturing && delivery == .reconnecting
    }

    /// Whether quitting this copy stops capture — the app's own quit rule
    /// (`CaptureControl.stopsCaptureOnQuit`), fed the same facts. A copy
    /// without the bus while ANOTHER copy runs leaves capture to it; one
    /// without the bus and no other copy (the delivery verdict is then "not
    /// listening", never "another copy") stops a capture nobody receives.
    public var quitStopsCapture: Bool {
        capturing && CaptureControl.stopsCaptureOnQuit(real: .connected, holdsBus: holdsBus,
                                                       anotherCopyRunning: delivery == .anotherCopy)
    }
}

// MARK: - Glyph

/// What the menu bar draws. Four shapes, no more.
///
/// There is deliberately NO transitional case: see `isDimmed(for:)`.
public enum ReqResStatusIcon: String, CaseIterable, Sendable {
    /// Requests are held and a human has to answer them.
    case waiting
    /// Capture cannot work until the user fixes something.
    case blocked
    /// Intercepting.
    case capturing
    /// Not intercepting.
    case idle

    /// SF Symbol name, as data — the point of this file is that the drawing
    /// code chooses nothing.
    public var symbolName: String {
        switch self {
        case .waiting: return "exclamationmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .capturing: return "record.circle.fill"
        case .idle: return "record.circle"
        }
    }
}

// MARK: - Menu rows

/// Stable identity for one row of the status menu.
///
/// Rows are addressed by this, never by their title: the wording is expected
/// to change and the wiring is not. Separators get identities too, so a test
/// can assert where the sections fall instead of counting anonymous gaps.
public enum ReqResStatusMenuItem: String, CaseIterable, Sendable {
    /// The state, in words. Never clickable.
    case status
    case toggleCapture
    /// Stop capture and start it again from this app, so the extension
    /// connects to it (F11). Only while capture is on and not reaching it.
    case restartCapture
    /// Between the capture control and the "something is happening" section.
    case sectionSeparator
    /// How many requests are held, and how long the soonest one has left.
    case heldRequests
    case resumeAll
    /// Which agent is driving.
    case activeAgent
    case turnOffBridge
    /// Between that section and the app section.
    case appSeparator
    case openApp
    case diagnoseSetup
    case settings
    case quit

    /// A rule, not a row: carries no title and cannot be chosen.
    public var isSeparator: Bool {
        switch self {
        case .sectionSeparator, .appSeparator: return true
        default: return false
        }
    }

    /// Text the menu reports but never acts on. Kept as data because AppKit
    /// enables a row with a target and greys out one without, and "the state
    /// line looks clickable" is the kind of thing nobody files a bug about.
    public var isInformational: Bool {
        switch self {
        case .status, .heldRequests, .activeAgent: return true
        default: return false
        }
    }

    /// Stable identifier string, namespaced like the toolbar's.
    public var identifier: String { "com.oloapps.ReqRes.statusMenu.\(rawValue)" }
}

/// One built row: what it is, what it says, whether it can be chosen.
public struct ReqResStatusMenuRow: Equatable, Sendable {
    public let id: ReqResStatusMenuItem
    public let title: String
    public let isEnabled: Bool

    public init(id: ReqResStatusMenuItem, title: String, isEnabled: Bool) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
    }

    public var isSeparator: Bool { id.isSeparator }
}

// MARK: - The plan

public enum ReqResStatusMenuPlan {

    // MARK: Glyph

    /// First match wins: held → blocked → capturing → idle.
    ///
    /// The order is by URGENCY OF THE HUMAN'S ATTENTION, not by how
    /// interesting the state is. A held request is a browser tab spinning
    /// somewhere with a 60-second fuse on it; a setup problem means capture
    /// is not working at all. Either one outranks "capture is fine", which is
    /// the state the user already assumes.
    ///
    /// Capture that is on but not reaching ReqRes is `blocked` too (F11): the
    /// tunnel is decrypting every request on the Mac while the app shows
    /// none of them, which is not the "capture is fine" the capturing glyph
    /// promises.
    public static func icon(for state: ReqResStatusState) -> ReqResStatusIcon {
        if state.heldRequestCount > 0 { return .waiting }
        if state.setupBlocked || state.capturingButNotReceiving { return .blocked }
        if state.capturing { return .capturing }
        return .idle
    }

    /// Connecting/disconnecting DIMS the glyph and never changes its shape.
    ///
    /// A fifth shape here would mean the menu bar icon flickers through a
    /// third silhouette on every start and stop — motion in the corner of the
    /// eye that says "something is wrong" for a state that is entirely
    /// normal. Dimming reads as "working on it" without the user having to
    /// re-identify the glyph. It is also why this is a separate function:
    /// nothing may derive the dim from the icon case, or the independence is
    /// gone the first time someone refactors.
    public static func isDimmed(for state: ReqResStatusState) -> Bool {
        state.transitional
    }

    // MARK: Words

    /// The status line at the top of the menu.
    ///
    /// `capturingSinceText` is PRE-FORMATTED (see `sinceText(for:formatter:)`).
    /// Nothing in this file may turn a `Date` into a string on its own — the
    /// bug that costs is the one in `SavedSessionSummary.relativeAge`'s
    /// comment: a function that takes `now` and then asks the system clock
    /// what "today" is passes its tests only on the day they were written.
    ///
    /// Ranked like the glyph, with one addition: `transitional` speaks here
    /// even though it is silent in the glyph. A menu that says "Not
    /// capturing" while the tunnel is mid-connect is simply wrong, and a menu
    /// has room for a sentence where a 16pt glyph has room for dimming.
    public static func statusTitle(for state: ReqResStatusState, capturingSinceText: String? = nil) -> String {
        if state.heldRequestCount > 0 {
            return heldCountText(state.heldRequestCount)
        }
        if state.setupBlocked {
            return "Setup needs attention"
        }
        if state.transitional {
            // No direction is claimed. `transitional` is one Bool and cannot
            // tell a connect from a disconnect, and "Starting capture…" shown
            // while capture is STOPPING is worse than the vaguer truth.
            return "Starting or stopping capture"
        }
        if state.capturing {
            // The tunnel is up either way; what the line owes the user is
            // whether THIS app is getting what it captures (F11).
            if state.capturingButNotReceiving { return CaptureDeliveryCopy.menuNotReceiving }
            if state.capturingForAnotherCopy { return CaptureDeliveryCopy.anotherCopyTitle }
            if state.capturingAndReconnecting { return CaptureDeliveryCopy.menuReconnecting }
            guard let since = capturingSinceText, !since.isEmpty else { return "Capturing" }
            return "Capturing — since \(since)"
        }
        return "Not capturing"
    }

    /// What VoiceOver says for the status item itself.
    ///
    /// Spelled out because for a VoiceOver user the glyph is not a signal at
    /// all, and neither is the dim — an assistive user has NO other way to
    /// learn that ReqRes is currently intercepting their traffic. It takes no
    /// formatter on purpose: the time capture started is detail, the fact
    /// that it is capturing is the message, and a label that needed a clock
    /// would be one more thing that can be wrong.
    public static func accessibilityLabel(for state: ReqResStatusState) -> String {
        "ReqRes: " + spokenPhrase(for: state)
    }

    private static func spokenPhrase(for state: ReqResStatusState) -> String {
        if state.heldRequestCount > 0 { return heldCountText(state.heldRequestCount) }
        if state.setupBlocked { return "setup needs attention" }
        if state.transitional { return "starting or stopping capture" }
        // Spelled out rather than lowercased: "reqres" is not what anyone says.
        if state.capturingButNotReceiving { return "capture is on but not reaching ReqRes" }
        if state.capturingForAnotherCopy { return "another copy of ReqRes holds this capture's connection" }
        if state.capturingAndReconnecting { return "reconnecting to the running capture" }
        if state.capturing { return "capturing" }
        return "not capturing"
    }

    // MARK: Rows

    /// The whole menu for a state, top to bottom.
    public static func rows(for state: ReqResStatusState, capturingSinceText: String? = nil) -> [ReqResStatusMenuRow] {
        var rows: [ReqResStatusMenuRow] = []

        rows.append(ReqResStatusMenuRow(
            id: .status,
            title: statusTitle(for: state, capturingSinceText: capturingSinceText),
            isEnabled: false))

        // Disabled mid-transition: the tunnel is already moving, and a second
        // start (or a stop landing on a half-built tunnel) is how the
        // extension gets wedged in `Connecting` — measured on this machine,
        // and only a reboot clears it.
        rows.append(ReqResStatusMenuRow(
            id: .toggleCapture,
            title: state.capturing ? "Stop Capturing" : "Start Capturing",
            isEnabled: !state.transitional))

        // Right under the control it pairs with, and only when it helps:
        // capture on, this app not receiving it, the tunnel not already
        // moving. Never for another copy — restarting here would take the
        // capture away from the window that is receiving it.
        if state.capturingButNotReceiving && !state.transitional {
            rows.append(ReqResStatusMenuRow(id: .restartCapture, title: CaptureDeliveryCopy.restartButton, isEnabled: true))
        }

        rows.append(separator(.sectionSeparator))

        if state.heldRequestCount > 0 {
            rows.append(ReqResStatusMenuRow(
                id: .heldRequests,
                title: heldRequestsTitle(for: state),
                isEnabled: false))
            rows.append(ReqResStatusMenuRow(id: .resumeAll, title: "Resume All", isEnabled: true))
        }

        if let agent = state.activeAgentName {
            rows.append(ReqResStatusMenuRow(id: .activeAgent, title: "\(agent) connected", isEnabled: false))
        }

        // Independent of an agent being connected: the bridge is a listening
        // port whether or not anything is talking to it, and the kill switch
        // has to be reachable exactly when nothing is visibly using it.
        if state.bridgeEnabled {
            rows.append(ReqResStatusMenuRow(id: .turnOffBridge, title: "Turn Off Bridge", isEnabled: true))
        }

        rows.append(separator(.appSeparator))

        rows.append(ReqResStatusMenuRow(id: .openApp, title: "Open ReqRes", isEnabled: true))

        if state.setupBlocked {
            rows.append(ReqResStatusMenuRow(id: .diagnoseSetup, title: "Diagnose Setup…", isEnabled: true))
        }

        rows.append(ReqResStatusMenuRow(id: .settings, title: "Settings…", isEnabled: true))

        // The parenthetical is the whole point of the row: quitting ReqRes
        // tears down the tunnel, so a user quitting "just the little icon"
        // is also turning off the capture they were relying on. A copy that
        // leaves the capture to another copy of ReqRes does not, and says so.
        rows.append(ReqResStatusMenuRow(
            id: .quit,
            title: state.quitStopsCapture ? "Quit ReqRes (stops capture)" : "Quit ReqRes",
            isEnabled: true))

        return collapsingSeparators(rows)
    }

    // MARK: Pieces

    /// `2 requests held — 41s left`, or just the count when no fuse is known.
    public static func heldRequestsTitle(for state: ReqResStatusState) -> String {
        let count = heldCountText(state.heldRequestCount)
        guard let fuse = state.shortestFuseSeconds else { return count }
        return count + " — " + fuseText(seconds: fuse)
    }

    /// The SHORTEST time remaining, which is the only one worth a deadline.
    ///
    /// Not the first, and not the newest: the requests are held in arrival
    /// order, so the first one in the queue is usually the one with the LEAST
    /// time left — usually, which is what makes taking it by position a bug
    /// that works in testing. A held request whose fuse burns out is resumed
    /// by the core without asking, so the number shown is how long the user
    /// has before a decision is made for them.
    public static func shortestFuse(among secondsRemaining: [Int]) -> Int? {
        secondsRemaining.min()
    }

    /// `41s left`, `1m 5s left`, `resuming now`.
    public static func fuseText(seconds: Int) -> String {
        let remaining = max(0, seconds)
        // Zero is not "0s left" — the fuse has burned and the core is about
        // to resume the request on its own. Saying so is the difference
        // between "hurry" and "too late".
        if remaining == 0 { return "resuming now" }
        if remaining < 60 { return "\(remaining)s left" }
        let minutes = remaining / 60
        let seconds = remaining % 60
        return seconds == 0 ? "\(minutes)m left" : "\(minutes)m \(seconds)s left"
    }

    /// `1 request held` / `2 requests held`.
    public static func heldCountText(_ count: Int) -> String {
        let clamped = max(0, count)
        return "\(clamped) request\(clamped == 1 ? "" : "s") held"
    }

    // MARK: Time, injected

    /// The formatter the status line's `since` time is built with.
    ///
    /// Time only, never a date: "since 14:02" answers "is this session old?",
    /// and a capture running long enough for the DAY to matter is a different
    /// problem than a menu line can report. Built here so a test can hand in
    /// a fixed locale and time zone and get a string that does not depend on
    /// where the machine running the test is standing.
    public static func sinceFormatter(locale: Locale = .current, timeZone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    /// Renders `capturingSince` for `statusTitle(for:capturingSinceText:)`.
    ///
    /// Takes the formatter rather than making one, and takes the date rather
    /// than reading the clock. There is no "today"/"yesterday" branch here by
    /// design — that branch is precisely what made the saved-session
    /// formatter consult the system clock behind its own `now` parameter.
    public static func sinceText(for date: Date?, formatter: DateFormatter) -> String? {
        guard let date else { return nil }
        return formatter.string(from: date)
    }

    // MARK: Assembly

    private static func separator(_ id: ReqResStatusMenuItem) -> ReqResStatusMenuRow {
        ReqResStatusMenuRow(id: id, title: "", isEnabled: false)
    }

    /// Drops a separator that would render as a leading rule, a trailing
    /// rule, or a doubled one.
    ///
    /// Both middle sections are conditional, so the plain assembly above
    /// produces two adjacent rules whenever nothing is held, no agent is
    /// connected and the bridge is off — which is the ordinary state of the
    /// app, i.e. the one every user sees. AppKit draws every separator it is
    /// given; nothing else collapses them.
    private static func collapsingSeparators(_ rows: [ReqResStatusMenuRow]) -> [ReqResStatusMenuRow] {
        var result: [ReqResStatusMenuRow] = []
        for row in rows {
            if row.isSeparator && (result.isEmpty || result.last?.isSeparator == true) { continue }
            result.append(row)
        }
        while result.last?.isSeparator == true { result.removeLast() }
        return result
    }
}
