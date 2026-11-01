//
//  MCPCaptureDelivery.swift
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
//  Whether what capture records reaches the app the agent is talking to
//  (F11, 2026-09-30), as capture_status and diagnose_setup carry it.
//
//  Capture on and rows arriving are different facts: the extension delivers
//  only to an app that proved itself on the message bus. Before build 53 it
//  dialed the app only when capture started, so after the app was relaunched
//  while capturing, capture_status said "running" and every list came back
//  empty — the one state an agent could not tell from "nothing has happened
//  yet". Since core 95062d1 the extension redials a relaunched app by itself
//  and delivers what it kept meanwhile; the few seconds that takes are
//  `reconnecting`, and what it delivered rides on `receiving`. The app makes
//  the verdict (Utils `CaptureReattach`, which MCPKit cannot import) and sends
//  it here with the person-facing reason; the agent's wording is this file's,
//  and so is the person's version of each fix, for Capture ▸ Diagnose Setup…
//  and the menu bar item's tooltip.
//

import Foundation

/// The verdict, as the bridge sends it.
public struct MCPCaptureDelivery: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// An extension has proved itself on the app's bus: rows arrive.
        case receiving
        /// Capture is on and the extension has not proved itself yet — the
        /// first moments of a start the app sent.
        case waiting
        /// Capture that was running before the app could receive it (the app
        /// was relaunched, or the extension's connection closed) is
        /// reconnecting: its extension redials the app by itself and then
        /// delivers what it kept meanwhile (build 53).
        case reconnecting
        /// Capture is on and nothing reaches this app.
        case notReceiving = "not_receiving"
        /// Capture is on and another copy of ReqRes holds its connection —
        /// whether that copy receives it is not known to this one.
        case otherCopy = "other_copy"
        /// Capture is off or on its way on or off.
        case notCapturing = "not_capturing"

        /// A state a later app adds reads as not capturing — the check that
        /// renders it is then "could not tell", never a false ok, and the
        /// whole status is not lost over one field.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .notCapturing
        }
    }

    public var state: State
    /// Why nothing arrives, in one sentence for a person (Utils
    /// `CaptureDeliveryCopy.reason`); nil unless `notReceiving`.
    public var reason: String?
    /// Whether Restart Capture in the app fixes it — false for another copy,
    /// where restarting would take the capture away from the copy holding it.
    public var restartable: Bool
    /// `receiving` after a reattach: the requests the extension delivered
    /// from while no app received them — for a few minutes after it (the app
    /// stops sending them, `CaptureReattach.reattachReportWindow`). Nil
    /// otherwise, and absent from older statuses.
    public var capturedWhileDetached: Int?
    /// …and the earlier rows it could not keep (its queue holds the newest
    /// 512 messages). Nil otherwise, and absent from older statuses.
    public var droppedRows: Int?

    public init(state: State, reason: String? = nil, restartable: Bool = false,
                capturedWhileDetached: Int? = nil, droppedRows: Int? = nil) {
        self.state = state
        self.reason = reason
        self.restartable = restartable
        self.capturedWhileDetached = capturedWhileDetached
        self.droppedRows = droppedRows
    }

    /// The check's id, which diagnose_setup places right after `proxy`.
    public static let checkId = "delivery"
    public static let checkTitle = "Delivery to ReqRes"

    // MARK: Fixes — the agent's, and a person's

    /// What the agent asks for: the button the app shows in the traffic list
    /// and in the menu bar item's menu (Utils `CaptureDeliveryCopy.restartButton`),
    /// or the two tools. They are routine changes, which the user's standing
    /// grant can answer without a panel (`MCPAgentAction.canBeCoveredByStandingGrant`)
    /// — so nothing here promises the user will be asked.
    public static let restartFix = "Ask the user to click Restart Capture in ReqRes — in the traffic list, or in the menu bar item's menu — or call stop_capture and then start_capture (each asks the user first unless they allowed agent changes without asking). Either starts capture again from ReqRes, so the extension connects to it; until then no new session reaches list_sessions."
    public static let otherCopyFix = "Ask the user which copy of ReqRes they want to use — you are connected to the one that is not receiving. To capture in this one, they quit the other copy (which stops its capture) and start capture here."

    /// The same fixes said TO the person (Capture ▸ Diagnose Setup…, the
    /// menu bar item's tooltip): the agent's wording names tools and speaks
    /// about "the user", and the app's generic rewording only strips an
    /// opening "Ask the user to" — it left "call stop_capture" in one and all
    /// of "Ask the user which copy…" in the other (F11 review).
    public static let humanRestartFix = "Click Restart Capture — in the traffic list or in the menu bar item's menu — so capture starts again from this window and the extension connects to it."
    public static let humanOtherCopyFix = "Use the other copy of ReqRes, which holds this capture's connection — or quit it (quitting it stops its capture) and start capture here."

    /// The person's fix for a delivery check, nil for any other check or one
    /// with nothing to do.
    public static func humanFix(for check: MCPSetupCheck) -> String? {
        guard check.id == checkId else { return nil }
        switch check.fix {
        case restartFix?: return humanRestartFix
        case otherCopyFix?: return humanOtherCopyFix
        default: return nil
        }
    }

    /// Whether the report's first problem is capture not reaching ReqRes in a
    /// way Restart Capture fixes — Diagnose Setup then offers the button.
    public static func offersRestart(in report: MCPSetupReport) -> Bool {
        guard report.blockingCheckId == checkId else { return false }
        return report.checks.first { $0.id == checkId }?.fix == restartFix
    }

    // MARK: The check and the status line

    /// diagnose_setup's check. Receiving is ok; not receiving and another
    /// copy block (capture is on and this app gets nothing new); waiting and
    /// reconnecting are a moment's warning, like a tunnel still connecting;
    /// not capturing is "could not tell" — there is nothing to deliver while
    /// capture is off.
    ///
    /// The details are read by a person too (Diagnose Setup…, the tooltip),
    /// so they speak to neither party; what is the agent's to hear — its
    /// tools, "you" — is in the fix and in `statusLine`.
    public func check() -> MCPSetupCheck {
        switch state {
        case .receiving:
            return MCPSetupCheck(
                id: Self.checkId, title: Self.checkTitle, state: .ok,
                detail: "The extension is connected to ReqRes, so what capture records reaches the traffic list." + (reattachSentence.map { " " + $0 } ?? "")
            )
        case .reconnecting:
            return MCPSetupCheck(
                id: Self.checkId, title: Self.checkTitle, state: .warning,
                detail: "Capture kept running while ReqRes wasn't receiving it, and its extension is reconnecting to ReqRes — what it captured meanwhile arrives when it does; ask again in a moment."
            )
        case .waiting:
            // Neutral on purpose: the first moments of a start the app sent,
            // and the seconds before ReqRes restarts a capture whose extension
            // cannot reconnect by itself (started outside ReqRes, or an
            // earlier build's) — a relaunch's are `reconnecting`.
            return MCPSetupCheck(
                id: Self.checkId, title: Self.checkTitle, state: .warning,
                detail: "The extension has not connected to ReqRes yet; ask again in a moment."
            )
        case .notReceiving:
            return MCPSetupCheck(
                id: Self.checkId, title: Self.checkTitle, state: .problem,
                detail: "Capture is on, but ReqRes isn't receiving what it records, so no new request reaches its traffic list." + (reason.map { " " + $0 } ?? ""),
                fix: restartable ? Self.restartFix : nil
            )
        case .otherCopy:
            return MCPSetupCheck(
                id: Self.checkId, title: Self.checkTitle, state: .problem,
                detail: "Another copy of ReqRes is running and holds this capture's connection, so this copy receives nothing new.",
                fix: Self.otherCopyFix
            )
        case .notCapturing:
            return MCPSetupCheck(
                id: Self.checkId, title: Self.checkTitle, state: .unknown,
                detail: "Capture is not on, so there is nothing to deliver yet."
            )
        }
    }

    /// capture_status's line; nil while capture is off (the Capture line
    /// already says so, and the status is polled — every line costs). It sits
    /// right under the session count, which can be anything but zero: rows
    /// from before stay listed, so the line speaks of NEW sessions.
    public var statusLine: String? {
        switch state {
        case .receiving:
            // Mid-line after the dash: "the extension…", not "The extension…".
            return "Delivery: requests reach ReqRes" + (reattachSentence.map { " — " + $0.prefix(1).lowercased() + $0.dropFirst() } ?? "")
        case .reconnecting:
            return "Delivery: reconnecting to the running capture — what it captured meanwhile reaches list_sessions when it has; ask again in a moment"
        case .waiting:
            return "Delivery: the extension has not connected to ReqRes yet — ask again in a moment"
        case .notReceiving:
            return "Delivery: NOT reaching ReqRes, so no new session reaches list_sessions —" + (reason.map { " " + $0 } ?? "") + (restartable ? " Ask the user to click Restart Capture in ReqRes, or call stop_capture then start_capture." : "")
        case .otherCopy:
            return "Delivery: another copy of ReqRes holds this capture's connection, so no new session reaches this copy"
        case .notCapturing:
            return nil
        }
    }

    /// What a reattach delivered, in one sentence read by both parties; nil
    /// when there is none to speak of. It names the extension: in the status
    /// line it follows a dash, where "It" had nothing to refer to.
    var reattachSentence: String? {
        let captured = max(0, capturedWhileDetached ?? 0)
        let dropped = max(0, droppedRows ?? 0)
        guard captured > 0 || dropped > 0 else { return nil }
        guard captured > 0 else {
            return "The extension reconnected after capturing while ReqRes wasn't receiving it; \(Self.requests(dropped)) captured then \(dropped == 1 ? "was" : "were") not kept."
        }
        let lost = dropped == 0 ? "" : "; \(StreamEventsPresentation.grouped(dropped)) earlier \(dropped == 1 ? "one was" : "ones were") not kept"
        return "The extension reconnected and delivered \(Self.requests(captured)) captured while ReqRes wasn't receiving it\(lost)."
    }

    /// "1 request", "25,000 requests" — grouped like the app's other counts.
    private static func requests(_ count: Int) -> String {
        count == 1 ? "1 request" : "\(StreamEventsPresentation.grouped(count)) requests"
    }
}
