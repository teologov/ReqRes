//
//  MCPBreakpointAdapter.swift
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
//  The bridge's view of held requests.
//
//  Thin on purpose: the decisions are `BreakpointService`'s (it owns the queue
//  and the bus), the rules about what an agent may send are `MCPKit`'s, and
//  the header shape is the core's. What is left here is the crossing between
//  them — and the one thing that genuinely belongs to this layer: reading the
//  grant, on every call, from the setting the human controls.
//

import Foundation
import MCPKit
import XReqResCore

final class MCPBreakpointAdapter: MCPBreakpointProviding {
    /// The human's standing permission for agents to answer held requests.
    ///
    /// NOT registered with a default: absent means off, and the one way this
    /// becomes true is the user switching it on in Settings → Breakpoints.
    /// (The bridge's own `MCPBridgeEnabled` registers a default of true; this
    /// deliberately does the opposite, because that one only opens a redacted
    /// read surface and this one hands out live traffic.)
    static let defaultsKey = "BreakpointAgentDecisions"

    private let defaults: UserDefaults
    private let service: BreakpointService

    init(defaults: UserDefaults = .standard, service: BreakpointService = .shared) {
        self.defaults = defaults
        self.service = service
    }

    /// Read per call, never cached. The user can withdraw this mid-session —
    /// probably while watching an agent do something they did not expect —
    /// and the next decision has to see that, not a value sampled at launch.
    var agentDecisionsEnabled: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    var armedRuleCount: Int {
        onMain { self.service.rules.filter { $0.rule.enabled }.count }
    }

    func pausedRequests() -> [MCPPausedRequest] {
        onMain {
            self.service.pending.map { request in
                MCPPausedRequest(
                    id: request.id,
                    host: request.host,
                    method: request.method,
                    url: Self.url(for: request),
                    path: request.uri,
                    // The core's own decoder, reached across the framework
                    // boundary: the shape is `BreakpointHeaderWire`'s and
                    // parsing it again here would be a second spelling of a
                    // contract that already has one.
                    headers: (BreakpointHeaderWire.decode(request.headers) ?? [])
                        .map { MCPHeaderPair(name: $0.name, value: $0.value) },
                    bodyPreview: request.bodyPreview,
                    bodyByteCount: request.bodyByteCount,
                    bodyTruncated: BreakpointService.isBodyTruncated(request),
                    // The core's reading of the head (35dd624): what the
                    // agent's body line says before the headers are read.
                    bodyExpected: request.bodyExpected,
                    declaredBodyLength: request.declaredBodyLength,
                    secondsRemaining: self.service.secondsRemaining(for: request)
                )
            }
        }
    }

    func decide(_ decision: MCPBreakpointDecision) throws -> MCPBreakpointOutcome {
        // Every hop from here on has to happen on main, in ONE block: the
        // queue can change between two of them (a request expires at its
        // deadline whatever else is going on), and an id checked in one hop
        // and answered in the next is exactly how a decision lands on a
        // request that is already on the wire.
        try onMain {
            guard let held = self.service.pending.first(where: { $0.id == decision.id }) else {
                throw MCPWriteError.notFound("That request is no longer held — it was answered or has already been resumed.")
            }
            let url = Self.url(for: held)
            let summary: String

            switch decision.action {
            case .abort:
                let status = decision.abortStatus ?? MCPBreakpointValidation.defaultAbortStatus
                self.service.abort(id: held.id, status: status)
                summary = "Aborted \(held.method) \(url) with \(status) — it never reached the server."

            case .resume where !decision.editsAnything:
                self.service.resume(id: held.id)
                summary = "Resumed \(held.method) \(url) untouched."

            case .resume:
                // The patch is applied to the REAL headers, not to the
                // redacted copy the agent read: resuming what an agent saw
                // would write "[redacted]" into the user's own request as if
                // it were a credential.
                let original = (BreakpointHeaderWire.decode(held.headers) ?? [])
                    .map { MCPHeaderPair(name: $0.name, value: $0.value) }
                let patched = MCPBreakpointValidation.apply(
                    setHeaders: decision.setHeaders,
                    removeHeaders: decision.removeHeaders,
                    to: original
                )
                let headersChanged = patched != original
                if let body = decision.body, BreakpointService.isBodyTruncated(held), body == held.bodyPreview {
                    // The agent sent back the preview it was given. That is
                    // not an edit, it is the rest of the upload being cut off.
                    throw MCPWriteError.invalid(
                        "That body is the truncated preview you were shown, not the whole body — resuming with it "
                        + "would drop the rest of the upload. Resume without a body to send the original."
                    )
                }
                let message = self.service.resume(
                    id: held.id,
                    headers: headersChanged ? patched.map { BreakpointHeader(name: $0.name, value: $0.value) } : nil,
                    body: decision.body
                )
                if let message { throw MCPWriteError.invalid(message) }
                summary = MCPBreakpointValidation.summary(for: decision, request: MCPPausedRequest(
                    id: held.id, host: held.host, method: held.method, url: url,
                    path: held.uri, headers: [], secondsRemaining: 0
                ))
            }

            // The panel's own way of saying what happened to a queue that
            // emptied without the user clicking anything. A decision made
            // elsewhere is exactly that, and "it vanished while I was reading
            // it" is the one outcome this feature must never produce.
            self.service.noteAgentDecision(summary)

            return MCPBreakpointOutcome(
                id: held.id,
                action: decision.action,
                host: held.host,
                method: held.method,
                url: url,
                summary: summary
            )
        }
    }

    private static func url(for request: PausedRequestCodable) -> String {
        let scheme = request.scheme.isEmpty ? "https" : request.scheme
        return "\(scheme)://\(request.host)\(request.uri)"
    }

    /// The bridge answers on a per-connection queue; every published thing
    /// this touches belongs to main. `sync` is safe in this direction — the
    /// main thread never waits on the bridge.
    private func onMain<T>(_ work: @escaping () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }
}
