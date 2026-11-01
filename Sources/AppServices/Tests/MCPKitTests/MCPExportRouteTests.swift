//
//  MCPExportRouteTests.swift
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
//  Roadmap item 10. `MCPHARExport` has its own tests for the bytes; these are
//  about the route around it — the parts that decide whether captured traffic
//  reaches a file at all: consent, the name the agent may choose, and what
//  actually lands in the encoder.
//

import XCTest
@testable import MCPKit

/// Records what it was handed instead of touching disk.
final class StubExporter: MCPSessionExporting {
    var written: [(data: Data, filename: String)] = []
    var error: Error?
    var directory = "/tmp/exports"

    func writeExport(_ data: Data, filename: String) throws -> URL {
        if let error { throw error }
        written.append((data, filename))
        return URL(fileURLWithPath: directory).appendingPathComponent(filename)
    }
}

final class MCPExportRouteTests: XCTestCase {
    private let token = "test-token"
    private var consent: StubConsent!
    private var audit: StubAudit!
    private var exporter: StubExporter!

    override func setUp() {
        super.setUp()
        consent = StubConsent()
        audit = StubAudit()
        exporter = StubExporter()
    }

    private func detail(uid: String, host: String = "api.example.com", startedAt: Date? = nil) -> MCPSessionDetail {
        var summary = makeSession(uid: uid, host: host)
        summary.startedAt = startedAt
        return MCPSessionDetail(
            summary: summary,
            requestHeaders: ["Authorization": "Bearer super-secret-token-value"],
            responseHeaders: ["Content-Type": "application/json"],
            responseBodyPreview: #"{"ok":true}"#
        )
    }

    private func makeRouter(_ details: [MCPSessionDetail], exporter: MCPSessionExporting? = nil) -> MCPBridgeRouter {
        let sessions = StubSessionProvider(
            summaries: details.map(\.summary),
            details: Dictionary(uniqueKeysWithValues: details.map { ($0.summary.uid, $0) })
        )
        return MCPBridgeRouter(
            token: token,
            sessions: sessions,
            status: StubStatusProvider(),
            writes: MCPWriteSeams(
                rules: StubRuleProvider(),
                hosts: StubHostProvider(),
                capture: StubCaptureController(),
                consent: consent,
                audit: audit,
                exporter: exporter ?? self.exporter
            )
        )
    }

    private func export(_ router: MCPBridgeRouter, uids: [String], filename: String) throws -> ParsedResponse {
        var request = makeRequest(method: "POST", target: "/v1/sessions/export", token: token)
        request.body = try JSONSerialization.data(withJSONObject: ["uids": uids, "filename": filename])
        request.headers["content-type"] = "application/json"
        return try XCTUnwrap(parseRawResponse(router.respond(to: request)))
    }

    // MARK: - The happy path

    func testExportWritesTheFileAndReportsWhereItWent() throws {
        let router = makeRouter([detail(uid: "s1"), detail(uid: "s2")])

        let response = try export(router, uids: ["s1", "s2"], filename: "login-flow.har")
        XCTAssertEqual(response.status, 201)

        let result = try JSONDecoder().decode(MCPExportResult.self, from: response.body)
        XCTAssertEqual(result.includedCount, 2)
        XCTAssertEqual(result.requestedCount, 2)
        XCTAssertTrue(result.redacted)
        XCTAssertEqual(result.path, "/tmp/exports/login-flow.har")
        XCTAssertEqual(exporter.written.count, 1)
        XCTAssertEqual(audit.entries.last?.outcome, .performed)
    }

    /// The whole reason this path needed its own consent copy.
    func testTheFileIsRedacted() throws {
        let router = makeRouter([detail(uid: "s1")])

        _ = try export(router, uids: ["s1"], filename: "flow")
        let written = try XCTUnwrap(exporter.written.first)

        XCTAssertFalse(String(decoding: written.data, as: UTF8.self).contains("super-secret-token-value"))
    }

    func testAMissingExtensionIsAdded() throws {
        let router = makeRouter([detail(uid: "s1")])

        _ = try export(router, uids: ["s1"], filename: "flow")

        XCTAssertEqual(exporter.written.first?.filename, "flow.har")
    }

    /// A HAR is read as a timeline, so the file's order is the capture's, not
    /// the order the agent happened to list.
    func testEntriesAreWrittenOldestFirst() throws {
        let older = detail(uid: "old", host: "old.example.com", startedAt: Date(timeIntervalSince1970: 1_000))
        let newer = detail(uid: "new", host: "new.example.com", startedAt: Date(timeIntervalSince1970: 2_000))
        let router = makeRouter([older, newer])

        _ = try export(router, uids: ["new", "old"], filename: "flow.har")
        let text = String(decoding: try XCTUnwrap(exporter.written.first?.data), as: UTF8.self)

        let oldIndex = try XCTUnwrap(text.range(of: "old.example.com")).lowerBound
        let newIndex = try XCTUnwrap(text.range(of: "new.example.com")).lowerBound
        XCTAssertLessThan(oldIndex, newIndex)
    }

    // MARK: - Consent

    func testADeniedExportWritesNothing() throws {
        consent.decision = .denied(reason: "not now")
        let router = makeRouter([detail(uid: "s1")])

        let response = try export(router, uids: ["s1"], filename: "flow.har")

        XCTAssertEqual(response.status, 403)
        XCTAssertTrue(exporter.written.isEmpty, "a refusal must not leave a file behind")
        XCTAssertEqual(audit.entries.last?.outcome, .denied)
    }

    func testTheApprovalNamesTheHostsAndTheRedaction() throws {
        let router = makeRouter([detail(uid: "s1", host: "api.example.com"), detail(uid: "s2", host: "cdn.example.com")])

        _ = try export(router, uids: ["s1", "s2"], filename: "flow.har")
        let action = try XCTUnwrap(consent.asked.last)

        XCTAssertEqual(action.kind, .exportSessions)
        XCTAssertEqual(action.severity, .exportsData)
        XCTAssertTrue(action.summary.contains("flow.har"))
        XCTAssertTrue(action.details.contains { $0.contains("api.example.com") && $0.contains("cdn.example.com") })
        XCTAssertTrue(action.details.contains { $0.lowercased().contains("masked") })
    }

    /// Sessions that have aged out between list_sessions and the export are
    /// skipped, but the human is told before they approve.
    func testTheApprovalSaysWhenSomeSessionsAreGone() throws {
        let router = makeRouter([detail(uid: "s1")])

        let response = try export(router, uids: ["s1", "gone"], filename: "flow.har")
        XCTAssertEqual(response.status, 201)

        let action = try XCTUnwrap(consent.asked.last)
        XCTAssertTrue(action.details.contains { $0.contains("no longer captured") })
    }

    // MARK: - What the agent may ask for

    func testAPathIsRefused() throws {
        let router = makeRouter([detail(uid: "s1")])

        for name in ["../escape.har", "/tmp/escape.har", "sub/dir.har", ".hidden.har"] {
            let response = try export(router, uids: ["s1"], filename: name)
            XCTAssertEqual(response.status, 400, "\(name) must be refused")
        }
        XCTAssertTrue(exporter.written.isEmpty)
        XCTAssertTrue(consent.asked.isEmpty, "a name that cannot be used must not interrupt the human")
    }

    func testUnknownSessionsAreA404() throws {
        let router = makeRouter([detail(uid: "s1")])

        let response = try export(router, uids: ["nope"], filename: "flow.har")

        XCTAssertEqual(response.status, 404)
        XCTAssertTrue(consent.asked.isEmpty)
    }

    func testAnEmptyUidListIsRejected() throws {
        let router = makeRouter([detail(uid: "s1")])

        XCTAssertEqual(try export(router, uids: [], filename: "flow.har").status, 400)
    }

    func testTooManySessionsAtOnceIsRejected() throws {
        let router = makeRouter([detail(uid: "s1")])
        let uids = (0...MCPLimits.maxPageSize).map { "s\($0)" }

        XCTAssertEqual(try export(router, uids: uids, filename: "flow.har").status, 400)
        XCTAssertTrue(consent.asked.isEmpty)
    }

    // MARK: - Failure

    func testAFailedWriteIsReportedAndLogged() throws {
        exporter.error = MCPWriteError.failed("disk full")
        let router = makeRouter([detail(uid: "s1")])

        let response = try export(router, uids: ["s1"], filename: "flow.har")

        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(audit.entries.last?.outcome, .failed)
    }

    /// A build with no exporter answers honestly instead of pretending.
    func testABuildWithoutAnExporterSaysSo() throws {
        let router = MCPBridgeRouter(
            token: token,
            sessions: StubSessionProvider(),
            status: StubStatusProvider(),
            writes: MCPWriteSeams(
                rules: StubRuleProvider(),
                hosts: StubHostProvider(),
                capture: StubCaptureController(),
                consent: consent,
                audit: audit
            )
        )

        XCTAssertEqual(try export(router, uids: ["s1"], filename: "flow.har").status, 503)
    }
}
