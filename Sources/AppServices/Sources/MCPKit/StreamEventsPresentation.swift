//
//  StreamEventsPresentation.swift
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

/// Every word and number the Events tab shows, as pure functions — the view
/// only lays them out, so the copy is tested here (protocol-engine doc §S5).
public enum StreamEventsPresentation {
    /// "+1,204 ms", or nil when the arrival was not recorded.
    public static func offset(_ seconds: TimeInterval?) -> String? {
        seconds.map { "+\(milliseconds($0 * 1000))" }
    }

    /// "1,204 ms" (whole milliseconds, grouped).
    public static func milliseconds(_ ms: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return "\(formatter.string(from: NSNumber(value: ms.rounded())) ?? String(Int(ms.rounded()))) ms"
    }

    /// "12,288".
    public static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// The event's name as a person reads it: the SSE `event` field, the
    /// JSON `type` when the stream puts its name there (OpenAI Chat's chunks
    /// have neither), or "message" — the SSE default.
    public static func title(of event: StreamEvent, format: StreamFormat) -> String {
        if let name = event.name, !name.isEmpty { return name }
        if let type = jsonType(event.data) { return type }
        return format == .sse ? "message" : "line"
    }

    static func jsonType(_ data: String) -> String? {
        guard data.hasPrefix("{"),
              let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { return nil }
        if let type = object["type"] as? String, !type.isEmpty { return type }
        if let kind = object["object"] as? String, !kind.isEmpty { return kind }
        return nil
    }

    /// True for an event that reports an error — shown with a symbol and the
    /// word, never by colour alone.
    public static func isError(_ event: StreamEvent) -> Bool {
        if event.name == "error" { return true }
        guard event.data.hasPrefix("{"),
              let object = (try? JSONSerialization.jsonObject(with: Data(event.data.utf8))) as? [String: Any] else { return false }
        return (object["type"] as? String) == "error" || object["error"] is [String: Any]
    }

    /// The summary line above the events.
    ///
    /// "Anthropic Messages · 38 events · first event +412 ms · longest gap
    /// 1,030 ms (after #7)". A stream that reached the app as one finished
    /// body has no arrival times, and says so instead of inventing them;
    /// its head-to-end duration is still a fact.
    public static func summary(log: StreamEventLog, assembly: LLMStreamAssembly?, responseDurationMs: Double?) -> String {
        var parts: [String] = []
        if let provider = assembly?.provider { parts.append(provider.displayName) } else { parts.append(log.format.displayName) }
        parts.append(count(log.events.count, "event"))
        let timing = log.timing
        if let first = timing.timeToFirstEvent {
            parts.append("first event \(offset(first) ?? "")")
            if let gap = timing.longestGap {
                parts.append("longest gap \(milliseconds(gap.duration * 1000)) (after #\(gap.afterEventIndex + 1))")
            }
        } else {
            if let duration = responseDurationMs { parts.append("streamed for \(milliseconds(duration))") }
            parts.append("arrival times not recorded")
        }
        return parts.joined(separator: " · ")
    }

    /// Why there are no per-event times, for the tooltip / caption.
    public static let untimedExplanation =
        "This stream reached ReqRes as one finished body, so when each event arrived was not recorded. Times appear for streams watched while they are open."

    /// The assembled answer in one line: model, stop reason, usage.
    /// `inFlight`: the stream is still arriving (a live row), so a missing
    /// end marker is expected, not a cut.
    public static func assemblyLine(_ assembly: LLMStreamAssembly, inFlight: Bool = false) -> String? {
        guard assembly.provider != nil else { return nil }
        var parts: [String] = []
        if let model = assembly.model { parts.append(model) }
        if let reason = assembly.stopReason { parts.append("stop: \(reason)") }
        if let usage = assembly.usage, !usage.isEmpty {
            var tokens: [String] = []
            if let input = usage.inputTokens { tokens.append("\(grouped(input)) in") }
            if let output = usage.outputTokens { tokens.append("\(grouped(output)) out") }
            if let cached = usage.cacheReadInputTokens, cached > 0 { tokens.append("\(grouped(cached)) cached") }
            if !tokens.isEmpty { parts.append("tokens " + tokens.joined(separator: " / ")) }
        }
        let calls = assembly.toolCalls.count
        if calls > 0 { parts.append(count(calls, "tool call")) }
        parts.append(assembly.completed ? "complete" : inFlight ? "still streaming" : "ended without its end marker")
        return parts.joined(separator: " · ")
    }

    /// The pending tail, in the words the agent surface uses.
    public static func pendingLine(_ log: StreamEventLog) -> String? {
        let bytes = log.pendingByteCount
        guard bytes > 0 else { return nil }
        return MCPStreamEgress.pendingNote(bytes, format: log.format)
    }

    /// VoiceOver's label for one event row: number, name, time.
    public static func accessibilityLabel(for event: StreamEvent, format: StreamFormat) -> String {
        var label = "Event \(event.index + 1), \(title(of: event, format: format))"
        if isError(event) { label += ", error" }
        if let at = event.receivedAt { label += ", \(milliseconds(at * 1000)) after the response started" }
        return label
    }

    /// The data as shown: JSON re-indented with its KEY ORDER KEPT (a
    /// provider's `type` first reads better than sorted keys), anything else
    /// as is.
    public static func displayData(_ data: String) -> String {
        JSONReindent.pretty(data) ?? data
    }

    /// The most of one event a row draws. A single NDJSON line can be
    /// megabytes; the Body tab has all of it.
    public static let displayDataMaxBytes = 16 * 1024

    /// `displayData`, cut at `maxBytes` of UTF-8 on a character boundary,
    /// with how many bytes were left out.
    public static func displayData(_ data: String, maxBytes: Int) -> (text: String, hiddenBytes: Int) {
        let shown = displayData(data)
        let utf8 = shown.utf8
        guard utf8.count > maxBytes else { return (shown, 0) }
        var end = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while end > utf8.startIndex, String.Index(end, within: shown) == nil { end = utf8.index(before: end) }
        let prefix = String(shown[..<end])
        return (prefix, utf8.count - prefix.utf8.count)
    }

    /// "… 2.1 MB more — the Body tab shows the whole event".
    public static func hiddenLine(_ bytes: Int) -> String {
        "… \(RecordedExchangeCopy.binaryBytes(Int64(bytes))) more — the Body tab shows the whole event"
    }
}

/// Re-indents JSON text without parsing it into objects, so key order,
/// number spelling and string escapes stay exactly as the server sent them.
/// Only text that `JSONSerialization` accepts is touched.
public enum JSONReindent {
    public static func pretty(_ text: String, indent: String = "  ") -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first, first == "{" || first == "[",
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil else { return nil }
        // Scalars, not Characters: a quote followed by a combining mark is ONE
        // Character, which would hide the quote from the string tracking.
        let scalars = Array(trimmed.unicodeScalars)
        var output = String.UnicodeScalarView()
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0
        func newline() {
            output.append("\n")
            for _ in 0..<depth { output.append(contentsOf: indent.unicodeScalars) }
        }
        func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
        }
        func nextSignificant(after position: Int) -> Int? {
            var cursor = position + 1
            while cursor < scalars.count {
                if !isSpace(scalars[cursor]) { return cursor }
                cursor += 1
            }
            return nil
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if inString {
                output.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            switch scalar {
            case "\"":
                inString = true
                output.append(scalar)
            case "{", "[":
                output.append(scalar)
                let closing: Unicode.Scalar = scalar == "{" ? "}" : "]"
                if let next = nextSignificant(after: index), scalars[next] == closing {
                    // Keep `{}` / `[]` on one line.
                    output.append(closing)
                    index = next
                } else {
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth = max(0, depth - 1)
                newline()
                output.append(scalar)
            case ",":
                output.append(scalar)
                newline()
            case ":":
                output.append(contentsOf: ": ".unicodeScalars)
            default:
                if !isSpace(scalar) { output.append(scalar) }
            }
            index += 1
        }
        return String(output)
    }
}
