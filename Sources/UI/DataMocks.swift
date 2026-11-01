//
//  DataMocks.swift
//  ReqRes
//
//  Created by OloApps on 6/10/24.
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
import XReqResCore

let SESSION_MOCK = SessionCodable(
        startTime: NSNumber(value: mockNow),
        host: "reqresapp.com",
        localAddress: "127.0.0.1",
        method: "GET",
        uri: "/test",
        reqHTTPVersion: "1.0",
        userAgentProduct: "target",
        reqHeaders: """
    {
    "Origin": "https://mail.superhuman.com",
    "sec-ch-ua-mobile": "?0",
    "Host": "content.googleapis.com",
    "Accept-Encoding": "gzip, deflate, br",
    "sec-ch-ua-platform": "",
    "Sec-Fetch-Site": "cross-site",
    "Connection": "keep-alive",
    "Sec-Fetch-Mode": "cors",
    "Authorization": "Bearer 123",
    "Accept-Language": "en-GB",
    "Accept": "*/*",
    "Sec-Fetch-Dest": "empty"
    }
    """,
        reqContentEncoding: "gzip",
        reqContentType: "application/json; charset=utf-8",
        reqBody: """
        {
            "reqRes": true,
            "test": 1
        }
        """,
        rspHTTPVersion: "Http/1.1",
    rspStatus: "200",
        rspReasonPhrase: "ok",
        rspContentType: "application/json; charset=utf-8",
    rspHeaders: """
    {
    "Cache-Control": "max-age=0, private, must-revalidate",
    "Content-Encoding": "gzip"
    }
    """,
    rspBody: """
    {
        "rsp": true,
        "test": 1,
        "string": "my string",
        "array": ["one", "two", "three"]
    }
    """,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 0.01),
    reqBodyStartTime: NSNumber(value: mockNow + 0.02),
    rspStartTime: NSNumber(value: mockNow + 0.276),      // +31ms for request
    rspEndTime: NSNumber(value: mockNow + 0.309),        // +33ms for response
    connectStartTime: NSNumber(value: mockNow + 0.008),       // +8ms for queuing
    connectEndTime: NSNumber(value: mockNow + 0.009),     // +1ms for DNS
    tlsEndTime: NSNumber(value: mockNow + 0.147),  // +118ms for TCP
    reqEndTime: NSNumber(value: mockNow + 0.245),        // +98ms for TLS handshake
    requestBytes: NSNumber(value: 973),             // 973 bytes sent
    responseBytes: NSNumber(value: 1264),              // 1.2KB received
    downloadStartTime: NSNumber(value: mockNow + 0.285), // +9ms after rspStartTime for server processing
    downloadEndTime: NSNumber(value: mockNow + 0.309),  // Same as rspEndTime (download completes)
    // Safari's traffic arrives from the shared WebKit networking service, not
    // from Safari (UX spec errata 1): the mocks' one system-service row, shown
    // as "WebKit" with the `network` symbol, never Safari's icon.
    processName: "com.apple.WebKit.Networking",
    processID: 40213,
    processPath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
    // Where it went (destination-map UX spec §10): a BARE IP, as the core
    // records it — a Fastly edge; DB-IP's 2026-09 table places it in Canada, so the Destinations window reads it as CA.
    remoteAddress: "151.101.1.69"
)

// MARK: - What the 1.1.0 core records (protocol-engine doc §C2, §C3)
//
// Three rows the older mocks cannot show, in the shapes that core writes:
// headers as an ORDERED PAIR ARRAY (a repeated header twice), per-exchange
// connection facts, a body kept only in part, and a relayed connection.
// Seeded by `addMockSessions` in Debug builds and rendered by the
// `REQRES_UI_PROBE=session-reused|session-truncated|session-relay|traffic-rows`
// probes.

/// The THIRD request on a keep-alive connection: `connectionReused`, index 2,
/// its setup timings anchored at its own start (core C2.7), and a login
/// response that sets two cookies — one with a comma in `Expires`.
let SESSION_MOCK_REUSED = SessionCodable(
    startTime: NSNumber(value: mockNow + 1.0),
    host: "api.example.com",
    localAddress: "127.0.0.1:52341",
    method: "POST",
    uri: "/v1/session",
    reqHTTPVersion: "HTTP/1.1",
    userAgentProduct: "curl",
    reqHeaders: #"[{"Host":"api.example.com"},{"Accept":"application/json"},{"Content-Type":"application/json"},{"Cookie":"theme=dark"},{"Cookie":"lang=en"},{"Content-Length":"33"}]"#,
    reqContentEncoding: "",
    reqContentType: "application/json",
    reqBody: #"{"user":"ada","remember":true}"#,
    rspHTTPVersion: "HTTP/1.1",
    rspStatus: "200",
    rspReasonPhrase: "OK",
    rspContentType: "application/json",
    rspHeaders: #"[{"Content-Type":"application/json"},{"Set-Cookie":"sid=31d4d96e407aad42; Path=/; Secure; HttpOnly"},{"Set-Cookie":"csrf=9f2c; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT"},{"Content-Length":"15"}]"#,
    rspBody: #"{"ok":true}"#,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 1.0002),
    reqBodyStartTime: NSNumber(value: mockNow + 1.0003),
    rspStartTime: NSNumber(value: mockNow + 1.084),
    rspEndTime: NSNumber(value: mockNow + 1.091),
    connectStartTime: NSNumber(value: mockNow + 1.0),
    connectEndTime: NSNumber(value: mockNow + 1.0),
    tlsEndTime: NSNumber(value: mockNow + 1.0),
    reqEndTime: NSNumber(value: mockNow + 1.002),
    requestBytes: NSNumber(value: 33),
    responseBytes: NSNumber(value: 15),
    downloadStartTime: NSNumber(value: mockNow + 1.086),
    downloadEndTime: NSNumber(value: mockNow + 1.091),
    processName: "curl",
    processID: 51_022,
    processPath: "/usr/bin/curl",
    remoteAddress: "93.184.215.14",
    connectionReused: true,
    exchangeIndex: 2
)

/// A 40 MB download of which the extension kept the first 16 MB (decision
/// D10): the body on screen is a prefix, and the row says 24 MB is missing.
let SESSION_MOCK_TRUNCATED = SessionCodable(
    startTime: NSNumber(value: mockNow + 2.0),
    host: "downloads.example.com",
    localAddress: "127.0.0.1:52388",
    method: "GET",
    uri: "/exports/events.ndjson",
    reqHTTPVersion: "HTTP/1.1",
    userAgentProduct: "curl",
    reqHeaders: #"[{"Host":"downloads.example.com"},{"Accept":"*/*"}]"#,
    reqContentEncoding: "",
    reqContentType: "",
    reqBody: "",
    rspHTTPVersion: "HTTP/1.1",
    rspStatus: "200",
    rspReasonPhrase: "OK",
    rspContentType: "application/x-ndjson",
    rspHeaders: #"[{"Content-Type":"application/x-ndjson"},{"Content-Length":"41943040"}]"#,
    rspBody: (0..<40).map { #"{"event":"page_view","id":\#($0),"path":"/pricing"}"# }.joined(separator: "\n"),
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 2.2),
    reqBodyStartTime: NSNumber(value: mockNow + 2.2),
    rspStartTime: NSNumber(value: mockNow + 2.35),
    rspEndTime: NSNumber(value: mockNow + 14.8),
    connectStartTime: NSNumber(value: mockNow + 2.01),
    connectEndTime: NSNumber(value: mockNow + 2.03),
    tlsEndTime: NSNumber(value: mockNow + 2.12),
    reqEndTime: NSNumber(value: mockNow + 2.21),
    requestBytes: NSNumber(value: 0),
    responseBytes: NSNumber(value: 41_943_040),
    downloadStartTime: NSNumber(value: mockNow + 2.4),
    downloadEndTime: NSNumber(value: mockNow + 14.8),
    processName: "curl",
    processID: 51_190,
    processPath: "/usr/bin/curl",
    remoteAddress: "151.101.1.69",
    exchangeIndex: 0,
    rspBodyTruncatedBytes: 25_165_824
)

/// A Claude Code answer streamed over SSE (Anthropic Messages): text, a
/// tool call whose arguments arrive in pieces, usage and the stop reason —
/// the Events tab's mock (protocol-engine doc §S5). Written from the public
/// API reference's wire shape.
let SESSION_MOCK_SSE_BODY = [
    #"event: message_start\#ndata: {"type":"message_start","message":{"id":"msg_01Q9vXj8kB3yHn2LwT5pRz7c","type":"message","role":"assistant","model":"claude-sonnet-4-5-20250929","content":[],"stop_reason":null,"usage":{"input_tokens":1824,"cache_read_input_tokens":12288,"output_tokens":3}}}"#,
    #"event: content_block_start\#ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    #"event: ping\#ndata: {"type":"ping"}"#,
    #"event: content_block_delta\#ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The failing test reads the fixture"}}"#,
    #"event: content_block_delta\#ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" before it is written. Let me look at the setup."}}"#,
    #"event: content_block_stop\#ndata: {"type":"content_block_stop","index":0}"#,
    #"event: content_block_start\#ndata: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01VbX3kq9Tz2nD8sYw4LmP6e","name":"Read","input":{}}}"#,
    #"event: content_block_delta\#ndata: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\": \"/Users/ann/app/Tests/"}}"#,
    #"event: content_block_delta\#ndata: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"FixtureTests.swift\"}"}}"#,
    #"event: content_block_stop\#ndata: {"type":"content_block_stop","index":1}"#,
    #"event: message_delta\#ndata: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":61}}"#,
    #"event: message_stop\#ndata: {"type":"message_stop"}"#,
].joined(separator: "\n\n") + "\n\n"

let SESSION_MOCK_SSE = SessionCodable(
    startTime: NSNumber(value: mockNow + 4.0),
    host: "api.anthropic.com",
    localAddress: "127.0.0.1:52460",
    method: "POST",
    uri: "/v1/messages?beta=true",
    reqHTTPVersion: "HTTP/1.1",
    userAgentProduct: "claude-cli",
    reqHeaders: #"[{"Host":"api.anthropic.com"},{"Content-Type":"application/json"},{"Accept":"text/event-stream"},{"x-api-key":"sk-ant-api03-mock"},{"anthropic-version":"2023-06-01"}]"#,
    reqContentEncoding: "",
    reqContentType: "application/json",
    reqBody: #"{"model":"claude-sonnet-4-5-20250929","max_tokens":32000,"stream":true,"messages":[{"role":"user","content":"Why does FixtureTests fail?"}]}"#,
    rspHTTPVersion: "HTTP/1.1",
    rspStatus: "200",
    rspReasonPhrase: "OK",
    rspContentType: "text/event-stream; charset=utf-8",
    rspHeaders: #"[{"Content-Type":"text/event-stream; charset=utf-8"},{"Cache-Control":"no-cache"},{"request-id":"req_011CTmock"}]"#,
    rspBody: SESSION_MOCK_SSE_BODY,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 4.02),
    reqBodyStartTime: NSNumber(value: mockNow + 4.02),
    rspStartTime: NSNumber(value: mockNow + 4.61),
    rspEndTime: NSNumber(value: mockNow + 7.93),
    connectStartTime: NSNumber(value: mockNow + 4.0),
    connectEndTime: NSNumber(value: mockNow + 4.0),
    tlsEndTime: NSNumber(value: mockNow + 4.0),
    reqEndTime: NSNumber(value: mockNow + 4.03),
    requestBytes: NSNumber(value: 142),
    responseBytes: NSNumber(value: SESSION_MOCK_SSE_BODY.utf8.count),
    downloadStartTime: NSNumber(value: mockNow + 4.61),
    downloadEndTime: NSNumber(value: mockNow + 7.93),
    processName: "claude",
    processID: 61_204,
    processPath: "/Users/ann/.local/bin/claude",
    remoteAddress: "160.79.104.10",
    connectionReused: true,
    exchangeIndex: 3
)

/// A connection relayed with no ReqRes CA installed (decision D7): one row
/// at close — `CONNECT`, no path, no status, the endpoint and bytes each way.
/// The host carries no port because it was 443, as the core records it.
let SESSION_MOCK_RELAY = SessionCodable(
    startTime: NSNumber(value: mockNow + 3.0),
    host: "api.github.com",
    localAddress: "127.0.0.1:52410",
    method: "CONNECT",
    uri: "",
    reqHTTPVersion: "",
    userAgentProduct: "",
    reqHeaders: "[]",
    reqContentEncoding: "",
    reqContentType: "",
    reqBody: "",
    rspHTTPVersion: nil,
    rspStatus: nil,
    rspReasonPhrase: nil,
    rspHeaders: nil,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 3.041),
    reqBodyStartTime: NSNumber(value: mockNow + 3.041),
    rspStartTime: NSNumber(value: mockNow + 3.041),
    rspEndTime: NSNumber(value: mockNow + 18.6),
    connectStartTime: NSNumber(value: mockNow + 3.002),
    connectEndTime: NSNumber(value: mockNow + 3.041),
    tlsEndTime: NSNumber(value: mockNow + 3.041),
    reqEndTime: NSNumber(value: mockNow + 3.041),
    requestBytes: NSNumber(value: 2_318),
    responseBytes: NSNumber(value: 48_911),
    downloadStartTime: NSNumber(value: mockNow + 3.041),
    downloadEndTime: NSNumber(value: mockNow + 18.6),
    processName: "git-remote-https",
    processID: 51_307,
    processPath: "/Library/Developer/CommandLineTools/usr/libexec/git-core/git-remote-https",
    remoteAddress: "140.82.121.6",
    relayed: true
)

/// A connection to a host macOS itself pins (live-run F5, core `PinnedHosts`):
/// iCloud's gateway, opened by the background-transfer daemon — relayed
/// untouched with the CA trusted, recorded with the macOS policy.
let SESSION_MOCK_PINNED: SessionCodable = {
    var session = SESSION_MOCK_RELAY
    session.id = UUID()
    session.host = "gateway.icloud.com"
    session.localAddress = "127.0.0.1:52433"
    session.requestBytes = NSNumber(value: 1_904)
    session.responseBytes = NSNumber(value: 6_212)
    session.processName = "nsurlsessiond"
    session.processID = 664
    session.processPath = "/usr/libexec/nsurlsessiond"
    session.remoteAddress = "17.248.211.72"
    session.pinnedBy = "MMCS"
    return session
}()

/// A connection from an app that refused ReqRes's certificate earlier (core
/// `LearnedPins`): WhatsApp's media server, relayed and marked with the
/// domain it pinned.
let SESSION_MOCK_APP_PINNED: SessionCodable = {
    var session = SESSION_MOCK_RELAY
    session.id = UUID()
    session.host = "media-dub4-1.cdn.whatsapp.net"
    session.localAddress = "127.0.0.1:52460"
    session.requestBytes = NSNumber(value: 3_118)
    session.responseBytes = NSNumber(value: 1_874_332)
    session.processName = "WhatsApp"
    session.processID = 671
    session.processPath = "/Applications/WhatsApp.app/Contents/MacOS/WhatsApp"
    session.remoteAddress = "157.240.221.60"
    session.pinnedBy = "app:whatsapp.net"
    return session
}()

// MARK: - Requests that did not complete (protocol-engine doc §C6, §S3)
//
// The shapes core 26618ca writes for a failure: an `outcome`, the phase it
// broke in, one sentence naming the cause, and whether the APP cancelled it.
// Seeded by `addMockSessions` in Debug builds (the cancelled one stays hidden
// until Settings ▸ Capture ▸ Show cancelled requests is on) and rendered by
// `REQRES_UI_PROBE=traffic-failures|session-failed-tls|session-failed-tls-cli|
// session-failed-dns|session-aborted|session-failed-tls-confirm`.

/// An app refusing ReqRes's certificate — the pinning case. `CONNECT`, no
/// URI, the CONNECT host, the process from the CONNECT head, no server
/// address (the upstream is dialled lazily and never was).
let SESSION_MOCK_FAILED_TLS_CLIENT = SessionCodable(
    startTime: NSNumber(value: mockNow + 4.0),
    host: "api.northwind-bank.example",
    localAddress: "127.0.0.1:52455",
    method: "CONNECT",
    uri: "",
    reqHTTPVersion: "",
    userAgentProduct: "",
    reqHeaders: "[]",
    reqContentEncoding: "",
    reqContentType: "",
    reqBody: "",
    rspHTTPVersion: nil,
    rspStatus: nil,
    rspReasonPhrase: nil,
    rspHeaders: nil,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 4.0),
    reqBodyStartTime: NSNumber(value: mockNow + 4.0),
    rspStartTime: NSNumber(value: mockNow + 4.03),
    rspEndTime: NSNumber(value: mockNow + 4.03),
    processName: "Northwind",
    processID: 51_502,
    processPath: "/Applications/Northwind.app/Contents/MacOS/Northwind",
    outcome: .failed,
    failurePhase: .tlsClient,
    failureDetail: "The app refused ReqRes's certificate for api.northwind-bank.example (TLS alert: bad certificate). Apps that pin their certificates do this; exclude the host to let its traffic through unrecorded."
)

/// The same refusal from a command-line tool: node reads its trusted
/// certificates from a file, so the row offers the CA export first.
let SESSION_MOCK_FAILED_TLS_CLIENT_CLI = SessionCodable(
    startTime: NSNumber(value: mockNow + 4.5),
    host: "registry.npmjs.org",
    localAddress: "127.0.0.1:52461",
    method: "CONNECT",
    uri: "",
    reqHTTPVersion: "",
    userAgentProduct: "",
    reqHeaders: "[]",
    reqContentEncoding: "",
    reqContentType: "",
    reqBody: "",
    rspHTTPVersion: nil,
    rspStatus: nil,
    rspReasonPhrase: nil,
    rspHeaders: nil,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 4.5),
    reqBodyStartTime: NSNumber(value: mockNow + 4.5),
    rspStartTime: NSNumber(value: mockNow + 4.52),
    rspEndTime: NSNumber(value: mockNow + 4.52),
    processName: "node",
    processID: 51_560,
    processPath: "/opt/homebrew/bin/node",
    outcome: .failed,
    failurePhase: .tlsClient,
    failureDetail: "The app refused ReqRes's certificate for registry.npmjs.org (TLS alert: unknown ca). Apps that pin their certificates do this; exclude the host to let its traffic through unrecorded."
)

/// A name that did not resolve: ReqRes answered the app 502 with the
/// sentence as the body; no server address.
let SESSION_MOCK_FAILED_DNS = SessionCodable(
    startTime: NSNumber(value: mockNow + 5.0),
    host: "api.exmaple.com",
    localAddress: "127.0.0.1:52470",
    method: "GET",
    uri: "/v1/users",
    reqHTTPVersion: "HTTP/1.1",
    userAgentProduct: "curl",
    reqHeaders: #"[{"Host":"api.exmaple.com"},{"Accept":"*/*"}]"#,
    reqContentEncoding: "",
    reqContentType: "",
    reqBody: "",
    rspHTTPVersion: "HTTP/1.1",
    rspStatus: "502",
    rspReasonPhrase: "Bad Gateway",
    rspContentType: "text/plain",
    rspHeaders: #"[{"Content-Type":"text/plain"},{"Connection":"close"}]"#,
    rspBody: "Could not resolve api.exmaple.com — the name does not exist or DNS did not answer.",
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 5.0),
    reqBodyStartTime: NSNumber(value: mockNow + 5.0),
    rspStartTime: NSNumber(value: mockNow + 5.21),
    rspEndTime: NSNumber(value: mockNow + 5.21),
    processName: "curl",
    processID: 51_611,
    processPath: "/usr/bin/curl",
    outcome: .failed,
    failurePhase: .dns,
    failureDetail: "Could not resolve api.exmaple.com — the name does not exist or DNS did not answer."
)

/// A download the SERVER cut half way: aborted, not by the app.
let SESSION_MOCK_ABORTED = SessionCodable(
    startTime: NSNumber(value: mockNow + 6.0),
    host: "downloads.example.com",
    localAddress: "127.0.0.1:52488",
    method: "GET",
    uri: "/builds/app-1.4.2.zip",
    reqHTTPVersion: "HTTP/1.1",
    userAgentProduct: "curl",
    reqHeaders: #"[{"Host":"downloads.example.com"},{"Accept":"*/*"}]"#,
    reqContentEncoding: "",
    reqContentType: "",
    reqBody: "",
    rspHTTPVersion: "HTTP/1.1",
    rspStatus: "200",
    rspReasonPhrase: "OK",
    rspContentType: "application/zip",
    rspHeaders: #"[{"Content-Type":"application/zip"},{"Content-Length":"104857600"}]"#,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 6.1),
    reqBodyStartTime: NSNumber(value: mockNow + 6.1),
    rspStartTime: NSNumber(value: mockNow + 6.3),
    rspEndTime: NSNumber(value: mockNow + 48.2),
    connectStartTime: NSNumber(value: mockNow + 6.01),
    connectEndTime: NSNumber(value: mockNow + 6.04),
    tlsEndTime: NSNumber(value: mockNow + 6.09),
    reqEndTime: NSNumber(value: mockNow + 6.1),
    requestBytes: NSNumber(value: 0),
    responseBytes: NSNumber(value: 38_207_488),
    downloadStartTime: NSNumber(value: mockNow + 6.3),
    downloadEndTime: NSNumber(value: mockNow + 48.2),
    processName: "curl",
    processID: 51_640,
    processPath: "/usr/bin/curl",
    remoteAddress: "151.101.1.69",
    exchangeIndex: 0,
    outcome: .aborted,
    failurePhase: .response,
    failureDetail: "The server closed the connection before the response finished."
)

/// A request the browser cancelled itself (decision D8): hidden unless
/// Settings ▸ Capture ▸ Show cancelled requests is on.
let SESSION_MOCK_CANCELLED = SessionCodable(
    startTime: NSNumber(value: mockNow + 7.0),
    host: "www.example.com",
    localAddress: "127.0.0.1:52501",
    method: "GET",
    uri: "/assets/hero.webp",
    reqHTTPVersion: "HTTP/1.1",
    userAgentProduct: "Mozilla",
    reqHeaders: #"[{"Host":"www.example.com"},{"Accept":"image/webp,*/*"}]"#,
    reqContentEncoding: "",
    reqContentType: "",
    reqBody: "",
    rspHTTPVersion: nil,
    rspStatus: nil,
    rspReasonPhrase: nil,
    rspHeaders: nil,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 7.0),
    reqBodyStartTime: NSNumber(value: mockNow + 7.0),
    rspStartTime: NSNumber(value: mockNow + 7.12),
    rspEndTime: NSNumber(value: mockNow + 7.12),
    processName: "Brave Browser Helper",
    processID: 51_702,
    processPath: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper",
    remoteAddress: "93.184.215.14",
    outcome: .aborted,
    failurePhase: .response,
    failureDetail: "The app closed the connection before the response finished.",
    clientCancelled: true
)

/// ReqRes's own idle limit closed a request whose server never answered.
let SESSION_MOCK_TIMED_OUT = SessionCodable(
    startTime: NSNumber(value: mockNow + 8.0),
    host: "api.example.com",
    localAddress: "127.0.0.1:52512",
    method: "POST",
    uri: "/v1/reports/generate",
    reqHTTPVersion: "HTTP/1.1",
    userAgentProduct: "MyShop",
    reqHeaders: #"[{"Host":"api.example.com"},{"Content-Type":"application/json"},{"Content-Length":"18"}]"#,
    reqContentEncoding: "",
    reqContentType: "application/json",
    reqBody: #"{"range":"90d"}"#,
    rspHTTPVersion: nil,
    rspStatus: nil,
    rspReasonPhrase: nil,
    rspHeaders: nil,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 8.0),
    reqBodyStartTime: NSNumber(value: mockNow + 8.0),
    rspStartTime: NSNumber(value: mockNow + 308.0),
    rspEndTime: NSNumber(value: mockNow + 308.0),
    requestBytes: NSNumber(value: 18),
    processName: "MyShop",
    processID: 51_733,
    processPath: "/Applications/MyShop.app/Contents/MacOS/MyShop",
    remoteAddress: "3.120.12.34",
    outcome: .timedOut,
    failurePhase: .response,
    failureDetail: "The server sent nothing for 300 s after the request; ReqRes closed the connection."
)

/// A relay whose connect failed — the default no-CA state (C6.2(b),
/// `RelayRecorder.connectFailed`): `CONNECT`, relayed, no status, no server
/// address, failed at `connect`. It must read as a failure, not as an
/// ordinary "not decrypted" relay.
let SESSION_MOCK_FAILED_RELAY = SessionCodable(
    startTime: NSNumber(value: mockNow + 7.5),
    host: "staging.internal.example:8443",
    localAddress: "127.0.0.1:52512",
    method: "CONNECT",
    uri: "",
    reqHTTPVersion: "",
    userAgentProduct: "",
    reqHeaders: "[]",
    reqContentEncoding: "",
    reqContentType: "",
    reqBody: "",
    rspHTTPVersion: nil,
    rspStatus: nil,
    rspReasonPhrase: nil,
    rspHeaders: nil,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 7.5),
    reqBodyStartTime: NSNumber(value: mockNow + 7.5),
    rspStartTime: NSNumber(value: mockNow + 7.51),
    rspEndTime: NSNumber(value: mockNow + 7.51),
    requestBytes: NSNumber(value: 0),
    responseBytes: NSNumber(value: 0),
    processName: "curl",
    processID: 51_802,
    processPath: "/usr/bin/curl",
    relayed: true,
    outcome: .failed,
    failurePhase: .connect,
    failureDetail: "ReqRes could not connect to staging.internal.example:8443 (connection refused)."
)

/// Every failure mock, in the order the traffic list shows them.
let SESSION_MOCKS_FAILURES = [
    SESSION_MOCK_FAILED_TLS_CLIENT, SESSION_MOCK_FAILED_TLS_CLIENT_CLI, SESSION_MOCK_FAILED_DNS,
    SESSION_MOCK_ABORTED, SESSION_MOCK_CANCELLED, SESSION_MOCK_TIMED_OUT, SESSION_MOCK_FAILED_RELAY,
]

// MARK: - gRPC-Web (protocol-engine doc §S8)

/// A tiny protobuf encoder for the mocks only — field numbers, no schema.
private enum MockProto {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }
    static func uint(_ field: Int, _ value: UInt64) -> [UInt8] { varint(UInt64(field << 3)) + varint(value) }
    static func len(_ field: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(field << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    static func string(_ field: Int, _ text: String) -> [UInt8] { len(field, Array(text.utf8)) }
    static func frame(_ payload: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        let n = UInt32(payload.count)
        return [flags, UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + payload
    }
}

/// `acme.users.v1.UserService/ListUsers`, server-streaming over gRPC-Web:
/// two users (a nested address, a packed repeated field, raw bytes), then the
/// trailer frame with grpc-status 0.
let SESSION_MOCK_GRPC_WEB_REQUEST: [UInt8] = MockProto.frame(MockProto.uint(1, 2) + MockProto.string(2, "team:platform"))
let SESSION_MOCK_GRPC_WEB_RESPONSE: [UInt8] =
    MockProto.frame(MockProto.uint(1, 42) + MockProto.string(2, "Ann Lindqvist")
        + MockProto.len(3, MockProto.string(1, "Amsterdam") + MockProto.uint(2, 1011))
        + MockProto.len(4, [1, 2, 0xAC, 0x02]) + MockProto.len(5, [0x9F, 0x3A, 0x00, 0xE1]))
    + MockProto.frame(MockProto.uint(1, 43) + MockProto.string(2, "Björn Ek")
        + MockProto.len(3, MockProto.string(1, "Utrecht") + MockProto.uint(2, 3511)))
    + MockProto.frame(Array("grpc-status: 0\r\ngrpc-message: \r\nx-envoy-upstream-service-time: 12\r\n".utf8), flags: 0x80)

let SESSION_MOCK_GRPC_WEB = SessionCodable(
    startTime: NSNumber(value: mockNow + 5.0),
    host: "api.acme.dev",
    localAddress: "127.0.0.1:52470",
    method: "POST",
    uri: "/acme.users.v1.UserService/ListUsers",
    reqHTTPVersion: "HTTP/1.1",
    userAgentProduct: "Mozilla",
    reqHeaders: #"[{"Host":"api.acme.dev"},{"Content-Type":"application/grpc-web+proto"},{"X-Grpc-Web":"1"},{"X-User-Agent":"grpc-web-javascript/0.1"}]"#,
    reqContentEncoding: "",
    reqContentType: "application/grpc-web+proto",
    reqBody: "",
    rspHTTPVersion: "HTTP/1.1",
    rspStatus: "200",
    rspReasonPhrase: "OK",
    rspContentType: "application/grpc-web+proto",
    rspHeaders: #"[{"Content-Type":"application/grpc-web+proto"},{"Access-Control-Expose-Headers":"grpc-status,grpc-message"}]"#,
    rspBody: "",
    rspBodyData: Data(SESSION_MOCK_GRPC_WEB_RESPONSE),
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 5.01),
    reqBodyStartTime: NSNumber(value: mockNow + 5.01),
    rspStartTime: NSNumber(value: mockNow + 5.09),
    rspEndTime: NSNumber(value: mockNow + 5.12),
    requestBytes: NSNumber(value: SESSION_MOCK_GRPC_WEB_REQUEST.count),
    responseBytes: NSNumber(value: SESSION_MOCK_GRPC_WEB_RESPONSE.count),
    // Safari's requests come from the shared WebKit networking service, not
    // from Safari itself: a mock named "Safari" with no path read as a tool
    // "outside an app bundle" in Settings.
    processName: "com.apple.WebKit.Networking",
    processID: 812,
    processPath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
    remoteAddress: "104.18.12.33",
    reqBodyData: Data(SESSION_MOCK_GRPC_WEB_REQUEST),
    reqBodyIsBinary: true,
    rspBodyIsBinary: true
)

/// The same service's GetUser failing the gRPC-Web way: HTTP 200, and
/// NOT_FOUND in the trailer frame.
let SESSION_MOCK_GRPC_WEB_ERROR = SessionCodable(
    startTime: NSNumber(value: mockNow + 5.5),
    host: "api.acme.dev",
    localAddress: "127.0.0.1:52471",
    method: "POST",
    uri: "/acme.users.v1.UserService/GetUser",
    reqHTTPVersion: "HTTP/1.1",
    userAgentProduct: "Mozilla",
    reqHeaders: #"[{"Host":"api.acme.dev"},{"Content-Type":"application/grpc-web+proto"},{"X-Grpc-Web":"1"}]"#,
    reqContentEncoding: "",
    reqContentType: "application/grpc-web+proto",
    reqBody: "",
    rspHTTPVersion: "HTTP/1.1",
    rspStatus: "200",
    rspReasonPhrase: "OK",
    rspContentType: "application/grpc-web+proto",
    rspHeaders: #"[{"Content-Type":"application/grpc-web+proto"}]"#,
    rspBody: "",
    rspBodyData: Data(MockProto.frame(Array("grpc-status: 5\r\ngrpc-message: user%2044%20not%20found\r\n".utf8), flags: 0x80)),
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 5.51),
    reqBodyStartTime: NSNumber(value: mockNow + 5.51),
    rspStartTime: NSNumber(value: mockNow + 5.56),
    rspEndTime: NSNumber(value: mockNow + 5.57),
    requestBytes: NSNumber(value: 7),
    responseBytes: NSNumber(value: 50),
    // Safari's requests come from the shared WebKit networking service, not
    // from Safari itself: a mock named "Safari" with no path read as a tool
    // "outside an app bundle" in Settings.
    processName: "com.apple.WebKit.Networking",
    processID: 812,
    processPath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
    remoteAddress: "104.18.12.33",
    reqBodyData: Data(MockProto.frame(MockProto.uint(1, 44))),
    reqBodyIsBinary: true,
    rspBodyIsBinary: true
)

// MARK: - HTTP/2 and trailers (protocol-engine doc §S9, core C12/C13)
//
// Rendered by `REQRES_UI_PROBE=session-h2 | session-grpc | session-grpc-rpc |
// traffic-h2`, and seeded by `addMockSessions` in Debug builds.

/// The third stream on an HTTP/2 connection (core C12: `HTTP/2.0` both
/// ways, `connectionReused`, `exchangeIndex` in stream-open order, the
/// setup phases zero-length at the stream's own start).
let SESSION_MOCK_H2 = SessionCodable(
    startTime: NSNumber(value: mockNow + 6.0),
    host: "www.example.org",
    localAddress: "127.0.0.1:52480",
    method: "GET",
    uri: "/assets/app.js",
    reqHTTPVersion: "HTTP/2.0",
    userAgentProduct: "Mozilla",
    reqHeaders: #"[{"host":"www.example.org"},{"accept":"*/*"},{"accept-encoding":"gzip, br"},{"referer":"https://www.example.org/"}]"#,
    reqContentEncoding: "",
    reqContentType: "",
    reqBody: "",
    rspHTTPVersion: "HTTP/2.0",
    rspStatus: "200",
    rspReasonPhrase: "OK",
    rspContentType: "application/javascript",
    rspHeaders: #"[{"content-type":"application/javascript"},{"cache-control":"max-age=31536000"},{"content-length":"24"}]"#,
    rspBody: "console.log(\"loaded\");\n",
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 6.0002),
    reqBodyStartTime: NSNumber(value: mockNow + 6.0002),
    rspStartTime: NSNumber(value: mockNow + 6.041),
    rspEndTime: NSNumber(value: mockNow + 6.043),
    connectStartTime: NSNumber(value: mockNow + 6.0),
    connectEndTime: NSNumber(value: mockNow + 6.0),
    tlsEndTime: NSNumber(value: mockNow + 6.0),
    reqEndTime: NSNumber(value: mockNow + 6.0002),
    requestBytes: NSNumber(value: 0),
    responseBytes: NSNumber(value: 24),
    downloadStartTime: NSNumber(value: mockNow + 6.041),
    downloadEndTime: NSNumber(value: mockNow + 6.043),
    // Safari's requests come from the shared WebKit networking service, not
    // from Safari itself: a mock named "Safari" with no path read as a tool
    // "outside an app bundle" in Settings.
    processName: "com.apple.WebKit.Networking",
    processID: 812,
    processPath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
    remoteAddress: "93.184.215.14",
    connectionReused: true,
    exchangeIndex: 2
)

/// Native gRPC over HTTP/2 (core C13): HTTP 200, one reply message, and the
/// RPC's status in the TRAILERS — PERMISSION_DENIED — where only a C13 core
/// records it. A request trailer too (a client checksum), so both sides'
/// Headers tabs show their trailer section.
let SESSION_MOCK_GRPC_NATIVE_REQUEST: [UInt8] = MockProto.frame(MockProto.uint(1, 44))
let SESSION_MOCK_GRPC_NATIVE_RESPONSE: [UInt8] = MockProto.frame(MockProto.string(1, "partial"))

let SESSION_MOCK_GRPC_NATIVE = SessionCodable(
    startTime: NSNumber(value: mockNow + 6.5),
    host: "api.acme.dev",
    localAddress: "127.0.0.1:52481",
    method: "POST",
    uri: "/acme.users.v1.UserService/DeleteUser",
    reqHTTPVersion: "HTTP/2.0",
    userAgentProduct: "grpc-go",
    reqHeaders: #"[{"host":"api.acme.dev"},{"content-type":"application/grpc"},{"te":"trailers"},{"grpc-timeout":"5S"},{"user-agent":"grpc-go/1.66.0"}]"#,
    reqContentEncoding: "",
    reqContentType: "application/grpc",
    reqBody: "",
    rspHTTPVersion: "HTTP/2.0",
    rspStatus: "200",
    rspReasonPhrase: "OK",
    rspContentType: "application/grpc",
    rspHeaders: #"[{"content-type":"application/grpc"},{"grpc-accept-encoding":"gzip"}]"#,
    rspBody: "",
    rspBodyData: Data(SESSION_MOCK_GRPC_NATIVE_RESPONSE),
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 6.5002),
    reqBodyStartTime: NSNumber(value: mockNow + 6.5003),
    rspStartTime: NSNumber(value: mockNow + 6.538),
    rspEndTime: NSNumber(value: mockNow + 6.541),
    connectStartTime: NSNumber(value: mockNow + 6.5),
    connectEndTime: NSNumber(value: mockNow + 6.5),
    tlsEndTime: NSNumber(value: mockNow + 6.5),
    reqEndTime: NSNumber(value: mockNow + 6.5004),
    requestBytes: NSNumber(value: SESSION_MOCK_GRPC_NATIVE_REQUEST.count),
    responseBytes: NSNumber(value: SESSION_MOCK_GRPC_NATIVE_RESPONSE.count),
    downloadStartTime: NSNumber(value: mockNow + 6.539),
    downloadEndTime: NSNumber(value: mockNow + 6.541),
    processName: "grpcurl",
    processID: 61_204,
    processPath: "/opt/homebrew/bin/grpcurl",
    remoteAddress: "104.18.12.33",
    reqBodyData: Data(SESSION_MOCK_GRPC_NATIVE_REQUEST),
    reqBodyIsBinary: true,
    rspBodyIsBinary: true,
    reqTrailers: #"[{"x-request-checksum":"crc32c=9a71bb4c"}]"#,
    rspTrailers: #"[{"grpc-status":"7"},{"grpc-message":"caller%20lacks%20scope%20users.delete"},{"x-envoy-upstream-service-time":"3"}]"#
)
