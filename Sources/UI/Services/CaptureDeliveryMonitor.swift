//
//  CaptureDeliveryMonitor.swift
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
//  Whether what capture records reaches THIS app (F11, 2026-09-30), and the
//  reattach of a capture that outlived it (build 53, core 95062d1).
//
//  The decisions are `CaptureReattach` (Utils, tested as a table); this
//  gathers its facts — the tunnel's status, this process's hold on the
//  message bus, whether an extension has proved itself on it, the bus's last
//  refusal, another copy of ReqRes running — feeds it the events the bus and
//  the app deliver (a reattach reported, a start sent, a person's request,
//  the update's extension swap returning), and does what it asks: restart
//  capture once, try the bus again, adopt the running capture's port and
//  start. It publishes the verdict for the traffic pane, the menu bar item and
//  the agent bridge, and the pane's one-line note.
//
//  Looked at when the tunnel's status changes, when an extension says hello
//  or reports, and once a second while the tunnel is connected: the core
//  offers no callback for a refusal or for the extension's connection
//  closing, and a look is a few locked reads. No timer runs while capture is
//  off.
//

import AppKit
import Combine
import MCPKit
import NetworkExtension
import Utils
import XReqResCore

@MainActor
final class CaptureDeliveryMonitor: ObservableObject {
    static let shared = CaptureDeliveryMonitor()

    /// The verdict; published only when it changes.
    @Published private(set) var delivery: CaptureDelivery = .notCapturing
    /// A Restart Capture is under way (the pane says so instead of flashing
    /// through "Start Monitoring" while the tunnel is briefly down).
    @Published private(set) var isRestarting = false
    /// Why ReqRes is restarting capture by itself, while it does; nil for a
    /// restart someone asked for.
    @Published private(set) var automaticRestartProblem: CaptureDeliveryProblem?
    /// The pane's one line (`CaptureReattachNotice`), until it is dismissed.
    @Published private(set) var notice: CaptureReattachNotice?
    /// What ReqRes's own restart already did in this stretch — said inside
    /// "Capture is on, but ReqRes isn't receiving it", which hides the note.
    @Published private(set) var restartTried: CaptureStretchRestart?

    private var machine = CaptureReattach(launchedAt: Date())
    /// The tunnel's status has been read from the system (the launch read, or
    /// a status notification). Until then the display's initial "off" is not
    /// a report, and nothing is decided from it.
    private var tunnelStatusKnown = false
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    /// How often a connected tunnel is looked at. A second is enough to say
    /// "not receiving" within a second of the grace running out.
    private static let lookInterval: TimeInterval = 1

    private init() {}

    /// Once, from `AppController.openCaptureChannel`.
    func start() {
        guard !started else { return }
        started = true
        // `@Published` emits BEFORE the property changes, so the look is
        // taken on the next turn of the run loop, when it has.
        AppState.shared.$vpnStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: Events

    /// The tunnel's status has been read from the system — the launch read,
    /// or a status notification. Call it before the status is shown.
    func tunnelStatusRead() {
        guard !tunnelStatusKnown else { return }
        tunnelStatusKnown = true
        // The status read may equal the display, which then publishes nothing.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// The launch check found the tunnel up: the run is not this process's,
    /// so the extension that delivered to the last app is expected to redial.
    func tunnelWasUpAtLaunch() {
        machine.tunnelWasUpAtLaunch()
    }

    /// This process sent a start (`AppController.startTunnel`): the run that
    /// follows is its own, with a new grace — known at the send, not left to
    /// a look that may never see the tunnel down in between (F11 review).
    func startSent() {
        machine.startSent(at: Date())
        publish()
        // A "down" read while the start is in flight is not the run's end
        // (`CaptureReattachFacts.startInFlight`); one more look once that
        // window has passed, so a start the system never reported moving
        // still ends its run — nothing else looks at a tunnel that stays down.
        DispatchQueue.main.asyncAfter(deadline: .now() + CaptureControl.startInFlightWindow + 0.25) { [weak self] in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
    }

    /// A person or an agent asked for a start, a stop or a restart
    /// (`AppController.noteCaptureRequest`, `restartCapture`): while capture
    /// runs, what they asked for stands, and ReqRes does not restart capture
    /// by itself in this stretch. One made while capture is off is about no
    /// later run (`CaptureReattach.userRequested`).
    func captureRequested() {
        machine.userRequested(tunnel: reportedTunnel())
    }

    /// An extension proved itself on the bus (its `hello`, from
    /// `AppController`'s bus delegate): an attachment begins — a second one in
    /// a run is a reconnection however quick — and the look that follows says
    /// so at once, rather than at the next tick.
    func extensionSaidHello() {
        machine.extensionSaidHello(at: Date())
        refresh()
    }

    /// The update's extension swap returned (`forceResetExtensionAfterUpdate`;
    /// at once on a launch with no update). Capture is never restarted by
    /// ReqRes itself before: the old extension may be being replaced.
    func updateResetFinished() {
        machine.extensionSwapFinished()
        refresh()
    }

    func dismissNotice() {
        machine.dismissNotice()
        publish()
    }

    /// A status_update arrived (`AppController`, after the bus thread closed
    /// the backlog's tally). A reattach's is honoured only while
    /// NetworkExtension says the tunnel is connected; before the status is
    /// known it waits for it.
    func statusUpdateReceived(reattach report: CaptureReattachReport?, capturedWhileDetached: Int) {
        guard let report else { return }
        AppLog.shared.notice("[CaptureDeliveryMonitor] the extension reattached: \(capturedWhileDetached, privacy: .public) request(s) delivered from while no app received them, \(report.droppedRows, privacy: .public) row(s) not kept")
        perform(machine.reattachReported(report, capturedWhileDetached: capturedWhileDetached, tunnel: reportedTunnel(), now: Date()))
        publish()
    }

    // MARK: The look

    /// Takes a look now and returns the verdict (published if it changed).
    @discardableResult
    func refresh() -> CaptureDelivery {
        let tunnel = reportedTunnel()
        let bus = AppController.tcpServerBus
        let holdsBus = bus.isServerListening()
        let rejected = bus.lastRejectedClient
        let facts = CaptureReattachFacts(
            tunnel: tunnel,
            holdsBus: holdsBus,
            // The only fact acted on (core 95062d1): the refusal below picks
            // words, never a restart.
            extensionAuthenticated: bus.hasAuthenticatedExtension,
            refusal: rejected.flatMap { CaptureBusRefusal(rawValue: $0.reason.rawValue) },
            refusalDate: rejected?.date,
            // Asked only when it decides something: capture on, bus not held.
            anotherCopyRunning: tunnel == .connected && !holdsBus && Self.anotherCopyRunning(),
            // A "down" read while a start from here has not been reported
            // moving is the stop before it, read late: the run goes on.
            startInFlight: AppController.shared.isStartInFlight
        )
        let actions = machine.look(facts, now: Date())
        publish()
        scheduleLooks(while: tunnel)
        perform(actions)
        return delivery
    }

    /// Stop capture and start it again from this app, so the extension
    /// connects to it. Offered only while `delivery.offersRestart`; a
    /// person's request (`AppController.restartCapture` says so).
    func restartCapture() {
        guard !isRestarting else { return }
        isRestarting = true
        AppController.shared.restartCapture { [weak self] _ in
            self?.isRestarting = false
            self?.refresh()
        }
    }

    /// What the agent bridge reports (capture_status, diagnose_setup): a
    /// fresh look, with the person-facing reason — and what ReqRes's own
    /// restart already did in this stretch. A reattach's counts ride on
    /// `receiving` for `CaptureReattach.reattachReportWindow` after it: an
    /// hour later they are not news.
    func bridgeFact() -> MCPCaptureDelivery {
        let verdict = refresh()
        switch verdict {
        case .receiving:
            if let counts = machine.reattachCounts(at: Date()) {
                return MCPCaptureDelivery(state: .receiving, capturedWhileDetached: counts.captured, droppedRows: counts.droppedRows)
            }
            return MCPCaptureDelivery(state: .receiving)
        case .waiting:
            return MCPCaptureDelivery(state: .waiting)
        case .reconnecting:
            return MCPCaptureDelivery(state: .reconnecting)
        case .notReceiving(let problem):
            let reason = CaptureDeliveryCopy.notReceivingDetail(for: problem, restartTried: machine.restartTriedThisStretch,
                                                                busPort: MessageBusPort)
            return MCPCaptureDelivery(state: .notReceiving, reason: reason, restartable: true)
        case .anotherCopy:
            // No reason: the check and the line say what is known themselves.
            return MCPCaptureDelivery(state: .otherCopy, restartable: false)
        case .notCapturing:
            return MCPCaptureDelivery(state: .notCapturing)
        }
    }

    /// Another process with this app's bundle identifier — a Debug build
    /// launched from Xcode beside the installed one, typically. Nonisolated:
    /// the start path asks it too.
    nonisolated static func anotherCopyRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    // MARK: The backlog's tally — on the bus's thread

    /// The requests a reattach delivers, counted where they arrive: the bus
    /// hands its delegate the hello, the backlog and the status_update in
    /// order on one thread (`AppController`).
    private nonisolated static let tally = ReattachTallyBox()

    /// The extension proved itself (`hello`).
    nonisolated static func busExtensionProvedItself() {
        tally.mutate { $0.extensionProvedItself() }
    }

    /// A row arrived (`send_session`, `session_started`), keyed by exchange.
    nonisolated static func busRowArrived(_ key: String) {
        tally.mutate { $0.row(key) }
    }

    /// A status_update arrived: the backlog's count, its window closed.
    nonisolated static func busStatusUpdateArrived() -> Int {
        tally.mutate { $0.statusUpdate() }
    }

    // MARK: Private

    /// The tunnel's status as the system last reported it; nil until this
    /// process has heard it.
    private func reportedTunnel() -> CaptureTunnelState? {
        tunnelStatusKnown ? CaptureTunnelState(AppState.shared.vpnStatus) : nil
    }

    private func publish() {
        let verdict = machine.delivery
        if verdict != delivery {
            AppLog.shared.notice("[CaptureDeliveryMonitor] delivery: \(String(describing: verdict), privacy: .public)")
            delivery = verdict
        }
        if machine.notice != notice { notice = machine.notice }
        if machine.restartTriedThisStretch != restartTried { restartTried = machine.restartTriedThisStretch }
    }

    private func perform(_ actions: [CaptureReattach.Action]) {
        for action in actions {
            switch action {
            case .restartCapture(let problem):
                restartAutomatically(because: problem)
            case .retryBusBind:
                // The copy that held the bus may be gone: listening here lets
                // the extension's redial find this copy (the core logs a
                // refusal of its own each time it is still taken).
                if AppController.shared.openMessageBus(quietly: true) {
                    AppLog.shared.notice("[CaptureDeliveryMonitor] now listening where the extension delivers; waiting for it to reconnect")
                    DispatchQueue.main.async { [weak self] in self?.refresh() }
                }
            case let .adoptRunningCapture(port, startedAt):
                // A capture this app did not start ran with whatever port the
                // app that started it had set, since whenever it started.
                if let port { CaptureProxyPort.runningCaptureReported(port: port) }
                if let startedAt { AppState.shared.adoptRunStart(startedAt) }
            }
        }
    }

    /// The one restart ReqRes makes by itself in a stretch: Restart Capture's
    /// stop → down → start, without its alerts — the person did not click
    /// anything, so how it ended is the pane's one line instead.
    private func restartAutomatically(because problem: CaptureDeliveryProblem) {
        guard !isRestarting else {
            // A person's restart is already under way: it is the restart.
            machine.automaticRestartFinished(.stoodDown)
            return
        }
        AppLog.shared.notice("[CaptureDeliveryMonitor] capture is not reaching ReqRes (\(problem.rawValue, privacy: .public)); restarting it once")
        isRestarting = true
        automaticRestartProblem = problem
        AppController.shared.restartCapture(completion: { [weak self] outcome in
            guard let self else { return }
            self.isRestarting = false
            self.automaticRestartProblem = nil
            AppLog.shared.notice("[CaptureDeliveryMonitor] the automatic restart ended: \(String(describing: outcome), privacy: .public)")
            self.machine.automaticRestartFinished(outcome)
            self.publish()
            self.refresh()
        }, automatic: true)
    }

    /// Looks once a second while the tunnel is connected; nothing otherwise.
    private func scheduleLooks(while tunnel: CaptureTunnelState?) {
        if tunnel == .connected {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: Self.lookInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}

/// `CaptureReattachTally` behind a lock: written on the bus's thread, read
/// nowhere else.
private final class ReattachTallyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tally = CaptureReattachTally()

    func mutate<T>(_ body: (inout CaptureReattachTally) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&tally)
    }
}
