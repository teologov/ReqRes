//
//  MCPWebSocketModels.swift
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
//  WebSocket messages as an agent reads them: `list_messages` (one
//  connection, paged) and `wait_for_message` (the next matching message after
//  the call). Protocol PRD Phase 4b / decision D17; protocol-engine doc §S7.
//
//  Every preview is captured material. On its way out it goes through the
//  redactor exactly as a body does — JSON by structure, anything else by
//  name and shape — and three rules keep that honest:
//  1. a preview the EXTENSION cut (64 KB, `truncated`) loses its trailing
//     token before redaction: the cut may split a secret, and half a secret
//     has no shape to find (the redact-after-cap class, `bef7f96`);
//  2. real binary is never shown to an agent while its host is redacted —
//     base64 of a protobuf carrying a token defeats every pass;
//  3. `contains` matches the REDACTED text, so a filter can never be used to
//     probe for a value the answer would mask.
//

import Foundation

// MARK: - The seam

/// One WebSocket connection as the bridge sees it: the `101` row it belongs
/// to and its messages (nil when none have arrived).
public struct MCPSocketConversation: Sendable {
    /// The `101` row's session uid.
    public var uid: String
    public var host: String
    public var url: String
    /// When the `101` arrived (seconds since 1970) — the zero of `atMs`.
    public var upgradeAt: Double?
    /// The row is a WebSocket upgrade (a `101` naming `websocket`).
    public var isWebSocket: Bool
    public var log: SocketMessageLog?

    public init(uid: String, host: String, url: String, upgradeAt: Double?, isWebSocket: Bool, log: SocketMessageLog?) {
        self.uid = uid
        self.host = host
        self.url = url
        self.upgradeAt = upgradeAt
        self.isWebSocket = isWebSocket
        self.log = log
    }
}

/// A message found by the feed, with the connection it belongs to.
public struct MCPSocketFeedItem: Sendable {
    public var uid: String
    public var host: String
    public var upgradeAt: Double?
    public var stored: StoredSocketMessage

    public init(uid: String, host: String, upgradeAt: Double?, stored: StoredSocketMessage) {
        self.uid = uid
        self.host = host
        self.upgradeAt = upgradeAt
        self.stored = stored
    }
}

/// What the app hands the feed: messages after an ordinal, across every
/// connection, oldest first, plus the newest ordinal at the time and how far
/// the scan actually got.
public struct MCPSocketFeedRaw: Sendable {
    public var latestOrdinal: Int64
    public var items: [MCPSocketFeedItem]
    /// Every message at or below this ordinal has been looked at: the next
    /// poll starts after it. Less than `latestOrdinal` when the scan stopped
    /// at its limit or at a message whose row is not in the table yet.
    public var scannedThrough: Int64

    /// `scannedThrough` defaults to `latestOrdinal`: a complete scan.
    public init(latestOrdinal: Int64, items: [MCPSocketFeedItem], scannedThrough: Int64? = nil) {
        self.latestOrdinal = latestOrdinal
        self.items = items
        self.scannedThrough = scannedThrough ?? latestOrdinal
    }

    /// Seconds a message may wait for its row before the feed stops waiting
    /// for it (a row that never came, or already left).
    public static let missingRowGrace: TimeInterval = 5

    /// Joins the store's messages (`found`, oldest first, at most
    /// `scanLimit`) to their rows. `row` returns the item for a message whose
    /// row is in the table, nil otherwise.
    ///
    /// - A message whose row is missing and younger than `missingRowGrace`
    ///   stops the scan just BEFORE it: its row lands with the next 150 ms
    ///   flush and the next poll reads it (`wait_for_message` keeps arrival
    ///   order — the earliest match wins).
    /// - One missing for longer is skipped.
    /// - A scan that hit `scanLimit` got only as far as its last message,
    ///   whatever was skipped on the way — never to `latestOrdinal`.
    public static func joining(
        latestOrdinal: Int64,
        after ordinal: Int64,
        found: [(exchangeID: UUID, stored: StoredSocketMessage)],
        scanLimit: Int,
        now: TimeInterval,
        row: (UUID, StoredSocketMessage) -> MCPSocketFeedItem?
    ) -> MCPSocketFeedRaw {
        var items: [MCPSocketFeedItem] = []
        items.reserveCapacity(found.count)
        for entry in found {
            guard let item = row(entry.exchangeID, entry.stored) else {
                if now - entry.stored.message.time > missingRowGrace { continue }
                return MCPSocketFeedRaw(latestOrdinal: latestOrdinal, items: items,
                                        scannedThrough: max(ordinal, entry.stored.ordinal - 1))
            }
            items.append(item)
        }
        let scanned = found.count >= scanLimit ? (found.last?.stored.ordinal ?? ordinal) : latestOrdinal
        return MCPSocketFeedRaw(latestOrdinal: latestOrdinal, items: items, scannedThrough: max(ordinal, scanned))
    }
}

extension MCPSessionProviding {
    /// Default: no WebSocket messages (a provider that predates them).
    public func socketConversation(uid: String) -> MCPSocketConversation? { nil }
    /// Default: nothing, ever.
    public func socketFeed(afterOrdinal ordinal: Int64?, scanLimit: Int) -> MCPSocketFeedRaw { MCPSocketFeedRaw(latestOrdinal: 0, items: []) }
}

// MARK: - Agent-facing types

/// One message, redacted.
public struct MCPSocketMessage: Codable, Equatable, Sendable {
    /// The `101` row's session uid.
    public var uid: String
    /// The connection's host (redacted like a row's host).
    public var host: String
    /// Per connection, 0-based; the Messages tab shows `#seq+1`.
    public var seq: Int64
    /// App-wide arrival number (what `wait_for_message` counts from).
    public var ordinal: Int64
    /// `sent` (by the app) or `received` (from the server).
    public var direction: String
    public var opcode: String
    /// Milliseconds after the upgrade, when known.
    public var atMs: Double?
    /// Seconds since 1970 (its last byte).
    public var time: Double
    public var size: Int64
    public var compressed: Bool
    public var frames: Int
    /// The payload as shown to agents — redacted, at most `dataMaxBytes`.
    /// Nil when withheld (see `withheld`).
    public var data: String?
    /// `json`, `text` or `base64` (binary, only for a host excepted from
    /// redaction); `none` when there is no data.
    public var dataFormat: String
    /// Less than the whole payload: the extension kept only 64 KB, or the
    /// agent cap cut it.
    public var dataTruncated: Bool
    /// Why `data` is absent — ReqRes's own words, never captured material.
    public var withheld: String?
    public var closeCode: Int?
    public var closeReason: String?

    public init(uid: String, host: String, seq: Int64, ordinal: Int64, direction: String, opcode: String, atMs: Double?, time: Double,
                size: Int64, compressed: Bool, frames: Int, data: String?, dataFormat: String, dataTruncated: Bool,
                withheld: String?, closeCode: Int?, closeReason: String?) {
        self.uid = uid
        self.host = host
        self.seq = seq
        self.ordinal = ordinal
        self.direction = direction
        self.opcode = opcode
        self.atMs = atMs
        self.time = time
        self.size = size
        self.compressed = compressed
        self.frames = frames
        self.data = data
        self.dataFormat = dataFormat
        self.dataTruncated = dataTruncated
        self.withheld = withheld
        self.closeCode = closeCode
        self.closeReason = closeReason
    }
}

public struct MCPSocketClose: Codable, Equatable, Sendable {
    /// `close_handshake`, `close_frame`, `connection_dropped`, `idle_timeout`.
    public var end: String
    public var code: Int?
    public var reason: String?
    public var initiatedBy: String?
    public var totalMessages: Int64
    public var bytesFromClient: Int64
    public var bytesFromServer: Int64
}

/// A connection's facts, with every page.
public struct MCPSocketConnection: Codable, Equatable, Sendable {
    public var uid: String
    public var host: String
    public var url: String
    public var open: Bool
    /// Messages that reached the app.
    public var messages: Int64
    public var sent: Int64
    public var received: Int64
    /// Kept now (the first 200 and the last 2,000).
    public var kept: Int
    /// Let go by the app's retention (D10) or its app-wide bound.
    public var notKeptByApp: Int64
    /// Dropped in the extension because the app fell behind.
    public var droppedBeforeTheApp: Int64
    public var lostBatches: Int
    /// The `101`'s `Sec-WebSocket-Extensions`.
    public var extensions: String?
    /// A direction the extension stopped reading, in ReqRes's words.
    public var stoppedReading: [String]
    public var close: MCPSocketClose?
}

public struct MCPSocketMessagePage: Codable, Equatable, Sendable {
    public var connection: MCPSocketConnection
    public var messages: [MCPSocketMessage]
    /// Pass back as `cursor` for the next page (the last `seq` returned).
    public var nextCursor: String?
    /// Kept messages matching the filter, from the cursor on.
    public var totalMatched: Int
    public var note: String?
}

/// `GET /v1/messages`: what `wait_for_message` polls.
public struct MCPSocketFeed: Codable, Equatable, Sendable {
    /// The newest ordinal handed out when this answer was made.
    public var latestOrdinal: Int64
    /// Every message up to here was looked at; poll again from it.
    public var scannedThrough: Int64
    /// Matches after the requested ordinal, oldest first.
    public var messages: [MCPSocketMessage]
}

// MARK: - Filters

public struct MCPMessageFilter: Equatable, Sendable {
    public var uid: String?
    public var host: String?
    public var direction: SocketDirection?
    public var opcode: SocketOpcode?
    public var contains: String?

    public init(uid: String? = nil, host: String? = nil, direction: SocketDirection? = nil, opcode: SocketOpcode? = nil, contains: String? = nil) {
        self.uid = uid?.isEmpty == true ? nil : uid
        self.host = host?.isEmpty == true ? nil : host
        self.direction = direction
        self.opcode = opcode
        self.contains = contains?.isEmpty == true ? nil : contains
    }

    /// From a bridge query string. An unknown `direction` or `opcode` is
    /// REFUSED: a dropped filter hands back an unfiltered answer that reads
    /// as a filtered one.
    public init(queryItems items: [URLQueryItem]) throws {
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        var direction: SocketDirection?
        if let raw = value("direction") {
            guard let parsed = SocketDirection.parse(raw) else {
                throw MCPQueryParameterError(parameter: "direction", message: "Unknown direction '\(raw)'. Use sent (by the app) or received (from the server).")
            }
            direction = parsed
        }
        var opcode: SocketOpcode?
        if let raw = value("opcode") {
            guard let parsed = SocketOpcode.parse(raw) else {
                throw MCPQueryParameterError(parameter: "opcode", message: "Unknown opcode '\(raw)'. Use one of \(SocketOpcode.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            opcode = parsed
        }
        self.init(uid: value("uid"), host: value("host"), direction: direction, opcode: opcode, contains: value("contains"))
    }

    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let uid { items.append(URLQueryItem(name: "uid", value: uid)) }
        if let host { items.append(URLQueryItem(name: "host", value: host)) }
        if let direction { items.append(URLQueryItem(name: "direction", value: direction.agentToken)) }
        if let opcode { items.append(URLQueryItem(name: "opcode", value: opcode.rawValue)) }
        if let contains { items.append(URLQueryItem(name: "contains", value: contains)) }
        return items
    }

    /// Against the message as an agent would see it (redacted): `contains`
    /// can only find what the answer would show.
    public func matches(_ message: MCPSocketMessage, rawHost: String) -> Bool {
        if let uid, message.uid != uid { return false }
        if let host, rawHost.range(of: host, options: .caseInsensitive) == nil { return false }
        if let direction, message.direction != direction.agentToken { return false }
        if let opcode, message.opcode != opcode.rawValue { return false }
        if let contains {
            let found = [message.data, message.closeReason].contains { $0?.range(of: contains, options: .caseInsensitive) != nil }
            if !found { return false }
        }
        return true
    }

    public var summaryText: String {
        var parts: [String] = []
        if let uid { parts.append("session \(uid)") }
        if let host { parts.append("host~\(host)") }
        if let direction { parts.append(direction.agentToken) }
        if let opcode { parts.append(opcode.rawValue) }
        if let contains { parts.append("containing \"\(contains)\"") }
        return parts.isEmpty ? "any WebSocket message" : parts.joined(separator: ", ")
    }
}

// MARK: - Egress

public enum MCPSocketEgress {
    public static let defaultPageSize = 50
    public static let maxPageSize = 200
    /// Per message on the agent surface; the Messages tab has the rest.
    public static let dataMaxBytes = 4_096
    /// How many messages one feed poll looks at.
    public static let feedScanLimit = 5_000

    public static let binaryWithheld = "binary payload not shown to agents while this host is redacted (it cannot be checked for credentials); the Messages tab in ReqRes shows it"
    public static let unreadable = "the preview could not be decoded"

    /// One message on its way out.
    public static func message(_ stored: StoredSocketMessage, uid: String, host: String, upgradeAt: Double?,
                               redacting: Bool, dataMaxBytes: Int = dataMaxBytes) -> MCPSocketMessage {
        let m = stored.message
        var data: String?
        var format = "none"
        var truncated = m.truncated
        var withheld: String?
        switch m.opcode {
        case .close:
            break
        default:
            if let text = m.previewText {
                if !text.isEmpty {
                    let shown: (text: String, json: Bool) = redacting ? redactText(text, cut: m.truncated) : (text, isJSON(text) && !m.truncated)
                    data = shown.text
                    format = shown.json ? "json" : "text"
                }
            } else if redacting {
                withheld = m.previewData == nil ? unreadable : binaryWithheld
            } else if m.previewData != nil {
                data = m.previewEncoding == .base64 ? m.preview : m.previewData?.base64EncodedString()
                format = "base64"
            } else {
                withheld = unreadable
            }
        }
        if let text = data {
            let capped = MCPSessionQuery.cappedPreview(text, maxBytes: dataMaxBytes)
            data = capped.preview
            truncated = truncated || capped.truncated
        }
        let reason = m.closeReason.map { redacting ? MCPRedactor.redactStatic($0, aggressive: true) : $0 }
        return MCPSocketMessage(
            uid: uid,
            host: redacting ? MCPRedactor.redactStatic(host, aggressive: false) : host,
            seq: m.seq,
            ordinal: stored.ordinal,
            direction: m.direction.agentToken,
            opcode: m.opcode.rawValue,
            atMs: SocketMessagePresentation.offsetMilliseconds(m.time, from: upgradeAt),
            time: m.time,
            size: m.size,
            compressed: m.compressed,
            frames: m.frames,
            data: data,
            dataFormat: format,
            dataTruncated: truncated,
            withheld: withheld,
            closeCode: m.closeCode,
            closeReason: reason
        )
    }

    /// Redacts one message's text. A whole JSON message is redacted by
    /// structure (and re-encoded compactly, keys sorted); anything else by
    /// name (lenient, for JSON that does not parse), then form, markup and
    /// shape (`MCPRedactor.redactBody`). A preview the extension CUT first
    /// loses its trailing token (`withholdingTrailingToken`).
    static func redactText(_ text: String, cut: Bool) -> (text: String, json: Bool) {
        let redactor = MCPRedactor()
        if !cut, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
           !(object is String), let compact = MCPStreamEgress.compactJSON(MCPRedactor.redactJSON(object)) {
            return (compact, true)
        }
        let material = cut ? withholdingTrailingToken(text) : text
        return (redactor.redactBody(MCPRedactor.redactPartialJSONByName(material)), false)
    }

    /// Cuts a truncated preview back to the last separator (whitespace, or
    /// one of `,;:&=?/{}[]()"'<>`) and marks the cut. What was there may have
    /// been the first half of a secret that no shape pass can recognise.
    static func withholdingTrailingToken(_ text: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:&=?/{}[]()\"'<>"))
        guard let last = text.unicodeScalars.lastIndex(where: { separators.contains($0) }) else {
            return "…"
        }
        let kept = String(text.unicodeScalars[...last])
        return kept + "…"
    }

    static func isJSON(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first, first == "{" || first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    public static func connection(_ conversation: MCPSocketConversation, redacting: Bool) -> MCPSocketConnection {
        let log = conversation.log
        let close = log?.close.map { close in
            MCPSocketClose(
                end: closeToken(close.end),
                code: close.code,
                reason: close.reason.map { redacting ? MCPRedactor.redactStatic($0, aggressive: true) : $0 },
                initiatedBy: close.initiatedBy?.agentToken,
                totalMessages: close.totalMessages,
                bytesFromClient: close.bytesFromClient,
                bytesFromServer: close.bytesFromServer
            )
        }
        return MCPSocketConnection(
            uid: conversation.uid,
            host: redacting ? MCPRedactor.redactStatic(conversation.host, aggressive: false) : conversation.host,
            url: redacting ? MCPRedactor(enabled: true).redactURL(conversation.url) : conversation.url,
            open: !(log?.isFinal ?? false),
            messages: log?.received ?? 0,
            sent: log?.sentCount ?? 0,
            received: log?.receivedCount ?? 0,
            kept: log?.retainedCount ?? 0,
            notKeptByApp: log?.droppedByApp ?? 0,
            droppedBeforeTheApp: log?.droppedByExtension ?? 0,
            lostBatches: log?.lostBatches ?? 0,
            extensions: log?.extensions.map { redacting ? MCPRedactor.redactStatic($0, aggressive: true) : $0 },
            stoppedReading: (log?.gaveUp ?? []).map(SocketMessagePresentation.gaveUpLine),
            close: close
        )
    }

    static func closeToken(_ end: SocketEnd) -> String {
        switch end {
        case .closeHandshake: return "close_handshake"
        case .closeFrame: return "close_frame"
        case .connectionDropped: return "connection_dropped"
        case .idleTimeout: return "idle_timeout"
        }
    }

    /// `list_messages`: one connection's kept messages after `cursor` (a
    /// `seq`), filtered, oldest first.
    public static func page(_ conversation: MCPSocketConversation, filter: MCPMessageFilter, cursor: String?, limit: Int?,
                            redacting: Bool) -> MCPSocketMessagePage {
        let size = min(max(1, limit ?? defaultPageSize), maxPageSize)
        let after = cursor.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? -1
        let kept = conversation.log?.messages(afterSeq: after) ?? []
        var matched: [MCPSocketMessage] = []
        for stored in kept {
            let shown = message(stored, uid: conversation.uid, host: conversation.host, upgradeAt: conversation.upgradeAt, redacting: redacting)
            if filter.matches(shown, rawHost: conversation.host) { matched.append(shown) }
        }
        let pageItems = Array(matched.prefix(size))
        let next = matched.count > size ? pageItems.last.map { String($0.seq) } : nil
        var note: String?
        if conversation.log == nil || conversation.log?.received == 0 {
            note = conversation.log?.isFinal == true
                ? "This connection closed without any messages."
                : "No messages yet. Call wait_for_message with this uid to be told of the next one."
        }
        return MCPSocketMessagePage(
            connection: connection(conversation, redacting: redacting),
            messages: pageItems,
            nextCursor: next,
            totalMatched: matched.count,
            note: note
        )
    }

    /// `wait_for_message`'s poll: matches among the messages after `ordinal`.
    public static func feed(_ raw: MCPSocketFeedRaw, after ordinal: Int64, filter: MCPMessageFilter, limit: Int,
                            redacts: (String) -> Bool) -> MCPSocketFeed {
        var matched: [MCPSocketMessage] = []
        for item in raw.items where item.stored.ordinal > ordinal {
            let shown = message(item.stored, uid: item.uid, host: item.host, upgradeAt: item.upgradeAt, redacting: redacts(item.host))
            if filter.matches(shown, rawHost: item.host) {
                matched.append(shown)
                if matched.count >= limit { break }
            }
        }
        // Everything scanned is behind us — as far as the provider says the
        // scan got, which is not `latestOrdinal` when it stopped at its limit
        // or before a message whose row has not landed.
        let scanned = raw.scannedThrough
        let through = matched.count >= limit ? (matched.last?.ordinal ?? scanned) : scanned
        return MCPSocketFeed(latestOrdinal: raw.latestOrdinal, scannedThrough: max(ordinal, through), messages: matched)
    }
}

// MARK: - The wait

/// "Tell me when the server sends `transcript.final`": waits for the first
/// matching message that ARRIVES AFTER the call — a message already captured
/// never satisfies it, exactly like `wait_for_session`'s baseline. Polls
/// client-side so the bridge stays synchronous; time and fetching are
/// injected for the tests.
public enum MCPMessageWaiter {
    public struct Outcome: Equatable {
        public var message: MCPSocketMessage?
        public var timedOut: Bool
        public var polls: Int

        public init(message: MCPSocketMessage?, timedOut: Bool, polls: Int) {
            self.message = message
            self.timedOut = timedOut
            self.polls = polls
        }
    }

    public static let defaultTimeout: TimeInterval = 30
    public static let maxTimeout: TimeInterval = 300
    public static let defaultPollInterval: TimeInterval = 0.5

    /// - Parameter fetch: `nil` asks only for the newest ordinal (the
    ///   baseline); an ordinal asks for matches after it.
    public static func wait(
        timeout: TimeInterval = defaultTimeout,
        pollInterval: TimeInterval = defaultPollInterval,
        fetch: (Int64?) async throws -> MCPSocketFeed,
        elapsed: () -> TimeInterval,
        sleep: (TimeInterval) async throws -> Void
    ) async throws -> Outcome {
        let budget = min(max(timeout, 0), maxTimeout)
        var since = try await fetch(nil).latestOrdinal
        var polls = 1
        while elapsed() < budget {
            try await sleep(pollInterval)
            let feed = try await fetch(since)
            polls += 1
            if let first = feed.messages.first(where: { $0.ordinal > since }) {
                return Outcome(message: first, timedOut: false, polls: polls)
            }
            since = max(since, feed.scannedThrough)
        }
        return Outcome(message: nil, timedOut: true, polls: polls)
    }
}

// MARK: - Text for the tools

extension MCPTextFormat {
    /// `list_messages`.
    public static func socketMessages(_ page: MCPSocketMessagePage) -> String {
        var lines = socketConnectionLines(page.connection)
        if let note = page.note { lines.append(note) }
        guard !page.messages.isEmpty else {
            if page.note == nil { lines.append("No kept messages match.") }
            return lines.joined(separator: "\n")
        }
        lines.append("")
        var previous: Int64?
        for message in page.messages {
            if let previous, message.seq > previous + 1 {
                lines.append("  … \(SocketMessagePresentation.gapLine(message.seq - previous - 1)) (or filtered out)")
            }
            lines.append(contentsOf: socketMessageLines(message, showUID: false))
            previous = message.seq
        }
        if let next = page.nextCursor {
            lines.append("")
            lines.append("More: \(page.totalMatched - page.messages.count) further matches — call list_messages again with cursor=\(next).")
        }
        return lines.joined(separator: "\n")
    }

    /// `wait_for_message`.
    public static func messageWait(_ outcome: MCPMessageWaiter.Outcome, timeout: TimeInterval, filter: MCPMessageFilter) -> String {
        guard let message = outcome.message else {
            return "No new WebSocket message matching \(filter.summaryText) arrived within \(Int(timeout))s. Messages captured before the call are ignored; a WebSocket opened while capture was off, or through a host that is excluded, has none."
        }
        var lines = ["New WebSocket message on session \(message.uid) (\(message.host)):"]
        lines.append(contentsOf: socketMessageLines(message, showUID: false))
        lines.append("")
        lines.append("The rest of the conversation: list_messages uid=\(message.uid) cursor=\(message.seq) for what came after it.")
        return lines.joined(separator: "\n")
    }

    static func socketConnectionLines(_ c: MCPSocketConnection) -> [String] {
        var lines = ["WebSocket \(c.uid) · \(c.url)"]
        var facts = ["\(c.messages) messages (\(c.sent) sent, \(c.received) received)", "\(c.kept) kept", c.open ? "open" : "closed"]
        if let extensions = c.extensions, !extensions.isEmpty { facts.append("extensions: \(extensions)") }
        lines.append(facts.joined(separator: " · "))
        var notKept: [String] = []
        if c.notKeptByApp > 0 { notKept.append("\(c.notKeptByApp) let go by ReqRes (it keeps the first \(SocketMessageLog.headCapacity) and last \(SocketMessageLog.tailCapacity) per connection)") }
        if c.droppedBeforeTheApp > 0 { notKept.append("\(c.droppedBeforeTheApp) dropped before reaching the app") }
        if c.lostBatches > 0 { notKept.append("\(c.lostBatches) batches lost") }
        if !notKept.isEmpty { lines.append("Not kept: " + notKept.joined(separator: "; ")) }
        lines.append(contentsOf: c.stoppedReading)
        if let close = c.close {
            var line = "Closed: \(close.end)"
            if let code = close.code { line += " \(code)" + (SocketMessagePresentation.closeCodeName(code).map { " (\($0))" } ?? "") }
            if let reason = close.reason, !reason.isEmpty { line += " \"\(reason)\"" }
            if let by = close.initiatedBy { line += ", first by the \(by == "sent" ? "app" : "server")" }
            lines.append(line)
        }
        return lines
    }

    static func socketMessageLines(_ m: MCPSocketMessage, showUID: Bool) -> [String] {
        var head = "#\(m.seq + 1) \(m.direction == "sent" ? "↑ sent" : "↓ received") \(m.opcode)"
        if let at = m.atMs { head += " +\(SocketMessagePresentation.groupedInteger(Int64(at.rounded())))ms" }
        head += " \(m.size)B"
        if m.compressed { head += " compressed" }
        if m.frames > 1 { head += " \(m.frames) frames" }
        if showUID { head += " uid=\(m.uid)" }
        var lines = [head]
        if m.opcode == SocketOpcode.close.rawValue {
            lines.append("  " + SocketMessagePresentation.closeFrameText(code: m.closeCode, reason: m.closeReason))
        } else if let data = m.data {
            lines.append("  " + data + (m.dataTruncated && !data.hasSuffix(MCPLimits.truncationMarker) ? " [preview cut; the message was \(m.size) bytes]" : ""))
        } else if let withheld = m.withheld {
            lines.append("  (\(withheld))")
        } else {
            lines.append("  (empty)")
        }
        return lines
    }
}
