//
//  RPCWire.swift
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
//  The bytes of a gRPC, gRPC-Web or Connect body (protocol PRD Phase 6.1;
//  protocol-engine doc §S8): the 5-byte length prefix, the gRPC-Web trailer
//  frame, `application/grpc-web-text` (base64, possibly in several padded
//  segments), and per-message compression. Foundation plus the system zlib
//  (a C dylib — never a second copy of anything the core links).
//
//  Everything here reads bytes from the network, so nothing here traps: no
//  force-unwrap, no unchecked arithmetic on a length, no allocation sized by
//  a length the bytes merely CLAIM.
//

import Foundation
import zlib

// MARK: - Framing

/// One length-prefixed message: gRPC and gRPC-Web's "Length-Prefixed-Message"
/// and Connect's "envelope" are the same five bytes — a flags byte and a
/// big-endian UInt32 length — followed by the payload.
public struct RPCFrame: Equatable, Sendable {
    /// The flags byte as sent.
    public var flags: UInt8
    public var payload: Data
    /// Where the frame's flags byte sits in the body (after base64 decoding
    /// for grpc-web-text).
    public var offset: Int

    public init(flags: UInt8, payload: Data, offset: Int) {
        self.flags = flags
        self.payload = payload
        self.offset = offset
    }

    /// Bit 0: the payload is compressed with the message encoding the
    /// headers name (`grpc-encoding`, or `connect-content-encoding`).
    public var isCompressed: Bool { flags & 0x01 != 0 }
    /// gRPC-Web: the MSB marks the trailer frame, whose payload is an HTTP/1
    /// header block (`grpc-status: 0\r\n…`).
    public var isGRPCWebTrailer: Bool { flags & 0x80 != 0 }
    /// Connect streaming: 0x02 marks the end-of-stream message, a JSON
    /// `{"error": …, "metadata": …}`.
    public var isConnectEndStream: Bool { flags & 0x02 != 0 }
}

/// Splits a body into frames, incrementally: bytes may arrive in any pieces
/// (one at a time, a header split across two, a payload across ten) and the
/// frames that come out are the same as from the whole body at once.
///
/// A frame whose bytes have not all arrived is NEVER returned: it is
/// `pendingByteCount` (and its declared length, when the header arrived), so
/// a cut body reads as "N messages and an incomplete one", never as a short
/// message.
public struct RPCFrameReader: Sendable {
    public static let headerLength = 5

    private var buffer: [UInt8] = []
    /// Where the unread bytes start in `buffer` (compacted now and then, so
    /// a long body is not re-copied per frame).
    private var start = 0
    /// Body offset of `buffer[start]`.
    private var bodyOffset = 0

    public init() {}

    /// The frames `data` completed, in order.
    public mutating func append(_ data: Data) -> [RPCFrame] {
        guard !data.isEmpty else { return [] }
        buffer.append(contentsOf: data)
        var frames: [RPCFrame] = []
        while buffer.count - start >= Self.headerLength {
            let flags = buffer[start]
            let length = Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16
                | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
            let available = buffer.count - start - Self.headerLength
            guard length <= available else { break }
            let payloadStart = start + Self.headerLength
            frames.append(RPCFrame(flags: flags, payload: Data(buffer[payloadStart ..< payloadStart + length]), offset: bodyOffset))
            start = payloadStart + length
            bodyOffset += Self.headerLength + length
        }
        if start > 0, start >= buffer.count / 2 {
            buffer.removeFirst(start)
            start = 0
        }
        return frames
    }

    /// Bytes received that are not (yet) a whole frame.
    public var pendingByteCount: Int { buffer.count - start }

    /// The length the incomplete frame's header declares, once its five
    /// header bytes have arrived.
    public var pendingDeclaredLength: Int? {
        guard buffer.count - start >= Self.headerLength else { return nil }
        return Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16
            | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
    }

    /// The whole body at once.
    public static func frames(in data: Data) -> (frames: [RPCFrame], pendingBytes: Int, pendingDeclaredLength: Int?) {
        var reader = RPCFrameReader()
        let frames = reader.append(data)
        return (frames, reader.pendingByteCount, reader.pendingDeclaredLength)
    }
}

// MARK: - grpc-web-text

/// `application/grpc-web-text`: the framed bytes, base64-encoded. A server
/// may encode each frame (or each flush) separately and send the segments
/// back to back, each with its own `=` padding — so padding may appear in
/// the MIDDLE of a body, where an ordinary base64 decoder gives up. This one
/// decodes quantum by quantum, a padded quantum closing its segment.
///
/// Incremental like the frame reader: characters may arrive split anywhere.
/// Whitespace (a client that wrapped lines) is skipped. The first character
/// that is not base64 stops it: `isValid` turns false and later input is
/// ignored, so the frames decoded before it still read.
public struct GRPCWebTextDecoder: Sendable {
    /// The characters of the quantum being read, packed; `count` of them.
    private var quantum: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    private var count = 0
    public private(set) var isValid = true

    public init() {}

    /// The bytes `text` completed (whole quanta only). Decoded straight into
    /// one buffer — the quantum is four bytes on the stack, not an array
    /// allocated per group (release review, 2026-09-29: a 12 MB body took
    /// 170 ms on main the first time its row was drawn).
    public mutating func append(_ text: Data) -> Data {
        guard isValid else { return Data() }
        var out = [UInt8]()
        out.reserveCapacity(text.count / 4 * 3 + 3)
        let pad = UInt8(ascii: "=")
        for char in text {
            if char == 0x20 || char == 0x0A || char == 0x0D || char == 0x09 { continue }
            guard char == pad || Self.value(of: char) != nil else {
                isValid = false
                return Data(out)
            }
            switch count {
            case 0: quantum.0 = char
            case 1: quantum.1 = char
            case 2: quantum.2 = char
            default: quantum.3 = char
            }
            count += 1
            if count == 4 {
                count = 0
                guard Self.decodeQuantum(quantum, into: &out) else {
                    isValid = false
                    return Data(out)
                }
            }
        }
        return Data(out)
    }

    /// Characters of an incomplete quantum at the end.
    public var pendingCharacters: Int { count }

    public static func decode(_ text: Data) -> (bytes: Data, isValid: Bool, pendingCharacters: Int) {
        var decoder = GRPCWebTextDecoder()
        let bytes = decoder.append(text)
        return (bytes, decoder.isValid, decoder.pendingCharacters)
    }

    @inline(__always)
    private static func value(of char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"): return char - UInt8(ascii: "A")
        case UInt8(ascii: "a") ... UInt8(ascii: "z"): return char - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return char - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"): return 62
        case UInt8(ascii: "/"): return 63
        default: return nil
        }
    }

    /// Four characters → 1…3 bytes appended to `out`; false for padding in
    /// the wrong place.
    private static func decodeQuantum(_ q: (UInt8, UInt8, UInt8, UInt8), into out: inout [UInt8]) -> Bool {
        let pad = UInt8(ascii: "=")
        guard let a = value(of: q.0), let b = value(of: q.1) else { return false }
        let first = a << 2 | b >> 4
        if q.2 == pad {
            guard q.3 == pad else { return false }
            out.append(first)
            return true
        }
        guard let c = value(of: q.2) else { return false }
        let second = (b & 0x0F) << 4 | c >> 2
        if q.3 == pad {
            out.append(first)
            out.append(second)
            return true
        }
        guard let d = value(of: q.3) else { return false }
        out.append(first)
        out.append(second)
        out.append((c & 0x03) << 6 | d)
        return true
    }
}

// MARK: - Header blocks (the gRPC-Web trailer frame)

/// One header as recorded, name lowercased.
public struct RPCHeaderPair: Codable, Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum RPCHeaderBlock {
    /// The trailer frame's payload — `grpc-status: 5\r\ngrpc-message: …\r\n`
    /// — as ordered pairs. Lines split on CRLF or LF; a line with no colon is
    /// skipped; names lowercased and trimmed, values trimmed. Invalid UTF-8
    /// reads with U+FFFD rather than failing the block.
    public static func parse(_ data: Data) -> [RPCHeaderPair] {
        let text = String(decoding: data, as: UTF8.self)
        var pairs: [RPCHeaderPair] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let name = rawLine[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            let value = rawLine[rawLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            pairs.append(RPCHeaderPair(name: name, value: value))
        }
        return pairs
    }

    /// The first value named `name` (case-insensitive).
    public static func value(_ name: String, in pairs: [RPCHeaderPair]) -> String? {
        let wanted = name.lowercased()
        return pairs.first { $0.name.lowercased() == wanted }?.value
    }

    /// `grpc-message` is percent-encoded UTF-8 (gRPC over HTTP/2, "Status-Message").
    /// A `%` not followed by two hex digits is kept as sent; the bytes are
    /// read as UTF-8 with U+FFFD for anything invalid.
    public static func percentDecoded(_ value: String) -> String {
        guard value.contains("%") else { return value }
        let bytes = Array(value.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
               let high = hex(bytes[i + 1]), let low = hex(bytes[i + 2]) {
                out.append(high << 4 | low)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

// MARK: - Per-message compression

/// A message's compressed payload, undone by the encoding its headers name.
///
/// `identity` needs nothing; `gzip` and `deflate` go through the system
/// zlib. Anything else (`snappy`, `zstd`, a name nobody registered) is
/// NAMED, never guessed at: guessing wrong shows a person a tree of garbage
/// as if it were the message.
public enum RPCMessageCompression {
    /// No message is inflated past this — a small compressed frame can claim
    /// gigabytes (a decompression bomb), and the extension's own budget per
    /// exchange is 16 MB.
    public static let maxDecodedBytes = 16 * 1024 * 1024

    public enum Outcome: Equatable, Sendable {
        case decoded(Data)
        /// An encoding ReqRes does not decode, by its name as sent.
        case unsupported(String)
        /// The frame says compressed but the headers name no encoding.
        case unnamed
        /// The bytes did not inflate (named encoding).
        case failed(String)
        /// It would inflate past `maxDecodedBytes`.
        case tooLarge(String)
    }

    /// `encoding` is the header's value as sent (`gzip`, `GZIP `, nil).
    public static func decompress(_ payload: Data, encoding: String?, maxBytes: Int = maxDecodedBytes) -> Outcome {
        guard let encoding = encoding?.trimmingCharacters(in: .whitespaces), !encoding.isEmpty else { return .unnamed }
        switch encoding.lowercased() {
        case "identity":
            return .decoded(payload)
        case "gzip", "x-gzip":
            return inflate(payload, windowBits: 15 + 16, name: encoding, maxBytes: maxBytes)
        case "deflate":
            // gRPC's "deflate" is zlib-wrapped (RFC 1950); some peers send
            // raw DEFLATE under the same name.
            let wrapped = inflate(payload, windowBits: 15, name: encoding, maxBytes: maxBytes)
            if case .failed = wrapped { return inflate(payload, windowBits: -15, name: encoding, maxBytes: maxBytes) }
            return wrapped
        default:
            return .unsupported(encoding)
        }
    }

    private static func inflate(_ input: Data, windowBits: Int32, name: String, maxBytes: Int) -> Outcome {
        guard !input.isEmpty else { return .failed(name) }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return .failed(name)
        }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var result: Outcome?
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else {
                result = .failed(name)
                return
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    guard output.count + produced <= maxBytes else {
                        result = .tooLarge(name)
                        return
                    }
                    output.append(contentsOf: chunk[0 ..< produced])
                }
                switch status {
                case Z_STREAM_END:
                    result = .decoded(output)
                    return
                case Z_OK:
                    continue
                case Z_BUF_ERROR:
                    // No progress possible: out of input before the end
                    // (a cut payload), or stuck — never loop on it.
                    if stream.avail_in == 0 || produced == 0 {
                        result = .failed(name)
                        return
                    }
                    continue
                default:
                    result = .failed(name)
                    return
                }
            }
        }
        return result ?? .failed(name)
    }
}
