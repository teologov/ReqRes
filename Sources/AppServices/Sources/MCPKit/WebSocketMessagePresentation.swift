//
//  WebSocketMessagePresentation.swift
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
//  Every word and number the Messages tab shows (protocol-engine doc §S7),
//  kept here so it is tested and so the view only lays it out. For people:
//  nothing here redacts — the Messages tab is the user's own traffic on the
//  user's own screen, like every other detail tab. Agents read the
//  redacted copy (`MCPSocketEgress`).
//

import Foundation

public enum SocketMessagePresentation {
    // MARK: Which rows have messages

    /// A `101 Switching Protocols` whose response names `websocket` in
    /// `Upgrade` — the rows the core taps (doc §C11.2). An `h2c` upgrade is a
    /// 101 too, and has no messages.
    ///
    /// `responseHeaders` is an autoclosure ON PURPOSE: callers pass a parse of
    /// the row's recorded headers, and this runs for every row on paths that
    /// run constantly (the protocol classification behind every agent list and
    /// wait poll, and every flush while a `proto:` chip is set). Only a `101`
    /// may pay for that parse (protocol-engine doc §S9.2).
    public static func isWebSocketUpgrade(status: String?, responseHeaders: @autoclosure () -> [String: String]) -> Bool {
        guard status?.trimmingCharacters(in: .whitespaces) == "101" else { return false }
        return responseHeaders().contains { name, value in
            name.caseInsensitiveCompare("upgrade") == .orderedSame
                && value.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "websocket" }
        }
    }

    // MARK: One line per message

    /// SF Symbol for the direction; always shown WITH `directionWord`.
    public static func directionSymbol(_ direction: SocketDirection) -> String {
        direction.isSent ? "arrow.up" : "arrow.down"
    }

    public static func directionWord(_ direction: SocketDirection) -> String {
        direction.isSent ? "Sent" : "Received"
    }

    public static func opcodeWord(_ opcode: SocketOpcode) -> String { opcode.rawValue }

    /// Time since the upgrade, in milliseconds: "+0 ms", "+1,240 ms". Nil
    /// when there is no upgrade time to measure from.
    public static func offset(_ time: Double, from upgrade: Double?) -> String? {
        guard let upgrade, upgrade > 0, time > 0 else { return nil }
        let ms = max(0, (time - upgrade) * 1000)
        return "+" + groupedInteger(Int64(ms.rounded())) + " ms"
    }

    /// Milliseconds since the upgrade, for agents and HAR consumers.
    public static func offsetMilliseconds(_ time: Double, from upgrade: Double?) -> Double? {
        guard let upgrade, upgrade > 0, time > 0 else { return nil }
        return max(0, ((time - upgrade) * 1000 * 10).rounded() / 10)
    }

    public static func size(_ bytes: Int64) -> String { RecordedExchangeCopy.binaryBytes(bytes) }

    /// The row's one-line preview: text with its whitespace folded; a close's
    /// code and reason; binary as its first bytes in hex.
    public static func oneLine(_ message: SocketMessage, maxCharacters: Int = 160) -> String {
        switch message.opcode {
        case .close:
            return closeFrameText(code: message.closeCode, reason: message.closeReason)
        default:
            if let text = message.previewText {
                let folded = fold(text)
                if folded.isEmpty { return message.size == 0 ? "(empty)" : "" }
                return folded.count > maxCharacters ? String(folded.prefix(maxCharacters)) + "…" : folded
            }
            guard let data = message.previewData else { return "(unreadable preview)" }
            let bytes = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            return data.count > 16 ? bytes + " …" : bytes
        }
    }

    // MARK: A message, whole

    public enum BodyKind: Equatable, Sendable {
        case json
        case text
        case hex
        case empty
    }

    /// The selected message shown whole: JSON pretty-printed, text as text,
    /// binary as a hex dump. Only what the extension kept (64 KB) exists;
    /// `truncatedNote` says so when there was more.
    public static func body(_ message: SocketMessage) -> (kind: BodyKind, text: String) {
        if message.opcode == .close {
            return (.text, closeFrameText(code: message.closeCode, reason: message.closeReason))
        }
        if let text = message.previewText {
            if text.isEmpty { return (.empty, "This message has no payload.") }
            if !message.truncated, let pretty = prettyJSON(text) { return (.json, pretty) }
            return (.text, text)
        }
        guard let data = message.previewData else { return (.text, "The preview could not be decoded.") }
        if data.isEmpty { return (.empty, "This message has no payload.") }
        return (.hex, hexDump(data))
    }

    /// Said under a message whose preview is shorter than the message.
    public static func truncatedNote(_ message: SocketMessage) -> String? {
        guard message.truncated else { return nil }
        let kept = message.previewData.map { Int64($0.count) } ?? 0
        return "ReqRes kept the first \(size(kept)) of this \(size(message.size)) message; the whole message was forwarded."
    }

    /// Facts under the whole message: frames, compression.
    public static func detailFacts(_ message: SocketMessage) -> String {
        var parts = ["\(directionWord(message.direction)) \(opcodeWord(message.opcode))", size(message.size)]
        if message.compressed { parts.append("compressed to \(size(message.wireSize)) on the wire") }
        if message.frames > 1 { parts.append("\(message.frames) frames") }
        parts.append("#\(message.seq + 1)")
        return parts.joined(separator: " · ")
    }

    static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let pretty = String(data: data, encoding: .utf8) else { return nil }
        return pretty
    }

    /// `00000000  48 65 6c 6c 6f 20 77 6f  72 6c 64 21 0a 00 ff fe  |Hello world!....|` (hexdump -C's layout)
    public static func hexDump(_ data: Data, bytesPerLine: Int = 16, maxBytes: Int = 64 * 1024) -> String {
        let bytes = [UInt8](data.prefix(maxBytes))
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / bytesPerLine + 1)
        var offset = 0
        while offset < bytes.count {
            let row = bytes[offset..<min(offset + bytesPerLine, bytes.count)]
            var hex = ""
            for (i, byte) in row.enumerated() {
                if i == bytesPerLine / 2 { hex += " " }
                hex += String(format: "%02x ", byte)
            }
            let width = bytesPerLine * 3 + 1
            hex = hex.padding(toLength: width, withPad: " ", startingAt: 0)
            let ascii = String(row.map { $0 >= 0x20 && $0 < 0x7f ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset) + hex + " |" + ascii + "|")
            offset += bytesPerLine
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Gaps, the close, the tap

    /// One line of the list: a message, or the messages not kept before it.
    public enum Item: Equatable, Sendable, Identifiable {
        case message(StoredSocketMessage)
        /// `count` messages were not kept; `beforeSeq` is the seq of the
        /// message after the gap (or the total for a gap at the end).
        case gap(count: Int64, beforeSeq: Int64)

        public var id: String {
            switch self {
            case .message(let stored): return "m\(stored.message.seq)"
            case .gap(_, let before): return "g\(before)"
            }
        }
    }

    /// The list: every kept message in order, and a gap line wherever `seq`
    /// jumps — whoever let them go (this app's ring, the extension falling
    /// behind, a lost batch). At the end, the messages the close counted
    /// that never arrived.
    public static func items(_ messages: [StoredSocketMessage], close: SocketClose? = nil) -> [Item] {
        var items: [Item] = []
        items.reserveCapacity(messages.count + 2)
        var expected: Int64 = 0
        for stored in messages {
            let seq = stored.message.seq
            if seq > expected { items.append(.gap(count: seq - expected, beforeSeq: seq)) }
            items.append(.message(stored))
            expected = max(expected, seq + 1)
        }
        if let total = close?.totalMessages, total > expected {
            items.append(.gap(count: total - expected, beforeSeq: total))
        }
        return items
    }

    public static func gapLine(_ count: Int64) -> String {
        "\(groupedInteger(count)) \(count == 1 ? "message" : "messages") not kept"
    }

    /// What the gap lines add up to, and why — under the list.
    public static func retentionLine(_ log: SocketMessageLog) -> String? {
        var parts: [String] = []
        if log.droppedByApp > 0 {
            parts.append("\(groupedInteger(log.droppedByApp)) let go by ReqRes, which keeps the first \(SocketMessageLog.headCapacity) and the last \(groupedInteger(Int64(SocketMessageLog.tailCapacity))) messages of a connection")
        }
        if log.droppedByExtension > 0 {
            parts.append("\(groupedInteger(log.droppedByExtension)) dropped before reaching the app (it fell behind)")
        }
        if log.lostBatches > 0 {
            parts.append("\(log.lostBatches) \(log.lostBatches == 1 ? "batch" : "batches") of messages lost on the way to the app")
        }
        guard !parts.isEmpty else { return nil }
        return "Not kept: " + parts.joined(separator: "; ") + "."
    }

    /// The last line: how the connection ended.
    public static func closeLine(_ close: SocketClose) -> String {
        var line: String
        switch close.end {
        case .closeHandshake:
            line = "Closed cleanly: both sides sent a close frame"
        case .closeFrame:
            line = "Closed: one side sent a close frame"
        case .connectionDropped:
            line = "The connection dropped without a close frame"
        case .idleTimeout:
            line = "Closed by ReqRes after 10 minutes with no data either way"
        }
        if let by = close.initiatedBy, close.end != .connectionDropped, close.end != .idleTimeout {
            line += by.isSent ? ", first by the app" : ", first by the server"
        }
        if close.code != nil || !(close.reason ?? "").isEmpty {
            line += " — " + closeFrameText(code: close.code, reason: close.reason)
        }
        return line + "."
    }

    /// "1000 Normal closure “bye now”".
    public static func closeFrameText(code: Int?, reason: String?) -> String {
        var parts: [String] = []
        if let code {
            parts.append(closeCodeName(code).map { "\(code) \($0)" } ?? "\(code)")
        } else {
            parts.append("no status code")
        }
        if let reason, !reason.isEmpty { parts.append("“\(reason)”") }
        return parts.joined(separator: " ")
    }

    /// RFC 6455 §7.4.1 and the IANA registry's common codes.
    public static func closeCodeName(_ code: Int) -> String? {
        switch code {
        case 1000: return "Normal closure"
        case 1001: return "Going away"
        case 1002: return "Protocol error"
        case 1003: return "Unsupported data"
        case 1005: return "No status received"
        case 1006: return "Abnormal closure"
        case 1007: return "Invalid payload data"
        case 1008: return "Policy violation"
        case 1009: return "Message too big"
        case 1010: return "Mandatory extension"
        case 1011: return "Internal error"
        case 1012: return "Service restart"
        case 1013: return "Try again later"
        case 1014: return "Bad gateway"
        case 1015: return "TLS handshake failure"
        default: return nil
        }
    }

    /// A direction the extension stopped reading (doc §C11.2 "Gave up").
    public static func gaveUpLine(_ issue: SocketTapIssue) -> String {
        let who = issue.direction.isSent ? "the app's messages" : "the server's messages"
        let reason = issue.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return "ReqRes stopped reading \(who)\(reason.isEmpty ? "" : ": \(reason)"). The connection is unaffected — its bytes still flow."
    }

    /// The header above the list.
    public static func summary(_ log: SocketMessageLog?) -> String {
        guard let log, log.received > 0 else {
            return log?.isFinal == true ? "No messages were sent on this connection." : "No messages yet."
        }
        var parts = ["\(groupedInteger(log.received)) \(log.received == 1 ? "message" : "messages")"]
        parts.append("↑ \(groupedInteger(log.sentCount)) sent (\(size(log.sentBytes)))")
        parts.append("↓ \(groupedInteger(log.receivedCount)) received (\(size(log.receivedBytes)))")
        parts.append(log.isFinal ? "closed" : "open")
        return parts.joined(separator: " · ")
    }

    // MARK: Search and VoiceOver

    /// Case-insensitive search over what a row shows: the preview's text (or
    /// its hex), the opcode, the direction word and a close reason.
    /// What the list shows for a search: every item when the query is
    /// blank; otherwise the messages that match it (gap lines only make
    /// sense between neighbours, so a search shows none).
    public static func shown(_ items: [Item], query: String) -> [Item] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            if case .message(let stored) = item { return matches(stored.message, query: needle) }
            return false
        }
    }

    /// `shown`, remembered between pulls: a message's answer for the current
    /// query is kept by its ordinal, so a pull that adds k messages tests k
    /// of them rather than every kept message again (up to 2,200, each a
    /// case- and diacritic-insensitive search over up to 64 KB, on main,
    /// every 150 ms — release review, 2026-09-29). A new query starts over;
    /// ordinals no longer in the log are forgotten.
    public struct IncrementalSearch: Sendable {
        public private(set) var query = ""
        private var answers: [Int64: Bool] = [:]
        /// How many messages `shown` tested, for the tests.
        public private(set) var tested = 0

        public init(query: String = "") {
            self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public mutating func setQuery(_ newQuery: String) {
            let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != query else { return }
            // Typing on: a message that did not contain "abc" cannot contain
            // "abcd", so its "no" stands and only the "yes" ones are asked
            // again.
            let narrows = !query.isEmpty
                && trimmed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            query = trimmed
            if narrows {
                answers = answers.filter { !$0.value }
            } else {
                answers.removeAll(keepingCapacity: true)
            }
        }

        public mutating func shown(_ items: [Item]) -> [Item] {
            guard !query.isEmpty else {
                answers.removeAll()
                return items
            }
            var kept: [Int64: Bool] = [:]
            kept.reserveCapacity(answers.count + 16)
            var result: [Item] = []
            for item in items {
                guard case .message(let stored) = item else { continue }
                let answer: Bool
                if let known = answers[stored.ordinal] {
                    answer = known
                } else {
                    answer = SocketMessagePresentation.matches(stored.message, query: query)
                    tested += 1
                }
                kept[stored.ordinal] = answer
                if answer { result.append(item) }
            }
            answers = kept
            return result
        }
    }

    public static func matches(_ message: SocketMessage, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystacks: [String?] = [
            message.previewText,
            message.previewText == nil ? oneLine(message, maxCharacters: .max) : nil,
            message.closeReason,
            message.opcode.rawValue,
            directionWord(message.direction),
        ]
        return haystacks.contains { $0?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    public static func accessibilityLabel(_ message: SocketMessage, upgrade: Double?) -> String {
        var parts = [directionWord(message.direction), message.opcode.rawValue, size(message.size)]
        if let offset = offsetMilliseconds(message.time, from: upgrade) {
            parts.append("\(groupedInteger(Int64(offset.rounded()))) milliseconds after the upgrade")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Helpers

    static func fold(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    public static func groupedInteger(_ value: Int64) -> String {
        let digits = String(abs(value))
        var result = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { result.append(",") }
            result.append(ch)
        }
        return (value < 0 ? "-" : "") + String(result.reversed())
    }
}
