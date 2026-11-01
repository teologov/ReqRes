//
//  MCPWriteAdapters.swift
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
//  RR-MCP-2: the app side of the write seams. Rules and hosts go through
//  the same core bridge calls the forms use (ReqResCoreModelBridge) and
//  refresh the same state, so an agent's rule is indistinguishable from one
//  made by hand — including the free-tier limits.
//
//  The seams are synchronous and run on the bridge's queue; the core is
//  async and the UI state is main-thread, so each call bridges the two with
//  a blocking wait. Never call these on the main thread.
//

import Foundation
import Utils
import MCPKit
import NetworkExtension
import UniformTypeIdentifiers
import XReqResCore

// MARK: - Sync bridge

enum MCPSync {
    /// Runs an async operation and blocks until it completes. Safe here only
    /// because the bridge queue never runs on main and main never waits on it.
    static func wait<T>(_ operation: @escaping () async throws -> T) throws -> T {
        precondition(!Thread.isMainThread, "MCPSync.wait must not block the main thread")
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error>?
        Task {
            do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome!.get()
    }

    static func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
}

// MARK: - Free-tier limits (the same the forms enforce)

enum MCPFreeTier {
    // The agent obeys the same limits as the forms, from the same constants —
    // two numbers that drifted apart would mean the bridge and the window
    // disagreed about what the user had paid for.
    static let hostFilters = FreeTier.hostFilters
    static let rules = FreeTier.overrideRules

    static var isPro: Bool { MCPSync.onMain { LicenseManager.shared.isProUser() } }
}

// MARK: - Hosts

struct MCPHostAdapter: MCPHostProviding {
    /// From the store, not the sidebar's in-memory list — the bridge can be
    /// asked before bootstrap has loaded it.
    func hosts() throws -> [MCPHost] {
        do {
            return try MCPSync.wait { try await ReqResCoreModelBridge.findAllHosts() }.compactMap(Self.mcpHost)
        } catch {
            throw MCPWriteError.failed("Could not read hosts: \(error.localizedDescription)")
        }
    }

    func addHost(_ draft: MCPHostDraft) throws -> MCPHost {
        let existing = try MCPSync.wait { try await ReqResCoreModelBridge.findAllHosts() }
        if existing.contains(where: { $0.host.caseInsensitiveCompare(draft.host) == .orderedSame }) {
            throw MCPWriteError.invalid("\(draft.host) is already a host filter.")
        }
        if !MCPFreeTier.isPro, existing.count >= MCPFreeTier.hostFilters {
            throw MCPWriteError.limitReached("The free version includes \(MCPFreeTier.hostFilters) host filters; remove one, or upgrade ReqRes for unlimited filters.")
        }
        let saved: HostCodable
        do {
            saved = try MCPSync.wait {
                try await ReqResCoreModelBridge.saveHost(HostCodable(
                    host: draft.host,
                    // The app's own form stores 80 for every host; keep parity unless the agent says otherwise.
                    port: NSNumber(value: draft.port ?? 80),
                    hostDbId: nil,
                    requestProtocol: draft.scheme.uppercased()
                ))
            }
        } catch {
            throw MCPWriteError.failed("Could not save the host: \(error.localizedDescription)")
        }
        // `saveHost` hands back the input without its database id (the form
        // appends that id-less copy to the sidebar, which is why a fresh host
        // could not be resolved until a reload); re-read the row.
        let all = (try? MCPSync.wait { try await ReqResCoreModelBridge.findAllHosts() }) ?? existing + [saved]
        let stored = all.first { $0.host.caseInsensitiveCompare(draft.host) == .orderedSame && ($0.hostDbId?.int64Value ?? 0) != 0 } ?? saved
        MCPSync.onMain {
            AppState.shared.hosts.append(stored)
            AppController.shared.notifyExtension(message: ServerBusMessage(action: .allHostsChanged, payload: ["data": all]))
        }
        guard let host = Self.mcpHost(stored) else {
            throw MCPWriteError.failed("The host was saved but could not be read back with an id.")
        }
        return host
    }

    func removeHost(id: Int64) throws {
        let stored = try MCPSync.wait { try await ReqResCoreModelBridge.findAllHosts() }
        guard let host = stored.first(where: { $0.hostDbId?.int64Value == id }) else {
            throw MCPWriteError.notFound("No host filter with id \(id). Use list_hosts to see the current ids.")
        }
        // The core cascades the host's rules; their fixtures are ours to clean.
        let orphanedFixtures = ((try? MCPSync.wait { try await ReqResCoreModelBridge.findRulesByHost(id: id) }) ?? [])
            .filter { $0.ruleMode == .MAP_LOCAL }
            .map(\.rspPath)
        do {
            try MCPSync.wait { try await ReqResCoreModelBridge.deleteHost(id) }
        } catch {
            throw MCPWriteError.failed("Could not remove the host: \(error.localizedDescription)")
        }
        orphanedFixtures.forEach(MCPRuleAdapter.discardFixture)
        let all = (try? MCPSync.wait { try await ReqResCoreModelBridge.findAllHosts() }) ?? []
        MCPSync.onMain {
            AppState.shared.hosts.removeAll { $0.hostDbId == host.hostDbId }
            if AppState.shared.selectedHost?.hostDbId == host.hostDbId {
                AppState.shared.selectedHost = AppState.shared.hosts.first
            }
            AppController.shared.notifyExtension(message: ServerBusMessage(action: .allHostsChanged, payload: ["data": all]))
        }
        try? MCPSync.wait { await AppState.shared.reloadRulesAfterExternalChange() }
    }

    static func mcpHost(_ host: HostCodable) -> MCPHost? {
        guard let id = host.hostDbId?.int64Value, id != 0 else { return nil }
        return MCPHost(id: id, host: host.host, scheme: host.requestProtocol.lowercased(), port: host.port.intValue)
    }
}

// MARK: - Rules

struct MCPRuleAdapter: MCPRuleProviding {
    /// Where inline map_local content is written: inside the app's own
    /// container, which the sandbox lets the app read back at match time.
    static func fixturesDirectory() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("MCP Fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func rules() throws -> [MCPRule] {
        let (stored, hosts) = try loadRulesAndHosts()
        return stored.compactMap { Self.mcpRule($0, hosts: hosts) }
    }

    func createRule(_ draft: MCPRuleDraft) throws -> MCPRule {
        let (existing, hosts) = try loadRulesAndHosts()
        if !MCPFreeTier.isPro, existing.count >= MCPFreeTier.rules {
            throw MCPWriteError.limitReached("The free version includes \(MCPFreeTier.rules) override; delete it first, or upgrade ReqRes for unlimited overrides.")
        }
        // `host_rules.hostId` is a foreign key; "All traffic" is virtual and
        // has no row, so a rule can only be scoped to a real host filter.
        guard let hostId = draft.hostId, hostId > 0 else {
            throw MCPWriteError.invalid("hostId is required: a host id from list_hosts (add_host creates one).")
        }
        guard hosts.contains(where: { $0.hostDbId?.int64Value == hostId }) else {
            throw MCPWriteError.notFound("No host filter with id \(hostId). Use list_hosts to see the current ids.")
        }
        // Written before the save so the path can be stored; removed again if
        // the save fails, so a rejected call leaves nothing behind.
        let localPath = try draft.localFile.map(Self.materialize)
        let rule = RuleCodable(
            id: UUID(),
            path: draft.path,
            hostId: NSNumber(value: hostId),
            enabled: NSNumber(value: draft.enabled),
            isRegexp: NSNumber(value: draft.matchType == .regex),
            isWildCard: NSNumber(value: draft.matchType == .wildcard),
            ruleMode: Self.coreMode(draft.mode),
            reqProtocol: draft.scheme.uppercased(),
            reqMethod: draft.method,
            reqHeaders: Self.encodeHeaders(draft.requestHeaders),
            rspHeaders: Self.encodeHeaders(draft.responseHeaders),
            rspCode: NSNumber(value: draft.responseStatus),
            rspBody: draft.mode == .mapLocal ? "" : (draft.responseBody ?? ""),
            rspPath: localPath ?? "",
            modelRealId: nil
        )
        do {
            return try save(rule, hosts: hosts)
        } catch {
            if draft.localFile?.content != nil { Self.discardFixture(at: localPath) }
            throw error
        }
    }

    func updateRule(id: Int64, patch: MCPRulePatch) throws -> MCPRule {
        let (existing, hosts) = try loadRulesAndHosts()
        guard var rule = existing.first(where: { $0.modelRealId == id }) else {
            throw MCPWriteError.notFound("No rule with id \(id). Use list_rules to see the current ids.")
        }
        if let enabled = patch.enabled { rule.enabled = NSNumber(value: enabled) }
        if let mode = patch.mode { rule.ruleMode = Self.coreMode(mode) }
        if let matchType = patch.matchType {
            rule.isRegexp = NSNumber(value: matchType == .regex)
            rule.isWildCard = NSNumber(value: matchType == .wildcard)
        }
        if let path = patch.path { rule.path = path }
        if let method = patch.method { rule.reqMethod = method }
        if let scheme = patch.scheme { rule.reqProtocol = scheme.uppercased() }
        if let headers = patch.requestHeaders { rule.reqHeaders = Self.encodeHeaders(headers) }
        if let status = patch.responseStatus { rule.rspCode = NSNumber(value: status) }
        if let headers = patch.responseHeaders { rule.rspHeaders = Self.encodeHeaders(headers) }
        if let body = patch.responseBody { rule.rspBody = body }
        let previousPath = rule.rspPath
        if let file = patch.localFile { rule.rspPath = try Self.materialize(file) }
        if rule.ruleMode == .MAP_LOCAL {
            guard !rule.rspPath.isEmpty else {
                throw MCPWriteError.invalid("A map_local rule needs a localFile.")
            }
            // A map_local rule answers with its file; a stale body would be
            // shown by list_rules and restored if the mode changed back.
            rule.rspBody = ""
        } else {
            rule.rspPath = ""
        }
        let updated = try save(rule, hosts: hosts)
        // The fixture the rule no longer points at is ours to remove.
        if previousPath != rule.rspPath { Self.discardFixture(at: previousPath) }
        return updated
    }

    func deleteRule(id: Int64) throws {
        let (existing, _) = try loadRulesAndHosts()
        guard let rule = existing.first(where: { $0.modelRealId == id }) else {
            throw MCPWriteError.notFound("No rule with id \(id). Use list_rules to see the current ids.")
        }
        do {
            try MCPSync.wait { try await ReqResCoreModelBridge.deleteRule(id) }
        } catch {
            throw MCPWriteError.failed("Could not delete the rule: \(error.localizedDescription)")
        }
        Self.discardFixture(at: rule.rspPath)
        try MCPSync.wait { await AppState.shared.reloadRulesAfterExternalChange() }
    }

    /// Snapshot a captured exchange into a rule that replays its response.
    func mockFromSession(_ request: MCPMockFromSessionRequest) throws -> MCPRule {
        guard let uuid = UUID(uuidString: request.uid),
              let session = MCPSync.onMain({ SessionState.shared.sessions.first { $0.id == uuid } }) else {
            throw MCPWriteError.notFound("No session with uid \(request.uid) in the current capture run.")
        }
        // A live row has no response body yet; a mock of it would replay
        // nothing (protocol-engine doc §S6).
        if let refusal = LiveRowKeeping.refusal(
            uid: request.uid,
            live: MCPSync.onMain({ SessionState.shared.agentLiveState(for: session) }),
            purpose: "mock it"
        ) {
            throw MCPWriteError.invalid(refusal)
        }
        let mode = request.mode ?? .override
        guard mode != .extend else {
            throw MCPWriteError.invalid("mock_from_session supports override or map_local; use create_rule for an extend rule.")
        }
        // Before any side effect (a host filter is added below): a capture
        // that cannot be replayed whole is refused, not mocked in part.
        if let refusal = MCPMockFromSessionCheck.refusal(
            uid: request.uid, mode: mode, responseBody: request.responseBody,
            captured: .init(textBody: session.rspBody, binaryByteCount: session.rspBodyData?.count ?? 0,
                            notRetainedBytes: session.rspBodyTruncatedBytes,
                            undecodedEncoding: session.rspBodyUndecodedEncoding)
        ) {
            throw MCPWriteError.invalid(refusal)
        }
        // The session's method has to be one the proxy can match on, and the
        // message must name the session's method — the tool has no `method`.
        guard MCPWriteValidation.methods.contains(session.method.uppercased()) else {
            throw MCPWriteError.invalid("That session is a \(session.method) request; rules match \(MCPWriteValidation.methods.joined(separator: ", ")) only, so it cannot be mocked.")
        }

        // Check BOTH limits before anything is written: a mock that cannot be
        // saved must not leave a host filter (or a fixture) behind.
        let (existingRules, existingHosts) = try loadRulesAndHosts()
        let (hostName, hostPort) = Self.splitHostAndPort(session.host)
        let knownHost = existingHosts.first { $0.host.caseInsensitiveCompare(hostName) == .orderedSame && ($0.hostDbId?.int64Value ?? 0) != 0 }
        if !MCPFreeTier.isPro {
            if existingRules.count >= MCPFreeTier.rules {
                throw MCPWriteError.limitReached("The free version includes \(MCPFreeTier.rules) override; delete it first, or upgrade ReqRes for unlimited overrides.")
            }
            if knownHost == nil, existingHosts.count >= MCPFreeTier.hostFilters {
                throw MCPWriteError.limitReached("A mock needs a host filter for \(hostName), and the free version includes \(MCPFreeTier.hostFilters); remove one, or upgrade ReqRes.")
            }
        }
        guard MCPWriteValidation.isValidHostname(hostName) else {
            throw MCPWriteError.invalid("The session's host (\(session.host)) is not a hostname ReqRes can filter on, so it cannot be mocked.")
        }

        let hostId: Int64
        if let knownHost, let id = knownHost.hostDbId?.int64Value {
            hostId = id
        } else {
            hostId = try MCPHostAdapter().addHost(MCPHostDraft(host: hostName, scheme: session.scheme, port: hostPort)).id
        }

        // Header names keep their wire case; merge case-insensitively or the
        // agent's Content-Type ends up alongside the captured content-type and
        // the proxy applies the captured one last. `ruleHeaders`, not the
        // display dictionary: a repeated Set-Cookie is joined by a newline
        // there, which rule validation refuses (every login response failed
        // with a 400), and a rule carries one value per name anyway.
        var headers = MCPRecordedHeaders.ruleHeaders(from: session.rspHeaders)
        Self.removeHeaders(named: ["content-length", "transfer-encoding", "content-encoding"], from: &headers)
        // A text body is sent as UTF-8 — `rspBody` is the capture DECODED,
        // from whatever charset it arrived in — so the copied Content-Type
        // must say UTF-8 (R2-1). Before the agent's headers go on, so a
        // Content-Type the agent names itself stands as sent.
        headers = MCPMockCharset.headers(headers, agentBody: request.responseBody, capturedText: session.rspBody)
        for (name, value) in request.responseHeaders ?? [:] {
            Self.removeHeaders(named: [name], from: &headers)
            headers[name] = value
        }

        let status = request.responseStatus ?? session.rspStatus.flatMap { Int($0) } ?? 200
        let matchType = request.matchType ?? .wildcard
        let path = try request.path.map { try MCPWriteValidation.normalizedPath($0, matchType: matchType) }
            ?? Self.pathAndQuery(of: session.fullUrl, scheme: session.scheme)

        var draft = MCPRuleDraft(
            hostId: hostId, mode: mode, matchType: matchType, path: path,
            method: session.method.uppercased(), scheme: session.scheme,
            responseStatus: status, responseHeaders: headers
        )
        switch mode {
        case .mapLocal:
            if let body = request.responseBody {
                draft.localFile = MCPLocalFile(content: body, contentType: Self.header(named: "content-type", in: headers) ?? session.rspContentType)
            } else if !session.rspBody.isEmpty {
                draft.localFile = MCPLocalFile(content: session.rspBody, contentType: session.rspContentType.isEmpty ? "application/json" : session.rspContentType)
            } else if let data = session.rspBodyData, !data.isEmpty {
                // Binary bodies become a fixture file directly.
                let url = try Self.writeFixture(data, contentType: session.rspContentType)
                draft.localFile = MCPLocalFile(path: url.path)
            } else {
                throw MCPWriteError.invalid("Session \(request.uid) has no response body to map; use mode override with a responseBody.")
            }
        case .override, .extend:
            if let body = request.responseBody {
                draft.responseBody = body
            } else if !session.rspBody.isEmpty {
                draft.responseBody = session.rspBody
            } else if let data = session.rspBodyData, !data.isEmpty {
                throw MCPWriteError.invalid("Session \(request.uid) has a binary response body; use mode map_local to replay it as a file.")
            }
        }
        // `validate`, not `validateNewRule`: a mock's headers are the
        // capture's — no default Content-Type is added to a response that
        // had none — and its path is derived from the captured URL, real
        // query and all (agents are shown it masked: `MCPRedactor.redactRule`).
        return try createRule(try MCPWriteValidation.validate(draft))
    }

    // MARK: Pieces

    private func loadRulesAndHosts() throws -> ([RuleCodable], [HostCodable]) {
        do {
            return try MCPSync.wait {
                async let rules = ReqResCoreModelBridge.findAllRules()
                async let hosts = ReqResCoreModelBridge.findAllHosts()
                return (try await rules, try await hosts)
            }
        } catch {
            throw MCPWriteError.failed("Could not read rules: \(error.localizedDescription)")
        }
    }

    private func save(_ rule: RuleCodable, hosts: [HostCodable]) throws -> MCPRule {
        do {
            try MCPSync.wait { try await ReqResCoreModelBridge.saveRule(rule) }
        } catch {
            throw MCPWriteError.failed("Could not save the rule: \(error.localizedDescription)")
        }
        try MCPSync.wait { await AppState.shared.reloadRulesAfterExternalChange() }
        let all = (try? MCPSync.wait { try await ReqResCoreModelBridge.findAllRules() }) ?? []
        // The core keeps the UUID; a fresh rule may only be findable as the newest.
        let saved = all.first(where: { $0.id == rule.id })
            ?? (rule.modelRealId != nil ? all.first(where: { $0.modelRealId == rule.modelRealId }) : all.max(by: { ($0.modelRealId ?? 0) < ($1.modelRealId ?? 0) }))
        guard let saved, let mapped = Self.mcpRule(saved, hosts: hosts) else {
            throw MCPWriteError.failed("The rule was saved but could not be read back.")
        }
        return mapped
    }

    /// Inline content becomes a file in the app's fixtures directory.
    ///
    /// A PATH is accepted only if it is already inside that directory. An
    /// agent that could name any readable file would be able to have the proxy
    /// serve it as the response to a host it also controls — a file-read
    /// primitive out of the user's Mac. The human's own file picker (the
    /// override form) is unaffected: it grants the sandbox access explicitly.
    static func materialize(_ file: MCPLocalFile) throws -> String {
        if let content = file.content {
            let url = try writeFixture(Data(content.utf8), contentType: file.contentType ?? "application/json")
            return url.path
        }
        guard let path = file.path else {
            throw MCPWriteError.invalid("localFile needs content or a path.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let fixtures = try fixturesDirectory().standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(fixtures.path + "/") else {
            throw MCPWriteError.invalid("localFile.path may only point inside \(fixtures.path) (files an agent wrote earlier). Pass the content inline instead — ReqRes will write the fixture itself.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPWriteError.notFound("No file at \(url.path).")
        }
        do {
            try MapLocalConfig.validateFile(at: url)
        } catch {
            throw MCPWriteError.invalid("\(url.lastPathComponent) cannot be mapped: \(error.localizedDescription)")
        }
        return url.path
    }

    /// Removes a fixture this adapter wrote, when the rule that used it is
    /// gone or has been repointed. Files the human chose are never touched.
    static func discardFixture(at path: String?) {
        guard let path, !path.isEmpty,
              let fixtures = try? fixturesDirectory().standardizedFileURL.resolvingSymlinksInPath() else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(fixtures.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func writeFixture(_ data: Data, contentType: String) throws -> URL {
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "application/json"
        let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "json"
        do {
            let url = try fixturesDirectory().appendingPathComponent("\(UUID().uuidString).\(ext)")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw MCPWriteError.failed("Could not write the fixture: \(error.localizedDescription)")
        }
    }

    /// The pattern derived from a captured URL — `OverridePattern.derivedPath`
    /// (MCPKit, tested): pathname AND query on both schemes since plain HTTP
    /// matches the query (core C5). Dropping it for http:// as this used to
    /// would now make the mock miss the very request it was made from.
    static func pathAndQuery(of urlString: String, scheme: String) -> String {
        OverridePattern.derivedPath(fromCapturedURL: urlString)
    }

    /// "api.example.com:3000" → ("api.example.com", 3000). A captured Host
    /// header carries the port; a host filter's name must not.
    static func splitHostAndPort(_ host: String) -> (String, Int?) {
        let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard let colon = trimmed.lastIndex(of: ":"),
              let port = Int(trimmed[trimmed.index(after: colon)...]), (1...65535).contains(port) else {
            return (trimmed, nil)
        }
        return (String(trimmed[trimmed.startIndex..<colon]), port)
    }

    static func removeHeaders(named names: [String], from headers: inout [String: String]) {
        for name in names {
            for key in headers.keys where key.caseInsensitiveCompare(name) == .orderedSame {
                headers.removeValue(forKey: key)
            }
        }
    }

    static func header(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func coreMode(_ mode: MCPRuleMode) -> RuleMode {
        switch mode {
        case .extend: return .EXTEND
        case .override: return .OVERRIDE
        case .mapLocal: return .MAP_LOCAL
        }
    }

    static func mcpMode(_ mode: RuleMode) -> MCPRuleMode {
        switch mode {
        case .EXTEND: return .extend
        case .OVERRIDE: return .override
        case .MAP_LOCAL: return .mapLocal
        }
    }

    /// Headers are stored as a JSON array of the form's `HeaderEntry`.
    ///
    /// An EMPTY list must still be "[]", not "": the core decodes
    /// `rule.reqHeaders` with `JSONDecoder` and skips the whole request-side
    /// branch when it fails (`if isMatch, let customHeaders = …` in
    /// GlueHandler), so a rule with no request headers would never be applied
    /// — silently, with one error line per matching request.
    static func encodeHeaders(_ headers: [String: String]) -> String {
        let entries = headers.sorted { $0.key < $1.key }.map { HeaderEntry(key: $0.key, value: $0.value, isEnabled: true) }
        guard let data = try? JSONEncoder().encode(entries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeHeaders(_ raw: String) -> [String: String] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let entries = try? JSONDecoder().decode([HeaderEntry].self, from: data) else { return [:] }
        return entries.filter(\.isEnabled).reduce(into: [:]) { $0[$1.key] = $1.value }
    }

    static func mcpRule(_ rule: RuleCodable, hosts: [HostCodable]) -> MCPRule? {
        guard let id = rule.modelRealId else { return nil }
        let hostId = rule.hostId.int64Value
        return MCPRule(
            id: id,
            hostId: hostId,
            host: hostId == 0 ? nil : hosts.first(where: { $0.hostDbId?.int64Value == hostId })?.host,
            enabled: rule.enabled.boolValue,
            mode: mcpMode(rule.ruleMode),
            matchType: rule.isRegexp.boolValue ? .regex : .wildcard,
            path: rule.path,
            method: rule.reqMethod,
            scheme: rule.reqProtocol.lowercased(),
            requestHeaders: decodeHeaders(rule.reqHeaders),
            responseStatus: rule.rspCode.intValue,
            responseHeaders: decodeHeaders(rule.rspHeaders),
            responseBody: rule.rspBody.isEmpty ? nil : rule.rspBody,
            localFilePath: rule.rspPath.isEmpty ? nil : rule.rspPath
        )
    }
}

// MARK: - Capture

struct MCPCaptureAdapter: MCPCaptureControlling {
    /// How long to wait for the tunnel to leave its previous state before
    /// answering. `toggleVPNTunnel` only schedules the work, so without this
    /// the agent is told "stopped" right after starting capture and retries —
    /// and a retry inside the window toggles it back off.
    private static let settleTimeout: TimeInterval = 8

    func startCapture() throws {
        let (status, vpn) = MCPSync.onMain { (AppState.shared.extensionStatus, AppState.shared.vpnStatus) }
        guard status == .ready else {
            throw MCPWriteError.unavailable("Capture cannot start: \(MCPTextFormat.remediation(for: status.rawValue))")
        }
        switch vpn {
        case .connected, .connecting:
            return
        case .disconnecting, .reasserting:
            // A start is not sent to a tunnel that is still moving.
            throw MCPWriteError.unavailable("The tunnel is \(MCPStatusAdapter.describe(vpn)); call capture_status in a moment and retry.")
        default:
            // Without the bus the extension delivers to, a start would record
            // for nobody and be refused with only an alert in the window —
            // the agent is told why instead (F11).
            let (listening, anotherCopy) = MCPSync.onMain {
                (AppController.shared.openMessageBus(), CaptureDeliveryMonitor.anotherCopyRunning())
            }
            guard listening else {
                throw MCPWriteError.unavailable(CaptureDeliveryCopy.channelUnavailableMessage(busPort: MessageBusPort, anotherCopyRunning: anotherCopy))
            }
            // An explicit start: if the display was wrong and capture was
            // already running (F11), it is shown running — never stopped, as
            // the toggle this called used to.
            MCPSync.onMain { AppController.shared.startCapture() }
            Self.waitForStatus(toLeave: vpn)
        }
    }

    func stopCapture() throws {
        let vpn = MCPSync.onMain { AppState.shared.vpnStatus }
        switch vpn {
        case .disconnected, .disconnecting, .invalid:
            // Nothing to send — but a Restart Capture caught between its stop
            // and its start must not start capture again after the agent was
            // told it is stopped (F11 review): the request is noted, and the
            // restart stands down.
            MCPSync.onMain { AppController.shared.noteCaptureRequest() }
            return
        case .reasserting:
            throw MCPWriteError.unavailable("The tunnel is reasserting; call capture_status in a moment and retry.")
        default:
            // An explicit stop: never a start, whatever the display said.
            MCPSync.onMain { AppController.shared.stopCapture() }
            Self.waitForStatus(toLeave: vpn)
        }
    }

    func clearSessions() throws -> Int {
        MCPSync.onMain { SessionState.shared.clearAllSessions() }
    }

    /// Polls off the main thread until the tunnel status changes or the
    /// timeout passes, so the status the agent receives is the new one.
    private static func waitForStatus(toLeave previous: NEVPNStatus) {
        let deadline = Date().addingTimeInterval(settleTimeout)
        while Date() < deadline {
            if MCPSync.onMain({ AppState.shared.vpnStatus }) != previous { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

// MARK: - Consent and audit

struct MCPConsentAdapter: MCPWriteConsenting {
    func authorize(_ action: MCPAgentAction) -> MCPConsentDecision {
        MCPAgentActivity.shared.authorize(action)
    }
}

struct MCPAuditAdapter: MCPAuditLogging {
    func record(_ entry: MCPAuditEntry) {
        MCPAgentActivity.shared.record(entry)
    }
}

// MARK: - Exports

/// Writes HAR exports inside the app's own container.
///
/// The agent names the file and ReqRes names the folder — deliberately, and
/// for the same reason `map_local` fixtures are confined: a path an agent
/// chooses is a path an agent can choose badly, and the sandbox would not
/// stop a write into anything the app itself can reach (its own Application
/// Support, its group container). One directory also means "where did that
/// export go" has one answer, and the user can clear them all at once.
struct MCPExportAdapter: MCPSessionExporting {
    static func exportsDirectory() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("MCP Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func writeExport(_ data: Data, filename: String) throws -> URL {
        // `appendingPathComponent` is safe here only because the name was
        // validated in MCPKit (no separators, no "..", no leading dot); it
        // would happily build a traversal out of a raw one.
        let url = try Self.exportsDirectory().appendingPathComponent(filename, isDirectory: false)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw MCPWriteError.failed("Could not write the export: \(error.localizedDescription)")
        }
        return url
    }
}

// MARK: - Exclusions (exclude_host, protocol PRD 3.5)

/// Settings ▸ Capture's exclusion list for the bridge. The list's rules are
/// `ExcludedHostList`'s (Utils, tested); `ExcludedHostsSettings` owns the
/// stored list and pushes every change to the extension, so an agent's
/// exclusion is indistinguishable from one typed into the pane.
/// reqresapp.com (pay-once A16) is always excluded: the list the agent is
/// shown starts with it, and asking to exclude it answers "already excluded".
struct MCPExclusionAdapter: MCPExclusionProviding {
    func excludedHosts() throws -> [String] {
        MCPSync.onMain { MainActor.assumeIsolated { ExcludedHostsSettings.shared.list.allEntries } }
    }

    func check(_ raw: String) -> MCPExclusionCheck {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("://"), !trimmed.contains("/") else {
            return .invalid("host is a bare hostname or a *. wildcard — no scheme or path. Send \(Self.bareHost(trimmed)) instead of \(trimmed).")
        }
        guard let entry = ExcludedHostList.canonicalEntry(trimmed) else {
            return .invalid("'\(raw)' cannot be excluded: send a hostname such as api.example.com, or *.example.com for its subdomains.")
        }
        let list = MCPSync.onMain { MainActor.assumeIsolated { ExcludedHostsSettings.shared.list } }
        // A built-in entry, another spelling of a listed one, or a listed
        // wildcard above a plain host (`ExcludedHostList.coveringEntry`).
        if let covering = list.coveringEntry(for: entry) {
            return .alreadyExcluded(entry: covering)
        }
        return .add(entry: entry)
    }

    func exclude(_ entry: String) throws -> [String] {
        let added = MCPSync.onMain { MainActor.assumeIsolated { ExcludedHostsSettings.shared.exclude(entry) } }
        guard added else {
            throw MCPWriteError.failed("\(entry) could not be added to the exclusion list.")
        }
        return try excludedHosts()
    }

    /// The undo: takes that one entry back off the list.
    func include(_ entry: String) throws {
        MCPSync.onMain { MainActor.assumeIsolated { ExcludedHostsSettings.shared.stopExcluding(entry) } }
    }

    private static func bareHost(_ text: String) -> String {
        URLComponents(string: text.contains("://") ? text : "https://" + text)?.host ?? text
    }
}
