//
//  FailureRows.swift
//  AppServices
//
//  Created by OloApps on 9/29/26.
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
//  Failed, aborted and timed-out rows (protocol PRD 3.4, decision D8; the
//  core half is protocol-engine doc §C6).
//
//  Before core 26618ca an exchange that broke left no row at all: a DNS
//  failure, a refused connect, a dev server's self-signed certificate, an app
//  refusing ReqRes's certificate, a cancelled fetch. That core writes one row
//  per exchange whatever happened, with an `outcome`, the phase it broke in,
//  and ONE human sentence naming the cause. This file is what every shell
//  surface says about such a row — the traffic list, the detail banner, the
//  agent's text, HAR, the diagnosis — so the window and an agent can never
//  describe the same failure two ways (the reason `RecordedExchangeCopy`
//  exists, applied to failures).
//
//  Pure Foundation (no XReqResCore) so it is tested in `swift test`. The core's
//  `SessionOutcome` / `SessionFailurePhase` are mirrored here by raw value; the
//  app maps them in one place (`SessionCodable+Failure.swift`).
//

import Foundation

// MARK: - The vocabulary

/// How an exchange ended. Raw values are the core's (`SessionOutcome`), so a
/// row read from the wire or a saved row maps by `rawValue`.
public enum MCPSessionOutcome: String, Codable, CaseIterable, Sendable {
    /// The response ended. Every row an older core ever wrote.
    case completed
    /// It never got a response: the name did not resolve, the connect or a
    /// TLS handshake failed, the server hung up before answering, or ReqRes
    /// refused the request.
    case failed
    /// It started and was cut: the app or the server closed mid-way, or a
    /// human aborted it at a breakpoint.
    case aborted
    /// ReqRes's own idle limit closed it (300 s of two-way silence in flight,
    /// 10 minutes on a relay — decision D6).
    case timedOut

    /// A value a later extension adds reads as `.failed` — the core's own rule
    /// (C6.3): an unknown outcome is at least "not completed", and failing the
    /// whole `list_sessions` page over one row would cost more than it tells.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MCPSessionOutcome(rawValue: raw) ?? .failed
    }

    /// Anything but `.completed`.
    public var isFailure: Bool { self != .completed }

    /// The word a filter, a search token and an agent's row use:
    /// `completed`, `failed`, `aborted`, `timed_out`.
    public var token: String {
        switch self {
        case .completed: return "completed"
        case .failed: return "failed"
        case .aborted: return "aborted"
        case .timedOut: return "timed_out"
        }
    }

    /// The four tokens, in the order a filter description lists them.
    public static var tokens: [String] { allCases.map(\.token) }

    /// `failed`, `ABORTED`, `timed_out`, `timedOut`, `timed-out`, `timedout`
    /// and `timeout` all parse; anything else is nil (and the bridge answers a
    /// 400 for it — a dropped filter reads as a filtered page).
    public static func parse(_ raw: String) -> MCPSessionOutcome? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch key {
        case "completed", "complete": return .completed
        case "failed", "failure": return .failed
        case "aborted": return .aborted
        case "timedout", "timeout": return .timedOut
        default: return nil
        }
    }
}

/// Where an exchange broke. Raw values are the core's (`SessionFailurePhase`).
public enum MCPFailurePhase: String, Codable, CaseIterable, Sendable {
    /// The server's name did not resolve.
    case dns
    /// The TCP connect failed: refused, unreachable, timed out.
    case connect
    /// The SERVER's TLS failed: its certificate is not trusted, expired or for
    /// another name, or it demanded a client certificate.
    case tlsUpstream
    /// The APP refused ReqRes's certificate — the pinning case — or the
    /// handshake between the app and ReqRes failed.
    case tlsClient
    /// While the request was being sent (or ReqRes refused it).
    case request
    /// While the response was awaited or arriving.
    case response
    /// A phase a later extension adds. Kept as a value rather than failing the
    /// decode: the row, its outcome and its sentence are still worth showing.
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MCPFailurePhase(rawValue: raw) ?? .other
    }
}

// MARK: - What a failure row means

/// The facts about one row's outcome, as every surface reads them.
public struct FailureRowFacts: Equatable, Sendable {
    public var outcome: MCPSessionOutcome
    public var phase: MCPFailurePhase?
    /// The core's one sentence (host, port, alert name, seconds — never a
    /// header or a body). Nil or blank falls back to the phase's sentence.
    public var detail: String?
    /// The APP ended an aborted exchange (decision D8) — a browser cancelling a
    /// speculative request, a navigation, a closed tab.
    public var clientCancelled: Bool
    /// The row's status as recorded ("502" for a failed dial ReqRes answered).
    public var status: String?
    /// Whether the row carries a server address. A failed row without one
    /// never connected anywhere.
    public var hasServerAddress: Bool

    public init(
        outcome: MCPSessionOutcome,
        phase: MCPFailurePhase? = nil,
        detail: String? = nil,
        clientCancelled: Bool = false,
        status: String? = nil,
        hasServerAddress: Bool = false
    ) {
        self.outcome = outcome
        self.phase = phase
        self.detail = detail
        self.clientCancelled = clientCancelled
        self.status = status
        self.hasServerAddress = hasServerAddress
    }

    public var isFailure: Bool { outcome.isFailure }

    /// A request that never reached any server: it did not complete and the
    /// core recorded no server address for it (the address is set when the
    /// upstream connects, C4's lazy dial). The one exception is a server-side
    /// TLS failure: its TCP connect DID reach a server, so an unrecorded
    /// address there is "not known", not "nowhere". The Destinations map and
    /// `list_destinations` leave never-connected rows out rather than
    /// counting them as Unknown — see `FailureRowCopy.neverConnectedNote`.
    public var neverConnected: Bool {
        guard outcome.isFailure, !hasServerAddress else { return false }
        return phase != .tlsUpstream
    }

    /// Whether opening this row is an HTTPS inspection after all (D14's
    /// limit): an exchange that got under way — aborted or timed out — and
    /// recorded a decrypted body holds the server's (or the app's) content,
    /// up to 16 MB of it. A FAILED row never is: it got no response, and any
    /// 502 body is ReqRes's own sentence. `hasRecordedBody` is whether the
    /// row kept any request or response body.
    public func carriesDecryptedBody(hasRecordedBody: Bool) -> Bool {
        (outcome == .aborted || outcome == .timedOut) && hasRecordedBody
    }

    /// D8: a client-cancelled abort is hidden from the traffic list unless
    /// Settings ▸ Capture ▸ "Show cancelled requests" is on. Nothing else is
    /// ever hidden — a server's hang-up, a human's breakpoint abort and
    /// ReqRes's own idle close are exactly what the rows exist to show.
    public func isHidden(showCancelled: Bool) -> Bool {
        outcome == .aborted && clientCancelled && !showCancelled
    }
}

/// The action a failure row's banner offers, decided from its facts alone.
public enum FailureRowAction: Hashable, Sendable {
    /// Add the host to Settings ▸ Capture's exclusion list, after a
    /// confirmation (`FailureRowCopy.excludeConfirmation`).
    case excludeHost(String)
    /// Open Settings ▸ Capture, where the CA is exported and the environment
    /// lines for a command-line tool are printed.
    case exportCertificateAndEnvironment
}

public enum FailureRowCopy {
    // MARK: Labels

    /// The chip's word, beside its symbol — colour is never the only signal.
    public static func label(_ outcome: MCPSessionOutcome) -> String {
        switch outcome {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .aborted: return "Aborted"
        case .timedOut: return "Timed out"
        }
    }

    /// The chip's SF Symbol. All three exist on macOS 13 (the package floor).
    public static func symbolName(_ outcome: MCPSessionOutcome) -> String {
        switch outcome {
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .aborted: return "slash.circle"
        case .timedOut: return "hourglass"
        }
    }

    /// What broke, in one sentence: the core's own when it wrote one, the
    /// phase's otherwise.
    public static func cause(_ facts: FailureRowFacts) -> String {
        if let detail = facts.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            return detail
        }
        switch facts.outcome {
        case .completed:
            return "The exchange completed."
        case .timedOut:
            return "ReqRes closed the connection after it had been silent in both directions for too long."
        case .failed, .aborted:
            break
        }
        switch facts.phase {
        case .dns?: return "The server's name could not be resolved."
        case .connect?: return "ReqRes could not connect to the server."
        case .tlsUpstream?: return "The TLS handshake with the server failed."
        case .tlsClient?: return "The app refused ReqRes's certificate."
        case .request?:
            return facts.outcome == .aborted ? "The request was cut off before it was complete." : "The request could not be sent."
        case .response?:
            return facts.outcome == .aborted ? "The response was cut off before it was complete." : "The server closed the connection without answering."
        case .other?, nil:
            return facts.outcome == .aborted ? "The exchange was cut off before it finished." : "The exchange failed before a response arrived."
        }
    }

    /// The table cell's tooltip and accessibility label: the word, then why.
    public static func accessibilityLabel(_ facts: FailureRowFacts) -> String {
        var text = "\(label(facts.outcome)): \(cause(facts))"
        if facts.clientCancelled { text += " Cancelled by the app." }
        return text
    }

    /// Extra lines the banner states under the cause, in order.
    public static func notes(_ facts: FailureRowFacts) -> [String] {
        var notes: [String] = []
        if facts.clientCancelled {
            notes.append(clientCancelledNote)
        }
        if answeredWithBadGateway(facts) {
            notes.append(badGatewayNote(facts))
        }
        if facts.outcome == .timedOut {
            notes.append("\(CaptureEngineFacts.idleSentence())")
        }
        return notes
    }

    /// True when ReqRes itself answered the app `502` for this row (C6: a dial,
    /// a server TLS failure or a hang-up before any answer, on a fresh upstream).
    public static func answeredWithBadGateway(_ facts: FailureRowFacts) -> Bool {
        facts.outcome == .failed && facts.status?.trimmingCharacters(in: .whitespaces) == "502"
            && facts.phase != .tlsClient && facts.phase != .request
    }

    public static let clientCancelledNote =
        "The app itself ended this request — browsers do this constantly (a page navigated away, a tab closed, a duplicate connection dropped). Rows like it are hidden from the traffic list unless Settings ▸ Capture ▸ Show cancelled requests is on."

    /// Whether the request is known NOT to have reached the server: only when
    /// it broke resolving the name or opening the connection. A 502 at
    /// `response` is a server hanging up AFTER the request went up, and one at
    /// `tlsUpstream` can be a TLS 1.3 client-certificate alert that arrives
    /// after the request was sent (C6.2(b)) — telling a user a POST or DELETE
    /// "never reached the server" there invites re-sending a request that
    /// already ran.
    public static func requestNeverSent(_ facts: FailureRowFacts) -> Bool {
        facts.phase == .dns || facts.phase == .connect
    }

    /// The banner's note for a 502 ReqRes sent, worded by what is known about
    /// whether the server saw the request.
    public static func badGatewayNote(_ facts: FailureRowFacts) -> String {
        requestNeverSent(facts) ? badGatewayNeverSentNote : badGatewayMayHaveReachedNote
    }

    public static let badGatewayNeverSentNote =
        "ReqRes answered the app with 502 Bad Gateway, and that response's body is the sentence above — a 502 from ReqRes names its reason. The server never saw the request."

    public static let badGatewayMayHaveReachedNote =
        "ReqRes answered the app with 502 Bad Gateway, and that response's body is the sentence above — a 502 from ReqRes names its reason. The request may have reached the server before it failed, so check before sending it again."

    // MARK: Actions

    /// What the banner offers. A client-rejected certificate is the pinning
    /// case: excluding the host is the one thing that makes the app work while
    /// capturing. For a command-line tool the likelier reason is that it reads
    /// its trust from a FILE, not the keychain (node, Python, anything inside
    /// Docker) — so exporting the CA and the environment lines comes first,
    /// and excluding stays available after it.
    public static func actions(
        _ facts: FailureRowFacts,
        host: String,
        isCommandLineTool: Bool,
        hostAlreadyExcluded: Bool
    ) -> [FailureRowAction] {
        guard facts.outcome == .failed, facts.phase == .tlsClient else { return [] }
        var actions: [FailureRowAction] = []
        if isCommandLineTool { actions.append(.exportCertificateAndEnvironment) }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        if !hostAlreadyExcluded, !trimmedHost.isEmpty { actions.append(.excludeHost(trimmedHost)) }
        return actions
    }

    /// The button's title.
    public static func buttonTitle(_ action: FailureRowAction) -> String {
        switch action {
        case .excludeHost(let host): return "Exclude \(host)…"
        case .exportCertificateAndEnvironment: return "Export the CA and the environment lines…"
        }
    }

    /// The sentence beside the button, or nil when the cause above it
    /// already says it — the core's own refusal sentence ends "exclude the
    /// host to let its traffic through unrecorded", and a banner that says
    /// the same thing twice reads as padding.
    public static func explanation(_ action: FailureRowAction, cause: String) -> String? {
        if case .excludeHost = action, cause.localizedCaseInsensitiveContains("exclude the host") { return nil }
        return explanation(action)
    }

    /// The sentence beside the button: why it is offered.
    public static func explanation(_ action: FailureRowAction) -> String {
        switch action {
        case .excludeHost:
            return "Some apps pin their certificate and refuse any other on purpose. Excluding the host lets the app reach the real server while capture runs — and ReqRes stops recording it."
        case .exportCertificateAndEnvironment:
            return "A command-line tool usually reads its trusted certificates from a file, not the keychain. Settings ▸ Capture exports the ReqRes CA and prints the lines that point the tool at it."
        }
    }

    /// Shown instead of the exclude button when the host is already on the list.
    public static func alreadyExcluded(_ host: String) -> String {
        "\(host) is now excluded: new connections to it are passed straight through and not recorded."
    }

    /// The confirmation's title, message and button — the SAME consequence the
    /// agent's `exclude_host` consent panel states.
    public static func excludeConfirmationTitle(_ host: String) -> String {
        "Stop recording \(host)?"
    }

    public static func excludeConfirmation(_ host: String) -> String {
        exclusionConsequence(host) + " " + exclusionScope + " Settings ▸ Capture lists the host and puts it back."
    }

    public static func excludeConfirmButton(_ host: String) -> String {
        "Exclude \(host)"
    }

    /// What an exclusion does to each scheme, and from when (doc §S10). HTTPS
    /// to an excluded host is a raw relay of the CONNECT (core ConnectHandler),
    /// untouched; plain http:// still goes through the plain-HTTP front (core
    /// PlainHTTPFront), which rewrites the URI to origin-form and strips the
    /// hop-by-hop headers like any proxy — only the row, the rules and the
    /// breakpoints are turned off. So "unchanged" is true of HTTPS only.
    public static let exclusionScope =
        "HTTPS connections to it opened from now on are passed straight through, untouched, with the server's own certificate. Plain http:// requests to it are forwarded from the next one as any proxy forwards them (hop-by-hop headers removed), with no row, rule or breakpoint."

    /// The one sentence both the human's confirmation and the agent's consent
    /// panel print (PRD 3.5).
    public static func exclusionConsequence(_ host: String) -> String {
        "ReqRes will stop recording \(host); you will no longer see its traffic."
    }

    // MARK: Settings and Help

    /// Settings ▸ Capture's "Requests that did not complete" caption.
    public static let settingsExplanation =
        "A request that fails, is cut off or times out is still a row in the traffic list, marked Failed, Aborted or Timed out with the reason in one sentence. When a server cannot be reached, ReqRes answers the app with 502 Bad Gateway and that reason as the body — for a native gRPC call that got as far as a request, HTTP 200 with grpc-status 14 UNAVAILABLE and the reason as grpc-message. A native gRPC client whose server cannot be reached while its connection is being set up is offered HTTP/1.1 instead, which it does not speak: it closes the connection, and one Failed row says so. An app that refuses ReqRes's certificate appears as one Failed row; ReqRes then remembers it and passes that app's connections to the same domain through, marked SSL pinned (listed under SSL-pinned apps). Opening a Failed row never uses a free HTTPS inspection; an Aborted or Timed out one that kept a body counts like any other request."

    /// The caption under "Show cancelled requests" (decision D8).
    public static let cancelledCaption =
        "Requests an app cancels itself — browsers do this constantly, for pages navigated away from and connections they no longer need — are hidden from the traffic list unless this is on. Agents can still list them; their waits skip them unless asked."

    /// Help's bullets about failure rows, in reading order.
    public static let helpBullets: [String] = [
        "Failed — it never got a response: the server's name did not resolve, the connection was refused, the server's certificate was not trusted, the server hung up before answering, or the app refused ReqRes's own certificate. The detail says which, in one sentence.",
        "Aborted — it started and was cut off: the app gave up, the server hung up half way, or you aborted it at a breakpoint.",
        "Timed out — ReqRes closed a connection that had been silent in both directions for too long.",
        "When a server cannot be reached or fails before answering, ReqRes answers the app itself with 502 Bad Gateway, and that response's body is the same one-sentence reason — so a 502 from ReqRes names its cause. A native gRPC call that got as far as a request gets its own protocol's answer instead: HTTP 200 with grpc-status 14 (UNAVAILABLE) and the reason as grpc-message. A native gRPC client whose server cannot be reached while its connection is being set up gets no gRPC answer — ReqRes can offer it only HTTP/1.1, it closes the connection, and the Failed row says so. If the name did not resolve or the connection was refused, the server never saw the request; if the server hung up or its TLS failed after the request went up, it may have run — check before sending it again.",
        "An app that refuses ReqRes's certificate pins its own on purpose (WhatsApp's media, banking apps, some SDKs), or does not trust the ReqRes CA. ReqRes remembers the app and the domain: from then on that app's connections there pass through untouched and show as rows marked SSL pinned, so trying again in the app works. Settings ▸ Capture ▸ SSL-pinned apps lists what it remembered; forget one to try decrypting again. A command-line tool that refuses it usually just needs the CA as a file — the row offers Settings ▸ Capture for that instead.",
        "Type outcome:failed (or aborted, timed_out) in the search field to see only those. Requests an app cancelled itself are hidden unless Settings ▸ Capture ▸ Show cancelled requests is on.",
    ]

    // MARK: Destinations

    /// Why the Destinations map and `list_destinations` leave some rows out.
    public static func neverConnectedNote(_ count: Int) -> String {
        count == 1
            ? "1 request that failed before connecting to any server is not counted — it went nowhere."
            : "\(count) requests that failed before connecting to any server are not counted — they went nowhere."
    }

    // MARK: Agents

    /// `outcome=failed(dns)` — the token an agent can match, with the phase.
    public static func agentToken(_ facts: FailureRowFacts) -> String {
        var token = "outcome=\(facts.outcome.token)"
        if let phase = facts.phase { token += "(\(phase.rawValue))" }
        if facts.clientCancelled { token += " cancelled_by_app" }
        return token
    }

    /// The detail's outcome line for an agent.
    public static func agentOutcomeLine(_ facts: FailureRowFacts) -> String {
        var line = "Outcome: \(facts.outcome.token)"
        if let phase = facts.phase { line += " at \(phase.rawValue)" }
        line += " — \(cause(facts))"
        if facts.clientCancelled { line += " (the app cancelled it)" }
        if answeredWithBadGateway(facts) {
            line += " ReqRes answered the app 502 with this sentence as the body."
            line += requestNeverSent(facts)
                ? " The server never saw the request."
                : " The request may have reached the server; do not assume it did not run."
        }
        return line
    }
}
