//
//  SessionCodable+Recorded.swift
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
//  The ONE place the views read the 1.1.0 core's per-row facts — a reused
//  connection, a body kept only in part, a relayed connection (protocol-engine
//  doc §C2, §C3). Every sentence comes from `RecordedExchangeCopy` (MCPKit),
//  which the agent surface prints too, so the window and an agent cannot
//  describe the same row two ways.
//

import Foundation
import MCPKit
import XReqResCore

extension SessionCodable {
    /// "Reused connection · request 3 on it", or nil for the exchange that
    /// opened its connection (and for every row an older core recorded).
    var reusedConnectionLabel: String? {
        guard !relayed else { return nil }
        return RecordedExchangeCopy.connectionLabel(reused: connectionReused, exchangeIndex: exchangeIndex)
    }

    /// The request body's "not the whole body" notice, or nil when it was kept
    /// whole. `requestBytes` is the whole body as sent (the core counts every
    /// byte it forwarded, kept or not).
    var requestBodyNotice: String? {
        guard !relayed else { return nil }
        return RecordedExchangeCopy.notRetainedNotice(notRetained: reqBodyTruncatedBytes, totalAsSent: requestBytes.int64Value)
    }

    /// The same for the response body.
    var responseBodyNotice: String? {
        guard !relayed else { return nil }
        return RecordedExchangeCopy.notRetainedNotice(notRetained: rspBodyTruncatedBytes, totalAsSent: responseBytes.int64Value)
    }

    /// `api.example.com:443` — a relay row's endpoint.
    var relayEndpoint: String { RecordedExchangeCopy.relayEndpoint(host: host) }

    /// "↑ 512 B  ↓ 24 KB" — a relay row's traffic, each way.
    var relayBytesText: String {
        RecordedExchangeCopy.relayBytes(sent: requestBytes.int64Value, received: responseBytes.int64Value)
    }

    // MARK: Protocol (protocol-engine doc §S9)

    /// The version this row recorded: the request's, else the response's
    /// (NIO's `"HTTP/2.0"` / `"HTTP/1.1"`). Nil when neither was recorded —
    /// a relay, or a request that failed before its head.
    var recordedHTTPVersion: String? {
        let request = reqHTTPVersion.trimmingCharacters(in: .whitespaces)
        if !request.isEmpty { return request }
        let response = rspHTTPVersion?.trimmingCharacters(in: .whitespaces) ?? ""
        return response.isEmpty ? nil : response
    }

    /// What the row spoke — ONE classification (`SessionProtocol`) for the
    /// Metrics row, the `proto:` chip and the agent's `proto`.
    var sessionProtocol: SessionProtocol? {
        SessionProtocol.classify(httpVersion: recordedHTTPVersion, isRelay: relayed, isWebSocket: isWebSocketUpgrade)
    }

    /// "HTTP/2", "HTTP/1.1", "WebSocket", "relay/tcp", or "Not recorded".
    var protocolLabel: String {
        SessionProtocolPresentation.label(httpVersion: recordedHTTPVersion, isRelay: relayed, isWebSocket: isWebSocketUpgrade)
    }

    /// The Metrics row's second line; nil for plain HTTP/1.1.
    var protocolCaption: String? {
        SessionProtocolPresentation.caption(httpVersion: recordedHTTPVersion, isRelay: relayed, isWebSocket: isWebSocketUpgrade)
    }

    // MARK: Trailers (core C13)

    /// A copy of this row whose request headers ARE its request trailers, so
    /// the core's own Headers renderer draws them with the headers'
    /// typography; nil when the request had none.
    var requestTrailersAsHeaders: SessionCodable? {
        guard let reqTrailers, !MCPRecordedHeaders.pairs(from: reqTrailers).isEmpty else { return nil }
        var copy = self
        copy.reqHeaders = reqTrailers
        return copy
    }

    /// The same for the response.
    var responseTrailersAsHeaders: SessionCodable? {
        guard let rspTrailers, !MCPRecordedHeaders.pairs(from: rspTrailers).isEmpty else { return nil }
        var copy = self
        copy.rspHeaders = rspTrailers
        return copy
    }
}

/// The capture engine's sentences with the RUNNING core's numbers — Help and
/// Settings ▸ Capture read these. `CaptureEngineFacts`' defaults are what the
/// MCP helper (which cannot link the core) quotes; reading the core's own
/// `ConnectionIdlePolicy` here means the app's copy follows the engine even if
/// the two ever drift.
enum LiveCaptureEngineFacts {
    static var idleSentence: String {
        CaptureEngineFacts.idleSentence(
            between: ConnectionIdlePolicy.http.idleTimeout,
            inFlight: ConnectionIdlePolicy.http.inFlightTimeout,
            relay: ConnectionIdlePolicy.relayed.idleTimeout
        )
    }

    /// Where `CaptureEngineFacts`' defaults (what the MCP helper, SKILL.md and
    /// the tool descriptions quote) disagree with the running core. Nothing
    /// in `swift test` can see the core, so this is the only check that a
    /// change to D6 in the core reached the helper's copy; the retention limit
    /// has no public constant in the core and is NOT checked — changing it
    /// needs a manual edit of `CaptureEngineFacts.retainedBytesPerExchange`.
    static var helperDefaultsDrift: [String] {
        var drift: [String] = []
        func compare(_ name: String, _ helper: TimeInterval, _ core: TimeInterval) {
            if helper != core { drift.append("\(name): helper says \(helper) s, core says \(core) s") }
        }
        compare("idle between exchanges", CaptureEngineFacts.idleBetweenExchanges, ConnectionIdlePolicy.http.idleTimeout)
        compare("idle while in flight", CaptureEngineFacts.idleWhileInFlight, ConnectionIdlePolicy.http.inFlightTimeout)
        compare("idle on a relay", CaptureEngineFacts.idleRelay, ConnectionIdlePolicy.relayed.idleTimeout)
        return drift
    }

    /// DEBUG builds only: stop at launch when the helper's numbers drifted
    /// from the embedded core's, so a core rebuild that changed them cannot
    /// ship an agent-facing sentence quoting the old ones.
    static func assertHelperDefaultsMatchCore() {
        #if DEBUG
        let drift = helperDefaultsDrift
        if !drift.isEmpty {
            assertionFailure("CaptureEngineFacts drifted from the embedded core — update RecordedExchange.swift and SKILL.md: " + drift.joined(separator: "; "))
        }
        #endif
    }

    /// Every sentence about what capture does to traffic, in reading order.
    static var sentences: [String] {
        [
            CaptureEngineFacts.addsNoHeaders,
            idleSentence,
            CaptureEngineFacts.retentionSentence(),
            CaptureEngineFacts.http2RetentionSentence(),
            CaptureEngineFacts.withoutCertificate,
        ]
    }
}
