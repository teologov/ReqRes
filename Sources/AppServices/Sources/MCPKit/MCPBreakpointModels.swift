//
//  MCPBreakpointModels.swift
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
//  Letting an agent answer a request a human stopped.
//
//  This is the one surface where an agent acts on traffic that is HAPPENING,
//  not on traffic that already happened or on a rule for traffic to come. A
//  browser tab is spinning while the decision is outstanding. Three rules
//  follow from that, and they are the design:
//
//   1. **An agent can never arm a breakpoint.** Rules live in Settings and
//      belong to the human. Everything here acts only on requests someone
//      already chose to stop, which is what keeps "a confused agent hangs your
//      network" out of reach by construction rather than by good behaviour.
//
//   2. **Decisions are pre-authorised, once, by a setting that ships OFF.**
//      Every other write in this bridge asks per action. That cannot work
//      here: consent may take `MCPLimits.consentTimeout` (45s) and a held
//      request is released by the core at 60s, so a panel per decision would
//      spend the window the decision has to fit inside. The grant is therefore
//      given deliberately in advance, in the same pane where the human armed
//      the breakpoint, and every decision is still audited.
//
//   3. **The safe answer is always available and always the default.** A
//      request nobody answers resumes untouched. So a refusal here — bad
//      input, the setting off, an expired id — costs the user nothing worse
//      than the request going through as it would have anyway.
//

import Foundation

// MARK: - What the agent sees

/// One request header, kept as an ordered pair.
///
/// Not a dictionary: `Cookie` twice is legal and common, and order is part of
/// what the user is looking at. A map would silently keep one of a pair, which
/// is the same class of bug the core's `BreakpointHeaderWire` exists to avoid.
public struct MCPHeaderPair: Codable, Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A request stopped mid-flight, as an agent reads it.
public struct MCPPausedRequest: Codable, Equatable, Sendable, Identifiable {
    /// The id to answer it with. Meaningless after it is answered or expires.
    public var id: String
    public var host: String
    public var method: String
    public var url: String
    public var path: String
    public var headers: [MCPHeaderPair]
    /// The head of the body, redacted and capped like every other body this
    /// bridge returns — when there is one to show. The core holds a request
    /// at its head and reports no body (nil, with a count of 0, for a POST
    /// with a body as much as for a GET), so what can be said instead comes
    /// from the head: `bodyExpected` / `declaredBodyLength` and the headers,
    /// read by `HeldRequestBody`, which `list_paused_requests` prints for
    /// every request.
    public var bodyPreview: String?
    /// 0 when the core reported no body — which is not "no body".
    public var bodyByteCount: Int
    /// True when `bodyPreview` is a prefix. An agent must not send a truncated
    /// preview back as the new body — it would drop the rest of the upload.
    public var bodyTruncated: Bool
    /// What the request's head says about its body, as the core read it
    /// (`PausedRequestCodable.bodyExpected`, core 35dd624): false — no body
    /// follows; true — one follows, not shown; nil — the head cannot say (an
    /// HTTP/2 GET without content-length, say), or the extension predates
    /// the field.
    public var bodyExpected: Bool?
    /// The head's Content-Length as the core read it, or nil: none, not one
    /// number, or an extension older than the field.
    public var declaredBodyLength: Int?
    /// How long the human has left before the core resumes it untouched. This
    /// is the number an agent should reason about before doing anything slow.
    public var secondsRemaining: Int

    public init(
        id: String,
        host: String,
        method: String,
        url: String,
        path: String,
        headers: [MCPHeaderPair],
        bodyPreview: String? = nil,
        bodyByteCount: Int = 0,
        bodyTruncated: Bool = false,
        bodyExpected: Bool? = nil,
        declaredBodyLength: Int? = nil,
        secondsRemaining: Int
    ) {
        self.id = id
        self.host = host
        self.method = method
        self.url = url
        self.path = path
        self.headers = headers
        self.bodyPreview = bodyPreview
        self.bodyByteCount = bodyByteCount
        self.bodyTruncated = bodyTruncated
        self.bodyExpected = bodyExpected
        self.declaredBodyLength = declaredBodyLength
        self.secondsRemaining = secondsRemaining
    }
}

/// The answer to `list_paused_requests`.
///
/// It carries the two pieces of context that turn an empty list from a dead
/// end into an answer: whether any breakpoint is armed at all, and whether the
/// human has allowed agent decisions. Without them an agent can only report
/// "nothing is paused", which is true and useless — the user's next question
/// is always "why not".
public struct MCPPausedRequestPage: Codable, Equatable, Sendable {
    public var requests: [MCPPausedRequest]
    public var armedRules: Int
    public var agentDecisionsEnabled: Bool

    public init(requests: [MCPPausedRequest], armedRules: Int, agentDecisionsEnabled: Bool) {
        self.requests = requests
        self.armedRules = armedRules
        self.agentDecisionsEnabled = agentDecisionsEnabled
    }
}

// MARK: - What the agent sends

/// An answer for one held request.
public struct MCPBreakpointDecision: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// Send it on — as it stands, or with the edits below.
        case resume
        /// Answer it here. The server never sees the request.
        case abort
    }

    public var id: String
    public var action: Action
    /// Headers to set on top of the request's own — replacing one that is
    /// already there by that name, adding one that is not. Never
    /// Content-Length or Transfer-Encoding: ReqRes sets those
    /// (`HeldRequestFraming`), so naming one is refused.
    ///
    /// Deliberately a PATCH rather than a replacement list, and deliberately
    /// the same shape `replay_request` uses. An agent restating every header
    /// it wants kept is an agent that eventually drops one; worse, a
    /// wholesale list expressed as a JSON object would collapse a repeated
    /// `Cookie` into one and say nothing. Headers the agent does not name
    /// travel exactly as the client sent them, duplicates and order included.
    public var setHeaders: [String: String]?
    /// Header names to drop before sending. Matched without case, because
    /// that is how HTTP compares them. Not Content-Length or
    /// Transfer-Encoding, for the same reason as `setHeaders`.
    public var removeHeaders: [String]?
    /// Replaces the request's whole body — an original the agent was never
    /// shown, since the core reports no body for a held request. `nil` means
    /// "send the original"; `""` sends an empty body. None of the original
    /// then reaches the server (core 35dd624), and ReqRes gives the
    /// replacement a Content-Length to match. Refused for a TRACE, which may
    /// not carry one (`validate(_:for:)`).
    public var body: String?
    /// The status the client receives on an abort.
    public var abortStatus: Int?

    public init(
        id: String,
        action: Action,
        setHeaders: [String: String]? = nil,
        removeHeaders: [String]? = nil,
        body: String? = nil,
        abortStatus: Int? = nil
    ) {
        self.id = id
        self.action = action
        self.setHeaders = setHeaders
        self.removeHeaders = removeHeaders
        self.body = body
        self.abortStatus = abortStatus
    }

    /// True when the agent asked for a change at all. A decision that edits
    /// nothing resumes the request byte-for-byte rather than round-tripping it
    /// through this app's idea of how headers are spelled.
    public var editsAnything: Bool {
        !(setHeaders?.isEmpty ?? true) || !(removeHeaders?.isEmpty ?? true) || body != nil
    }
}

/// What the bridge reports back about a decision that landed.
public struct MCPBreakpointOutcome: Codable, Equatable, Sendable {
    public var id: String
    public var action: MCPBreakpointDecision.Action
    public var host: String
    public var method: String
    public var url: String
    /// Plain English for the audit row and the tool's reply.
    public var summary: String

    public init(
        id: String,
        action: MCPBreakpointDecision.Action,
        host: String,
        method: String,
        url: String,
        summary: String
    ) {
        self.id = id
        self.action = action
        self.host = host
        self.method = method
        self.url = url
        self.summary = summary
    }
}

// MARK: - Validation

public enum MCPBreakpointValidation {
    /// A replacement body is capped. A person can read what they typed into
    /// the panel; an agent-supplied body is neither seen nor bounded by
    /// anything upstream, and it goes onto a live socket in place of an
    /// original nobody was shown.
    public static let maxBodyBytes = 256 * 1024

    /// Statuses an abort may answer with. Deliberately not "any integer": a
    /// 2xx abort tells the client's code that something it never did
    /// succeeded, which is a worse lie than an error.
    public static let abortStatusRange = 400...599

    /// Checks an agent's decision before anything is sent.
    ///
    /// Every refusal here leaves the request held and the human in control —
    /// and if nobody answers it, it resumes untouched. That is why this
    /// refuses rather than repairs: a decision quietly adjusted into a
    /// different one is the one outcome neither the agent nor the user asked
    /// for.
    public static func validate(_ decision: MCPBreakpointDecision) throws {
        guard !decision.id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPWriteError.invalid("Which held request? Pass the `id` from list_paused_requests.")
        }

        switch decision.action {
        case .abort:
            if decision.editsAnything {
                throw MCPWriteError.invalid(
                    "An aborted request is never sent, so editing its headers or body has no meaning. "
                    + "Use action \"resume\" with the edits, or \"abort\" on its own."
                )
            }
            if let status = decision.abortStatus, !abortStatusRange.contains(status) {
                throw MCPWriteError.invalid(
                    "An abort answers with a client or server error (\(abortStatusRange.lowerBound)–\(abortStatusRange.upperBound)); "
                    + "\(status) would tell the app something it never did had succeeded."
                )
            }
        case .resume:
            if decision.abortStatus != nil {
                throw MCPWriteError.invalid("`abort_status` only applies to action \"abort\".")
            }
            if let body = decision.body, body.utf8.count > maxBodyBytes {
                throw MCPWriteError.invalid(
                    "That replacement body is \(body.utf8.count) bytes and the limit is \(maxBodyBytes). "
                    + "A breakpoint edits a request in flight; a body this size belongs in a map_local rule."
                )
            }
            try validate(setHeaders: decision.setHeaders, removeHeaders: decision.removeHeaders)
        }
    }

    /// What the held request itself rules out, checked once the bridge has
    /// found it (`validate(_:)` runs before, on the decision alone): a body
    /// for a TRACE, which may not carry one — over HTTP/1.1 the core answers
    /// such a request 502 and records a failed row instead of forwarding it
    /// (core 5efe7aa). Refused for any `body`, an empty one included. What to
    /// do instead depends on the TRACE (`replacementRefusalForAgents`): one
    /// with no body of its own resumes without `body`; one carrying a body
    /// gets the same 502 when resumed over HTTP/1.1, so it is told to abort.
    public static func validate(_ decision: MCPBreakpointDecision, for held: MCPPausedRequest) throws {
        guard decision.action == .resume, decision.body != nil,
              let refusal = HeldRequestBody(held).replacementRefusalForAgents else { return }
        throw MCPWriteError.invalid(refusal)
    }

    /// The request-splitting guard, restated on this side of the framework
    /// boundary because this package cannot link the core.
    ///
    /// The core's `BreakpointHeaderWire.isSendable` is the authority and runs
    /// again before anything is written — this exists so the agent gets a 400
    /// naming the offending header instead of a generic refusal. Checked on
    /// unicode SCALARS: Swift folds "\r\n" into a single Character, so a
    /// Character-level search for "\n" misses exactly the CRLF pair that ends
    /// the header block early and lets the rest be read as another request.
    ///
    /// And the framing guard (`HeldRequestFraming`): Content-Length and
    /// Transfer-Encoding are ReqRes's to set, so a patch naming either is
    /// refused rather than accepted and silently overridden by the core.
    public static func validate(setHeaders: [String: String]?, removeHeaders: [String]?) throws {
        for (rawName, value) in setHeaders ?? [:] {
            let name = rawName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw MCPWriteError.invalid("A header with no name cannot be sent.")
            }
            guard !containsLineBreak(name), !containsLineBreak(value) else {
                throw MCPWriteError.invalid(
                    "“\(name)” contains a line break. That would end the request's header block early "
                    + "and let the rest be read as another request."
                )
            }
            guard !name.contains(":"), !name.unicodeScalars.contains(where: { $0 == " " || $0 == "\t" }) else {
                throw MCPWriteError.invalid("“\(name)” is not a usable header name — no colons and no spaces.")
            }
        }
        for name in removeHeaders ?? [] where name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw MCPWriteError.invalid("`remove_headers` contains an empty name.")
        }
        if let refusal = HeldRequestFraming.agentRefusal(setHeaders: setHeaders, removeHeaders: removeHeaders) {
            throw MCPWriteError.invalid(refusal)
        }
    }

    private static func containsLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }
    }

    /// Applies an agent's header patch to the headers a request actually
    /// carries.
    ///
    /// Lives here, pure, rather than in the app adapter because every rule in
    /// it is a decision about someone's live request and all of them are
    /// invisible from the outside:
    ///
    ///  * Names are matched WITHOUT case, because that is how HTTP compares
    ///    them — an agent setting "authorization" on a request carrying
    ///    "Authorization" must replace it, not add a second one.
    ///  * Setting a name that appears twice leaves ONE of it. "Set X to this"
    ///    cannot sensibly mean "and also keep the other X".
    ///  * Everything the patch does not name keeps its position and its
    ///    duplicates. A held request is the user's own traffic; the parts an
    ///    agent did not ask to change should reach the server byte-identical.
    ///  * Additions are appended in name order, because a Swift dictionary has
    ///    none and a request whose headers shuffle between runs is one nobody
    ///    can debug.
    public static func apply(
        setHeaders: [String: String]?,
        removeHeaders: [String]?,
        to headers: [MCPHeaderPair]
    ) -> [MCPHeaderPair] {
        let removals = Set((removeHeaders ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let sets = setHeaders ?? [:]
        let setKeys = Dictionary(
            sets.map { ($0.key.trimmingCharacters(in: .whitespaces).lowercased(), $0.key.trimmingCharacters(in: .whitespaces)) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [MCPHeaderPair] = []
        var replaced: Set<String> = []
        for header in headers {
            let key = header.name.lowercased()
            if removals.contains(key) { continue }
            guard let canonical = setKeys[key] else {
                result.append(header)
                continue
            }
            // The first occurrence takes the new value; any later duplicate of
            // the same name is dropped rather than left contradicting it.
            if replaced.insert(key).inserted {
                result.append(MCPHeaderPair(name: canonical, value: sets[canonical] ?? ""))
            }
        }
        for key in setKeys.keys.sorted() where !replaced.contains(key) {
            guard let canonical = setKeys[key], let value = sets[canonical] else { continue }
            result.append(MCPHeaderPair(name: canonical, value: value))
        }
        return result
    }

    /// The sentence the audit log and the tool reply both use, so what the
    /// user reads afterwards matches what the agent was told.
    public static func summary(for decision: MCPBreakpointDecision, request: MCPPausedRequest) -> String {
        switch decision.action {
        case .abort:
            let status = decision.abortStatus ?? defaultAbortStatus
            return "Aborted \(request.method) \(request.url) with \(status) — it never reached the server."
        case .resume:
            let headersChanged = !(decision.setHeaders?.isEmpty ?? true) || !(decision.removeHeaders?.isEmpty ?? true)
            switch (headersChanged, decision.body != nil) {
            case (true, true):
                return "Resumed \(request.method) \(request.url) with edited headers and a replaced body."
            case (true, false):
                return "Resumed \(request.method) \(request.url) with edited headers."
            case (false, true):
                return "Resumed \(request.method) \(request.url) with a replaced body."
            case (false, false):
                return "Resumed \(request.method) \(request.url) untouched."
            }
        }
    }

    /// Matches the panel's own default so an agent and a human answering the
    /// same request produce the same thing. 409 says "refused here", without
    /// claiming the server broke.
    public static let defaultAbortStatus = 409
}

// MARK: - The seam the app implements

/// Held requests, and the power to answer them.
///
/// `agentDecisionsEnabled` is read through the seam rather than captured once:
/// the human can withdraw the grant mid-session, and the next decision must
/// see that rather than a value the bridge sampled at launch. (The same
/// reasoning as the redaction policy's `redactorSource` closure — rebuilding
/// the router to apply a setting would rotate the handshake token and drop
/// every connected client.)
public protocol MCPBreakpointProviding {
    /// Whether the human has allowed agents to answer held requests.
    var agentDecisionsEnabled: Bool { get }
    /// How many breakpoint rules are armed, so an empty queue can explain
    /// itself.
    var armedRuleCount: Int { get }
    /// Oldest first — the one with the least time left comes first.
    func pausedRequests() -> [MCPPausedRequest]
    /// Answers one. Throws `.notFound` when the id is no longer held, which
    /// after 60 seconds is the normal case rather than an error condition.
    func decide(_ decision: MCPBreakpointDecision) throws -> MCPBreakpointOutcome
}
