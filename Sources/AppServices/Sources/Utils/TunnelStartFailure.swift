//
//  TunnelStartFailure.swift
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
//  Why the extension refused a capture start, worded (build 53, core 95062d1).
//
//  The core used to `fatalError` when a start found no ReqRes app listening,
//  and its old entry point still maps every failure to nil — which the
//  extension then reported as a busy port ("Another app may be using the
//  port…") whatever the cause. `MitmService.prepareCapture` says why now; the
//  extension (`PacketTunnelProvider`) maps each reason here.
//
//  The words travel as the error's DESCRIPTION, set explicitly
//  (`NSLocalizedDescriptionKey`): the error crosses from the extension to
//  NetworkExtension and to whoever reads it — System Settings, the app's
//  "Capture did not start" alert (`fetchLastDisconnectError`) — and a Swift
//  error's own description stays behind in the extension's process. Whether
//  NetworkExtension keeps a description set this way is not measured, so the
//  app also reads the reason back from the domain and code
//  (`init(readBack:)`), which every NSError keeps.
//

import Foundation

public enum TunnelStartFailure: Equatable, Sendable {
    /// The tunnel was started without ReqRes's start options — from System
    /// Settings ▸ VPN, scutil, or the system restarting it — while no ReqRes
    /// app was listening: nothing could ever receive what it captured.
    case startedOutsideReqRes
    /// The extension could not read or create its proxy's settings in its
    /// own database (the error's description).
    case settingsUnreadable(String)
    /// The core saw capture stopped while this start was being prepared —
    /// by something other than NetworkExtension's stop, which overtakes a
    /// start silently. Said, rather than leaving NetworkExtension waiting for
    /// an answer that never comes.
    case interrupted
    /// A reason a later core adds (its `StartFailure` is a resilient enum),
    /// described as the core describes it.
    case failed(String)

    public static let errorDomain = "com.oloapps.ReqRes.vpn-tunnel.start"

    public var code: Int {
        switch self {
        case .startedOutsideReqRes: return 1
        case .settingsUnreadable: return 2
        case .interrupted: return 3
        case .failed: return 4
        }
    }

    /// What the person reads. Each starts with what to do.
    public var message: String {
        switch self {
        case .startedOutsideReqRes:
            return "Start capture from ReqRes. Capture was started from System Settings or another tool while ReqRes was not open, so nothing could receive what it captures."
        case .settingsUnreadable(let detail):
            let reason = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Start capture from ReqRes again. Its extension could not read its capture settings"
                + (reason.isEmpty ? "." : " (\(reason)).")
                + " If it keeps failing, restart the Mac."
        case .interrupted:
            return "Start capture from ReqRes again. Capture was stopped while this start was being prepared."
        case .failed(let detail):
            let reason = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Start capture from ReqRes again. Its extension could not start capturing"
                + (reason.isEmpty ? "." : " (\(reason)).")
        }
    }

    /// Whether crash reporting hears of it: a start from System Settings is
    /// the person's choice, not a fault.
    public var isReportable: Bool {
        self != .startedOutsideReqRes
    }

    /// The error the extension hands NetworkExtension, its description set.
    public var error: NSError {
        NSError(domain: Self.errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Read back where it arrives

extension TunnelStartFailure {
    /// The failure an error the extension handed NetworkExtension stands
    /// for, read back where it arrives — the app, through
    /// `fetchLastDisconnectError` — by its domain and code, which survive the
    /// trip whatever becomes of the description. Nil for any other error.
    public init?(readBack error: NSError) {
        guard error.domain == Self.errorDomain else { return nil }
        switch error.code {
        case 1: self = .startedOutsideReqRes
        case 2: self = .settingsUnreadable("")
        case 3: self = .interrupted
        case 4: self = .failed("")
        default: return nil
        }
    }

    /// "Capture did not start"'s message for the error the system kept. When
    /// the extension said why, its words alone: they are about the start, not
    /// the port, so the busy-port advice does not lead them (it used to, for
    /// every failure) — the description as it was set when it survived the
    /// trip, else the words its code stands for. Any other error keeps the
    /// port's message, with the system's reason when it gave one worth
    /// reading.
    public static func didNotStartMessage(port: Int, error: NSError?) -> String {
        if let error, let failure = TunnelStartFailure(readBack: error) {
            return ProxyPortSetting.startFailedReason(for: error) ?? failure.message
        }
        return ProxyPortSetting.startFailedMessage(port: port, reason: error.flatMap(ProxyPortSetting.startFailedReason(for:)))
    }
}
