//
//  SessionProtocol.swift
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
//  What a row spoke (protocol-engine doc §S9, decision D11): HTTP/1.1,
//  HTTP/2 (since core C12, when the user turned it on and both sides speak
//  it), a WebSocket after its upgrade, or a relayed connection ReqRes did not
//  decrypt. ONE classification for every surface — the Metrics tab's Protocol
//  row, the `proto:` search token (its vocabulary is spelled a second time
//  in Utils and pinned equal by a test), `list_sessions proto=` and the
//  `proto` field an agent reads — so a row can never be HTTP/2 in one place
//  and HTTP/1.1 in another.
//
//  The version comes from the row as recorded (`reqHTTPVersion`, NIO's
//  `"HTTP/2.0"` / `"HTTP/1.1"` spelling), never from a constant: the HAR
//  export said "HTTP/1.1" for every entry because the engine used to be
//  HTTP/1.1 on both legs, and C12 made that false.
//
//  Also here: the HTTP/2 capture setting's words (Settings ▸ Capture, Help,
//  diagnose_setup) and the trailer section titles, for the same one-source
//  reason.
//

import Foundation

/// The one protocol token a row carries. Each row has exactly one: a
/// WebSocket's handshake was HTTP/1.1, but the row is `ws`, not `h1`.
public enum SessionProtocol: String, Codable, CaseIterable, Equatable, Sendable {
    /// HTTP/1.0 or HTTP/1.1.
    case http1 = "h1"
    /// HTTP/2 (both legs — C12 never bridges).
    case http2 = "h2"
    /// A `101 Switching Protocols` naming websocket: the row is the upgrade,
    /// and the connection carried WebSocket messages after it.
    case webSocket = "ws"
    /// A connection relayed byte for byte without being decrypted (no CA, an
    /// excluded host): TCP, nothing inside it was read.
    case relay

    /// The token the filter, the search chip and the agent use.
    public var token: String { rawValue }

    /// What a row spoke. `httpVersion` is the row's recorded request version
    /// (the response's when the request's is empty); nil when the row is none
    /// of the four — no request head was ever read (a TLS failure before it),
    /// or an unrecognised version string. Nil is never guessed as HTTP/1.1.
    public static func classify(httpVersion: String?, isRelay: Bool, isWebSocket: Bool) -> SessionProtocol? {
        if isRelay { return .relay }
        if isWebSocket { return .webSocket }
        switch HTTPVersionName.major(httpVersion) {
        case 1: return .http1
        case 2: return .http2
        default: return nil
        }
    }

    /// A filter or chip value: the token itself, or a spelling people type —
    /// `http1`, `http/1.1`, `1.1`, `http2`, `http/2`, `2`, `websocket`,
    /// `tcp`. Case and surrounding whitespace ignored. Nil for anything else
    /// (the search field keeps it as free text; the bridge answers 400).
    public static func parse(_ raw: String) -> SessionProtocol? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "h1", "http1", "http/1", "http/1.1", "http/1.0", "1", "1.1", "1.0", "http1.1": return .http1
        case "h2", "http2", "http/2", "http/2.0", "2", "2.0": return .http2
        case "ws", "wss", "websocket", "websockets": return .webSocket
        case "relay", "tcp", "relayed": return .relay
        default: return nil
        }
    }

    /// The 400 an unusable `proto` earns — refused, never dropped.
    public static func parameterError(_ value: String) -> MCPQueryParameterError {
        MCPQueryParameterError(
            parameter: "proto",
            message: "'proto' must be h1, h2, ws or relay — got '\(value)'."
        )
    }
}

/// `"HTTP/2.0"` → `"HTTP/2"`, `"HTTP/1.1"` → `"HTTP/1.1"`.
public enum HTTPVersionName {
    /// The major version of a recorded version string, or nil when it is not
    /// one: NIO writes `HTTP/<major>.<minor>`; `h2` and a bare `HTTP/2` are
    /// accepted too.
    public static func major(_ recorded: String?) -> Int? {
        guard let recorded else { return nil }
        let text = recorded.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "h2" { return 2 }
        guard text.hasPrefix("http/") else { return nil }
        let number = text.dropFirst("http/".count)
        guard let first = number.first, let major = first.wholeNumberValue else { return nil }
        let rest = number.dropFirst()
        guard rest.isEmpty || (rest.first == "." && rest.dropFirst().allSatisfy(\.isNumber) && rest.count > 1) else { return nil }
        return major
    }

    /// How a version reads to a person: `HTTP/2` (the protocol has no minor
    /// version, and nobody writes `HTTP/2.0`), `HTTP/1.1`, `HTTP/1.0`. Nil
    /// for a string that is not a version.
    public static func display(_ recorded: String?) -> String? {
        guard let major = major(recorded), let recorded else { return nil }
        if major == 2 { return "HTTP/2" }
        if major == 1 {
            return recorded.trimmingCharacters(in: .whitespaces).uppercased() == "HTTP/1.0" ? "HTTP/1.0" : "HTTP/1.1"
        }
        return nil
    }
}

/// The words for a row's protocol — the Metrics tab's Protocol row, the
/// relay detail's, and the chip.
public enum SessionProtocolPresentation {
    /// `HTTP/2`, `HTTP/1.1`, `WebSocket`, `relay/tcp`; "Not recorded" when the
    /// row has none (no request head was read).
    public static func label(httpVersion: String?, isRelay: Bool, isWebSocket: Bool) -> String {
        switch SessionProtocol.classify(httpVersion: httpVersion, isRelay: isRelay, isWebSocket: isWebSocket) {
        case .relay: return "relay/tcp"
        case .webSocket: return "WebSocket"
        case .http2: return "HTTP/2"
        case .http1: return HTTPVersionName.display(httpVersion) ?? "HTTP/1.1"
        case nil: return notRecorded
        }
    }

    public static let notRecorded = "Not recorded"

    /// The line under the label: what the protocol means for this row. Nil
    /// for plain HTTP/1.1, which needs no explaining.
    public static func caption(httpVersion: String?, isRelay: Bool, isWebSocket: Bool) -> String? {
        switch SessionProtocol.classify(httpVersion: httpVersion, isRelay: isRelay, isWebSocket: isWebSocket) {
        case .relay:
            return "Relayed byte for byte without being decrypted, so nothing inside the connection was read."
        case .webSocket:
            let handshake = HTTPVersionName.display(httpVersion) ?? "HTTP/1.1"
            return "Upgraded from \(handshake) with 101 Switching Protocols; the messages that followed are in the Messages tab."
        case .http2:
            return "One stream on a connection it may share with other requests; ReqRes spoke HTTP/2 to the app and to the server."
        case .http1:
            return nil
        case nil:
            return "No request was read on this connection, so no protocol was recorded."
        }
    }

    /// What a `proto:` chip shows: "HTTP/2", "HTTP/1.x", "WebSocket", "Relay".
    public static func chipName(_ proto: SessionProtocol) -> String {
        switch proto {
        case .http1: return "HTTP/1.x"
        case .http2: return "HTTP/2"
        case .webSocket: return "WebSocket"
        case .relay: return "Relay"
        }
    }
}

/// The HTTP/2 capture setting's words (decision D11): an opt-in beta, OFF by
/// default. Settings ▸ Capture, Help and diagnose_setup all print these.
public enum HTTP2CaptureCopy {
    public static let toggleTitle = "Capture HTTP/2 (beta)"

    /// The caption under the toggle: what it does, the one exception, and
    /// when to turn it off.
    public static let caption =
        "When an app and the server both speak HTTP/2, ReqRes speaks it to both and records one row per request. "
            + "WebSockets stay on HTTP/1.1. Turn this off if a site misbehaves."

    /// When a change takes effect — the switch is read once per connection.
    public static let appliesTo =
        "The change applies to connections opened after it; connections already open keep the protocol they started with. Capture does not need restarting."

    /// Hosts with a Map Local or Override-with-a-body rule stay on HTTP/1.1
    /// (C12.2(c): a mocked host is never dialled before its request — D3).
    public static let mockedHostsNote =
        "A host with an enabled Map Local rule, or an Override rule with a body, stays on HTTP/1.1 so ReqRes can answer it without contacting the server."

    /// diagnose_setup's informational line.
    public static func diagnosisDetail(enabled: Bool) -> String {
        enabled
            ? "HTTP/2 capture is ON (beta): apps and servers that both speak HTTP/2 are captured as HTTP/2, one row per request (proto=h2); WebSockets stay on HTTP/1.1. If a site misbehaves, the user can turn it off in Settings ▸ Capture."
            : "HTTP/2 capture is off (the default): every intercepted request is HTTP/1.1 between the app and ReqRes and between ReqRes and the server, whatever both would otherwise speak. The user can turn it on in Settings ▸ Capture."
    }
}

/// Trailers: header fields sent AFTER a body (an HTTP/2 trailing HEADERS
/// frame, an HTTP/1.1 chunked trailer section) — where native gRPC puts its
/// status. The core records them since C13 (`reqTrailers` / `rspTrailers`,
/// the headers' ordered-pairs JSON, nil when the message had none).
public enum SessionTrailersCopy {
    public static let requestTitle = "Request Trailers"
    public static let responseTitle = "Response Trailers"
    /// Under the title in the Headers tab.
    public static let caption = "Sent after the body."
}
