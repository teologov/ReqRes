//
//  CaptureTunnelWatch.swift
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
//  What the app has seen its own capture tunnel do, from the status
//  notifications — two facts the proxy-port preflight needs (F10, 2026-09-30)
//  that a status alone does not keep:
//
//   * when the tunnel last went DOWN. For a moment after, a port that still
//     accepts is most likely ReqRes's own listener finishing its shutdown, and
//     is looked at again before it is called taken
//     (`ProxyPortAvailability.check(settling:)`).
//   * whether a start the APP asked for ended before the tunnel ever
//     connected. The preflight lets lingering connections through and the
//     extension's own bind is the last word; when the extension refuses, the
//     user used to see capture flip back off with nothing said.
//

import Foundation

public struct CaptureTunnelWatch: Equatable, Sendable {
    /// NEVPNStatus, as far as this needs it (Utils does not import
    /// NetworkExtension): `.invalid` and `.disconnected` are `.down`,
    /// `.reasserting` is `.connecting`.
    public enum Status: Equatable, Sendable {
        case down
        case connecting
        case connected
        case disconnecting
    }

    /// The last status the notifications gave; nil until the first.
    public private(set) var lastStatus: Status?
    /// When the tunnel last went down from any other status. The first status
    /// after launch is never a stop.
    public private(set) var stoppedAt: Date?
    /// A start the app asked for that has not yet connected, been stopped by
    /// the app, or failed.
    private var startAwaited = false
    /// Whether that start has been seen connecting: a `.down` before it is a
    /// late notification from the stop before, not this start failing.
    private var startSeenConnecting = false

    public init() {}

    /// The app asked the tunnel to start (`startVPNTunnel` returned).
    public mutating func startRequested() {
        startAwaited = true
        startSeenConnecting = false
    }

    /// The app asked it to stop: a start the app cancels is not a failure.
    public mutating func stopRequested() {
        startAwaited = false
    }

    /// Records a status notification. True when it ends a start the app asked
    /// for before the tunnel ever connected — once per start.
    @discardableResult
    public mutating func observe(_ status: Status, at now: Date) -> Bool {
        defer { lastStatus = status }
        switch status {
        case .connecting:
            if startAwaited { startSeenConnecting = true }
            return false
        case .connected:
            startAwaited = false
            return false
        case .disconnecting:
            // A failing start passes through here on its way down.
            return false
        case .down:
            if let lastStatus, lastStatus != .down { stoppedAt = now }
            guard startAwaited, startSeenConnecting else { return false }
            startAwaited = false
            return true
        }
    }

    /// Whether the tunnel went down less than `window` ago — or is going down
    /// as far as the notifications have said: the preflight runs once the
    /// manager already reads disconnected, and the notification saying so can
    /// still be queued behind it (the CA replacement's restart polls the
    /// manager and starts at once).
    public func stoppedRecently(now: Date, within window: TimeInterval = ProxyPortAvailability.settlingWindow) -> Bool {
        if let lastStatus, lastStatus != .down { return true }
        guard let stoppedAt else { return false }
        return now.timeIntervalSince(stoppedAt) < window
    }
}
