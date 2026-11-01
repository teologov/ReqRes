//
//  MCPModels.swift
//  AppServices
//
//  Created by OloApps on 8/26/26.
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

import CryptoKit
import Foundation

/// Limits shared by the bridge and its future MCP tool layer.
public enum MCPLimits {
    /// How long the bridge may hold a write while the human decides. Kept
    /// under the shortest tool-call timeout MCP clients use (Claude Desktop
    /// gives up around 60s), so an approval given in time still reaches the
    /// agent that asked for it.
    public static let consentTimeout: TimeInterval = 45
    /// Body previews are hard-capped so tool responses stay context-friendly.
    public static let bodyPreviewMaxBytes = 10_240
    public static let defaultPageSize = 30
    public static let maxPageSize = 100
    /// The MITM proxy's loopback port (the core's `MitmService`). Here so the
    /// diagnosis can name it without the pure layer importing the app.
    /// The DEFAULT proxy port. The live one is `MCPBridgeStatus.proxyPort`
    /// (Settings ▸ Capture can change it since 2026-09-29).
    public static let proxyPort = 8034
    public static let truncationMarker = "…[truncated — full body available in the app]"
}

/// Compact one-row representation of a captured session, sized for list responses.
public struct MCPSessionSummary: Codable, Equatable {
    public var uid: String
    public var host: String
    public var method: String
    public var url: String
    public var scheme: String
    public var statusCode: Int?
    public var startedAt: Date?
    public var durationMs: Double?
    public var requestBodySize: Int?
    public var responseBodySize: Int?
    public var contentType: String?
    /// The process that opened the connection to the proxy — an executable or
    /// bundle name such as "Safari", "curl" or "claude". Nil when the capture
    /// layer could not attribute it (a system process such as nsurlsessiond
    /// doing an app's background work, or a lookup that did not run), which
    /// is reported as unknown and never guessed.
    ///
    /// Attribution is per CONNECTION: a keep-alive connection carries several
    /// sessions, and all of them read the same name.
    public var app: String?
    /// The originating process id. The name alone does not separate several
    /// instances of the same tool (three `claude` processes on one Mac is
    /// ordinary); the pid does.
    public var pid: Int?
    /// Where the connection went, as a `TrafficDestination` token: a
    /// two-letter ISO country (`"US"`) the server address resolved to through
    /// the offline table, or `"local"` (a private network address) or `"mac"`
    /// (this Mac). Nil when Unknown — the row omits it rather than stamping
    /// a fourth word on every unplaceable request (destination-map UX spec
    /// §8.1). Filled by the app's summary adapter; the helper never resolves.
    public var country: String?
    /// `.relay` for a connection ReqRes relayed without decrypting it (no CA
    /// installed and trusted when it opened) — a row with no method, status,
    /// headers or body, only an endpoint, bytes each way and a duration.
    /// `.exchange` for an ordinary request. Nil from an app that predates the
    /// field, which only ever recorded exchanges.
    public var kind: MCPSessionKind?
    /// How the exchange ended (protocol PRD 3.4): completed, failed, aborted
    /// or timed out. Nil from an app that predates the field — every row such
    /// an app sent was a completed one.
    public var outcome: MCPSessionOutcome?
    /// Where it broke, when it did not complete.
    public var failurePhase: MCPFailurePhase?
    /// The core's one sentence naming the cause — a host, a port, an alert
    /// name, a number of seconds; never a header or a body.
    public var failureDetail: String?
    /// True when the APP ended an aborted exchange (decision D8).
    public var clientCancelled: Bool?
    /// True for a row that failed before connecting to any server — it went
    /// nowhere, so `list_destinations` does not count it. Nil when unknown.
    public var neverConnected: Bool?
    /// Set while the exchange is still open (a live row, protocol PRD 4a.1),
    /// and on a row that stopped being live without its final row. Nil for an
    /// ordinary finished row — and from an app that predates live rows.
    public var live: MCPLiveState?
    /// The RPC's own status for a gRPC-Web, Connect or (trailers-only)
    /// native gRPC row — `0` OK, `5` NOT_FOUND, … — which a gRPC-Web error
    /// carries under an HTTP 200 (protocol-engine doc §S8). Nil for a row
    /// that is not an RPC, or whose status was not recorded.
    public var grpcStatus: Int?
    /// The HTTP version the row RECORDED — `"HTTP/1.1"`, `"HTTP/2.0"` (NIO's
    /// spelling) — never a constant (protocol-engine doc §S9). Nil when the
    /// row has none: a relay (nothing inside it was read), or a request that
    /// failed before its head.
    public var httpVersion: String?
    /// What the row spoke, as one token: `h1`, `h2`, `ws` (a WebSocket after
    /// its upgrade — its handshake was HTTP/1.1) or `relay`
    /// (`SessionProtocol`). Nil when none was recorded. `list_sessions
    /// proto=` matches it.
    public var proto: String?
    /// For a relay to a host macOS itself pins: the macOS pinning policy
    /// ("MMCS", "AMP", …; `PinnedHostCopy`). Nil for every other row, and
    /// from an app that predates the field.
    public var pinnedBy: String?
    public init(
        uid: String,
        host: String,
        method: String,
        url: String,
        scheme: String,
        statusCode: Int? = nil,
        startedAt: Date? = nil,
        durationMs: Double? = nil,
        requestBodySize: Int? = nil,
        responseBodySize: Int? = nil,
        contentType: String? = nil,
        app: String? = nil,
        pid: Int? = nil,
        country: String? = nil,
        kind: MCPSessionKind? = nil,
        outcome: MCPSessionOutcome? = nil,
        failurePhase: MCPFailurePhase? = nil,
        failureDetail: String? = nil,
        clientCancelled: Bool? = nil,
        neverConnected: Bool? = nil,
        live: MCPLiveState? = nil,
        grpcStatus: Int? = nil,
        httpVersion: String? = nil,
        proto: String? = nil,
        pinnedBy: String? = nil
    ) {
        self.uid = uid
        self.host = host
        self.method = method
        self.url = url
        self.scheme = scheme
        self.statusCode = statusCode
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.requestBodySize = requestBodySize
        self.responseBodySize = responseBodySize
        self.contentType = contentType
        self.app = app
        self.pid = pid
        self.country = country
        self.kind = kind
        self.outcome = outcome
        self.failurePhase = failurePhase
        self.failureDetail = failureDetail
        self.clientCancelled = clientCancelled
        self.neverConnected = neverConnected
        self.live = live
        self.grpcStatus = grpcStatus
        self.httpVersion = httpVersion
        self.proto = proto
        self.pinnedBy = pinnedBy
    }

    /// The row's protocol: the `proto` the app sent, else derived from what
    /// the summary does carry (a row from a helper-side fixture or an older
    /// app: a relay, a 101, the recorded version).
    public var sessionProtocol: SessionProtocol? {
        if let proto, let parsed = SessionProtocol.parse(proto) { return parsed }
        return SessionProtocol.classify(httpVersion: httpVersion, isRelay: isRelay, isWebSocket: statusCode == 101)
    }

    /// Still open: no final row yet (waiting for its response head, or
    /// streaming its body).
    public var isInFlight: Bool { live?.isInFlight ?? false }

    /// It stopped being live WITHOUT its final row (`MCPLiveState.phase`
    /// `ended`): capture stopped, or its end was lost. Its facts are the
    /// last ones heard, and its body is not in the app.
    public var endedWithoutFinal: Bool { live?.phase == .ended }

    /// Whether this row has got as far as `stage` (a finished row has got as
    /// far as every stage). `wait_for_session(until:)`'s question.
    public func hasReached(_ stage: MCPWaitStage) -> Bool {
        guard let live, live.isInFlight else { return true }
        switch stage {
        case .complete: return false
        case .headers: return live.phase == .streaming
        case .firstMessage: return live.phase == .streaming && (live.completeMessages ?? 0) > 0
        }
    }

    /// True for a relayed connection. Nil (an older app) is an exchange.
    public var isRelay: Bool { kind == .relay }

    /// How it ended; nil (an older app) is completed.
    public var effectiveOutcome: MCPSessionOutcome { outcome ?? .completed }

    /// The failure's facts, or nil for a completed row.
    public var failureFacts: FailureRowFacts? {
        guard effectiveOutcome.isFailure else { return nil }
        return FailureRowFacts(
            outcome: effectiveOutcome,
            phase: failurePhase,
            detail: failureDetail,
            clientCancelled: clientCancelled ?? false,
            status: statusCode.map(String.init),
            hasServerAddress: !(neverConnected ?? false)
        )
    }
}

/// The line that stands in for a body an agent cannot be handed as text: a
/// binary one (protobuf, an image, a multipart upload with a file) or one
/// still under a coding ReqRes did not undo (compress). Said on BOTH sides —
/// a binary REQUEST used to leave no line at all, which read as an empty
/// POST — with its size and a short SHA-256, so `diff_sessions` can tell two
/// such bodies apart and a HAR says what was there (release review,
/// 2026-09-29). The digest is 12 hex characters: short enough that the
/// redactor's entropy pass leaves it alone, long enough to compare.
public enum MCPBinaryBody {
    public static func description(contentType: String?, bytes: Data, undecodedEncoding: String? = nil) -> String {
        let type = (contentType?.isEmpty == false) ? contentType! : "binary"
        let digest = SHA256.hash(data: bytes).prefix(6).map { String(format: "%02x", $0) }.joined()
        if let coding = undecodedEncoding, !coding.isEmpty {
            return "[body omitted — still \(coding)-encoded (ReqRes does not decode \(coding)), \(type), \(bytes.count) bytes, sha256 \(digest)]"
        }
        return "[binary body omitted — \(type), \(bytes.count) bytes, sha256 \(digest)]"
    }

    /// True for a line `description` wrote (and the older form without a
    /// digest), so a HAR writes it as a comment rather than as the body.
    public static func isDescription(_ text: String) -> Bool {
        text.hasPrefix("[binary body omitted — ") || text.hasPrefix("[body omitted — still ")
    }
}

/// Full detail for a single session. Body previews arrive pre-decoded from the
/// capture layer; the router enforces the preview cap and redaction on top.
public struct MCPSessionDetail: Codable, Equatable {
    public var summary: MCPSessionSummary
    public var requestHeaders: [String: String]
    public var responseHeaders: [String: String]
    public var requestBodyPreview: String?
    public var responseBodyPreview: String?
    public var requestBodyTruncated: Bool
    public var responseBodyTruncated: Bool
    public var curl: String?
    /// The raw server address the proxy connected to (a bare IP literal from
    /// the core), detail only — the list carries the country token instead.
    /// Nil when the upstream connect never happened or the extension predates
    /// the field. Passed through redaction: an address is not a credential.
    public var serverAddress: String?
    /// True when this exchange rode a connection an earlier one opened — it
    /// had no DNS/TCP/TLS of its own. Nil from an app that predates the field.
    public var connectionReused: Bool?
    /// 0, 1, 2, … — this exchange's place on its connection.
    public var exchangeIndex: Int?
    /// Bytes of the request body AS SENT that the capture did not keep (the
    /// extension keeps 16 MB per exchange and forwards everything). Anything
    /// above zero means `requestBodyPreview` is not the whole body — and the
    /// missing part is not in the app either. This is a different fact from
    /// `requestBodyTruncated`, which is the bridge's own preview cap.
    public var requestBodyNotRetainedBytes: Int64?
    /// The same for the response body.
    public var responseBodyNotRetainedBytes: Int64?
    /// Header fields sent AFTER the body (core C13): an HTTP/2 trailing
    /// HEADERS frame or an HTTP/1.1 chunked trailer section — where native
    /// gRPC's `grpc-status` is. Nil when the message had none. Redacted like
    /// headers (`MCPRedactor.redactDetail`).
    public var requestTrailers: [String: String]?
    public var responseTrailers: [String: String]?

    public init(
        summary: MCPSessionSummary,
        requestHeaders: [String: String] = [:],
        responseHeaders: [String: String] = [:],
        requestBodyPreview: String? = nil,
        responseBodyPreview: String? = nil,
        requestBodyTruncated: Bool = false,
        responseBodyTruncated: Bool = false,
        curl: String? = nil,
        serverAddress: String? = nil,
        connectionReused: Bool? = nil,
        exchangeIndex: Int? = nil,
        requestBodyNotRetainedBytes: Int64? = nil,
        responseBodyNotRetainedBytes: Int64? = nil,
        requestTrailers: [String: String]? = nil,
        responseTrailers: [String: String]? = nil
    ) {
        self.summary = summary
        self.requestTrailers = requestTrailers.flatMap { $0.isEmpty ? nil : $0 }
        self.responseTrailers = responseTrailers.flatMap { $0.isEmpty ? nil : $0 }
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBodyPreview = requestBodyPreview
        self.responseBodyPreview = responseBodyPreview
        self.requestBodyTruncated = requestBodyTruncated
        self.responseBodyTruncated = responseBodyTruncated
        self.curl = curl
        self.serverAddress = serverAddress
        self.connectionReused = connectionReused
        self.exchangeIndex = exchangeIndex
        self.requestBodyNotRetainedBytes = requestBodyNotRetainedBytes
        self.responseBodyNotRetainedBytes = responseBodyNotRetainedBytes
    }

    /// Bytes of `side`'s body the capture did not keep; 0 when it kept it all
    /// or the app predates the field.
    public func notRetainedBytes(_ side: MCPBodySide) -> Int64 {
        max(0, (side == .request ? requestBodyNotRetainedBytes : responseBodyNotRetainedBytes) ?? 0)
    }
}

/// One readiness snapshot: capture state, extension setup, CA trust, counts.
public struct MCPBridgeStatus: Codable, Equatable {
    public var captureActive: Bool
    public var vpnStatus: String
    public var extensionStatus: String
    public var caCertificateInstalled: Bool?
    public var caCertificateTrusted: Bool?
    public var sessionCount: Int
    public var appVersion: String
    public var bridgeVersion: Int
    /// Where the user last exported the ReqRes CA as a PEM file from
    /// Settings ▸ Capture (the app's status adapter reads UserDefaults
    /// `CaptureEnvironmentLines.exportedPathDefaultsKey`), or nil before any
    /// export. `capture_environment` prints its certificate lines against
    /// this path exactly as the pane does — one renderer, one path — and
    /// falls back to the keychain step when it is nil. Optional and absent
    /// from older statuses, so a helper and an app of different builds still
    /// decode each other.
    public var caExportedPath: String?
    /// True when the file at `caExportedPath` holds a CA other than this
    /// install's (`CaptureEnvironmentLines.exportFreshness` → `.outdated`):
    /// every tool pointed at it fails TLS. Nil when unknown or nothing was
    /// exported. Optional, absent from older statuses.
    public var caExportedCertificateOutdated: Bool?
    /// How many "ReqRes CA" certificates in the keychain are NOT this
    /// install's — the 1.0.x shared one (its private key is public) or an
    /// earlier install's. Nil when the app did not look. Optional, absent
    /// from older statuses.
    public var caOutdatedCertificatesInstalled: Int?
    /// This install's CA SHA-256 (hex), which `capture_environment`'s keychain
    /// step selects by — an older "ReqRes CA" can sit beside it under the
    /// same name. Nil when the app could not produce its CA. Optional,
    /// absent from older statuses.
    public var caFingerprintSHA256: String?
    /// The user's HTTP/2 capture setting (Settings ▸ Capture, off by
    /// default); nil when the app did not say. `MCPSetupFacts` takes it from
    /// here unless given one, so diagnose_setup and capture_status read the
    /// same value (doc §S13). Optional, absent from older statuses.
    public var http2CaptureEnabled: Bool?
    /// What each protocol does, short, with this Mac's notes
    /// (`ProtocolSupport.statusLines(state:)`). Filled by the bridge's
    /// `/v1/status` route only — the one capture_status reads — and nil in
    /// every other response that carries a status (start/stop capture).
    /// Optional, absent from older statuses.
    public var protocols: [ProtocolSupportStatusLine]?
    /// The port ReqRes's proxy listens on: the running capture's, else the
    /// one Settings ▸ Capture will use next (8034 unless the user changed
    /// it). Optional, absent from older statuses — read it through
    /// `effectiveProxyPort`.
    public var proxyPort: Int?
    /// Whether what capture records reaches this app (F11): capture can be
    /// on while nothing arrives — for a few seconds after a relaunch while
    /// the extension reconnects, or until capture is started again from
    /// ReqRes when it cannot. Read by capture_status's Delivery line and
    /// diagnose_setup's `delivery` check. Optional, absent from older
    /// statuses (both then say nothing about it).
    public var delivery: MCPCaptureDelivery?

    /// `proxyPort`, or the default an app that predates the setting used.
    public var effectiveProxyPort: Int { proxyPort ?? MCPLimits.proxyPort }

    public init(
        captureActive: Bool,
        vpnStatus: String,
        extensionStatus: String,
        caCertificateInstalled: Bool? = nil,
        caCertificateTrusted: Bool? = nil,
        sessionCount: Int = 0,
        appVersion: String = "",
        bridgeVersion: Int = MCPBridgeRouter.bridgeVersion,
        caExportedPath: String? = nil,
        caExportedCertificateOutdated: Bool? = nil,
        caOutdatedCertificatesInstalled: Int? = nil,
        caFingerprintSHA256: String? = nil,
        http2CaptureEnabled: Bool? = nil,
        protocols: [ProtocolSupportStatusLine]? = nil,
        proxyPort: Int? = nil,
        delivery: MCPCaptureDelivery? = nil
    ) {
        self.captureActive = captureActive
        self.vpnStatus = vpnStatus
        self.extensionStatus = extensionStatus
        self.caCertificateInstalled = caCertificateInstalled
        self.caCertificateTrusted = caCertificateTrusted
        self.sessionCount = sessionCount
        self.appVersion = appVersion
        self.bridgeVersion = bridgeVersion
        self.caExportedPath = caExportedPath
        self.caExportedCertificateOutdated = caExportedCertificateOutdated
        self.caOutdatedCertificatesInstalled = caOutdatedCertificatesInstalled
        self.caFingerprintSHA256 = caFingerprintSHA256
        self.http2CaptureEnabled = http2CaptureEnabled
        self.protocols = protocols
        self.proxyPort = proxyPort
        self.delivery = delivery
    }
}

/// A query-string parameter `/v1/sessions` could not use.
///
/// Refused with a 400 rather than dropped: a dropped filter hands back an
/// unfiltered page that the agent reads as filtered — the same failure the
/// attribution filters were once removed for, one layer down from the tool.
/// The stdio helper already refuses a non-numeric `pid` before it reaches
/// the bridge; this is the same rule for anything else that speaks HTTP to it.
public struct MCPQueryParameterError: Error, Equatable, Sendable {
    public let parameter: String
    public let message: String

    public init(parameter: String, message: String) {
        self.parameter = parameter
        self.message = message
    }
}

/// Filters accepted by the session list endpoint. All criteria AND together.
public struct MCPSessionFilter: Equatable {
    /// Case-insensitive substring match on the host.
    public var host: String?
    /// Case-insensitive exact match ("GET", "post", …).
    public var method: String?
    /// "2xx".."5xx" class or an exact code like "404".
    public var status: String?
    /// Exact scheme ("http"/"https").
    public var scheme: String?
    /// Case-insensitive substring match on the full URL.
    public var urlContains: String?
    /// Case-insensitive substring match on the originating app — "claude"
    /// finds "Claude" and "claude-code". A session with no attribution is
    /// EXCLUDED when this is set: the agent asked for one app's traffic, and
    /// "unknown" is not that app.
    public var app: String?
    /// Exact match on the originating process id.
    public var pid: Int?
    /// Where the connection went: a two-letter ISO code (normalised upper),
    /// or `local` / `mac` / `unknown` (destination-map UX spec §8.2).
    /// `unknown` selects the sessions whose `country` is nil; a code or a
    /// class compares the token exactly. Names are not accepted.
    public var country: String?
    /// How the exchange ended: `completed`, `failed`, `aborted` or
    /// `timed_out` (`MCPSessionOutcome.parse`). A summary from an app that
    /// predates the field is completed.
    public var outcome: String?
    /// The RPC status (protocol-engine doc §S8): `error` (anything but OK),
    /// `ok`, a code name (`NOT_FOUND`, `not_found`) or a number
    /// (`RPCStatusMatch.parse`). A row that is not an RPC, or whose status
    /// was not recorded, matches none of them.
    public var grpc: String?
    /// The row's protocol (protocol-engine doc §S9): `h1`, `h2`, `ws` or
    /// `relay`, or a spelling `SessionProtocol.parse` reads (`http2`,
    /// `websocket`). A row with no recorded protocol matches none.
    public var proto: String?
    public init(
        host: String? = nil,
        method: String? = nil,
        status: String? = nil,
        scheme: String? = nil,
        urlContains: String? = nil,
        app: String? = nil,
        pid: Int? = nil,
        country: String? = nil,
        outcome: String? = nil,
        grpc: String? = nil,
        proto: String? = nil
    ) {
        self.host = host
        self.method = method
        self.status = status
        self.scheme = scheme
        self.urlContains = urlContains
        self.app = app
        self.pid = pid
        self.country = country
        self.outcome = outcome
        self.grpc = grpc
        self.proto = proto
    }

    /// The 400 an unusable `grpc` earns — refused, never dropped.
    public static func grpcParameterError(_ value: String) -> MCPQueryParameterError {
        MCPQueryParameterError(
            parameter: "grpc",
            message: "'grpc' must be error, ok, a status name such as NOT_FOUND, or a status number — got '\(value)'."
        )
    }

    /// The outcome this filter asks for, parsed; nil when none (or unusable —
    /// the query-string path refuses that earlier with a 400).
    public var wantedOutcome: MCPSessionOutcome? {
        outcome.flatMap(MCPSessionOutcome.parse)
    }

    /// The 400 an unusable `outcome` earns — refused, never dropped.
    public static func outcomeParameterError(_ value: String) -> MCPQueryParameterError {
        MCPQueryParameterError(
            parameter: "outcome",
            message: "'outcome' must be one of \(MCPSessionOutcome.tokens.joined(separator: ", ")) — got '\(value)'."
        )
    }

    /// The 400 an unusable `country` earns (spec §8.2) — the `pid` precedent:
    /// a filter that cannot be applied is refused, never dropped.
    public static func countryParameterError(_ value: String) -> MCPQueryParameterError {
        MCPQueryParameterError(
            parameter: "country",
            message: "'country' must be a two-letter ISO code (US), or local, mac or unknown — got '\(value)'. Names are not accepted; codes are."
        )
    }

    /// Reads the filter out of a query string. Throws `MCPQueryParameterError`
    /// for a `pid` that is not an integer: `?pid=curl` is a typo for
    /// `?app=curl`, and answering it with every session would be answering a
    /// question nobody asked. The same for a `country` that is neither a
    /// two-letter code nor one of the three class words.
    public init(queryItems: [URLQueryItem]) throws {
        for item in queryItems {
            guard let value = item.value, !value.isEmpty else { continue }
            switch item.name {
            case "host": host = value
            case "method": method = value
            case "status": status = value
            case "scheme": scheme = value
            case "url_contains": urlContains = value
            case "app": app = value
            case "pid":
                guard let parsed = Int(value.trimmingCharacters(in: .whitespaces)) else {
                    throw MCPQueryParameterError(
                        parameter: "pid",
                        message: "'pid' must be an integer process id, e.g. 9437 — got '\(value)'. To filter by process NAME, use 'app'."
                    )
                }
                pid = parsed
            case "country":
                guard let destination = TrafficDestination.parseToken(value) else {
                    throw Self.countryParameterError(value)
                }
                country = destination.token
            case "outcome":
                guard let parsed = MCPSessionOutcome.parse(value) else {
                    throw Self.outcomeParameterError(value)
                }
                outcome = parsed.token
            case "grpc":
                guard let parsed = RPCStatusMatch.parse(value) else {
                    throw Self.grpcParameterError(value)
                }
                grpc = parsed.token
            case "proto", "protocol":
                guard let parsed = SessionProtocol.parse(value) else {
                    throw SessionProtocol.parameterError(value)
                }
                proto = parsed.token
            default: break
            }
        }
    }

    /// `"host=api.example.com, app=claude"` — the filter as an agent would
    /// read it back, for the `list_destinations` heading; nil when empty.
    public var summaryText: String? {
        var parts: [String] = []
        if let host { parts.append("host=\(host)") }
        if let method { parts.append("method=\(method)") }
        if let status { parts.append("status=\(status)") }
        if let scheme { parts.append("scheme=\(scheme)") }
        if let urlContains { parts.append("url_contains=\(urlContains)") }
        if let app { parts.append("app=\(app)") }
        if let pid { parts.append("pid=\(pid)") }
        if let country { parts.append("country=\(country)") }
        if let outcome { parts.append("outcome=\(outcome)") }
        if let grpc { parts.append("grpc=\(grpc)") }
        if let proto { parts.append("proto=\(proto)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    public func matches(_ session: MCPSessionSummary) -> Bool {
        matches(session, redactor: nil)
    }

    /// `redactor` is the one the answer will be redacted with. When given,
    /// `url_contains` is matched against the URL AS THE AGENT WILL SEE IT:
    /// matched against the raw URL, a filter for `access_token=a`, `…=ab`, …
    /// would read a masked query value back one character at a time through
    /// `totalMatched` (release review, 2026-09-29; the message filter made
    /// the same choice, `MCPMessageFilter`). Checked last, so the URL is
    /// only redacted for rows every cheaper filter already let through.
    public func matches(_ session: MCPSessionSummary, redactor: MCPRedactor?) -> Bool {
        if let host, !session.host.localizedCaseInsensitiveContains(host) { return false }
        if let method, session.method.caseInsensitiveCompare(method) != .orderedSame { return false }
        if let scheme, session.scheme.caseInsensitiveCompare(scheme) != .orderedSame { return false }
        guard matchesExceptURL(session) else { return false }
        if let urlContains {
            let url = redactor.map { $0.redacts(host: session.host) ? $0.redactURL(session.url) : session.url } ?? session.url
            if !url.localizedCaseInsensitiveContains(urlContains) { return false }
        }
        return true
    }

    private func matchesExceptURL(_ session: MCPSessionSummary) -> Bool {
        if let app {
            guard let sessionApp = session.app, sessionApp.localizedCaseInsensitiveContains(app) else { return false }
        }
        if let pid, session.pid != pid { return false }
        if let country {
            // Normalised here too, so a filter built with the memberwise
            // initialiser ("us") answers like one read from a query string.
            // An unparseable value matches nothing — the query-string path
            // refuses it earlier with a 400; this is the guard for a filter
            // built by hand.
            guard let wanted = TrafficDestination.parseToken(country) else { return false }
            let actual = session.country.flatMap(TrafficDestination.parseToken) ?? .unknown
            if actual != wanted { return false }
        }
        if let outcome {
            // Same guard shape as `country`: an unparseable value built by
            // hand matches nothing.
            guard let wanted = MCPSessionOutcome.parse(outcome), session.effectiveOutcome == wanted else { return false }
        }
        if let grpc {
            guard let wanted = RPCStatusMatch.parse(grpc), wanted.matches(session.grpcStatus) else { return false }
        }
        if let proto {
            guard let wanted = SessionProtocol.parse(proto), session.sessionProtocol == wanted else { return false }
        }
        if let status {
            guard let code = session.statusCode else { return false }
            let normalized = status.lowercased()
            if normalized.hasSuffix("xx"), normalized.count == 3, let classDigit = normalized.first?.wholeNumberValue {
                if code / 100 != classDigit { return false }
            } else if let exact = Int(normalized) {
                if code != exact { return false }
            } else {
                return false
            }
        }
        return true
    }
}

/// One page of session summaries, newest first.
public struct MCPSessionPage: Codable, Equatable {
    public var sessions: [MCPSessionSummary]
    public var nextCursor: String?
    public var totalMatched: Int
    /// Set when results were left out, so an agent knows to refine or paginate.
    public var note: String?

    public init(sessions: [MCPSessionSummary], nextCursor: String?, totalMatched: Int, note: String?) {
        self.sessions = sessions
        self.nextCursor = nextCursor
        self.totalMatched = totalMatched
        self.note = note
    }
}

/// The running app supplies captured sessions to the bridge through this seam.
/// Kept core-agnostic so MCPKit stays testable without the closed framework.
public protocol MCPSessionProviding {
    /// All sessions of the current run, in arrival order (oldest first).
    func sessionSummaries() -> [MCPSessionSummary]
    func sessionDetail(uid: String) -> MCPSessionDetail?
    /// The FULL, uncapped body — queried app-side so only the matched subset
    /// crosses the wire. Returns nil when the session or side has no text body.
    func sessionBody(uid: String, side: MCPBodySide) -> String?
    /// The two facts that change what a body query's answer means — whether
    /// the row is a relay (no body exists) and how much of each body the
    /// capture did not keep — without building a whole detail (which renders
    /// a cURL from a request body of up to 16 MB). Nil when the session is
    /// unknown. Has a default derived from `sessionDetail`.
    func sessionBodyFacts(uid: String) -> MCPSessionBodyFacts?
    /// What the stream views (`get_session view=events|assembled`) need
    /// besides the body: content type, host, response duration, what was not
    /// kept. Nil when the session is unknown. Default derived from
    /// `sessionDetail` (MCPStreamModels.swift).
    func sessionStreamFacts(uid: String) -> MCPSessionStreamFacts?
    /// The response text the stream views read: the whole body of a finished
    /// row, or — for a row still in flight — the text that has arrived so far
    /// (only its COMPLETE events ever leave; the parser withholds the tail).
    /// Default: `sessionBody(uid:side: .response)`.
    func sessionStreamBody(uid: String) -> String?
    /// A `101` row's WebSocket connection and its kept messages
    /// (`list_messages`). Nil when the uid is unknown. Default: nil
    /// (MCPWebSocketModels.swift).
    func socketConversation(uid: String) -> MCPSocketConversation?
    /// Kept WebSocket messages with an ordinal after `ordinal`, across every
    /// connection, oldest first, at most `scanLimit` (`wait_for_message`).
    /// `ordinal` nil: none, only the newest ordinal. Default: nothing.
    func socketFeed(afterOrdinal ordinal: Int64?, scanLimit: Int) -> MCPSocketFeedRaw
    /// A row's bytes and headers for `get_session view=rpc` (protocol-engine
    /// doc §S8). Nil when the uid is unknown. Default: nil
    /// (MCPRPCModels.swift) — a REQUIREMENT, so the router's existential
    /// calls the app's implementation, never the default.
    func sessionRPCFacts(uid: String) -> MCPSessionRPCFacts?
}

extension MCPSessionProviding {
    public func sessionRPCFacts(uid: String) -> MCPSessionRPCFacts? { nil }

    public func sessionStreamBody(uid: String) -> String? {
        sessionBody(uid: uid, side: .response)
    }

    public func sessionBodyFacts(uid: String) -> MCPSessionBodyFacts? {
        sessionDetail(uid: uid).map(MCPSessionBodyFacts.init(detail:))
    }
}

/// What `query_session_body` must know about a row besides its body.
public struct MCPSessionBodyFacts: Equatable, Sendable {
    public var isRelay: Bool
    public var requestNotRetainedBytes: Int64
    public var responseNotRetainedBytes: Int64
    /// A live row — in flight, or ended without its final row. Its bodies
    /// are snapshots and may be prefixes, so neither is queried
    /// (`MCPSessionDetail.withholdingLiveBodies`).
    public var isLive: Bool

    public init(isRelay: Bool, requestNotRetainedBytes: Int64 = 0, responseNotRetainedBytes: Int64 = 0, isLive: Bool = false) {
        self.isRelay = isRelay
        self.requestNotRetainedBytes = max(0, requestNotRetainedBytes)
        self.responseNotRetainedBytes = max(0, responseNotRetainedBytes)
        self.isLive = isLive
    }

    public init(detail: MCPSessionDetail) {
        self.init(
            isRelay: detail.summary.isRelay,
            requestNotRetainedBytes: detail.notRetainedBytes(.request),
            responseNotRetainedBytes: detail.notRetainedBytes(.response),
            isLive: detail.summary.live != nil
        )
    }

    public func notRetainedBytes(_ side: MCPBodySide) -> Int64 {
        side == .request ? requestNotRetainedBytes : responseNotRetainedBytes
    }
}

public extension MCPSessionDetail {
    /// A live row's detail with NO body and no cURL (protocol-engine doc §S6).
    ///
    /// A live snapshot's bodies are whatever had arrived: a request still
    /// uploading, or one past the 64 KB the live snapshot shows, is a
    /// PREFIX. Redaction parses — a JSON prefix does not parse, falls through
    /// to the free-text pass, and `"password":"hunter2"` goes out verbatim.
    /// Before live rows every row was finished, with bodies complete up to
    /// the 16 MB cap, so this path did not exist. The same holds for a row
    /// that ended without its final row: its facts are the last snapshot.
    /// Applied at the bridge's egress, so no provider can forget it.
    func withholdingLiveBodies() -> MCPSessionDetail {
        guard summary.live != nil else { return self }
        var withheld = self
        withheld.requestBodyPreview = nil
        withheld.responseBodyPreview = nil
        withheld.requestBodyTruncated = false
        withheld.responseBodyTruncated = false
        withheld.curl = nil
        return withheld
    }
}

public enum MCPBodySide: String, Codable, CaseIterable {
    case request
    case response
}

/// Result of a server-side body query.
public struct MCPBodyQueryResult: Codable, Equatable {
    public var uid: String
    public var side: MCPBodySide
    public var mode: String
    public var path: String?
    public var found: Bool
    public var text: String
    /// Bytes of the queried body AS SENT that the capture did not keep. Above
    /// zero, `text` describes a PREFIX of the body — a structure with keys
    /// missing, or a path that is absent only because it was never kept.
    /// Nil from an app that predates the field.
    public var notRetainedBytes: Int64?

    public init(uid: String, side: MCPBodySide, mode: String, path: String?, found: Bool, text: String, notRetainedBytes: Int64? = nil) {
        self.uid = uid
        self.side = side
        self.mode = mode
        self.path = path
        self.found = found
        self.text = text
        self.notRetainedBytes = notRetainedBytes
    }
}

/// The running app supplies capture/setup state through this seam.
public protocol MCPStatusProviding {
    func bridgeStatus() -> MCPBridgeStatus
    /// Everything `diagnose_setup` needs. Defaulted to what `bridgeStatus`
    /// already knows, so an implementor that cannot see the keychain, the
    /// bundle path or the socket reports those as unknown rather than being
    /// forced to guess — a check that did not run is never reported as one
    /// that passed.
    func setupFacts() -> MCPSetupFacts
}

extension MCPStatusProviding {
    public func setupFacts() -> MCPSetupFacts {
        let status = bridgeStatus()
        return MCPSetupFacts(status: status, proxyPort: status.effectiveProxyPort)
    }
}

// MARK: - Live rows (protocol PRD 4a.2)

/// Where a live row stands, as an agent reads it.
public enum MCPLivePhase: String, Codable, Equatable, Sendable, CaseIterable {
    /// No response head yet.
    case waiting
    /// The response head arrived; the body is still coming.
    case streaming
    /// No longer in flight, but its final row never came (capture stopped,
    /// or the extension's end of it was lost). Not a completed exchange.
    case ended

    /// An unknown value from a later app reads as `streaming` (still open) —
    /// the core's own fallback for the same field.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MCPLivePhase(rawValue: raw) ?? .streaming
    }
}

/// `wait_for_session(until:)`: how far a new request must get.
public enum MCPWaitStage: String, Codable, Equatable, Sendable, CaseIterable {
    /// Its response head arrived (status and headers are known) — or it
    /// finished, whichever first.
    case headers
    /// Its first COMPLETE event or line arrived (an SSE or NDJSON stream), or
    /// it finished. A response that is not a stream has no messages before
    /// its end, so for it this is `complete`.
    case firstMessage = "first_message"
    /// It finished (today's behaviour, the default).
    case complete

    /// Reads `headers`, `first_message` (or `first_event`, `firstMessage`)
    /// and `complete`; nil otherwise.
    public static func parse(_ value: String) -> MCPWaitStage? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "headers", "head": return .headers
        case "first_message", "firstmessage", "first_event", "first-message": return .firstMessage
        case "complete", "completed", "end": return .complete
        default: return nil
        }
    }
}

/// A live row's facts for agents. Numbers and enums only: nothing here is
/// captured text, so nothing here can carry a credential.
public struct MCPLiveState: Codable, Equatable, Sendable {
    public var phase: MCPLivePhase
    /// Body bytes so far each way, as sent.
    public var requestBytes: Int64
    public var responseBytes: Int64
    public var requestComplete: Bool
    /// For an SSE / NDJSON response: complete events or lines so far.
    public var completeMessages: Int?
    /// For a stream: bytes of an event or line not finished yet — withheld.
    public var pendingBytes: Int?
    /// Seconds since the request started, when the app answered.
    public var elapsedSeconds: Double?
    /// For `ended`: why.
    public var endReason: LiveEndReason?

    public init(phase: MCPLivePhase, requestBytes: Int64 = 0, responseBytes: Int64 = 0, requestComplete: Bool = false,
                completeMessages: Int? = nil, pendingBytes: Int? = nil, elapsedSeconds: Double? = nil,
                endReason: LiveEndReason? = nil) {
        self.phase = phase
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.requestComplete = requestComplete
        self.completeMessages = completeMessages
        self.pendingBytes = pendingBytes
        self.elapsedSeconds = elapsedSeconds
        self.endReason = endReason
    }

    public var isInFlight: Bool { phase != .ended }

    /// Built from the app's live row state.
    public init(state: LiveRowState, elapsedSeconds: Double?) {
        self.init(
            phase: state.phase == .waiting ? .waiting : .streaming,
            requestBytes: state.requestBytes,
            responseBytes: state.responseBytes,
            requestComplete: state.requestComplete,
            completeMessages: state.streamFormat == nil ? nil : state.completeMessages,
            pendingBytes: state.streamFormat == nil ? nil : state.pendingBytes,
            elapsedSeconds: elapsedSeconds
        )
    }
}
