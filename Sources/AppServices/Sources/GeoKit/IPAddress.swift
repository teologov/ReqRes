//
//  IPAddress.swift
//  AppServices
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
//  Address parsing and the 128-bit integer the IPv6 table needs. The parser
//  is `inet_pton`, which is strict: brackets, a trailing `:port`, a hostname
//  or garbage all fail, and failure is a nil, never a crash.
//

import Foundation

enum IPAddress: Equatable {
    case v4(UInt32)
    case v6(UInt128Value)

    /// Accepts "1.2.3.4" and any RFC 4291 spelling of an IPv6 address
    /// (surrounding whitespace and an IPv6 zone suffix such as "%en0" are
    /// dropped). IPv4-mapped (`::ffff:a.b.c.d`) and NAT64 (`64:ff9b::a.b.c.d`)
    /// addresses name an IPv4 destination and come back as `.v4`.
    static func parse(_ text: String) -> IPAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An embedded NUL would truncate the C string and let "8.8.8.8\0junk" parse.
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64, !trimmed.utf8.contains(0) else { return nil }
        if trimmed.contains(":") {
            var candidate = Substring(trimmed)
            if let percent = candidate.firstIndex(of: "%") { candidate = candidate[..<percent] }
            return parseV6(String(candidate))
        }
        return parseV4(trimmed)
    }

    private static func parseV4(_ text: String) -> IPAddress? {
        var address = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return .v4(UInt32(bigEndian: address.s_addr))
    }

    private static func parseV6(_ text: String) -> IPAddress? {
        var address = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        let value = withUnsafeBytes(of: &address) { raw in
            UInt128Value(hi: UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
                         lo: UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
        }
        if value.hi == 0, value.lo >> 32 == 0xffff {                       // ::ffff:0:0/96
            return .v4(UInt32(truncatingIfNeeded: value.lo))
        }
        if value.hi == 0x0064_ff9b_0000_0000, value.lo >> 32 == 0 {       // 64:ff9b::/96
            return .v4(UInt32(truncatingIfNeeded: value.lo))
        }
        return .v6(value)
    }
}

/// Just enough of a 128-bit unsigned integer for IPv6 starts and deltas:
/// ordering, addition, shifts, or. The stdlib's `UInt128` needs macOS 15 and
/// this package's floor is 13.
struct UInt128Value: Comparable, Hashable {
    var hi: UInt64
    var lo: UInt64

    static let zero = UInt128Value(hi: 0, lo: 0)

    init(hi: UInt64, lo: UInt64) {
        self.hi = hi
        self.lo = lo
    }

    init(_ small: UInt64) {
        self.init(hi: 0, lo: small)
    }

    static func < (lhs: UInt128Value, rhs: UInt128Value) -> Bool {
        lhs.hi != rhs.hi ? lhs.hi < rhs.hi : lhs.lo < rhs.lo
    }

    static func | (lhs: UInt128Value, rhs: UInt128Value) -> UInt128Value {
        UInt128Value(hi: lhs.hi | rhs.hi, lo: lhs.lo | rhs.lo)
    }

    /// Wrapping addition — the table never produces a sum past 2^128 − 1, and a
    /// corrupt file must not trap.
    func adding(_ other: UInt128Value) -> UInt128Value {
        let (low, carry) = lo.addingReportingOverflow(other.lo)
        return UInt128Value(hi: hi &+ other.hi &+ (carry ? 1 : 0), lo: low)
    }

    func shiftedLeft(_ bits: Int) -> UInt128Value {
        if bits <= 0 { return self }
        if bits >= 128 { return .zero }
        if bits >= 64 { return UInt128Value(hi: lo << UInt64(bits - 64), lo: 0) }
        return UInt128Value(hi: (hi << UInt64(bits)) | (lo >> UInt64(64 - bits)), lo: lo << UInt64(bits))
    }

    func shiftedRight(_ bits: Int) -> UInt128Value {
        if bits <= 0 { return self }
        if bits >= 128 { return .zero }
        if bits >= 64 { return UInt128Value(hi: 0, lo: hi >> UInt64(bits - 64)) }
        return UInt128Value(hi: hi >> UInt64(bits), lo: (lo >> UInt64(bits)) | (hi << UInt64(64 - bits)))
    }
}
