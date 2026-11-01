//
//  MCPHARExportTests.swift
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

import XCTest
@testable import MCPKit

final class MCPHARExportTests: XCTestCase {
    private func detail(
        uid: String = "s1",
        host: String = "api.example.com",
        method: String = "GET",
        url: String? = nil,
        statusCode: Int? = 200,
        startedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000.250),
        durationMs: Double? = 42,
        requestBodySize: Int? = nil,
        responseBodySize: Int? = nil,
        contentType: String? = "application/json",
        requestHeaders: [String: String] = [:],
        responseHeaders: [String: String] = [:],
        requestBodyPreview: String? = nil,
        responseBodyPreview: String? = nil
    ) -> MCPSessionDetail {
        var summary = makeSession(uid: uid, host: host, method: method, url: url, statusCode: statusCode)
        summary.startedAt = startedAt
        summary.durationMs = durationMs
        summary.requestBodySize = requestBodySize
        summary.responseBodySize = responseBodySize
        summary.contentType = contentType
        return MCPSessionDetail(
            summary: summary,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBodyPreview: requestBodyPreview,
            responseBodyPreview: responseBodyPreview
        )
    }

    private func log(from data: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["log"] as? [String: Any])
    }

    private func entries(from data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(try log(from: data)["entries"] as? [[String: Any]])
    }

    // MARK: - Shape conformance

    // MARK: - Per-process attribution (UX spec §6, §11)

    /// The originating app and pid ride along as HAR custom fields (the `_`
    /// prefix is the spec's own extension point), so a HAR handed to someone
    /// else still says which process made each request.
    func testAnAttributedEntryCarriesTheAppAndPidAsCustomFields() throws {
        var attributed = detail(uid: "s1")
        attributed.summary.app = "claude"
        attributed.summary.pid = 9437
        let result = MCPHARExport.encode(sessions: [attributed], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let entry = try XCTUnwrap(try entries(from: result.data).first)

        XCTAssertEqual(entry["_reqresApp"] as? String, "claude")
        XCTAssertEqual(entry["_reqresPid"] as? Int, 9437)
    }

    /// An unattributed session has NO such fields — not empty ones, which a
    /// reader could take for a process called "".
    func testAnUnattributedEntryHasNoAttributionFields() throws {
        let result = MCPHARExport.encode(sessions: [detail(uid: "s1")], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let entry = try XCTUnwrap(try entries(from: result.data).first)

        XCTAssertNil(entry["_reqresApp"])
        XCTAssertNil(entry["_reqresPid"])
        XCTAssertFalse(String(decoding: result.data, as: UTF8.self).contains("_reqres"))
    }

    /// The executable path carries the username and no HAR consumer reads
    /// it: the name and the pid are the ONLY attribution that leaves the
    /// screen. Pinned by enumerating every custom field an entry has.
    func testNoPathAndNoOtherAttributionFieldLeavesTheApp() throws {
        var attributed = detail(uid: "s1")
        attributed.summary.app = "Brave Browser"
        attributed.summary.pid = 4127
        let result = MCPHARExport.encode(sessions: [attributed], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let entry = try XCTUnwrap(try entries(from: result.data).first)

        let customFields = entry.keys.filter { $0.hasPrefix("_") }.sorted()
        XCTAssertEqual(customFields, ["_reqresApp", "_reqresPid"])
        let text = String(decoding: result.data, as: UTF8.self)
        XCTAssertFalse(text.contains("/Applications/"))
        XCTAssertFalse(text.lowercased().contains("path"))
    }

    /// Redaction touches credentials, not process names: the export goes
    /// through the redactor and keeps the attribution.
    func testRedactionKeepsTheAttribution() throws {
        var attributed = detail(uid: "s1", requestHeaders: ["Authorization": "Bearer secret-token-value"])
        attributed.summary.app = "claude"
        attributed.summary.pid = 9437
        let result = MCPHARExport.encode(sessions: [attributed], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let entry = try XCTUnwrap(try entries(from: result.data).first)
        let text = String(decoding: result.data, as: UTF8.self)

        XCTAssertFalse(text.contains("secret-token-value"))
        XCTAssertEqual(entry["_reqresApp"] as? String, "claude")
        XCTAssertEqual(entry["_reqresPid"] as? Int, 9437)
    }

    /// A blank app name is nothing, not a process.
    func testABlankAppNameIsOmitted() throws {
        var attributed = detail(uid: "s1")
        attributed.summary.app = ""
        attributed.summary.pid = 1
        let result = MCPHARExport.encode(sessions: [attributed], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let entry = try XCTUnwrap(try entries(from: result.data).first)

        XCTAssertNil(entry["_reqresApp"])
        XCTAssertEqual(entry["_reqresPid"] as? Int, 1)
    }

    // MARK: - Shape conformance

    func testEncodesTheRequiredHAR12Shape() throws {
        let result = MCPHARExport.encode(sessions: [detail()], redactor: MCPRedactor(), creatorVersion: "1.0.5")
        let log = try log(from: result.data)

        XCTAssertEqual(log["version"] as? String, "1.2")
        let creator = try XCTUnwrap(log["creator"] as? [String: Any])
        XCTAssertEqual(creator["name"] as? String, "ReqRes")
        XCTAssertEqual(creator["version"] as? String, "1.0.5")

        let entries = try entries(from: result.data)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)

        XCTAssertNotNil(entry["startedDateTime"] as? String)
        XCTAssertNotNil(entry["time"])
        XCTAssertNotNil(entry["cache"] as? [String: Any])
        let timings = try XCTUnwrap(entry["timings"] as? [String: Any])
        XCTAssertNotNil(timings["send"])
        XCTAssertNotNil(timings["wait"])
        XCTAssertNotNil(timings["receive"])

        let request = try XCTUnwrap(entry["request"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "GET")
        XCTAssertNotNil(request["url"] as? String)
        XCTAssertNotNil(request["httpVersion"] as? String)
        XCTAssertNotNil(request["cookies"] as? [Any])
        XCTAssertNotNil(request["headers"] as? [Any])
        XCTAssertNotNil(request["queryString"] as? [Any])
        XCTAssertNotNil(request["headersSize"] as? Int)
        XCTAssertNotNil(request["bodySize"] as? Int)

        let response = try XCTUnwrap(entry["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 200)
        XCTAssertNotNil(response["statusText"] as? String)
        XCTAssertNotNil(response["httpVersion"] as? String)
        XCTAssertNotNil(response["cookies"] as? [Any])
        XCTAssertNotNil(response["headers"] as? [Any])
        XCTAssertNotNil(response["redirectURL"] as? String)
        XCTAssertNotNil(response["headersSize"] as? Int)
        XCTAssertNotNil(response["bodySize"] as? Int)
        let content = try XCTUnwrap(response["content"] as? [String: Any])
        XCTAssertNotNil(content["size"] as? Int)
        XCTAssertNotNil(content["mimeType"] as? String)
    }

    func testEmptyInputProducesAValidEmptyHAR() throws {
        let result = MCPHARExport.encode(sessions: [], redactor: MCPRedactor(), creatorVersion: "1.0.5")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.includedCount, 0)

        let log = try log(from: result.data)
        XCTAssertEqual(log["version"] as? String, "1.2")
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertTrue(entries.isEmpty)
        // An empty export is not a truncated one. No comment should appear
        // just because there was nothing to include.
        XCTAssertNil(log["comment"])
    }

    // MARK: - Redaction (this file's own responsibility, not assumed upstream)

    func testCredentialRequestHeaderIsMaskedInTheOutput() throws {
        let d = detail(requestHeaders: ["Authorization": "Bearer secret-token-abc123"])
        let result = MCPHARExport.encode(sessions: [d], redactor: MCPRedactor(), creatorVersion: "1.0.5")
        let text = try XCTUnwrap(String(data: result.data, encoding: .utf8))

        XCTAssertFalse(text.contains("secret-token-abc123"))
        XCTAssertTrue(text.contains(MCPRedactor.placeholder))
    }

    func testSetCookieResponseHeaderIsMaskedInTheOutput() throws {
        // The exact regression this file exists to avoid repeating:
        // mock_from_session once forwarded a login response's Set-Cookie
        // verbatim because it assumed an earlier layer had redacted it.
        let d = detail(responseHeaders: ["Set-Cookie": "session=abc123def456; Path=/"])
        let result = MCPHARExport.encode(sessions: [d], redactor: MCPRedactor(), creatorVersion: "1.0.5")
        let text = try XCTUnwrap(String(data: result.data, encoding: .utf8))

        XCTAssertFalse(text.contains("abc123def456"))
    }

    /// HAR lists one entry per header line. A repeated Set-Cookie reaches the
    /// encoder joined by a newline (`MCPRecordedHeaders`); it must leave as
    /// separate entries, in order, not one value with a line break inside.
    func testRepeatedSetCookieBecomesOneHAREntryPerCookie() throws {
        let joined = MCPRecordedHeaders.dictionary(from: #"[{"Set-Cookie":"sid=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT"},{"Set-Cookie":"theme=dark"},{"Content-Type":"text/plain"}]"#)
        let d = detail(responseHeaders: joined)
        let result = MCPHARExport.encode(sessions: [d], redactor: MCPRedactor(enabled: false), creatorVersion: "1.1.0")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        let entry = try XCTUnwrap((log["entries"] as? [[String: Any]])?.first)
        let response = try XCTUnwrap(entry["response"] as? [String: Any])
        let headers = try XCTUnwrap(response["headers"] as? [[String: String]])
        let cookies = headers.filter { $0["name"]?.lowercased() == "set-cookie" }.compactMap { $0["value"] }
        XCTAssertEqual(cookies, ["sid=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT", "theme=dark"])
        XCTAssertFalse(headers.contains { $0["value"]?.contains("\n") == true })
    }

    func testUnredactedCallerStillGetsAnUnmaskedExport() throws {
        // Confirms the masking above comes from the redactor, not from some
        // accidental stripping of header values in the encoder itself.
        let d = detail(requestHeaders: ["Authorization": "Bearer secret-token-abc123"])
        let result = MCPHARExport.encode(sessions: [d], redactor: MCPRedactor(enabled: false), creatorVersion: "1.0.5")
        let text = try XCTUnwrap(String(data: result.data, encoding: .utf8))

        XCTAssertTrue(text.contains("secret-token-abc123"))
    }

    // MARK: - Dates

    func testStartedDateTimeIsISO8601WithMilliseconds() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000.257)
        let result = MCPHARExport.encode(sessions: [detail(startedAt: started)], redactor: MCPRedactor(), creatorVersion: "1.0.5")
        let entry = try XCTUnwrap(try entries(from: result.data).first)
        let startedDateTime = try XCTUnwrap(entry["startedDateTime"] as? String)

        // ISO8601DateFormatter with .withFractionalSeconds always emits
        // exactly three fractional digits before the zone marker.
        XCTAssertTrue(
            startedDateTime.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil,
            "unexpected format: \(startedDateTime)"
        )
    }

    // MARK: - Unknown numerics

    func testRequiredButUnavailableNumericsAreNegativeOneNotZero() throws {
        let d = detail(durationMs: nil, requestBodySize: nil, responseBodySize: nil)
        let result = MCPHARExport.encode(sessions: [d], redactor: MCPRedactor(), creatorVersion: "1.0.5")
        let entry = try XCTUnwrap(try entries(from: result.data).first)

        let request = try XCTUnwrap(entry["request"] as? [String: Any])
        XCTAssertEqual(request["headersSize"] as? Int, -1)
        XCTAssertEqual(request["bodySize"] as? Int, -1)

        let response = try XCTUnwrap(entry["response"] as? [String: Any])
        XCTAssertEqual(response["headersSize"] as? Int, -1)
        XCTAssertEqual(response["bodySize"] as? Int, -1)
        let content = try XCTUnwrap(response["content"] as? [String: Any])
        XCTAssertEqual(content["size"] as? Int, -1)

        let timings = try XCTUnwrap(entry["timings"] as? [String: Any])
        XCTAssertEqual(timings["send"] as? Int, -1)
        XCTAssertEqual(timings["wait"] as? Int, -1)
        XCTAssertEqual(timings["receive"] as? Int, -1)
        XCTAssertEqual(entry["time"] as? Int, -1)
    }

    func testKnownDurationFillsTheWaitTimingNotZero() throws {
        let d = detail(durationMs: 123.5)
        let result = MCPHARExport.encode(sessions: [d], redactor: MCPRedactor(), creatorVersion: "1.0.5")
        let entry = try XCTUnwrap(try entries(from: result.data).first)
        let timings = try XCTUnwrap(entry["timings"] as? [String: Any])

        XCTAssertEqual(timings["wait"] as? Double, 123.5)
        XCTAssertEqual(timings["send"] as? Int, -1)
        XCTAssertEqual(timings["receive"] as? Int, -1)
        // The spec ties entry.time to the sum of its non -1 timings; with
        // only "wait" known, that sum is exactly the duration we were given.
        XCTAssertEqual(entry["time"] as? Double, 123.5)
    }

    // MARK: - Determinism

    func testEncodingTheSameSessionsTwiceIsByteIdentical() {
        let sessions = (1...6).map {
            detail(uid: "s\($0)", requestHeaders: ["X-Header-\($0)": "v\($0)", "Accept": "*/*"])
        }
        let first = MCPHARExport.encode(sessions: sessions, redactor: MCPRedactor(), creatorVersion: "1.0.5")
        let second = MCPHARExport.encode(sessions: sessions, redactor: MCPRedactor(), creatorVersion: "1.0.5")

        XCTAssertEqual(first.data, second.data)
    }

    // MARK: - Truncation guard

    func testTruncationGuardFiresAndSaysSoInTheHARItself() throws {
        let bigBody = String(repeating: "x", count: 4_000)
        let sessions = (1...30).map { detail(uid: "s\($0)", responseBodyPreview: bigBody) }
        let result = MCPHARExport.encode(
            sessions: sessions,
            redactor: MCPRedactor(),
            creatorVersion: "1.0.5",
            maxEncodedBytes: 10_000
        )

        XCTAssertTrue(result.truncated)
        XCTAssertGreaterThan(result.includedCount, 0)
        XCTAssertLessThan(result.includedCount, sessions.count)

        let log = try log(from: result.data)
        let comment = try XCTUnwrap(log["comment"] as? String)
        XCTAssertTrue(comment.localizedCaseInsensitiveContains("truncat"))
        XCTAssertTrue(comment.contains("\(result.includedCount)"))
        XCTAssertTrue(comment.contains("\(sessions.count)"))

        // The comment must describe reality, not just exist alongside it.
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, result.includedCount)
    }

    func testUnderTheCapNoTruncationIsReportedAtAll() throws {
        let sessions = (1...3).map { detail(uid: "s\($0)") }
        let result = MCPHARExport.encode(sessions: sessions, redactor: MCPRedactor(), creatorVersion: "1.0.5")

        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.includedCount, 3)
        let log = try log(from: result.data)
        XCTAssertNil(log["comment"])
    }

    // MARK: - serverIPAddress (destination-map UX spec §8.4)

    /// HAR 1.2 defines `serverIPAddress`; the address the proxy connected to
    /// goes there and nowhere else — no custom country field, because a
    /// reader with the address can resolve it and one without has nothing
    /// to be misled by.
    func testTheServerAddressFillsHARsOwnServerIPAddressField() throws {
        var placed = detail(uid: "s1")
        placed.serverAddress = "104.18.32.7"
        placed.summary.country = "DE"
        let result = MCPHARExport.encode(sessions: [placed], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let entry = try XCTUnwrap(try entries(from: result.data).first)

        XCTAssertEqual(entry["serverIPAddress"] as? String, "104.18.32.7")
        XCTAssertEqual(entry.keys.filter { $0.hasPrefix("_") }, [], "no custom field for the country")
        XCTAssertFalse(String(decoding: result.data, as: UTF8.self).lowercased().contains("country"))
    }

    /// Absent, not empty: an older extension reports no address, and a HAR
    /// reader must not take "" for a server.
    func testNoServerAddressMeansNoServerIPAddressField() throws {
        let result = MCPHARExport.encode(sessions: [detail(uid: "s1")], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let entry = try XCTUnwrap(try entries(from: result.data).first)
        XCTAssertNil(entry["serverIPAddress"])
        XCTAssertFalse(String(decoding: result.data, as: UTF8.self).contains("serverIPAddress"))
    }

    /// The core hands a bare literal; a port from any other source is
    /// dropped as HAR defines the field, and a bare IPv6 is left alone.
    func testAPortIsStrippedFromTheServerAddress() {
        XCTAssertEqual(MCPHARExport.serverIPAddress(from: "104.18.32.7"), "104.18.32.7")
        XCTAssertEqual(MCPHARExport.serverIPAddress(from: "104.18.32.7:443"), "104.18.32.7")
        XCTAssertEqual(MCPHARExport.serverIPAddress(from: "[2001:db8::1]:443"), "2001:db8::1")
        XCTAssertEqual(MCPHARExport.serverIPAddress(from: "[::1]"), "::1")
        XCTAssertEqual(MCPHARExport.serverIPAddress(from: "2001:db8::1"), "2001:db8::1")
        XCTAssertEqual(MCPHARExport.serverIPAddress(from: " 8.8.8.8 "), "8.8.8.8")
        XCTAssertNil(MCPHARExport.serverIPAddress(from: nil))
        XCTAssertNil(MCPHARExport.serverIPAddress(from: ""))
        XCTAssertNil(MCPHARExport.serverIPAddress(from: "   "))
        XCTAssertNil(MCPHARExport.serverIPAddress(from: "[]:443"))
    }

    /// Redaction touches credentials, not addresses: the export keeps the
    /// server address while masking the header beside it.
    func testRedactionKeepsTheServerAddress() throws {
        var placed = detail(uid: "s1", requestHeaders: ["Authorization": "Bearer secret-token-value"])
        placed.serverAddress = "104.18.32.7"
        let result = MCPHARExport.encode(sessions: [placed], redactor: MCPRedactor(), creatorVersion: "1.1.0")
        let entry = try XCTUnwrap(try entries(from: result.data).first)
        XCTAssertEqual(entry["serverIPAddress"] as? String, "104.18.32.7")
        XCTAssertFalse(String(decoding: result.data, as: UTF8.self).contains("secret-token-value"))
    }
}
