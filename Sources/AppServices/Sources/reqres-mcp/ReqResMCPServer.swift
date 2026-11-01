//
//  ReqResMCPServer.swift
//  reqres-mcp
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

import Foundation
import MCP
import MCPKit

/// The agent surface: RR-MCP-1 reads and RR-MCP-2 writes. Every tool is a
/// thin translation of a bridge call into agent-readable text; filtering,
/// capping, redaction, validation and the human's consent all happen
/// app-side, so this binary never holds captured traffic of its own and
/// cannot change anything the app has not approved.
enum ReqResMCPServer {
    static let appGroupIdentifier = "ZUP9ZNBCHM.com.oloapps.ReqRes"
    static let appBundleIdentifier = "com.oloapps.ReqRes"
    static let serverName = "reqres"
    static let serverVersion = "0.2.0"

    static func main() -> Never {
        monitorStdin()

        Task {
            do {
                try await run()
            } catch {
                FileHandle.standardError.write(Data("reqres-mcp: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        RunLoop.main.run()
        exit(0)
    }

    /// Exits when the client goes away, two ways because macOS `poll` never
    /// reported POLLHUP for our pipe (measured 2026-09-17: the client closed
    /// stdin and the process lived on):
    ///  * a kqueue EVFILT_READ watch on stdin reports EV_EOF when the writer
    ///    closes — without consuming bytes the stdio transport needs;
    ///  * the parent pid: a client that quits leaves us reparented to launchd.
    private static func monitorStdin() {
        let parent = getppid()
        DispatchQueue.global().async {
            let queue = kqueue()
            var change = kevent(ident: UInt(STDIN_FILENO), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
            if queue >= 0 {
                kevent(queue, &change, 1, nil, 0, nil)
            }
            while true {
                var timeout = timespec(tv_sec: 2, tv_nsec: 0)
                var event = kevent()
                let count = queue >= 0 ? kevent(queue, nil, 0, &event, 1, &timeout) : 0
                if count > 0, event.flags & UInt16(EV_EOF) != 0 {
                    exit(0)
                }
                if getppid() != parent {
                    exit(0)
                }
                if count > 0 {
                    // Data is waiting for the transport; do not spin on it.
                    usleep(100_000)
                }
            }
        }
    }

    private static func run() async throws {
        let server = Server(
            name: serverName,
            version: serverVersion,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await handle(name: params.name, arguments: params.arguments ?? [:])
        }

        try await server.start(transport: StdioTransport())
    }

    // MARK: - Tool surface

    static var tools: [Tool] {
        [
            Tool(
                name: "capture_status",
                description: "Readiness snapshot of ReqRes: whether capture is running, whether what it records is reaching ReqRes (Delivery — reconnecting for a few seconds after ReqRes was relaunched while capturing, while the extension reconnects and delivers what it captured meanwhile; capture can also be on while nothing arrives, until it is started again from ReqRes), the Network Extension setup state, CA certificate status, how many sessions are currently captured, and what each protocol does — every protocol by name and status (supported, beta, relayed or not_captured), with what this Mac's certificate and HTTP/2 setting make of it. A request of a relayed or not_captured kind (HTTP/3, raw TCP, an excluded host) is missing or unread by design, not a broken capture; diagnose_setup explains each. Call this first when traffic seems missing.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "list_sessions",
                description: "List captured HTTP(S) sessions, newest first. Filter by host, method, status (e.g. '404' or '5xx'), scheme, URL substring, originating app, pid, destination country, outcome, gRPC status, or protocol (h1, h2, ws, relay). Returns compact rows; use get_session for full detail. Every request row carries proto=h1, h2 or ws (a relay row is kind=relay and matches proto=relay): HTTP/2 appears only when the user turned on HTTP/2 capture in Settings ▸ Capture (a beta, off by default) and both the app and the server speak it; a WebSocket row is ws (its handshake was HTTP/1.1). A gRPC-Web, Connect or native gRPC call carries grpc=<STATUS> (a gRPC-Web error arrives as HTTP 200, so grpc=NOT_FOUND beside 200 is the failure); get_session view=rpc decodes its messages. A connection captured while the ReqRes CA was not installed and trusted — or one that carried neither HTTP nor TLS (SSH, a database; its row says not HTTP) — is ONE row marked kind=relay, never decrypted or decoded, so it has an endpoint, bytes each way and a duration but no method, status, headers or body. A request that did not complete is still a row, marked outcome=failed, aborted or timed_out with the phase it broke in (dns, connect, tlsUpstream — the server's certificate —, tlsClient — the app refused ReqRes's certificate —, request, response) and cancelled_by_app when the app itself gave up; get_session says why in one sentence. A request still open is listed as it goes, marked IN_FLIGHT waiting (no response yet, with seconds so far) or IN_FLIGHT streaming (bytes so far, and complete events for a stream); its row is replaced by the finished one under the SAME uid. ENDED_WITHOUT_FINAL_ROW marks one whose end was never recorded (capture stopped while it was open). A WebSocket connection is its 101 Switching Protocols row; list_messages reads its messages and wait_for_message waits for the next one. Credential-shaped values are redacted.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "host": .object(["type": .string("string"), "description": .string("Case-insensitive substring of the host")]),
                        "method": .object(["type": .string("string"), "description": .string("HTTP method, e.g. GET or POST")]),
                        "status": .object(["type": .string("string"), "description": .string("Status code '404' or class '5xx'")]),
                        "scheme": .object(["type": .string("string"), "description": .string("http or https")]),
                        "url_contains": .object(["type": .string("string"), "description": .string("Case-insensitive substring of the full URL")]),
                        "app": .object(["type": .string("string"), "description": .string(appParameterDescription)]),
                        "pid": .object(["type": .string("integer"), "description": .string(pidParameterDescription)]),
                        "country": .object(["type": .string("string"), "description": .string(countryParameterDescription)]),
                        "outcome": .object(["type": .string("string"), "description": .string(outcomeParameterDescription)]),
                        "grpc": .object(["type": .string("string"), "description": .string(grpcParameterDescription)]),
                        "proto": .object(["type": .string("string"), "description": .string(protoParameterDescription)]),
                        "limit": .object(["type": .string("integer"), "description": .string("Rows per page (default 30, max 100)")]),
                        "cursor": .object(["type": .string("string"), "description": .string("Cursor from a previous page")]),
                    ]),
                ])
            ),
            Tool(
                name: "query_session_body",
                description: "Query a captured body WITHOUT pulling it into context. mode=structure describes the shape (keys, types, array lengths); mode=path extracts one value, e.g. path='data.items[0].id'. Prefer this over get_session for large JSON bodies. When the capture kept only part of the body (it keeps \(RecordedExchangeCopy.binaryBytes(CaptureEngineFacts.retainedBytesPerExchange)) per exchange), the answer says so — a key or path reported missing may simply not have been kept.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "uid": .object(["type": .string("string"), "description": .string("Session uid from list_sessions")]),
                        "side": .object(["type": .string("string"), "description": .string("request or response (default: response)")]),
                        "mode": .object(["type": .string("string"), "description": .string("structure (default) or path")]),
                        "path": .object(["type": .string("string"), "description": .string("Dotted path with optional [index], required when mode=path")]),
                    ]),
                    "required": .array([.string("uid")]),
                ])
            ),
            Tool(
                name: "wait_for_session",
                description: "Block until the NEXT matching request is captured, then return it. Use this to watch traffic while a human reproduces a bug: call it, ask them to perform the action, and it returns the request they triggered. until says how far the request must get: complete (default) — it finished; headers — its response status and headers arrived, so you learn about a slow or streaming request while it is still open; first_message — its first complete event or line arrived (an SSE or NDJSON stream such as an LLM answer; a response that is not a stream counts only when it finishes). A request returned before it finished is marked IN_FLIGHT: call get_session with view=events for the complete events so far, or wait again with until=complete. Sessions already captured before the call are ignored, and so are requests that failed, were aborted or timed out unless include_failed is true (or outcome names one) — browsers cancel requests constantly, and the first cancelled one is rarely the request you meant.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "host": .object(["type": .string("string"), "description": .string("Case-insensitive substring of the host")]),
                        "method": .object(["type": .string("string"), "description": .string("HTTP method")]),
                        "status": .object(["type": .string("string"), "description": .string("Status code '404' or class '5xx'")]),
                        "scheme": .object(["type": .string("string"), "description": .string("http or https")]),
                        "url_contains": .object(["type": .string("string"), "description": .string("Case-insensitive substring of the full URL")]),
                        "app": .object(["type": .string("string"), "description": .string(appParameterDescription)]),
                        "pid": .object(["type": .string("integer"), "description": .string(pidParameterDescription)]),
                        "country": .object(["type": .string("string"), "description": .string(countryParameterDescription)]),
                        "outcome": .object(["type": .string("string"), "description": .string(outcomeParameterDescription)]),
                        "grpc": .object(["type": .string("string"), "description": .string(grpcParameterDescription)]),
                        "proto": .object(["type": .string("string"), "description": .string(protoParameterDescription)]),
                        "until": .object([
                            "type": .string("string"),
                            "enum": .array(MCPWaitStage.allCases.map { .string($0.rawValue) }),
                            "description": .string("headers, first_message or complete (default)"),
                        ]),
                        "timeout_seconds": .object(["type": .string("integer"), "description": .string("How long to wait (default 30, max 300)")]),
                        "include_failed": .object(["type": .string("boolean"), "description": .string(includeFailedParameterDescription)]),
                    ]),
                ])
            ),
            Tool(
                name: "wait_for_sessions",
                description: "Block until SEVERAL matching requests are captured, then return them in order. Use this when one action fires more than one request, such as a login or a page load: it stops early once nothing further has matched for a few seconds, so you do not have to guess a duration. Sessions captured before the call are ignored, and failed, aborted or timed-out requests are skipped unless include_failed is true (or outcome names one). Prefer this over calling wait_for_session repeatedly.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "host": .object(["type": .string("string"), "description": .string("Case-insensitive substring of the host")]),
                        "method": .object(["type": .string("string"), "description": .string("HTTP method")]),
                        "status": .object(["type": .string("string"), "description": .string("Status code '404' or class '5xx'")]),
                        "scheme": .object(["type": .string("string"), "description": .string("http or https")]),
                        "url_contains": .object(["type": .string("string"), "description": .string("Case-insensitive substring of the full URL")]),
                        "app": .object(["type": .string("string"), "description": .string(appParameterDescription)]),
                        "pid": .object(["type": .string("integer"), "description": .string(pidParameterDescription)]),
                        "country": .object(["type": .string("string"), "description": .string(countryParameterDescription)]),
                        "outcome": .object(["type": .string("string"), "description": .string(outcomeParameterDescription)]),
                        "grpc": .object(["type": .string("string"), "description": .string(grpcParameterDescription)]),
                        "proto": .object(["type": .string("string"), "description": .string(protoParameterDescription)]),
                        "max_count": .object(["type": .string("integer"), "description": .string("Stop after this many matches (default \(MCPSessionCollector.defaultMaxCount), max \(MCPSessionCollector.maxCollectCount))")]),
                        "timeout_seconds": .object(["type": .string("integer"), "description": .string("Overall budget (default \(Int(MCPSessionCollector.defaultTimeout)), max \(Int(MCPSessionWaiter.maxTimeout)))")]),
                        "settle_seconds": .object(["type": .string("integer"), "description": .string("Stop early once no further match has arrived for this long (default \(Int(MCPSessionCollector.defaultSettleInterval)))")]),
                        "include_failed": .object(["type": .string("boolean"), "description": .string(includeFailedParameterDescription)]),
                    ]),
                ])
            ),
            Tool(
                name: "diff_sessions",
                description: "Compare two captured sessions and return only what differs: status, method, query parameters, headers, and JSON bodies compared structurally by key path. Use this instead of fetching both with get_session and comparing them yourself. Answers 'this works in curl but not in my app' in one call.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "uid_a": .object(["type": .string("string"), "description": .string("The uid of the first session, from list_sessions")]),
                        "uid_b": .object(["type": .string("string"), "description": .string("The uid of the second session")]),
                    ]),
                    "required": .array([.string("uid_a"), .string("uid_b")]),
                ])
            ),
            Tool(
                name: "get_session",
                description: "Full detail for one captured session: the HTTP version it recorded (httpVersion: HTTP/1.1, or HTTP/2.0 when HTTP/2 capture is on and both sides speak it) and its protocol token, headers (a repeated Set-Cookie is listed once per cookie; any other repeated header is one line with its values joined by ', ' — Cookie by '; ', as browsers send it), trailers when the message had any (header fields sent after the body — an HTTP/2 trailing HEADERS frame or an HTTP/1.1 chunked trailer section, where native gRPC puts grpc-status; redacted like headers), timings, whether the request reused a connection an earlier request opened (then it had no DNS/TCP/TLS of its own), and body previews (hard-capped, with an explicit truncation marker). A request that did not complete carries an Outcome line: failed, aborted or timed out, the phase, and the one-sentence cause (a 502 ReqRes answered for an unreachable server carries that sentence as its body). ReqRes keeps at most \(RecordedExchangeCopy.binaryBytes(CaptureEngineFacts.retainedBytesPerExchange)) of each exchange's bodies; a body kept only in part says how many bytes are missing, and those bytes are not in the app either. For a streamed response (text/event-stream or NDJSON), view=events returns its numbered events (name, milliseconds after the response head when recorded, data) a page at a time, and view=assembled puts an Anthropic Messages, OpenAI Chat Completions or OpenAI Responses stream back together: text, tool calls with their arguments, stop reason, usage, model and any error event. Only complete events are shown; an incomplete one at the end is withheld as 'N bytes pending'. Credential-shaped values are redacted — per event, and in assembled text after assembly (an event whose delta helps spell a redacted value is marked 'delta withheld'). A request still in flight says so (waiting for its response head, or streaming with the bytes and complete events so far) and shows NO body on either side and no cURL until it finishes (a body still arriving may be cut mid-document, which redaction cannot read safely; query_session_body refuses it with in_flight); for a stream still arriving, view=events and view=assembled read the complete events so far and withhold the unfinished tail. view=events and view=assembled read sessions of the current capture run only; a saved session's stream comes back through get_saved_session as its whole body, redacted event by event, without paging or assembly. For a gRPC-Web, Connect or native gRPC call, view=rpc returns the service and method, every request and response message decoded WITHOUT a schema (field numbers, wire types and values; a length-delimited field is printable text, else a nested message when it parses as one, else bytes; alsoParsesAsMessage flags text that also parses as a message, and the other readings are offered) a page at a time, and the RPC's status with where it came from (gRPC-Web's trailer frame, Connect's end-of-stream message or error body, native gRPC's recorded HTTP/2 trailers, or the response head for a trailers-only answer). Redaction in view=rpc is SHAPE-ONLY for protobuf strings: there are no field names without the .proto, so JWTs, vendor-prefixed keys and long high-entropy runs are masked but a short secret in a protobuf string is not recognised; bytes fields (with their packed-number reading) and undecoded messages are withheld while the host is redacted, but a bytes field that happens to parse cleanly as a message is shown as that message; JSON-codec messages are redacted by key name.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "uid": .object(["type": .string("string"), "description": .string("Session uid from list_sessions")]),
                        "view": .object([
                            "type": .string("string"),
                            "enum": .array([.string("detail"), .string("events"), .string("assembled"), .string("rpc")]),
                            "description": .string("detail (default): headers, timings, body previews. events: a streamed response's events. assembled: an LLM stream put back together. rpc: a gRPC-Web / Connect / gRPC call's messages as field-number trees and its RPC status."),
                        ]),
                        "from": .object(["type": .string("integer"), "description": .string("view=events: the 1-based event number to start at; view=rpc: the 1-based message position (requests first, then responses). Take nextFrom from the previous page. Default 1.")]),
                        "limit": .object(["type": .string("integer"), "description": .string("view=events: events per page, default \(MCPStreamEgress.defaultPageSize), at most \(MCPStreamEgress.maxPageSize). view=rpc: messages per page, default \(MCPRPCEgress.defaultPageSize), at most \(MCPRPCEgress.maxPageSize).")]),
                    ]),
                    "required": .array([.string("uid")]),
                ])
            ),
            Tool(
                name: "list_messages",
                description: "The messages of one captured WebSocket connection, oldest first: direction (sent by the app, or received from the server), opcode (text, binary, ping, pong, close), milliseconds after the upgrade, size and the payload. uid is the connection's 101 Switching Protocols row from list_sessions (status=101). ReqRes keeps the first \(SocketMessageLog.headCapacity) and the last \(SocketMessageLog.tailCapacity) messages of a connection and says how many it let go in between; the extension keeps the first 64 KB of each message. Every payload is redacted like a body — JSON by structure, anything else by name and shape; a payload cut at 64 KB loses its last word before redaction; a binary payload is not shown while its host is redacted; contains matches the redacted text. Each message is complete: the tap emits one only once its last byte has passed.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "uid": .object(["type": .string("string"), "description": .string("The WebSocket's session uid (its 101 row) from list_sessions")]),
                        "direction": .object(["type": .string("string"), "enum": .array([.string("sent"), .string("received")]), "description": .string("sent (by the app) or received (from the server)")]),
                        "opcode": .object(["type": .string("string"), "enum": .array(SocketOpcode.allCases.map { .string($0.rawValue) }), "description": .string("text, binary, ping, pong or close")]),
                        "contains": .object(["type": .string("string"), "description": .string("Case-insensitive substring of the payload as shown (after redaction)")]),
                        "cursor": .object(["type": .string("string"), "description": .string("nextCursor from the previous page: the messages after it")]),
                        "limit": .object(["type": .string("integer"), "description": .string("Messages per page (default \(MCPSocketEgress.defaultPageSize), max \(MCPSocketEgress.maxPageSize))")]),
                    ]),
                    "required": .array([.string("uid")]),
                ])
            ),
            Tool(
                name: "wait_for_message",
                description: "Block until the NEXT WebSocket message matching the filter arrives, then return it — messages captured before the call never count. Use it to watch a realtime API while a human acts: call it with contains='transcript.final' (or a uid, direction or opcode), ask them to speak or click, and it returns the message their action produced. Narrow it with the connection's uid, or with host for any connection to that host. The message comes back redacted like list_messages; list_messages with its uid and cursor=its seq reads what followed.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "uid": .object(["type": .string("string"), "description": .string("Only this WebSocket (its 101 row's uid from list_sessions)")]),
                        "host": .object(["type": .string("string"), "description": .string("Only connections whose host contains this (case-insensitive)")]),
                        "direction": .object(["type": .string("string"), "enum": .array([.string("sent"), .string("received")]), "description": .string("sent (by the app) or received (from the server)")]),
                        "opcode": .object(["type": .string("string"), "enum": .array(SocketOpcode.allCases.map { .string($0.rawValue) }), "description": .string("text, binary, ping, pong or close")]),
                        "contains": .object(["type": .string("string"), "description": .string("Case-insensitive substring of the payload as shown (after redaction)")]),
                        "timeout_seconds": .object(["type": .string("integer"), "description": .string("How long to wait (default \(Int(MCPMessageWaiter.defaultTimeout)), max \(Int(MCPMessageWaiter.maxTimeout)))")]),
                    ]),
                ])
            ),
            Tool(
                name: "list_destinations",
                description: "Where captured requests went, grouped by destination country (offline IP-to-country lookup, country-level only) plus three classes: mac (this Mac), local (private network) and unknown (not placeable). Accepts the same filters as list_sessions, so app='claude' answers 'where does this tool send data'. Per destination: requests, bytes, host and app counts, top hosts and apps. A request that failed before connecting to any server went nowhere and is left out (the report says how many). Nothing is sent anywhere to resolve addresses; the user's own location is never reported.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "host": .object(["type": .string("string"), "description": .string("Case-insensitive substring of the host")]),
                        "method": .object(["type": .string("string"), "description": .string("HTTP method")]),
                        "status": .object(["type": .string("string"), "description": .string("Status code '404' or class '5xx'")]),
                        "scheme": .object(["type": .string("string"), "description": .string("http or https")]),
                        "url_contains": .object(["type": .string("string"), "description": .string("Case-insensitive substring of the full URL")]),
                        "app": .object(["type": .string("string"), "description": .string(appParameterDescription)]),
                        "pid": .object(["type": .string("integer"), "description": .string(pidParameterDescription)]),
                        "country": .object(["type": .string("string"), "description": .string("One destination to detail: a two-letter ISO code, or local, mac or unknown. The report then carries that destination's full host and app lists (up to 20 and 10) instead of the top three.")]),
                        "outcome": .object(["type": .string("string"), "description": .string(outcomeParameterDescription)]),
                        "grpc": .object(["type": .string("string"), "description": .string(grpcParameterDescription)]),
                        "proto": .object(["type": .string("string"), "description": .string(protoParameterDescription)]),
                    ]),
                ])
            ),

            // ── Writes. The human approves each one in the ReqRes window unless
            // they allowed agent changes in Settings → MCP; a denial is an error. ──
            Tool(
                name: "list_hosts",
                description: "List ReqRes host filters (the sidebar entries) with their ids. EVERY rule is scoped to one host filter — pass its id to create_rule as host_id (add_host creates one). Traffic is captured for every host regardless of the filters.",
                inputSchema: schema([:])
            ),
            Tool(
                name: "add_host",
                description: "Add a host filter for a hostname, e.g. api.example.com. \(MCPAgentAction.Kind.addHost.consentNote) The free version allows 2 host filters.",
                inputSchema: schema([
                    "host": ("string", "Bare hostname — no scheme, port or path"),
                    "scheme": ("string", "https (default) or http"),
                    "port": ("integer", "Optional port"),
                ], required: ["host"])
            ),
            Tool(
                name: "remove_host",
                description: "Remove a host filter and the rules scoped to it. \(MCPAgentAction.Kind.removeHost.consentNote)",
                inputSchema: schema(["id": ("integer", "Host id from list_hosts")], required: ["id"])
            ),
            Tool(
                name: "list_rules",
                description: "List override/extend/map_local rules with their ids, scope, pattern and response. A rule's path is shown with credential-shaped query values masked, as every URL you read is (mock_from_session copies a captured query, token and all) — raw only for a host the user excepted from redaction; the stored rule keeps the real values and matches on them. A credential-named value that is a pattern is shown as written (access_token=* in a wildcard path; access_token=\\w+, [^&]* or [A-Za-z0-9]{32} in a regex one), and one holding literal text is masked whole, a ; or ? in it included. A path sent back to update_rule exactly as shown here keeps the stored one, and a path holding the mask any other way is refused, so omit path to keep it. An override or extend rule's status is shown as the response gets it — → 404, say, or → server's status for one that keeps the server's — and a map_local rule shows its file instead.",
                inputSchema: schema(["host_id": ("integer", "Only rules scoped to this host id")])
            ),
            Tool(
                name: "create_rule",
                description: "Create a rule. mode=override replaces the matching response with response_status/response_headers/response_body; mode=extend forwards the request and rewrites the real response: it keeps the server's status unless you give response_status (200–599), which then answers IN PLACE OF the server's — a 404 or a 500 included (0, like leaving it out, keeps the server's) — sets response_headers over the server's (one of the same name is replaced), and replaces the body only when you give response_body; mode=map_local answers with a file (local_file.content inline, or local_file.path) and status 200 — response_status is not used. A new override whose response_headers name no Content-Type is given Content-Type: application/json; charset=utf-8; extend and map_local get no response headers unless you give them: an extend rule then keeps the server's Content-Type, and a map_local answer is labelled by its file's type (for inline content, local_file.content_type). An override WITH a response_body and a map_local whose file ReqRes can read answer the app themselves and never contact the server; an override WITHOUT response_body FORWARDS the request to the server — the app's own request, with request_headers set over it — and its response comes back with the override's response_status in place of the server's; a map_local whose file ReqRes cannot read (moved, deleted, or chosen before ReqRes was last relaunched without a kept permission) answers 500 with a plain-text note naming the file, never forwards, and the rule is marked in the Overrides list. path is the pathname+query to match: wildcard ('/users?*', '*' matches anything) or regex; the rule you get back shows credential-shaped query values in it masked (raw only for a host the user excepted from redaction), while the stored rule keeps and matches the real ones — and a path holding such a mask is refused: write the real value, or a pattern in its place, access_token=* in a wildcard path or access_token=[^&]* in a regex one (? and * are quantifiers there); the 400 names the one for your rule. \(MCPAgentAction.Kind.createRule.consentNote) The free version allows 1 rule.",
                inputSchema: schema([
                    "mode": ("string", "override, extend or map_local"),
                    "path": ("string", "Pathname + query to match, e.g. /users?* (wildcard) or /users/\\d+$ (regex: start with /, never with ^ — ReqRes puts scheme://host in front)"),
                    "host_id": ("integer", "Host id from list_hosts (add_host creates one); every rule is scoped to a host filter"),
                    "match_type": ("string", "wildcard (default) or regex"),
                    "method": ("string", "Omit for any method (the default), or limit the rule to GET, POST, PUT, PATCH or DELETE"),
                    "scheme": ("string", "https (default) or http — recorded with the rule; matching ignores it, so a rule answers http:// and https:// requests to its host alike"),
                    "request_headers": ("object", "Headers to set on a request the rule forwards, name → value; each replaces the app's header of that name. Not Content-Length or Transfer-Encoding: they describe the app's body, and the request keeps the app's own whatever the rule sets"),
                    "response_status": ("integer", "A final status, 200–599. extend: leave it out, or send 0, to keep the server's status (the default); one you give answers in place of the server's, whatever that was. override: the status it answers with (200 when left out); 0 is refused — keeping the server's status is extend's. map_local: not used — its file answers 200, and a file ReqRes cannot read answers 500 with a note instead of forwarding"),
                    "response_headers": ("object", "Headers to set on the response, name → value; each replaces the server's header of that name. An override that names no Content-Type is given application/json; charset=utf-8; extend and map_local get none by default, so the server's Content-Type (extend) or the file's (map_local) stands"),
                    "response_body": ("string", "Response body for override/extend"),
                    "local_file": ("object", "map_local only: {content, content_type} for inline content, or {path} to an existing file"),
                    "enabled": ("boolean", "Default true"),
                ], required: ["host_id", "mode", "path"])
            ),
            Tool(
                name: "update_rule",
                description: "Change fields of an existing rule; only the fields given change, except that a map_local rule made extend or override takes that mode's status unless you send one (see response_status). Use enabled=false to switch a rule off without deleting it. \(MCPAgentAction.Kind.updateRule.consentNote)",
                inputSchema: schema([
                    "id": ("integer", "Rule id from list_rules"),
                    "enabled": ("boolean", ""),
                    "mode": ("string", "override, extend or map_local"),
                    "match_type": ("string", "wildcard or regex"),
                    "path": ("string", "The new pathname + query to match; omit it to keep the rule's own. A path read from list_rules has credential-shaped query values masked: sent back exactly as shown it keeps the stored path, and one holding the mask any other way is refused"),
                    "method": ("string", "\"any\" (or \"\") for any method, or GET, POST, PUT, PATCH or DELETE"),
                    "scheme": ("string", ""),
                    "request_headers": ("object", "Replaces the request headers; not Content-Length or Transfer-Encoding, which a forwarded request keeps as the app sent them"),
                    "response_status": ("integer", "A final status, 200–599, or 0 to keep the server's status — extend only (an override refuses 0; a map_local rule uses no status). Omitted, the rule keeps its status, through a change of mode too: an override made extend this way goes on answering every response it matches with its status (its 200, say), so send 0 with the mode change to keep the server's; an extend rule that keeps the server's status cannot become an override without one (400). A map_local rule has no status of its own: made an override or extend without one, it starts as a new rule in that mode does — an override answers 200, an extend rule keeps the server's"),
                    "response_headers": ("object", "Replaces the response headers; {} removes them all. Omitted, the stored ones are kept — through a change of mode too: an override's Content-Type stays on the extend rule it becomes and relabels every response it matches, or on the map_local rule it becomes and is sent in place of the file's own type, and a rule made an override answers with no Content-Type unless its stored headers name one — send response_headers with the mode change"),
                    "response_body": ("string", ""),
                    "local_file": ("object", "{content, content_type} or {path}"),
                ], required: ["id"])
            ),
            Tool(
                name: "delete_rule",
                description: "Delete a rule. \(MCPAgentAction.Kind.deleteRule.consentNote)",
                inputSchema: schema(["id": ("integer", "Rule id from list_rules")], required: ["id"])
            ),
            Tool(
                name: "mock_from_session",
                description: "The fast mock loop: turn a captured session into a rule that replays its response, optionally changing the status, body or headers — e.g. make the real /users endpoint return 500 to test error handling. The rule answers the app itself and never contacts the server, which is why a capture that cannot be replayed whole is refused rather than mocked in part: a response with no body (give response_body — an override without one would forward the request), a body the capture kept only in part, or one still under a coding ReqRes did not undo (compress, say). A capture whose status no mock can answer with (a WebSocket's 101, anything outside 200–599) is refused for an override mock unless you give response_status; a map_local mock uses none. Scoped to the session's host, adding a host filter for it when there is none (which uses one of the free tier's two). The rule's path is the session's path and query, so the rule you get back shows it with credential-shaped query values masked (raw only for a host the user excepted from redaction); the stored rule keeps and matches the real ones. A text response is replayed as UTF-8, and the copied Content-Type says so: a charset other than UTF-8 becomes charset=utf-8, and a text/*, XML or JavaScript type with no charset gains one. A Content-Type you pass in response_headers is kept as given. \(MCPAgentAction.Kind.mockFromSession.consentNote)",
                inputSchema: schema([
                    "uid": ("string", "Session uid from list_sessions"),
                    "response_status": ("integer", "Replace the captured status, 200–599 — needed when the captured one is not (a WebSocket's 101). A map_local mock ignores it and answers 200"),
                    "response_body": ("string", "Replace the captured body"),
                    "response_headers": ("object", "Merged over the captured headers"),
                    "mode": ("string", "override (default, replays inline) or map_local (writes a fixture file; needed for binary bodies — it answers 200, so neither the captured status nor response_status is replayed). extend is not accepted here."),
                    "path": ("string", "Replace the derived pattern. A path holding a redaction mask (what a session read shows in place of a credential) is refused — leave it out to use the captured path, real query and all, or put a pattern in the mask's place (access_token=* in a wildcard path, access_token=[^&]* in a regex one)"),
                    "match_type": ("string", "wildcard (default) or regex"),
                ], required: ["uid"])
            ),
            Tool(
                name: "test_pattern",
                description: "Dry-run a rule path against a URL without creating anything. Pass the path exactly as create_rule would store it (e.g. /users?*); the host comes from the URL, as it does in the proxy. The result shows the pattern ReqRes compiles. A path holding REDACTED after a credential name, or «redacted», is refused (400), as create_rule refuses to store it: a masked path would match a masked URL whatever the real tokens are.",
                inputSchema: schema([
                    "path": ("string", "Rule path, e.g. /users?* — pathname and query only"),
                    "url": ("string", "Full URL to test, e.g. https://api.example.com/users?id=1"),
                    "match_type": ("string", "wildcard (default) or regex"),
                ], required: ["path", "url"])
            ),
            Tool(
                name: "exclude_host",
                description: "Stop ReqRes intercepting and recording a host: add it to Settings ▸ Capture's exclusion list, so its connections are passed straight through with the server's own certificate. An app that refuses ReqRes's certificate (list_sessions outcome=failed shows tlsClient rows; diagnose_setup's tls_rejections check names them) does not need it to keep working: ReqRes remembers the refusal and passes that app's later connections to the domain through untouched, as rows marked SSL pinned. Exclude a host to stop recording it at all: it then disappears from the traffic list for the user AND for you. A *.example.com wildcard covers subdomains, not example.com itself. A host already excluded changes nothing and asks no one. \(MCPAgentAction.Kind.excludeHost.consentNote)",
                inputSchema: schema([
                    "host": ("string", "Bare hostname such as api.example.com, or *.example.com for its subdomains — no scheme, port or path"),
                ], required: ["host"])
            ),
            Tool(
                name: "start_capture",
                description: "Start capturing network traffic (the Network Extension must be set up — see capture_status). \(MCPAgentAction.Kind.startCapture.consentNote)",
                inputSchema: schema([:])
            ),
            Tool(
                name: "stop_capture",
                description: "Stop capturing network traffic. \(MCPAgentAction.Kind.stopCapture.consentNote)",
                inputSchema: schema([:])
            ),
            Tool(
                name: "clear_sessions",
                description: "Drop every captured session from the current run. \(MCPAgentAction.Kind.clearSessions.consentNote)",
                inputSchema: schema([:])
            ),
            Tool(
                name: "diagnose_setup",
                description: "Work out why nothing is being captured. Returns an ordered list of checks — app location, network extension, capture, proxy port, delivery to ReqRes (reconnecting after a relaunch, or capture on with nothing reaching the app, and why), CA certificate and trust, free-tier limit, traffic seen, which kinds of client are captured at all, and which protocols this version captures (supported_protocols: HTTP/3, native gRPC with HTTP/2 off, pinned apps and excluded hosts are missing by design, not broken) — with the first thing to fix and what the USER has to do about it (these are System Settings approvals and keychain trust, which you cannot do for them). Call this before telling anyone capture is broken.",
                inputSchema: schema([:])
            ),
            Tool(
                name: "capture_environment",
                description: "The shell lines that put a tool which ignores the system proxy — the Claude Code CLI, node, curl, a process inside a Docker container — through ReqRes: HTTPS_PROXY and HTTP_PROXY pointing at the proxy (an http:// address, even for HTTPS — an https:// proxy URL does not work), each exported under its lowercase name too (curl and git take the proxy for plain http:// only from http_proxy, and a lowercase variable already set in the shell outranks the uppercase one), NO_PROXY and no_proxy for localhost, 127.0.0.1 and ::1 (so a local backend called from that shell is NOT captured; unset NO_PROXY no_proxy to include it), NODE_USE_ENV_PROXY=1 (node's own fetch ignores the proxy without it), the ReqRes CA as a PEM file (the path the user exported to from Settings ▸ Capture, or a keychain export when none is known), and NODE_EXTRA_CA_CERTS, SSL_CERT_FILE and REQUESTS_CA_BUNDLE pointing at that file for node, curl/OpenSSL-based tools and Python requests respectively. The lines carry no # comments, on purpose: hand them to a person exactly as printed and add none — a default zsh does not treat a pasted # as a comment, so its words reach export, and the first one export refuses drops every line after it. Go binaries need only the proxy lines: on macOS they verify through the keychain, so the CA must be trusted there. Call this when YOUR OWN requests, or a CLI tool's, are missing from list_sessions while browser traffic shows up. Read-only; it changes nothing and asks no one. It says so first when capture is stopped — exporting the lines then makes every request from that shell fail with connection refused — and when the CA is not installed it names the step instead of printing lines (without the CA the tool's HTTPS would only be relayed, never read).",
                inputSchema: schema([:])
            ),
            Tool(
                name: "export_sessions",
                description: "Save captured sessions as a HAR 1.2 file — the format Chrome, Charles and Proxyman all open — so a human can reproduce or attach them. ReqRes chooses the folder and returns the full path; send a bare file name, not a path. Values are redacted in the file, so do not treat it as a source of credentials. Sessions still in flight are left out (the result says how many). \(MCPAgentAction.Kind.exportSessions.consentNote)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "uids": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Session uids from list_sessions, up to \(MCPLimits.maxPageSize)"),
                        ]),
                        "filename": .object([
                            "type": .string("string"),
                            "description": .string("A bare file name such as login-flow.har; .har is appended if missing"),
                        ]),
                    ]),
                    "required": .array([.string("uids"), .string("filename")]),
                ])
            ),

            Tool(
                name: "replay_request",
                description: "Send a captured request again and read the new response — the loop that lets you test a change yourself instead of proposing one and waiting for the user to click. ONLY GET, HEAD and OPTIONS can be replayed; POST, PUT, PATCH and DELETE are refused, because re-sending one can place a second order, send a second email or delete something twice on a server nobody here controls (use create_rule or mock_from_session for those and have the user trigger them). You may change the method, the path and query, and headers; the HOST cannot change — a captured request carries its own credentials and is only ever replayed against the server it was sent to. While capture is running it goes through ReqRes's proxy; the user's rules apply and it lands in the traffic list only when the ReqRes CA is installed AND trusted and the host is not excluded — otherwise it is relayed untouched (the real server answers, no rule applies). With capture stopped it goes straight out. The result always says which happened. The response comes back redacted like every other read. \(MCPAgentAction.Kind.replayRequest.consentNote)",
                inputSchema: schema([
                    "uid": ("string", "Session uid from list_sessions — the request to send again"),
                    "method": ("string", "Override the method: GET, HEAD or OPTIONS"),
                    "url": ("string", "Override the full URL. Same scheme, host and port as the captured request; change the path and query"),
                    "headers": ("object", "Headers to set on top of the captured ones, name → value"),
                    "remove_headers": ("array", "Captured header names to drop before sending"),
                ], required: ["uid"])
            ),

            // ── Saved sessions. Captured traffic is dropped when the run
            // ends; these are the ones the user chose to keep. ──
            Tool(
                name: "save_session",
                description: "Keep a captured session so it survives the capture run (captured traffic is otherwise dropped when capture stops or the buffer fills). Use it when you find the exchange that explains a bug, before it ages out. Returns a durable id — the session uid does NOT survive the run, the saved id does. \(MCPAgentAction.Kind.saveSession.consentNote)",
                inputSchema: schema([
                    "uid": ("string", "Session uid from list_sessions"),
                    "note": ("string", "Why it is worth keeping — shown beside it in ReqRes"),
                ], required: ["uid"])
            ),
            Tool(
                name: "list_saved_sessions",
                description: "List the sessions the user has kept, newest-saved first, with their ids and notes. These outlive the capture run, so this is where to look for an exchange from an earlier session. Credential-shaped values are redacted, as everywhere else.",
                inputSchema: schema(["limit": ("integer", "Rows to return (default \(MCPLimits.defaultPageSize), max \(MCPLimits.maxPageSize))")])
            ),
            Tool(
                name: "get_saved_session",
                description: "Full detail for one saved session: headers, timings and capped body previews. Takes the saved id from list_saved_sessions, not a capture uid. Credential-shaped values are redacted. A saved streamed response is shown as its body redacted event by event; it has no view=events paging or view=assembled answer (those read the current capture run only).",
                inputSchema: schema(["id": ("integer", "Saved session id from list_saved_sessions")], required: ["id"])
            ),
            // ── Breakpoints. The only tools that touch traffic that is
            // HAPPENING: a request stopped mid-flight, with a browser tab
            // spinning on it and under a minute to decide. ──
            Tool(
                name: "list_paused_requests",
                description: "Requests stopped mid-flight by the user's breakpoints, waiting for a decision. This is live traffic: each one has a countdown, and when it runs out the request is resumed untouched — so read, decide, and act, rather than exploring. An empty list says whether any breakpoint is armed at all, which is nearly always the answer to \"why didn't it stop?\". Nothing is held while no ReqRes is receiving the capture (capture_status's Delivery line says it is reconnecting, has not connected yet, or is NOT reaching ReqRes): a matching request then goes through unheld, and one held before ReqRes went away is listed again once it reconnects. You cannot arm a breakpoint; the user does that in ReqRes → Settings → Breakpoints. A held request's body is not shown, to you or to the user: ReqRes stops a request as soon as its headers arrive and does not report its body. Each request's body line says what its head declares instead — empty (no body follows), a size (Content-Length), a body sent in chunks (Transfer-Encoding) or of a size it does not declare (HTTP/2), or, when the head cannot say (an HTTP/2 GET without content-length, say), that a body can still follow — and resuming without a body sends the original unchanged, except a TRACE that arrives with a body of its own, which over HTTP/1.1 ReqRes answers 502 instead of forwarding it (its body line says so). Headers and credential-shaped values are redacted like every other read.",
                inputSchema: schema([:])
            ),
            Tool(
                name: "answer_paused_request",
                description: "Answer one held request: resume it (optionally editing its headers or replacing its body first) or abort it so the server never sees it. Headers you do not name travel exactly as the client sent them — set_headers replaces or adds by name, remove_headers drops by name. \(HeldRequestFraming.agentRule) Without body, the original body goes on unchanged. With body, the server receives what you send in place of the original, which neither you nor the user has seen (list_paused_requests gives only what the request declares) — so send one only to replace the body outright, never to patch one you have not read; an empty string sends an empty body. \(HeldRequestBody.originalDroppedNote) A TRACE takes no body: body is refused for one, and over HTTP/1.1 a TRACE that arrives with a body of its own is answered 502 by ReqRes when resumed (its body line says so) — abort that one instead. A preview marked truncated must NEVER be sent back — it would drop the rest of the upload. Act quickly: the id stops working when the countdown ends and the request goes on its way untouched. The reply names the request with its URL redacted, as list_paused_requests shows it — raw only for a host the user excepted from redaction. \(MCPAgentAction.Kind.answerPausedRequest.consentNote)",
                inputSchema: schema([
                    "id": ("string", "Held request id from list_paused_requests"),
                    "action": ("string", "resume (send it on) or abort (answer it here; the server never receives it)"),
                    "set_headers": ("object", "Headers to set before resuming, name → value. Replaces one of that name, adds one that is not there. Not Content-Length or Transfer-Encoding (refused): ReqRes sets those"),
                    "remove_headers": ("array", "Header names to drop before resuming. Not Content-Length or Transfer-Encoding (refused)"),
                    "body": ("string", "Replace the request body before resuming: none of the original, which is not shown, reaches the server. Omit it to send the original unchanged. ReqRes gives it a Content-Length to match. Refused for a TRACE, which may not carry a body"),
                    "abort_status": ("integer", "Status the client receives on an abort (\(MCPBreakpointValidation.abortStatusRange.lowerBound)–\(MCPBreakpointValidation.abortStatusRange.upperBound), default \(MCPBreakpointValidation.defaultAbortStatus))"),
                ], required: ["id", "action"])
            ),

            Tool(
                name: "delete_saved_session",
                description: "Remove one saved session. It cannot be recovered — the traffic it held was captured once and rerunning the request produces a different exchange. \(MCPAgentAction.Kind.deleteSavedSession.consentNote)",
                inputSchema: schema(["id": ("integer", "Saved session id from list_saved_sessions")], required: ["id"])
            ),
        ]
    }


    /// The two attribution filters, worded once for the three listing tools so
    /// they cannot describe the same axis three different ways.
    private static let appParameterDescription =
        "Case-insensitive substring of the originating app or process name, e.g. 'claude' matches Claude (the desktop app) and claude (the CLI). Sessions ReqRes could not attribute are excluded."
    private static let pidParameterDescription =
        "Exact process id of the originating process — separates several instances of the same tool"
    /// The outcome filter (protocol PRD 3.4), worded once for the four tools.
    private static let outcomeParameterDescription =
        "How the request ended: completed, failed (never got a response — DNS, connect, a TLS handshake, the server hanging up before answering), aborted (cut off mid-way by the app, the server or a breakpoint) or timed_out (ReqRes's idle limit closed it)"
    /// The gRPC status filter (protocol-engine doc §S8).
    private static let grpcParameterDescription =
        "The RPC's own status on gRPC-Web, Connect and native gRPC rows: error (anything but OK), ok, a status name such as NOT_FOUND or UNAVAILABLE, or a number. Native gRPC's status is read from its recorded HTTP/2 trailers, or from the response head for a trailers-only answer. Rows that are not RPCs, and rows whose status was never recorded (a stream cut before its trailers, or a row from a ReqRes before 1.1.0), match none."
    /// The protocol filter (protocol-engine doc §S9).
    private static let protoParameterDescription =
        "What the row spoke: h1 (HTTP/1.x), h2 (HTTP/2 — only when the user turned on HTTP/2 capture in Settings ▸ Capture and both sides speak it), ws (a WebSocket after its upgrade) or relay (a connection relayed without being decrypted). http2, websocket and tcp are accepted too."
    /// `include_failed`, worded once for both waits.
    private static let includeFailedParameterDescription =
        "Also resolve on a request that failed, was aborted or timed out (default false: those are skipped and the wait goes on)"

    /// The destination filter (destination-map UX spec §8.2), worded once for
    /// the same reason.
    private static let countryParameterDescription =
        "Two-letter ISO country the connection's server address resolved to (offline lookup, country level), or local (private network), mac (this Mac), unknown (not placeable). Where the connection went — a CDN answers from its nearest edge."

    /// A JSON-schema object for a tool's arguments.
    private static func schema(_ properties: [String: (String, String)], required: [String] = []) -> Value {
        var props: [String: Value] = [:]
        for (name, (type, description)) in properties {
            var entry: [String: Value] = ["type": .string(type)]
            if !description.isEmpty { entry["description"] = .string(description) }
            props[name] = .object(entry)
        }
        var object: [String: Value] = ["type": .string("object"), "properties": .object(props)]
        if !required.isEmpty { object["required"] = .array(required.map { .string($0) }) }
        return .object(object)
    }

    /// Tool arguments arrive as snake_case JSON; the bridge models are
    /// camelCase Codable — one decoder pass with key conversion bridges them.
    private static func decodeArguments<T: Decodable>(_ type: T.Type, from arguments: [String: Value], dropping: Set<String> = []) throws -> T {
        let filtered = arguments.filter { !dropping.contains($0.key) }
        let data = try JSONEncoder().encode(Value.object(filtered))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw ArgumentError(message: describe(error))
        }
    }

    struct ArgumentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "Missing required argument '\(snake(key.stringValue))'."
        case .typeMismatch(_, let context): return "Wrong type for '\(context.codingPath.map { snake($0.stringValue) }.joined(separator: "."))': \(context.debugDescription)"
        case .valueNotFound(_, let context): return "Missing value for '\(context.codingPath.map { snake($0.stringValue) }.joined(separator: "."))'."
        case .dataCorrupted(let context): return "Invalid value for '\(context.codingPath.map { snake($0.stringValue) }.joined(separator: "."))': \(context.debugDescription)"
        @unknown default: return "Arguments could not be decoded."
        }
    }

    private static func snake(_ camel: String) -> String {
        camel.reduce(into: "") { result, char in
            if char.isUppercase { result += "_" + char.lowercased() } else { result.append(char) }
        }
    }

    private static func requiredId(_ arguments: [String: Value], tool: String, list: String) throws -> Int64 {
        guard let id = arguments["id"]?.intValue else {
            throw ArgumentError(message: "\(tool) requires an integer 'id' (take one from \(list)).")
        }
        return Int64(id)
    }

    /// The optional `pid` filter. A pid arrives as an integer, or as a numeric
    /// string from a client that quotes everything; anything else is REFUSED
    /// rather than dropped, because a dropped filter hands back an unfiltered
    /// page that the agent reads as filtered — the failure the attribution
    /// filters were once removed for.
    static func optionalPid(_ arguments: [String: Value]) throws -> Int? {
        guard let value = arguments["pid"], value != .null else { return nil }
        if let pid = value.intValue { return pid }
        if let string = value.stringValue, let pid = Int(string.trimmingCharacters(in: .whitespaces)) { return pid }
        throw ArgumentError(message: "'pid' must be an integer process id, e.g. 9437.")
    }

    /// The session filter the three listing tools share, so a filter added to
    /// one cannot be forgotten on the other two.
    private static func sessionFilter(_ arguments: [String: Value]) throws -> MCPSessionFilter {
        MCPSessionFilter(
            host: arguments["host"]?.stringValue,
            method: arguments["method"]?.stringValue,
            status: arguments["status"]?.stringValue,
            scheme: arguments["scheme"]?.stringValue,
            urlContains: arguments["url_contains"]?.stringValue,
            app: arguments["app"]?.stringValue,
            pid: try optionalPid(arguments),
            // Sent as typed; the bridge normalises a code and refuses
            // anything that is neither a code nor a class word with a 400
            // that says what to send instead.
            country: arguments["country"]?.stringValue,
            outcome: try optionalOutcome(arguments),
            grpc: try optionalGRPC(arguments),
            proto: try optionalProto(arguments)
        )
    }

    /// The optional `proto` filter, refused here when unusable for the same
    /// reason as `grpc`: the waits filter client-side.
    static func optionalProto(_ arguments: [String: Value]) throws -> String? {
        guard let value = arguments["proto"], value != .null else { return nil }
        guard let raw = value.stringValue, let parsed = SessionProtocol.parse(raw) else {
            throw ArgumentError(message: "'proto' must be h1, h2, ws or relay.")
        }
        return parsed.token
    }

    /// The optional `grpc` filter, refused here when unusable — the waits
    /// filter client-side, where an unparseable value would match nothing.
    static func optionalGRPC(_ arguments: [String: Value]) throws -> String? {
        guard let value = arguments["grpc"], value != .null else { return nil }
        let raw = value.stringValue ?? value.intValue.map(String.init)
        guard let raw, let parsed = RPCStatusMatch.parse(raw) else {
            throw ArgumentError(message: "'grpc' must be error, ok, a status name such as NOT_FOUND, or a status number.")
        }
        return parsed.token
    }

    /// The message filter both message tools share. An unknown direction or
    /// opcode is refused here, before the bridge is asked: a wait with a
    /// filter that can never match would time out looking like silence.
    static func messageFilter(_ arguments: [String: Value]) throws -> MCPMessageFilter {
        var direction: SocketDirection?
        if let raw = arguments["direction"]?.stringValue, !raw.isEmpty {
            guard let parsed = SocketDirection.parse(raw) else {
                throw ArgumentError(message: "'direction' must be sent or received — got '\(raw)'.")
            }
            direction = parsed
        }
        var opcode: SocketOpcode?
        if let raw = arguments["opcode"]?.stringValue, !raw.isEmpty {
            guard let parsed = SocketOpcode.parse(raw) else {
                throw ArgumentError(message: "'opcode' must be one of \(SocketOpcode.allCases.map(\.rawValue).joined(separator: ", ")) — got '\(raw)'.")
            }
            opcode = parsed
        }
        return MCPMessageFilter(
            uid: arguments["uid"]?.stringValue,
            host: arguments["host"]?.stringValue,
            direction: direction,
            opcode: opcode,
            contains: arguments["contains"]?.stringValue
        )
    }

    /// The optional `outcome` filter, parsed HERE rather than only by the
    /// bridge: the waits apply the filter client-side, so an unparseable
    /// value would otherwise match nothing and the wait would time out
    /// looking like "nothing happened".
    static func optionalOutcome(_ arguments: [String: Value]) throws -> String? {
        guard let value = arguments["outcome"], value != .null else { return nil }
        guard let raw = value.stringValue, let outcome = MCPSessionOutcome.parse(raw) else {
            throw ArgumentError(message: "'outcome' must be one of \(MCPSessionOutcome.tokens.joined(separator: ", ")).")
        }
        return outcome.token
    }

    private static func handle(name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            let client = try makeClient()
            switch name {
            case "capture_status":
                return text(MCPTextFormat.status(try await client.status(), listingProtocols: true))

            case "list_sessions":
                let page = try await client.sessions(
                    filter: try sessionFilter(arguments),
                    limit: arguments["limit"]?.intValue,
                    cursor: arguments["cursor"]?.stringValue
                )
                return text(MCPTextFormat.page(page))

            case "get_session":
                guard let uid = arguments["uid"]?.stringValue, !uid.isEmpty else {
                    return text("get_session requires a 'uid' argument (take one from list_sessions).", isError: true)
                }
                switch arguments["view"]?.stringValue ?? "detail" {
                case "detail":
                    return text(MCPTextFormat.detail(try await client.session(uid: uid)))
                case MCPStreamView.events.rawValue:
                    let page = try await client.sessionEvents(uid: uid, from: arguments["from"]?.intValue, limit: arguments["limit"]?.intValue)
                    return text(MCPTextFormat.streamEvents(page))
                case MCPStreamView.assembled.rawValue:
                    return text(MCPTextFormat.streamAssembled(try await client.sessionAssembled(uid: uid)))
                case "rpc":
                    let view = try await client.sessionRPC(uid: uid, from: arguments["from"]?.intValue, limit: arguments["limit"]?.intValue)
                    return text(MCPTextFormat.rpcView(view))
                case let other:
                    return text("Unknown view '\(other)'. Use detail, events, assembled or rpc.", isError: true)
                }

            case "query_session_body":
                guard let uid = arguments["uid"]?.stringValue, !uid.isEmpty else {
                    return text("query_session_body requires a 'uid' argument (take one from list_sessions).", isError: true)
                }
                let side = MCPBodySide(rawValue: arguments["side"]?.stringValue ?? "response") ?? .response
                let mode = MCPJSONQuery.Mode(rawValue: arguments["mode"]?.stringValue ?? "structure") ?? .structure
                let result = try await client.body(
                    uid: uid,
                    side: side,
                    mode: mode,
                    path: arguments["path"]?.stringValue
                )
                return text(MCPTextFormat.bodyQuery(result), isError: !result.found)

            case "wait_for_session":
                let timeout = TimeInterval(arguments["timeout_seconds"]?.intValue ?? Int(MCPSessionWaiter.defaultTimeout))
                let includeFailed = arguments["include_failed"]?.boolValue ?? false
                var stage = MCPWaitStage.complete
                if let raw = arguments["until"]?.stringValue, !raw.isEmpty {
                    guard let parsed = MCPWaitStage.parse(raw) else {
                        return text("'until' must be headers, first_message or complete — got '\(raw)'.", isError: true)
                    }
                    stage = parsed
                }
                let outcome = try await client.waitForSession(filter: try sessionFilter(arguments), includeFailed: includeFailed, until: stage, timeout: timeout)
                return text(MCPTextFormat.waitOutcome(outcome, timeout: timeout, includeFailed: includeFailed, until: stage))

            case "wait_for_sessions":
                let includeFailed = arguments["include_failed"]?.boolValue ?? false
                let outcome = try await client.waitForSessions(
                    filter: try sessionFilter(arguments),
                    includeFailed: includeFailed,
                    maxCount: arguments["max_count"]?.intValue ?? MCPSessionCollector.defaultMaxCount,
                    timeout: TimeInterval(arguments["timeout_seconds"]?.intValue ?? Int(MCPSessionCollector.defaultTimeout)),
                    settleInterval: TimeInterval(arguments["settle_seconds"]?.intValue ?? Int(MCPSessionCollector.defaultSettleInterval))
                )
                return text(MCPTextFormat.collectOutcome(outcome, timeout: TimeInterval(arguments["timeout_seconds"]?.intValue ?? Int(MCPSessionCollector.defaultTimeout)), includeFailed: includeFailed))

            case "list_messages":
                guard let uid = arguments["uid"]?.stringValue, !uid.isEmpty else {
                    return text("list_messages requires a 'uid': the WebSocket's 101 row from list_sessions (status=101).", isError: true)
                }
                let page = try await client.messages(uid: uid, filter: try messageFilter(arguments), cursor: arguments["cursor"]?.stringValue,
                                                     limit: arguments["limit"]?.intValue)
                return text(MCPTextFormat.socketMessages(page))

            case "wait_for_message":
                let filter = try messageFilter(arguments)
                let timeout = TimeInterval(arguments["timeout_seconds"]?.intValue ?? Int(MCPMessageWaiter.defaultTimeout))
                let outcome = try await client.waitForMessage(filter: filter, timeout: timeout)
                return text(MCPTextFormat.messageWait(outcome, timeout: min(timeout, MCPMessageWaiter.maxTimeout), filter: filter))

            case "list_destinations":
                let filter = try sessionFilter(arguments)
                let report = try await client.destinations(filter: filter)
                return text(MCPTextFormat.destinations(report, filterDescription: filter.summaryText))

            case "diff_sessions":
                guard let uidA = arguments["uid_a"]?.stringValue,
                      let uidB = arguments["uid_b"]?.stringValue else {
                    throw MCPError.invalidParams("diff_sessions needs uid_a and uid_b. Take both from list_sessions.")
                }
                return text(MCPSessionDiffFormat.render(try await client.diffSessions(uidA, uidB)))

            // ── Writes ──
            case "list_hosts":
                return text(MCPTextFormat.hosts(try await client.hosts()))

            case "add_host":
                let draft = try decodeArguments(MCPHostDraft.self, from: arguments)
                let host = try await client.addHost(draft)
                return text("Added host filter:\n" + MCPTextFormat.hosts([host]))

            case "remove_host":
                let id = try requiredId(arguments, tool: "remove_host", list: "list_hosts")
                _ = try await client.removeHost(id: id)
                return text("Removed host filter #\(id) and its rules.")

            case "list_rules":
                let hostId = arguments["host_id"]?.intValue.map(Int64.init)
                return text(MCPTextFormat.rules(try await client.rules(hostId: hostId)))

            case "create_rule":
                let draft = try decodeArguments(MCPRuleDraft.self, from: arguments)
                let rule = try await client.createRule(draft)
                return text(Self.created(rule, client: client))

            case "update_rule":
                let id = try requiredId(arguments, tool: "update_rule", list: "list_rules")
                let patch = try decodeArguments(MCPRulePatch.self, from: arguments, dropping: ["id"])
                let rule = try await client.updateRule(id: id, patch: patch)
                return text("Updated rule:\n" + MCPTextFormat.rule(rule))

            case "delete_rule":
                let id = try requiredId(arguments, tool: "delete_rule", list: "list_rules")
                _ = try await client.deleteRule(id: id)
                return text("Deleted rule #\(id).")

            case "mock_from_session":
                let request = try decodeArguments(MCPMockFromSessionRequest.self, from: arguments)
                let rule = try await client.mockFromSession(request)
                return text(Self.created(rule, client: client, mock: true))

            case "test_pattern":
                let request = try decodeArguments(MCPPatternTestRequest.self, from: arguments)
                return text(MCPTextFormat.patternTest(try await client.testPattern(request)))

            case "exclude_host":
                let request = try decodeArguments(MCPExcludeHostRequest.self, from: arguments)
                return text(MCPTextFormat.exclusion(try await client.excludeHost(request)))

            case "start_capture":
                return text(MCPTextFormat.status(try await client.capture(.start)))

            case "stop_capture":
                return text(MCPTextFormat.status(try await client.capture(.stop)))

            case "diagnose_setup":
                return text(MCPTextFormat.diagnosis(try await client.diagnose()))

            // Read-only: rendered here from what /v1/status already says, so
            // the bridge gains no route, no consent and no audit entry for it.
            case "capture_environment":
                return text(MCPCaptureEnvironment.render(status: try await client.status()))

            case "clear_sessions":
                let cleared = try await client.clearSessions()
                return text("Cleared \(cleared.cleared) captured sessions.")

            case "export_sessions":
                guard let uids = arguments["uids"]?.arrayValue?.compactMap({ $0.stringValue }), !uids.isEmpty,
                      let filename = arguments["filename"]?.stringValue else {
                    throw MCPError.invalidParams("export_sessions needs uids (from list_sessions) and a filename.")
                }
                let export = try await client.exportSessions(MCPExportRequest(uids: uids, filename: filename))
                return text(MCPTextFormat.export(export))

            case "replay_request":
                let replay = try decodeArguments(MCPReplayRequest.self, from: arguments)
                return text(MCPTextFormat.replay(try await client.replay(replay)))

            case "list_paused_requests":
                return text(MCPTextFormat.pausedRequests(try await client.pausedRequests()))

            case "answer_paused_request":
                let decision = try decodeArguments(MCPBreakpointDecision.self, from: arguments)
                return text(MCPTextFormat.decision(try await client.decideBreakpoint(decision)))

            case "save_session":
                let request = try decodeArguments(MCPSaveSessionRequest.self, from: arguments)
                let saved = try await client.saveSession(request)
                return text("Saved as #\(saved.id) — it survives the capture run.\n" + MCPTextFormat.savedRow(saved))

            case "list_saved_sessions":
                return text(MCPTextFormat.savedSessions(try await client.savedSessions(limit: arguments["limit"]?.intValue)))

            case "get_saved_session":
                let id = try requiredId(arguments, tool: "get_saved_session", list: "list_saved_sessions")
                return text(MCPTextFormat.savedSession(try await client.savedSession(id: id)))

            case "delete_saved_session":
                let id = try requiredId(arguments, tool: "delete_saved_session", list: "list_saved_sessions")
                _ = try await client.deleteSavedSession(id: id)
                return text("Deleted saved session #\(id).")

            default:
                return text("Unknown tool: \(name)", isError: true)
            }
        } catch {
            return text(error.localizedDescription, isError: true)
        }
    }

    /// What actually happens now: a disabled rule changes nothing, and neither
    /// does any rule while capture is stopped.
    private static func created(_ rule: MCPRule, client: MCPBridgeClient, mock: Bool = false) -> String {
        var lines: [String] = []
        if !rule.enabled {
            lines.append("Created DISABLED — it will not affect any request until you call update_rule id=\(rule.id) enabled=true.")
        } else if let status = try? captureIsRunningSync(client), status == false {
            lines.append("Created, but capture is STOPPED — call start_capture for it to take effect.")
        } else {
            lines.append(mock
                ? "Mock created — matching requests now get this response instead of the real one."
                : "Created — it applies to new requests immediately.")
        }
        lines.append(MCPTextFormat.rule(rule))
        lines.append("")
        lines.append("Remove it with delete_rule id=\(rule.id), or switch it off with update_rule id=\(rule.id) enabled=false.")
        return lines.joined(separator: "\n")
    }

    /// Best-effort: never let a status read turn a successful write into an error.
    private static func captureIsRunningSync(_ client: MCPBridgeClient) throws -> Bool? {
        let semaphore = DispatchSemaphore(value: 0)
        var active: Bool?
        Task {
            active = try? await client.status().captureActive
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return active
    }

    private static func makeClient() throws -> MCPBridgeClient {
        let candidates = MCPBridgeClient.defaultHandshakeURLs(
            appGroupIdentifier: appGroupIdentifier,
            bundleIdentifier: appBundleIdentifier
        )
        return MCPBridgeClient(
            handshake: try MCPBridgeClient.locateHandshake(in: candidates),
            // Tells the app who is asking, so Settings and the sidebar can show
            // "Claude Code" rather than an anonymous count.
            identity: MCPBridgeClient.identityHeader(version: serverVersion)
        )
    }

    private static func text(_ body: String, isError: Bool = false) -> CallTool.Result {
        CallTool.Result(content: [.text(body)], isError: isError)
    }
}
