//
//  RPCWireTests.swift
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

/// Framing, grpc-web-text, trailer blocks and per-message compression
/// (protocol-engine doc §S8).
final class RPCWireTests: XCTestCase {
    private let body: [UInt8] = RPCFixtures.frame(RPCFixtures.helloRequest)
        + RPCFixtures.frame([], flags: 0)
        + RPCFixtures.frame(Array(repeating: 0x41, count: 300), flags: 1)
        + RPCFixtures.trailer("grpc-status: 0\r\n")

    // MARK: Framing

    func testFramesOfAWholeBody() {
        let split = RPCFrameReader.frames(in: Data(body))
        XCTAssertEqual(split.frames.count, 4)
        XCTAssertEqual(split.frames[0].payload, Data(RPCFixtures.helloRequest))
        XCTAssertEqual(split.frames[1].payload, Data())
        XCTAssertTrue(split.frames[2].isCompressed)
        XCTAssertEqual(split.frames[2].payload.count, 300)
        XCTAssertTrue(split.frames[3].isGRPCWebTrailer)
        XCTAssertEqual(split.frames.map(\.offset), [0, 5 + RPCFixtures.helloRequest.count, 10 + RPCFixtures.helloRequest.count, 315 + RPCFixtures.helloRequest.count])
        XCTAssertEqual(split.pendingBytes, 0)
    }

    func testFramingIsTheSameWhateverTheSplits() {
        let whole = RPCFrameReader.frames(in: Data(body)).frames
        // Byte at a time.
        var reader = RPCFrameReader()
        var oneByOne: [RPCFrame] = []
        for byte in body { oneByOne += reader.append(Data([byte])) }
        XCTAssertEqual(oneByOne, whole)
        XCTAssertEqual(reader.pendingByteCount, 0)
        // Every two-piece split, headers split included.
        for cut in 0 ... body.count {
            var r = RPCFrameReader()
            let frames = r.append(Data(body[..<cut])) + r.append(Data(body[cut...]))
            XCTAssertEqual(frames, whole, "split at \(cut)")
        }
    }

    func testAnIncompleteFrameIsPendingNeverShort() {
        // Two whole frames (10 + 5 bytes), then the 300-byte frame's header
        // and 100 of its bytes.
        let cut = Array(body.prefix(10 + 5 + 5 + 100))
        let split = RPCFrameReader.frames(in: Data(cut))
        XCTAssertEqual(split.frames.count, 2, "the 300-byte frame has not all arrived")
        XCTAssertEqual(split.pendingBytes, 105)
        XCTAssertEqual(split.pendingDeclaredLength, 300)
        // A header cut in two: no declared length yet.
        let headerOnly = RPCFrameReader.frames(in: Data([0, 0, 0]))
        XCTAssertEqual(headerOnly.pendingBytes, 3)
        XCTAssertNil(headerOnly.pendingDeclaredLength)
    }

    func testAHugeDeclaredLengthIsWaitedForNotAllocated() {
        let split = RPCFrameReader.frames(in: Data([0, 0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3]))
        XCTAssertTrue(split.frames.isEmpty)
        XCTAssertEqual(split.pendingDeclaredLength, 0xFFFF_FFFF)
    }

    // MARK: Trailer frame

    func testTheTrailerBlock() {
        let pairs = RPCHeaderBlock.parse(Data("grpc-status: 5\r\nGrpc-Message: user%2042%20not%20found\r\n\r\nno-colon-line\nx-a:  b \n".utf8))
        XCTAssertEqual(pairs, [
            RPCHeaderPair(name: "grpc-status", value: "5"),
            RPCHeaderPair(name: "grpc-message", value: "user%2042%20not%20found"),
            RPCHeaderPair(name: "x-a", value: "b"),
        ])
        XCTAssertEqual(RPCHeaderBlock.value("GRPC-STATUS", in: pairs), "5")
        XCTAssertEqual(RPCHeaderBlock.percentDecoded("user%2042%20not%20found"), "user 42 not found")
        XCTAssertEqual(RPCHeaderBlock.percentDecoded("100%"), "100%", "a bare % is kept")
        XCTAssertEqual(RPCHeaderBlock.percentDecoded("caf%C3%A9 %zz"), "café %zz")
    }

    // MARK: grpc-web-text

    func testGRPCWebTextDecodesSegmentsWithPaddingInTheMiddle() {
        let first = RPCFixtures.frame(RPCFixtures.helloReply)          // 14 bytes → padded
        let second = RPCFixtures.trailer("grpc-status: 0\r\n")        // separately encoded
        XCTAssertNotEqual(first.count % 3, 0, "the fixture must end its first segment in padding")
        let text = Data(first).base64EncodedString() + "\r\n" + Data(second).base64EncodedString()
        XCTAssertTrue(text.contains("="), text)
        let decoded = GRPCWebTextDecoder.decode(Data(text.utf8))
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.pendingCharacters, 0)
        XCTAssertEqual([UInt8](decoded.bytes), first + second)
        // And split anywhere.
        let all = Array(text.utf8)
        for cut in 0 ... all.count {
            var d = GRPCWebTextDecoder()
            let bytes = d.append(Data(all[..<cut])) + d.append(Data(all[cut...]))
            XCTAssertEqual([UInt8](bytes), first + second, "split at \(cut)")
        }
    }

    func testGRPCWebTextStopsAtTheFirstInvalidCharacter() {
        let good = Data(RPCFixtures.frame(RPCFixtures.helloReply)).base64EncodedString()
        let decoded = GRPCWebTextDecoder.decode(Data((good + "*AAAA").utf8))
        XCTAssertFalse(decoded.isValid)
        XCTAssertEqual([UInt8](decoded.bytes), RPCFixtures.frame(RPCFixtures.helloReply))
        XCTAssertFalse(GRPCWebTextDecoder.decode(Data("A=AA".utf8)).isValid, "padding in the wrong place")
        XCTAssertEqual(GRPCWebTextDecoder.decode(Data("QUJ".utf8)).pendingCharacters, 3)
    }

    // MARK: Compression

    func testGzipPerMessage() {
        let plain = RPCFixtures.user + RPCFixtures.user
        let packed = Data(RPCFixtures.gzip(plain))
        XCTAssertEqual(RPCMessageCompression.decompress(packed, encoding: "gzip"), .decoded(Data(plain)))
        XCTAssertEqual(RPCMessageCompression.decompress(packed, encoding: " GZIP "), .decoded(Data(plain)))
        XCTAssertEqual(RPCMessageCompression.decompress(Data(RPCFixtures.zlibWrapped(plain)), encoding: "deflate"), .decoded(Data(plain)))
        XCTAssertEqual(RPCMessageCompression.decompress(Data(plain), encoding: "identity"), .decoded(Data(plain)))
    }

    func testAnEncodingReqResDoesNotReadIsNamedNeverGuessed() {
        XCTAssertEqual(RPCMessageCompression.decompress(Data([1, 2, 3]), encoding: "snappy"), .unsupported("snappy"))
        XCTAssertEqual(RPCMessageCompression.decompress(Data([1, 2, 3]), encoding: nil), .unnamed)
        XCTAssertEqual(RPCMessageCompression.decompress(Data([1, 2, 3]), encoding: "gzip"), .failed("gzip"))
        let cut = Data(RPCFixtures.gzip(RPCFixtures.user).dropLast(6))
        XCTAssertEqual(RPCMessageCompression.decompress(cut, encoding: "gzip"), .failed("gzip"), "a cut stream does not inflate")
    }

    func testADecompressionBombStopsAtTheCap() {
        let bomb = Data(RPCFixtures.gzip([UInt8](repeating: 0, count: 200_000)))
        XCTAssertLessThan(bomb.count, 1_000)
        XCTAssertEqual(RPCMessageCompression.decompress(bomb, encoding: "gzip", maxBytes: 100_000), .tooLarge("gzip"))
    }
}
