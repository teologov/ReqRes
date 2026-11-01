//
//  ProtobufDecoderTests.swift
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

import XCTest
@testable import MCPKit

/// The schema-less protobuf reader (protocol-engine doc §S8), and the fuzz
/// test that says it never traps on anything the network can send.
final class ProtobufDecoderTests: XCTestCase {
    private func delimited(_ field: ProtoField) -> ProtoLengthDelimited? {
        if case .lengthDelimited(let d) = field.value { return d }
        return nil
    }

    func testAHandBuiltMessageWithNestedPackedStringAndBytesFields() throws {
        let message = try XCTUnwrap(ProtobufDecoder.decode(Data(RPCFixtures.user)))
        XCTAssertFalse(message.fieldsNotShown)
        XCTAssertFalse(message.nestedReadingStopped)
        XCTAssertEqual(message.fields.map(\.number), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(message.fields[0].value, .varint(42))

        let name = try XCTUnwrap(delimited(message.fields[1]))
        XCTAssertEqual(name.reading, .text("Ann"))
        XCTAssertEqual(name.byteCount, 3)

        let address = try XCTUnwrap(delimited(message.fields[2]))
        guard case .message(let nested) = address.reading else { return XCTFail("the address is a nested message") }
        XCTAssertEqual(nested.count, 2)
        XCTAssertEqual(delimited(nested[0])?.reading, .text("Amsterdam"))
        XCTAssertEqual(nested[1].value, .varint(1011))

        // [1, 2, 300] packed: 01 02 ac 02 — not a message (field 0), not
        // printable text; bytes, with the packed reading offered.
        let packed = try XCTUnwrap(delimited(message.fields[3]))
        XCTAssertEqual(packed.reading, .bytes)
        XCTAssertEqual(packed.packedVarints, [1, 2, 300])
        XCTAssertEqual(packed.bytes, Data([1, 2, 0xAC, 0x02]))

        let raw = try XCTUnwrap(delimited(message.fields[4]))
        XCTAssertEqual(raw.reading, .bytes)
        XCTAssertEqual(raw.bytes, Data([0x00, 0xFF, 0xFE, 0x01]))
        // 00 | ff fe 01 happens to be a run of varints too; offered, not preferred.
        XCTAssertEqual(raw.packedVarints, [0, 32_639])
        XCTAssertEqual(message.fields[5].value, .fixed32(0x3F80_0000))
        XCTAssertEqual(ProtobufDecoder.fixed32Alternatives(0x3F80_0000), ["float 1.0"])
        XCTAssertEqual(message.fields[6].value, .fixed64(7))
    }

    func testPrintableTextWinsOverAnAccidentalMessageWhichIsNamed() throws {
        // "Amsterdam" is also field 8, an i64 ("msterdam"); "hi" is field 13
        // = 105. Text wins; the other reading is named.
        for word in ["Amsterdam", "hi"] {
            let message = try XCTUnwrap(ProtobufDecoder.decode(Data(PB.string(1, word))))
            let field = try XCTUnwrap(delimited(message.fields[0]))
            XCTAssertEqual(field.reading, .text(word))
            XCTAssertTrue(field.alsoParsesAsMessage, word)
            XCTAssertNil(field.packedVarints, "every ASCII string is a run of varints; never offered for text")
        }
        let hello = try XCTUnwrap(ProtobufDecoder.decode(Data(PB.string(1, "hello world"))))
        XCTAssertFalse(try XCTUnwrap(delimited(hello.fields[0])).alsoParsesAsMessage)
        // A real nested message is not printable (its keys and lengths are
        // control bytes), so it still reads as one.
        let nested = try XCTUnwrap(ProtobufDecoder.decode(Data(PB.len(1, PB.string(1, "Amsterdam") + PB.uint(2, 7)))))
        guard case .message(let inner) = try XCTUnwrap(delimited(nested.fields[0])).reading else { return XCTFail() }
        XCTAssertEqual(inner.count, 2)
        // `08 01` is both {1: 1} and packed [8, 1]: the packed reading is
        // offered beside a message made only of varints.
        let ambiguous = try XCTUnwrap(ProtobufDecoder.decode(Data(PB.len(1, [0x08, 0x01]))))
        XCTAssertEqual(delimited(ambiguous.fields[0])?.packedVarints, [8, 1])
        // An empty field is empty text.
        let empty = try XCTUnwrap(ProtobufDecoder.decode(Data(PB.len(2, []))))
        XCTAssertEqual(delimited(empty.fields[0])?.reading, .text(""))
    }

    func testVarintEdges() throws {
        XCTAssertEqual(ProtobufDecoder.decode(Data(PB.uint(1, .max)))?.fields.first?.value, .varint(.max))
        // Eleven bytes: invalid. Ten with a large last byte: invalid.
        XCTAssertNil(ProtobufDecoder.decode(Data([0x08] + [UInt8](repeating: 0xFF, count: 10) + [0x01])))
        XCTAssertNil(ProtobufDecoder.decode(Data([0x08] + [UInt8](repeating: 0xFF, count: 9) + [0x02])))
        XCTAssertNil(ProtobufDecoder.decode(Data([0x08, 0x80])), "a varint cut short")
        XCTAssertEqual(ProtobufDecoder.varintAlternatives(UInt64.max), ["int64 -1", "sint -9223372036854775808"])
        XCTAssertEqual(ProtobufDecoder.varintAlternatives(3), ["sint -2"])
        XCTAssertEqual(ProtobufDecoder.varintAlternatives(0), [])
    }

    func testWhatIsNotACleanMessage() {
        XCTAssertNil(ProtobufDecoder.decode(Data([0x00, 0x01])), "field number 0")
        XCTAssertNil(ProtobufDecoder.decode(Data([0x0B, 0x0C])), "a group (wire types 3 and 4)")
        XCTAssertNil(ProtobufDecoder.decode(Data([0x0E])), "reserved wire type 6")
        XCTAssertNil(ProtobufDecoder.decode(Data([0x0A, 0x05, 0x01])), "a length past the end")
        XCTAssertNil(ProtobufDecoder.decode(Data([0x0D, 0x01, 0x02])), "a fixed32 cut short")
        XCTAssertNil(ProtobufDecoder.decode(Data([0x0A] + PB.varint(UInt64.max))), "a length that does not fit")
        XCTAssertEqual(ProtobufDecoder.decode(Data())?.fields, [], "an empty payload is an empty message")
    }

    func testNestingStopsAtTheDepthLimit() throws {
        var bytes = PB.uint(1, 1)
        for _ in 0 ..< 40 { bytes = PB.len(1, bytes) }
        let message = try XCTUnwrap(ProtobufDecoder.decode(Data(bytes)))
        var depth = 0
        var fields = message.fields
        while let field = fields.first, case .lengthDelimited(let d) = field.value, case .message(let nested) = d.reading {
            depth += 1
            fields = nested
        }
        XCTAssertEqual(depth, ProtobufDecoder.maxDepth, "nested readings stop at \(ProtobufDecoder.maxDepth)")
        if case .lengthDelimited(let d) = fields.first?.value {
            XCTAssertNotEqual(d.reading, .text(""), "the rest is text or bytes")
        } else {
            XCTFail("the deepest field is length-delimited")
        }
    }

    func testTheNestedBudgetDegradesToBytesNeverToFailure() throws {
        // 30,000 nested messages of three fields: the budget (50,000 field reads) runs
        // out part-way, the top level still decodes whole.
        var bytes: [UInt8] = []
        for i in 0 ..< 30_000 { bytes += PB.len(1, PB.uint(1, UInt64(i)) + PB.uint(2, 1) + PB.uint(3, 2)) }
        let message = try XCTUnwrap(ProtobufDecoder.decode(Data(bytes)))
        XCTAssertEqual(message.fields.count, 20_000, "the top level is capped")
        XCTAssertTrue(message.fieldsNotShown)
        XCTAssertTrue(message.nestedReadingStopped)
    }

    // MARK: - Fuzz

    /// SplitMix64: seeded, so a failure reproduces.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Thousands of random and mutated inputs through EVERY consumer of the
    /// decoder — the protobuf reader, the frame reader, grpc-web-text, the
    /// exchange decoder, the tab's lines and the agent egress. A trap in any
    /// of them kills the test process, which is the failure this catches.
    func testNothingTrapsOnRandomOrMutatedInput() {
        var rng = Seeded(state: 0x5EED_0F_62_2026)
        let corpus: [[UInt8]] = [
            RPCFixtures.user,
            RPCFixtures.helloReply,
            PB.len(1, RPCFixtures.user) + PB.packed(2, [0, 1, 127, 128, .max]),
            RPCFixtures.frame(RPCFixtures.user) + RPCFixtures.trailer("grpc-status: 3\r\ngrpc-message: bad%20thing\r\n"),
            RPCFixtures.frame(RPCFixtures.gzip(RPCFixtures.user), flags: 1),
        ]
        var decoded = 0
        let start = Date()
        for iteration in 0 ..< 6_000 {
            var input: [UInt8]
            if iteration % 3 == 0 {
                let length = Int(rng.next() % 256)
                input = (0 ..< length).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            } else {
                input = corpus[Int(rng.next() % UInt64(corpus.count))]
                let mutations = 1 + Int(rng.next() % 6)
                for _ in 0 ..< mutations where !input.isEmpty {
                    let position = Int(rng.next() % UInt64(input.count))
                    switch rng.next() % 5 {
                    case 0: input[position] = UInt8(truncatingIfNeeded: rng.next())
                    case 1: input.remove(at: position)
                    case 2: input.insert(UInt8(truncatingIfNeeded: rng.next()), at: position)
                    case 3: input = Array(input.prefix(position))
                    default: input[position] ^= 1 << UInt8(rng.next() % 8)
                    }
                }
            }
            let data = Data(input)
            if let message = ProtobufDecoder.decode(data) {
                decoded += 1
                _ = RPCPresentation.lines(RPCMessage(direction: .response, number: 1, wireBytes: data.count, compressed: false, content: .protobuf(message)))
                var budget = MCPRPCEgress.fieldBudgetPerMessage
                var cut = false
                _ = MCPRPCEgress.fields(message.fields, redacting: iteration % 2 == 0, budget: &budget, cut: &cut)
                // Deterministic.
                XCTAssertEqual(ProtobufDecoder.decode(data), message)
            }
            _ = GRPCWebTextDecoder.decode(data)
            for proto in ["application/grpc-web+proto", "application/grpc-web-text", "application/connect+proto", "application/grpc", "application/proto"] {
                let exchange = RPCExchangeInput(
                    path: "/a.B/C", httpStatus: iteration % 7 == 0 ? 503 : 200,
                    requestHeaders: [RPCHeaderPair(name: "content-type", value: proto), RPCHeaderPair(name: "grpc-encoding", value: "gzip"),
                                     RPCHeaderPair(name: "connect-content-encoding", value: "gzip"),
                                     RPCHeaderPair(name: "connect-protocol-version", value: "1")],
                    responseHeaders: [RPCHeaderPair(name: "grpc-encoding", value: "gzip")],
                    requestBody: data, responseBody: data
                )
                if let rpc = RPCExchange.decode(exchange) {
                    for message in rpc.requestMessages + rpc.responseMessages {
                        _ = RPCPresentation.lines(message)
                        _ = MCPRPCEgress.egress(message, redacting: true)
                    }
                    _ = RPCPresentation.statusLine(rpc)
                }
            }
        }
        XCTAssertGreaterThan(decoded, 500, "the mutated corpus must reach the nested paths, not only fail at the first byte")
        XCTAssertLessThan(Date().timeIntervalSince(start), 30, "fast enough to run on every test pass")
    }
}
