//
//  StreamEventLog.swift
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

/// The two stream shapes ReqRes reads as events (protocol PRD 2.4 / 4a.2).
public enum StreamFormat: String, Codable, Equatable, Sendable {
    /// `text/event-stream` — server-sent events.
    case sse
    /// NDJSON / JSON Lines — one JSON value per line.
    case ndjson

    /// Media types read as NDJSON. The core announces the first three at
    /// their response head (they are in `LiveRowPolicy.streamingMediaFamilies`,
    /// with text/event-stream and, since core C14, the RPC and push
    /// families); the rest are the other spellings in use, parsed the same way
    /// once the row is final.
    public static let ndjsonMediaTypes: Set<String> = [
        "application/x-ndjson",
        "application/jsonl",
        "application/x-jsonlines",
        "application/ndjson",
        "application/jsonlines",
        "application/json-seq",
    ]

    /// The format a response's `Content-Type` names (parameters and case
    /// ignored), or nil when it is not a stream this layer reads.
    public static func detect(contentType: String?) -> StreamFormat? {
        guard let contentType else { return nil }
        let mediaType = contentType.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if mediaType == "text/event-stream" { return .sse }
        if ndjsonMediaTypes.contains(mediaType) { return .ndjson }
        return nil
    }

    /// How the format is named to a person.
    public var displayName: String {
        switch self {
        case .sse: return "Server-sent events"
        case .ndjson: return "JSON lines"
        }
    }
}

/// One complete event (SSE) or line (NDJSON) of a stream.
public struct StreamEvent: Equatable, Sendable {
    /// 0-based position in the stream. Shown 1-based ("#1").
    public var index: Int
    /// The SSE `event` field; nil for a default ("message") event and for
    /// every NDJSON line.
    public var name: String?
    /// The event's data (SSE, data lines joined by LF) or the line (NDJSON).
    public var data: String
    /// The SSE last event id at dispatch; nil for NDJSON or when empty.
    public var id: String?
    /// A `retry` field in this event's block (SSE), in milliseconds.
    public var retry: Int?
    /// UTF-8 byte offsets of the event in the body.
    public var byteRange: Range<Int>
    /// Seconds after the response head when the bytes that COMPLETED this
    /// event arrived. Nil when arrival times were not recorded — a stream
    /// that reached the app as one finished body (every row before the live
    /// transport is consumed) has none, and none are made up.
    public var receivedAt: TimeInterval?

    public init(index: Int, name: String? = nil, data: String, id: String? = nil, retry: Int? = nil,
                byteRange: Range<Int> = 0..<0, receivedAt: TimeInterval? = nil) {
        self.index = index
        self.name = name
        self.data = data
        self.id = id
        self.retry = retry
        self.byteRange = byteRange
        self.receivedAt = receivedAt
    }
}

/// The gap between two consecutive events.
public struct StreamGap: Equatable, Sendable {
    public var duration: TimeInterval
    /// The 0-based index of the event BEFORE the gap.
    public var afterEventIndex: Int
}

/// Timing facts about a stream, from the events that carry arrival times.
public struct StreamTiming: Equatable, Sendable {
    /// Seconds from the response head to the first event.
    public var timeToFirstEvent: TimeInterval?
    /// The longest silence between two consecutive timed events.
    public var longestGap: StreamGap?
    /// How many events carry an arrival time.
    public var timedEvents: Int

    public static func of(_ events: [StreamEvent]) -> StreamTiming {
        var accumulator = Accumulator()
        for event in events { accumulator.add(event, isFirst: event.index == events.first?.index) }
        return accumulator.timing
    }

    /// `of`, one event at a time: what `StreamEventLog` keeps up to date as
    /// events arrive, so reading `timing` never walks every event again (a
    /// live stream's pane read it twice per refresh — release review,
    /// 2026-09-29).
    struct Accumulator: Sendable {
        private(set) var timing = StreamTiming(timeToFirstEvent: nil, longestGap: nil, timedEvents: 0)
        private var previous: (index: Int, at: TimeInterval)?

        mutating func add(_ event: StreamEvent, isFirst: Bool) {
            guard let at = event.receivedAt else {
                previous = nil
                return
            }
            timing.timedEvents += 1
            if timing.timeToFirstEvent == nil, isFirst { timing.timeToFirstEvent = at }
            if let before = previous {
                let gap = max(0, at - before.at)
                if gap > (timing.longestGap?.duration ?? -1) {
                    timing.longestGap = StreamGap(duration: gap, afterEventIndex: before.index)
                }
            }
            previous = (event.index, at)
        }
    }
}

/// A stream's events, built incrementally.
///
/// The store the Events view and the agent surface both read. Built for the
/// live transport (protocol-engine doc §C10): `append` takes the next piece
/// of the body with the time it arrived, and returns the indices of the
/// events it completed — so a view appends those rows and re-renders nothing
/// else, and a finished row is just the whole body appended once with no
/// time. `append` never changes an event already made.
public struct StreamEventLog: Sendable {
    public let format: StreamFormat
    public private(set) var events: [StreamEvent] = []
    public private(set) var isFinished = false

    private var sse = SSEParser()
    private var ndjson = NDJSONSplitter()

    public init(format: StreamFormat) {
        self.format = format
    }

    /// Parses a whole body at once (a finished row): no arrival times.
    public static func parse(body: String, format: StreamFormat) -> StreamEventLog {
        var log = StreamEventLog(format: format)
        log.append(body.utf8)
        log.finish()
        return log
    }

    /// Bytes of the body read so far.
    public var byteCount: Int {
        switch format {
        case .sse: return sse.byteCount
        case .ndjson: return ndjson.byteCount
        }
    }

    /// Bytes at the end that do not form a complete event or line yet. At the
    /// end of a stream these are what a cut left behind: never an event.
    public var pendingByteCount: Int {
        switch format {
        case .sse: return sse.pendingByteCount
        case .ndjson: return ndjson.pendingByteCount
        }
    }

    /// SSE comment lines (`: ping`); always 0 for NDJSON.
    public var commentCount: Int { format == .sse ? sse.commentCount : 0 }

    /// The reconnection time the stream asked for (SSE `retry`).
    public var reconnectionTime: Int? { format == .sse ? sse.reconnectionTime : nil }

    /// Kept up to date by `append` — O(1) to read.
    public var timing: StreamTiming { timingAccumulator.timing }
    private var timingAccumulator = StreamTiming.Accumulator()

    private mutating func add(_ event: StreamEvent) {
        timingAccumulator.add(event, isFirst: event.index == 0)
        events.append(event)
    }

    /// Feeds the next piece of the body. `receivedAt` is seconds after the
    /// response head, or nil when unknown. Returns the indices of the events
    /// this piece completed.
    @discardableResult
    public mutating func append<S: Sequence>(_ bytes: S, receivedAt: TimeInterval? = nil) -> Range<Int> where S.Element == UInt8 {
        let first = events.count
        guard !isFinished else { return first..<first }
        switch format {
        case .sse:
            for event in sse.feed(bytes) {
                add(StreamEvent(index: events.count, name: event.name, data: event.data, id: event.id,
                                          retry: event.retry, byteRange: event.byteRange, receivedAt: receivedAt))
            }
        case .ndjson:
            for line in ndjson.feed(bytes) {
                add(StreamEvent(index: events.count, data: line.text, byteRange: line.byteRange, receivedAt: receivedAt))
            }
        }
        return first..<events.count
    }

    @discardableResult
    public mutating func append(text: String, receivedAt: TimeInterval? = nil) -> Range<Int> {
        append(text.utf8, receivedAt: receivedAt)
    }

    /// The end of the stream. What is pending stays pending.
    public mutating func finish() {
        guard !isFinished else { return }
        switch format {
        case .sse: sse.finish()
        case .ndjson: ndjson.finish()
        }
        isFinished = true
    }
}
