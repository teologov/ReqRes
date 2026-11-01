//
//  SSEParser.swift
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

import Foundation

/// Server-sent events, parsed the way a browser's `EventSource` parses them
/// (WHATWG HTML §9.2.6 "Interpreting an event stream"), incrementally.
///
/// Why bytes and not a `String`: a chunk boundary can fall inside a UTF-8
/// sequence, inside the BOM, or between the CR and LF of one line ending.
/// CR (0x0D) and LF (0x0A) are never part of a multi-byte UTF-8 sequence, so
/// splitting LINES on bytes and decoding each COMPLETE line is exact whatever
/// the chunking — which is the property the tests feed every split point to.
///
/// What the spec says, and this does:
/// - one leading U+FEFF (EF BB BF) is ignored, only at the very start;
/// - a line ends at CRLF, LF or CR (a CR whose LF arrives in the next chunk
///   is still ONE line ending);
/// - a blank line dispatches; a line starting with `:` is a comment;
/// - `field:value` with ONE leading space stripped from the value; a line
///   with no colon is a field with an empty value;
/// - `data` appends value + LF; `event` sets the type; `id` sets the last
///   event id unless the value contains NUL (and it PERSISTS across events);
///   `retry` sets the reconnection time only when it is ASCII digits;
///   every other field is ignored;
/// - a block whose data buffer is empty dispatches nothing (but resets the
///   type); the trailing LF of the data is removed on dispatch;
/// - at the end of the stream an undispatched event is DISCARDED. Here it is
///   reported as `pendingByteCount` instead of silently vanishing, because a
///   withheld fragment is a fact the reader should see ("N bytes pending").
///
/// Invalid UTF-8 decodes with U+FFFD, as the spec's UTF-8 decode does.
public struct SSEParser: Sendable {
    /// One dispatched event.
    public struct Event: Equatable, Sendable {
        /// The `event` field, or nil when none was sent (the spec's type is
        /// then "message" — `type` says so).
        public var name: String?
        public var data: String
        /// The last event id AT DISPATCH — it persists across events, per the
        /// spec (it is what a reconnecting client would send). Nil when empty.
        public var id: String?
        /// A `retry` field seen in THIS event's block, if any.
        public var retry: Int?
        /// UTF-8 byte offsets in the stream (BOM included) of the event's first
        /// line and of the end of the blank line that dispatched it.
        public var byteRange: Range<Int>

        public var type: String { name ?? "message" }

        public init(name: String?, data: String, id: String?, retry: Int?, byteRange: Range<Int>) {
            self.name = name
            self.data = data
            self.id = id
            self.retry = retry
            self.byteRange = byteRange
        }
    }

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A

    /// nil once the BOM question is settled; the bytes seen so far otherwise.
    private var bomProbe: [UInt8]? = []
    private var line: [UInt8] = []
    /// The previous byte ended a line with CR — an LF next is part of it.
    private var lastWasCR = false
    /// Offset of the first byte of `line` in the stream.
    private var lineStart = 0
    /// The line the last CR ended was a field line (its LF belongs to the
    /// pending block too).
    private var lastLineWasField = false
    /// Every byte fed so far, BOM included.
    public private(set) var byteCount = 0

    private var dataBuffer = ""
    private var dataBufferUsed = false
    private var eventType = ""
    private var lastEventID = ""
    private var blockRetry: Int?
    /// Offset where the block being built began (its first field line).
    private var blockStart: Int?
    /// Bytes of field lines (and their terminators) consumed since the last
    /// blank line — the part of `pendingByteCount` that is not `line`.
    private var blockFieldBytes = 0

    /// The reconnection time the stream asked for, in milliseconds.
    public private(set) var reconnectionTime: Int?
    public private(set) var commentCount = 0

    public init() {}

    /// Bytes that belong to an event not dispatched yet: its field lines and
    /// the unterminated line. Comments do not count — they are never events.
    public var pendingByteCount: Int { blockFieldBytes + line.count }

    /// Feeds bytes; returns the events they completed, in order.
    public mutating func feed<S: Sequence>(_ bytes: S) -> [Event] where S.Element == UInt8 {
        var events: [Event] = []
        for byte in bytes {
            if var probe = bomProbe {
                probe.append(byte)
                if probe == Self.bom {
                    bomProbe = nil
                    byteCount += probe.count
                    lineStart = byteCount
                } else if Self.bom.starts(with: probe) {
                    bomProbe = probe
                } else {
                    bomProbe = nil
                    for held in probe { consume(held, into: &events) }
                }
                continue
            }
            consume(byte, into: &events)
        }
        return events
    }

    public mutating func feed(_ text: String) -> [Event] {
        feed(text.utf8)
    }

    /// The end of the stream. A partial BOM probe is replayed as content; an
    /// unterminated line is NOT processed (the spec discards an undispatched
    /// event), so it stays in `pendingByteCount`. Returns no events, ever —
    /// it exists so the probe is not lost and so callers state the end.
    public mutating func finish() {
        if let probe = bomProbe, !probe.isEmpty {
            bomProbe = nil
            var ignored: [Event] = []
            for held in probe { consume(held, into: &ignored) }
        } else {
            bomProbe = nil
        }
    }

    private mutating func consume(_ byte: UInt8, into events: inout [Event]) {
        byteCount += 1
        if byte == Self.lf, lastWasCR {
            // The LF of a CRLF split from its CR (possibly across chunks):
            // part of the line ending that was already processed.
            lastWasCR = false
            if lastLineWasField { blockFieldBytes += 1 }
            lineStart = byteCount
            return
        }
        lastWasCR = false
        if byte == Self.cr || byte == Self.lf {
            lastWasCR = byte == Self.cr
            let terminated = line
            line.removeAll(keepingCapacity: true)
            let start = lineStart
            lineStart = byteCount
            processLine(terminated, start: start, end: byteCount, into: &events)
            return
        }
        line.append(byte)
    }

    private mutating func processLine(_ bytes: [UInt8], start: Int, end: Int, into events: inout [Event]) {
        lastLineWasField = false
        if bytes.isEmpty {
            dispatch(end: end, into: &events)
            return
        }
        if bytes[0] == UInt8(ascii: ":") {
            commentCount += 1
            return
        }
        if blockStart == nil { blockStart = start }
        blockFieldBytes += end - start
        lastLineWasField = true

        let name: String
        let value: String
        if let colon = bytes.firstIndex(of: UInt8(ascii: ":")) {
            name = String(decoding: bytes[..<colon], as: UTF8.self)
            var valueStart = colon + 1
            if valueStart < bytes.count, bytes[valueStart] == UInt8(ascii: " ") { valueStart += 1 }
            value = String(decoding: bytes[valueStart...], as: UTF8.self)
        } else {
            name = String(decoding: bytes, as: UTF8.self)
            value = ""
        }

        switch name {
        case "event":
            eventType = value
        case "data":
            dataBuffer += value
            dataBuffer += "\n"
            dataBufferUsed = true
        case "id":
            if !value.unicodeScalars.contains("\u{0}") { lastEventID = value }
        case "retry":
            if !value.isEmpty, value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) {
                // A value too large for Int is still "ASCII digits"; saturate
                // rather than trap on data from the network.
                let parsed = Int(value) ?? Int.max
                reconnectionTime = parsed
                blockRetry = parsed
            }
        default:
            break
        }
    }

    private mutating func dispatch(end: Int, into events: inout [Event]) {
        defer {
            dataBuffer = ""
            dataBufferUsed = false
            eventType = ""
            blockRetry = nil
            blockStart = nil
            blockFieldBytes = 0
        }
        guard dataBufferUsed, !dataBuffer.isEmpty else { return }
        var data = dataBuffer
        if data.hasSuffix("\n") { data.removeLast() }
        events.append(Event(
            name: eventType.isEmpty ? nil : eventType,
            data: data,
            id: lastEventID.isEmpty ? nil : lastEventID,
            retry: blockRetry,
            byteRange: (blockStart ?? end)..<end
        ))
    }
}

/// JSON Lines / NDJSON (`application/x-ndjson`, `application/jsonl`, …),
/// split incrementally: one value per LF-terminated line.
///
/// A CR before the LF is stripped (Windows line endings), blank lines are
/// skipped, one leading BOM is ignored, and a leading RS (0x1E, RFC 7464
/// JSON text sequences) is stripped from a line. The unterminated last line
/// is PENDING, not a record: a stream cut mid-line would otherwise hand a
/// reader half a JSON object as if it were one.
public struct NDJSONSplitter: Sendable {
    public struct Line: Equatable, Sendable {
        public var text: String
        public var byteRange: Range<Int>

        public init(text: String, byteRange: Range<Int>) {
            self.text = text
            self.byteRange = byteRange
        }
    }

    private var bomProbe: [UInt8]? = []
    private var line: [UInt8] = []
    private var lineStart = 0
    public private(set) var byteCount = 0

    public init() {}

    public var pendingByteCount: Int { line.count }

    public mutating func feed<S: Sequence>(_ bytes: S) -> [Line] where S.Element == UInt8 {
        var lines: [Line] = []
        for byte in bytes {
            if var probe = bomProbe {
                probe.append(byte)
                if probe == [0xEF, 0xBB, 0xBF] {
                    bomProbe = nil
                    byteCount += 3
                    lineStart = byteCount
                } else if [UInt8]([0xEF, 0xBB, 0xBF]).starts(with: probe) {
                    bomProbe = probe
                } else {
                    bomProbe = nil
                    for held in probe { consume(held, into: &lines) }
                }
                continue
            }
            consume(byte, into: &lines)
        }
        return lines
    }

    public mutating func feed(_ text: String) -> [Line] {
        feed(text.utf8)
    }

    public mutating func finish() {
        if let probe = bomProbe, !probe.isEmpty {
            bomProbe = nil
            var ignored: [Line] = []
            for held in probe { consume(held, into: &ignored) }
        } else {
            bomProbe = nil
        }
    }

    private mutating func consume(_ byte: UInt8, into lines: inout [Line]) {
        byteCount += 1
        guard byte == 0x0A else {
            line.append(byte)
            return
        }
        var content = line[...]
        line.removeAll(keepingCapacity: true)
        let start = lineStart
        lineStart = byteCount
        if content.last == 0x0D { content = content.dropLast() }
        if content.first == 0x1E { content = content.dropFirst() }
        let text = String(decoding: content, as: UTF8.self)
        guard !text.allSatisfy(\.isWhitespace) else { return }
        lines.append(Line(text: text, byteRange: start..<byteCount))
    }
}
