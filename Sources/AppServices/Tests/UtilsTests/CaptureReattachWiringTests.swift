//
//  CaptureReattachWiringTests.swift
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
//  Build 53's wiring, read from the source: the extension's provider and the
//  app's bus delegate have no test target, and the core's contract for them
//  (95062d1) is a list of obligations — start through prepareCapture, end the
//  bus's search on every failure after it, never trap on a stop that overtakes
//  a start, honour a reattach only while connected, act only on an
//  authenticated extension, push the CA state last. The decisions themselves
//  are tested in CaptureReattachTests and TunnelStartFailureTests; these check
//  the code still asks them.
//

import XCTest

final class CaptureReattachWiringTests: XCTestCase {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
    }

    /// The file with `//` comments dropped, so a comment that quotes the old
    /// code is not mistaken for it.
    private func code(_ relative: String) throws -> String {
        let text = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(relative), encoding: .utf8)
        return text.components(separatedBy: "\n").map { line in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// From `signature` to the next member declared at the same indentation
    /// (or the end of the type), whichever comes first.
    private func body(of signature: String, in text: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found — renamed? Update this test.", file: file, line: line)
        let rest = text[start.upperBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    fileprivate func ", "\n    static func ", "\n    private static func ",
                    "\n    nonisolated ", "\n    override func ", "\n    @objc ", "\n    @MainActor", "\n    @discardableResult",
                    "\n    private nonisolated", "\n}\n"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return String(rest[..<(ends.min() ?? rest.endIndex)])
    }

    /// The `case` of a switch, up to the next `case` or `default:` at the
    /// same indentation.
    private func switchCase(_ label: String, in text: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let start = try XCTUnwrap(text.range(of: label), "\(label) not found", file: file, line: line)
        let rest = text[start.upperBound...]
        let lineStart = text[..<start.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let indent = String(text[lineStart..<start.lowerBound])
        let ends = ["\n\(indent)case ", "\n\(indent)default:", "\n\(indent)}"].compactMap { rest.range(of: $0)?.lowerBound }
        return String(rest[..<(ends.min() ?? rest.endIndex)])
    }

    private func assertOrder(_ needles: [String], in text: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var previous: String.Index?
        for needle in needles {
            let found = try XCTUnwrap(text.range(of: needle), "\(needle) not found — \(message)", file: file, line: line)
            if let previous { XCTAssertLessThan(previous, found.lowerBound, "\(needle) out of order — \(message)", file: file, line: line) }
            previous = found.lowerBound
        }
    }

    /// Each needle found AFTER the one before it — for needles that repeat
    /// (`assertOrder` finds each one's first occurrence).
    private func assertSequence(_ needles: [String], in text: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var from = text.startIndex
        for needle in needles {
            let found = try XCTUnwrap(text.range(of: needle, range: from..<text.endIndex),
                                      "\(needle) not found after the needle before it — \(message)", file: file, line: line)
            from = found.upperBound
        }
    }

    private let provider = "vpn-tunnel/PacketTunnelProvider.swift"
    private let controller = "UI/Controllers/AppController.swift"

    // MARK: - The extension's provider

    /// `prepareCapture`, which says why a start fails: the old `prepare`
    /// mapped every failure to nil, which the provider reported as a port.
    func testTheProviderStartsThroughPrepareCapture() throws {
        let source = try code(provider)
        XCTAssertTrue(source.contains("MitmService.prepareCapture(tunnelOptions: options)"))
        XCTAssertFalse(source.contains("MitmService.prepare(tunnelOptions:"))
        XCTAssertFalse(source.contains("Another app may be using the port"), "every failure read as a busy port")
        let mapping = try body(of: "static func tunnelStartFailure(", in: source)
        XCTAssertTrue(mapping.contains("case .startedOutsideReqRes: return .startedOutsideReqRes"))
        XCTAssertTrue(mapping.contains("case .stoppedBeforeStart: return .interrupted"))
        // The core's `StartFailure` has these two cases and no other: a start
        // whose proxy settings could not be read is no longer one of its
        // failures, so the mapping names no such case, and anything a later
        // core adds goes through `@unknown default`.
        XCTAssertFalse(mapping.contains("taskUnavailable"), "a case the core's StartFailure no longer has")
        XCTAssertEqual(mapping.components(separatedBy: "case .").count - 1, 2, "the two cases the core's StartFailure has")
        XCTAssertTrue(mapping.contains("@unknown default:"))
    }

    /// Nothing is force-unwrapped any more: a stop that came before any start
    /// had made a proxy trapped on `mitmServer.close()`, and one that
    /// overtook a start trapped on its nil completion.
    func testTheProviderForceUnwrapsNothingAStopCanClear() throws {
        let source = try code(provider)
        XCTAssertTrue(source.contains("var mitmServer: MitmService?"))
        XCTAssertFalse(source.contains("MitmService!"))
        XCTAssertFalse(source.contains("mitmServer.close()"))
        XCTAssertFalse(source.contains("mitmServer!"))
        XCTAssertTrue(source.contains("var pendingStartCompletion: ((Error?) -> Void)?"))
        XCTAssertFalse(source.contains("pendingStartCompletion: ((Error?) -> Void)!"))
        XCTAssertFalse(source.contains("pendingStartCompletion("), "called only through finishStart, optionally")
    }

    /// Every way capture ends after `prepareCapture` returned ends the bus's
    /// search for the app: closing the proxy (its `close()` calls
    /// `captureStopped`), or `captureStopped` itself when there is none —
    /// and never `tcpClientBus.stop()` (F9: the next start would hang).
    func testEveryEndOfCaptureEndsTheBussSearch() throws {
        let source = try code(provider)
        let end = try body(of: "private func endCapture()", in: source)
        try assertOrder(["if let server = mitmServer", "mitmServer = nil", "server.close()", "} else {", "MitmService.captureStopped()"],
                        in: end, "a proxy is closed, otherwise the search is ended directly")
        XCTAssertFalse(source.contains("tcpClientBus.stop"))

        let stop = try body(of: "override func stopTunnel(", in: source)
        try assertOrder(["startQueue.sync", "startGeneration &+= 1", "pendingStartCompletion = nil", "endCapture()"], in: stop,
                        "a stop invalidates the start under way, then ends the capture")

        let proxySet = try body(of: "private func systemProxySet(", in: source)
        try assertOrder(["if let error", "endCapture()", "finishStart(error)"], in: proxySet,
                        "setTunnelNetworkSettings failed: capture ended before the start fails")

        let ran = try body(of: "private func ran(", in: source)
        try assertOrder(["case .failure(let error):", "endCapture()", "finishStart(error)"], in: ran, "the proxy could not listen")
    }

    /// A step of a start a stop (or a later start) has overtaken does
    /// nothing; a proxy it made is closed only when no start has begun in the
    /// extension PROCESS since — NetworkExtension makes a provider object per
    /// session, and closing calls the process-wide `captureStopped`, which
    /// would end a later session's search for the app (review: the check was
    /// this provider's own).
    func testAnOvertakenStartIsLeftAlone() throws {
        let source = try code(provider)
        let prepared = try body(of: "private func prepared(", in: source)
        try assertOrder(["guard isCurrent(generation) else",
                         "PacketTunnelProvider.discardOvertaken(server, processStart: processStart)", "switch result"], in: prepared,
                        "nothing of an overtaken start is reported or run")
        for step in ["private func ran(", "private func systemProxySet("] {
            XCTAssertTrue(try body(of: step, in: source).contains("guard isCurrent(generation), mitmServer === server else { return }"), step)
        }
        let discard = try body(of: "private static func discardOvertaken(", in: source)
        XCTAssertTrue(discard.contains("CaptureStartLedger.process.ifNoStartSince(processStart) { server.close() }"), discard)
        XCTAssertFalse(discard.contains("pendingStartCompletion"), "this provider's own state cannot see a later session's start")
        XCTAssertEqual(source.components(separatedBy: "server.close()").count - 1, 2, "closed in discardOvertaken and in endCapture only")
        let current = try body(of: "private func isCurrent(", in: source)
        XCTAssertTrue(current.contains("generation == startGeneration && pendingStartCompletion != nil"))
        let start = try body(of: "override func startTunnel(", in: source)
        try assertOrder(["let processStart = CaptureStartLedger.process.begin()",
                         "startGeneration &+= 1", "pendingStartCompletion = completionHandler", "MitmService.prepareCapture",
                         "guard let self else", "PacketTunnelProvider.discardOvertaken(server, processStart: processStart)",
                         "self.prepared(result, generation: generation, processStart: processStart)"], in: start,
                        "each start has its own generation and its place in the process")
    }

    // MARK: - The app's bus delegate

    /// The hello opens the backlog's tally before the look; rows feed it by
    /// exchange; the status_update closes it and reads the reattach BEFORE
    /// the whole-state push.
    func testTheDelegateCountsTheBacklogAndReadsTheReattach() throws {
        let source = try code(controller)
        let hello = try switchCase("case .hello:", in: source)
        try assertOrder(["CaptureDeliveryMonitor.busExtensionProvedItself()", "CaptureDeliveryMonitor.shared.extensionSaidHello()"], in: hello,
                        "the window opens before anything else is looked at")
        let send = try switchCase("case .sendSession:", in: source)
        try assertOrder(["CaptureDeliveryMonitor.busRowArrived((session.exchangeID ?? session.id).uuidString)",
                         "SessionState.shared.addSession(session: session)"], in: send, "a final row counts")
        let started = try switchCase("case .sessionStarted:", in: source)
        XCTAssertTrue(started.contains("CaptureDeliveryMonitor.busRowArrived(started.exchangeID.uuidString)"))
        let status = try switchCase("case .statusUpdate:", in: source)
        try assertOrder(["CaptureDeliveryMonitor.busStatusUpdateArrived()",
                         "Self.reattachReport(fromStatusUpdate: data)",
                         "CaptureDeliveryMonitor.shared.statusUpdateReceived(reattach: reattach, capturedWhileDetached: capturedWhileDetached)",
                         "Task {"], in: status, "read before the push")
        let reader = try body(of: "static func reattachReport(fromStatusUpdate data: Data)", in: source)
        try assertOrder(["BusReattachStatus.from(statusUpdateFrame: data)", "CaptureReattachReport.from(statusUpdateFrame: data)"], in: reader,
                        "the core's reader first, Utils' lenient one after it")
        XCTAssertTrue(try body(of: "func booststrap(", in: source).contains("Self.assertReattachReaderMatchesCore()"))
    }

    /// Answered with the whole state, the CA's LAST: a start no app answered
    /// relays every new connection until it arrives, so the exclusions, the
    /// learned pins, the HTTP/2 switch and the breakpoints are in place first.
    func testTheCAStateIsPushedLast() throws {
        let status = try switchCase("case .statusUpdate:", in: try code(controller))
        try assertOrder(["await ExcludedHostsSettings.shared.push()",
                         "await LearnedPinsSettings.shared.push()",
                         "HTTP2CaptureSync.push()",
                         "BreakpointService.shared.push()",
                         "CAStateSync.push()"], in: status, "the CA's state goes last")
        XCTAssertEqual(status.components(separatedBy: "CAStateSync.push()").count - 1, 1)
    }

    /// A database read that fails is logged and skipped — never the reason
    /// the rest is not pushed (review: the hosts and rules were read with
    /// `try` at the top of the one do-block, so a failed read skipped the
    /// exclusions, the pins, HTTP/2, breakpoints and the CA state, and a start
    /// no app answered relayed every connection until the next start).
    func testAFailedReadSkipsNothingElse() throws {
        let status = try switchCase("case .statusUpdate:", in: try code(controller))
        try assertSequence(["do {", "try await ReqResCoreModelBridge.findAllHosts()", "} catch {",
                            "do {", "try await ReqResCoreModelBridge.findAllRules()", "} catch {",
                            "await ExcludedHostsSettings.shared.push()"], in: status, "each read in its own do-block")
        let afterTheReads = try XCTUnwrap(status.range(of: "await ExcludedHostsSettings.shared.push()"))
        let rest = status[afterTheReads.lowerBound...]
        XCTAssertFalse(rest.contains("try "), "nothing after the reads can throw past the CA push")
        XCTAssertFalse(rest.contains("catch"), "the pushes sit in no do-block")
        XCTAssertEqual(status.components(separatedBy: "try ").count - 1, 2, "the two reads are the only throwing calls")
    }

    /// Nothing the bus is told about the extension's state, or a refusal,
    /// decides anything: the look reads `hasAuthenticatedExtension`, the
    /// refusal is only passed on for words, and the restart is the machine's.
    func testOnlyAnAuthenticatedExtensionIsActedOn() throws {
        let monitor = try code("UI/Services/CaptureDeliveryMonitor.swift")
        XCTAssertTrue(monitor.contains("extensionAuthenticated: bus.hasAuthenticatedExtension"))
        XCTAssertFalse(monitor.contains("extensionState"), "the hello's claims decide nothing")
        let restart = try body(of: "private func restartAutomatically(", in: monitor)
        XCTAssertFalse(restart.contains("lastRejectedClient"))
        XCTAssertFalse(restart.contains("refusal"))
        XCTAssertTrue(monitor.contains("let actions = machine.look(facts, now: Date())"))
        XCTAssertTrue(monitor.contains("case .restartCapture(let problem):"))
    }

    /// A reattach is honoured with the tunnel's REPORTED status — nil until
    /// the system has said it, never the display's initial "off".
    func testAReattachIsHonouredWithTheReportedStatus() throws {
        let monitor = try code("UI/Services/CaptureDeliveryMonitor.swift")
        let received = try body(of: "func statusUpdateReceived(", in: monitor)
        XCTAssertTrue(received.contains("machine.reattachReported(report, capturedWhileDetached: capturedWhileDetached, tunnel: reportedTunnel(), now: Date())"))
        let reported = try body(of: "private func reportedTunnel()", in: monitor)
        XCTAssertTrue(reported.contains("tunnelStatusKnown ? CaptureTunnelState(AppState.shared.vpnStatus) : nil"))
        let source = try code(controller)
        let seed = try body(of: "func seedCaptureStatus()", in: source)
        try assertOrder(["CaptureDeliveryMonitor.shared.tunnelStatusRead()", "self.appModel.adoptTunnelStatus(connection.status"], in: seed,
                        "known before the launch reading is shown")
        let change = try body(of: "@objc func vpnDidChange(noti: Notification)", in: source)
        try assertOrder(["CaptureDeliveryMonitor.shared.tunnelStatusRead()", "appModel.adoptTunnelStatus(newStatus"], in: change,
                        "a status notification is a report too")
    }

    /// The running capture's port and start come from the reattach.
    func testTheRunningCapturesPortAndStartAreAdopted() throws {
        let monitor = try code("UI/Services/CaptureDeliveryMonitor.swift")
        let adopt = try switchCase("case let .adoptRunningCapture(port, startedAt):", in: monitor)
        XCTAssertTrue(adopt.contains("CaptureProxyPort.runningCaptureReported(port: port)"))
        XCTAssertTrue(adopt.contains("AppState.shared.adoptRunStart(startedAt)"))
        XCTAssertTrue(try code("UI/Models/AppState.swift").contains("func adoptRunStart(_ startedAt: Date)"))
        let port = try body(of: "static func runningCaptureReported(port: Int)", in: try code("UI/Services/CaptureProxyPort.swift"))
        try assertOrder(["guard ProxyPortSetting.isAllowed(port) else { return }", "started = port"], in: port, "only a real port")
    }

    // MARK: - Requests, restarts, the update

    /// Any person's or agent's request stands the automatic restart down —
    /// a click, ⌘⇧C, the menu, an agent, and a Restart Capture someone asked
    /// for; the automatic restart itself is nobody's request and raises no
    /// dialog.
    func testRequestsStandTheAutomaticRestartDown() throws {
        let source = try code(controller)
        let note = try body(of: "func noteCaptureRequest()", in: source)
        XCTAssertTrue(note.contains("CaptureDeliveryMonitor.shared.captureRequested()"))
        let restart = try body(of: "func restartCapture(completion:", in: source)
        try assertOrder(["if !automatic { CaptureDeliveryMonitor.shared.captureRequested() }", "guard openMessageBus() else"], in: restart,
                        "a person's restart is said before anything else")
        XCTAssertTrue(restart.contains("if !automatic, let failure { TrafficCommands.presentCaptureRestartFailed(failure) }"))
        XCTAssertTrue(restart.contains("completion?(.stoodDown)"))
        XCTAssertTrue(restart.contains("completion?(.nothingToRestart)"))
        let monitor = try code("UI/Services/CaptureDeliveryMonitor.swift")
        XCTAssertTrue(try body(of: "private func restartAutomatically(", in: monitor).contains("}, automatic: true)"))
    }

    /// No automatic restart until the update's extension swap has returned.
    func testTheSwapReturnsBeforeAnyAutomaticRestart() throws {
        let delegate = try code("UI/UIAppDelegate.swift")
        let launch = try body(of: "func applicationDidFinishLaunching(", in: delegate)
        try assertOrder(["await forceResetExtensionAfterUpdate()",
                         "CaptureDeliveryMonitor.shared.updateResetFinished()",
                         "AppController.shared.checkNetworkExtensionStatus()"], in: launch, "the swap first")
    }

    /// The copy without the bus tries it again, quietly.
    func testTheBusIsRetriedQuietly() throws {
        let monitor = try code("UI/Services/CaptureDeliveryMonitor.swift")
        let retry = try switchCase("case .retryBusBind:", in: monitor)
        XCTAssertTrue(retry.contains("AppController.shared.openMessageBus(quietly: true)"))
        let open = try body(of: "func openMessageBus(quietly: Bool = false)", in: try code(controller))
        XCTAssertTrue(open.contains("if quietly {"))
    }

    /// The agent bridge hears the new states, the counts for a while after a
    /// reattach, and what ReqRes's own restart already did.
    func testTheBridgeHearsReconnectingAndTheCounts() throws {
        let monitor = try code("UI/Services/CaptureDeliveryMonitor.swift")
        let fact = try body(of: "func bridgeFact()", in: monitor)
        XCTAssertTrue(fact.contains("case .reconnecting:"))
        XCTAssertTrue(fact.contains("if let counts = machine.reattachCounts(at: Date())"))
        XCTAssertTrue(fact.contains("MCPCaptureDelivery(state: .receiving, capturedWhileDetached: counts.captured, droppedRows: counts.droppedRows)"))
        XCTAssertFalse(fact.contains("machine.state"), "the counts only through the window")
        XCTAssertTrue(fact.contains("CaptureDeliveryCopy.notReceivingDetail(for: problem, restartTried: machine.restartTriedThisStretch,"))
    }

    // MARK: - The review of build 53

    /// The look feeds the machine what decides the stretch: the extension's
    /// hello (each one an attachment, a second a reconnection), the start in
    /// flight (a late "down" is not the run's end), and the tunnel a request
    /// was made against (one made while capture is off stands nothing down).
    func testTheMonitorFeedsTheMachineWhatDecidesTheStretch() throws {
        let monitor = try code("UI/Services/CaptureDeliveryMonitor.swift")
        let hello = try body(of: "func extensionSaidHello()", in: monitor)
        try assertOrder(["machine.extensionSaidHello(at: Date())", "refresh()"], in: hello, "recorded, then looked at")
        XCTAssertTrue(try body(of: "func refresh()", in: monitor).contains("startInFlight: AppController.shared.isStartInFlight"))
        XCTAssertTrue(try body(of: "func captureRequested()", in: monitor).contains("machine.userRequested(tunnel: reportedTunnel())"))
        let inFlight = try body(of: "var isStartInFlight: Bool", in: try code(controller))
        XCTAssertTrue(inFlight.contains("CaptureControl.startInFlight(sentAt: startSentAt, now: Date())"))
        XCTAssertTrue(try code(controller).contains("if !CaptureTunnelState(newStatus).isDown {\n           startSentAt = nil"),
                      "cleared only by the system's own report of the tunnel moving")
    }

    /// The automatic restart was decided a hop before it stops anything: an
    /// extension that reattached meanwhile is not cut (review).
    func testTheAutomaticRestartChecksTheExtensionBeforeItStops() throws {
        let restart = try body(of: "func restartCapture(completion:", in: try code(controller))
        try assertOrder(["guard running.contains(connection.status) else",
                         "if automatic && AppController.tcpServerBus.hasAuthenticatedExtension {",
                         "completion?(.noLongerNeeded)",
                         "connection.stopVPNTunnel()"], in: restart, "checked last, right before the stop")
    }

    /// "Capture did not start" says the extension's reason alone when it gave
    /// one; the port's advice only for the rest (review).
    func testCaptureDidNotStartSaysTheExtensionsReasonAlone() throws {
        let report = try body(of: "private func reportStartThatNeverConnected(", in: try code(controller))
        XCTAssertTrue(report.contains("TunnelStartFailure.didNotStartMessage(port: port, error: error as NSError?)"))
        XCTAssertTrue(report.contains("TrafficCommands.presentCaptureDidNotStart(message: message)"))
        let slots = try code("UI/Views/Toolbar/ReqResToolbarSlots.swift")
        let present = try body(of: "static func presentCaptureDidNotStart(message: String)", in: slots)
        XCTAssertTrue(present.contains("presentAlert(title: ProxyPortSetting.startFailedTitle, message: message)"))
        XCTAssertFalse(slots.contains("startFailedMessage(port:"), "the message is decided in one place")
    }

    /// The pane says what ReqRes's own restart is doing and already did: the
    /// banner over rows while it restarts (the spinner on a disabled button
    /// read as the person's own click), and the stretch's restart under the
    /// notice, banner and empty state alike.
    func testThePaneSaysWhatTheAutomaticRestartDid() throws {
        let view = try code("UI/Views/SessionContentView.swift")
        XCTAssertTrue(view.contains("CaptureDeliveryBanner(title: notice.title, detail: bannerDetail(fallback: notice.detail),"))
        let detail = try body(of: "private func bannerDetail(fallback: String)", in: view)
        try assertOrder(["if delivery.isRestarting, let problem = delivery.automaticRestartProblem",
                         "CaptureDeliveryCopy.automaticRestartingDetail(for: problem)",
                         "CaptureDeliveryCopy.notReceivingDetail(for: problem, restartTried: delivery.restartTried, busPort: MessageBusPort)"],
                        in: detail, "restarting first, then what it did")
        XCTAssertTrue(view.contains("CaptureDeliveryCopy.emptyStateDetail(for: problem, restartTried: delivery.restartTried,"))
    }
}
