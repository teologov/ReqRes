//
//  CaptureReattach.swift
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
//  A capture that outlived the app reattaches to it.
//
//  The extension now looks for the app by itself. When the app it delivered
//  to goes away — it quit, crashed, was relaunched, or the connection closed —
//  its bus redials 127.0.0.1:50001 (after 250 ms, doubling to every 2 s; every
//  30 s once three tries in a row were turned away) until an app proves
//  itself over a handshake bound to the connection. That app gets the rows
//  the extension kept meanwhile (the newest 512 messages), the requests still
//  held for breakpoints and the learned pins, then ONE status_update saying it
//  was reattached and how many rows it could not keep (`BusReattachStatus`).
//  The app answers it, like a start's, by pushing its whole state.
//
//  This file decides what the app makes of that, from facts it can read:
//
//   * reconnecting — capture on, this app holds the bus, no extension has
//     proved itself on it, for less than the grace (3x the 2 s redial);
//   * attached — an extension proved itself: `hasAuthenticatedExtension`,
//     the only fact acted on (every refusal reason but one can be produced by
//     any local process — they pick words, never decide);
//   * not reaching — the grace ran out. Unless the run is one this app just
//     started (a restart would only repeat it), ReqRes restarts capture ONCE
//     by itself, saying why in one line; F11's
//     notice and Restart Capture are what remains when it cannot, or did and
//     that did not help. Never without the bus, never after a person or an
//     agent asked for a start or a stop while capture ran in the same
//     stretch, never before the update's extension swap has returned;
//   * another copy holds the bus — nothing to restart from here; the bind is
//     retried every 5 s, so this copy takes over if the other one dies, and
//     the extension then finds it.
//
//  A stretch — and with it the one automatic restart — ends when an
//  extension has stayed attached for `stableAttachment` (the core's own 4 s),
//  not at the first sign of one: an attachment the extension drops right
//  after the app's state push (a push it cannot read, a Map Local file past
//  its frame limit) comes back by itself, and re-arming on it restarted
//  capture every few seconds for as long as that went on. Each `hello` the
//  bus passes on begins an attachment: a second one in a run is a
//  reconnection, however quickly it came back — a look a second apart may
//  never see the connection gone.
//
//  A reattach the extension reports is honoured only while NetworkExtension
//  says the tunnel is connected. Reported before the app has read the
//  tunnel's status at all (the launch read is asynchronous, and the redial
//  can win the race), it waits for that status instead of being dropped. And
//  a "down" read while a start this app sent has not been reported moving is
//  the previous stop's late notification (`CaptureTunnelWatch` reads its
//  notifications the same way), not the end of the run that start began.
//

import Foundation

// MARK: - What the extension reported

/// The reattach a `status_update` reports — the core's `BusReattachStatus`,
/// read here too so `swift test` reaches it, and read leniently: a key a later
/// core leaves out reads as its default instead of costing the whole report,
/// as the core's own synthesized decoder would. The app tries the core's
/// reader first (`AppController`) and checks at launch that the two agree.
public struct CaptureReattachReport: Equatable, Sendable {
    /// `status`'s value in a reattach (`BusReattachStatus.statusValue`); a
    /// start's status_update says "connected".
    public static let statusValue = "reattached"
    /// The bus action carrying it (`ClientBusAction.statusUpdate`).
    public static let action = "status_update"

    /// Rows the extension dropped because no app was attached and its queue
    /// was full — the oldest.
    public var droppedRows: Int
    /// Every message dropped for the same reason, the rows included.
    public var droppedMessages: Int
    /// The running capture's proxy port; nil when not said or not a port.
    public var proxyPort: Int?
    /// When the running capture started; nil when not said.
    public var runStartedAt: Date?

    public init(droppedRows: Int = 0, droppedMessages: Int = 0, proxyPort: Int? = nil, runStartedAt: Date? = nil) {
        self.droppedRows = max(0, droppedRows)
        self.droppedMessages = max(0, droppedMessages)
        self.proxyPort = proxyPort.flatMap { (1...65535).contains($0) ? $0 : nil }
        self.runStartedAt = runStartedAt
    }

    /// From a whole bus frame (`{"action":"status_update","payload":{…}}`, the
    /// `data` the app's bus delegate receives); nil for any other frame, a
    /// start's status_update included.
    public static func from(statusUpdateFrame data: Data) -> CaptureReattachReport? {
        guard let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              frame["action"] as? String == action,
              let payload = frame["payload"] as? [String: Any] else { return nil }
        return from(payload: payload)
    }

    /// From a status_update's payload. A reattach is `status: "reattached"`;
    /// with no status at all, `reattached: true` stands in for it. An explicit
    /// `reattached: false` is never one.
    public static func from(payload: [String: Any]) -> CaptureReattachReport? {
        let status = payload["status"] as? String
        let flag = (payload["reattached"] as? NSNumber)?.boolValue
        guard flag != false else { return nil }
        guard status == statusValue || (status == nil && flag == true) else { return nil }
        let startedAt = number(payload["runStartedAt"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return CaptureReattachReport(
            droppedRows: number(payload["droppedRows"]).map(Self.count) ?? 0,
            droppedMessages: number(payload["droppedMessages"]).map(Self.count) ?? 0,
            proxyPort: number(payload["proxyPort"]).flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil },
            runStartedAt: startedAt
        )
    }

    private static func number(_ value: Any?) -> Double? {
        // JSONSerialization hands numbers (and booleans) over as NSNumber; a
        // boolean is not a count.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func count(_ value: Double) -> Int {
        guard value > 0 else { return 0 }
        return value >= Double(Int.max) ? Int.max : Int(value)
    }
}

// MARK: - The requests a reattach delivers

/// Counts the requests the extension delivers between proving itself (its
/// `hello`) and the status_update that ends its backlog — what was captured
/// while no app received it. Distinct by exchange: a request the backlog
/// holds as its live row's start AND its final row is one request.
///
/// The core writes the backlog, its greeting and the reattach status_update
/// in one turn of its loop, and drops the start's own status_update from a
/// reattach's backlog, so the window holds exactly that backlog. Any
/// status_update closes it; a reattach's reports the count.
public struct CaptureReattachTally: Equatable, Sendable {
    /// Far above the extension's queue (512 messages): a window that grows
    /// past it is not a backlog any more.
    public static let maxRows = 2048

    public private(set) var isOpen = false
    private var keys: Set<String> = []

    public init() {}

    /// The extension proved itself: the rows that follow are its backlog.
    public mutating func extensionProvedItself() {
        isOpen = true
        keys.removeAll()
    }

    /// A row arrived — a final row (`send_session`) or a live row's start
    /// (`session_started`), keyed by its exchange.
    public mutating func row(_ key: String) {
        guard isOpen, keys.count < Self.maxRows else { return }
        keys.insert(key)
    }

    /// A status_update arrived: the window closes, and its count is returned
    /// (0 when none was open).
    public mutating func statusUpdate() -> Int {
        defer {
            isOpen = false
            keys.removeAll()
        }
        return isOpen ? keys.count : 0
    }
}

// MARK: - A note in the traffic pane

/// One line the traffic pane shows above its rows until it is dismissed.
public enum CaptureReattachNotice: Equatable, Sendable {
    /// The extension reattached and delivered what it kept meanwhile.
    case reattached(capturedWhileDetached: Int, droppedRows: Int, appWasClosed: Bool)
    /// ReqRes restarted capture by itself, because the running capture could
    /// not reattach — said once the restarted capture is up.
    case restartedAutomatically(CaptureDeliveryProblem)
    /// That restart did not go through.
    case automaticRestartFailed(CaptureRestartFailure)
    /// That restart stopped capture and sent its start, and the capture never
    /// came up — the system or the extension refused it.
    case automaticRestartDidNotStart

    /// Says something did not work (drawn as a warning, not information).
    public var isProblem: Bool {
        switch self {
        case .automaticRestartFailed, .automaticRestartDidNotStart: return true
        case .reattached, .restartedAutomatically: return false
        }
    }

    /// Whether the note stays when the capture it was about stops: one that
    /// says why capture is off — ReqRes's own restart stopped it and it did
    /// not come back, or did not stop in time — does, until the next capture
    /// starts; one about the capture under way goes with it (F13's class: a
    /// line that outlived what it was about).
    public var outlivesTheRun: Bool {
        switch self {
        case .reattached, .restartedAutomatically: return false
        case .automaticRestartDidNotStart: return true
        case .automaticRestartFailed(let failure):
            switch failure {
            case .startRefused, .didNotStop: return true
            case .channelUnavailable, .configurationUnreadable: return false
            }
        }
    }

    public func text(busPort: Int) -> String {
        switch self {
        case let .reattached(captured, dropped, appWasClosed):
            return CaptureDeliveryCopy.reattachSummary(capturedWhileDetached: captured, droppedRows: dropped, appWasClosed: appWasClosed) ?? ""
        case .restartedAutomatically(let problem):
            return CaptureDeliveryCopy.automaticRestartNote(for: problem)
        case .automaticRestartFailed(let failure):
            return CaptureDeliveryCopy.automaticRestartFailedNote(failure, busPort: busPort)
        case .automaticRestartDidNotStart:
            return CaptureDeliveryCopy.automaticRestartDidNotStartNote
        }
    }
}

/// What ReqRes's own restart already did in the stretch under way — said
/// inside "Capture is on, but ReqRes isn't receiving it" (F11's notice),
/// which hides the pane's one-line note while it shows.
public enum CaptureStretchRestart: Equatable, Sendable {
    /// Capture was restarted, and the stretch did not end.
    case restarted
    /// The restart did not go through.
    case failed(CaptureRestartFailure)
}

/// A reattach's counts, as the agent bridge reports them.
public struct CaptureReattachCounts: Equatable, Sendable {
    public var captured: Int
    public var droppedRows: Int

    public init(captured: Int, droppedRows: Int) {
        self.captured = captured
        self.droppedRows = droppedRows
    }
}

// MARK: - The facts a look reads

/// Everything a look is made from, flattened to primitives.
public struct CaptureReattachFacts: Equatable, Sendable {
    /// The tunnel's status as NetworkExtension last reported it; nil until
    /// this process has heard it at all — the display's initial "off" is not
    /// a report, and nothing is decided or reset from it.
    public var tunnel: CaptureTunnelState?
    /// This process listens on the bus (`TCPServerBus.isServerListening`).
    public var holdsBus: Bool
    /// An extension has proved itself on it (`hasAuthenticatedExtension`).
    public var extensionAuthenticated: Bool
    /// The bus's last refusal (`lastRejectedClient`) — words only.
    public var refusal: CaptureBusRefusal?
    /// When it was refused; one from before the run it would explain is not
    /// that run's. Nil reads as current.
    public var refusalDate: Date?
    /// Another process with ReqRes's bundle identifier is running.
    public var anotherCopyRunning: Bool
    /// A start this process sent that the system has not reported moving
    /// yet (`CaptureControl.startInFlight`): a "down" read now is the previous
    /// stop's late notification, not the end of the run the start began.
    public var startInFlight: Bool

    public init(
        tunnel: CaptureTunnelState?,
        holdsBus: Bool = true,
        extensionAuthenticated: Bool = false,
        refusal: CaptureBusRefusal? = nil,
        refusalDate: Date? = nil,
        anotherCopyRunning: Bool = false,
        startInFlight: Bool = false
    ) {
        self.tunnel = tunnel
        self.holdsBus = holdsBus
        self.extensionAuthenticated = extensionAuthenticated
        self.refusal = refusal
        self.refusalDate = refusalDate
        self.anotherCopyRunning = anotherCopyRunning
        self.startInFlight = startInFlight
    }
}

/// Where the capture run under way came from, as far as this process knows.
public enum CaptureRunOrigin: Equatable, Sendable {
    /// No run seen.
    case none
    /// Up when this process launched.
    case predatesProcess
    /// This process sent its start.
    case startedHere
    /// Came up without this process's start: System Settings, scutil, the
    /// system restarting it, or another copy of ReqRes.
    case startedElsewhere
}

/// The one restart ReqRes makes by itself in a stretch of "capture on,
/// nothing reaching it".
public enum CaptureAutomaticRestart: Equatable, Sendable {
    case available
    /// Asked for; the restart is stopping capture or has not reported yet.
    case inFlight(CaptureDeliveryProblem)
    /// Made (or stood down) in this stretch: no second one until an
    /// extension has stayed attached, or capture has stopped.
    case used
}

// MARK: - The machine

public struct CaptureReattach: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Capture is off, on its way on or off, or not reported yet.
        case notCapturing
        /// Capture is on, this app holds the bus, and no extension has proved
        /// itself on it since `since` — for less than the grace.
        case reconnecting(since: Date)
        /// An extension proved itself. The counts are the reattach's that
        /// brought it here — what it delivered from while no app received
        /// it, and the rows it could not keep; 0 for a plain start.
        case attached(capturedWhileClosed: Int, droppedRows: Int)
        /// Capture is on and nothing reaches this app.
        case notReaching(CaptureDeliveryProblem)
        /// Capture is on and another copy of ReqRes holds the bus.
        case otherCopyHoldsBus
    }

    public enum Action: Equatable, Sendable {
        /// Restart capture once (stop, wait for it to be down, start —
        /// Restart Capture's shape), saying why.
        case restartCapture(CaptureDeliveryProblem)
        /// Try to listen on the bus again: the copy that held it may be gone.
        case retryBusBind
        /// The running capture's port and start, from a reattach.
        case adoptRunningCapture(proxyPort: Int?, startedAt: Date?)
    }

    /// How long a connected capture may go without an extension on this
    /// app's bus before it is "not reaching": 3x the extension's 2 s redial
    /// cap. A healthy start proves itself BEFORE the tunnel reads connected
    /// (the extension dials the bus while it starts).
    public static let grace: TimeInterval = 6
    /// How long an extension must stay attached before its attachment ends
    /// the stretch — frees the next automatic restart, and makes what was
    /// asked for before it history: the core's own `stableAttachment` (4 s,
    /// longer than the app takes to answer a reattach with its whole state).
    /// One dropped sooner the core counts like a refusal, and so does this.
    public static let stableAttachment: TimeInterval = 4
    /// How often a copy without the bus tries to listen on it again.
    public static let busRetryInterval: TimeInterval = 5
    /// How long after a reattach the agent bridge still reports its counts:
    /// a capture_status read an hour later is not news of it.
    public static let reattachReportWindow: TimeInterval = 300

    public private(set) var state: State = .notCapturing
    public private(set) var origin: CaptureRunOrigin = .none
    /// An extension proved itself on this process's bus in the run under way.
    public private(set) var attachedThisRun = false
    /// …and its connection closed since, while this process ran.
    public private(set) var detachedThisRun = false
    /// When the current stretch of "connected, bus held, no extension" began.
    public private(set) var unattachedSince: Date?
    public private(set) var automaticRestart: CaptureAutomaticRestart = .available
    /// A person or an agent asked for a start or a stop while capture ran in
    /// this stretch: what they asked for stands.
    public private(set) var requestedThisStretch = false
    /// The update's extension swap has returned (or there was none). Until
    /// then capture is never restarted: the old extension may be mid-swap.
    public private(set) var updateResetFinished = false
    /// The pane's line, until it is dismissed.
    public private(set) var notice: CaptureReattachNotice?
    /// What ReqRes's own restart already did in this stretch.
    public private(set) var restartTriedThisStretch: CaptureStretchRestart?
    /// When the reattach behind `.attached`'s counts was honoured.
    public private(set) var reattachedAt: Date?
    public let launchedAt: Date

    /// Refusals before this are not about the run under way.
    private var refusalsCountFrom: Date
    /// A reattach reported before NetworkExtension said the tunnel is
    /// connected: honoured once it does, dropped if it says down.
    private var pendingReport: PendingReport?
    private var lastBusRetry: Date?
    /// Hellos in the run under way.
    private var hellosThisRun = 0
    /// When the current attachment began — its hello, or the first look
    /// that saw it.
    private var attachmentStartedAt: Date?
    /// The automatic restart's start was sent: its note waits for the
    /// restarted capture to read connected.
    private var restartedRunPending: CaptureDeliveryProblem?
    /// The refusal dated within the stretch, at its last look — words only.
    private var stretchRefusal: CaptureBusRefusal?

    private struct PendingReport: Equatable, Sendable {
        let report: CaptureReattachReport
        let captured: Int
    }

    public init(launchedAt: Date) {
        self.launchedAt = launchedAt
        self.refusalsCountFrom = launchedAt
    }

    // MARK: Events

    /// The launch read found the tunnel up: the run is not this process's.
    /// Call it before the status it read is shown.
    public mutating func tunnelWasUpAtLaunch() {
        origin = .predatesProcess
    }

    /// This process sent a start. Its own restart's start keeps the stretch
    /// (and its one restart); any other is a new run, which makes the notes
    /// about the last one stale.
    public mutating func startSent(at now: Date) {
        origin = .startedHere
        attachedThisRun = false
        detachedThisRun = false
        hellosThisRun = 0
        attachmentStartedAt = nil
        unattachedSince = nil
        pendingReport = nil
        stretchRefusal = nil
        reattachedAt = nil
        refusalsCountFrom = now
        if case .inFlight = automaticRestart { return }
        notice = nil
        restartedRunPending = nil
        restartTriedThisStretch = nil
    }

    /// A person or an agent asked for a start, a stop or a restart, with the
    /// tunnel as last reported. While capture runs (or is on its way on or
    /// off) it stands the automatic restart down for the stretch; one made
    /// while capture is off — or not yet reported — is about no later run (a
    /// start it sends begins a run of this process's own, `startSent`). A
    /// restart already under way stands down by itself (`CaptureRestart.step`).
    public mutating func userRequested(tunnel: CaptureTunnelState?) {
        guard let tunnel, !tunnel.isDown else { return }
        requestedThisStretch = true
    }

    /// An extension proved itself on this process's bus: the core passes its
    /// `hello` on once it accepted it. Each one begins an attachment, and a
    /// second in a run means the connection closed and came back in between
    /// — the core redials within a quarter of a second, between two looks.
    public mutating func extensionSaidHello(at now: Date) {
        hellosThisRun += 1
        attachedThisRun = true
        attachmentStartedAt = now
        if hellosThisRun > 1 {
            detachedThisRun = true
            // A refusal from before this is not about a later loss.
            refusalsCountFrom = max(refusalsCountFrom, now)
        }
    }

    /// The update's extension swap returned (`forceResetExtensionAfterUpdate`).
    public mutating func extensionSwapFinished() {
        updateResetFinished = true
    }

    public mutating func dismissNotice() {
        notice = nil
    }

    /// The restart this machine asked for ended.
    public mutating func automaticRestartFinished(_ outcome: CaptureRestartOutcome) {
        guard case .inFlight(let problem) = automaticRestart else { return }
        automaticRestart = .used
        switch outcome {
        case .startSent:
            // Said once the restarted capture reads connected; if it never
            // does, that is said instead (`endRun`).
            restartedRunPending = problem
            restartTriedThisStretch = .restarted
        case .failed(let failure):
            notice = .automaticRestartFailed(failure)
            restartTriedThisStretch = .failed(failure)
        case .nothingToRestart, .stoodDown, .notSent, .noLongerNeeded:
            break
        }
    }

    /// The extension reported a reattach. Honoured only while the tunnel
    /// reads connected; while its status is unknown or still moving the report
    /// waits for the next look, and a tunnel that is down or stopping drops it.
    public mutating func reattachReported(_ report: CaptureReattachReport, capturedWhileDetached: Int,
                                          tunnel: CaptureTunnelState?, now: Date) -> [Action] {
        switch tunnel {
        case .connected?:
            pendingReport = nil
            // Reported before a look saw this run come up: it is the run, so
            // that look must not take the note for the last run's.
            runCameUp()
            return honour(report, captured: capturedWhileDetached, now: now)
        case nil, .connecting?, .reasserting?:
            pendingReport = PendingReport(report: report, captured: capturedWhileDetached)
            return []
        case .invalid?, .disconnected?, .disconnecting?:
            pendingReport = nil
            return []
        }
    }

    // MARK: The look

    /// Records one look and returns what to do about it.
    public mutating func look(_ facts: CaptureReattachFacts, now: Date) -> [Action] {
        // Not reported yet: nothing is decided and nothing is reset.
        guard let tunnel = facts.tunnel else {
            state = .notCapturing
            return []
        }
        if tunnel.isDown {
            state = .notCapturing
            unattachedSince = nil
            // A start this process sent has not been reported moving: this
            // "down" is the stop before it, read late — the start's run goes
            // on, with its origin, its stretch and its notes.
            if facts.startInFlight { return [] }
            pendingReport = nil
            lastBusRetry = nil
            // A refusal from before this is not about whatever runs next.
            refusalsCountFrom = max(refusalsCountFrom, now)
            // This machine's own restart stopped it: the stretch, its one
            // restart and its notes go on.
            if case .inFlight = automaticRestart { return [] }
            endRun()
            return []
        }
        runCameUp()
        var actions: [Action] = []
        switch tunnel {
        case .connected:
            // ReqRes's own restart brought capture back: said now, not when
            // its start was merely sent.
            if let problem = restartedRunPending {
                restartedRunPending = nil
                notice = .restartedAutomatically(problem)
            }
            actions = lookAtConnected(facts, now: now)
            // A reattach that arrived before NetworkExtension said
            // connected: it says so now.
            if let pending = pendingReport {
                pendingReport = nil
                actions += honour(pending.report, captured: pending.captured, now: now)
            }
        case .disconnecting:
            pendingReport = nil
            fallthrough
        default:
            // Starting, stopping or reasserting: nothing to report on, and
            // the stretch is not timed.
            unattachedSince = nil
            state = .notCapturing
        }
        return actions
    }

    /// The tunnel reads connected.
    private mutating func lookAtConnected(_ facts: CaptureReattachFacts, now: Date) -> [Action] {
        guard facts.holdsBus else {
            // No bus, no rows — and no grace: nothing can arrive. Never a
            // restart from here; the bind is tried again instead.
            unattachedSince = nil
            state = facts.anotherCopyRunning ? .otherCopyHoldsBus : .notReaching(.notListening)
            let due = lastBusRetry.map { now.timeIntervalSince($0) >= Self.busRetryInterval || now < $0 } ?? true
            guard due else { return [] }
            lastBusRetry = now
            return [.retryBusBind]
        }
        lastBusRetry = nil
        if facts.extensionAuthenticated {
            attachedThisRun = true
            unattachedSince = nil
            stretchRefusal = nil
            let since = attachmentStartedAt ?? now
            attachmentStartedAt = since
            // An attachment that has lasted ends the stretch: a later loss
            // may be restarted again, what was asked for before it is
            // history, and what the restart left said is moot. One dropped
            // sooner is the same stretch — no second automatic restart.
            if now.timeIntervalSince(since) >= Self.stableAttachment {
                requestedThisStretch = false
                restartTriedThisStretch = nil
                if case .automaticRestartFailed? = notice { notice = nil }
                if case .inFlight = automaticRestart {} else { automaticRestart = .available }
            }
            if case .attached = state {} else { state = .attached(capturedWhileClosed: 0, droppedRows: 0) }
            return []
        }
        // Connected, bus held, no extension. Attached earlier in this run and
        // a new stretch beginning: its connection closed while this process
        // ran — and a refusal from before is not about this loss.
        if attachedThisRun && unattachedSince == nil {
            detachedThisRun = true
            refusalsCountFrom = max(refusalsCountFrom, now)
        }
        attachmentStartedAt = nil
        let since = unattachedSince ?? now
        unattachedSince = since
        let refusal = currentRefusal(facts)
        stretchRefusal = refusal
        guard now.timeIntervalSince(since) >= Self.grace else {
            state = .reconnecting(since: since)
            return []
        }
        let problem = Self.problem(refusal: refusal, origin: origin, attachedEarlierThisRun: attachedThisRun)
        state = .notReaching(problem)
        guard mayRestartAutomatically else { return [] }
        automaticRestart = .inFlight(problem)
        return [.restartCapture(problem)]
    }

    /// Whether this stretch may still be restarted by ReqRes itself: once,
    /// not after a person or an agent asked for something, not before the
    /// update's swap returned, and not for a run this process started that
    /// never attached — restarting that would only repeat it.
    public var mayRestartAutomatically: Bool {
        automaticRestart == .available
            && !requestedThisStretch
            && updateResetFinished
            && (origin != .startedHere || attachedThisRun)
    }

    // MARK: What the surfaces show

    /// The verdict the pane, the menu bar item and the agent bridge render.
    public var delivery: CaptureDelivery {
        switch state {
        case .notCapturing: return .notCapturing
        case .reconnecting:
            // A start this process sent that has not attached yet is the
            // first moments of that start, not a reconnection.
            if origin == .startedHere && !detachedThisRun { return .waiting }
            // Nor is a capture whose extension was refused for a reason no
            // redial gets past within the stretch: started without the key
            // (System Settings, scutil), or an earlier build's, which never
            // redials. Words only — the restart does not read it.
            if stretchRefusal == .noCredential || stretchRefusal == .unboundHello { return .waiting }
            return .reconnecting
        case .attached: return .receiving
        case .notReaching(let problem): return .notReceiving(problem)
        case .otherCopyHoldsBus: return .anotherCopy
        }
    }

    /// The counts the agent bridge reports with `.receiving`: the reattach
    /// that brought the run here, for `reattachReportWindow` after it.
    public func reattachCounts(at now: Date) -> CaptureReattachCounts? {
        guard case let .attached(captured, dropped) = state, captured > 0 || dropped > 0,
              let reattachedAt, now.timeIntervalSince(reattachedAt) < Self.reattachReportWindow else { return nil }
        return CaptureReattachCounts(captured: captured, droppedRows: dropped)
    }

    /// The best explanation available — words only: the decision to restart
    /// never reads it.
    ///
    /// `unboundHello` is a fact (it takes this install's credential) and says
    /// the most. A refused hello with no proof or a wrong one is the next
    /// best evidence, though any local process could have sent it. An
    /// extension that was attached earlier in this run lost its connection; a
    /// run from before launch is the relaunch; what is left is a connection
    /// that never identified itself, or nothing at all.
    public static func problem(refusal: CaptureBusRefusal?, origin: CaptureRunOrigin, attachedEarlierThisRun: Bool) -> CaptureDeliveryProblem {
        switch refusal {
        case .unboundHello?: return .earlierExtension
        case .noCredential?: return .startedOutsideReqRes
        case .badProof?: return .otherInstall
        case .noHello?, .timedOut?, nil: break
        }
        if attachedEarlierThisRun { return .connectionLost }
        if origin == .predatesProcess { return .appRelaunched }
        return refusal == nil ? .unexplained : .silentConnection
    }

    // MARK: Private

    /// The tunnel is up. A run with no origin yet is one this process did not
    /// start, come up since the last ended: whatever the pane said about the
    /// last one is history.
    private mutating func runCameUp() {
        guard origin == .none else { return }
        origin = .startedElsewhere
        notice = nil
    }

    private func currentRefusal(_ facts: CaptureReattachFacts) -> CaptureBusRefusal? {
        guard let refusal = facts.refusal else { return nil }
        if let date = facts.refusalDate, date < refusalsCountFrom { return nil }
        return refusal
    }

    private mutating func honour(_ report: CaptureReattachReport, captured: Int, now: Date) -> [Action] {
        let captured = max(0, captured)
        if case .attached = state {
            state = .attached(capturedWhileClosed: captured, droppedRows: report.droppedRows)
            reattachedAt = now
        }
        // The extension kept this run while no app received it: the app was
        // closed (or the copy receiving it was) unless this process saw the
        // connection close — or a second hello. Nothing kept and nothing
        // lost: nothing to say.
        if captured > 0 || report.droppedRows > 0 {
            notice = .reattached(capturedWhileDetached: captured, droppedRows: report.droppedRows,
                                 appWasClosed: !detachedThisRun)
        }
        return [.adoptRunningCapture(proxyPort: report.proxyPort, startedAt: report.runStartedAt)]
    }

    /// The run ended (the tunnel was seen down — not by this machine's own
    /// restart, and not as a late notification): its notes go with it,
    /// unless they say why capture is off, and a restart whose capture never
    /// came up says so now.
    private mutating func endRun() {
        if let current = notice, !current.outlivesTheRun { notice = nil }
        // The restart's capture never read connected — unless someone asked
        // for a stop (or anything else) while it came up: then that is why.
        if restartedRunPending != nil, !requestedThisStretch { notice = .automaticRestartDidNotStart }
        restartedRunPending = nil
        origin = .none
        attachedThisRun = false
        detachedThisRun = false
        hellosThisRun = 0
        attachmentStartedAt = nil
        automaticRestart = .available
        requestedThisStretch = false
        restartTriedThisStretch = nil
        stretchRefusal = nil
        reattachedAt = nil
    }
}
