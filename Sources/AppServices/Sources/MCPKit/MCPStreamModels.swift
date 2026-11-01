//
//  MCPStreamModels.swift
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
//  A streamed response as an agent reads it: `get_session view=events`
//  (numbered, per-event redacted events) and `view=assembled` (the LLM
//  answer put back together). Protocol PRD 2.4 / 4a.2; the rules below are
//  protocol-engine doc §S5.
//

import Foundation

// MARK: - The seam

/// What the stream views need to know about a row besides its body — read
/// without building a whole detail (which renders a cURL).
public struct MCPSessionStreamFacts: Equatable, Sendable {
    public var isRelay: Bool
    /// The response's `Content-Type` as recorded.
    public var contentType: String?
    /// The host, for the per-host redaction policy.
    public var host: String
    /// Response head → end of the response, in milliseconds; nil when
    /// unknown or still open.
    public var responseDurationMs: Double?
    /// Bytes of the response body the capture did not keep (D10).
    public var notRetainedBytes: Int64
    /// The response is still arriving (a live row): the body is the text so
    /// far, and only its complete events are shown.
    public var inFlight: Bool

    public init(isRelay: Bool, contentType: String?, host: String, responseDurationMs: Double? = nil, notRetainedBytes: Int64 = 0,
                inFlight: Bool = false) {
        self.isRelay = isRelay
        self.contentType = contentType
        self.host = host
        self.responseDurationMs = responseDurationMs
        self.notRetainedBytes = max(0, notRetainedBytes)
        self.inFlight = inFlight
    }
}

extension MCPSessionProviding {
    /// Default: derived from the detail. The app overrides it with a cheap read.
    public func sessionStreamFacts(uid: String) -> MCPSessionStreamFacts? {
        sessionDetail(uid: uid).map { detail in
            MCPSessionStreamFacts(
                isRelay: detail.summary.isRelay,
                contentType: detail.summary.contentType,
                host: detail.summary.host,
                notRetainedBytes: detail.notRetainedBytes(.response)
            )
        }
    }
}

// MARK: - Agent-facing types

public enum MCPStreamView: String, Codable, CaseIterable, Sendable {
    case events
    case assembled
}

/// Facts every stream answer carries.
public struct MCPStreamFacts: Codable, Equatable, Sendable {
    public var uid: String
    public var format: StreamFormat
    public var totalEvents: Int
    /// Bytes at the end that are not a complete event or line: withheld,
    /// never shown as an event (a secret split across two chunks defeats
    /// shape-based redaction, and half an event is not an event).
    public var pendingBytes: Int
    /// SSE comment lines (`: ping`) — not events, counted.
    public var comments: Int
    /// Bytes of the body the capture did not keep: the events end early.
    public var notRetainedBytes: Int64
    /// Response head → first event, when arrival times were recorded.
    public var timeToFirstEventMs: Double?
    public var longestGapMs: Double?
    /// 1-based number of the event before the longest gap.
    public var longestGapAfterEvent: Int?
    /// How many events carry an arrival time (0 for a stream that reached
    /// the app as one finished body).
    public var timedEvents: Int
    /// Response head → end of the response.
    public var responseDurationMs: Double?
    /// The LLM API recognised, if any.
    public var provider: LLMStreamAssembly.Provider?
    /// True while the response is still arriving: these are the complete
    /// events so far. Nil (absent) for a finished stream.
    public var inFlight: Bool?

    public init(uid: String, format: StreamFormat, totalEvents: Int, pendingBytes: Int, comments: Int,
                notRetainedBytes: Int64, timeToFirstEventMs: Double?, longestGapMs: Double?,
                longestGapAfterEvent: Int?, timedEvents: Int, responseDurationMs: Double?,
                provider: LLMStreamAssembly.Provider?) {
        self.uid = uid
        self.format = format
        self.totalEvents = totalEvents
        self.pendingBytes = pendingBytes
        self.comments = comments
        self.notRetainedBytes = notRetainedBytes
        self.timeToFirstEventMs = timeToFirstEventMs
        self.longestGapMs = longestGapMs
        self.longestGapAfterEvent = longestGapAfterEvent
        self.timedEvents = timedEvents
        self.responseDurationMs = responseDurationMs
        self.provider = provider
    }
}

public struct MCPStreamEvent: Codable, Equatable, Sendable {
    /// 1-based.
    public var number: Int
    public var name: String?
    /// Redacted; JSON re-serialized compactly with sorted keys.
    public var data: String
    public var id: String?
    public var retry: Int?
    /// Milliseconds after the response head; nil when not recorded.
    public var atMs: Double?
    /// The data was longer than the per-event cap.
    public var dataTruncated: Bool
    /// Its delta field is masked: the value the deltas assemble holds a
    /// credential-shaped string (see `view=assembled`, where it is redacted).
    public var deltaWithheld: Bool

    public init(number: Int, name: String?, data: String, id: String?, retry: Int?, atMs: Double?,
                dataTruncated: Bool, deltaWithheld: Bool) {
        self.number = number
        self.name = name
        self.data = data
        self.id = id
        self.retry = retry
        self.atMs = atMs
        self.dataTruncated = dataTruncated
        self.deltaWithheld = deltaWithheld
    }
}

public struct MCPStreamEventsPage: Codable, Equatable, Sendable {
    public var facts: MCPStreamFacts
    public var events: [MCPStreamEvent]
    /// The number to pass as `from` for the next page; nil at the end.
    public var nextFrom: Int?
    /// How many events of the WHOLE stream had their delta masked.
    public var withheldDeltaEvents: Int

    public init(facts: MCPStreamFacts, events: [MCPStreamEvent], nextFrom: Int?, withheldDeltaEvents: Int) {
        self.facts = facts
        self.events = events
        self.nextFrom = nextFrom
        self.withheldDeltaEvents = withheldDeltaEvents
    }
}

public struct MCPStreamBlock: Codable, Equatable, Sendable {
    public var kind: LLMStreamAssembly.BlockKind
    public var choice: Int?
    public var id: String?
    public var name: String?
    /// Redacted after assembly. Tool-call arguments are compact JSON when
    /// they parse (`argumentsAreJSON`).
    public var content: String
    public var contentTruncated: Bool
    public var argumentsAreJSON: Bool?

    public init(kind: LLMStreamAssembly.BlockKind, choice: Int?, id: String?, name: String?, content: String,
                contentTruncated: Bool, argumentsAreJSON: Bool?) {
        self.kind = kind
        self.choice = choice
        self.id = id
        self.name = name
        self.content = content
        self.contentTruncated = contentTruncated
        self.argumentsAreJSON = argumentsAreJSON
    }
}

public struct MCPStreamError: Codable, Equatable, Sendable {
    public var type: String?
    public var code: String?
    public var message: String?
    /// 1-based number of the event that carried it.
    public var eventNumber: Int

    public init(type: String?, code: String?, message: String?, eventNumber: Int) {
        self.type = type
        self.code = code
        self.message = message
        self.eventNumber = eventNumber
    }
}

public struct MCPStreamAssembled: Codable, Equatable, Sendable {
    public var facts: MCPStreamFacts
    public var model: String?
    public var responseID: String?
    /// The answer's text (first choice), redacted after assembly.
    public var text: String?
    public var textTruncated: Bool
    public var blocks: [MCPStreamBlock]
    public var stopReason: String?
    public var usage: LLMStreamAssembly.Usage?
    public var error: MCPStreamError?
    /// The stream's own end marker arrived.
    public var completed: Bool
    public var recognizedEvents: Int
    public var unrecognizedEvents: Int

    public init(facts: MCPStreamFacts, model: String?, responseID: String?, text: String?, textTruncated: Bool,
                blocks: [MCPStreamBlock], stopReason: String?, usage: LLMStreamAssembly.Usage?, error: MCPStreamError?,
                completed: Bool, recognizedEvents: Int, unrecognizedEvents: Int) {
        self.facts = facts
        self.model = model
        self.responseID = responseID
        self.text = text
        self.textTruncated = textTruncated
        self.blocks = blocks
        self.stopReason = stopReason
        self.usage = usage
        self.error = error
        self.completed = completed
        self.recognizedEvents = recognizedEvents
        self.unrecognizedEvents = unrecognizedEvents
    }
}

// MARK: - Egress

/// Builds the agent-facing views of a stream, with redaction.
///
/// The rules (all pinned by `MCPStreamEgressTests`):
/// 1. **Only complete events leave.** The parser never makes an event of an
///    unterminated tail; it is reported as `pendingBytes`.
/// 2. **Every event is redacted on its own**: JSON data structurally (by
///    key name, whatever the nesting), anything else by shape, aggressively;
///    the event name and id by shape too.
/// 3. **Assembled values are redacted AFTER assembly** — a credential the
///    model emitted across two deltas is only recognisable whole — and when
///    that changes a block, every delta that built it is masked in the events
///    view (`deltaWithheld`). Without this the events view would hand out
///    the two halves the assembled view hid. The events that repeat a block
///    WHOLE (Responses' `function_call_arguments.done`, `output_item.done`,
///    `response.completed`; Chat arguments sent in one piece) need no mask:
///    they hold the arguments as a JSON-encoded string, which `redactJSON`
///    walks by key name like any other JSON.
/// 4. **Arguments cut short** (the stream ended inside a tool call) do not
///    parse; they are redacted by name leniently
///    (`MCPRedactor.redactPartialJSONByName`) and then by shape, so a short
///    value under `password` is still found and its deltas masked.
/// 5. A host the user excepted from redaction is shown as recorded (caps
///    still apply), exactly like `get_session`.
public enum MCPStreamEgress {
    public static let defaultPageSize = 50
    public static let maxPageSize = 200
    /// Per-event data cap after redaction.
    public static let eventDataMaxBytes = 4_096
    /// A page stops adding events once its data passes this (one event is
    /// always returned).
    public static let pageDataBudgetBytes = 48 * 1024
    public static let textMaxBytes = 32 * 1024
    public static let blockMaxBytes = 16 * 1024

    /// A parsed stream plus the redaction decisions made over the WHOLE of
    /// it — built once per request.
    public struct Prepared {
        public let log: StreamEventLog
        public let assembly: LLMStreamAssembly
        public let redacting: Bool
        /// 0-based indices of events whose delta is masked.
        public let maskedEvents: Set<Int>
    }

    public static func prepare(body: String, format: StreamFormat, redacting: Bool) -> Prepared {
        let log = StreamEventLog.parse(body: body, format: format)
        let assembly = LLMStreamAssembler.assemble(log.events)
        var masked = Set<Int>()
        if redacting {
            for block in assembly.blocks where redactedBlock(block).changed {
                masked.formUnion(block.deltaEventIndices)
            }
        }
        return Prepared(log: log, assembly: assembly, redacting: redacting, maskedEvents: masked)
    }

    public static func facts(uid: String, prepared: Prepared, stream: MCPSessionStreamFacts) -> MCPStreamFacts {
        let timing = prepared.log.timing
        var facts = MCPStreamFacts(
            uid: uid,
            format: prepared.log.format,
            totalEvents: prepared.log.events.count,
            pendingBytes: prepared.log.pendingByteCount,
            comments: prepared.log.commentCount,
            notRetainedBytes: stream.notRetainedBytes,
            timeToFirstEventMs: timing.timeToFirstEvent.map { $0 * 1000 },
            longestGapMs: timing.longestGap.map { $0.duration * 1000 },
            longestGapAfterEvent: timing.longestGap.map { $0.afterEventIndex + 1 },
            timedEvents: timing.timedEvents,
            responseDurationMs: stream.responseDurationMs,
            provider: prepared.assembly.provider
        )
        facts.inFlight = stream.inFlight ? true : nil
        return facts
    }

    public static func eventsPage(uid: String, prepared: Prepared, stream: MCPSessionStreamFacts,
                                  from: Int? = nil, limit: Int? = nil) -> MCPStreamEventsPage {
        let events = prepared.log.events
        let start = max(1, from ?? 1) - 1
        let size = min(max(1, limit ?? defaultPageSize), maxPageSize)
        var page: [MCPStreamEvent] = []
        var spent = 0
        var index = start
        while index < events.count, page.count < size {
            if !page.isEmpty, spent >= pageDataBudgetBytes { break }
            let event = events[index]
            let rendered = egressEvent(event, prepared: prepared)
            spent += rendered.data.utf8.count
            page.append(rendered)
            index += 1
        }
        return MCPStreamEventsPage(
            facts: facts(uid: uid, prepared: prepared, stream: stream),
            events: page,
            nextFrom: index < events.count ? index + 1 : nil,
            withheldDeltaEvents: prepared.maskedEvents.count
        )
    }

    public static func assembled(uid: String, prepared: Prepared, stream: MCPSessionStreamFacts) -> MCPStreamAssembled {
        let assembly = prepared.assembly
        let blocks = assembly.blocks.map { block -> MCPStreamBlock in
            let content = prepared.redacting ? redactedBlock(block).content : block.content
            let capped = MCPSessionQuery.cappedPreview(content, maxBytes: blockMaxBytes)
            return MCPStreamBlock(
                kind: block.kind,
                choice: block.choice,
                id: block.id.map { prepared.redacting ? MCPRedactor.redactStatic($0, aggressive: false) : $0 },
                name: block.name.map { prepared.redacting ? MCPRedactor.redactStatic($0, aggressive: false) : $0 },
                content: capped.preview ?? "",
                contentTruncated: capped.truncated,
                argumentsAreJSON: block.kind == .toolCall ? isJSON(block.content) : nil
            )
        }
        let rawText = assembly.text
        let text = prepared.redacting ? redactAssembledText(rawText) : rawText
        let cappedText = MCPSessionQuery.cappedPreview(text.isEmpty ? nil : text, maxBytes: textMaxBytes)
        let error = assembly.error.map { error in
            MCPStreamError(
                type: error.type.map(scrub(prepared)),
                code: error.code.map(scrub(prepared)),
                message: error.message.map(scrub(prepared)),
                eventNumber: error.eventIndex + 1
            )
        }
        return MCPStreamAssembled(
            facts: facts(uid: uid, prepared: prepared, stream: stream),
            model: assembly.model.map(scrub(prepared)),
            responseID: assembly.responseID.map(scrub(prepared)),
            text: cappedText.preview,
            textTruncated: cappedText.truncated,
            blocks: blocks,
            stopReason: assembly.stopReason.map(scrub(prepared)),
            usage: assembly.usage,
            error: error,
            completed: assembly.completed,
            recognizedEvents: assembly.recognizedEvents,
            unrecognizedEvents: assembly.unrecognizedEvents
        )
    }

    // MARK: Redaction

    /// Short identifier-like strings (a model name, a stop reason, an error
    /// message): JWTs and vendor prefixes only — high-entropy detection would
    /// eat ordinary model ids.
    private static func scrub(_ prepared: Prepared) -> (String) -> String {
        { prepared.redacting ? MCPRedactor.redactStatic($0, aggressive: false) : $0 }
    }

    static func egressEvent(_ event: StreamEvent, prepared: Prepared) -> MCPStreamEvent {
        let masked = prepared.maskedEvents.contains(event.index)
        let data = prepared.redacting
            ? redactEventData(event.data, maskingDeltasFor: masked ? prepared.assembly.provider : nil)
            : event.data
        let capped = MCPSessionQuery.cappedPreview(data, maxBytes: eventDataMaxBytes)
        return MCPStreamEvent(
            number: event.index + 1,
            name: event.name.map { prepared.redacting ? MCPRedactor.redactStatic($0, aggressive: true) : $0 },
            data: capped.preview ?? "",
            id: event.id.map { prepared.redacting ? MCPRedactor.redactStatic($0, aggressive: true) : $0 },
            retry: event.retry,
            atMs: event.receivedAt.map { $0 * 1000 },
            dataTruncated: capped.truncated,
            deltaWithheld: masked
        )
    }

    /// One event's data on its way out: JSON by structure (then compact,
    /// sorted keys), `[DONE]` as is, anything else by shape.
    static func redactEventData(_ data: String, maskingDeltasFor provider: LLMStreamAssembly.Provider?) -> String {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" { return trimmed }
        if let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) {
            var value: Any = object
            if let provider, let dictionary = object as? [String: Any] {
                value = LLMStreamAssembler.maskingDeltas(in: dictionary, provider: provider, placeholder: MCPRedactor.placeholder)
            }
            if let text = compactJSON(MCPRedactor.redactJSON(value)) { return text }
        }
        return MCPRedactor.redactStatic(MCPRedactor.redactPartialJSONByName(data), aggressive: true)
    }

    /// The assembled text: JWTs and vendor prefixes, as a JSON body's string
    /// values are treated. Not the high-entropy pass — it would eat every
    /// camel-cased identifier in a code answer.
    static func redactAssembledText(_ text: String) -> String {
        MCPRedactor.redactStatic(text, aggressive: false)
    }

    /// A block redacted whole, and whether that changed it.
    static func redactedBlock(_ block: LLMStreamAssembly.Block) -> (content: String, changed: Bool) {
        switch block.kind {
        case .text, .thinking, .refusal:
            let redacted = redactAssembledText(block.content)
            return (redacted, redacted != block.content)
        case .toolCall:
            if let object = try? JSONSerialization.jsonObject(with: Data(block.content.utf8), options: [.fragmentsAllowed]) {
                let redacted = MCPRedactor.redactJSON(object)
                let before = compactJSON(object)
                let after = compactJSON(redacted) ?? MCPRedactor.placeholder
                return (after, before != after)
            }
            // Arguments cut short (a stream that ended mid-call) do not parse:
            // pairs are found by NAME leniently (a short value under
            // `password` has no shape to find), then the aggressive shape pass.
            let byName = MCPRedactor.redactPartialJSONByName(block.content)
            let redacted = MCPRedactor.redactStatic(byName, aggressive: true)
            return (redacted, redacted != block.content)
        }
    }

    static func compactJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber || value is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func isJSON(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil
    }

    // MARK: A whole stream body, redacted per event

    /// The body `get_session` (and every other surface that redacts a whole
    /// body — saved sessions, HAR) shows for a stream: re-rendered event by
    /// event through the same redaction, masked deltas included, the pending
    /// tail withheld. A stream body used to fall through to free-text
    /// redaction, which cannot see `"api_key":"abc"` inside a data line.
    ///
    /// nil when the body is not a stream despite its label (no event parsed
    /// and nothing that reads as one) — the caller then redacts it as the
    /// document it is. A body that IS stream-shaped but holds only an
    /// unfinished event still comes back as the pending note.
    static func redactedStreamBody(_ body: String, format: StreamFormat) -> String? {
        let prepared = prepare(body: body, format: format, redacting: true)
        if prepared.log.events.isEmpty, !looksLikeStream(body, format: format) { return nil }
        var lines: [String] = []
        for event in prepared.log.events {
            let data = redactEventData(event.data, maskingDeltasFor: prepared.maskedEvents.contains(event.index) ? prepared.assembly.provider : nil)
            switch format {
            case .sse:
                if let name = event.name { lines.append("event: \(MCPRedactor.redactStatic(name, aggressive: true))") }
                if let id = event.id { lines.append("id: \(MCPRedactor.redactStatic(id, aggressive: true))") }
                // Data with LF is several data lines on the wire; keep it so.
                data.split(separator: "\n", omittingEmptySubsequences: false).forEach { lines.append("data: \($0)") }
                lines.append("")
            case .ndjson:
                lines.append(data)
            }
        }
        let comments = prepared.log.commentCount
        if format == .sse, comments > 0 {
            lines.append(": \(comments) comment line\(comments == 1 ? "" : "s") omitted")
        }
        if prepared.log.pendingByteCount > 0 {
            let note = pendingNote(prepared.log.pendingByteCount, format: format)
            lines.append(format == .sse ? ": \(note)" : "[\(note)]")
        }
        return lines.joined(separator: "\n")
    }

    /// Whether a body with no complete event still reads as the stream it is
    /// labelled: an SSE body with any field line (`data:`, `event:`, `id:`,
    /// `retry:`), or an NDJSON body that starts as a JSON object but does not
    /// parse (a line cut short). A whole JSON document, a sentence, or the
    /// app's "[binary body omitted — …]" line does not.
    static func looksLikeStream(_ body: String, format: StreamFormat) -> Bool {
        switch format {
        case .sse:
            let fields: Set<Substring> = ["data", "event", "id", "retry"]
            return body.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
                .contains { line in
                    let field = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? line
                    return fields.contains(field.drop(while: { $0 == "\u{FEFF}" }))
                }
        case .ndjson:
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.first == "{" else { return false }
            return !isJSON(trimmed)
        }
    }

    /// "37 bytes pending — an incomplete event at the end is withheld".
    public static func pendingNote(_ bytes: Int, format: StreamFormat) -> String {
        let unit = format == .sse ? "event" : "line"
        return "\(bytes) byte\(bytes == 1 ? "" : "s") pending — an incomplete \(unit) at the end is withheld"
    }
}
