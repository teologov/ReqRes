//
//  ProtobufDecoder.swift
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
//  A SCHEMA-LESS protobuf reader (protocol PRD Phase 6.1, decision D12;
//  protocol-engine doc §S8): what `protoc --decode_raw` shows, as data.
//  Without the .proto there are no field names and no types — only field
//  numbers, wire types and the bytes. A length-delimited field is ambiguous
//  (a nested message, a string, bytes or packed numbers all look alike), so
//  it is read as printable text, else a clean nested message, else bytes —
//  and the other readings that also fit are offered beside it.
//
//  It reads bytes off the network, so it NEVER traps: every length is
//  compared with what is left before it is used, a varint longer than ten
//  bytes is invalid, nesting stops at `maxDepth`, and the work done on
//  nested guesses is bounded by a field budget. The fuzz test feeds it
//  thousands of random and mutated inputs.
//

import Foundation

/// A field's wire type (the low three bits of its key).
public enum ProtoWireType: Int, Codable, Equatable, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5

    /// How it is named on the agent surface and in the tab.
    public var token: String {
        switch self {
        case .varint: return "varint"
        case .fixed64: return "i64"
        case .lengthDelimited: return "len"
        case .fixed32: return "i32"
        }
    }
}

/// How a length-delimited field is read.
public enum ProtoReading: Equatable, Sendable {
    /// It parses cleanly as a message and is not printable text.
    case message([ProtoField])
    /// Valid, printable UTF-8 (or empty).
    case text(String)
    /// Neither.
    case bytes
}

public struct ProtoLengthDelimited: Equatable, Sendable {
    /// The field's length in bytes, as sent.
    public var byteCount: Int
    public var reading: ProtoReading
    /// The bytes, kept only for a `.bytes` reading (a message or text reading
    /// carries its content already; keeping every level's bytes would hold a
    /// deep message many times over).
    public var bytes: Data?
    /// A `.text` reading whose bytes ALSO parse cleanly as a message
    /// (`"hi"` is field 13 = 105; `"Amsterdam"` is field 8, an i64). Text
    /// wins — a real nested message is almost never printable, because its
    /// keys and short lengths are control bytes — and the other reading is
    /// named, so a person or an agent can doubt it.
    public var alsoParsesAsMessage: Bool
    /// The packed-repeated-varint reading (a `repeated int32` field is sent
    /// as a run of varints), offered for a `.bytes` reading, and for a
    /// `.message` reading made only of varint fields (`08 01` is both
    /// `{1: 1}` and `[8, 1]`). Never for text: every ASCII string is a run of
    /// one-byte varints. Only for fields up to
    /// `ProtobufDecoder.alternativeReadingMaxBytes`.
    public var packedVarints: [UInt64]?

    public init(byteCount: Int, reading: ProtoReading, bytes: Data? = nil, alsoParsesAsMessage: Bool = false, packedVarints: [UInt64]? = nil) {
        self.byteCount = byteCount
        self.reading = reading
        self.bytes = bytes
        self.alsoParsesAsMessage = alsoParsesAsMessage
        self.packedVarints = packedVarints
    }
}

public enum ProtoValue: Equatable, Sendable {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case lengthDelimited(ProtoLengthDelimited)

    public var wireType: ProtoWireType {
        switch self {
        case .varint: return .varint
        case .fixed64: return .fixed64
        case .fixed32: return .fixed32
        case .lengthDelimited: return .lengthDelimited
        }
    }
}

public struct ProtoField: Equatable, Sendable {
    /// The field number (1 … 2^29 − 1). No name: there is no schema.
    public var number: Int
    public var value: ProtoValue

    public init(number: Int, value: ProtoValue) {
        self.number = number
        self.value = value
    }
}

/// A decoded message: its fields, and what the decoder had to give up on.
public struct ProtoMessage: Equatable, Sendable {
    public var fields: [ProtoField]
    /// Fields past `ProtobufDecoder.maxTopLevelFields` at the top level were
    /// not read (the message is shown in part, and says so).
    public var fieldsNotShown: Bool
    /// The nested-reading budget ran out: some length-delimited fields that
    /// might be messages are shown as text or bytes instead.
    public var nestedReadingStopped: Bool

    public init(fields: [ProtoField], fieldsNotShown: Bool = false, nestedReadingStopped: Bool = false) {
        self.fields = fields
        self.fieldsNotShown = fieldsNotShown
        self.nestedReadingStopped = nestedReadingStopped
    }
}

public enum ProtobufDecoder {
    /// Nested messages deeper than this are shown as text or bytes.
    public static let maxDepth = 32
    /// Fields read at the top level of one message.
    public static let maxTopLevelFields = 20_000
    /// Fields read across every nested GUESS in one message (successful or
    /// not). Bounds the work: each byte is re-read at most once per depth
    /// level, and this caps the total.
    public static let nestedFieldBudget = 50_000
    /// The packed-varint alternative is only computed for fields this short.
    public static let alternativeReadingMaxBytes = 1_024

    /// The message `data` holds, or nil when it is not a clean protobuf
    /// message: a bad key, a length past the end, a varint over ten bytes, a
    /// group (wire types 3 and 4, deprecated and unreadable without a schema),
    /// or a reserved wire type. An empty payload is an empty message.
    public static func decode(_ data: Data) -> ProtoMessage? {
        let bytes = [UInt8](data)
        var budget = nestedFieldBudget
        var stopped = false
        var truncated = false
        guard let fields = parse(bytes, 0 ..< bytes.count, depth: 0, budget: &budget, stopped: &stopped,
                                 topLevelLimit: maxTopLevelFields, truncated: &truncated) else { return nil }
        return ProtoMessage(fields: fields, fieldsNotShown: truncated, nestedReadingStopped: stopped)
    }

    // MARK: - Parsing

    private static func parse(
        _ bytes: [UInt8],
        _ range: Range<Int>,
        depth: Int,
        budget: inout Int,
        stopped: inout Bool,
        topLevelLimit: Int?,
        truncated: inout Bool
    ) -> [ProtoField]? {
        var fields: [ProtoField] = []
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            if let limit = topLevelLimit {
                if fields.count >= limit {
                    // Keep reading KEYS to prove the rest is well formed,
                    // but stop keeping fields.
                    guard skipRest(bytes, from: i, to: end) else { return nil }
                    truncated = true
                    return fields
                }
            } else {
                // A nested guess: out of budget means "not read as a
                // message", which the caller turns into text or bytes.
                guard budget > 0 else {
                    stopped = true
                    return nil
                }
                budget -= 1
            }
            guard let (key, afterKey) = readVarint(bytes, i, end) else { return nil }
            i = afterKey
            let rawNumber = key >> 3
            guard rawNumber >= 1, rawNumber <= 536_870_911 else { return nil }
            let number = Int(rawNumber)
            switch key & 0x07 {
            case 0:
                guard let (value, next) = readVarint(bytes, i, end) else { return nil }
                fields.append(ProtoField(number: number, value: .varint(value)))
                i = next
            case 1:
                guard end - i >= 8 else { return nil }
                var value: UInt64 = 0
                for k in 0 ..< 8 { value |= UInt64(bytes[i + k]) << (8 * UInt64(k)) }
                fields.append(ProtoField(number: number, value: .fixed64(value)))
                i += 8
            case 5:
                guard end - i >= 4 else { return nil }
                var value: UInt32 = 0
                for k in 0 ..< 4 { value |= UInt32(bytes[i + k]) << (8 * UInt32(k)) }
                fields.append(ProtoField(number: number, value: .fixed32(value)))
                i += 4
            case 2:
                guard let (length, next) = readVarint(bytes, i, end) else { return nil }
                guard length <= UInt64(end - next) else { return nil }
                let sub = next ..< next + Int(length)
                fields.append(ProtoField(number: number, value: .lengthDelimited(
                    interpret(bytes, sub, depth: depth + 1, budget: &budget, stopped: &stopped))))
                i = sub.upperBound
            default:
                // 3/4 (groups) and 6/7 (reserved).
                return nil
            }
        }
        return fields
    }

    /// Validates the rest of a top-level message without keeping it.
    private static func skipRest(_ bytes: [UInt8], from start: Int, to end: Int) -> Bool {
        var i = start
        while i < end {
            guard let (key, afterKey) = readVarint(bytes, i, end) else { return false }
            i = afterKey
            guard key >> 3 >= 1, key >> 3 <= 536_870_911 else { return false }
            switch key & 0x07 {
            case 0:
                guard let (_, next) = readVarint(bytes, i, end) else { return false }
                i = next
            case 1:
                guard end - i >= 8 else { return false }
                i += 8
            case 5:
                guard end - i >= 4 else { return false }
                i += 4
            case 2:
                guard let (length, next) = readVarint(bytes, i, end), length <= UInt64(end - next) else { return false }
                i = next + Int(length)
            default:
                return false
            }
        }
        return true
    }

    /// Reads a length-delimited field. Order: printable text, then a clean
    /// message, then bytes — see `ProtoLengthDelimited.alsoParsesAsMessage`
    /// for why text is tried first (protocol-engine doc §S8, "Traps").
    private static func interpret(_ bytes: [UInt8], _ range: Range<Int>, depth: Int, budget: inout Int, stopped: inout Bool) -> ProtoLengthDelimited {
        if range.isEmpty {
            return ProtoLengthDelimited(byteCount: 0, reading: .text(""))
        }
        let small = range.count <= alternativeReadingMaxBytes
        var nested: [ProtoField]?
        if depth <= maxDepth {
            var ignored = false
            nested = parse(bytes, range, depth: depth, budget: &budget, stopped: &stopped, topLevelLimit: nil, truncated: &ignored)
        }
        if let text = printableText(bytes[range]) {
            return ProtoLengthDelimited(byteCount: range.count, reading: .text(text), alsoParsesAsMessage: nested != nil)
        }
        if let nested {
            let allVarints = nested.allSatisfy { $0.value.wireType == .varint }
            return ProtoLengthDelimited(byteCount: range.count, reading: .message(nested),
                                        packedVarints: small && allVarints ? packedVarints(bytes, range) : nil)
        }
        return ProtoLengthDelimited(byteCount: range.count, reading: .bytes, bytes: Data(bytes[range]),
                                    packedVarints: small ? packedVarints(bytes, range) : nil)
    }

    /// A varint at `i`, at most ten bytes, the tenth carrying at most one
    /// bit; nil when it runs past `end` or is longer.
    static func readVarint(_ bytes: [UInt8], _ start: Int, _ end: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < end, shift < 70 {
            let byte = bytes[i]
            i += 1
            if shift == 63 {
                // The tenth byte: only its lowest bit fits in 64.
                guard byte <= 1 else { return nil }
            }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (value, i) }
            shift += 7
        }
        return nil
    }

    /// The bytes as a run of varints, or nil (an empty run is not a reading).
    static func packedVarints(_ bytes: [UInt8], _ range: Range<Int>) -> [UInt64]? {
        guard !range.isEmpty else { return nil }
        var values: [UInt64] = []
        var i = range.lowerBound
        while i < range.upperBound {
            guard let (value, next) = readVarint(bytes, i, range.upperBound) else { return nil }
            values.append(value)
            i = next
        }
        return values
    }

    /// Valid UTF-8 with no control characters but tab, LF and CR (and no
    /// C1 controls or DEL): text a person would recognise as text.
    static func printableText(_ bytes: ArraySlice<UInt8>) -> String? {
        guard let string = String(bytes: bytes, encoding: .utf8) else { return nil }
        for scalar in string.unicodeScalars {
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D { continue }
            if v < 0x20 || v == 0x7F || (0x80 ... 0x9F).contains(v) { return nil }
        }
        return string
    }

    // MARK: - Numeric readings

    /// A varint's other readings: signed 64-bit (two's complement) when it
    /// does not fit in Int64, and zig-zag (`sint32`/`sint64`) when it differs.
    public static func varintAlternatives(_ value: UInt64) -> [String] {
        var readings: [String] = []
        if value > UInt64(Int64.max) {
            readings.append("int64 \(Int64(bitPattern: value))")
        }
        let zigzag = Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
        if zigzag >= 0 ? UInt64(zigzag) != value : true {
            readings.append("sint \(zigzag)")
        }
        return readings
    }

    public static func fixed64Alternatives(_ value: UInt64) -> [String] {
        var readings: [String] = []
        if value > UInt64(Int64.max) { readings.append("sfixed64 \(Int64(bitPattern: value))") }
        let double = Double(bitPattern: value)
        if double.isFinite { readings.append("double \(double)") }
        return readings
    }

    public static func fixed32Alternatives(_ value: UInt32) -> [String] {
        var readings: [String] = []
        if value > UInt32(Int32.max) { readings.append("sfixed32 \(Int32(bitPattern: value))") }
        let float = Float(bitPattern: value)
        if float.isFinite { readings.append("float \(float)") }
        return readings
    }
}
