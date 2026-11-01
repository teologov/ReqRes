//
//  CaptureStartLedger.swift
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
//  The capture starts one extension PROCESS has seen (build 53, core
//  95062d1), across every provider object NetworkExtension makes in it — one
//  per tunnel session, while the process lives on.
//
//  A start that a stop overtook can still be handed a proxy by the core.
//  Closing it is right only while nothing has started since: `close()` calls
//  the core's `MitmService.captureStopped()`, which is the whole process's —
//  it would end a later start's search for the app, or fail that start as
//  "stopped before it started". A count kept per provider object cannot see
//  a later session's start; this one can.
//

import Foundation

public final class CaptureStartLedger: @unchecked Sendable {
    /// The extension process's ledger.
    public static let process = CaptureStartLedger()

    private let lock = NSLock()
    private var starts: UInt64 = 0

    public init() {}

    /// A start begins: its number in this process.
    public func begin() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        starts &+= 1
        return starts
    }

    /// Runs `body` only when no start has begun since `start` — under the
    /// ledger's lock, so none can begin while it runs. True when it ran.
    @discardableResult
    public func ifNoStartSince(_ start: UInt64, _ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard starts == start else { return false }
        body()
        return true
    }
}
