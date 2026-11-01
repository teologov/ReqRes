//
//  RPCCandidate.swift
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
//  Which rows are worth asking about RPC at all, and a per-row cache that
//  remembers the answer — the "no" included (release review, 2026-09-29).
//  The table asks every visible row per render, the `grpc:` chip every row
//  per flush, and the agent list every row per call: at 5,000 ordinary rows
//  four case-insensitive Foundation searches over each row's header JSON,
//  repeated because a "no" was never cached, held the main thread 0.6–2 s
//  per call.
//

import Foundation

public enum RPCCandidate {
    /// The media types and header name that mark an RPC, lowercase ASCII.
    static let needles: [[UInt8]] = [
        "application/grpc", "application/connect", "application/proto", "connect-protocol-version",
    ].map { Array($0.utf8) }

    /// True when a row could be gRPC, gRPC-Web or Connect: a content type
    /// or the recorded request headers name one of `needles`. One pass over
    /// the header bytes, ASCII-folded, no allocation.
    public static func mightBeRPC(requestType: String, responseType: String, requestHeads: String) -> Bool {
        contains(requestType) || contains(responseType) || contains(requestHeads)
    }

    static func contains(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            let count = bytes.count
            var i = 0
            while i < count {
                let first = lower(bytes[i])
                if first == UInt8(ascii: "a") || first == UInt8(ascii: "c") {
                    for needle in needles where needle[0] == first && i + needle.count <= count {
                        var j = 1
                        while j < needle.count, lower(bytes[i + j]) == needle[j] { j += 1 }
                        if j == needle.count { return true }
                    }
                }
                i += 1
            }
            return false
        }
    }

    @inline(__always)
    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
    }
}

/// A value per row id, valid while the row's revision is unchanged — nil
/// answers included, so a row that is not an RPC is examined once, not on
/// every call. Thread-safe; starts over past `capacity` entries.
public final class RevisionedCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: (revision: Int, value: Value?)] = [:]
    private let capacity: Int

    public init(capacity: Int = 20_000) {
        self.capacity = capacity
    }

    /// The cached value for `id` at `revision`, or `compute()`'s, stored.
    /// `compute` runs outside the lock.
    public func value(id: UUID, revision: Int, compute: () -> Value?) -> Value? {
        lock.lock()
        if let entry = entries[id], entry.revision == revision {
            lock.unlock()
            return entry.value
        }
        lock.unlock()
        let value = compute()
        lock.lock()
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[id] = (revision, value)
        lock.unlock()
        return value
    }
}
