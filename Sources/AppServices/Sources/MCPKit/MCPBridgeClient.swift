//
//  MCPBridgeClient.swift
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

import Darwin
import Foundation

/// Client side of the bridge, used by the stdio `reqres-mcp` binary the MCP
/// client spawns. Discovers the running app through the handshake file, then
/// talks HTTP to its loopback listener.
public struct MCPBridgeClient {
    public enum ClientError: LocalizedError, Equatable {
        case appNotRunning(path: String)
        case unauthorized
        case badResponse(status: Int, message: String)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .appNotRunning(let path):
                return "Cannot reach ReqRes: either it is not running, or its AI bridge is off. Open ReqRes → Settings → MCP and turn on \"Enable the AI bridge\", then retry. (No handshake at \(path).)"
            case .unauthorized:
                return "The bridge rejected this token. Restart ReqRes to mint a fresh handshake."
            case .badResponse(let status, let message):
                return "Bridge returned \(status): \(message)"
            case .transport(let detail):
                return "Could not reach the ReqRes bridge: \(detail)"
            }
        }
    }

    private let handshake: MCPHandshake
    private let session: URLSession

    /// Sent on every request so the app can show who is using the bridge.
    /// Nil in tests and for callers that would rather stay anonymous.
    private let identity: String?

    public init(
        handshake: MCPHandshake,
        session: URLSession = .shared,
        identity: String? = nil
    ) {
        self.handshake = handshake
        self.session = session
        self.identity = identity
    }

    /// Loads the handshake written by the running app.
    public static func loadHandshake(at url: URL) throws -> MCPHandshake {
        do {
            return try MCPHandshakeFile.read(from: url)
        } catch {
            throw ClientError.appNotRunning(path: url.path)
        }
    }

    /// The app-group container is the documented location; the app's own
    /// container is the fallback when the group is unavailable.
    ///
    /// The bundled helper runs SANDBOXED as an app-group member, and inside
    /// its sandbox `homeDirectoryForCurrentUser` is its OWN container — a
    /// home-based path would point at ~/Library/Containers/…mcp/Data/Library/
    /// Group Containers (measured 2026-09-17). The system-resolved group
    /// container comes first; the home-based paths serve unsandboxed runs.
    public static func defaultHandshakeURLs(appGroupIdentifier: String, bundleIdentifier: String) -> [URL] {
        var urls: [URL] = []
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            urls.append(group.appendingPathComponent("MCP/\(MCPHandshakeFile.fileName)"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent("Library/Group Containers/\(appGroupIdentifier)/MCP/\(MCPHandshakeFile.fileName)"))
        urls.append(home.appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/Library/Application Support/MCP/\(MCPHandshakeFile.fileName)"))
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func locateHandshake(in candidates: [URL]) throws -> MCPHandshake {
        for url in candidates {
            if let handshake = try? MCPHandshakeFile.read(from: url) {
                return handshake
            }
        }
        throw ClientError.appNotRunning(path: candidates.first?.path ?? "~/Library/Group Containers")
    }

    public func url(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(handshake.port)
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        // Components are all machine-built; a nil here would be a programming error.
        return components.url!
    }

    public func request(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: url(path: path, query: query))
        request.httpMethod = "GET"
        request.setValue("Bearer \(handshake.token)", forHTTPHeaderField: "Authorization")
        if let identity { request.setValue(identity, forHTTPHeaderField: MCPClientRegistry.headerName) }
        request.timeoutInterval = 15
        return request
    }

    /// How this process identifies itself to the bridge, so the app can show
    /// the user who is talking to it.
    ///
    /// The name is the PARENT process: the helper is spawned by the MCP client,
    /// so the parent is Claude Code, Cursor or whatever launched it. That is the
    /// name a user recognises, and it needs no cooperation from the MCP SDK,
    /// which keeps `clientInfo` private.
    ///
    /// `ppid` is that parent's process id (UX spec §8.1). Per-process
    /// attribution puts a pid on every captured session, so the app can mark
    /// the requests a connected agent itself makes — a CLI agent's traffic
    /// carries exactly this pid — and offer "Show its traffic" for it. The
    /// app trusts none of this before the bearer check: the header is parsed
    /// only for an authenticated request.
    public static func identityHeader(
        version: String,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        parentName: String? = parentProcessName(),
        parentPID: Int32 = getppid()
    ) -> String {
        let name = parentName?.isEmpty == false ? parentName! : "MCP client"
        return "name=\(name); id=\(pid); version=\(version); ppid=\(parentPID)"
    }

    /// The parent's display name, or nil when its path cannot be read. Best
    /// effort by design: an unnamed client simply is not listed.
    ///
    /// Named by `ProcessIdentity`, the ONE rule the App column and the `app:`
    /// token use as well — so Cursor is "Cursor" in the sidebar footer and in
    /// the table, and a Chromium-style helper is its outermost bundle in both.
    public static func parentProcessName() -> String? {
        var buffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        guard !path.isEmpty else { return nil }
        return ProcessIdentity(name: nil, pid: nil, executablePath: path).displayName
    }


    /// Maps a bridge response onto a typed result, translating the JSON error
    /// envelope into a readable message for the agent.
    public static func decode<T: Decodable>(_ type: T.Type, data: Data, status: Int) throws -> T {
        guard status != 401 else { throw ClientError.unauthorized }
        guard (200..<300).contains(status) else {
            throw ClientError.badResponse(status: status, message: errorMessage(from: data) ?? "unexpected status")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ClientError.transport("could not decode bridge response: \(error.localizedDescription)")
        }
    }

    /// The bridge's error code AND message. The code is what the tool
    /// descriptions promise an agent ("fails with consent_denied"), and what
    /// tells it whether retrying is pointless.
    static func errorMessage(from data: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                let code: String
                let message: String
            }
            let error: Inner
        }
        guard let error = (try? JSONDecoder().decode(Envelope.self, from: data))?.error else { return nil }
        switch error.code {
        case "consent_denied":
            return "consent_denied — \(error.message) Do not retry unless the user asks you to."
        case "consent_timeout":
            return "consent_timeout — \(error.message) Ask the user to answer the ReqRes approval panel, then try again."
        case "limit_reached":
            return "limit_reached — \(error.message)"
        default:
            return "\(error.code) — \(error.message)"
        }
    }

    /// A write: JSON body, and long enough to cover the human's approval
    /// (`MCPLimits.consentTimeout`) plus the round trip.
    public static let writeTimeout: TimeInterval = MCPLimits.consentTimeout + 20

    /// A breakpoint decision. Short on purpose: nothing blocks behind it (the
    /// grant is a setting, not a panel) and the request it answers is released
    /// by the core within the minute anyway, so a long wait here could only
    /// outlive the thing it was waiting for.
    public static let decisionTimeout: TimeInterval = 15

    /// `timeout` overrides the write timeout for the one route that waits on
    /// something slower than a human: a replay also holds a real network
    /// round trip open inside the same call.
    public func writeRequest<B: Encodable>(method: String, path: String, body: B?, timeout: TimeInterval? = nil) throws -> URLRequest {
        var request = URLRequest(url: url(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(handshake.token)", forHTTPHeaderField: "Authorization")
        if let identity { request.setValue(identity, forHTTPHeaderField: MCPClientRegistry.headerName) }
        request.timeoutInterval = timeout ?? Self.writeTimeout
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public func send<T: Decodable, B: Encodable>(_ type: T.Type, method: String, path: String, body: B?, timeout: TimeInterval? = nil) async throws -> T {
        let request: URLRequest
        do {
            request = try writeRequest(method: method, path: path, body: body, timeout: timeout)
        } catch {
            throw ClientError.transport("could not encode request: \(error.localizedDescription)")
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return try Self.decode(type, data: data, status: status)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
    }

    private struct NoBody: Encodable {}

    public func send<T: Decodable>(_ type: T.Type, method: String, path: String) async throws -> T {
        try await send(type, method: method, path: path, body: NoBody?.none)
    }

    // MARK: Write surface

    public struct HostsEnvelope: Decodable { public let hosts: [MCPHost] }
    public struct RulesEnvelope: Decodable { public let rules: [MCPRule] }

    public func hosts() async throws -> [MCPHost] {
        try await fetch(HostsEnvelope.self, path: "/v1/hosts").hosts
    }

    public func addHost(_ draft: MCPHostDraft) async throws -> MCPHost {
        try await send(MCPHost.self, method: "POST", path: "/v1/hosts", body: draft)
    }

    public func removeHost(id: Int64) async throws -> MCPDeleted {
        try await send(MCPDeleted.self, method: "DELETE", path: "/v1/hosts/\(id)")
    }

    public func rules(hostId: Int64? = nil) async throws -> [MCPRule] {
        let query = hostId.map { [URLQueryItem(name: "host_id", value: String($0))] } ?? []
        return try await fetch(RulesEnvelope.self, path: "/v1/rules", query: query).rules
    }

    public func createRule(_ draft: MCPRuleDraft) async throws -> MCPRule {
        try await send(MCPRule.self, method: "POST", path: "/v1/rules", body: draft)
    }

    public func updateRule(id: Int64, patch: MCPRulePatch) async throws -> MCPRule {
        try await send(MCPRule.self, method: "PATCH", path: "/v1/rules/\(id)", body: patch)
    }

    public func deleteRule(id: Int64) async throws -> MCPDeleted {
        try await send(MCPDeleted.self, method: "DELETE", path: "/v1/rules/\(id)")
    }

    public func mockFromSession(_ request: MCPMockFromSessionRequest) async throws -> MCPRule {
        try await send(MCPRule.self, method: "POST", path: "/v1/rules/from-session", body: request)
    }

    public func capture(_ command: MCPCaptureCommand) async throws -> MCPBridgeStatus {
        try await send(MCPBridgeStatus.self, method: "POST", path: "/v1/capture", body: MCPCaptureRequest(action: command))
    }

    public func diagnose() async throws -> MCPSetupReport {
        try await fetch(MCPSetupReport.self, path: "/v1/diagnose")
    }

    public func clearSessions() async throws -> MCPCleared {
        try await send(MCPCleared.self, method: "POST", path: "/v1/sessions/clear")
    }

    /// Writes a HAR file. Goes through `send`, so it inherits the write
    /// timeout — the human is asked before this returns.
    public func exportSessions(_ request: MCPExportRequest) async throws -> MCPExportResult {
        try await send(MCPExportResult.self, method: "POST", path: "/v1/sessions/export", body: request)
    }

    // MARK: Saved sessions

    /// Reads: no consent, so these go through `fetch` rather than `send` and
    /// return as fast as any other read.
    public func savedSessions(limit: Int? = nil) async throws -> MCPSavedSessionPage {
        let query = limit.map { [URLQueryItem(name: "limit", value: String($0))] } ?? []
        return try await fetch(MCPSavedSessionPage.self, path: "/v1/saved-sessions", query: query)
    }

    public func savedSession(id: Int64) async throws -> MCPSavedSession {
        try await fetch(MCPSavedSession.self, path: "/v1/saved-sessions/\(id)")
    }

    /// Writes: through `send`, so they inherit the write timeout — the human
    /// is asked before either returns.
    public func saveSession(_ request: MCPSaveSessionRequest) async throws -> MCPSavedSessionSummary {
        try await send(MCPSavedSessionSummary.self, method: "POST", path: "/v1/saved-sessions", body: request)
    }

    public func deleteSavedSession(id: Int64) async throws -> MCPDeleted {
        try await send(MCPDeleted.self, method: "DELETE", path: "/v1/saved-sessions/\(id)")
    }

    // MARK: Replay

    /// Sends a captured request again. Budgeted for both waits it contains:
    /// the human's approval (which a standing grant never skips for this one)
    /// and the replay itself on the wire.
    public func replay(_ request: MCPReplayRequest) async throws -> MCPReplayResult {
        try await send(
            MCPReplayResult.self,
            method: "POST",
            path: "/v1/sessions/replay",
            body: request,
            timeout: Self.writeTimeout + MCPReplayLimits.timeout
        )
    }

    // MARK: Breakpoints

    /// What is held right now. A plain read — no consent, no waiting.
    public func pausedRequests() async throws -> MCPPausedRequestPage {
        try await fetch(MCPPausedRequestPage.self, path: "/v1/breakpoints/paused")
    }

    /// Answers one held request.
    ///
    /// Sent with the READ timeout, not the write one. Every other write waits
    /// for a human to answer a panel; this one is pre-authorised by a setting,
    /// so nothing blocks behind it — and the request it decides is released by
    /// the core within the minute regardless, so a long client-side wait here
    /// could only outlive the thing it was waiting for.
    public func decideBreakpoint(_ decision: MCPBreakpointDecision) async throws -> MCPBreakpointOutcome {
        try await send(
            MCPBreakpointOutcome.self,
            method: "POST",
            path: "/v1/breakpoints/decide",
            body: decision,
            timeout: Self.decisionTimeout
        )
    }

    /// `exclude_host` (PRD 3.5): consent-gated like every write.
    public func excludeHost(_ request: MCPExcludeHostRequest) async throws -> MCPExclusionResult {
        try await send(MCPExclusionResult.self, method: "POST", path: "/v1/exclusions", body: request)
    }

    public func testPattern(_ request: MCPPatternTestRequest) async throws -> MCPPatternTestResult {
        try await send(MCPPatternTestResult.self, method: "POST", path: "/v1/patterns/test", body: request)
    }

    public func fetch<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        let request = self.request(path: path, query: query)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return try Self.decode(type, data: data, status: status)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
    }

    public func status() async throws -> MCPBridgeStatus {
        try await fetch(MCPBridgeStatus.self, path: "/v1/status")
    }

    public func sessions(filter: MCPSessionFilter = MCPSessionFilter(), limit: Int? = nil, cursor: String? = nil) async throws -> MCPSessionPage {
        try await fetch(MCPSessionPage.self, path: "/v1/sessions", query: Self.sessionsQuery(filter: filter, limit: limit, cursor: cursor))
    }

    /// The query string `/v1/sessions` is asked with. Every filter field has
    /// to be serialised here or the router never sees it and the agent gets an
    /// unfiltered page believing it is filtered — the same failure as a tool
    /// advertising a filter the model lacks, one layer down. The names are the
    /// ones `MCPSessionFilter.init(queryItems:)` reads.
    static func sessionsQuery(filter: MCPSessionFilter, limit: Int?, cursor: String?) -> [URLQueryItem] {
        var query: [URLQueryItem] = []
        if let host = filter.host { query.append(URLQueryItem(name: "host", value: host)) }
        if let method = filter.method { query.append(URLQueryItem(name: "method", value: method)) }
        if let status = filter.status { query.append(URLQueryItem(name: "status", value: status)) }
        if let scheme = filter.scheme { query.append(URLQueryItem(name: "scheme", value: scheme)) }
        if let urlContains = filter.urlContains { query.append(URLQueryItem(name: "url_contains", value: urlContains)) }
        if let app = filter.app { query.append(URLQueryItem(name: "app", value: app)) }
        if let pid = filter.pid { query.append(URLQueryItem(name: "pid", value: String(pid))) }
        if let country = filter.country { query.append(URLQueryItem(name: "country", value: country)) }
        if let outcome = filter.outcome { query.append(URLQueryItem(name: "outcome", value: outcome)) }
        if let grpc = filter.grpc { query.append(URLQueryItem(name: "grpc", value: grpc)) }
        if let proto = filter.proto { query.append(URLQueryItem(name: "proto", value: proto)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return query
    }

    /// Where the sessions matching `filter` went, by destination
    /// (destination-map UX spec §8.3). The same query string as `sessions`,
    /// minus paging — the report is one page by construction.
    public func destinations(filter: MCPSessionFilter = MCPSessionFilter()) async throws -> MCPDestinationsReport {
        try await fetch(MCPDestinationsReport.self, path: "/v1/destinations", query: Self.sessionsQuery(filter: filter, limit: nil, cursor: nil))
    }

    public func session(uid: String) async throws -> MCPSessionDetail {
        try await fetch(MCPSessionDetail.self, path: "/v1/sessions/\(uid)")
    }

    /// `get_session view=events`: one page of the response stream's
    /// complete events, redacted per event. `from` is 1-based.
    public func sessionEvents(uid: String, from: Int? = nil, limit: Int? = nil) async throws -> MCPStreamEventsPage {
        var query: [URLQueryItem] = []
        if let from { query.append(URLQueryItem(name: "from", value: String(from))) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await fetch(MCPStreamEventsPage.self, path: "/v1/sessions/\(uid)/events", query: query)
    }

    /// `list_messages`: one WebSocket connection's kept messages, redacted,
    /// oldest first (protocol-engine doc §S7).
    public func messages(uid: String, filter: MCPMessageFilter = MCPMessageFilter(), cursor: String? = nil, limit: Int? = nil) async throws -> MCPSocketMessagePage {
        var query = filter.queryItems.filter { $0.name != "uid" }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await fetch(MCPSocketMessagePage.self, path: "/v1/sessions/\(uid)/messages", query: query)
    }

    /// One poll of the message feed: nil asks only for the newest ordinal.
    public func messageFeed(since: Int64?, filter: MCPMessageFilter) async throws -> MCPSocketFeed {
        var query = filter.queryItems
        if let since { query.append(URLQueryItem(name: "since", value: String(since))) }
        return try await fetch(MCPSocketFeed.self, path: "/v1/messages", query: query)
    }

    /// `wait_for_message`: the first matching message that arrives after the
    /// call. Polled here, so the bridge stays synchronous.
    public func waitForMessage(filter: MCPMessageFilter, timeout: TimeInterval = MCPMessageWaiter.defaultTimeout) async throws -> MCPMessageWaiter.Outcome {
        try await MCPMessageWaiter.wait(
            timeout: timeout,
            fetch: { try await self.messageFeed(since: $0, filter: filter) },
            elapsed: MCPSessionWaiter.monotonicElapsed(),
            sleep: MCPSessionWaiter.taskSleep
        )
    }

    /// `get_session view=rpc`: a gRPC-Web / Connect / gRPC row's messages
    /// and status, redacted (protocol-engine doc §S8).
    public func sessionRPC(uid: String, from: Int? = nil, limit: Int? = nil) async throws -> MCPRPCView {
        var query: [URLQueryItem] = []
        if let from { query.append(URLQueryItem(name: "from", value: String(from))) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await fetch(MCPRPCView.self, path: "/v1/sessions/\(uid)/rpc", query: query)
    }

    /// `get_session view=assembled`: the LLM answer put back together.
    public func sessionAssembled(uid: String) async throws -> MCPStreamAssembled {
        try await fetch(MCPStreamAssembled.self, path: "/v1/sessions/\(uid)/assembled")
    }

    public func body(
        uid: String,
        side: MCPBodySide = .response,
        mode: MCPJSONQuery.Mode = .structure,
        path: String? = nil
    ) async throws -> MCPBodyQueryResult {
        var query = [
            URLQueryItem(name: "side", value: side.rawValue),
            URLQueryItem(name: "mode", value: mode.rawValue),
        ]
        if let path, !path.isEmpty {
            query.append(URLQueryItem(name: "path", value: path))
        }
        return try await fetch(MCPBodyQueryResult.self, path: "/v1/sessions/\(uid)/body", query: query)
    }

    /// Every in-flight row plus the named ones, wherever they sit in the list
    /// (`MCPWatchedRows`); newest first.
    public func watchedSessions(uids: Set<String>) async throws -> [MCPSessionSummary] {
        let query = [URLQueryItem(name: "uids", value: uids.sorted().joined(separator: ","))]
        do {
            return try await fetch(MCPSessionPage.self, path: "/v1/sessions/watched", query: query).sessions
        } catch ClientError.badResponse(status: 404, _) {
            // A bridge from before live rows: it finalizes nothing in place,
            // so the newest page is all a wait needs.
            return []
        }
    }

    /// Waits for the next NEW session matching `filter`, polling the bridge.
    public func waitForSession(
        filter: MCPSessionFilter,
        includeFailed: Bool = false,
        until stage: MCPWaitStage = .complete,
        timeout: TimeInterval = MCPSessionWaiter.defaultTimeout
    ) async throws -> MCPSessionWaiter.Outcome {
        let elapsed = MCPSessionWaiter.monotonicElapsed()
        return try await MCPSessionWaiter.wait(
            filter: filter,
            includeFailed: includeFailed,
            until: stage,
            timeout: timeout,
            fetch: { try await self.sessions(limit: MCPLimits.maxPageSize).sessions },
            watch: { try await self.watchedSessions(uids: $0) },
            elapsed: elapsed,
            sleep: MCPSessionWaiter.taskSleep
        )
    }

    /// Collects several matching requests instead of returning on the first.
    ///
    /// Polls client-side for the same reason the single wait does: the bridge
    /// stays synchronous, so a long wait never holds a request open on the
    /// app's side.
    public func waitForSessions(
        filter: MCPSessionFilter,
        includeFailed: Bool = false,
        maxCount: Int = MCPSessionCollector.defaultMaxCount,
        timeout: TimeInterval = MCPSessionCollector.defaultTimeout,
        settleInterval: TimeInterval = MCPSessionCollector.defaultSettleInterval
    ) async throws -> MCPSessionCollector.Outcome {
        let elapsed = MCPSessionWaiter.monotonicElapsed()
        return try await MCPSessionCollector.collect(
            filter: filter,
            includeFailed: includeFailed,
            maxCount: maxCount,
            timeout: timeout,
            settleInterval: settleInterval,
            fetch: { try await self.sessions(limit: MCPLimits.maxPageSize).sessions },
            watch: { try await self.watchedSessions(uids: $0) },
            elapsed: elapsed,
            sleep: MCPSessionWaiter.taskSleep
        )
    }

    /// Fetches both sides of a comparison and returns the delta.
    ///
    /// Fetched in parallel: two round trips run back to back doubled the
    /// latency of what an agent experiences as one question.
    public func diffSessions(_ uidA: String, _ uidB: String) async throws -> MCPSessionDiff {
        async let a = session(uid: uidA)
        async let b = session(uid: uidB)
        // Both sides arrive already redacted from the bridge, and the diff
        // redacts again rather than trusting that, because a comparison that
        // reported "this value changed" across a masked field would leak the
        // fact of the difference even when the values are hidden.
        return MCPSessionDiff.diff(try await a, try await b)
    }
}
