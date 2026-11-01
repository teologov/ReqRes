//
//  MCPRPCModels.swift
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
//  An RPC as an agent reads it: `get_session view=rpc` (protocol PRD 6.3;
//  protocol-engine doc §S8). Every message as a field-number tree, the RPC's
//  status, and — the one thing to know about it — redaction that is
//  SHAPE-ONLY for protobuf strings: without the .proto there are no field
//  names, so `password` cannot be recognised by name the way it is in JSON.
//  A JWT or a vendor-prefixed key is caught by its shape; a short secret in
//  a protobuf string is not. Binary is withheld while a host is redacted.
//

import Foundation

// MARK: - The seam

/// What `view=rpc` needs about a row: its bytes and headers, plus the facts
/// that decide whether it may be read at all.
public struct MCPSessionRPCFacts: Equatable, Sendable {
    public var host: String
    public var isRelay: Bool
    /// In flight, or ended without its final row: bodies are snapshots.
    public var isLive: Bool
    public var input: RPCExchangeInput

    public init(host: String, isRelay: Bool = false, isLive: Bool = false, input: RPCExchangeInput) {
        self.host = host
        self.isRelay = isRelay
        self.isLive = isLive
        self.input = input
    }
}

// MARK: - Agent-facing types

/// One protobuf field. Numbers are decimal STRINGS: a uint64 does not fit a
/// JSON number without losing digits.
public struct MCPProtoField: Codable, Equatable, Sendable {
    public var field: Int
    /// varint | i64 | i32 | len
    public var wire: String
    /// A varint's, i64's or i32's value, unsigned.
    public var value: String?
    /// Its other readings ("sint -3", "double 1.5").
    public var alternatives: [String]?
    /// A length-delimited field read as text — redacted by SHAPE only.
    public var text: String?
    /// A nested message.
    public var message: [MCPProtoField]?
    /// Bytes, base64 — only for a host whose redaction the user switched
    /// off; otherwise nil and `withheld` says why.
    public var bytes: String?
    public var byteCount: Int?
    public var withheld: String?
    /// A text field whose bytes also parse cleanly as a nested message —
    /// the text reading won; doubt it if the text looks like noise.
    public var alsoParsesAsMessage: Bool?
    /// The packed-repeated-varint reading.
    public var packed: [String]?

    public init(field: Int, wire: String) {
        self.field = field
        self.wire = wire
    }
}

public struct MCPRPCMessage: Codable, Equatable, Sendable {
    public var direction: RPCDirection
    /// 1-based within its direction.
    public var number: Int
    public var sizeBytes: Int
    public var compressed: Bool
    /// A protobuf message's fields.
    public var fields: [MCPProtoField]?
    /// A JSON-codec message, redacted by structure (key names).
    public var json: String?
    /// An undecoded payload, base64 (redaction off for the host only).
    public var bytes: String?
    public var withheld: String?
    /// Why the message was not decoded.
    public var note: String?
    /// Fields past the per-message budget were left out.
    public var fieldsNotShown: Bool?

    public init(direction: RPCDirection, number: Int, sizeBytes: Int, compressed: Bool) {
        self.direction = direction
        self.number = number
        self.sizeBytes = sizeBytes
        self.compressed = compressed
    }
}

public struct MCPRPCStatus: Codable, Equatable, Sendable {
    public var code: Int
    public var name: String
    /// Redacted by shape.
    public var message: String?
    public var source: RPCStatusSource

    public init(code: Int, name: String, message: String?, source: RPCStatusSource) {
        self.code = code
        self.name = name
        self.message = message
        self.source = source
    }
}

public struct MCPRPCView: Codable, Equatable, Sendable {
    public var uid: String
    public var rpcProtocol: RPCProtocol
    public var codec: RPCCodec
    public var service: String?
    public var method: String?
    public var httpStatus: Int?
    public var status: MCPRPCStatus?
    public var statusNote: String?
    /// The trailer frame's (or end-of-stream metadata's) other entries,
    /// redacted like headers.
    public var trailers: [RPCHeaderPair]
    public var notes: [String]
    public var totalRequestMessages: Int
    public var totalResponseMessages: Int
    /// Request messages first, then response messages, numbered within each.
    public var messages: [MCPRPCMessage]
    /// The 1-based position (over requests then responses) to pass as `from`
    /// for the next page; nil at the end.
    public var nextFrom: Int?
    /// Messages past the decoder's per-direction limit.
    public var messagesNotDecoded: Int
    /// How this answer was redacted — say it to the user if it matters.
    public var redaction: String

    enum CodingKeys: String, CodingKey {
        case uid, rpcProtocol = "protocol", codec, service, method, httpStatus, status, statusNote, trailers, notes
        case totalRequestMessages, totalResponseMessages, messages, nextFrom, messagesNotDecoded, redaction
    }
}

// MARK: - Egress

public enum MCPRPCEgress {
    public static let defaultPageSize = 20
    public static let maxPageSize = 100
    /// Fields per message on the agent surface (nested ones included).
    public static let fieldBudgetPerMessage = 2_000
    /// Characters of one text field or JSON message.
    public static let maxTextCharacters = 4_000
    /// Bytes of one bytes field or undecoded message shown as base64.
    public static let maxBytesShown = 4_096
    /// A page stops once its content passes this many characters (always at
    /// least one message).
    public static let pageCharacterBudget = 48_000

    public static let redactionShapeOnly = "Protobuf is decoded without its schema, so there are no field names: strings are redacted by SHAPE only (JWTs, vendor-prefixed keys, long high-entropy runs) — a short secret in a protobuf string field is NOT recognised. Bytes fields (and their packed-number reading) and undecoded messages are withheld; a bytes field that happens to parse cleanly as a message is shown as that message. JSON messages are redacted by key name."
    public static let redactionOff = "Redaction is off for this host (Settings ▸ MCP): values are shown as recorded."

    static func withheldBytes(_ count: Int) -> String {
        "\(count) bytes not shown: binary cannot be redacted, and this host is redacted (Settings ▸ MCP)."
    }

    public static func view(uid: String, facts: MCPSessionRPCFacts, decoded: RPCDecodedExchange, redactor: MCPRedactor,
                            from: Int?, limit: Int?) -> MCPRPCView {
        let redacting = redactor.redacts(host: facts.host)
        let all = decoded.requestMessages + decoded.responseMessages
        let start = max(1, from ?? 1)
        let pageSize = min(max(1, limit ?? defaultPageSize), maxPageSize)
        var messages: [MCPRPCMessage] = []
        var used = 0
        var index = start - 1
        while index < all.count, messages.count < pageSize {
            let message = egress(all[index], redacting: redacting)
            let cost = characterCost(message)
            if !messages.isEmpty, used + cost > pageCharacterBudget { break }
            messages.append(message)
            used += cost
            index += 1
        }
        let status = decoded.status.map {
            MCPRPCStatus(code: $0.code, name: $0.name,
                         message: $0.message.map { redacting ? MCPRedactor.redactStatic($0, aggressive: true) : $0 },
                         source: $0.source)
        }
        return MCPRPCView(
            uid: uid,
            rpcProtocol: decoded.rpcProtocol,
            codec: decoded.codec,
            service: decoded.service.map { redacting ? MCPRedactor.redactStatic($0, aggressive: false) : $0 },
            method: decoded.method.map { redacting ? MCPRedactor.redactStatic($0, aggressive: false) : $0 },
            httpStatus: facts.input.httpStatus,
            status: status,
            statusNote: decoded.statusNote,
            trailers: decoded.trailers.map { pair in
                guard redacting else { return pair }
                return RPCHeaderPair(name: MCPRedactor.redactStatic(pair.name, aggressive: false),
                                     value: MCPRedactor.isSensitiveName(pair.name) ? MCPRedactor.placeholder : MCPRedactor.redactStatic(pair.value, aggressive: false))
            },
            notes: decoded.notes.map { redacting ? MCPRedactor.redactStatic($0, aggressive: false) : $0 },
            totalRequestMessages: decoded.requestMessages.count,
            totalResponseMessages: decoded.responseMessages.count,
            messages: messages,
            nextFrom: index < all.count ? index + 1 : nil,
            messagesNotDecoded: decoded.requestMessagesNotShown + decoded.responseMessagesNotShown,
            redaction: redacting ? redactionShapeOnly : redactionOff
        )
    }

    static func egress(_ message: RPCMessage, redacting: Bool) -> MCPRPCMessage {
        var out = MCPRPCMessage(direction: message.direction, number: message.number, sizeBytes: message.wireBytes, compressed: message.compressed)
        switch message.content {
        case .protobuf(let proto):
            var budget = fieldBudgetPerMessage
            var cut = proto.fieldsNotShown
            out.fields = fields(proto.fields, redacting: redacting, budget: &budget, cut: &cut)
            if cut { out.fieldsNotShown = true }
        case .text(let text):
            let redacted = redacting ? MCPRedactor(enabled: true).redactBody(text, contentType: "application/json") : text
            out.json = capped(redacted)
        case .bytes(let data, let reason):
            // The reason can name a message encoding as the headers sent it.
            out.note = redacting ? MCPRedactor.redactStatic(reason, aggressive: false) : reason
            if redacting {
                out.withheld = withheldBytes(data.count)
            } else {
                out.bytes = data.prefix(maxBytesShown).base64EncodedString()
            }
        }
        return out
    }

    static func fields(_ fields: [ProtoField], redacting: Bool, budget: inout Int, cut: inout Bool) -> [MCPProtoField] {
        var out: [MCPProtoField] = []
        for field in fields {
            guard budget > 0 else {
                cut = true
                break
            }
            budget -= 1
            var entry = MCPProtoField(field: field.number, wire: field.value.wireType.token)
            switch field.value {
            case .varint(let value):
                entry.value = String(value)
                entry.alternatives = nonEmpty(ProtobufDecoder.varintAlternatives(value))
            case .fixed64(let value):
                entry.value = String(value)
                entry.alternatives = nonEmpty(ProtobufDecoder.fixed64Alternatives(value))
            case .fixed32(let value):
                entry.value = String(value)
                entry.alternatives = nonEmpty(ProtobufDecoder.fixed32Alternatives(value))
            case .lengthDelimited(let delimited):
                entry.byteCount = delimited.byteCount
                // The packed reading of a `.bytes` field IS its bytes, one
                // per number whenever they sit below 0x80 (all ASCII, half of
                // random binary) — so while the host is redacted it is
                // withheld with them. A `.message` reading only carries one
                // when every field is a varint, numbers already shown.
                if !(redacting && delimited.reading == .bytes) {
                    entry.packed = delimited.packedVarints.map { $0.prefix(64).map(String.init) }
                }
                switch delimited.reading {
                case .message(let nested):
                    entry.message = self.fields(nested, redacting: redacting, budget: &budget, cut: &cut)
                case .text(let text):
                    entry.text = shaped(text, redacting: redacting)
                    if delimited.alsoParsesAsMessage { entry.alsoParsesAsMessage = true }
                case .bytes:
                    let data = delimited.bytes ?? Data()
                    if redacting {
                        entry.withheld = withheldBytes(data.count)
                    } else {
                        entry.bytes = data.prefix(maxBytesShown).base64EncodedString()
                    }
                }
            }
            out.append(entry)
        }
        return out
    }

    /// A protobuf string on its way out: the aggressive shape pass (there is
    /// no name to go by), then the cap — redact BEFORE cap, always.
    static func shaped(_ text: String, redacting: Bool) -> String {
        capped(redacting ? MCPRedactor.redactStatic(text, aggressive: true) : text)
    }

    static func capped(_ text: String) -> String {
        guard text.count > maxTextCharacters else { return text }
        return String(text.prefix(maxTextCharacters)) + "…[\(text.count - maxTextCharacters) more characters]"
    }

    private static func nonEmpty(_ values: [String]) -> [String]? { values.isEmpty ? nil : values }

    private static func characterCost(_ message: MCPRPCMessage) -> Int {
        (try? JSONEncoder().encode(message).count) ?? 0
    }
}

// MARK: - Text for the stdio tool

extension MCPTextFormat {
    public static func rpcView(_ view: MCPRPCView) -> String {
        var lines: [String] = []
        var head = "\(view.rpcProtocol.displayName) · \(RPCPresentation.codecWord(view.codec))"
        if let service = view.service, let method = view.method { head += " · \(service) / \(method)" }
        head += " · uid=\(view.uid)"
        lines.append(head)
        if let status = view.status {
            var line = "Status: \(status.name) (\(status.code))"
            if let message = status.message, !message.isEmpty { line += " — \(message)" }
            line += " · \(RPCPresentation.sourceWords(status.source))"
            if let http = view.httpStatus { line += " · HTTP \(http)" }
            lines.append(line)
        } else {
            lines.append("Status: none — \(view.statusNote ?? "not recorded")")
        }
        if !view.trailers.isEmpty {
            lines.append("Trailers: " + view.trailers.map { "\($0.name): \($0.value)" }.joined(separator: "; "))
        }
        lines.append("\(view.totalRequestMessages) request message(s), \(view.totalResponseMessages) response message(s)"
                     + (view.messagesNotDecoded > 0 ? ", \(view.messagesNotDecoded) more not decoded" : ""))
        for note in view.notes { lines.append("Note: \(note)") }
        lines.append("Redaction: \(view.redaction)")
        for message in view.messages {
            lines.append("")
            var title = "\(RPCPresentation.directionWord(message.direction)) \(message.number) · \(message.sizeBytes) bytes"
            if message.compressed { title += " compressed" }
            lines.append(title)
            if let note = message.note { lines.append("  (\(note))") }
            if let fields = message.fields {
                if fields.isEmpty { lines.append("  (empty message)") }
                appendFieldLines(fields, depth: 1, into: &lines)
                if message.fieldsNotShown == true { lines.append("  … more fields not shown") }
            }
            if let json = message.json { lines.append(contentsOf: json.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }) }
            if let bytes = message.bytes { lines.append("  base64: \(bytes)") }
            if let withheld = message.withheld { lines.append("  \(withheld)") }
        }
        if let next = view.nextFrom { lines.append(contentsOf: ["", "More messages: call again with from=\(next)."]) }
        return lines.joined(separator: "\n")
    }

    private static func appendFieldLines(_ fields: [MCPProtoField], depth: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: depth)
        for field in fields {
            var extra: [String] = field.alternatives ?? []
            if let packed = field.packed { extra.append("packed: " + packed.joined(separator: ", ")) }
            if field.alsoParsesAsMessage == true { extra.append("also parses as a message") }
            let suffix = extra.isEmpty ? "" : "   [" + extra.joined(separator: " · ") + "]"
            if let nested = field.message {
                lines.append("\(pad)\(field.field) {\(suffix)")
                appendFieldLines(nested, depth: depth + 1, into: &lines)
                lines.append("\(pad)}")
            } else if let text = field.text {
                lines.append("\(pad)\(field.field): \(RPCPresentation.quoted(text, max: MCPRPCEgress.maxTextCharacters))\(suffix)")
            } else if let value = field.value {
                lines.append("\(pad)\(field.field): \(value) (\(field.wire))\(suffix)")
            } else if let bytes = field.bytes {
                lines.append("\(pad)\(field.field): <\(field.byteCount ?? 0) bytes> base64 \(bytes)\(suffix)")
            } else if let withheld = field.withheld {
                lines.append("\(pad)\(field.field): <\(withheld)>\(suffix)")
            }
        }
    }
}
