//
//  MCPAgentFacingRedactionTests.swift
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

import XCTest
@testable import MCPKit

/// Every String an agent can receive, walked with `Mirror`, under a canary
/// secret put into EVERY field that carries captured material (protocol PRD
/// 4a.2; protocol-engine doc §S5).
///
/// Two assertions per agent-facing type, through the real bridge routes:
/// 1. no String anywhere in the answer contains the canary;
/// 2. every String field (by path) carried a redaction marker in at least
///    one answer — so a field that is added later and never populated here,
///    or populated but not redacted, fails this test instead of passing it
///    silently. The only fields excused are listed in `exempt`, each with the
///    reason it cannot hold captured material.
final class MCPAgentFacingRedactionTests: XCTestCase {
    /// A vendor-prefixed key: the one credential shape every redaction pass
    /// (structural, shape, identifier) is required to catch.
    static let canary = "sk_live_" + "CANARY0123456789abcdefXYZ"
    static let canaryCore = "CANARY0123456789"
    /// A second canary the stream emits in TWO deltas.
    static let splitCanaryCore = "SPLITCANARY98765abcdef"

    /// Fields that never carry captured material, and why.
    static let exempt: [String: String] = [
        "uid": "minted by ReqRes (a UUID), not by the traffic",
        "summary.uid": "minted by ReqRes",
        "facts.uid": "echo of the uid the agent asked for, validated against the capture",
        "scheme": "written by the core: http or https",
        "summary.scheme": "written by the core",
        "country": "a token from the offline resolver",
        "proto": "one of four protocol tokens (h1, h2, ws, relay), written by ReqRes (doc §S9)",
        "summary.proto": "one of four protocol tokens, written by ReqRes",
        "summary.country": "a token from the offline resolver",
        "serverAddress": "an IP literal the core resolved",
        "pinnedBy": "a macOS pinning-policy name from the core's built-in copy of trustd's list, never from the traffic",
        "summary.pinnedBy": "a macOS pinning-policy name from the core's built-in list",
        "curl": "dropped entirely when redacting (asserted nil below)",
        // WebSocket messages (protocol-engine doc §S7): tokens and ReqRes's own words.
        "direction": "sent | received, written by ReqRes",
        "opcode": "one of five opcode names, written by ReqRes",
        "dataFormat": "json | text | base64 | none, written by ReqRes",
        "withheld": "ReqRes's own sentence saying why a payload is not shown",
        "stoppedReading": "ReqRes's own sentence around the core's parser reason",
        "end": "one of four close tokens, written by ReqRes",
        "initiatedBy": "sent | received, written by ReqRes",
        "nextCursor": "a seq number",
        "note": "ReqRes's own sentence",
        // The RPC view (protocol-engine doc §S8): numbers, tokens and ReqRes's words.
        "wire": "one of four wire-type tokens, written by ReqRes",
        "statusNote": "ReqRes's own sentence saying why there is no status",
        "redaction": "ReqRes's own sentence describing the redaction applied",
        "status.name": "a status name from ReqRes's table",
        "messages.fields.value": "a number, as decimal digits",
        "messages.fields.alternatives": "numbers, as decimal digits, with a type word",
        "messages.fields.packed": "numbers, as decimal digits: offered on a redacted host only beside a nested message made only of varints (numbers already shown); a bytes reading's packed reading is its bytes and is withheld with them (MCPRPCRouteTests.testAWithheldBytesFieldDoesNotLeakThroughItsPackedReading)",
        "messages.fields.message.value": "a number, as decimal digits",
        "messages.fields.message.alternatives": "numbers, as decimal digits, with a type word",
        "messages.fields.message.packed": "numbers, as decimal digits: as messages.fields.packed — never for a bytes reading on a redacted host",
        "messages.fields.message.message.value": "a number, as decimal digits",
        "messages.bytes": "base64 only for a host excepted from redaction; nil here (withheld, asserted)",
        "messages.fields.bytes": "base64 only for a host excepted from redaction; nil here (withheld, asserted)",
        "messages.fields.message.bytes": "base64 only for a host excepted from redaction; nil here",
        // Breakpoints (F15). Full paths, never the bare field "id": an SSE
        // event's id is captured material and must stay checked.
        "requests.id": "minted by ReqRes's breakpoint registry (a UUID), not by the traffic",
        "answer.id": "the same ReqRes-minted id, echoed back",
        // Rules (the F15 class in the rule routes). Full paths: a session's
        // method stays checked.
        "rules.method": "validated: empty (any method) or GET, POST, PUT, PATCH or DELETE — a mock's is the session's, checked against that list",
        "rule.method": "validated: empty (any method) or one of five methods",
        "rules.localFilePath": "a file on this Mac: a fixture ReqRes named (a UUID) or one the user picked in the form — never captured traffic",
        "rule.localFilePath": "a file on this Mac, never captured traffic",
    ]

    private let token = "t"
    private let c = MCPAgentFacingRedactionTests.canary

    // MARK: Fixture

    private var summary: MCPSessionSummary {
        MCPSessionSummary(
            uid: "s1",
            host: "\(c).example.com",
            method: "POST-\(c)",
            url: "https://api.example.com/v1/\(c)/messages?q=\(c)",
            scheme: "https",
            statusCode: 200,
            contentType: "text/event-stream; profile=\(c)",
            app: "tool-\(c)",
            pid: 42,
            country: "US",
            kind: .exchange,
            outcome: .failed,
            failurePhase: .response,
            failureDetail: "The server at \(c) closed the connection.",
            clientCancelled: false,
            neverConnected: false,
            httpVersion: "HTTP/2.0-\(c)",
            proto: "h2"
        )
    }

    /// An Anthropic stream with the canary in every string the assembler
    /// reads, plus an unrecognised event whose name, id and data carry it,
    /// plus the split canary in two text deltas, plus a cut tail.
    private var stream: String {
        let split = MCPAgentFacingRedactionTests.splitCanaryCore
        return """
        id: \(c)
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_\(c)","model":"claude-\(c)","usage":{"input_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"key \(c) and sk_live_"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\(split) end"}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_\(c)","name":"tool_\(c)","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"q\\":\\"\(c)\\"}"}}

        event: \(c)
        data: plain \(c)

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"stop_\(c)"},"usage":{"output_tokens":3}}

        event: error
        data: {"type":"error","error":{"type":"type_\(c)","message":"message \(c)"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"sk_live_
        """
    }

    /// The Responses error shape, for the error's `code`.
    private var responsesErrorStream: String {
        """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_\(c)","model":"gpt-\(c)","status":"in_progress"}}

        event: error
        data: {"type":"error","code":"code_\(c)","message":"message \(c)"}


        """
    }

    private func router(body: String, uid: String = "s1") -> MCPBridgeRouter {
        var row = summary
        row.uid = uid
        let detail = MCPSessionDetail(
            summary: row,
            requestHeaders: ["X-\(c)": c, "Authorization": "Bearer \(c)"],
            responseHeaders: ["X-Trace-\(c)": "trace \(c)"],
            requestBodyPreview: "{\"prompt\":\"\(c)\"}",
            responseBodyPreview: body,
            curl: "curl -H 'X: \(c)' https://api.example.com",
            serverAddress: "192.0.2.1",
            connectionReused: false,
            exchangeIndex: 0,
            requestBodyNotRetainedBytes: 0,
            responseBodyNotRetainedBytes: 0,
            // Trailers (core C13, doc §S9): a new egress surface, walked like headers.
            requestTrailers: ["X-Sum-\(c)": c, "Authorization": "Bearer \(c)"],
            responseTrailers: ["grpc-message": "denied \(c)", "X-\(c)": "trace \(c)"]
        )
        let provider = StubSessionProvider(summaries: [row], details: [uid: detail], bodies: ["\(uid):response": body])
        return MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider())
    }

    private func get<T: Decodable>(_ type: T.Type, _ router: MCPBridgeRouter, _ target: String) throws -> T {
        let response = try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: target, token: token))))
        XCTAssertEqual(response.status, 200, target)
        return try JSONDecoder().decode(T.self, from: response.body)
    }

    // MARK: The walk

    /// Every String leaf and every nil `String?` field, by dotted path
    /// (array positions dropped, dictionary entries as `.key` / `.value`).
    static func strings(in value: Any, path: String = "") -> [(path: String, value: String?)] {
        if let string = value as? String, type(of: value) == String.self {
            return [(path, string)]
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first { return strings(in: child.value, path: path) }
            return type(of: value) == Optional<String>.self ? [(path, nil)] : []
        }
        return mirror.children.flatMap { child -> [(path: String, value: String?)] in
            let label = child.label.map { path.isEmpty ? $0 : "\(path).\($0)" } ?? path
            return strings(in: child.value, path: label)
        }
    }

    private func assertRedacted(_ answers: [Any], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        var byPath: [String: [String?]] = [:]
        for answer in answers {
            for leaf in Self.strings(in: answer) { byPath[leaf.path, default: []].append(leaf.value) }
        }
        XCTAssertFalse(byPath.isEmpty, "\(name): nothing walked", file: file, line: line)
        for (path, values) in byPath.sorted(by: { $0.key < $1.key }) {
            for value in values.compactMap({ $0 }) {
                XCTAssertFalse(value.contains(Self.canaryCore), "\(name).\(path) leaks the canary: \(value)", file: file, line: line)
                XCTAssertFalse(value.contains(Self.splitCanaryCore), "\(name).\(path) leaks the split canary", file: file, line: line)
            }
            let field = path.split(separator: ".").last.map(String.init) ?? path
            if Self.exempt[path] != nil || Self.exempt[field] != nil { continue }
            let marked = values.compactMap { $0 }.contains { $0.contains(MCPRedactor.placeholder) || $0.contains(MCPRedactor.urlPlaceholder) }
            XCTAssertTrue(marked, "\(name).\(path) never carried the canary through redaction — populate it in the fixture, redact it, or exempt it with a reason",
                          file: file, line: line)
        }
    }

    // MARK: Tests

    func testTheSessionListRow() throws {
        let page = try get(MCPSessionPage.self, router(body: stream), "/v1/sessions")
        XCTAssertEqual(page.sessions.count, 1)
        assertRedacted(page.sessions, "summary")
    }

    func testTheSessionDetailIncludingFailureFieldsAndTheStreamBody() throws {
        let detail = try get(MCPSessionDetail.self, router(body: stream), "/v1/sessions/s1")
        XCTAssertNil(detail.curl, "cURL is dropped when redacting")
        XCTAssertNotNil(detail.summary.failureFacts, "the failure fields are part of this answer")
        assertRedacted([detail], "detail")
        let text = MCPTextFormat.detail(detail)
        XCTAssertFalse(text.contains(Self.canaryCore))
        XCTAssertFalse(text.contains(Self.splitCanaryCore))
    }

    func testTheStreamEvents() throws {
        let page = try get(MCPStreamEventsPage.self, router(body: stream), "/v1/sessions/s1/events?limit=200")
        XCTAssertGreaterThan(page.facts.pendingBytes, 0, "the cut tail is withheld")
        XCTAssertGreaterThan(page.withheldDeltaEvents, 0)
        assertRedacted([page], "events")
        let text = MCPTextFormat.streamEvents(page)
        XCTAssertFalse(text.contains(Self.canaryCore))
        XCTAssertFalse(text.contains(Self.splitCanaryCore))
    }

    func testTheAssembledOutput() throws {
        let anthropic = try get(MCPStreamAssembled.self, router(body: stream), "/v1/sessions/s1/assembled")
        let responses = try get(MCPStreamAssembled.self, router(body: responsesErrorStream), "/v1/sessions/s1/assembled")
        XCTAssertNotNil(anthropic.error)
        XCTAssertNotNil(responses.error?.code)
        assertRedacted([anthropic, responses], "assembled")
        for answer in [anthropic, responses] {
            let text = MCPTextFormat.streamAssembled(answer)
            XCTAssertFalse(text.contains(Self.canaryCore))
            XCTAssertFalse(text.contains(Self.splitCanaryCore))
        }
    }

    /// A short secret under a sensitive KEY NAME has no shape to find, so the
    /// vendor-prefixed canary above never tests it. OpenAI Responses carries
    /// tool arguments as a JSON-encoded STRING, in two deltas that split the
    /// key name and then three times whole — every copy must be caught by
    /// name, on every surface an agent reads.
    func testAKeyNamedSecretInToolArgumentsLeavesThroughNoSurface() throws {
        let secret = "kn7Qhunter"
        let body = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"login","arguments":""}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"{\\"pass"}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"word\\":\\"\(secret)\\"}"}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":0,"arguments":"{\\"password\\":\\"\(secret)\\"}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"login","arguments":"{\\"password\\":\\"\(secret)\\"}","status":"completed"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","model":"gpt-4.1","status":"completed","output":[{"type":"function_call","name":"login","arguments":"{\\"password\\":\\"\(secret)\\"}"}]}}


        """
        XCTAssertEqual(body.components(separatedBy: secret).count - 1, 4, "the fixture carries the secret in every copy")
        let router = router(body: body)
        let page = try get(MCPStreamEventsPage.self, router, "/v1/sessions/s1/events?limit=200")
        let assembled = try get(MCPStreamAssembled.self, router, "/v1/sessions/s1/assembled")
        let detail = try get(MCPSessionDetail.self, router, "/v1/sessions/s1")
        XCTAssertEqual(assembled.facts.provider, .openAIResponses)
        XCTAssertEqual(assembled.blocks.first?.content, "{\"password\":\"«redacted»\"}")
        for leaf in Self.strings(in: [page, assembled, detail] as [Any]) {
            XCTAssertFalse(leaf.value?.contains(secret) ?? false, "\(leaf.path) leaks the key-named secret: \(leaf.value ?? "")")
        }
        for text in [MCPTextFormat.streamEvents(page), MCPTextFormat.streamAssembled(assembled), MCPTextFormat.detail(detail)] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    /// WebSocket messages (protocol-engine doc §S7): the canary in every
    /// string a connection and its messages carry — the host, the URL, the
    /// extensions header, a JSON message, a text one, a ping, a close reason,
    /// the close summary — plus a preview CUT inside a second secret and a
    /// binary frame carrying the canary. Through the real routes.
    func testWebSocketMessagesAndTheirConnection() throws {
        let split = MCPAgentFacingRedactionTests.splitCanaryCore
        let provider = StubSocketProvider()
        let id = provider.addSocket(uid: "ws1", host: "\(c).example.com", url: "https://api.example.com/rt/\(c)?token=\(c)&room=\(c)")
        let up = SocketFixtures.upgradeAt
        provider.store.ingest(SocketFixtures.batch(id, 1, [
            SocketFixtures.text(0, #"{"type":"auth","key":"\#(c)","note":"see \#(c)"}"#, sent: true),
            SocketFixtures.text(1, "plain words then \(c) end"),
            SocketFixtures.text(2, "the value is \(c) and the next is sk_live_\(split)", truncated: true),
            SocketFixtures.binary(3, Array(c.utf8) + [0x00, 0xff]),
            SocketMessage(seq: 4, direction: .serverToClient, opcode: .ping, time: up + 1, size: 10, preview: "ping \(c)", previewEncoding: .text),
            SocketFixtures.close(5, code: 4001, reason: "revoked \(c)"),
        ], gaveUp: [SocketTapIssue(direction: .serverToClient, reason: "inflate")], extensions: "permessage-deflate; x-\(c)"))
        provider.store.ingest(SocketFixtures.batch(id, 2, [], final: true,
                                                   close: SocketClose(end: .closeFrame, code: 4001, reason: "revoked \(c)", initiatedBy: .clientToServer, totalMessages: 6)))
        let router = MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider())
        let page = try get(MCPSocketMessagePage.self, router, "/v1/sessions/ws1/messages")
        let feed = try get(MCPSocketFeed.self, router, "/v1/messages?since=0")
        XCTAssertEqual(page.messages.count, 6)
        XCTAssertEqual(feed.messages.count, 6)
        XCTAssertNotNil(page.connection.close?.reason)
        XCTAssertNotNil(page.messages[3].withheld, "binary is withheld")
        assertRedacted([page], "messages")
        assertRedacted([feed], "feed")
        for text in [MCPTextFormat.socketMessages(page), MCPTextFormat.messageWait(MCPMessageWaiter.Outcome(message: feed.messages[2], timedOut: false, polls: 2), timeout: 5, filter: MCPMessageFilter())] {
            XCTAssertFalse(text.contains(Self.canaryCore), text)
            XCTAssertFalse(text.contains(Self.splitCanaryCore), text)
        }
        // And the HAR written from the same conversation.
        let conversation = try XCTUnwrap(provider.socketConversation(uid: "ws1"))
        let har = MCPHARExport.encode(sessions: [MCPSessionDetail(summary: provider.rows[0].summary)], redactor: MCPRedactor(),
                                      creatorVersion: "1", webSocketMessages: ["ws1": conversation])
        let written = String(decoding: har.data, as: UTF8.self)
        XCTAssertFalse(written.contains(Self.canaryCore), written)
        XCTAssertFalse(written.contains(Self.splitCanaryCore))
    }

    /// `get_session view=rpc` (protocol-engine doc §S8): the canary in the
    /// path (service and method), a protobuf string (top level and nested),
    /// a JSON-codec message, the status message, a trailer name and value,
    /// a message encoding (which lands in a note), and a bytes field.
    /// Protobuf strings are redacted by SHAPE — the canary is vendor-prefixed,
    /// which is the shape every pass must catch.
    func testTheRPCView() throws {
        let provider = StubRPCProvider()
        let trailer = "grpc-status: 3\r\ngrpc-message: bad%20\(c)\r\nx-\(c): \(c)\r\n"
        let proto = RPCExchangeInput(
            path: "/pkg.\(c)/Get\(c)", httpStatus: 200,
            requestHeaders: [RPCHeaderPair(name: "content-type", value: "application/grpc-web+proto"),
                             RPCHeaderPair(name: "grpc-encoding", value: "enc-\(c)")],
            responseHeaders: [RPCHeaderPair(name: "content-type", value: "application/grpc-web+proto")],
            requestBody: Data(RPCFixtures.frame(Array("opaque".utf8), flags: 1)),
            responseBody: Data(RPCFixtures.frame(PB.string(1, "key \(c)") + PB.len(2, PB.string(1, c) + PB.uint(2, 1))
                                                 + PB.len(3, Array(c.utf8) + [0x00, 0xFF]))
                               + RPCFixtures.trailer(trailer))
        )
        provider.rpc["p"] = MCPSessionRPCFacts(host: "\(c).example.com", input: proto)
        let json = RPCExchangeInput(
            path: "/pkg.\(c)/Get\(c)", httpStatus: 200,
            requestHeaders: [RPCHeaderPair(name: "content-type", value: "application/connect+json")],
            responseBody: Data(RPCFixtures.frame(Array(#"{"note":"see \#(c)","password":"hunter2"}"#.utf8))
                               + RPCFixtures.frame(Array(#"{"error":{"code":"internal","message":"at \#(c)"}}"#.utf8), flags: 0x02))
        )
        provider.rpc["j"] = MCPSessionRPCFacts(host: "\(c).example.com", input: json)
        let router = MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider())
        let protoView = try get(MCPRPCView.self, router, "/v1/sessions/p/rpc")
        let jsonView = try get(MCPRPCView.self, router, "/v1/sessions/j/rpc")
        XCTAssertEqual(protoView.status?.code, 3)
        XCTAssertEqual(protoView.messages.count, 2)
        XCTAssertNotNil(protoView.messages[0].withheld, "the undecoded request is withheld")
        XCTAssertNotNil(protoView.messages[1].fields?[2].withheld, "the bytes field is withheld")
        XCTAssertFalse(jsonView.messages[0].json?.contains("hunter2") ?? true, "JSON messages are redacted by key name")
        assertRedacted([protoView, jsonView], "rpc")
        for text in [MCPTextFormat.rpcView(protoView), MCPTextFormat.rpcView(jsonView)] {
            XCTAssertFalse(text.contains(Self.canaryCore), text)
        }
    }

    /// Breakpoints (F15): a held request and the answer to it. The canary in
    /// every string a held request carries — host, method, URL (a path
    /// segment and the query), the request-target, a header name and values,
    /// the body — read through list_paused_requests, then answered three ways
    /// through answer_paused_request. The reply once went out raw (measured
    /// live on build 51), and `path` always had: neither route was walked.
    func testAHeldRequestAndTheAnswerToIt() throws {
        struct Reply { var answer: MCPBreakpointOutcome }
        let target = "/v1/\(c)/orders?q=\(c)&access_token=\(c)"
        let breakpoints = StubBreakpoints()
        breakpoints.held = [MCPPausedRequest(
            id: "held-1",
            host: "\(c).example.com",
            method: "POST-\(c)",
            url: "https://api.example.com\(target)",
            path: target,
            headers: [
                MCPHeaderPair(name: "X-\(c)", value: "trace \(c)"),
                MCPHeaderPair(name: "Authorization", value: "Bearer \(c)"),
                MCPHeaderPair(name: "Content-Type", value: "application/json"),
            ],
            bodyPreview: "{\"note\":\"see \(c)\"}",
            bodyByteCount: 60,
            secondsRemaining: 40
        )]
        let router = MCPBridgeRouter(
            token: token, sessions: StubSessionProvider(), status: StubStatusProvider(),
            writes: MCPWriteSeams(rules: StubRuleProvider(), hosts: StubHostProvider(), capture: StubCaptureController(),
                                  consent: StubConsent(), audit: StubAudit(), breakpoints: breakpoints)
        )

        let page = try get(MCPPausedRequestPage.self, router, "/v1/breakpoints/paused")
        XCTAssertEqual(page.requests.count, 1)
        assertRedacted([page], "paused")
        XCTAssertFalse(MCPTextFormat.pausedRequests(page).contains(Self.canaryCore))

        var replies: [Any] = []
        for decision: [String: Any] in [
            ["id": "held-1", "action": "resume"],
            ["id": "held-1", "action": "resume", "setHeaders": ["X-Debug": "1"]],
            ["id": "held-1", "action": "abort"],
        ] {
            var request = makeRequest(method: "POST", target: "/v1/breakpoints/decide", token: token)
            request.body = try JSONSerialization.data(withJSONObject: decision)
            request.headers["content-type"] = "application/json"
            let response = try XCTUnwrap(parseRawResponse(router.respond(to: request)))
            XCTAssertEqual(response.status, 200, "\(decision)")
            let outcome = try JSONDecoder().decode(MCPBreakpointOutcome.self, from: response.body)
            replies.append(Reply(answer: outcome))
            XCTAssertFalse(MCPTextFormat.decision(outcome).contains(Self.canaryCore))
        }
        assertRedacted(replies, "decide")
    }

    /// Rules (the F15 class in the rule routes). A rule
    /// carries captured material — mock_from_session copies a response's
    /// headers and body and derives its PATH from the captured URL, query and
    /// all — and a person may type a credential into any of it. The canary in
    /// every string a rule carries, read through list_rules and returned by
    /// create_rule, mock_from_session and update_rule.
    func testRulesAsAgentsReadThem() throws {
        struct Reply { var rule: MCPRule }
        struct Envelope: Decodable { let rules: [MCPRule] }
        let path = "/v1/\(c)/orders?q=\(c)&access_token=\(c)"
        let body = "{\"note\":\"see \(c)\"}"
        let rules = StubRuleProvider()
        rules.stored = [MCPRule(
            id: 90, hostId: 7, host: "\(c).example.com", enabled: true, mode: .extend, matchType: .wildcard,
            path: path, method: "", scheme: "https",
            requestHeaders: ["X-\(c)": c, "Authorization": "Bearer \(c)"],
            responseHeaders: ["X-Trace-\(c)": "trace \(c)"], responseBody: body
        )]
        rules.mockDerivedPath = path
        rules.mockResponseHeaders = ["X-\(c)": "trace \(c)", "Set-Cookie": "sid=\(c)"]
        rules.mockResponseBody = body
        let hosts = StubHostProvider()
        hosts.stored = [MCPHost(id: 7, host: "api.example.com", scheme: "https", port: 443)]
        let router = MCPBridgeRouter(
            token: token, sessions: StubSessionProvider(), status: StubStatusProvider(),
            writes: MCPWriteSeams(rules: rules, hosts: hosts, capture: StubCaptureController(),
                                  consent: StubConsent(), audit: StubAudit())
        )
        func write(_ method: String, _ target: String, _ object: [String: Any]) throws -> Reply {
            var request = makeRequest(method: method, target: target, token: token)
            request.body = try JSONSerialization.data(withJSONObject: object)
            request.headers["content-type"] = "application/json"
            let response = try XCTUnwrap(parseRawResponse(router.respond(to: request)))
            XCTAssertLessThan(response.status, 300, "\(method) \(target): \(String(decoding: response.body, as: UTF8.self))")
            return Reply(rule: try JSONDecoder().decode(MCPRule.self, from: response.body))
        }

        let listed = try get(Envelope.self, router, "/v1/rules")
        let replies = [
            try write("POST", "/v1/rules", [
                "hostId": 7, "mode": "override", "path": path,
                "requestHeaders": ["X-\(c)": c, "Authorization": "Bearer \(c)"],
                "responseHeaders": ["X-Trace-\(c)": "trace \(c)"], "responseBody": body,
            ]),
            try write("POST", "/v1/rules/from-session", ["uid": "s1"]),
            try write("PATCH", "/v1/rules/90", ["enabled": false]),
        ]
        assertRedacted([listed] + replies, "rules")
        for rule in listed.rules + replies.map(\.rule) {
            XCTAssertFalse(MCPTextFormat.rule(rule).contains(Self.canaryCore))
        }
        XCTAssertTrue(rules.stored.allSatisfy { $0.path == path }, "every rule is STORED with its real path")
    }

    /// The instrument itself: it must see a nil `String?` field, a dictionary
    /// key, and a String nested in an array — or the checks above prove less
    /// than they claim.
    func testTheWalkSeesNilOptionalsDictionaryKeysAndArrays() {
        struct Probe {
            var a: String?
            var b: [String: String]
            var c: [Inner]
            struct Inner { var d: String }
        }
        let leaves = Self.strings(in: Probe(a: nil, b: ["k": "v"], c: [.init(d: "x")]))
        let paths = Set(leaves.map(\.path))
        XCTAssertEqual(paths, ["a", "b.key", "b.value", "c.d"])
        XCTAssertTrue(leaves.contains { $0.path == "a" && $0.value == nil })
    }
}
