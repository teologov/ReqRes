//
//  OneShotCompletion.swift
//  ReqRes
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
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

import Foundation

/// Runs a completion exactly once, whichever of several callbacks gets there
/// first, from any thread.
///
/// The system-extension request delegates need this: a request reports
/// through several delegate methods (`foundProperties`, `didFinishWithResult`,
/// `didFailWithError`, `requestNeedsUserApproval`), more than one of which
/// can fire for a single request, and a continuation resumed twice traps
/// while one never resumed hangs its task forever.
public final class OneShotCompletion {
    private let lock = NSLock()
    private var completed = false

    public init() {}

    /// Whether the completion has already run.
    public var isCompleted: Bool {
        lock.lock(); defer { lock.unlock() }
        return completed
    }

    /// Runs `body` if nothing has run before; returns whether it ran.
    @discardableResult
    public func fire(_ body: () -> Void) -> Bool {
        lock.lock()
        if completed {
            lock.unlock()
            return false
        }
        completed = true
        lock.unlock()
        body()
        return true
    }
}
