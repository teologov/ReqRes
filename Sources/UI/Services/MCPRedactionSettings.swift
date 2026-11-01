//
//  MCPRedactionSettings.swift
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
//  Where the per-host redaction exceptions live between launches.
//
//  Two readers with incompatible needs: Settings reads `policy` on the main
//  thread and expects SwiftUI to update, while the bridge reads `redactor`
//  from a per-connection queue, once per request, and must never touch a
//  `@Published`. So the policy is held twice — a published copy for the UI and
//  a lock-guarded snapshot for the bridge — and written through one place that
//  updates both. This is the same discipline the bridge already follows for
//  SessionState (reads marshalled to main); here the direction is reversed,
//  which is why the snapshot exists at all rather than an `onMain` hop that
//  would deadlock a connection queue waiting on the main thread.
//
//  There is deliberately NO global "stop redacting" switch in the UI. The type
//  can express one (`MCPRedactionPolicy.isEnabled`) and the bridge honours it,
//  but a single click that ships every captured credential to an agent is the
//  kill switch pointed the wrong way — the bridge toggle already turns the
//  whole surface off. An exception has to be a host the user names.
//

import Foundation
import MCPKit

final class MCPRedactionSettings: ObservableObject {
    static let shared = MCPRedactionSettings()

    static let defaultsKey = "MCPRedactionPolicy"

    /// For the UI. Main thread only.
    @Published private(set) var policy: MCPRedactionPolicy

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var snapshot: MCPRedactionPolicy

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A stored blob that cannot be decoded falls back to redact-all rather
        // than to "no policy, so redact nothing" — see MCPRedactionPolicy.
        let loaded = defaults.data(forKey: Self.defaultsKey).map { MCPRedactionPolicy.decoding($0) } ?? .redactAll
        policy = loaded
        snapshot = loaded
    }

    /// Safe to call from any thread; the bridge calls it per request.
    var currentPolicy: MCPRedactionPolicy {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// The redactor the bridge should use right now.
    ///
    /// `enabled` mirrors the policy's own switch because several redactor
    /// entry points (`redactHeaders`, `redactURL`) consult `enabled` alone —
    /// passing `enabled: true` with a disabled policy would redact in some
    /// places and not others, which is worse than either answer.
    var currentRedactor: MCPRedactor {
        let policy = currentPolicy
        return MCPRedactor(enabled: policy.isEnabled, policy: policy)
    }

    /// True when the host was added. False means the text cannot except
    /// anything or is already covered — the caller says which.
    @discardableResult
    func except(_ host: String) -> Bool {
        guard let updated = policy.addingException(host) else { return false }
        apply(updated)
        return true
    }

    func removeException(_ host: String) {
        apply(policy.removingException(host))
    }

    func removeAllExceptions() {
        var updated = policy
        updated.exceptedHosts = []
        apply(updated)
    }

    /// The one writer. Publishes for the UI and swaps the snapshot the bridge
    /// reads, in that order, so a request that lands between the two sees the
    /// old policy rather than a half-applied one.
    private func apply(_ updated: MCPRedactionPolicy) {
        policy = updated
        lock.lock()
        snapshot = updated
        lock.unlock()
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
