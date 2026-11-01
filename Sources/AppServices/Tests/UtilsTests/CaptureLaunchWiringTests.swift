//
//  CaptureLaunchWiringTests.swift
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
//  The app-side wiring of F11 (2026-09-30), read from the source: Sources/UI
//  has no test target, and every one of these broke silently once — a status
//  guessed as "disconnected", an observer added per window, a Start that
//  toggled, a quit that read the display. The decisions themselves are tested
//  in CaptureTunnelStateTests and CaptureDeliveryTests; these check the app
//  still asks them.
//

import XCTest

final class CaptureLaunchWiringTests: XCTestCase {
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
    private func body(of signature: String, in text: String, file: StaticString = #filePath, line: UInt = #line) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found — renamed? Update this test.", file: file, line: line)
        let rest = text[start.upperBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    fileprivate func ", "\n    static func ", "\n    private static func ",
                    "\n    @objc ", "\n    @MainActor", "\n    @discardableResult", "\n}\n"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }

    // MARK: - The status is the tunnel's to say

    /// The launch check wrote "disconnected" for every outcome, `.ready`
    /// included — the relaunched app showed capture off while it ran.
    func testTheLaunchCheckSetsTheExtensionStateOnly() throws {
        let controller = try code("UI/Controllers/AppController.swift")
        let check = try body(of: "func checkNetworkExtensionStatus()", in: controller)
        XCTAssertFalse(check.contains("vpnStatus ="), "the extension check wrote the capture status")
        XCTAssertTrue(check.contains("appModel.extensionStatus = status"))
    }

    /// No path in the controller guesses "disconnected" any more: a failure
    /// to load or to reach something says nothing about the tunnel.
    func testTheControllerNeverGuessesDisconnected() throws {
        let controller = try code("UI/Controllers/AppController.swift")
        XCTAssertFalse(controller.contains("vpnStatus = .disconnected"))
        XCTAssertTrue(controller.contains("adoptTunnelStatus(newStatus, connectedDate: tunnelPS.connectedDate)"),
                      "status notifications are shown the way a launch reading is")
    }

    /// The tunnel's real status is read at launch without creating a
    /// configuration (which would put macOS's VPN prompt in front of someone
    /// who never asked to capture).
    func testTheLaunchReadingNeverCreatesAConfiguration() throws {
        let controller = try code("UI/Controllers/AppController.swift")
        let seed = try body(of: "func seedCaptureStatus()", in: controller)
        XCTAssertTrue(seed.contains("VPNManager.shared.loadExistingManager"))
        XCTAssertFalse(seed.contains("loadManager("))
    }

    // MARK: - Once per process, at launch

    /// Every appearing window used to add another status observer.
    func testTheStatusObserverIsAddedOnceFromTheCaptureChannel() throws {
        let controller = try code("UI/Controllers/AppController.swift")
        XCTAssertEqual(controller.components(separatedBy: "name: NSNotification.Name.NEVPNStatusDidChange").count - 1, 1)
        XCTAssertEqual(controller.components(separatedBy: "bindListeners()").count - 1, 2, "declared once, called once")
        let channel = try body(of: "func openCaptureChannel()", in: controller)
        XCTAssertTrue(channel.contains("bindListeners()"))
        XCTAssertTrue(channel.contains("guard !captureChannelOpened else { return }"))
        let bootstrap = try body(of: "func booststrap(completion: @escaping () -> Void)", in: controller)
        XCTAssertFalse(bootstrap.contains("bindListeners()"))
        XCTAssertFalse(bootstrap.contains("tcpServerBus.start("), "the bus opens with the channel, not with a window")
    }

    /// The channel opens in `applicationDidFinishLaunching`, before the
    /// update reset — not when the first window appears.
    func testTheChannelOpensAtLaunchBeforeTheUpdateReset() throws {
        let delegate = try code("UI/UIAppDelegate.swift")
        let launch = try body(of: "func applicationDidFinishLaunching(", in: delegate)
        let open = try XCTUnwrap(launch.range(of: "AppController.shared.openCaptureChannel()"))
        let reset = try XCTUnwrap(launch.range(of: "await forceResetExtensionAfterUpdate()"))
        XCTAssertLessThan(open.lowerBound, reset.lowerBound)
    }

    /// The database the channel opens is the one the core's bridge uses —
    /// not a second instance of the same file.
    func testTheControllerOpensTheBridgesDatabase() throws {
        let controller = try code("UI/Controllers/AppController.swift")
        XCTAssertTrue(controller.contains("let databaseManager: DatabaseManager = DatabaseManager.shared"))
        XCTAssertFalse(controller.contains("DatabaseManager(appGroupID:"))
    }

    // MARK: - Start means start

    /// The agent's start and stop, and the restarts, say what they mean; the
    /// toggle they called turned a Start into a stop when the display was
    /// wrong.
    func testCallersThatKnowWhatTheyMeanDoNotToggle() throws {
        let adapters = try code("UI/Services/MCPWriteAdapters.swift")
        XCTAssertFalse(adapters.contains("toggleVPNTunnel()"))
        XCTAssertTrue(adapters.contains("AppController.shared.startCapture()"))
        XCTAssertTrue(adapters.contains("AppController.shared.stopCapture()"))
        XCTAssertFalse(try code("UI/Services/CertificateAuthorityService.swift").contains("toggleVPNTunnel()"))
        let controller = try code("UI/Controllers/AppController.swift")
        let restart = try body(of: "func restartCapture(completion:", in: controller)
        XCTAssertTrue(restart.contains("self.act(on: .start, connection: connection)"))
        XCTAssertFalse(restart.contains("toggleVPNTunnel()"))
    }

    /// The capture button's command reads what the user saw at the click,
    /// before its asynchronous extension check — not after, when the launch
    /// reading may have changed the display under it.
    func testTheButtonDecidesAtTheClick() throws {
        let slots = try code("UI/Views/Toolbar/ReqResToolbarSlots.swift")
        let toggle = try body(of: "static func toggleCapture()", in: slots)
        let intent = try XCTUnwrap(toggle.range(of: "let intent = CaptureIntent.toggle(shown: CaptureTunnelState(AppState.shared.vpnStatus))"))
        let check = try XCTUnwrap(toggle.range(of: "await ExtensionStatusManager.shared.checkCompleteStatus()"))
        XCTAssertLessThan(intent.lowerBound, check.lowerBound)
        XCTAssertTrue(toggle.contains("AppController.shared.requestCapture(intent)"))
        XCTAssertFalse(toggle.contains("toggleVPNTunnel()"))
    }

    /// The toggle decides from what the user saw, before anything async runs.
    func testTheToggleDecidesFromTheDisplay() throws {
        let controller = try code("UI/Controllers/AppController.swift")
        let toggle = try body(of: "func toggleVPNTunnel()", in: controller)
        XCTAssertTrue(toggle.contains("CaptureIntent.toggle(shown: CaptureTunnelState(appModel.vpnStatus))"))
        let act = try body(of: "private func act(on intent: CaptureIntent", in: controller)
        XCTAssertTrue(act.contains("CaptureControl.action(for: intent, real: CaptureTunnelState(connection.status), startInFlight: inFlight)"))
    }

    // MARK: - Quit

    /// The quit read the display (off, after a relaunch) and neither asked
    /// nor stopped; it reads the tunnel, the bus, and whether another copy
    /// holds the capture.
    func testQuitReadsTheTunnelAndTheBus() throws {
        let delegate = try code("UI/UIAppDelegate.swift")
        let quit = try body(of: "private func quitStopsCapture()", in: delegate)
        XCTAssertTrue(quit.contains("CaptureControl.stopsCaptureOnQuit("))
        XCTAssertTrue(quit.contains("let holdsBus = AppController.tcpServerBus.isServerListening()"))
        XCTAssertTrue(quit.contains("anotherCopyRunning: !holdsBus && CaptureDeliveryMonitor.anotherCopyRunning()"))
        XCTAssertTrue(quit.contains("VPNManager.shared.manager?.connection.status"))
        XCTAssertFalse(delegate.contains("func isTunnelRunning()"))
    }

    // MARK: - The review's fixes

    /// The status checks only READ the configuration: the readiness poll
    /// (every 2 s until setup is done) and every activation used to create
    /// one, so after Don't Allow macOS asked again, and again. Only the two
    /// clicks create one.
    func testOnlyAClickCreatesTheConfiguration() throws {
        let controller = try code("UI/Controllers/AppController.swift")
        let check = try body(of: "public func isVPNConfigurationInstalled()", in: controller)
        XCTAssertTrue(check.contains("VPNManager.shared.loadExistingManager"))
        XCTAssertFalse(check.contains("loadManager"), "the status check creates a configuration again")

        let request = String(try body(of: "func requestCapture(_ intent: CaptureIntent)", in: controller))
        let install = String(try body(of: "public func installVPNConfiguration()", in: controller))
        XCTAssertTrue(install.contains("VPNManager.shared.loadManager"))
        XCTAssertTrue(request.contains("guard intent == .start else { return }"), "a start with no configuration creates one; a stop does not")
        var rest = controller
        for allowed in [request, install] { rest = rest.replacingOccurrences(of: allowed, with: "") }
        XCTAssertFalse(rest.contains("VPNManager.shared.loadManager {") || rest.contains("VPNManager.shared.loadManager({"),
                       "a configuration is created outside a click")

        let view = try code("UI/Views/SessionContentView.swift")
        XCTAssertTrue(view.contains("case .configurationMissing: installVPNConfiguration()"))
        XCTAssertTrue(view.contains("await ExtensionStatusManager.shared.installVPNConfiguration()"))
    }

    /// Restart Capture opens the bus BEFORE it stops anything — it used to
    /// stop and then be refused, leaving capture off — and says why when it
    /// cannot; it stands down for any request made meanwhile.
    func testTheRestartOpensTheBusFirstAndStandsDownForRequests() throws {
        let controller = try code("UI/Controllers/AppController.swift")
        let restart = String(try body(of: "func restartCapture(completion:", in: controller))
        let bus = try XCTUnwrap(restart.range(of: "guard openMessageBus() else"))
        let stop = try XCTUnwrap(restart.range(of: "connection.stopVPNTunnel()"))
        XCTAssertLessThan(bus.lowerBound, stop.lowerBound)
        XCTAssertTrue(restart.contains("finish(.channelUnavailable(anotherCopyRunning: anotherCopy))"))
        XCTAssertTrue(restart.contains("CaptureRestart.step("))
        XCTAssertTrue(restart.contains("requestedSince: self.captureRequests != requestsAtClick"))
        XCTAssertTrue(restart.contains("finish(.didNotStop)"))
        XCTAssertTrue(restart.contains("TrafficCommands.presentCaptureRestartFailed(failure)"))
        XCTAssertFalse(restart.contains("for _ in 0..<40"), "the fixed loop that ignored every request made meanwhile")

        let request = try body(of: "func requestCapture(_ intent: CaptureIntent)", in: controller)
        XCTAssertTrue(request.contains("noteCaptureRequest()"))
        let slots = try code("UI/Views/Toolbar/ReqResToolbarSlots.swift")
        let toggle = try body(of: "static func toggleCapture()", in: slots)
        let noted = try XCTUnwrap(toggle.range(of: "AppController.shared.noteCaptureRequest()"))
        let task = try XCTUnwrap(toggle.range(of: "Task {"))
        XCTAssertLessThan(noted.lowerBound, task.lowerBound, "noted at the click, before the asynchronous check")
        let adapters = try code("UI/Services/MCPWriteAdapters.swift")
        let agentStop = try body(of: "func stopCapture() throws", in: adapters)
        XCTAssertTrue(agentStop.contains("AppController.shared.noteCaptureRequest()"), "an agent's stop during a restart must stand it down")
    }

    /// A start is sent once: the controller remembers a start on its way until
    /// the system reports it, and a sent start begins a new run for the
    /// delivery verdict at the send.
    func testAStartIsSentOnceAndBeginsANewRun() throws {
        let controller = try code("UI/Controllers/AppController.swift")
        let start = try body(of: "private func startTunnel(_ connection: NEVPNConnection)", in: controller)
        let sent = try XCTUnwrap(start.range(of: "try connection.startVPNTunnel(options: options)"))
        let marked = try XCTUnwrap(start.range(of: "startSentAt = Date()"))
        let newRun = try XCTUnwrap(start.range(of: "CaptureDeliveryMonitor.shared.startSent()"))
        XCTAssertLessThan(sent.lowerBound, marked.lowerBound)
        XCTAssertLessThan(sent.lowerBound, newRun.lowerBound)
        let act = try body(of: "private func act(on intent: CaptureIntent", in: controller)
        XCTAssertTrue(act.contains("startInFlight: inFlight"))
        XCTAssertTrue(act.contains("case .startAlreadySent:"))
        let change = try body(of: "@objc func vpnDidChange(noti: Notification)", in: controller)
        XCTAssertTrue(change.contains("startSentAt = nil"))
    }

    /// What a person reads is said to a person: Diagnose Setup… and the menu
    /// bar item's tooltip used to show the agent's script.
    func testThePersonsSurfacesUseThePersonsWords() throws {
        let slots = try code("UI/Views/Toolbar/ReqResToolbarSlots.swift")
        XCTAssertTrue(slots.contains("MCPSetupDiagnosis.humanFixText(for: check)"))
        XCTAssertFalse(slots.contains("func humanVoiced("), "one re-voicing, in MCPKit, shared with the tooltip")
        XCTAssertTrue(slots.contains("case MCPCaptureDelivery.checkId where MCPCaptureDelivery.offersRestart(in: report):"))
        let menu = try code("UI/Views/MenuBar/ReqResStatusItemController.swift")
        XCTAssertTrue(menu.contains("self.cachedVerdict = MCPSetupDiagnosis.humanVerdict(report)"))
        XCTAssertFalse(menu.contains("self.cachedVerdict = report.verdict"))
    }

    // MARK: - The configuration load

    /// It called back only on success; now it is one coalesced load with a
    /// time-out, for the read and for the creation alike.
    func testTheConfigurationLoadAlwaysAnswers() throws {
        let manager = try code("vpn-manager/VPNManager.swift")
        XCTAssertTrue(manager.contains("CoalescedLoad<[NETunnelProviderManager]>(timeout: VPNManager.loadTimeout)"))
        XCTAssertTrue(manager.contains("CoalescedLoad<NETunnelProviderManager>(timeout: VPNManager.createTimeout)"))
        XCTAssertFalse(manager.contains("loadOrCreateDefaultWithCompletionHandler"))
        let load = try body(of: "func loadManager(", in: manager)
        XCTAssertTrue(load.contains("completionHandler?(nil, error)"), "a failed load answers")
    }
}
