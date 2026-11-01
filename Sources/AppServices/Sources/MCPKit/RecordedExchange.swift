//
//  RecordedExchange.swift
//  AppServices
//
//  Created by OloApps on 9/28/26.
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
//  What the 1.1.0 core records about a row beyond its request and response,
//  and the words every surface uses for it — the traffic table, the detail
//  pane, the saved-sessions browser, the agent's text and the HAR file.
//
//  Three facts arrived with that core (protocol-engine doc §C2, §C3):
//    - a row is one EXCHANGE, and an exchange may ride a connection an earlier
//      one opened (`connectionReused`, `exchangeIndex`) — it then had no DNS,
//      TCP or TLS of its own, which a waterfall must say rather than draw;
//    - a body is kept only up to 16 MB per exchange, the rest forwarded and
//      counted (`reqBodyTruncatedBytes` / `rspBodyTruncatedBytes`) — so a row
//      can hold part of a body, and nothing may present that part as whole;
//    - with no ReqRes CA installed and trusted as it opened, an HTTPS connection
//      is RELAYED, not decrypted, and recorded as one row when it closes
//      (`relayed`) — a connection, not a request: it has no method, no status,
//      no headers and no body, only an endpoint, bytes each way and a life.
//
//  The sentences live here, once, for the reason `DestinationCopy` does: the
//  app and the MCP helper both print them, and two spellings of "how much of
//  this body is missing" is how one of them ends up claiming a body is whole.
//
//  Pure Foundation (no XReqResCore) so it is tested in `swift test`.
//

import Foundation

/// What kind of row a captured session is.
public enum MCPSessionKind: String, Codable, Equatable, Sendable {
    /// A request and its response, decrypted and recorded.
    case exchange
    /// A connection ReqRes relayed without decrypting (no CA installed and
    /// trusted when it opened): one row per connection, written when it closed.
    case relay

    /// A kind this build does not know — a future row type, such as the
    /// failure rows decision D8 plans — reads as `.exchange` rather than
    /// throwing. The helper and the app ship together, but a synthesized
    /// decode would fail the WHOLE `list_sessions` page over one unknown
    /// value, where treating it as an ordinary row (which it was before
    /// `kind` existed) costs nothing.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MCPSessionKind(rawValue: raw) ?? .exchange
    }
}

/// The capture engine's numbers, as the core's 1.1.0 build sets them
/// (decisions D6 and D10 of the protocol PRD).
///
/// The app reads the live values from the core (`ConnectionIdlePolicy.http`,
/// `.relayed`) and passes them to the sentence builders below; the MCP helper
/// cannot link the core, so its tool descriptions and SKILL.md use these
/// defaults. `CaptureEngineFactsTests` pins them to the decisions, so a change
/// in the core that is not made here too is a failing test in review, not a
/// wrong number in front of a user.
public enum CaptureEngineFacts {
    /// Two-way silence that closes a connection BETWEEN exchanges.
    public static let idleBetweenExchanges: TimeInterval = 30
    /// Two-way silence that closes a connection while a response is awaited
    /// or streaming.
    public static let idleWhileInFlight: TimeInterval = 300
    /// Two-way silence that closes a relayed connection (a WebSocket after its
    /// upgrade, an excluded host, a connection captured without the CA).
    public static let idleRelay: TimeInterval = 600
    /// Body bytes the extension keeps per exchange — request and response
    /// together, in arrival order. Everything is forwarded regardless.
    public static let retainedBytesPerExchange: Int64 = 16 * 1024 * 1024
    /// An app refusing ReqRes's certificate is ONE failed row per (host, app)
    /// in this window, not one per refusal — pinned apps retry several times a
    /// second — and a bare hang-up with no TLS alert becomes a row only on its
    /// second time within it. Mirrors the core's `TLSClientRejections.window`
    /// (XReqResCore ExchangeOutcome.swift), which the package cannot import.
    public static let tlsRefusalWindow: TimeInterval = 30

    /// "30 s … 300 s … 10 minutes" — the one sentence about when ReqRes closes
    /// a quiet connection. Silence means nothing moving in EITHER direction:
    /// a stream that sends a byte a minute is never cut.
    public static func idleSentence(
        between: TimeInterval = idleBetweenExchanges,
        inFlight: TimeInterval = idleWhileInFlight,
        relay: TimeInterval = idleRelay
    ) -> String {
        "ReqRes closes a connection only when nothing has moved in either direction for "
            + "\(duration(between)) between requests, \(duration(inFlight)) while a response is awaited or streaming, "
            + "or \(duration(relay)) on a relayed connection (a WebSocket, an excluded host, or one captured without the certificate). "
            + "A download, upload or stream that keeps moving is never cut."
    }

    /// The header that stays on purpose: when a human ABORTS a request held
    /// at a breakpoint, the response ReqRes writes in its place carries it
    /// (core `GlueHandler`), so the client can tell that answer from a
    /// server's. It is never added to traffic that reached a server.
    public static let abortedHeader = "X-Req-Res-Aborted: breakpoint"

    /// ReqRes's own markers are gone from traffic (decision D5) — with the one
    /// exception above, which the sentence names rather than hides.
    public static let addsNoHeaders =
        "ReqRes adds no headers of its own to requests or responses; traffic changes only where one of your rules says so. "
            + "The one exception is a request you abort at a breakpoint: the response ReqRes sends back in its place carries \(abortedHeader)."

    /// What the row keeps of a body, and that the transfer itself is whole.
    ///
    /// The budget is per REQUEST on both schemes since core ef40bdf (C5):
    /// plain HTTP runs on the HTTPS exchange engine and calls
    /// `beginExchange()` per request, which replaces the budget. (Before it,
    /// the plain handler recorded one row per connection and spent one budget
    /// across it, and this sentence said so.)
    public static func retentionSentence(limit: Int64 = retainedBytesPerExchange) -> String {
        "Each request keeps at most the first \(RecordedExchangeCopy.binaryBytes(limit)) of its bodies for display (request and response together); "
            + "everything is still sent on in full, and a row that kept less says how much it is missing."
    }

    /// Body bytes the extension keeps across ALL the open requests of one
    /// HTTP/2 connection (core C12 `ConnectionRetentionPool`): up to 100
    /// streams share a connection, and 100 × 16 MB held in the root
    /// extension for one connection is not a bound. It only applies with
    /// HTTP/2 on.
    public static let retainedBytesPerHTTP2Connection: Int64 = 64 * 1024 * 1024

    /// The HTTP/2 half of the retention sentence (C12's note: Help's
    /// truncation wording must mention the pool).
    public static func http2RetentionSentence(
        perConnection: Int64 = retainedBytesPerHTTP2Connection,
        perExchange: Int64 = retainedBytesPerExchange
    ) -> String {
        "With HTTP/2 capture on, the requests open at the same time on one HTTP/2 connection keep at most \(RecordedExchangeCopy.binaryBytes(perConnection)) between them "
            + "(each still at most \(RecordedExchangeCopy.binaryBytes(perExchange))); a row that could keep less says how much it is missing, and every byte is still sent on."
    }

    /// What capture records while the certificate is not installed AND
    /// trusted. Since core C8 the extension decides per connection, as it
    /// opens, from the state the app pushes (`caStateChanged`) — not once
    /// when capture starts — and an installed-but-untrusted CA relays too
    /// (shell step S4 review).
    public static let withoutCertificate =
        "Until the ReqRes certificate is installed and trusted, HTTPS is relayed, not decrypted: each connection opened meanwhile appears as one row when it closes, with its host and port, the bytes sent each way and how long it was open — no requests, headers or bodies."

    /// 30 → "30 s", 300 → "300 s", 600 → "10 minutes" (a whole number of
    /// minutes of ten or more reads better as minutes; 300 is quoted in
    /// seconds because that is the number the decision states).
    public static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole >= 600, whole % 60 == 0 { return "\(whole / 60) minutes" }
        return "\(whole) s"
    }
}

/// The words for one row's recorded facts.
public enum RecordedExchangeCopy {
    // MARK: Reused connections

    /// "Reused connection · request 3 on it" for the third exchange on a
    /// keep-alive connection; nil for the exchange that opened it. The index
    /// is zero-based on the wire (`exchangeIndex` 2 is the third request).
    ///
    /// A row the core marked reused with index 0 cannot happen on a correct
    /// core; it still reads "reused" rather than inventing a position.
    public static func connectionLabel(reused: Bool, exchangeIndex: Int) -> String? {
        guard reused || exchangeIndex > 0 else { return nil }
        guard exchangeIndex > 0 else { return "Reused connection" }
        return "Reused connection · request \(exchangeIndex + 1) on it"
    }

    /// Whether the core tracked connection reuse for this row at all.
    ///
    /// The exchange engine numbers exchanges on a connection
    /// (`ReqResProxyContext.beginExchange`) — decrypted HTTPS since C2, and
    /// plain http:// since core ef40bdf (C5) moved it onto the same engine.
    /// A relay decodes `connectionReused` false and `exchangeIndex` 0 —
    /// defaults, not facts — so reporting them would print "new — request 1
    /// on it" about a connection nobody counted; a mapping passes nil for it,
    /// and nil prints nothing. (A plain row a pre-1.1.0 core saved reads
    /// "new — request 1" too; accepted, as it was for HTTPS in S2.)
    public static func tracksConnectionReuse(scheme: String, isRelay: Bool) -> Bool {
        guard !isRelay else { return false }
        let lowered = scheme.lowercased()
        return lowered == "https" || lowered == "http"
    }

    /// Why a reused row has no connect/TLS bars.
    public static let reusedExplanation =
        "This request went out on a connection an earlier request opened, so it had no DNS lookup, TCP connect or TLS handshake of its own."

    /// Whether a waterfall should draw DNS / TCP / TLS phases for the row.
    /// A reused exchange's setup timings are zero-length by construction
    /// (core C2.7) — drawing them would show three bars of nothing.
    public static func showsConnectionSetup(reused: Bool, exchangeIndex: Int) -> Bool {
        connectionLabel(reused: reused, exchangeIndex: exchangeIndex) == nil
    }

    // MARK: Bodies kept only in part

    /// The notice for a body the extension did not keep whole, or nil when it
    /// kept all of it.
    ///
    /// `notRetained` is in bytes AS SENT (what crossed the wire, compressed if
    /// the body was); `totalAsSent` is the whole body as sent. For a
    /// content-encoded body the text on screen is a DECODED prefix, so the
    /// count is never phrased as "characters missing" (core C3.7).
    public static func notRetainedNotice(notRetained: Int64, totalAsSent: Int64) -> String? {
        guard notRetained > 0 else { return nil }
        var sentence = "Not the whole body: \(binaryBytes(notRetained)) of it as sent is not shown"
        if totalAsSent >= notRetained {
            sentence += " (\(binaryBytes(totalAsSent)) in all)"
        }
        return sentence + ". ReqRes keeps the first \(binaryBytes(CaptureEngineFacts.retainedBytesPerExchange)) of each request's bodies; the rest was sent on in full but is not kept anywhere, in the app or on disk."
    }

    /// The same fact in one line for an agent: exact bytes, no rounding.
    public static func agentNotRetainedNote(notRetained: Int64) -> String? {
        guard notRetained > 0 else { return nil }
        return "(incomplete: ReqRes kept only the first \(binaryBytes(CaptureEngineFacts.retainedBytesPerExchange)) of this row's bodies — \(notRetained) bytes of this body as sent are not in it, and not in the app either; the full body was forwarded)"
    }

    // MARK: Relayed connections

    /// The detail pane's title for a relay row.
    public static let relayTitle = "Not decrypted"

    /// The one sentence that explains a relay row.
    public static let relayExplanation =
        "Not decrypted — the ReqRes certificate was not installed and trusted when this connection opened. ReqRes passed it on without reading it, so there is no request, response, header or body to show: only where it went, the bytes that crossed it each way and how long it stayed open."

    /// What to do about it.
    public static let relayRemedy =
        "Install and trust the certificate in Settings ▸ Certificate. Connections opened after that are decrypted, with no need to restart capture; this one stays as it was recorded."

    /// Why a relay row never costs a free HTTPS inspection.
    public static let relayIsFree = "Opening a connection like this never uses one of the free version's HTTPS inspections."

    /// The table's Code cell tooltip and accessibility label.
    public static let relayCellHelp = "A connection relayed without decrypting it — the ReqRes certificate was not installed and trusted when it opened."

    // MARK: Relays that carried neither HTTP nor TLS (core C5/C7: scheme "tcp")

    /// A relay row's scheme is `https` when the app spoke TLS inside it (the
    /// certificate was not installed and trusted when it opened) and `tcp`
    /// when it spoke neither HTTP nor TLS — SSH, a database, cleartext HTTP/2
    /// — which the core relays and records whatever the certificate's state
    /// (C5's classifier with the CA, C7's without). The certificate sentences
    /// above are false for a `tcp` relay: trusting the CA changes nothing
    /// about it. (protocol-engine doc §S10.)
    public static func relayIsNotTLS(scheme: String?) -> Bool {
        scheme?.lowercased() == "tcp"
    }

    public static let tcpRelayTitle = "Not HTTP"

    public static let tcpRelayExplanation =
        "Not HTTP — this connection carried neither HTTP nor TLS (an SSH session, a database, cleartext HTTP/2), so ReqRes passed it on without reading it: there is no request, response, header or body to show — only where it went, the bytes that crossed it each way and how long it stayed open."

    public static let tcpRelayRemedy =
        "Nothing to install: ReqRes records a connection like this but does not decode its protocol. To pass it through without a row, exclude its host in Settings ▸ Capture."

    public static let tcpRelayCellHelp = "A connection relayed without reading it — it carried neither HTTP nor TLS."

    /// For a caller that does not know the row's scheme.
    public static let relayExplanationAnyScheme =
        "ReqRes passed this connection on without reading it — it was not decrypted, or it carried neither HTTP nor TLS — so there is no request, response, header or body to show."

    // `pinnedBy` (1.1.0): why a relay row is SSL pinned — a macOS pinning
    // policy, or `app:<domain>` for an app that refused ReqRes's certificate
    // (`PinSource`). It wins over the scheme: such a row is neither "the
    // certificate was not trusted" nor "not HTTP". `appName` is the row's app,
    // which an app pin names.

    public static func relayTitle(scheme: String?, pinnedBy: String? = nil) -> String {
        if PinSource(pinnedBy: pinnedBy) != nil { return PinnedHostCopy.title }
        return relayIsNotTLS(scheme: scheme) ? tcpRelayTitle : relayTitle
    }

    public static func relayExplanation(scheme: String?, pinnedBy: String? = nil, appName: String? = nil) -> String {
        if let source = PinSource(pinnedBy: pinnedBy) { return PinnedHostCopy.explanation(source, appName: appName) }
        guard let scheme else { return relayExplanationAnyScheme }
        return relayIsNotTLS(scheme: scheme) ? tcpRelayExplanation : relayExplanation
    }

    /// The word the traffic row prints after the endpoint.
    public static func relayRowWord(scheme: String?, pinnedBy: String? = nil, appName: String? = nil) -> String {
        if let source = PinSource(pinnedBy: pinnedBy) { return PinnedHostCopy.rowWord(source, appName: appName) }
        return relayIsNotTLS(scheme: scheme) ? "not HTTP" : "not decrypted"
    }

    public static func relayRemedy(scheme: String?, pinnedBy: String? = nil) -> String {
        if let source = PinSource(pinnedBy: pinnedBy) { return PinnedHostCopy.remedy(source) }
        return relayIsNotTLS(scheme: scheme) ? tcpRelayRemedy : relayRemedy
    }

    public static func relayCellHelp(scheme: String?, pinnedBy: String? = nil, appName: String? = nil) -> String {
        if let source = PinSource(pinnedBy: pinnedBy) { return PinnedHostCopy.cellHelp(source, appName: appName) }
        return relayIsNotTLS(scheme: scheme) ? tcpRelayCellHelp : relayCellHelp
    }

    /// Whether the certificate is the answer for this relay: not for a `tcp`
    /// relay, and not for an SSL-pinned one.
    public static func relayIsAboutTheCertificate(scheme: String?, pinnedBy: String?) -> Bool {
        PinSource(pinnedBy: pinnedBy) == nil && !relayIsNotTLS(scheme: scheme)
    }

    /// `api.example.com:443` from the row's host. The core records a relay's
    /// host WITHOUT the port when it is 443 and `host:port` otherwise; a
    /// connection reads by its endpoint, so the default port is written back.
    /// A bare IPv6 literal gets brackets so the port cannot read as part of it.
    public static func relayEndpoint(host: String, defaultPort: Int = 443) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "—" }
        if trimmed.hasPrefix("[") {
            // [v6] or [v6]:port
            if let close = trimmed.lastIndex(of: "]"), trimmed[close...].contains(":") { return trimmed }
            return "\(trimmed):\(defaultPort)"
        }
        let colons = trimmed.filter { $0 == ":" }.count
        if colons > 1 { return "[\(trimmed)]:\(defaultPort)" }          // bare IPv6
        if colons == 1, let colon = trimmed.lastIndex(of: ":"),
           !trimmed[trimmed.index(after: colon)...].isEmpty,
           trimmed[trimmed.index(after: colon)...].allSatisfy(\.isNumber) {
            return trimmed                                               // host:port
        }
        return "\(trimmed):\(defaultPort)"
    }

    /// "↑ 512 B  ↓ 24 KB" — a connection's traffic in both directions.
    public static func relayBytes(sent: Int64, received: Int64) -> String {
        "↑ \(binaryBytes(sent))  ↓ \(binaryBytes(received))"
    }

    /// "sent 512 B, received 24 KB" — the same for an agent's text.
    public static func agentRelayBytes(sent: Int64, received: Int64) -> String {
        "sent \(binaryBytes(sent)), received \(binaryBytes(received))"
    }

    // MARK: Formatting

    /// 1024-based, like the 16 MB limit it is compared with, so "16 MB kept
    /// of 40 MB" adds up. Whole numbers print without a decimal.
    public static func binaryBytes(_ count: Int64) -> String {
        let value = Double(max(0, count))
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaled = value
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(scaled)) B" }
        let rounded = (scaled * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded)) \(units[unit])" }
        return String(format: "%.1f", rounded) + " " + units[unit]
    }
}
