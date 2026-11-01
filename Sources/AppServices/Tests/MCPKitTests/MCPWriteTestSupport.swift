//
//  MCPWriteTestSupport.swift
//  AppServices
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
@testable import MCPKit

/// In-memory rule store with the seam's error injection points.
final class StubRuleProvider: MCPRuleProviding {
    var stored: [MCPRule] = []
    var created: [MCPRuleDraft] = []
    var mocked: [MCPMockFromSessionRequest] = []
    var createError: MCPWriteError?
    var mockError: MCPWriteError?
    /// What the app would copy out of the captured session.
    var mockResponseHeaders: [String: String] = [:]
    var mockResponseBody: String?
    /// The path the app would derive from the captured URL — pathname AND
    /// query (`OverridePattern.derivedPath`) — when the agent names none.
    var mockDerivedPath: String?
    private var nextId: Int64 = 1

    func rules() throws -> [MCPRule] { stored }

    func createRule(_ draft: MCPRuleDraft) throws -> MCPRule {
        if let createError { throw createError }
        created.append(draft)
        let rule = MCPRule(
            id: nextId, hostId: draft.hostId ?? 0, host: draft.hostId.map { "host-\($0)" },
            enabled: draft.enabled, mode: draft.mode, matchType: draft.matchType, path: draft.path,
            method: draft.method, scheme: draft.scheme, requestHeaders: draft.requestHeaders,
            responseStatus: draft.responseStatus, responseHeaders: draft.responseHeaders,
            responseBody: draft.responseBody, localFilePath: draft.localFile?.path
        )
        nextId += 1
        stored.append(rule)
        return rule
    }

    func updateRule(id: Int64, patch: MCPRulePatch) throws -> MCPRule {
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            throw MCPWriteError.notFound("No rule with id \(id).")
        }
        var rule = stored[index]
        if let enabled = patch.enabled { rule.enabled = enabled }
        if let mode = patch.mode { rule.mode = mode }
        if let matchType = patch.matchType { rule.matchType = matchType }
        if let path = patch.path { rule.path = path }
        if let method = patch.method { rule.method = method }
        if let scheme = patch.scheme { rule.scheme = scheme }
        if let headers = patch.requestHeaders { rule.requestHeaders = headers }
        if let status = patch.responseStatus { rule.responseStatus = status }
        if let headers = patch.responseHeaders { rule.responseHeaders = headers }
        if let body = patch.responseBody { rule.responseBody = body }
        if let file = patch.localFile { rule.localFilePath = file.path }
        stored[index] = rule
        return rule
    }

    func deleteRule(id: Int64) throws {
        guard stored.contains(where: { $0.id == id }) else {
            throw MCPWriteError.notFound("No rule with id \(id).")
        }
        stored.removeAll { $0.id == id }
    }

    func mockFromSession(_ request: MCPMockFromSessionRequest) throws -> MCPRule {
        if let mockError { throw mockError }
        mocked.append(request)
        return try createRule(MCPRuleDraft(
            hostId: 7, mode: request.mode ?? .override, matchType: request.matchType ?? .wildcard,
            path: request.path ?? mockDerivedPath ?? "/from/\(request.uid)",
            responseStatus: request.responseStatus ?? 200,
            responseHeaders: mockResponseHeaders.merging(request.responseHeaders ?? [:]) { _, new in new },
            responseBody: request.responseBody ?? mockResponseBody ?? "{}"
        ))
    }
}

final class StubHostProvider: MCPHostProviding {
    var stored: [MCPHost] = []
    var addError: MCPWriteError?
    private var nextId: Int64 = 1

    func hosts() throws -> [MCPHost] { stored }

    func addHost(_ draft: MCPHostDraft) throws -> MCPHost {
        if let addError { throw addError }
        let host = MCPHost(id: nextId, host: draft.host, scheme: draft.scheme, port: draft.port ?? 80)
        nextId += 1
        stored.append(host)
        return host
    }

    func removeHost(id: Int64) throws {
        guard stored.contains(where: { $0.id == id }) else {
            throw MCPWriteError.notFound("No host with id \(id).")
        }
        stored.removeAll { $0.id == id }
    }
}

final class StubCaptureController: MCPCaptureControlling {
    var commands: [MCPCaptureCommand] = []
    var sessionsToClear = 0
    var error: MCPWriteError?

    func startCapture() throws {
        if let error { throw error }
        commands.append(.start)
    }

    func stopCapture() throws {
        if let error { throw error }
        commands.append(.stop)
    }

    func clearSessions() throws -> Int {
        if let error { throw error }
        return sessionsToClear
    }
}

final class StubConsent: MCPWriteConsenting {
    var decision: MCPConsentDecision = .allowed
    var asked: [MCPAgentAction] = []

    func authorize(_ action: MCPAgentAction) -> MCPConsentDecision {
        asked.append(action)
        return decision
    }
}

final class StubAudit: MCPAuditLogging {
    var entries: [MCPAuditEntry] = []
    func record(_ entry: MCPAuditEntry) { entries.append(entry) }
}
