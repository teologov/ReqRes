//
//  MCPHARExport.swift
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
//  The encoder half of export_sessions. A HAR file is a new kind of egress for
//  captured material. Once it is a file on disk, any tool can open it, not just
//  the MCP client that was approved to read the session. So this encoder
//  redacts for itself instead of trusting the caller already did: the last time
//  a write path assumed upstream redaction, mock_from_session handed an agent a
//  login response's Set-Cookie verbatim.
//
//  This file only turns already-fetched MCPSessionDetail values into bytes.
//  It does not touch disk and does not know about consent. The adapter
//  that calls it owns the file path, the write, and the copy shown to the
//  human before either happens.
//

import Foundation

/// Encodes captured sessions as a HAR 1.2 log
/// (http://www.softwareishard.com/blog/har-12-spec/), the format Chrome,
/// Charles and Proxyman all read.
public enum MCPHARExport {
    public static let harVersion = "1.2"

    /// A HAR viewer choking on a multi-hundred-MB file is the actual failure
    /// mode reported against long Charles/Proxyman exports. 20 MB stays
    /// comfortably openable while covering a realistic debugging session
    /// (a few hundred JSON-sized exchanges).
    public static let defaultMaxEncodedBytes = 20_000_000

    /// The spec's own answer for a required numeric field this capture layer
    /// cannot supply (no per-phase timing breakdown, no raw wire header
    /// size): -1, not zero. Zero reads as "measured, and it was instant."
    private static let unknownNumber = -1

    /// RFC 7231 §3.1.1.5's default for a body with no declared Content-Type.
    /// This is what a compliant HTTP client already assumes for such a body,
    /// not a type this encoder is guessing at.
    private static let unknownMimeType = "application/octet-stream"

    /// HAR's `httpVersion`, per entry, from what the ROW recorded (doc §S9).
    /// This used to be the constant "HTTP/1.1" — true while the engine spoke
    /// HTTP/1.1 on both legs, false since core C12 captures HTTP/2 (the
    /// recorded "HTTP/2.0"). A row that recorded none (a relay, a request
    /// that failed before its head) writes "", which is what Chrome writes
    /// for a request that got no answer — never a version it did not see.
    static func httpVersion(of summary: MCPSessionSummary) -> String {
        guard let version = summary.httpVersion?.trimmingCharacters(in: .whitespaces), !version.isEmpty else { return "" }
        return version
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public struct Result: Equatable {
        public let data: Data
        /// True when `maxEncodedBytes` cut the entry list short. The HAR
        /// itself already says so in `log.comment`; this mirrors that so a
        /// caller can react (e.g. warn before writing the file) without
        /// re-parsing its own output.
        public let truncated: Bool
        /// Sessions actually written into `entries`, for the same reason.
        public let includedCount: Int
    }

    /// Builds the HAR. `creatorVersion` is the app version string the caller
    /// already has (e.g. "1.0.5 (41)"); this file has no way to read it
    /// itself and does not invent one.
    ///
    /// Sessions are redacted here, one at a time, immediately before they are
    /// turned into an entry, never assumed to already be safe. `redactor`
    /// runs the same header/URL/body coverage the read surface uses
    /// (`MCPRedactor.redactDetail`), so this path cannot silently diverge
    /// from it the way a hand-rolled field-by-field redaction could.
    public static func encode(
        sessions: [MCPSessionDetail],
        redactor: MCPRedactor,
        creatorVersion: String,
        maxEncodedBytes: Int = defaultMaxEncodedBytes,
        webSocketMessages: [String: MCPSocketConversation] = [:]
    ) -> Result {
        var entries: [[String: Any]] = []
        var runningBytes = 0
        var truncated = false

        for session in sessions {
            let redacted = redactor.redactDetail(session)
            var entry = harEntry(for: redacted)
            // A WebSocket's messages ride on its 101 entry in Chrome's shape
            // (protocol-engine doc §S7), redacted exactly as the agent
            // surface redacts them, and counted against the same size cap.
            if let conversation = webSocketMessages[session.summary.uid], conversation.log != nil {
                addWebSocketMessages(to: &entry, conversation, redacting: redactor.redacts(host: session.summary.host))
            }
            let entryBytes = serializedByteCount(entry)
            // An empty export is a worse answer than one oversized entry, so
            // the first is always included. But it is included with its bodies
            // dropped rather than whole: today every body arriving here is
            // already preview-capped, and the moment this encoder is handed
            // full bodies a single large download would otherwise write an
            // unbounded file, which is the exact thing the cap exists to stop.
            if runningBytes + entryBytes > maxEncodedBytes {
                truncated = true
                if entries.isEmpty {
                    entries.append(entryWithoutBodies(entry))
                }
                break
            }
            entries.append(entry)
            runningBytes += entryBytes
        }

        let comment = truncated
            ? "Truncated: \(entries.count) of \(sessions.count) sessions included "
                + "(size cap of \(maxEncodedBytes) bytes reached). Narrow the "
                + "selection and export again to see the rest."
            : nil
        let log = harLog(entries: entries, creatorVersion: creatorVersion, comment: comment)
        let data = serialize(log) ?? fallbackEmptyHARData(
            creatorVersion: creatorVersion,
            comment: "Encoding failed unexpectedly; this export contains no entries."
        )
        return Result(data: data, truncated: truncated, includedCount: entries.count)
    }

    // MARK: - Entry assembly

    private static func harEntry(for detail: MCPSessionDetail) -> [String: Any] {
        let summary = detail.summary

        var request: [String: Any] = [
            "method": summary.method.uppercased(),
            "url": summary.url,
            "httpVersion": httpVersion(of: summary),
            "cookies": [] as [Any],
            "headers": headerArray(detail.requestHeaders),
            "queryString": queryItemsArray(from: summary.url),
            "headersSize": unknownNumber,
            "bodySize": summary.requestBodySize ?? unknownNumber,
        ]
        let requestNotRetained = detail.notRetainedBytes(.request)
        if let body = detail.requestBodyPreview, !body.isEmpty {
            var postData: [String: Any] = [
                "mimeType": mimeType(from: detail.requestHeaders) ?? unknownMimeType,
            ]
            // A binary body is described, never inlined: the description is
            // a comment, not the payload (HAR viewers show `text` as the body).
            if MCPBinaryBody.isDescription(body) {
                postData["comment"] = body
            } else {
                postData["text"] = body
            }
            markNotRetained(&postData, requestNotRetained)
            request["postData"] = postData
        } else if requestNotRetained > 0 {
            // Nothing of the body was kept, but there WAS one: say so rather
            // than let a reader take the missing postData for "no body".
            var postData: [String: Any] = [
                "mimeType": mimeType(from: detail.requestHeaders) ?? unknownMimeType,
                "text": "",
            ]
            markNotRetained(&postData, requestNotRetained)
            request["postData"] = postData
        }
        // HAR 1.2 has no field for trailers (header fields sent after the
        // body, core C13), so they ride as a custom `_trailers` array in the
        // headers' own shape, already redacted with them (`redactDetail`).
        if let trailers = detail.requestTrailers, !trailers.isEmpty {
            request["_trailers"] = headerArray(trailers)
        }

        var content: [String: Any] = [
            "size": summary.responseBodySize ?? unknownNumber,
            "mimeType": summary.contentType ?? mimeType(from: detail.responseHeaders) ?? unknownMimeType,
        ]
        if let body = detail.responseBodyPreview, !body.isEmpty {
            if MCPBinaryBody.isDescription(body) {
                content["comment"] = body
            } else {
                content["text"] = body
            }
        }
        markNotRetained(&content, detail.notRetainedBytes(.response))

        var response: [String: Any] = [
            // 0 signals "no response arrived" (mitmproxy's convention);
            // spec's -1 is reserved for "field not measured", a different
            // fact than "there was genuinely nothing to measure".
            // A FAILED row got no response from any server — the 502 some
            // of them carry is ReqRes's own answer to the app — so it is
            // written as status 0 with `_error` below, Chrome's convention
            // for a request that never got an answer.
            "status": summary.effectiveOutcome == .failed ? 0 : (summary.statusCode ?? 0),
            "statusText": "",
            // A FAILED row got no response, so no version either.
            "httpVersion": summary.effectiveOutcome == .failed ? "" : httpVersion(of: summary),
            "cookies": [] as [Any],
            "headers": headerArray(detail.responseHeaders),
            "content": content,
            "redirectURL": headerValue(detail.responseHeaders, named: "location") ?? "",
            "headersSize": unknownNumber,
            "bodySize": summary.responseBodySize ?? unknownNumber,
        ]
        if let trailers = detail.responseTrailers, !trailers.isEmpty {
            response["_trailers"] = headerArray(trailers)
        }

        let time = safeNumber(summary.durationMs)
        let timings: [String: Any] = [
            "send": unknownNumber,
            // The whole known duration is attributed to "wait" (time to
            // first byte) rather than split, because this capture layer has
            // no phase breakdown, and the spec requires entry.time to equal
            // the sum of its non -1 timings, so one bucket keeps that true
            // without inventing a split we cannot measure.
            "wait": time,
            "receive": unknownNumber,
        ]

        var entry: [String: Any] = [
            "startedDateTime": dateFormatter.string(from: summary.startedAt ?? Date(timeIntervalSince1970: 0)),
            "time": time,
            "request": request,
            "response": response,
            "cache": [:] as [String: Any],
            "timings": timings,
        ]
        // Per-process attribution (UX spec §6, §11), as HAR custom fields —
        // the spec reserves the `_` prefix for exactly this. The NAME and the
        // PID only: the executable path carries the username and no HAR
        // consumer reads it, so it never leaves the screen. Both are omitted
        // rather than written empty when the session was not attributed, so a
        // reader cannot mistake "" for a process called nothing.
        if let app = summary.app, !app.isEmpty {
            entry["_reqresApp"] = app
        }
        if let pid = summary.pid {
            entry["_reqresPid"] = pid
        }
        // HAR 1.2's own `serverIPAddress` (destination-map UX spec §8.4):
        // the address the proxy connected to, port stripped as the spec
        // defines the field. No custom country field — a reader with the
        // address can resolve it; one without has nothing to be misled by.
        if let address = serverIPAddress(from: detail.serverAddress) {
            entry["serverIPAddress"] = address
        }
        // A relayed connection is not a request: HAR has no entry type for
        // one, so it is written as the CONNECT it was, flagged, with the
        // reason there is nothing inside it. A reader that ignores `_` fields
        // still sees the comment; the byte counts are the tunnel's, each way.
        if summary.isRelay {
            entry["_reqresKind"] = MCPSessionKind.relay.rawValue
            entry["comment"] = RecordedExchangeCopy.relayExplanation(scheme: summary.scheme, pinnedBy: summary.pinnedBy, appName: summary.app)
        }
        // How it ended (protocol PRD 3.4). `_error` is the field Chrome's
        // own HAR export writes for a request that failed (`net::ERR_…`);
        // here it carries the core's one sentence, which names a host, a
        // port or an alert — never content. An aborted or timed-out row keeps
        // whatever status it had (a 200 cut mid-body is still a 200).
        if let facts = summary.failureFacts {
            entry["_error"] = FailureRowCopy.cause(facts)
            entry["_reqresOutcome"] = facts.outcome.token
            if let phase = facts.phase {
                entry["_reqresFailurePhase"] = phase.rawValue
            }
            if facts.clientCancelled {
                entry["_reqresClientCancelled"] = true
            }
        }
        // Where the exchange sat on its connection — a reused one has no
        // DNS/TCP/TLS of its own (HAR's `connection` is the socket id; this
        // is the position, which HAR has no field for).
        if let reused = detail.connectionReused {
            entry["_reqresConnectionReused"] = reused
        }
        if let index = detail.exchangeIndex {
            entry["_reqresExchangeIndex"] = index
        }
        return entry
    }

    /// Chrome's `_webSocketMessages`: `{type: send|receive, time (seconds
    /// since 1970), opcode (1 text, 2 binary, 8 close, 9 ping, 10 pong),
    /// data}` — what Chrome DevTools and Charles read back. Data goes through
    /// `MCPSocketEgress.message` (the agent surface's redaction, uncapped
    /// here: the file's own cap applies); a binary payload is base64 as
    /// Chrome writes it, or withheld while its host is redacted. Anything the
    /// capture did not keep is said in `_reqres…` fields, never silently.
    static func addWebSocketMessages(to entry: inout [String: Any], _ conversation: MCPSocketConversation, redacting: Bool) {
        guard let log = conversation.log else { return }
        var messages: [[String: Any]] = []
        messages.reserveCapacity(log.retainedCount)
        for stored in log.messages {
            let shown = MCPSocketEgress.message(stored, uid: conversation.uid, host: conversation.host, upgradeAt: conversation.upgradeAt,
                                                redacting: redacting, dataMaxBytes: .max)
            var message: [String: Any] = [
                "type": stored.message.direction.isSent ? "send" : "receive",
                "time": stored.message.time,
                "opcode": stored.message.opcode.number,
                "data": shown.data ?? (stored.message.opcode == .close ? closePayloadText(shown) : ""),
            ]
            if shown.dataTruncated { message["_reqresTruncated"] = true }
            if shown.dataTruncated || shown.withheld != nil { message["_reqresSize"] = stored.message.size }
            if let withheld = shown.withheld { message["_reqresWithheld"] = withheld }
            messages.append(message)
        }
        entry["_webSocketMessages"] = messages
        let notKept = log.droppedByApp + log.droppedByExtension
        if notKept > 0 { entry["_reqresWebSocketMessagesNotKept"] = notKept }
        if let close = log.close {
            var summary: [String: Any] = ["end": MCPSocketEgress.closeToken(close.end), "totalMessages": close.totalMessages]
            if let code = close.code { summary["code"] = code }
            if let reason = close.reason, !reason.isEmpty {
                summary["reason"] = redacting ? MCPRedactor.redactStatic(reason, aggressive: true) : reason
            }
            entry["_reqresWebSocketClose"] = summary
        }
    }

    /// A close frame's payload as Chrome shows it: the reason text.
    private static func closePayloadText(_ message: MCPSocketMessage) -> String {
        message.closeReason ?? ""
    }

    /// Marks a body the capture kept only part of: HAR 1.2's own `comment`
    /// on the content / postData object, plus the exact count as a custom
    /// field. Never silent — a truncated `text` with no mark reads as whole.
    private static func markNotRetained(_ object: inout [String: Any], _ notRetained: Int64) {
        guard notRetained > 0 else { return }
        object["_reqresNotRetainedBytes"] = notRetained
        object["comment"] = "Incomplete: ReqRes kept only the first \(RecordedExchangeCopy.binaryBytes(CaptureEngineFacts.retainedBytesPerExchange)) of this exchange's bodies; \(notRetained) bytes of this body as sent are not in this file (the full body was forwarded)."
    }

    /// The core hands a BARE literal; an `ip:port` or `[v6]:port` from any
    /// other source is tolerated by dropping the port. Empty → nil (absent).
    static func serverIPAddress(from address: String?) -> String? {
        guard var text = address?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("[") {
            // [v6]:port or [v6]
            guard let close = text.firstIndex(of: "]") else { return nil }
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":"),
                  text[text.index(after: colon)...].allSatisfy(\.isNumber) {
            // v4:port — one colon followed by digits; a bare v6 has more.
            text = String(text[..<colon])
        }
        return text.isEmpty ? nil : text
    }

    private static func harLog(entries: [[String: Any]], creatorVersion: String, comment: String?) -> [String: Any] {
        var log: [String: Any] = [
            "version": harVersion,
            "creator": ["name": "ReqRes", "version": creatorVersion] as [String: Any],
            "entries": entries,
        ]
        if let comment {
            log["comment"] = comment
        }
        return ["log": log]
    }

    // MARK: - Field helpers

    /// The same entry with its payloads emptied, for the case where one
    /// session alone exceeds the whole budget. Keeping the envelope means a
    /// reader still sees the request that was too big to include.
    private static func entryWithoutBodies(_ entry: [String: Any]) -> [String: Any] {
        var stripped = entry
        for side in ["request", "response"] {
            guard var part = stripped[side] as? [String: Any] else { continue }
            if var content = part["content"] as? [String: Any] {
                content["text"] = ""
                content["comment"] = "Body omitted: this session alone exceeded the export size cap."
                part["content"] = content
            }
            if var postData = part["postData"] as? [String: Any] {
                postData["text"] = ""
                postData["comment"] = "Body omitted: this session alone exceeded the export size cap."
                part["postData"] = postData
            }
            stripped[side] = part
        }
        if let messages = stripped["_webSocketMessages"] as? [Any], !messages.isEmpty {
            stripped["_webSocketMessages"] = [] as [Any]
            stripped["_reqresWebSocketMessagesOmitted"] = messages.count
        }
        return stripped
    }

    private static func headerArray(_ headers: [String: String]) -> [[String: String]] {
        // Swift's Dictionary iteration order is randomized per process, so
        // sorting by name is what makes two encodes of the same input
        // byte-identical, not just internally consistent within one run.
        // Sorting by the lowercased name alone leaves two keys that differ
        // only by case comparing equal, which hands their order back to
        // Dictionary's per-process randomized enumeration. The raw key is the
        // tie-break, matching what MCPSessionDiff does for the same problem.
        //
        // A repeated `Set-Cookie` arrives joined by a newline
        // (`MCPRecordedHeaders` — its values contain commas, so they cannot be
        // comma-joined). HAR lists one entry per header line, so it is split
        // back here; no header value on the wire can contain a line break, so
        // the split is exact. Every other name is already one line.
        headers.sorted { ($0.key.lowercased(), $0.key) < ($1.key.lowercased(), $1.key) }
            .flatMap { name, value -> [[String: String]] in
                guard name.lowercased() == "set-cookie", value.contains("\n") else {
                    return [["name": name, "value": value]]
                }
                return value.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { ["name": name, "value": String($0)] }
            }
    }

    private static func headerValue(_ headers: [String: String], named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func mimeType(from headers: [String: String]) -> String? {
        headerValue(headers, named: "content-type")
    }

    private static func queryItemsArray(from url: String) -> [[String: String]] {
        guard let items = URLComponents(string: url)?.queryItems, !items.isEmpty else { return [] }
        // Order is kept as it appears in the URL (already redacted upstream),
        // matching how every other HAR producer renders queryString.
        return items.map { ["name": $0.name, "value": $0.value ?? ""] }
    }

    /// Guards a Double field against NaN/infinite, which `JSONSerialization`
    /// cannot encode at all; a single bad duration would otherwise fail the
    /// whole export instead of just that one field.
    private static func safeNumber(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return unknownNumber }
        return value
    }

    // MARK: - Serialization

    private static func serializedByteCount(_ object: [String: Any]) -> Int {
        serialize(object)?.count ?? 0
    }

    private static func serialize(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Only reached if `serialize` fails on a fully-assembled log, which
    /// nothing in this file's own construction should ever produce; kept so
    /// a future bug degrades to an honest, valid, empty HAR instead of
    /// throwing away the export silently or crashing on a force-unwrap.
    private static func fallbackEmptyHARData(creatorVersion: String, comment: String) -> Data {
        let log = harLog(entries: [], creatorVersion: creatorVersion, comment: comment)
        return serialize(log) ?? Data()
    }
}
