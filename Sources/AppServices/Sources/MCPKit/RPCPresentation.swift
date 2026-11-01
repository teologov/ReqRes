//
//  RPCPresentation.swift
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
//  Every word and number of the RPC tab and of the table's RPC status
//  (protocol-engine doc §S8), pure so it is tested — the app only lays them
//  out. Status is always a WORD with a symbol; colour is never the only
//  signal.
//

import Foundation

public enum RPCPresentation {
    // MARK: - The table

    /// The word the table shows beside the HTTP status, or nil when the two
    /// say the same thing. They differ whenever the RPC failed (a gRPC-Web
    /// error rides an HTTP 200), and when an RPC that succeeded came back
    /// with a non-2xx HTTP status (which no conforming server sends — shown
    /// because it is odd). An OK RPC under a 2xx adds nothing.
    public static func tableWord(status: RPCStatus?, httpStatus: Int?) -> String? {
        guard let status else { return nil }
        if !status.isOK { return status.name }
        if let http = httpStatus, !(200 ..< 300).contains(http) { return status.name }
        return nil
    }

    /// "200 · NOT_FOUND", "200", "NOT_FOUND" (no HTTP status).
    public static func statusText(httpStatus: Int?, status: RPCStatus?) -> String {
        let http = httpStatus.map(String.init)
        guard let word = tableWord(status: status, httpStatus: httpStatus) else { return http ?? "" }
        return [http, word].compactMap { $0 }.joined(separator: " · ")
    }

    /// SF Symbol shown WITH the word.
    public static func symbolName(_ status: RPCStatus) -> String {
        status.isOK ? "checkmark.circle" : "exclamationmark.circle"
    }

    /// "HTTP 200, gRPC status NOT_FOUND" — the row's VoiceOver label and
    /// tooltip (the tooltip adds the message).
    public static func accessibilityLabel(protocol rpcProtocol: RPCProtocol, httpStatus: Int?, status: RPCStatus) -> String {
        let family = rpcProtocol == .connectUnary || rpcProtocol == .connectStreaming ? "Connect" : "gRPC"
        let http = httpStatus.map { "HTTP \($0), " } ?? ""
        return "\(http)\(family) status \(status.name)"
    }

    // MARK: - The tab's header

    /// "gRPC-Web · protobuf · helloworld.Greeter / SayHello".
    public static func headerLine(_ exchange: RPCDecodedExchange) -> String {
        var parts = [exchange.rpcProtocol.displayName, codecWord(exchange.codec)]
        if let service = exchange.service, let method = exchange.method {
            parts.append("\(service) / \(method)")
        }
        return parts.joined(separator: " · ")
    }

    public static func codecWord(_ codec: RPCCodec) -> String {
        switch codec {
        case .proto: return "protobuf"
        case .json: return "JSON"
        case .other: return "unknown codec"
        }
    }

    /// "Status NOT_FOUND (5) — “no such user” · from the trailer frame", or
    /// the reason there is none.
    public static func statusLine(_ exchange: RPCDecodedExchange) -> String {
        guard let status = exchange.status else {
            return "No RPC status — " + (exchange.statusNote ?? "none was recorded.")
        }
        var line = "Status \(status.name) (\(status.code))"
        if let message = status.message, !message.isEmpty {
            line += " — “\(oneLine(message, max: 300))”"
        }
        return line + " · " + sourceWords(status.source)
    }

    public static func sourceWords(_ source: RPCStatusSource) -> String {
        switch source {
        case .trailerFrame: return "from the trailer frame"
        case .trailers: return "from the response trailers"
        case .responseHead: return "from the response head (trailers-only)"
        case .endStream: return "from the end-of-stream message"
        case .connectUnary: return "from the Connect response"
        case .httpStatus: return "inferred from the HTTP status (the RPC sent none)"
        }
    }

    /// "2 requests · 3 responses" (+ "· 12 more not decoded").
    public static func countsLine(_ exchange: RPCDecodedExchange) -> String {
        var line = "\(count(exchange.requestMessages.count, "request message")) · \(count(exchange.responseMessages.count, "response message"))"
        let hidden = exchange.requestMessagesNotShown + exchange.responseMessagesNotShown
        if hidden > 0 { line += " · \(StreamEventsPresentation.grouped(hidden)) more not decoded" }
        return line
    }

    // MARK: - A message

    /// SF Symbol for the direction, always shown with `directionWord`.
    public static func directionSymbol(_ direction: RPCDirection) -> String {
        direction == .request ? "arrow.up" : "arrow.down"
    }

    public static func directionWord(_ direction: RPCDirection) -> String {
        direction == .request ? "Request" : "Response"
    }

    /// "Request 1 · 24 B" / "Response 2 · 1.2 KB compressed".
    public static func messageTitle(_ message: RPCMessage) -> String {
        var title = "\(directionWord(message.direction)) \(message.number) · \(RecordedExchangeCopy.binaryBytes(Int64(message.wireBytes)))"
        if message.compressed { title += " compressed" }
        return title
    }

    public static func accessibilityLabel(_ message: RPCMessage) -> String {
        var label = "\(directionWord(message.direction)) message \(message.number), \(RecordedExchangeCopy.binaryBytes(Int64(message.wireBytes)))"
        if message.compressed { label += ", compressed" }
        return label
    }

    /// One line of a field tree, indented by `depth`.
    public struct Line: Equatable, Sendable, Identifiable {
        public var id: Int
        public var depth: Int
        public var text: String
        /// The other readings, shown dimmer after the text.
        public var secondary: String?
    }

    /// The whole body of a message as tree lines — `protoc --decode_raw`'s
    /// layout, field numbers only:
    /// ```
    /// 1: 42
    /// 2: "Ann"
    /// 3 {
    ///   1: 7
    /// }
    /// 4: <3 bytes> 0a 0b 0c
    /// ```
    /// At most `maxLines`; then one line saying how many more.
    public static func lines(_ message: RPCMessage, maxLines: Int = 2_000) -> [Line] {
        var out: [Line] = []
        switch message.content {
        case .protobuf(let proto):
            if proto.fields.isEmpty {
                out.append(Line(id: 0, depth: 0, text: "(empty message)", secondary: nil))
            }
            var budget = maxLines
            var hidden = 0
            appendFields(proto.fields, depth: 0, into: &out, budget: &budget, hidden: &hidden)
            if hidden > 0 {
                out.append(Line(id: out.count, depth: 0, text: "… \(StreamEventsPresentation.grouped(hidden)) more lines not shown", secondary: nil))
            }
            if proto.fieldsNotShown {
                out.append(Line(id: out.count, depth: 0, text: "… the message has more than \(StreamEventsPresentation.grouped(ProtobufDecoder.maxTopLevelFields)) fields; the rest are not shown", secondary: nil))
            }
            if proto.nestedReadingStopped {
                out.append(Line(id: out.count, depth: 0, text: "Some fields that may be nested messages are shown as text or bytes: the reading budget ran out.", secondary: nil))
            }
        case .text(let text):
            let shown = JSONReindent.pretty(text) ?? text
            for (index, line) in shown.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines).enumerated() {
                out.append(Line(id: index, depth: 0, text: String(line), secondary: nil))
            }
        case .bytes(let data, let reason):
            out.append(Line(id: 0, depth: 0, text: reason, secondary: nil))
            for (index, line) in SocketMessagePresentation.hexDump(data, maxBytes: 4_096).split(separator: "\n").enumerated() {
                out.append(Line(id: index + 1, depth: 0, text: String(line), secondary: nil))
            }
            if data.count > 4_096 {
                out.append(Line(id: out.count, depth: 0, text: "… \(StreamEventsPresentation.grouped(data.count - 4_096)) more bytes", secondary: nil))
            }
        }
        return out
    }

    private static func appendFields(_ fields: [ProtoField], depth: Int, into out: inout [Line], budget: inout Int, hidden: inout Int) {
        for field in fields {
            guard budget > 0 else {
                hidden += 1 + nestedLineCount(field)
                continue
            }
            budget -= 1
            switch field.value {
            case .varint(let value):
                // Only the reading a person needs (a negative int32/int64
                // sent as ten bytes); the zig-zag reading of every number is
                // noise here — the agent surface carries it.
                out.append(Line(id: out.count, depth: depth, text: "\(field.number): \(value)",
                                secondary: joined(ProtobufDecoder.varintAlternatives(value).filter { $0.hasPrefix("int64") })))
            case .fixed64(let value):
                out.append(Line(id: out.count, depth: depth, text: "\(field.number): \(value) (i64)",
                                secondary: joined(ProtobufDecoder.fixed64Alternatives(value))))
            case .fixed32(let value):
                out.append(Line(id: out.count, depth: depth, text: "\(field.number): \(value) (i32)",
                                secondary: joined(ProtobufDecoder.fixed32Alternatives(value))))
            case .lengthDelimited(let delimited):
                let packed = delimited.packedVarints.map { "packed: " + $0.prefix(16).map(String.init).joined(separator: ", ") + ($0.count > 16 ? ", …" : "") }
                switch delimited.reading {
                case .message(let nested):
                    out.append(Line(id: out.count, depth: depth, text: "\(field.number) {", secondary: packed))
                    appendFields(nested, depth: depth + 1, into: &out, budget: &budget, hidden: &hidden)
                    if budget > 0 {
                        budget -= 1
                        out.append(Line(id: out.count, depth: depth, text: "}", secondary: nil))
                    } else {
                        hidden += 1
                    }
                case .text(let text):
                    // `alsoParsesAsMessage` is for agents: in the tab it would
                    // sit beside half the short strings ("Amsterdam").
                    out.append(Line(id: out.count, depth: depth, text: "\(field.number): \(quoted(text, max: 500))", secondary: nil))
                case .bytes:
                    let data = delimited.bytes ?? Data()
                    let hex = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ") + (data.count > 32 ? " …" : "")
                    out.append(Line(id: out.count, depth: depth, text: "\(field.number): <\(RecordedExchangeCopy.binaryBytes(Int64(delimited.byteCount)))> \(hex)",
                                    secondary: packed))
                }
            }
        }
    }

    private static func nestedLineCount(_ field: ProtoField) -> Int {
        guard case .lengthDelimited(let delimited) = field.value, case .message(let nested) = delimited.reading else { return 0 }
        return 1 + nested.reduce(0) { $0 + 1 + nestedLineCount($1) }
    }

    private static func joined(_ parts: [String]) -> String? {
        parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `"text"` with quotes, backslashes and line breaks escaped, cut on a
    /// character boundary.
    public static func quoted(_ text: String, max: Int) -> String {
        var escaped = ""
        var count = 0
        for character in text {
            if count >= max {
                escaped += "…"
                break
            }
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\r\n": escaped += "\\r\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
            count += 1
        }
        return "\"" + escaped + "\""
    }

    static func oneLine(_ text: String, max: Int) -> String {
        let folded = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard folded.count > max else { return folded }
        return String(folded.prefix(max)) + "…"
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(StreamEventsPresentation.grouped(value)) \(noun)\(value == 1 ? "" : "s")"
    }
}
