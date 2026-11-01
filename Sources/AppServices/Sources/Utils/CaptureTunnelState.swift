//
//  CaptureTunnelState.swift
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
//  The capture tunnel's status as the app SHOWS it and ACTS on it (F11,
//  2026-09-30).
//
//  When the app died while capture ran (a crash, Force Quit, Xcode's Stop),
//  the tunnel kept running, and the relaunched app got three things wrong:
//
//   * it showed capture OFF: the launch check wrote "disconnected" whatever
//     it found, and only a status CHANGE ever wrote the real status;
//   * its Start STOPPED the running capture: the button, ⌘⇧C and the agent's
//     start_capture all reached a toggle that branched on the tunnel's REAL
//     status — so the "Start" the user was shown did the opposite;
//   * its Quit neither asked nor stopped: the check read the wrong status.
//
//  The decisions behind those three live here, where `swift test` reaches
//  them: what a status read at launch is shown as, what a request to start or
//  stop does given the real status, and which process may stop capture when
//  it quits — and, for the Restart Capture that fixes a capture nothing
//  receives, what it does at each look between its stop and its start.
//

import Foundation

/// NEVPNStatus, mirrored by RAW VALUE (Utils does not import
/// NetworkExtension; `CaptureTunnelStateTests` pins every value against the
/// framework's). The app maps both ways through `rawValue`.
public enum CaptureTunnelState: Int, CaseIterable, Sendable {
    case invalid = 0
    case disconnected = 1
    case connecting = 2
    case connected = 3
    case reasserting = 4
    case disconnecting = 5

    /// Plainly off: no tunnel, or no configuration for one.
    public var isDown: Bool { self == .invalid || self == .disconnected }

    /// On its way somewhere: a start, a reconnect or a stop in progress. The
    /// capture controls are disabled in these, everywhere.
    public var isMoving: Bool {
        switch self {
        case .connecting, .reasserting, .disconnecting: return true
        case .invalid, .disconnected, .connected: return false
        }
    }

    /// What the app shows for a status it READ from the system — at launch,
    /// in a status notification, or when a request found the display wrong.
    ///
    /// Only `.invalid` changes: it is shown as `.disconnected`, so the capture
    /// button stays a usable Start (`.invalid` means "no configuration yet",
    /// and starting is what installs one). Everything else is shown as it is —
    /// above all `.connected`, which the launch check used to overwrite.
    public var displayed: CaptureTunnelState {
        self == .invalid ? .disconnected : self
    }
}

// MARK: - Start, stop, or neither

/// What a request to change capture MEANS, decided where the request is made
/// — before any asynchronous work, while the display the user acted on is
/// still the one they saw.
public enum CaptureIntent: Equatable, Sendable {
    case start
    case stop

    /// The capture button (toolbar, ⌘⇧C, the menu bar item): start what the
    /// user saw stopped, stop anything else they saw. The toggle used to
    /// decide from the tunnel's real status instead, which is exactly how a
    /// "Start" shown over a running capture stopped it.
    public static func toggle(shown: CaptureTunnelState) -> CaptureIntent {
        shown.isDown ? .start : .stop
    }
}

/// What the app does about a request, once it has read the real status.
public enum CaptureControlAction: Equatable, Sendable {
    case start
    case stop
    /// The request was made against a display that was wrong (or the tunnel
    /// is already moving): show the real status and do nothing else. Never the
    /// opposite of what was asked — a Start that stops, or a Stop that starts.
    case showRealStatus
    /// A start this process sent is on its way and the system has not said so
    /// yet, so the tunnel still READS down: nothing is sent — a second start
    /// into a starting tunnel is one of the shapes that wedges the extension —
    /// and the display, which already says connecting, is left alone (the
    /// status it would be corrected to is the stale one).
    case startAlreadySent
}

public enum CaptureControl {

    /// How long a start this process sent counts as on its way while the
    /// tunnel still reads down. The system reports a start within
    /// milliseconds; this only bounds one it never reports.
    public static let startInFlightWindow: TimeInterval = 5

    /// The one rule for acting on a request: a start only starts a tunnel that
    /// is down, a stop only stops one that is up. Anything else leaves the
    /// tunnel alone and corrects the display.
    ///
    /// A stop of a tunnel already `.disconnecting` is left to finish, and a
    /// start of one still disconnecting is not attempted — starting a tunnel
    /// mid-stop is how the extension got wedged in `Connecting` (measured,
    /// cleared only by a reboot).
    ///
    /// `startInFlight` (F11 review): this process sent a start the system has
    /// not reported yet (`startInFlight(sentAt:now:)`). Two requests made
    /// against the same "off" display — two quick clicks, or a click racing
    /// Restart Capture's own start — would otherwise both find the tunnel
    /// down and both send one.
    public static func action(for intent: CaptureIntent, real: CaptureTunnelState, startInFlight: Bool = false) -> CaptureControlAction {
        if startInFlight && real.isDown {
            // The tunnel is on its way up: a start is already sent, and a
            // stop stops it the way it stops a tunnel reading `.connecting`.
            return intent == .start ? .startAlreadySent : .stop
        }
        switch intent {
        case .start:
            return real.isDown ? .start : .showRealStatus
        case .stop:
            switch real {
            case .connecting, .connected, .reasserting: return .stop
            case .invalid, .disconnected, .disconnecting: return .showRealStatus
            }
        }
    }

    /// Whether a start sent at `sentAt` — cleared by the app when the system
    /// reports the tunnel moving — still counts as on its way at `now`.
    public static func startInFlight(sentAt: Date?, now: Date) -> Bool {
        guard let sentAt else { return false }
        let age = now.timeIntervalSince(sentAt)
        return age >= 0 && age < startInFlightWindow
    }

    /// Whether quitting THIS process asks "Quit ReqRes and stop capturing?"
    /// and then stops capture.
    ///
    /// Only for a tunnel that is not plainly off — a half-built tunnel left
    /// behind by a quit mid-connect is the shape that wedges the extension.
    /// And not in a copy of ReqRes that lacks the message bus while ANOTHER
    /// copy runs: that one holds the bus, the extension delivers to it, and a
    /// second copy — which now shows the real status — would otherwise stop
    /// the capture the first is receiving. With no other copy running, the
    /// tunnel is delivering to nobody (the copy that held the bus is gone),
    /// and a quit that left it running would leave every request on the Mac
    /// decrypted for no one — so this copy asks, and stops it (F11 review).
    public static func stopsCaptureOnQuit(real: CaptureTunnelState, holdsBus: Bool, anotherCopyRunning: Bool) -> Bool {
        !real.isDown && (holdsBus || !anotherCopyRunning)
    }
}

// MARK: - Restart Capture

/// What Restart Capture does next, at each look while it waits between its
/// stop and its start (F11 review).
public enum CaptureRestartStep: Equatable, Sendable {
    /// The stop is still under way.
    case wait
    /// The tunnel reads down: send the start.
    case start
    /// A start or stop was asked for since the restart began, or the tunnel
    /// came back up without this restart: that stands, and the restart sends
    /// nothing more. It used to start capture again regardless — undoing an
    /// agent's stop_capture made meanwhile — or wait out its 10 s on a tunnel
    /// someone else had started, showing "Restarting Capture…" all along.
    case standDown
    /// The stop did not finish in time: nothing is started.
    case giveUp
}

public enum CaptureRestart {
    /// How long the restart waits for its stop before it gives up.
    public static let stopTimeout: TimeInterval = 10
    /// How often it looks at the tunnel meanwhile.
    public static let lookInterval: TimeInterval = 0.25

    /// - Parameters:
    ///   - tunnel: the tunnel's real status at this look.
    ///   - sawStopping: an earlier look saw it disconnecting.
    ///   - requestedSince: a start or stop was asked for — a click, ⌘⇧C, the
    ///     menu bar item, an agent — since the restart began.
    ///   - elapsed: since the restart sent its stop.
    public static func step(tunnel: CaptureTunnelState, sawStopping: Bool, requestedSince: Bool, elapsed: TimeInterval) -> CaptureRestartStep {
        if requestedSince { return .standDown }
        if tunnel.isDown { return .start }
        // Up again after it was seen going down, and not by this restart —
        // it has sent no start yet: someone else started it.
        if sawStopping && tunnel != .disconnecting { return .standDown }
        return elapsed >= stopTimeout ? .giveUp : .wait
    }
}
