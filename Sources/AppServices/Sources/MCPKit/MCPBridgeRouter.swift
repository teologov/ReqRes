//
//  MCPBridgeRouter.swift
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

import Foundation

/// Routes bridge requests to the app-provided data seams, enforcing the
/// security baseline on every request: loopback Host, no foreign Origin,
/// bearer-token auth (constant-time), redaction on the way out.
public final class MCPBridgeRouter {
    public static let bridgeVersion = 2

    private let token: String
    private let sessions: MCPSessionProviding
    private let status: MCPStatusProviding
    /// Re-read per access, not captured once. The per-host redaction policy is
    /// a live setting: a user who excepts a host mid-session must not have to
    /// restart the bridge — which would rotate the token and disconnect every
    /// client — for it to take effect. A caller that has no such setting keeps
    /// passing a plain redactor and this closure just hands the same one back.
    private let redactorSource: () -> MCPRedactor
    private var redactor: MCPRedactor { redactorSource() }
    /// Who is using the bridge. Optional so tests and the health check do not
    /// have to care.
    private let clients: MCPClientRegistry?
    /// RR-MCP-2. Nil until the app wires it; every write then answers 503.
    private let writes: MCPWriteSeams?

    public init(
        token: String,
        sessions: MCPSessionProviding,
        status: MCPStatusProviding,
        redactor: MCPRedactor = MCPRedactor(),
        redactorProvider: (() -> MCPRedactor)? = nil,
        writes: MCPWriteSeams? = nil,
        clients: MCPClientRegistry? = nil
    ) {
        self.token = token
        self.sessions = sessions
        self.status = status
        // `redactorProvider` wins when given; `redactor` stays the parameter
        // every existing call site and test passes, defaulting to redact-all.
        self.redactorSource = redactorProvider ?? { redactor }
        self.writes = writes
        self.clients = clients
    }

    public func respond(to request: MCPHTTPRequest) -> Data {
        // DNS-rebinding defense: a browser reaching this listener through a
        // hostname that resolves to 127.0.0.1 sends that hostname as Host.
        if let host = request.headers["host"], !Self.isLoopbackHostHeader(host) {
            return MCPHTTPResponse.error(status: 403, code: "forbidden_host", message: "Bridge accepts loopback requests only.")
        }
        // Non-browser MCP clients send no Origin; any cross-site browser call does.
        if let origin = request.headers["origin"], !Self.isAllowedOrigin(origin) {
            return MCPHTTPResponse.error(status: 403, code: "forbidden_origin", message: "Bridge does not accept browser cross-origin requests.")
        }

        if request.path == "/v1/health" {
            guard request.method == "GET" else { return methodNotAllowed() }
            struct Health: Encodable {
                let ok: Bool
                let service: String
                let bridgeVersion: Int
            }
            return MCPHTTPResponse.json(status: 200, Health(ok: true, service: "reqres-mcp-bridge", bridgeVersion: Self.bridgeVersion))
        }

        guard authorized(request) else {
            return MCPHTTPResponse.error(
                status: 401,
                code: "unauthorized",
                message: "Missing or invalid bearer token. Read it from the handshake file written by the running ReqRes app.",
                extraHeaders: ["WWW-Authenticate": "Bearer"]
            )
        }

        // Recorded after the token check on purpose: anything that can reach
        // the port could otherwise put a label of its choosing in the sidebar.
        clients?.record(header: request.headers[MCPClientRegistry.headerName])

        switch (request.method, request.path) {
        // capture_status (doc §S13): the status plus the short protocol list,
        // with this Mac's notes read from that same status.
        case ("GET", "/v1/status"):
            var current = status.bridgeStatus()
            current.protocols = ProtocolSupport.statusLines(state: ProtocolSupport.state(for: current))
            return MCPHTTPResponse.json(status: 200, current)

        // Read-only: no consent, no audit. It answers "why is nothing being
        // captured", which is the one question an agent cannot work out from
        // status fields alone.
        case ("GET", "/v1/diagnose"):
            return MCPHTTPResponse.json(status: 200, MCPSetupDiagnosis.report(status.setupFacts()))

        case ("GET", "/v1/sessions"):
            let items = request.queryItems
            let filter: MCPSessionFilter
            do {
                filter = try MCPSessionFilter(queryItems: items)
            } catch let error as MCPQueryParameterError {
                // A filter that cannot be applied is refused, never dropped:
                // an unfiltered page returned for `?pid=curl` reads as "no
                // sessions from curl" to the agent that asked.
                return MCPHTTPResponse.error(status: 400, code: "bad_request", message: error.message)
            } catch {
                return MCPHTTPResponse.error(status: 400, code: "bad_request", message: "Malformed query string.")
            }
            let limit = items.first(where: { $0.name == "limit" })?.value.flatMap(Int.init)
            let cursor = items.first(where: { $0.name == "cursor" })?.value
            var page = MCPSessionQuery.page(
                from: sessions.sessionSummaries(),
                filter: filter,
                limit: limit,
                cursor: cursor,
                redactor: redactor
            )
            page.sessions = page.sessions.map(redactor.redactSummary)
            return MCPHTTPResponse.json(status: 200, page)

        // Read-only, no consent, no audit: where the matching sessions went,
        // by destination. Same filters as /v1/sessions, same 400 for one that
        // cannot be applied. Hosts and app names are the only strings in the
        // report — no URL, no header, nothing the redactor masks — and the
        // user's own location is never in it (destination-map UX spec §8.3).
        case ("GET", "/v1/destinations"):
            let filter: MCPSessionFilter
            do {
                filter = try MCPSessionFilter(queryItems: request.queryItems)
            } catch let error as MCPQueryParameterError {
                return MCPHTTPResponse.error(status: 400, code: "bad_request", message: error.message)
            } catch {
                return MCPHTTPResponse.error(status: 400, code: "bad_request", message: "Malformed query string.")
            }
            let report = MCPDestinationAggregation.report(summaries: sessions.sessionSummaries(), filter: filter, redactor: redactor)
            return MCPHTTPResponse.json(status: 200, report)

        // `get_session view=events|assembled` (protocol-engine doc §S5).
        // Read-only, no consent: the same material as get_session, redacted
        // per event, complete events only.
        case ("GET", let path) where path.hasPrefix("/v1/sessions/") && (path.hasSuffix("/events") || path.hasSuffix("/assembled")):
            let view: MCPStreamView = path.hasSuffix("/events") ? .events : .assembled
            let uid = String(path.dropFirst("/v1/sessions/".count).dropLast(view.rawValue.count + 1))
            return streamView(uid: uid, view: view, query: request.queryItems)

        // `get_session view=rpc` (protocol-engine doc §S8): a gRPC-Web,
        // Connect or native gRPC row's messages as field-number trees and
        // the RPC's status. Read-only, no consent; redacted per value.
        case ("GET", let path) where path.hasPrefix("/v1/sessions/") && path.hasSuffix("/rpc"):
            let uid = String(path.dropFirst("/v1/sessions/".count).dropLast("/rpc".count))
            return rpcView(uid: uid, query: request.queryItems)

        // `list_messages` (protocol-engine doc §S7): one WebSocket
        // connection's kept messages, redacted one by one. Read-only.
        case ("GET", let path) where path.hasPrefix("/v1/sessions/") && path.hasSuffix("/messages"):
            let uid = String(path.dropFirst("/v1/sessions/".count).dropLast("/messages".count))
            return socketMessages(uid: uid, query: request.queryItems)

        // `wait_for_message`'s poll: with no `since`, only the newest ordinal
        // (the baseline); with one, the matches that arrived after it.
        case ("GET", "/v1/messages"):
            return socketFeed(query: request.queryItems)

        case ("GET", let path) where path.hasPrefix("/v1/sessions/") && path.hasSuffix("/body"):
            let uid = String(path.dropFirst("/v1/sessions/".count).dropLast("/body".count))
            guard !uid.isEmpty, !uid.contains("/") else {
                return MCPHTTPResponse.error(status: 400, code: "bad_request", message: "Malformed session id.")
            }
            let items = request.queryItems
            let side = MCPBodySide(rawValue: items.first(where: { $0.name == "side" })?.value ?? "response") ?? .response
            let modeRaw = items.first(where: { $0.name == "mode" })?.value ?? MCPJSONQuery.Mode.structure.rawValue
            guard let mode = MCPJSONQuery.Mode(rawValue: modeRaw) else {
                return MCPHTTPResponse.error(
                    status: 400,
                    code: "bad_request",
                    message: "Unknown mode '\(modeRaw)'. Supported: \(MCPJSONQuery.Mode.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            // What the capture did NOT keep of the body, and whether the row
            // is a relay: both change what the answer means, so the query
            // reports them rather than leaving an agent to read a prefix as
            // the whole body. Facts only — a whole detail would build a cURL.
            let facts = sessions.sessionBodyFacts(uid: uid)
            if facts?.isLive == true {
                // A prefix is not a body, and a JSON prefix defeats the
                // structural redaction the query runs first.
                return MCPHTTPResponse.error(
                    status: 409,
                    code: "in_flight",
                    message: "Session \(uid) has not finished: its bodies are queried once it does. Call wait_for_session with until=complete, or use get_session view=events for a stream's complete events."
                )
            }
            guard let body = sessions.sessionBody(uid: uid, side: side) else {
                if facts?.isRelay == true {
                    return MCPHTTPResponse.error(
                        status: 404,
                        code: "not_found",
                        message: "Session \(uid) is a relayed connection: \(RecordedExchangeCopy.relayExplanationAnyScheme) There is no body to query."
                    )
                }
                return MCPHTTPResponse.error(
                    status: 404,
                    code: "not_found",
                    message: "No \(side.rawValue) body for session \(uid) in the current capture run."
                )
            }
            let queryPath = items.first(where: { $0.name == "path" })?.value
            // Redact BEFORE querying so a matched value can never leak a credential.
            let outcome = MCPJSONQuery.query(body: redactor.redactBodyPreview(body), mode: mode, path: queryPath)
            // cappedPreview already appends the truncation marker when it cuts.
            let capped = MCPSessionQuery.cappedPreview(outcome.text).preview ?? ""
            return MCPHTTPResponse.json(status: 200, MCPBodyQueryResult(
                uid: uid,
                side: side,
                mode: mode.rawValue,
                path: queryPath,
                found: outcome.found,
                text: capped,
                notRetainedBytes: facts.map { $0.notRetainedBytes(side) }
            ))

        // The waiters' second read per poll (`MCPWatchedRows`): every
        // in-flight row plus the rows named in `uids`, wherever they sit in
        // the list. A live row is finalized IN PLACE, so a long request
        // pushed past the newest page by later traffic is only ever seen
        // finishing through here. Read-only, redacted like the list.
        case ("GET", "/v1/sessions/watched"):
            let raw = request.queryItems.first(where: { $0.name == "uids" })?.value ?? ""
            let wanted = Set(raw.split(separator: ",").map { String($0) }.prefix(MCPWatchedRows.capacity))
            let rows = sessions.sessionSummaries().reversed().filter { $0.isInFlight || wanted.contains($0.uid) }
            // Named rows first under the cap: they are the ones a wait is
            // already following; an in-flight row beyond the cap is caught
            // on a later poll.
            let named = rows.filter { wanted.contains($0.uid) }
            let others = rows.filter { !wanted.contains($0.uid) }.prefix(max(MCPWatchedRows.capacity - named.count, 0))
            let keep = Set(named.map(\.uid)).union(others.map(\.uid))
            let page = MCPSessionPage(
                sessions: rows.filter { keep.contains($0.uid) }.map(redactor.redactSummary),
                nextCursor: nil,
                totalMatched: rows.count,
                note: nil
            )
            return MCPHTTPResponse.json(status: 200, page)

        case ("GET", let path) where path.hasPrefix("/v1/sessions/"):
            let uid = String(path.dropFirst("/v1/sessions/".count))
            guard !uid.isEmpty, !uid.contains("/") else {
                return MCPHTTPResponse.error(status: 400, code: "bad_request", message: "Malformed session id.")
            }
            guard let rawDetail = sessions.sessionDetail(uid: uid) else {
                return MCPHTTPResponse.error(status: 404, code: "not_found", message: "No session with uid \(uid) in the current capture run.")
            }
            return MCPHTTPResponse.json(status: 200, egress(rawDetail))

        // ── RR-MCP-2 write surface ──────────────────────────────────────
        case ("GET", "/v1/hosts"):
            return withWrites { writes in
                struct Envelope: Encodable { let hosts: [MCPHost] }
                return MCPHTTPResponse.json(status: 200, Envelope(hosts: try writes.hosts.hosts()))
            }

        case ("POST", "/v1/hosts"):
            return withWrites { writes in
                let draft = try MCPWriteValidation.validate(try Self.decodeBody(MCPHostDraft.self, from: request))
                let action = MCPAgentAction(
                    kind: .addHost,
                    summary: "Add the host filter \(draft.host) (\(draft.scheme))",
                    details: draft.port.map { ["Port: \($0)"] } ?? []
                )
                return self.performWrite(writes, action, status: 201, created: { .host($0.id) }) { try writes.hosts.addHost(draft) } detail: { "host #\($0.id) \($0.host)" }
            }

        case ("DELETE", let path) where path.hasPrefix("/v1/hosts/"):
            return withWrites { writes in
                let id = try Self.pathId(path, prefix: "/v1/hosts/", what: "host")
                // Resolve BEFORE interrupting the human: a bad id must not
                // produce an approval panel for a host that does not exist.
                guard let host = try writes.hosts.hosts().first(where: { $0.id == id }) else {
                    throw MCPWriteError.notFound("No host filter with id \(id). Use list_hosts to see the current ids.")
                }
                let name = host.host
                let ruleCount = (try? writes.rules.rules().filter { $0.hostId == id }.count) ?? 0
                let action = MCPAgentAction(
                    kind: .removeHost,
                    summary: "Remove the host filter \(name)",
                    details: [ruleCount == 0 ? "It has no rules." : "Its \(ruleCount) rule\(ruleCount == 1 ? "" : "s") are removed with it."]
                )
                return self.performWrite(writes, action, previousState: .host(host)) { try writes.hosts.removeHost(id: id); return MCPDeleted(id: id) } detail: { _ in "host #\(id) \(name)" }
            }

        case ("GET", "/v1/rules"):
            return withWrites { writes in
                struct Envelope: Encodable { let rules: [MCPRule] }
                var rules = try writes.rules.rules()
                if let hostId = request.queryItems.first(where: { $0.name == "host_id" })?.value.flatMap(Int64.init) {
                    rules = rules.filter { $0.hostId == hostId }
                }
                // Rules carry captured and human-entered credentials; the write
                // surface redacts exactly like the read surface.
                return MCPHTTPResponse.json(status: 200, Envelope(rules: rules.map(self.redactor.redactRule)))
            }

        case ("POST", "/v1/rules"):
            return withWrites { writes in
                // A new rule's defaults are applied BEFORE the human is asked,
                // so the panel lists the Content-Type an override will carry.
                let draft = try MCPWriteValidation.validateNewRule(try Self.decodeBody(MCPRuleDraft.self, from: request))
                let hostName = (try? writes.hosts.hosts())?.first(where: { $0.id == draft.hostId })?.host
                let action = MCPAgentAction(kind: .createRule, summary: Self.describe(draft, host: hostName), details: Self.details(draft))
                return self.performWrite(writes, action, status: 201, created: { .rule($0.id) }) { self.redactor.redactRule(try writes.rules.createRule(draft)) } detail: { "rule #\($0.id)" }
            }

        case ("POST", "/v1/rules/from-session"):
            return withWrites { writes in
                let mock = try Self.decodeBody(MCPMockFromSessionRequest.self, from: request)
                guard !mock.uid.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw MCPWriteError.invalid("uid is required (take one from list_sessions).")
                }
                if let mode = mock.mode, mode == .extend {
                    throw MCPWriteError.invalid("mock_from_session supports override (inline) or map_local (a file); use create_rule for an extend rule.")
                }
                let mode = mock.mode ?? .override
                // The session first: a mock that names no status replays the
                // captured one, and the refusals say so (`StatusRoute.mock`).
                let session = self.sessions.sessionDetail(uid: mock.uid)?.summary
                let replays = session?.statusCode.flatMap { RuleResponseDefaults.answeringStatuses.contains($0) ? $0 : nil }
                // A mock answers itself: an override mock with a final
                // status — sent, or the captured one — and a map_local mock
                // with its file (it uses none).
                if let status = mock.responseStatus {
                    try MCPWriteValidation.validateStatus(status, mode: mode, route: .mock(replays: replays))
                } else {
                    try MCPWriteValidation.validateReplayedStatus(session?.statusCode, uid: mock.uid, mode: mode)
                }
                if let headers = mock.responseHeaders { try MCPWriteValidation.validateHeaders(headers, label: "responseHeaders") }
                // Validate the pattern BEFORE interrupting the human — a path
                // copied from a redacted read included: the derived one is
                // the capture's own, real query and all.
                if let path = mock.path {
                    let matchType = mock.matchType ?? .wildcard
                    let stored = try MCPWriteValidation.normalizedPath(path, matchType: matchType)
                    try MCPWriteValidation.refuseRedactionMarker(inPath: stored, matchType: matchType) {
                        "Leave path out: mock_from_session derives it from the captured request, real query and all. Or write \($0)."
                    }
                }
                // The human must see WHAT is being mocked, not a UUID: the
                // session, and whether a host filter will appear.
                let knownHost = session.flatMap { summary in
                    (try? writes.hosts.hosts())?.contains { $0.host.caseInsensitiveCompare(summary.host) == .orderedSame }
                } ?? false
                var details: [String] = []
                if let session {
                    details.append("Replays the captured response of \(session.method) \(self.redactor.redactURL(session.url))")
                    if !knownHost {
                        details.append("Adds a host filter for \(session.host) (it has none yet)")
                    }
                }
                if let status = mock.responseStatus {
                    details.append(mode == .mapLocal
                        ? "Status: not used — a map_local mock answers 200 with its file"
                        : "Status: \(status) (replaces the captured \(session?.statusCode.map(String.init) ?? "status"))")
                }
                if let body = mock.responseBody { details.append("Body: replaced, \(body.utf8.count) bytes") }
                if let headers = mock.responseHeaders, !headers.isEmpty { details.append("Headers set: \(Self.describeHeaders(headers))") }
                if let path = mock.path { details.append("Pattern: \(path)") }
                let scope = session.map { "\($0.method) \($0.host)" } ?? "session \(mock.uid)"
                let action = MCPAgentAction(
                    kind: .mockFromSession,
                    summary: "Create a \(mode.rawValue) rule for \(scope) that answers instead of the real server",
                    details: details
                )
                // A map_local mock stores a map_local rule's status, 0, as
                // the form and create_rule do — never the captured one, which
                // it does not use and which the rule's validation would
                // refuse after the human approved it when it is not final.
                var forwarded = mock
                if forwarded.responseStatus == nil, mode == .mapLocal {
                    forwarded.responseStatus = RuleResponseDefaults.status(forNewRuleIn: .mapLocal).stored
                }
                return self.performWrite(writes, action, status: 201, created: { .rule($0.id) }) { self.redactor.redactRule(try writes.rules.mockFromSession(forwarded)) } detail: { "rule #\($0.id)" }
            }

        case ("PATCH", let path) where path.hasPrefix("/v1/rules/"):
            return withWrites { writes in
                let id = try Self.pathId(path, prefix: "/v1/rules/", what: "rule")
                guard let current = try writes.rules.rules().first(where: { $0.id == id }) else {
                    throw MCPWriteError.notFound("No rule with id \(id). Use list_rules to see the current ids.")
                }
                // `shownPath`: the path as list_rules showed it, so the mask in
                // it sent back never replaces the credential it hid.
                let patch = try MCPWriteValidation.validate(
                    try Self.decodeBody(MCPRulePatch.self, from: request),
                    currentMode: current.mode,
                    currentMatchType: current.matchType,
                    currentPath: current.path,
                    shownPath: self.redactor.redactRule(current).path,
                    currentStatus: current.responseStatus
                )
                let action = MCPAgentAction(kind: .updateRule, summary: "Change rule #\(id) (\(Self.describe(current)))", details: Self.details(patch, current: current))
                // The snapshot keeps the rule's REAL values, not the redacted
                // copy that goes to the agent: restoring a masked value would
                // write the mask into live traffic. This is no more exposure
                // than the rule store itself already holds, but it does mean
                // any future audit-log EXPORT has to redact on the way out.
                return self.performWrite(writes, action, previousState: .rule(current)) { self.redactor.redactRule(try writes.rules.updateRule(id: id, patch: patch)) } detail: { "rule #\($0.id)" }
            }

        case ("DELETE", let path) where path.hasPrefix("/v1/rules/"):
            return withWrites { writes in
                let id = try Self.pathId(path, prefix: "/v1/rules/", what: "rule")
                guard let current = try writes.rules.rules().first(where: { $0.id == id }) else {
                    throw MCPWriteError.notFound("No rule with id \(id). Use list_rules to see the current ids.")
                }
                let action = MCPAgentAction(kind: .deleteRule, summary: "Delete rule #\(id) (\(Self.describe(current)))")
                return self.performWrite(writes, action, previousState: .rule(current)) { try writes.rules.deleteRule(id: id); return MCPDeleted(id: id) } detail: { _ in "rule #\(id)" }
            }

        case ("POST", "/v1/capture"):
            return withWrites { writes in
                let command = try Self.decodeBody(MCPCaptureRequest.self, from: request).action
                let action = MCPAgentAction(
                    kind: command == .start ? .startCapture : .stopCapture,
                    summary: command == .start ? "Start capturing network traffic" : "Stop capturing network traffic"
                )
                return self.performWrite(writes, action) {
                    switch command {
                    case .start: try writes.capture.startCapture()
                    case .stop: try writes.capture.stopCapture()
                    }
                    return self.status.bridgeStatus()
                } detail: { _ in command.rawValue }
            }

        case ("POST", "/v1/sessions/clear"):
            return withWrites { writes in
                let action = MCPAgentAction(kind: .clearSessions, summary: "Clear all captured sessions")
                return self.performWrite(writes, action) { MCPCleared(cleared: try writes.capture.clearSessions()) } detail: { "\($0.cleared) sessions" }
            }

        // Roadmap item 10. The first path by which captured material leaves
        // as a FILE, so: its own consent severity, its own validation of the
        // name (never the path), redaction inside the encoder, and a size cap
        // there too.
        case ("POST", "/v1/sessions/export"):
            return withWrites { writes in
                guard let exporter = writes.exporter else {
                    return MCPHTTPResponse.error(status: 503, code: "unavailable", message: "This build cannot write exports.")
                }
                do {
                    let export = try Self.decodeBody(MCPExportRequest.self, from: request)
                    let filename = try MCPWriteValidation.exportFilename(export.filename)
                    let uids = export.uids.filter { !$0.isEmpty }
                    guard !uids.isEmpty else {
                        throw MCPWriteError.invalid("uids is required: the session ids to export, from list_sessions.")
                    }
                    guard uids.count <= MCPLimits.maxPageSize else {
                        throw MCPWriteError.invalid("Export up to \(MCPLimits.maxPageSize) sessions at a time.")
                    }
                    // Resolved BEFORE consent so the panel can name the hosts
                    // involved, and so an unknown id fails with a 404 instead
                    // of interrupting the human for a call that cannot work.
                    let found = uids.compactMap { self.sessions.sessionDetail(uid: $0) }
                    // A live row has no finished response to write: left out,
                    // and said so (protocol PRD 4a.2).
                    // An ended row goes out without bodies, like get_session.
                    let details = found.filter { !$0.summary.isInFlight }.map { $0.withholdingLiveBodies() }
                    let skippedInFlight = found.count - details.count
                    guard !found.isEmpty else {
                        throw MCPWriteError.notFound("None of those session ids are in the current capture run.")
                    }
                    guard !details.isEmpty else {
                        throw MCPWriteError.invalid(LiveRowCopy.exportSkippedLine(skippedInFlight))
                    }
                    let action = MCPAgentAction(
                        kind: .exportSessions,
                        summary: "Save \(details.count) captured \(details.count == 1 ? "session" : "sessions") to \(filename)",
                        details: Self.exportDetails(details, requested: uids.count)
                    )
                    return self.performWrite(writes, action, status: 201) { () -> MCPExportResult in
                        let encoded = MCPHARExport.encode(
                            // Oldest first: a HAR is read as a timeline. A
                            // session with no recorded start sorts last
                            // rather than jumping to 1970.
                            sessions: details.sorted { ($0.summary.startedAt ?? .distantFuture) < ($1.summary.startedAt ?? .distantFuture) },
                            redactor: self.redactor,
                            creatorVersion: self.status.bridgeStatus().appVersion,
                            // A WebSocket's messages ride on its 101 entry.
                            webSocketMessages: Dictionary(details.compactMap { detail in
                                detail.summary.statusCode == 101
                                    ? self.sessions.socketConversation(uid: detail.summary.uid).map { (detail.summary.uid, $0) }
                                    : nil
                            }, uniquingKeysWith: { first, _ in first })
                        )
                        let url = try exporter.writeExport(encoded.data, filename: filename)
                        return MCPExportResult(
                            path: url.path,
                            includedCount: encoded.includedCount,
                            requestedCount: uids.count,
                            truncated: encoded.truncated,
                            bytes: encoded.data.count,
                            redacted: self.redactor.enabled,
                            skippedInFlight: skippedInFlight
                        )
                    } detail: { "\($0.includedCount) sessions → \($0.path)" }
                } catch let error as MCPWriteError {
                    return Self.response(for: error)
                } catch let error as DecodingError {
                    return MCPHTTPResponse.error(status: 400, code: "bad_request", message: Self.describe(error))
                } catch {
                    return MCPHTTPResponse.error(status: 500, code: "internal_error", message: error.localizedDescription)
                }
            }

        // ── Replay (horizon 3, item 17) ──────────────────────────────
        // The only route on this surface whose effect is NOT on this Mac.
        // Everything that makes that safe is in MCPReplayModels and enforced
        // before consent is asked: idempotent methods only, the host cannot
        // change, and its own severity that no standing grant covers. What
        // happens here is the usual shape — resolve, describe, consent,
        // perform, redact on the way out.
        case ("POST", "/v1/sessions/replay"):
            return withWrites { writes in
                guard let replayer = writes.replay else {
                    return MCPHTTPResponse.error(status: 503, code: "unavailable", message: "This ReqRes build cannot replay requests.")
                }
                let body = try Self.decodeBody(MCPReplayRequest.self, from: request)
                let uid = try MCPSavedSessionValidation.uid(body.uid)
                // Resolved BEFORE consent, like an export: the panel has to
                // name the method, host and path, and a uid that has aged out
                // must 404 rather than interrupt the human for a call that
                // cannot work.
                guard let captured = self.sessions.sessionDetail(uid: uid) else {
                    throw MCPWriteError.notFound("No session with uid \(uid) in the current capture run. Replay works on a session from the current run — list_sessions has the ids.")
                }
                // The plan is built from the RAW captured detail, credentials
                // included: a replay of a redacted request is a replay of a
                // request that fails. It goes app-ward only; what comes back
                // goes through `egress` like every other read.
                let plan = try MCPReplayPlan.make(replaying: captured, request: body)
                let action = MCPAgentAction(
                    kind: .replayRequest,
                    summary: plan.consentSummary,
                    details: plan.consentDetails
                )
                return self.performWrite(writes, action) { () -> MCPReplayResult in
                    let response = try replayer.replay(plan)
                    let detail = response.detail(for: plan)
                    return MCPReplayResult(
                        session: self.egress(detail),
                        route: response.route,
                        replayedFrom: uid,
                        redacted: self.redactor.enabled && self.redactor.policy.shouldRedact(host: plan.host)
                    )
                } detail: { result in
                    "\(plan.method) \(plan.host) → \(result.session.summary.statusCode.map(String.init) ?? "no response") via \(result.route.rawValue)"
                }
            }

        // ── Breakpoints (1.1.0) ─────────────────────────────────────────
        // The only surface where an agent touches traffic that is HAPPENING.
        // Reading what is held needs no consent — it is the read surface, and
        // it goes through the redactor like every other body. Answering one is
        // pre-authorised by a setting rather than a panel: see
        // `MCPBreakpointModels` for why a per-call approval cannot fit inside
        // the 60 seconds a held request has.
        case ("GET", "/v1/breakpoints/paused"):
            return withBreakpoints { _, breakpoints in
                MCPHTTPResponse.json(status: 200, MCPPausedRequestPage(
                    requests: breakpoints.pausedRequests().map { self.egress($0) },
                    armedRules: breakpoints.armedRuleCount,
                    agentDecisionsEnabled: breakpoints.agentDecisionsEnabled
                ))
            }

        case ("POST", "/v1/breakpoints/decide"):
            return withBreakpoints { writes, breakpoints in
                let decision = try Self.decodeBody(MCPBreakpointDecision.self, from: request)
                try MCPBreakpointValidation.validate(decision)

                // Resolved before anything else so the audit row names the
                // request rather than an opaque id — and so an id that has
                // already expired 404s instead of being recorded as a change.
                guard let held = breakpoints.pausedRequests().first(where: { $0.id == decision.id }) else {
                    throw MCPWriteError.notFound(
                        "No held request with id \(decision.id). A held request is released on its own "
                        + "within about a minute, so it has most likely already gone to the server "
                        + "untouched. Call list_paused_requests again and check secondsRemaining."
                    )
                }
                // What the request itself rules out (a body for a TRACE),
                // refused like bad input: before anything is recorded.
                try MCPBreakpointValidation.validate(decision, for: held)

                let action = MCPAgentAction(
                    kind: .answerPausedRequest,
                    summary: MCPBreakpointValidation.summary(for: decision, request: held),
                    details: Self.decisionDetails(decision, held: held)
                )

                // The grant is a setting, not a panel — but a refusal is still
                // recorded, because "an agent tried to answer a held request
                // while this was switched off" is exactly what the log is for.
                guard breakpoints.agentDecisionsEnabled else {
                    writes.audit.record(self.redactor.redactLogEntry(MCPAuditEntry(
                        action: action,
                        outcome: .denied,
                        detail: "Agents are not allowed to answer held requests."
                    )))
                    return MCPHTTPResponse.error(
                        status: 403,
                        code: "consent_denied",
                        message: "The user has not allowed agents to answer held requests. They can turn that on in "
                            + "Settings → Breakpoints; until then the request stays held and they answer it in the "
                            + "ReqRes window."
                    )
                }

                return self.performWrite(writes, action, preauthorized: true) { () -> MCPBreakpointOutcome in
                    // The app builds the outcome from the RAW held request;
                    // the reply is the read surface again and leaves like
                    // the listing does, per-host exception included (F15).
                    self.redactor.redactOutcome(try breakpoints.decide(decision))
                } detail: { outcome in
                    outcome.summary
                }
            }

        // ── Saved sessions (1.1.0) ──────────────────────────────────────
        // The window can keep a captured exchange past the end of the run;
        // an agent can do the same, under the same consent. Reads here are
        // read surface — no consent, no audit — but they go through the
        // redactor exactly like /v1/sessions does, because the STORED copy is
        // the real exchange and saving one would otherwise be a way to launder
        // a credential past the read surface.
        case ("GET", "/v1/saved-sessions"):
            return withSavedSessions { _, store in
                let limit = MCPSavedSessionValidation.limit(request.queryItems.first(where: { $0.name == "limit" })?.value.flatMap(Int.init))
                var page = try store.savedSessions(limit: limit)
                page.saved = page.saved.map(self.egress)
                return MCPHTTPResponse.json(status: 200, page)
            }

        case ("GET", let path) where path.hasPrefix("/v1/saved-sessions/"):
            return withSavedSessions { _, store in
                let id = try Self.pathId(path, prefix: "/v1/saved-sessions/", what: "saved_session")
                guard let saved = try store.savedSession(id: id) else {
                    throw MCPWriteError.notFound("No saved session with id \(id). Use list_saved_sessions to see the current ids.")
                }
                return MCPHTTPResponse.json(status: 200, self.egress(saved))
            }

        case ("POST", "/v1/saved-sessions"):
            return withSavedSessions { writes, store in
                let body = try Self.decodeBody(MCPSaveSessionRequest.self, from: request)
                let uid = try MCPSavedSessionValidation.uid(body.uid)
                let note = try MCPSavedSessionValidation.note(body.note)
                // Resolved BEFORE consent, like an export: the panel has to
                // name whose traffic is about to be written down, and a uid
                // that has already aged out must 404 rather than interrupt
                // the human for a call that cannot work.
                guard let detail = self.sessions.sessionDetail(uid: uid) else {
                    throw MCPWriteError.notFound("No session with uid \(uid) in the current capture run. Saved sessions are kept by id; only a session still in the run can be saved.")
                }
                let action = MCPAgentAction(
                    kind: .saveSession,
                    summary: "Save a captured request from \(detail.summary.host) to ReqRes's saved sessions",
                    details: Self.saveDetails(detail, note: note, url: self.redactor.redactURL(detail.summary.url))
                )
                return self.performWrite(writes, action, status: 201) {
                    self.egress(try store.saveSession(uid: uid, note: note))
                } detail: { "saved session #\($0.id) \($0.session.host)" }
            }

        case ("DELETE", let path) where path.hasPrefix("/v1/saved-sessions/"):
            return withSavedSessions { writes, store in
                let id = try Self.pathId(path, prefix: "/v1/saved-sessions/", what: "saved_session")
                // Named before it is gone: "Delete saved session #12" tells
                // the human nothing about which exchange they are losing.
                guard let existing = try store.savedSession(id: id) else {
                    throw MCPWriteError.notFound("No saved session with id \(id). Use list_saved_sessions to see the current ids.")
                }
                let action = MCPAgentAction(
                    kind: .deleteSavedSession,
                    summary: "Delete the saved session #\(id) — \(existing.session.summary.method.uppercased()) from \(existing.session.summary.host)",
                    details: Self.deleteSavedDetails(existing, url: self.redactor.redactURL(existing.session.summary.url))
                )
                return self.performWrite(writes, action) {
                    try store.deleteSavedSession(id: id)
                    return MCPDeleted(id: id)
                } detail: { _ in "saved session #\(id)" }
            }

        // PRD 3.5. The name is checked and the list consulted BEFORE the
        // human is asked: a bad name must not raise a panel, and a host that
        // is already excluded has nothing to approve (answered 200 with
        // `alreadyExcluded`, nothing logged). The snapshot is the list before
        // the change, so an undo can take exactly this entry back off.
        case ("POST", "/v1/exclusions"):
            return withExclusions { writes, exclusions in
                let body = try Self.decodeBody(MCPExcludeHostRequest.self, from: request)
                let before = try exclusions.excludedHosts()
                switch exclusions.check(body.host) {
                case .invalid(let message):
                    throw MCPWriteError.invalid(message)
                case .alreadyExcluded(let entry):
                    return MCPHTTPResponse.json(status: 200, MCPExclusionResult(host: entry, alreadyExcluded: true, excludedHosts: before))
                case .add(let entry):
                    let action = MCPAgentAction(
                        kind: .excludeHost,
                        summary: FailureRowCopy.exclusionConsequence(entry),
                        details: [
                            FailureRowCopy.exclusionScope,
                            "Settings ▸ Capture lists the host and puts it back.",
                        ]
                    )
                    return self.performWrite(
                        writes, action,
                        previousState: .exclusion(MCPExclusionSnapshot(host: entry, before: before))
                    ) {
                        MCPExclusionResult(host: entry, alreadyExcluded: false, excludedHosts: try exclusions.exclude(entry))
                    } detail: { _ in "excluded \(entry)" }
                }
            }

        case ("POST", "/v1/patterns/test"):
            // Pure — no consent, no audit.
            do {
                let test = try Self.decodeBody(MCPPatternTestRequest.self, from: request)
                // The same validation create_rule applies, so a pattern that
                // passes here is one that can actually be stored — a path
                // holding what reads show in place of a credential included:
                // tested against a URL read the same way it matches (both say
                // REDACTED), whatever the real tokens are, and create_rule
                // refuses to store it.
                let path = try MCPWriteValidation.normalizedPath(test.path, matchType: test.matchType)
                try MCPWriteValidation.refuseRedactionMarker(inPath: path, matchType: test.matchType) {
                    "A masked value can be neither tested nor stored: write the real value, or \($0)."
                }
                guard let parsed = URL(string: test.url.trimmingCharacters(in: .whitespaces)), let host = parsed.host else {
                    throw MCPWriteError.invalid("url must be a full URL, e.g. https://api.example.com/users?id=1")
                }
                let matches = OverridePattern.matches(url: test.url, path: path, isRegex: test.matchType == .regex)
                return MCPHTTPResponse.json(status: 200, MCPPatternTestResult(
                    path: path,
                    url: test.url,
                    matchType: test.matchType,
                    matches: matches,
                    proxyPattern: OverridePattern.proxyPattern(scheme: parsed.scheme ?? "https", host: host, path: path)
                ))
            } catch let error as MCPWriteError {
                return Self.response(for: error)
            } catch {
                return MCPHTTPResponse.error(status: 400, code: "bad_request", message: error.localizedDescription)
            }

        default:
            // A known path with the wrong method is 405; anything else 404.
            return Self.isKnownPath(request.path)
                ? methodNotAllowed()
                : MCPHTTPResponse.error(status: 404, code: "not_found", message: "Unknown path.")
        }
    }

    static let knownPaths: Set<String> = ["/v1/status", "/v1/diagnose", "/v1/sessions", "/v1/destinations", "/v1/sessions/clear", "/v1/sessions/watched", "/v1/sessions/export", "/v1/sessions/replay", "/v1/saved-sessions", "/v1/hosts", "/v1/rules", "/v1/rules/from-session", "/v1/capture", "/v1/patterns/test", "/v1/exclusions"]
    static let knownPrefixes = ["/v1/sessions/", "/v1/saved-sessions/", "/v1/hosts/", "/v1/rules/"]

    static func isKnownPath(_ path: String) -> Bool {
        knownPaths.contains(path) || knownPrefixes.contains { path.hasPrefix($0) }
    }

    private func methodNotAllowed() -> Data {
        MCPHTTPResponse.error(status: 405, code: "method_not_allowed", message: "Bridge v\(Self.bridgeVersion) supports GET, POST, PATCH and DELETE.")
    }

    // MARK: - Writes: consent → perform → audit

    /// Runs a write route with the seams, translating thrown `MCPWriteError`s
    /// (and decode failures) into responses.
    private func withWrites(_ body: (MCPWriteSeams) throws -> Data) -> Data {
        guard let writes else {
            return MCPHTTPResponse.error(status: 503, code: "writes_unavailable", message: "This ReqRes build does not expose the write surface.")
        }
        do {
            return try body(writes)
        } catch let error as MCPWriteError {
            return Self.response(for: error)
        } catch let error as DecodingError {
            return MCPHTTPResponse.error(status: 400, code: "bad_request", message: Self.describe(error))
        } catch {
            return MCPHTTPResponse.error(status: 500, code: "internal_error", message: error.localizedDescription)
        }
    }

    /// Runs a saved-session route. Wraps `withWrites` because the store
    /// travels with the write seams, and answers 503 for its own absence so a
    /// build without it says which piece is missing rather than blaming the
    /// whole write surface.
    private func withSavedSessions(_ body: (MCPWriteSeams, MCPSavedSessionProviding) throws -> Data) -> Data {
        withWrites { writes in
            guard let store = writes.savedSessions else {
                return MCPHTTPResponse.error(status: 503, code: "unavailable", message: "This ReqRes build cannot keep saved sessions.")
            }
            return try body(writes, store)
        }
    }

    private func withExclusions(_ body: (MCPWriteSeams, MCPExclusionProviding) throws -> Data) -> Data {
        withWrites { writes in
            guard let exclusions = writes.exclusions else {
                return MCPHTTPResponse.error(status: 503, code: "unavailable", message: "This ReqRes build cannot change the exclusion list.")
            }
            return try body(writes, exclusions)
        }
    }

    private func withBreakpoints(_ body: (MCPWriteSeams, MCPBreakpointProviding) throws -> Data) -> Data {
        withWrites { writes in
            guard let breakpoints = writes.breakpoints else {
                return MCPHTTPResponse.error(status: 503, code: "unavailable", message: "This ReqRes build has no breakpoints.")
            }
            return try body(writes, breakpoints)
        }
    }

    /// What the audit row says a decision actually did. The summary is one
    /// line; these are the specifics a user reads later when asking what an
    /// agent changed about a request they never saw finish.
    private static func decisionDetails(_ decision: MCPBreakpointDecision, held: MCPPausedRequest) -> [String] {
        var details = ["Held request — \(held.method) \(held.url)"]
        switch decision.action {
        case .abort:
            details.append("Answered with \(decision.abortStatus ?? MCPBreakpointValidation.defaultAbortStatus); the server never received it")
        case .resume:
            // Header VALUES, like the rule consent copy: names alone hide
            // exactly what makes an edit worth reading. The log's copy is
            // redacted on the way in, the panel's is not.
            if let set = decision.setHeaders, !set.isEmpty {
                details.append("Headers set — " + set.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: ", "))
            }
            if let removed = decision.removeHeaders, !removed.isEmpty {
                details.append("Headers removed — " + removed.joined(separator: ", "))
            }
            if let body = decision.body {
                details.append("Body replaced (\(body.utf8.count) bytes)")
            }
            if !decision.editsAnything {
                details.append("Sent on unchanged")
            }
        }
        return details
    }

    // MARK: - Egress: everything a session leaves in

    /// A captured session on its way out: redacted, then capped.
    ///
    /// ORDER IS LOAD-BEARING: redact the FULL body first, then cap. Capping
    /// first can cut a secret mid-value, leaving its head in the clear where
    /// structural redaction can no longer recognise it. One function so the
    /// live route and the saved-session route cannot drift on that order —
    /// the saved copy is stored unredacted, so this is the only thing standing
    /// between a kept Authorization header and an agent's context.
    private func streamView(uid: String, view: MCPStreamView, query items: [URLQueryItem]) -> Data {
        guard !uid.isEmpty, !uid.contains("/") else {
            return MCPHTTPResponse.error(status: 400, code: "bad_request", message: "Malformed session id.")
        }
        guard let facts = sessions.sessionStreamFacts(uid: uid) else {
            return MCPHTTPResponse.error(status: 404, code: "not_found", message: "No session with uid \(uid) in the current capture run.")
        }
        if facts.isRelay {
            return MCPHTTPResponse.error(
                status: 404,
                code: "not_found",
                message: "Session \(uid) is a relayed connection: \(RecordedExchangeCopy.relayExplanationAnyScheme) There is no stream to read."
            )
        }
        guard let format = StreamFormat.detect(contentType: facts.contentType) else {
            let type = facts.contentType.map { MCPRedactor.redactStatic($0, aggressive: false) } ?? "none"
            return MCPHTTPResponse.error(
                status: 400,
                code: "not_a_stream",
                message: "Session \(uid)'s response is not a stream (Content-Type: \(type)). view=events and view=assembled read text/event-stream and NDJSON responses; call get_session without a view."
            )
        }
        guard let body = sessions.sessionStreamBody(uid: uid) else {
            if facts.inFlight {
                return MCPHTTPResponse.error(status: 404, code: "not_found", message: "Session \(uid) is still in flight and no text of its response has arrived yet. Call again, or wait_for_session with until=first_message.")
            }
            return MCPHTTPResponse.error(status: 404, code: "not_found", message: "Session \(uid) has no response body in the current capture run.")
        }
        let prepared = MCPStreamEgress.prepare(body: body, format: format, redacting: redactor.redacts(host: facts.host))
        switch view {
        case .events:
            let from = items.first(where: { $0.name == "from" })?.value.flatMap(Int.init)
            let limit = items.first(where: { $0.name == "limit" })?.value.flatMap(Int.init)
            return MCPHTTPResponse.json(status: 200, MCPStreamEgress.eventsPage(uid: uid, prepared: prepared, stream: facts, from: from, limit: limit))
        case .assembled:
            return MCPHTTPResponse.json(status: 200, MCPStreamEgress.assembled(uid: uid, prepared: prepared, stream: facts))
        }
    }

    private func rpcView(uid: String, query items: [URLQueryItem]) -> Data {
        guard !uid.isEmpty, !uid.contains("/") else {
            return MCPHTTPResponse.error(status: 400, code: "bad_request", message: "Malformed session id.")
        }
        guard let facts = sessions.sessionRPCFacts(uid: uid) else {
            return MCPHTTPResponse.error(status: 404, code: "not_found", message: "No session with uid \(uid) in the current capture run.")
        }
        if facts.isRelay {
            return MCPHTTPResponse.error(
                status: 404,
                code: "not_found",
                message: "Session \(uid) is a relayed connection: \(RecordedExchangeCopy.relayExplanationAnyScheme) There is no RPC to read."
            )
        }
        if facts.isLive {
            // A live snapshot's body may end mid-message; only whole frames
            // would be shown, but a body still arriving is not read at all
            // (the S6 rule every body surface follows).
            return MCPHTTPResponse.error(
                status: 409,
                code: "in_flight",
                message: "Session \(uid) has not finished: its messages are read once it does. Call wait_for_session with until=complete."
            )
        }
        guard let decoded = RPCExchange.decode(facts.input) else {
            let type = facts.input.requestContentType ?? facts.input.responseContentType
            let shown = type.map { MCPRedactor.redactStatic($0, aggressive: false) } ?? "none"
            return MCPHTTPResponse.error(
                status: 400,
                code: "not_an_rpc",
                message: "Session \(uid) is not a gRPC, gRPC-Web or Connect call (Content-Type: \(shown)). view=rpc reads application/grpc*, application/connect+* and Connect unary (application/proto, or application/json with Connect-Protocol-Version); call get_session without a view."
            )
        }
        let from = items.first(where: { $0.name == "from" })?.value.flatMap(Int.init)
        let limit = items.first(where: { $0.name == "limit" })?.value.flatMap(Int.init)
        return MCPHTTPResponse.json(status: 200, MCPRPCEgress.view(uid: uid, facts: facts, decoded: decoded, redactor: redactor, from: from, limit: limit))
    }

    private func socketMessages(uid: String, query items: [URLQueryItem]) -> Data {
        guard !uid.isEmpty, !uid.contains("/") else {
            return MCPHTTPResponse.error(status: 400, code: "bad_request", message: "Malformed session id.")
        }
        let filter: MCPMessageFilter
        do {
            filter = try MCPMessageFilter(queryItems: items)
        } catch let error as MCPQueryParameterError {
            return MCPHTTPResponse.error(status: 400, code: "bad_request", message: error.message)
        } catch {
            return MCPHTTPResponse.error(status: 400, code: "bad_request", message: "Malformed query string.")
        }
        guard let conversation = sessions.socketConversation(uid: uid) else {
            return MCPHTTPResponse.error(status: 404, code: "not_found", message: "No session with uid \(uid) in the current capture run.")
        }
        guard conversation.isWebSocket || conversation.log != nil else {
            return MCPHTTPResponse.error(
                status: 400,
                code: "not_a_websocket",
                message: "Session \(uid) is not a WebSocket connection (a 101 Switching Protocols naming websocket). list_sessions with status=101 lists them."
            )
        }
        let cursor = items.first(where: { $0.name == "cursor" })?.value
        let limit = items.first(where: { $0.name == "limit" })?.value.flatMap(Int.init)
        let page = MCPSocketEgress.page(conversation, filter: filter, cursor: cursor, limit: limit,
                                        redacting: redactor.redacts(host: conversation.host))
        return MCPHTTPResponse.json(status: 200, page)
    }

    private func socketFeed(query items: [URLQueryItem]) -> Data {
        let filter: MCPMessageFilter
        do {
            filter = try MCPMessageFilter(queryItems: items)
        } catch let error as MCPQueryParameterError {
            return MCPHTTPResponse.error(status: 400, code: "bad_request", message: error.message)
        } catch {
            return MCPHTTPResponse.error(status: 400, code: "bad_request", message: "Malformed query string.")
        }
        guard let rawSince = items.first(where: { $0.name == "since" })?.value, !rawSince.isEmpty else {
            let raw = sessions.socketFeed(afterOrdinal: nil, scanLimit: 0)
            return MCPHTTPResponse.json(status: 200, MCPSocketFeed(latestOrdinal: raw.latestOrdinal, scannedThrough: raw.latestOrdinal, messages: []))
        }
        guard let since = Int64(rawSince), since >= 0 else {
            return MCPHTTPResponse.error(status: 400, code: "bad_request", message: "'since' must be an ordinal from a previous answer (a non-negative integer).")
        }
        let limit = min(max(1, items.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 20), MCPSocketEgress.maxPageSize)
        let raw = sessions.socketFeed(afterOrdinal: since, scanLimit: MCPSocketEgress.feedScanLimit)
        let redactor = self.redactor
        let feed = MCPSocketEgress.feed(raw, after: since, filter: filter, limit: limit, redacts: { redactor.redacts(host: $0) })
        return MCPHTTPResponse.json(status: 200, feed)
    }

    private func egress(_ detail: MCPSessionDetail) -> MCPSessionDetail {
        // A live row's bodies may be prefixes, which structural redaction
        // cannot parse: none leaves (protocol-engine doc §S6).
        let detail = detail.withholdingLiveBodies()
        var redacted = redactor.redactDetail(detail)
        let cappedRequest = MCPSessionQuery.cappedPreview(redacted.requestBodyPreview)
        let cappedResponse = MCPSessionQuery.cappedPreview(redacted.responseBodyPreview)
        redacted.requestBodyPreview = cappedRequest.preview
        redacted.requestBodyTruncated = detail.requestBodyTruncated || cappedRequest.truncated
        redacted.responseBodyPreview = cappedResponse.preview
        redacted.responseBodyTruncated = detail.responseBodyTruncated || cappedResponse.truncated
        return redacted
    }

    private func egress(_ saved: MCPSavedSession) -> MCPSavedSession {
        var result = saved
        result.session = egress(saved.session)
        return result
    }

    private func egress(_ paused: MCPPausedRequest) -> MCPPausedRequest {
        var redacted = redactor.redactPaused(paused)
        let capped = MCPSessionQuery.cappedPreview(redacted.bodyPreview)
        redacted.bodyPreview = capped.preview
        redacted.bodyTruncated = paused.bodyTruncated || capped.truncated
        return redacted
    }

    private func egress(_ saved: MCPSavedSessionSummary) -> MCPSavedSessionSummary {
        var result = saved
        result.session = redactor.redactSummary(saved.session)
        return result
    }

    /// The gate every mutation passes: the human (or a standing grant)
    /// decides, the seam performs, the log records whichever happened.
    private func performWrite<T: Encodable>(
        _ writes: MCPWriteSeams,
        _ action: MCPAgentAction,
        status: Int = 200,
        /// What the target looked like before this call. Captured by the caller
        /// BEFORE consent is asked, because by the time the human answers the
        /// row may already be gone, and a snapshot taken afterwards would
        /// record the damage rather than the thing to restore.
        previousState: MCPAuditSnapshot? = nil,
        /// What the call created, if it created something. Recorded as an id
        /// rather than left to be read back out of `detail`'s prose, so the
        /// undo that deletes it again does not depend on a log message's
        /// wording.
        created: ((T) -> MCPAuditTarget?)? = nil,
        /// Skips the per-call approval because the user granted this one in
        /// advance. Exactly one route passes true: answering a held request,
        /// where a panel could outlast the request it is about (consent may
        /// take 45s, the core releases at 60). The grant is a setting that
        /// ships off, the route checks it itself, and the audit row is written
        /// either way — so this is a different SHAPE of consent, not an
        /// absence of it.
        preauthorized: Bool = false,
        _ perform: () throws -> T,
        detail: (T) -> String
    ) -> Data {
        let askedAt = Date()
        // One policy for the whole write: the log's copies below are made
        // with the redactor this call started with, not with a setting the
        // user changed while the panel was up.
        let redactor = self.redactor
        // The panel gets the action as built — raw URLs and header values,
        // because that is what makes the human's decision informed. The LOG
        // gets `redactLogEntry`'s copy: it is persisted to UserDefaults and
        // can be exported to a file, so a captured `?access_token=…` in it
        // outlives the decision it was shown for. That holds for the result
        // line too, on every outcome: answering a held request records a
        // sentence quoting its URL (F15).
        let log = { (entry: MCPAuditEntry) in writes.audit.record(redactor.redactLogEntry(entry)) }
        switch preauthorized ? .allowed : writes.consent.authorize(action) {
        case .denied(let reason):
            log(MCPAuditEntry(action: action, outcome: .denied, detail: reason))
            return MCPHTTPResponse.error(status: 403, code: "consent_denied", message: "Not allowed: \(reason)")
        case .timedOut(let reason):
            log(MCPAuditEntry(action: action, outcome: .timedOut, detail: reason))
            return MCPHTTPResponse.error(status: 408, code: "consent_timeout", message: reason)
        case .allowed:
            break
        }
        // A decision given late still stands — but the agent that asked may
        // have stopped waiting and retried, so the log records that.
        let late = Date().timeIntervalSince(askedAt) >= MCPLimits.consentTimeout
        do {
            let result = try perform()
            log(MCPAuditEntry(
                action: action,
                outcome: .performed,
                detail: detail(result),
                lateDecision: late,
                previousState: previousState,
                created: created?(result)
            ))
            return MCPHTTPResponse.json(status: status, result)
        } catch let error as MCPWriteError {
            log(MCPAuditEntry(action: action, outcome: .failed, detail: error.message, lateDecision: late))
            return Self.response(for: error)
        } catch {
            log(MCPAuditEntry(action: action, outcome: .failed, detail: error.localizedDescription, lateDecision: late))
            return MCPHTTPResponse.error(status: 500, code: "internal_error", message: error.localizedDescription)
        }
    }

    static func response(for error: MCPWriteError) -> Data {
        switch error {
        case .invalid(let m): return MCPHTTPResponse.error(status: 400, code: "bad_request", message: m)
        case .notFound(let m): return MCPHTTPResponse.error(status: 404, code: "not_found", message: m)
        case .limitReached(let m): return MCPHTTPResponse.error(status: 403, code: "limit_reached", message: m)
        case .unavailable(let m): return MCPHTTPResponse.error(status: 503, code: "unavailable", message: m)
        case .failed(let m): return MCPHTTPResponse.error(status: 500, code: "internal_error", message: m)
        }
    }

    static func decodeBody<T: Decodable>(_ type: T.Type, from request: MCPHTTPRequest) throws -> T {
        guard !request.body.isEmpty else {
            throw MCPWriteError.invalid("A JSON body is required.")
        }
        return try JSONDecoder().decode(type, from: request.body)
    }

    static func pathId(_ path: String, prefix: String, what: String) throws -> Int64 {
        let raw = String(path.dropFirst(prefix.count))
        guard !raw.isEmpty, !raw.contains("/"), let id = Int64(raw) else {
            throw MCPWriteError.invalid("Malformed \(what) id '\(raw)'; ids are integers from list_\(what)s.")
        }
        return id
    }

    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "Missing required field '\(key.stringValue)'."
        case .typeMismatch(_, let context): return "Wrong type at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        case .valueNotFound(_, let context): return "Missing value at \(context.codingPath.map(\.stringValue).joined(separator: "."))."
        case .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "The body is not valid JSON." : "Invalid value at \(path): \(context.debugDescription)"
        @unknown default: return "The body could not be decoded."
        }
    }

    // MARK: - Describing actions for the human

    static func describe(_ draft: MCPRuleDraft, host: String?) -> String {
        let scope = host ?? "host #\(draft.hostId ?? 0)"
        let target = "\(RuleMethod.displayName(draft.method)) \(draft.path)"
        switch draft.mode {
        case .mapLocal:
            let source = draft.localFile?.path ?? "inline \(draft.localFile?.contentType ?? "content")"
            return "Create a map-local rule for \(scope): \(target) → \(source)"
        case .override, .extend:
            // "→ server's status" for a kept one, never "→ 0".
            let status = RuleResponseDefaults.statusText(
                draft.responseStatus, mode: draft.mode, hasBody: !(draft.responseBody ?? "").isEmpty
            ) ?? "\(draft.responseStatus)"
            return "Create \(draft.mode == .override ? "an override" : "an extend") rule for \(scope): \(target) → \(status)"
        }
    }

    static func describe(_ rule: MCPRule) -> String {
        "\(rule.mode.rawValue) \(RuleMethod.displayName(rule.method)) \(rule.path) on \(rule.host ?? "a host filter that no longer exists")"
    }

    // The gate exists for a prompt-injected agent, so the panel has to show
    // what a rule will actually inject — names alone hide the payload.
    static let detailValueLimit = 90
    static let detailBodyLimit = 200

    static func truncated(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\r", with: "")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    /// What an export is about to write, in the terms someone deciding cares
    /// about: whose traffic, and whether anything they asked for is missing.
    /// Not a list of every URL — a burst of 40 turns the panel into a wall
    /// nobody reads, which is how a bad one gets approved.
    static func exportDetails(_ details: [MCPSessionDetail], requested: Int) -> [String] {
        var lines: [String] = []
        let hosts = Array(Set(details.map { $0.summary.host })).sorted()
        lines.append(hosts.count <= 4
            ? "Hosts: \(hosts.joined(separator: ", "))"
            : "Hosts: \(hosts.prefix(4).joined(separator: ", ")) and \(hosts.count - 4) more")
        if details.count < requested {
            lines.append("\(requested - details.count) of the \(requested) requested sessions are no longer captured and will be skipped")
        }
        lines.append("Credential-shaped values are masked in the file; everything else is written as captured")
        return lines
    }

    /// What a save is about to write down.
    ///
    /// The URL arrives already through `MCPRedactor.redactURL`, which masks
    /// only credential-shaped QUERY VALUES — the host and path stay, so the
    /// human can still tell which request this is, and an `?access_token=…`
    /// does not. That is the same treatment `mock_from_session` gives its URL,
    /// and the consistency matters: this line is also what the persisted,
    /// exportable activity log keeps.
    ///
    /// The last line says the part nobody would guess: the STORED copy is not
    /// redacted, because a saved session full of placeholders would be useless
    /// for the debugging it was kept for.
    static func saveDetails(_ detail: MCPSessionDetail, note: String?, url: String) -> [String] {
        let summary = detail.summary
        var lines = ["\(summary.method.uppercased()) \(truncated(url, detailBodyLimit))"]
        if let status = summary.statusCode {
            lines.append("Response: \(status)")
        }
        if let note {
            lines.append("Note: \(truncated(note, detailValueLimit))")
        }
        lines.append("Kept exactly as captured — headers and bodies are stored unmasked. Agents reading it back still get redacted values.")
        return lines
    }

    static func deleteSavedDetails(_ saved: MCPSavedSession, url: String) -> [String] {
        var lines = [truncated(url, detailBodyLimit), "Saved \(savedAtFormatter.string(from: saved.savedAt))"]
        if let note = saved.note, !note.isEmpty {
            lines.append("Note: \(truncated(note, detailValueLimit))")
        }
        return lines
    }

    /// The panel is read by a person, so a saved-at date is written the way
    /// their Mac writes dates — ISO is for the tool output, not for this.
    static let savedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// "Name: value" per header, with credential-shaped names marked so the
    /// human sees when a rule is about to inject one.
    static func describeHeaders(_ headers: [String: String]) -> String {
        headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { name, value in
                let marker = MCPRedactor.isSensitiveName(name) ? " ⚠️" : ""
                return "\(name): \(truncated(value, detailValueLimit))\(marker)"
            }
            .joined(separator: " · ")
    }

    static func details(_ draft: MCPRuleDraft) -> [String] {
        var lines = ["Match: \(draft.matchType.rawValue) · \(draft.scheme)"]
        if !draft.requestHeaders.isEmpty {
            lines.append("Sets request headers — \(describeHeaders(draft.requestHeaders))")
        }
        if !draft.responseHeaders.isEmpty {
            lines.append("Sets response headers — \(describeHeaders(draft.responseHeaders))")
        }
        if let body = draft.responseBody {
            lines.append("Response body (\(body.utf8.count) bytes): \(truncated(body, detailBodyLimit))")
        }
        if let content = draft.localFile?.content {
            lines.append("File content (\(content.utf8.count) bytes): \(truncated(content, detailBodyLimit))")
        }
        if let path = draft.localFile?.path { lines.append("File: \(truncated(path, detailValueLimit * 2))") }
        if !draft.enabled { lines.append("Created disabled") }
        return lines
    }

    /// `current`, when given, is the rule before the patch: a change of mode
    /// that sends no response headers keeps the stored ones (update_rule
    /// never adds or drops one on its own), and the human is told which —
    /// an override's Content-Type kept on an extend rule relabels every real
    /// response on its path (F17) — and what the rule's Content-Type does
    /// once the patch lands (`contentTypeConsequence`). The status is kept
    /// the same way, and an override's status kept on an extend rule answers
    /// every response on the path with it (`statusConsequence`).
    static func details(_ patch: MCPRulePatch, current: MCPRule? = nil) -> [String] {
        var lines: [String] = []
        // Said beside what causes it: the headers sent, or else the mode.
        let consequence = current.flatMap { contentTypeConsequence(of: patch, on: $0) }
        if let enabled = patch.enabled { lines.append(enabled ? "Enable" : "Disable") }
        if let mode = patch.mode {
            lines.append("Mode → \(mode.rawValue)")
            if let current, mode != current.mode, patch.responseHeaders == nil, !current.responseHeaders.isEmpty {
                lines.append("Response headers kept — \(describeHeaders(current.responseHeaders))")
            }
            if patch.responseHeaders == nil, let consequence { lines.append(consequence) }
            if let status = current.flatMap({ statusConsequence(of: patch, on: $0) }) { lines.append(status) }
        }
        if let matchType = patch.matchType { lines.append("Match → \(matchType.rawValue)") }
        if let path = patch.path { lines.append("Path → \(truncated(path, detailValueLimit))") }
        if let method = patch.method { lines.append("Method → \(RuleMethod.displayName(method))") }
        if let scheme = patch.scheme { lines.append("Scheme → \(scheme)") }
        if let status = patch.responseStatus {
            // Read for the mode and body the rule will have: "server's
            // status" for a kept one, never "→ 0" — and no number at all for
            // a map_local rule, which uses none (this line is also what the
            // Activity log keeps).
            let mode = patch.mode ?? current?.mode
            let hasBody = !(patch.responseBody ?? current?.responseBody ?? "").isEmpty
            if mode == .mapLocal {
                lines.append("Status: not used — a map_local rule answers 200 with its file")
            } else {
                lines.append("Status → \(mode.flatMap { RuleResponseDefaults.statusText(status, mode: $0, hasBody: hasBody) } ?? "\(status)")")
            }
        }
        if let headers = patch.requestHeaders {
            lines.append(headers.isEmpty ? "Request headers → none" : "Request headers → \(describeHeaders(headers))")
        }
        if let headers = patch.responseHeaders {
            lines.append(headers.isEmpty ? "Response headers → none" : "Response headers → \(describeHeaders(headers))")
            if let consequence { lines.append(consequence) }
        }
        if let body = patch.responseBody {
            lines.append("Response body (\(body.utf8.count) bytes) → \(truncated(body, detailBodyLimit))")
        }
        if let file = patch.localFile {
            lines.append("File → \(file.path.map { truncated($0, detailValueLimit * 2) } ?? "inline content (\(file.content?.utf8.count ?? 0) bytes)")")
        }
        return lines
    }

    /// What the rule's Content-Type does once `patch` lands on `current`,
    /// when the patch decides it and a person reading "Mode → …" would not
    /// see it (F17), or nil.
    ///
    /// update_rule keeps the stored response headers unless it is sent some
    /// — a change of mode included — so, unlike the override form, it never
    /// adds the JSON default to a rule becoming an override, or drops it from
    /// one that stops being one:
    /// - an override (made one, or given new headers) without a Content-Type
    ///   answers with none: its response carries the rule's headers only,
    ///   the server's Content-Type dropped whether it answers with a body or
    ///   forwards the server's;
    /// - a Content-Type kept onto an extend rule labels every real response
    ///   the rule matches with it;
    /// - one kept onto a map_local rule is sent in place of the file's own.
    static func contentTypeConsequence(of patch: MCPRulePatch, on current: MCPRule) -> String? {
        let mode = patch.mode ?? current.mode
        let changesMode = patch.mode.map { $0 != current.mode } ?? false
        guard changesMode || patch.responseHeaders != nil else { return nil }
        let headers = patch.responseHeaders ?? current.responseHeaders
        let contentType = headers.first {
            $0.key.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(RuleResponseDefaults.contentTypeName) == .orderedSame
        }?.value
        switch (mode, contentType) {
        case (.override, nil):
            return "No Content-Type — an override's response carries the rule's headers only, so it goes out without one"
        case (.extend, let contentType?) where changesMode && patch.responseHeaders == nil:
            return "Content-Type kept: every response the rule matches is labelled \(truncated(contentType, detailValueLimit))"
        case (.mapLocal, let contentType?) where changesMode && patch.responseHeaders == nil:
            return "Content-Type kept: the file is sent as \(truncated(contentType, detailValueLimit)), not as its own type"
        default:
            return nil
        }
    }

    /// What the rule's status does once `patch` makes `current` an extend
    /// rule without sending one, or nil.
    ///
    /// update_rule keeps a stored status through a change of mode, as it
    /// keeps the headers — unlike the override form, where an override's
    /// untouched 200 becomes "Keep server's status" on the way to Extend. So
    /// an override's status kept on an extend rule answers EVERY response the
    /// rule matches with it, a 404 or a 500 from the server included (F17).
    /// A status the core does not answer with is the server's kept, and says
    /// nothing; the other modes need no line (an override answering with its
    /// own status is what an override does, and map_local uses none). A
    /// map_local rule's own status is not kept: the validated patch carries
    /// extend's start, read as "Status → server's status"
    /// (`MCPWriteValidation.validate(_:currentMode:…)`). Nor is one re-sent
    /// to the mode the rule already has: nothing about its status changes.
    static func statusConsequence(of patch: MCPRulePatch, on current: MCPRule) -> String? {
        guard patch.mode == .extend, current.mode != .extend, patch.responseStatus == nil,
              RuleResponseDefaults.answeringStatuses.contains(current.responseStatus) else { return nil }
        return "Status kept: every response the rule matches comes back as \(current.responseStatus), in place of the server's"
    }

    private func authorized(_ request: MCPHTTPRequest) -> Bool {
        guard let value = request.headers["authorization"] else { return false }
        let prefix = "bearer "
        guard value.lowercased().hasPrefix(prefix) else { return false }
        let presented = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return Self.constantTimeEquals(presented, token)
    }

    static func isLoopbackHostHeader(_ host: String) -> Bool {
        let name = host.split(separator: ":").first.map(String.init)?.lowercased() ?? host.lowercased()
        return name == "127.0.0.1" || name == "localhost" || name == "[::1]" || name == "::1"
    }

    static func isAllowedOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else {
            // "null" and unparseable origins are treated as hostile.
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }
}
