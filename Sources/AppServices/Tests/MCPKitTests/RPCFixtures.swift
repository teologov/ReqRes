//
//  RPCFixtures.swift
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
//  Hand-built gRPC / gRPC-Web / Connect wire bytes for the RPC tests
//  (protocol-engine doc §S8): a tiny protobuf ENCODER (the opposite of what
//  is under test, so a decoder bug cannot hide in a shared helper), frames,
//  and gzip through the system zlib.
//

import Foundation
import zlib
@testable import MCPKit

enum PB {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func key(_ field: Int, _ wire: Int) -> [UInt8] { varint(UInt64(field << 3 | wire)) }
    static func uint(_ field: Int, _ value: UInt64) -> [UInt8] { key(field, 0) + varint(value) }
    static func len(_ field: Int, _ bytes: [UInt8]) -> [UInt8] { key(field, 2) + varint(UInt64(bytes.count)) + bytes }
    static func string(_ field: Int, _ text: String) -> [UInt8] { len(field, Array(text.utf8)) }
    static func fixed32(_ field: Int, _ value: UInt32) -> [UInt8] {
        key(field, 5) + (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }
    static func fixed64(_ field: Int, _ value: UInt64) -> [UInt8] {
        key(field, 1) + (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }
    static func packed(_ field: Int, _ values: [UInt64]) -> [UInt8] { len(field, values.flatMap(varint)) }
}

enum RPCFixtures {
    /// A 5-byte-prefixed frame.
    static func frame(_ payload: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        let n = UInt32(payload.count)
        return [flags, UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + payload
    }

    static func trailer(_ block: String) -> [UInt8] { frame(Array(block.utf8), flags: 0x80) }

    /// helloworld.HelloRequest { name = "Ann" }
    static let helloRequest = PB.string(1, "Ann")
    /// helloworld.HelloReply { message = "Hello Ann" }
    static let helloReply = PB.string(1, "Hello Ann")

    /// A user record with a nested address, a packed repeated field, a
    /// string, raw bytes, a fixed32 and a fixed64.
    static let user: [UInt8] = PB.uint(1, 42)
        + PB.string(2, "Ann")
        + PB.len(3, PB.string(1, "Amsterdam") + PB.uint(2, 1011))
        + PB.packed(4, [1, 2, 300])
        + PB.len(5, [0x00, 0xFF, 0xFE, 0x01])
        + PB.fixed32(6, 0x3F80_0000)
        + PB.fixed64(7, 7)

    static func headers(_ pairs: [(String, String)]) -> [RPCHeaderPair] {
        pairs.map { RPCHeaderPair(name: $0.0, value: $0.1) }
    }

    /// A gRPC-Web unary call answered with `status` in its trailer frame.
    static func grpcWeb(status: Int = 0, message: String? = nil, reply: [UInt8] = helloReply,
                        path: String = "/helloworld.Greeter/SayHello") -> RPCExchangeInput {
        var trailerBlock = "grpc-status: \(status)\r\n"
        if let message { trailerBlock += "grpc-message: \(message)\r\n" }
        trailerBlock += "x-trace: abc\r\n"
        let body = (status == 0 ? frame(reply) : []) + trailer(trailerBlock)
        return RPCExchangeInput(
            path: path, httpStatus: 200,
            requestHeaders: headers([("content-type", "application/grpc-web+proto"), ("x-grpc-web", "1")]),
            responseHeaders: headers([("content-type", "application/grpc-web+proto")]),
            requestBody: Data(frame(helloRequest)), responseBody: Data(body)
        )
    }

    static func gzip(_ bytes: [UInt8]) -> [UInt8] {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return [] }
        defer { deflateEnd(&stream) }
        var input = bytes
        var output = [UInt8](repeating: 0, count: bytes.count + 64)
        let produced: Int = input.withUnsafeMutableBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = inBuf.baseAddress
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                _ = deflate(&stream, Z_FINISH)
                return outBuf.count - Int(stream.avail_out)
            }
        }
        return Array(output.prefix(produced))
    }

    static func zlibWrapped(_ bytes: [UInt8]) -> [UInt8] {
        var stream = z_stream()
        guard deflateInit_(&stream, Z_DEFAULT_COMPRESSION, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return [] }
        defer { deflateEnd(&stream) }
        var input = bytes
        var output = [UInt8](repeating: 0, count: bytes.count + 64)
        let produced: Int = input.withUnsafeMutableBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = inBuf.baseAddress
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                _ = deflate(&stream, Z_FINISH)
                return outBuf.count - Int(stream.avail_out)
            }
        }
        return Array(output.prefix(produced))
    }
}

/// A provider with RPC rows (and summaries for the list filter).
final class StubRPCProvider: MCPSessionProviding {
    var summaries: [MCPSessionSummary] = []
    var rpc: [String: MCPSessionRPCFacts] = [:]

    func sessionSummaries() -> [MCPSessionSummary] { summaries }
    func sessionDetail(uid: String) -> MCPSessionDetail? { summaries.first { $0.uid == uid }.map { MCPSessionDetail(summary: $0) } }
    func sessionBody(uid: String, side: MCPBodySide) -> String? { nil }
    func sessionRPCFacts(uid: String) -> MCPSessionRPCFacts? { rpc[uid] }
}
