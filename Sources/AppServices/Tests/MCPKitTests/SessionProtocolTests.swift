//
//  SessionProtocolTests.swift
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

/// HTTP/2 and trailers reaching people and agents (protocol-engine doc §S9):
/// the one protocol classification, the agent's `httpVersion` / `proto` /
/// `proto=` filter, trailers in `get_session` and the HAR, native gRPC's
/// status read from its recorded trailers, and the diagnosis line.
final class SessionProtocolTests: XCTestCase {
    private let token = "t"

    // MARK: - The classification, for every row kind

    func testEveryRowKindHasItsProtocolAndLabel() {
        struct Row { let version: String?; let relay: Bool; let ws: Bool; let proto: SessionProtocol?; let label: String }
        let rows: [Row] = [
            Row(version: "HTTP/1.1", relay: false, ws: false, proto: .http1, label: "HTTP/1.1"),
            Row(version: "HTTP/1.0", relay: false, ws: false, proto: .http1, label: "HTTP/1.0"),
            // NIO's spelling of an HTTP/2 head (core C12: `"\(head.version)"`).
            Row(version: "HTTP/2.0", relay: false, ws: false, proto: .http2, label: "HTTP/2"),
            Row(version: "HTTP/2", relay: false, ws: false, proto: .http2, label: "HTTP/2"),
            Row(version: "h2", relay: false, ws: false, proto: .http2, label: "HTTP/2"),
            // A WebSocket is `ws`, not `h1`, though its handshake was HTTP/1.1.
            Row(version: "HTTP/1.1", relay: false, ws: true, proto: .webSocket, label: "WebSocket"),
            // A relay wins over any version it might carry: nothing inside was read.
            Row(version: "", relay: true, ws: false, proto: .relay, label: "relay/tcp"),
            Row(version: "HTTP/1.1", relay: true, ws: false, proto: .relay, label: "relay/tcp"),
            // No head was read (a TLS failure): never guessed as HTTP/1.1.
            Row(version: "", relay: false, ws: false, proto: nil, label: SessionProtocolPresentation.notRecorded),
            Row(version: nil, relay: false, ws: false, proto: nil, label: SessionProtocolPresentation.notRecorded),
            Row(version: "SPDY/3", relay: false, ws: false, proto: nil, label: SessionProtocolPresentation.notRecorded),
            Row(version: "HTTP/10.1", relay: false, ws: false, proto: nil, label: SessionProtocolPresentation.notRecorded),
            Row(version: "HTTP/2.x", relay: false, ws: false, proto: nil, label: SessionProtocolPresentation.notRecorded),
        ]
        for row in rows {
            XCTAssertEqual(SessionProtocol.classify(httpVersion: row.version, isRelay: row.relay, isWebSocket: row.ws), row.proto, "\(row)")
            XCTAssertEqual(SessionProtocolPresentation.label(httpVersion: row.version, isRelay: row.relay, isWebSocket: row.ws), row.label, "\(row)")
        }
    }

    func testCaptionsSayWhatTheProtocolMeansAndPlainHTTP1SaysNothing() {
        XCTAssertNil(SessionProtocolPresentation.caption(httpVersion: "HTTP/1.1", isRelay: false, isWebSocket: false))
        XCTAssertEqual(SessionProtocolPresentation.caption(httpVersion: "HTTP/2.0", isRelay: false, isWebSocket: false)?.contains("stream"), true)
        XCTAssertEqual(SessionProtocolPresentation.caption(httpVersion: "HTTP/1.1", isRelay: false, isWebSocket: true)?.contains("Upgraded from HTTP/1.1"), true)
        XCTAssertEqual(SessionProtocolPresentation.caption(httpVersion: nil, isRelay: true, isWebSocket: false)?.contains("without being decrypted"), true)
        XCTAssertEqual(SessionProtocolPresentation.caption(httpVersion: "", isRelay: false, isWebSocket: false)?.contains("no protocol was recorded"), true)
    }

    func testFilterSpellingsParseToTheFourTokens() {
        let cases: [(String, SessionProtocol?)] = [
            ("h1", .http1), ("HTTP/1.1", .http1), ("http1", .http1), ("1.1", .http1), (" H1 ", .http1),
            ("h2", .http2), ("HTTP/2", .http2), ("http2", .http2), ("2", .http2), ("HTTP/2.0", .http2),
            ("ws", .webSocket), ("WebSocket", .webSocket), ("wss", .webSocket),
            ("relay", .relay), ("tcp", .relay),
            ("h3", nil), ("quic", nil), ("", nil), ("banana", nil),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(SessionProtocol.parse(raw), expected, raw)
        }
        XCTAssertEqual(SessionProtocol.allCases.map(\.token), ["h1", "h2", "ws", "relay"])
    }

    // MARK: - The agent's list: httpVersion, proto, the filter

    private func summary(_ uid: String, version: String?, proto: SessionProtocol?, status: Int? = 200, relay: Bool = false) -> MCPSessionSummary {
        var row = makeSession(uid: uid, statusCode: status)
        row.httpVersion = version
        row.proto = proto?.token
        if relay { row.kind = .relay }
        return row
    }

    private var mixedRows: [MCPSessionSummary] {
        [
            summary("one", version: "HTTP/1.1", proto: .http1),
            summary("two", version: "HTTP/2.0", proto: .http2),
            summary("ws", version: "HTTP/1.1", proto: .webSocket, status: 101),
            summary("relay", version: nil, proto: .relay, status: nil, relay: true),
            summary("none", version: nil, proto: nil, status: nil),
        ]
    }

    private func router(_ rows: [MCPSessionSummary], details: [String: MCPSessionDetail] = [:]) -> MCPBridgeRouter {
        MCPBridgeRouter(token: token, sessions: StubSessionProvider(summaries: rows, details: details), status: StubStatusProvider())
    }

    private func respond(_ router: MCPBridgeRouter, _ target: String) throws -> ParsedResponse {
        try XCTUnwrap(parseRawResponse(router.respond(to: makeRequest(target: target, token: token))))
    }

    func testListSessionsFiltersByProtocolAndRefusesAnUnusableOne() throws {
        let bridge = router(mixedRows)
        for (value, expected) in [("h2", ["two"]), ("h1", ["one"]), ("ws", ["ws"]), ("relay", ["relay"]), ("http2", ["two"]), ("WebSocket", ["ws"])] {
            let response = try respond(bridge, "/v1/sessions?proto=\(value)")
            XCTAssertEqual(response.status, 200, value)
            let page = try JSONDecoder().decode(MCPSessionPage.self, from: response.body)
            XCTAssertEqual(Set(page.sessions.map(\.uid)), Set(expected), value)
        }
        // `protocol` is read as the same filter.
        let alias = try JSONDecoder().decode(MCPSessionPage.self, from: try respond(bridge, "/v1/sessions?protocol=h2").body)
        XCTAssertEqual(alias.sessions.map(\.uid), ["two"])
        // Refused, never dropped: a dropped filter hands back every row.
        let refused = try respond(bridge, "/v1/sessions?proto=h3")
        XCTAssertEqual(refused.status, 400)
        XCTAssertTrue(String(decoding: refused.body, as: UTF8.self).contains("'proto' must be h1, h2, ws or relay"))
    }

    func testAFilterBuiltByHandNeverSelectsARowWithNoProtocol() {
        let filter = MCPSessionFilter(proto: "h1")
        XCTAssertFalse(filter.matches(summary("none", version: nil, proto: nil, status: nil)))
        XCTAssertFalse(MCPSessionFilter(proto: "banana").matches(summary("one", version: "HTTP/1.1", proto: .http1)))
        XCTAssertEqual(MCPSessionFilter(host: "a", proto: "h2").summaryText, "host=a, proto=h2")
    }

    func testAProtocolIsDerivedWhenTheAppDidNotSendOne() {
        // A summary built without `proto` (a fixture, an older app) still
        // answers from what it carries: the version, a relay, a 101.
        XCTAssertEqual(summary("a", version: "HTTP/2.0", proto: nil).sessionProtocol, .http2)
        XCTAssertEqual(summary("b", version: "HTTP/1.1", proto: nil, status: 101).sessionProtocol, .webSocket)
        XCTAssertEqual(summary("c", version: nil, proto: nil, status: nil, relay: true).sessionProtocol, .relay)
        XCTAssertNil(summary("d", version: nil, proto: nil).sessionProtocol)
        // A sent token wins.
        XCTAssertEqual(summary("e", version: "HTTP/1.1", proto: .webSocket, status: 200).sessionProtocol, .webSocket)
    }

    func testTheClientSendsTheProtocolFilter() {
        let items = MCPBridgeClient.sessionsQuery(filter: MCPSessionFilter(proto: "h2"), limit: nil, cursor: nil)
        XCTAssertEqual(items, [URLQueryItem(name: "proto", value: "h2")])
    }

    func testRowsAndDetailSayWhatTheySpoke() {
        let h2 = summary("two", version: "HTTP/2.0", proto: .http2)
        XCTAssertTrue(MCPTextFormat.row(h2).contains("  proto=h2  "), MCPTextFormat.row(h2))
        XCTAssertFalse(MCPTextFormat.row(summary("none", version: nil, proto: nil, status: nil)).contains("proto="))
        let text = MCPTextFormat.detail(MCPSessionDetail(summary: h2))
        XCTAssertTrue(text.contains("Protocol: HTTP/2 (proto=h2, httpVersion HTTP/2.0)"), text)
        let ws = MCPTextFormat.detail(MCPSessionDetail(summary: summary("ws", version: "HTTP/1.1", proto: .webSocket, status: 101)))
        XCTAssertTrue(ws.contains("Protocol: WebSocket (proto=ws, httpVersion HTTP/1.1)"), ws)
    }

    func testTheSummaryCarriesHTTPVersionAndProtoOnTheWire() throws {
        let data = try JSONEncoder().encode(summary("two", version: "HTTP/2.0", proto: .http2))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["httpVersion"] as? String, "HTTP/2.0")
        XCTAssertEqual(json["proto"] as? String, "h2")
        // An older helper's JSON (no keys) still decodes.
        let old = #"{"uid":"x","host":"h","method":"GET","url":"https://h/","scheme":"https"}"#
        let decoded = try JSONDecoder().decode(MCPSessionSummary.self, from: Data(old.utf8))
        XCTAssertNil(decoded.httpVersion)
        XCTAssertNil(decoded.proto)
    }

    // MARK: - Trailers: get_session, redaction, text

    static let canary = "sk_live_" + "TRAILERCANARY0123456789abcdef"

    private func grpcDetail(uid: String = "g1", host: String = "api.acme.dev") -> MCPSessionDetail {
        var row = makeSession(uid: uid, host: host, method: "POST", statusCode: 200)
        row.httpVersion = "HTTP/2.0"
        row.proto = "h2"
        return MCPSessionDetail(
            summary: row,
            requestHeaders: ["content-type": "application/grpc"],
            responseHeaders: ["content-type": "application/grpc"],
            requestTrailers: ["x-request-checksum": "crc32c=9a71bb4c", "authorization": "Bearer \(Self.canary)"],
            responseTrailers: ["grpc-status": "7", "grpc-message": "key \(Self.canary) denied", "x-\(Self.canary)": "1"]
        )
    }

    func testTrailersAreRedactedLikeHeadersInGetSessionAndItsText() throws {
        let detail = grpcDetail()
        let response = try respond(router([detail.summary], details: ["g1": detail]), "/v1/sessions/g1")
        XCTAssertEqual(response.status, 200)
        let raw = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(raw.contains("TRAILERCANARY"), raw)
        let decoded = try JSONDecoder().decode(MCPSessionDetail.self, from: response.body)
        let request = try XCTUnwrap(decoded.requestTrailers)
        let responseTrailers = try XCTUnwrap(decoded.responseTrailers)
        XCTAssertEqual(request["authorization"], MCPRedactor.placeholder, "a credential NAME is masked like a header")
        XCTAssertEqual(request["x-request-checksum"], "crc32c=9a71bb4c", "an ordinary trailer is kept")
        XCTAssertEqual(responseTrailers["grpc-status"], "7")
        XCTAssertEqual(responseTrailers["grpc-message"]?.contains(MCPRedactor.placeholder), true)
        XCTAssertFalse(responseTrailers.keys.contains { $0.contains("TRAILERCANARY") }, "a credential shape in a NAME is masked too")
        let text = MCPTextFormat.detail(decoded)
        XCTAssertTrue(text.contains("Response trailers (sent after the body):"), text)
        XCTAssertTrue(text.contains("Request trailers (sent after the body):"), text)
        XCTAssertTrue(text.contains("grpc-status: 7"), text)
        XCTAssertFalse(text.contains("TRAILERCANARY"))
    }

    func testAnExceptedHostGetsItsTrailersAsRecorded() {
        let redactor = MCPRedactor(policy: MCPRedactionPolicy(exceptedHosts: ["api.acme.dev"]))
        let shown = redactor.redactDetail(grpcDetail())
        XCTAssertEqual(shown.requestTrailers?["authorization"], "Bearer \(Self.canary)")
    }

    func testNoTrailersIsNilNotAnEmptySection() {
        let detail = MCPSessionDetail(summary: makeSession(uid: "a"), requestTrailers: [:], responseTrailers: nil)
        XCTAssertNil(detail.requestTrailers)
        XCTAssertNil(detail.responseTrailers)
        XCTAssertFalse(MCPTextFormat.detail(detail).contains("trailers"))
    }

    // MARK: - HAR: httpVersion per entry, _trailers

    private func harEntries(_ details: [MCPSessionDetail]) throws -> [[String: Any]] {
        let result = MCPHARExport.encode(sessions: details, redactor: MCPRedactor(), creatorVersion: "1.1.0 (42)")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let log = try XCTUnwrap(json["log"] as? [String: Any])
        return try XCTUnwrap(log["entries"] as? [[String: Any]])
    }

    func testHARWritesEachRowsOwnVersionNeverAConstant() throws {
        var h1 = makeSession(uid: "a"); h1.httpVersion = "HTTP/1.1"
        var h2 = makeSession(uid: "b"); h2.httpVersion = "HTTP/2.0"
        let unknown = makeSession(uid: "c")
        var failed = makeSession(uid: "d", statusCode: 502); failed.httpVersion = "HTTP/2.0"; failed.outcome = .failed; failed.failurePhase = .connect
        let entries = try harEntries([h1, h2, unknown, failed].map { MCPSessionDetail(summary: $0) })
        func versions(_ entry: [String: Any]) -> (String?, String?) {
            ((entry["request"] as? [String: Any])?["httpVersion"] as? String, (entry["response"] as? [String: Any])?["httpVersion"] as? String)
        }
        XCTAssertEqual(versions(entries[0]).0, "HTTP/1.1"); XCTAssertEqual(versions(entries[0]).1, "HTTP/1.1")
        XCTAssertEqual(versions(entries[1]).0, "HTTP/2.0"); XCTAssertEqual(versions(entries[1]).1, "HTTP/2.0")
        XCTAssertEqual(versions(entries[2]).0, "", "a row that recorded no version is not given one")
        XCTAssertEqual(versions(entries[3]).0, "HTTP/2.0")
        XCTAssertEqual(versions(entries[3]).1, "", "a failed row got no response, so no response version")
    }

    func testHARCarriesTrailersAsACustomArrayRedactedLikeHeaders() throws {
        let entries = try harEntries([grpcDetail(), MCPSessionDetail(summary: makeSession(uid: "plain"))])
        let request = try XCTUnwrap(entries[0]["request"] as? [String: Any])
        let response = try XCTUnwrap(entries[0]["response"] as? [String: Any])
        let requestTrailers = try XCTUnwrap(request["_trailers"] as? [[String: String]])
        let responseTrailers = try XCTUnwrap(response["_trailers"] as? [[String: String]])
        XCTAssertTrue(requestTrailers.allSatisfy { Set($0.keys) == ["name", "value"] }, "the headers' own shape")
        XCTAssertTrue(responseTrailers.contains { $0["name"] == "grpc-status" && $0["value"] == "7" })
        XCTAssertTrue(requestTrailers.contains { $0["name"] == "authorization" && $0["value"] == MCPRedactor.placeholder })
        let data = try JSONSerialization.data(withJSONObject: entries)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("TRAILERCANARY"))
        // No trailers, no key.
        XCTAssertNil((entries[1]["request"] as? [String: Any])?["_trailers"])
        XCTAssertNil((entries[1]["response"] as? [String: Any])?["_trailers"])
    }

    // MARK: - Native gRPC's status: trailers, then head

    /// The core's `rspTrailers` / `rspHeaders` shape: ordered pairs.
    private func nativeInput(trailers: String?, head: String, recorded: Bool = true) -> RPCExchangeInput {
        RPCExchangeInput(
            path: "/acme.users.v1.UserService/DeleteUser",
            httpStatus: 200,
            requestHeaders: [RPCHeaderPair(name: "content-type", value: "application/grpc")],
            responseHeaders: RPCExchangeInput.recordedTrailers(from: head),
            responseTrailers: RPCExchangeInput.recordedTrailers(from: trailers),
            trailersRecorded: recorded
        )
    }

    func testRecordedTrailersAreReadInWireOrderWithLowercasedNames() {
        let pairs = RPCExchangeInput.recordedTrailers(from: #"[{"Grpc-Status":"7"},{"grpc-message":"a%20b"},{"x-a":"1"},{"x-a":"2"}]"#)
        XCTAssertEqual(pairs.map(\.name), ["grpc-status", "grpc-message", "x-a", "x-a"])
        XCTAssertEqual(pairs.map(\.value), ["7", "a%20b", "1", "2"])
        XCTAssertTrue(RPCExchangeInput.recordedTrailers(from: nil).isEmpty)
    }

    func testNativeGRPCStatusComesFromItsRecordedTrailers() throws {
        let input = nativeInput(trailers: #"[{"grpc-status":"7"},{"grpc-message":"caller%20lacks%20scope"},{"x-envoy-upstream-service-time":"3"}]"#,
                                head: #"[{"content-type":"application/grpc"}]"#)
        let status = try XCTUnwrap(RPCExchange.status(of: input))
        XCTAssertEqual(status.code, 7)
        XCTAssertEqual(status.message, "caller lacks scope")
        XCTAssertEqual(status.source, .trailers)
    }

    func testATrailersOnlyAnswerIsReadFromTheHead() throws {
        let input = nativeInput(trailers: nil, head: #"[{"content-type":"application/grpc"},{"grpc-status":"5"},{"grpc-message":"no%20such%20user"}]"#)
        let status = try XCTUnwrap(RPCExchange.status(of: input))
        XCTAssertEqual(status.code, 5)
        XCTAssertEqual(status.message, "no such user")
        XCTAssertEqual(status.source, .responseHead)
    }

    func testTrailersWinOverTheHead() throws {
        let input = nativeInput(trailers: #"[{"grpc-status":"0"}]"#, head: #"[{"content-type":"application/grpc"},{"grpc-status":"13"}]"#)
        let status = try XCTUnwrap(RPCExchange.status(of: input))
        XCTAssertEqual(status.code, 0)
        XCTAssertEqual(status.source, .trailers)
    }

    func testAMissingStatusSaysWhyForTheCaptureThatRecordedIt() throws {
        let cut = try XCTUnwrap(RPCExchange.decode(nativeInput(trailers: nil, head: #"[{"content-type":"application/grpc"}]"#), decodingMessages: false))
        XCTAssertNil(cut.status)
        XCTAssertEqual(cut.statusNote?.contains("ended without trailers"), true, cut.statusNote ?? "nil")
        let old = try XCTUnwrap(RPCExchange.decode(nativeInput(trailers: nil, head: #"[{"content-type":"application/grpc"}]"#, recorded: false), decodingMessages: false))
        XCTAssertEqual(old.statusNote?.contains("did not keep"), true, old.statusNote ?? "nil")
    }

    // MARK: - diagnose_setup, retention wording

    private func facts(http2: Bool?) -> MCPSetupFacts {
        MCPSetupFacts(status: StubStatusProvider().status, runningFromApplications: true, proxyPort: 8034,
                      proxyPortListening: true, http2CaptureEnabled: http2)
    }

    func testDiagnosisReportsTheHTTP2SettingAsInformationOnly() throws {
        for enabled in [true, false] {
            let report = MCPSetupDiagnosis.report(facts(http2: enabled))
            let check = try XCTUnwrap(report.checks.first { $0.id == "http2_capture" })
            XCTAssertEqual(check.state, .ok)
            XCTAssertNil(check.fix)
            XCTAssertEqual(check.detail, HTTP2CaptureCopy.diagnosisDetail(enabled: enabled))
            XCTAssertTrue(check.detail.contains(enabled ? "ON" : "off"))
            XCTAssertNotEqual(report.blockingCheckId, "http2_capture")
            XCTAssertEqual(report.checks.last?.id, "proxy_aware_clients", "that one stays last")
        }
        XCTAssertFalse(MCPSetupDiagnosis.report(facts(http2: nil)).checks.contains { $0.id == "http2_capture" }, "unknown is skipped, not guessed")
    }

    func testTheHTTP2RetentionSentenceNamesBothLimits() {
        let sentence = CaptureEngineFacts.http2RetentionSentence()
        XCTAssertTrue(sentence.contains("64 MB"), sentence)
        XCTAssertTrue(sentence.contains("16 MB"), sentence)
        XCTAssertEqual(CaptureEngineFacts.retainedBytesPerHTTP2Connection, 64 * 1024 * 1024)
    }

    func testTheSettingsWordsSayOffByDefaultNewConnectionsAndWebSockets() {
        XCTAssertTrue(HTTP2CaptureCopy.toggleTitle.contains("beta"))
        XCTAssertTrue(HTTP2CaptureCopy.caption.contains("WebSockets stay on HTTP/1.1"))
        XCTAssertTrue(HTTP2CaptureCopy.caption.contains("Turn this off"))
        XCTAssertTrue(HTTP2CaptureCopy.appliesTo.contains("connections already open keep"))
    }
}
