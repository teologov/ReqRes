//
//  CaptureProxyPort.swift
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
//  Which port ReqRes's proxy is on. The setting is `ProxyPortSetting` (Utils);
//  the start options carry it to the extension (core `ProxyPort`); everything
//  that prints or dials the proxy — the environment lines, the diagnosis,
//  replay, capture_status — reads `active`, so they never disagree with what is
//  actually listening.
//
//  Before a start, `conflict(port:)` asks whether another program holds the
//  port (`ProxyPortAvailability`, Utils). The tunnel's status notifications
//  are kept here too (`CaptureTunnelWatch`, Utils): the check needs to know
//  when ReqRes's own tunnel went down, and a start the extension refuses
//  anyway is said instead of capture silently flipping back off (F10).
//

import Foundation
import MCPKit
import NetworkExtension
import Utils
import XReqResCore

/// A port another program holds, found before capture started.
struct ProxyPortConflict: Identifiable, Equatable {
    let port: Int
    /// The holder's name, when the socket table can say (`ListeningPortOwner`).
    let holder: String?
    /// A free port to offer instead.
    let suggestion: Int?
    var id: Int { port }
}

enum CaptureProxyPort {
    /// The port Settings ▸ Capture says the next capture uses.
    static var configured: Int { ProxyPortSetting.current(in: .standard) }

    /// The port the running (or last) capture was started with, recorded by
    /// the one start-options builder.
    private static let lock = NSLock()
    private static var _started: Int?
    static var started: Int? {
        get { lock.withLock { _started } }
        set { lock.withLock { _started = newValue } }
    }

    /// What is listening now: the running capture's port while the tunnel is
    /// up, the configured one otherwise.
    static func active(tunnelUp: Bool) -> Int {
        tunnelUp ? (started ?? configured) : configured
    }

    /// The running capture's port, as its extension reported it when it
    /// reattached to this app (build 53, core 95062d1). A capture this app did
    /// not start — it outlived the last one — runs on whatever port the app
    /// that started it had set, which `started` cannot know: it is recorded by
    /// this process's own start. Without this, the environment lines, the
    /// diagnosis and replay named the configured port while the proxy
    /// listened elsewhere.
    static func runningCaptureReported(port: Int) {
        guard ProxyPortSetting.isAllowed(port) else { return }
        started = port
    }

    /// Nil when `port` is free on 127.0.0.1; otherwise who holds it and a
    /// free port to offer. Called on the main thread before capture starts,
    /// never while ReqRes itself listens there.
    ///
    /// Not a bare bind (F10, 2026-09-30): a bind as this user fails for a
    /// while after a stop because the stopped extension's closed connections
    /// are root's, which only root binds past; and it succeeds beside this
    /// user's own listener on the wildcard address. `ProxyPortAvailability`
    /// asks whether a listener answers as well, and just after a stop looks
    /// again at a port that still answers (ReqRes's own listener closing).
    /// The decision and the port offered instead are its `preflight`
    /// (Utils, tested); this only supplies the sockets and the socket table.
    /// Bounded for the main thread: a connect waits at most 0.3 s, the looks
    /// after a stop at most three more 0.3 s apart, and each port tried for
    /// the suggestion 50 ms.
    static func conflict(port: Int) -> ProxyPortConflict? {
        let settling = lock.withLock { _watch.stoppedRecently(now: Date()) }
        let preflight = ProxyPortAvailability.preflight(
            port: port,
            settling: settling,
            probes: .loopback(holder: holderName(listeningOn:)),
            candidates: .loopback(holder: holderName(listeningOn:),
                                  connectTimeout: ProxyPortAvailability.candidateConnectTimeout)
        )
        let finding = preflight.finding
        // Notice, not info: persisted, and shown by a plain `log stream`.
        if finding.verdict != .free || finding.looks > 1 {
            AppLog.shared.notice("[CaptureProxyPort] port \(port, privacy: .public): \(finding.summary, privacy: .public)")
        }
        guard preflight.isConflict else { return nil }
        return ProxyPortConflict(port: port, holder: finding.holder, suggestion: preflight.suggestion)
    }

    /// Who listens on `port`, when the socket table can say. Named with the
    /// App column's rule (`ProcessIdentity`, MCPKit): a tool inside Xcode's
    /// Developer folder (Apple's python3) is the tool, not "Xcode" — measured
    /// in the live check, where the core's own name for it was "Xcode".
    private static func holderName(listeningOn port: Int) -> String? {
        ListeningPortOwner.processPath(listeningOn: port, calibratingOn: MessageBusPort)
            .flatMap { ProcessIdentity(name: nil, pid: nil, executablePath: $0).displayName }
    }

    // MARK: The tunnel as the app has seen it (F10)

    /// When the tunnel last went down, and whether a start the app asked for
    /// is still waiting to connect (`CaptureTunnelWatch`, Utils).
    private static var _watch = CaptureTunnelWatch()

    /// The app asked the tunnel to start (`startVPNTunnel` returned).
    static func startRequested() {
        lock.withLock { _watch.startRequested() }
    }

    /// The app asked the tunnel to stop: a start it cancels is not a failure.
    static func stopRequested() {
        lock.withLock { _watch.stopRequested() }
    }

    /// Every status notification of the tunnel (`AppController.vpnDidChange`).
    /// True when it ends a start the app asked for before the tunnel ever
    /// connected — the extension refused it.
    static func tunnelStatusChanged(to status: NEVPNStatus) -> Bool {
        let seen: CaptureTunnelWatch.Status
        switch status {
        case .invalid, .disconnected: seen = .down
        case .connecting, .reasserting: seen = .connecting
        case .connected: seen = .connected
        case .disconnecting: seen = .disconnecting
        @unknown default: return false
        }
        return lock.withLock { _watch.observe(seen, at: Date()) }
    }
}
