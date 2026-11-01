//
//  HTTP2CaptureSync.swift
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
//  The "Capture HTTP/2 (beta)" switch reaching a RUNNING extension (decision
//  D11, protocol-engine doc §S9 and §C12.3). The tunnel's start options carry
//  it on every start (`VPNManager.tunnelStartOptions`); this sends the core's
//  `http2Changed` bus action on every change AND on every status update,
//  the rule the excluded hosts and the CA state follow — the extension is a
//  separate process, and a switch that silently stopped applying after a
//  restart is worse than none. The core reads it once per connection, at the
//  ClientHello, so an open connection keeps its protocol.
//
//  The value lives in the app's standard defaults (`HTTP2CaptureSetting`,
//  Utils) — never the app group, which the root extension would read as
//  root's copy.
//

import Foundation
import Utils
import XReqResCore

enum HTTP2CaptureSync {
    /// The user's choice, from the one place it is stored.
    static var isEnabled: Bool { HTTP2CaptureSetting.isEnabled(in: .standard) }

    /// Sends the current choice to the extension. Safe with no tunnel
    /// running — the bus drops it, and the next status update sends it again.
    static func push() {
        let enabled = isEnabled
        AppController.shared.notifyExtension(
            message: ServerBusMessage(action: .http2Changed, payload: ["data": HTTP2StatePayload(enabled: enabled)])
        )
        AppLog.shared.debug("[HTTP2CaptureSync] pushed HTTP/2 capture: \(enabled, privacy: .public)")
    }

    /// Where Utils' copy of the start option disagrees with the embedded
    /// core's `HTTP2Capture.startOptions(enabled:)`. Utils cannot see the core,
    /// so this is the only check that the key the app sends is the key the
    /// extension reads — a drift would leave every start "off" silently.
    static var startOptionDrift: [String] {
        [false, true].compactMap { enabled in
            let utils = HTTP2CaptureSetting.startOptions(enabled: enabled)
            let core = HTTP2Capture.startOptions(enabled: enabled)
            return NSDictionary(dictionary: utils).isEqual(to: core)
                ? nil
                : "enabled=\(enabled): Utils sends \(utils), the core reads \(core)"
        }
    }

    /// DEBUG builds only: stop at launch when the two disagree.
    static func assertMatchesCore() {
        #if DEBUG
        let drift = startOptionDrift
        if !drift.isEmpty {
            assertionFailure("HTTP2CaptureSetting drifted from the embedded core's HTTP2Capture — update Utils/HTTP2CaptureSetting.swift: " + drift.joined(separator: "; "))
        }
        #endif
    }
}
