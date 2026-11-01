//
//  HTTP2CaptureSetting.swift
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
//  The user's "Capture HTTP/2 (beta)" choice (decision D11, protocol-engine
//  doc §S9): OFF by default, and how it reaches the extension.
//
//  Stored in the APP's own defaults, never the app group: the extension runs
//  as ROOT and would read root's copy of the group defaults, not the user's
//  (the crash-reporting opt-out was lost exactly that way). It
//  crosses to the extension twice: in the tunnel's START OPTIONS on every
//  start (so a fresh extension begins with the user's choice), and as the
//  core's `http2Changed` bus action on every change and status update (so a
//  running extension switches without a restart). The core reads it once
//  per connection, at the ClientHello: existing connections keep their
//  protocol.
//
//  Utils cannot see the core, so `startOptionKey` is the core's
//  `HTTP2Capture.startOptionKey` spelled a second time; the app checks the
//  two are equal at launch in DEBUG (`HTTP2CaptureSync.assertMatchesCore`).
//

import Foundation

public enum HTTP2CaptureSetting {
    /// The app's defaults key. Absent means never chosen, which reads as OFF.
    public static let defaultsKey = "CaptureHTTP2Enabled"

    /// The key the core reads in the tunnel's start options
    /// (`XReqResCore.HTTP2Capture.startOptionKey`). An NSNumber bool; absent
    /// or unreadable is off on the core's side too.
    public static let startOptionKey = "reqres.http2.enabled"

    /// The stored choice. Unset is OFF: HTTP/2 capture is a beta, and an
    /// install that never saw the switch keeps today's HTTP/1.1 engine.
    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) == nil ? false : defaults.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    /// This setting's entry in the tunnel's start options — ALWAYS present,
    /// off included, so the extension never has to guess from an absence.
    public static func startOptions(enabled: Bool) -> [String: NSObject] {
        [startOptionKey: NSNumber(value: enabled)]
    }

    /// `options` with this setting's entry merged in (it wins over a stale
    /// value under the same key; every other key is kept) — how the app
    /// builds the ONE dictionary every tunnel start passes.
    public static func merging(into options: [String: NSObject], enabled: Bool) -> [String: NSObject] {
        options.merging(startOptions(enabled: enabled)) { _, new in new }
    }
}
