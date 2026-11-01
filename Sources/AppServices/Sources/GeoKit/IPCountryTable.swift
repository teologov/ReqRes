//
//  IPCountryTable.swift
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
//  IP → country from the DB-IP Lite table, read straight out of a memory-mapped
//  file. The file is `dbip-country.bin`, written by
//  Scripts/geo/build-geo-resources.py, whose docstring is the format's
//  specification; the reader below mirrors it field for field.
//
//  Shape, in one paragraph: the address space is covered by contiguous rows
//  (every gap is an explicit ZZ row), so only each row's START is stored, as a
//  varint delta from the previous one with a 2-bit tag choosing a shift. Every
//  64 rows an index entry records the block's first start and its byte offset,
//  so a lookup is a binary search over the index and a walk of at most 63
//  deltas. Loading is a header parse — the bytes stay in the mapped file.
//

import Foundation

public struct IPCountryTable: Sendable {

    /// The DB-IP snapshot month, "YYYY-MM".
    public let dataMonth: String
    /// Every code in the table, sorted; includes "ZZ" for unassigned space.
    public let countries: [String]
    public let ipv4RowCount: Int
    public let ipv6RowCount: Int

    private let data: Data
    private let layout: Layout
    private let unknownIndex: Int

    /// The bundled table, loaded once. Nil only if the resource is missing or
    /// corrupt — `bundled()` says which.
    public static let shared: IPCountryTable? = try? bundled()

    public static func bundled() throws -> IPCountryTable {
        try IPCountryTable(contentsOf: GeoKit.resourceURL("dbip-country", extension: "bin"))
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    // MARK: - Resolution

    /// "8.8.8.8" → `.country("US")`. Anything that is not a plain IPv4 or IPv6
    /// address — a hostname, "[::1]:443", "1.2.3.4:80", garbage — is `.unknown`.
    public func country(for address: String) -> GeoResolution {
        guard let parsed = IPAddress.parse(address) else { return .unknown }
        return resolve(parsed)
    }

    func resolve(_ address: IPAddress) -> GeoResolution {
        switch address {
        case .v4(let value):
            if let special = Self.classify(v4: value) { return special }
            return resolution(forCountryIndex: lookup(v4: value))
        case .v6(let value):
            if let special = Self.classify(v6: value) { return special }
            return resolution(forCountryIndex: lookup(v6: value))
        }
    }

    /// The table's own answer with no special-casing — "ZZ" included. For the
    /// tests, which compare it with the CSV the table was built from.
    func rawCountry(_ address: IPAddress) -> String? {
        let index: Int
        switch address {
        case .v4(let value): index = lookup(v4: value)
        case .v6(let value): index = lookup(v6: value)
        }
        return countries.indices.contains(index) ? countries[index] : nil
    }

    private func resolution(forCountryIndex index: Int) -> GeoResolution {
        guard countries.indices.contains(index), index != unknownIndex else { return .unknown }
        return .country(countries[index])
    }

    // MARK: - Address classes decided without the table

    static func classify(v4 ip: UInt32) -> GeoResolution? {
        let a = ip >> 24
        let b = (ip >> 16) & 0xff
        let c = (ip >> 8) & 0xff
        switch a {
        case 127: return .thisMac                                           // 127.0.0.0/8
        case 10: return .localNetwork                                       // 10.0.0.0/8
        case 172 where (16...31).contains(b): return .localNetwork          // 172.16.0.0/12
        case 192 where b == 168: return .localNetwork                       // 192.168.0.0/16
        case 169 where b == 254: return .localNetwork                       // 169.254.0.0/16 link-local
        case 100 where (64...127).contains(b): return .localNetwork         // 100.64.0.0/10 CGNAT
        case 0: return .unknown                                             // "this" network
        case 224...255: return .unknown                                     // multicast, reserved, broadcast
        case 192 where b == 0 && c == 0: return .unknown                    // 192.0.0.0/24 IETF
        case 192 where b == 0 && c == 2: return .unknown                    // 192.0.2.0/24 TEST-NET-1
        case 198 where b == 18 || b == 19: return .unknown                  // 198.18.0.0/15 benchmarking
        case 198 where b == 51 && c == 100: return .unknown                 // 198.51.100.0/24 TEST-NET-2
        case 203 where b == 0 && c == 113: return .unknown                  // 203.0.113.0/24 TEST-NET-3
        default: return nil
        }
    }

    static func classify(v6 ip: UInt128Value) -> GeoResolution? {
        if ip.hi == 0 {
            if ip.lo == 1 { return .thisMac }                                // ::1
            if ip.lo == 0 { return .unknown }                                // ::
            return nil
        }
        let top = ip.hi >> 56
        if top == 0xff { return .unknown }                                   // ff00::/8 multicast
        if ip.hi >> 54 == 0x3fa { return .localNetwork }                     // fe80::/10 link-local
        if top & 0xfe == 0xfc { return .localNetwork }                       // fc00::/7 unique local
        if ip.hi >> 32 == 0x2001_0db8 { return .unknown }                    // 2001:db8::/32 documentation
        // IANA has only ever allocated global unicast from 2000::/3. DB-IP's
        // monthly CSV carries junk tail rows (2c10::–fbff::…, fe00::–fe7f::…,
        // fec0::–ffff::… → CH in 2026-09) that would otherwise resolve
        // reserved and deprecated site-local space to a country. The IPv4 side
        // guards the same way; this belongs in code because the tail rows
        // change month to month.
        if (ip.hi >> 61) != 1 { return .unknown }
        if ip.hi >> 48 == 0x3ffe { return .unknown }                        // 3ffe::/16 6bone, returned to IANA in 2006
        return nil
    }

    // MARK: - Lookups

    private func lookup(v4 ip: UInt32) -> Int {
        data.withUnsafeBytes { raw -> Int in
            let layout = self.layout
            let indexOffset = layout.v4IndexOffset
            var low = 0
            var high = layout.v4Blocks
            while low < high {
                let mid = (low + high) >> 1
                let start = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: indexOffset + mid * Layout.v4IndexEntry, as: UInt32.self))
                if start <= ip { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { return -1 }
            let block = low - 1
            let entry = indexOffset + block * Layout.v4IndexEntry
            var start = UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: entry, as: UInt32.self)))
            var position = layout.v4StreamOffset + Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: entry + 4, as: UInt32.self)))
            let end = layout.v4StreamEnd
            guard position < end else { return -1 }
            var country = Int(raw.load(fromByteOffset: position, as: UInt8.self))
            position += 1
            let rows = min(layout.blockSize, ipv4RowCount - block * layout.blockSize)
            let target = UInt64(ip)
            for _ in 1..<max(rows, 1) {
                var value: UInt64 = 0
                var shift = 0
                while true {
                    guard position < end else { return -1 }
                    let byte = raw.load(fromByteOffset: position, as: UInt8.self)
                    position += 1
                    value |= UInt64(byte & 0x7f) << UInt64(shift)
                    if byte & 0x80 == 0 { break }
                    shift += 7
                    if shift > 63 { return -1 }
                }
                start &+= (value >> 2) << UInt64(layout.v4Shifts[Int(value & 3)])
                if start > target { break }
                guard position < end else { return -1 }
                country = Int(raw.load(fromByteOffset: position, as: UInt8.self))
                position += 1
            }
            return country
        }
    }

    private func lookup(v6 ip: UInt128Value) -> Int {
        data.withUnsafeBytes { raw -> Int in
            let layout = self.layout
            let indexOffset = layout.v6IndexOffset
            func blockStart(_ block: Int) -> UInt128Value {
                let entry = indexOffset + block * Layout.v6IndexEntry
                return UInt128Value(hi: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: entry + 8, as: UInt64.self)),
                                    lo: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: entry, as: UInt64.self)))
            }
            var low = 0
            var high = layout.v6Blocks
            while low < high {
                let mid = (low + high) >> 1
                if blockStart(mid) <= ip { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { return -1 }
            let block = low - 1
            let entry = indexOffset + block * Layout.v6IndexEntry
            var start = blockStart(block)
            var position = layout.v6StreamOffset + Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: entry + 16, as: UInt32.self)))
            let end = layout.length
            guard position < end else { return -1 }
            var country = Int(raw.load(fromByteOffset: position, as: UInt8.self))
            position += 1
            let rows = min(layout.blockSize, ipv6RowCount - block * layout.blockSize)
            for _ in 1..<max(rows, 1) {
                var value = UInt128Value.zero
                var shift = 0
                while true {
                    guard position < end else { return -1 }
                    let byte = raw.load(fromByteOffset: position, as: UInt8.self)
                    position += 1
                    value = value | UInt128Value(UInt64(byte & 0x7f)).shiftedLeft(shift)
                    if byte & 0x80 == 0 { break }
                    shift += 7
                    if shift > 133 { return -1 }
                }
                start = start.adding(value.shiftedRight(2).shiftedLeft(layout.v6Shifts[Int(value.lo & 3)]))
                if start > ip { break }
                guard position < end else { return -1 }
                country = Int(raw.load(fromByteOffset: position, as: UInt8.self))
                position += 1
            }
            return country
        }
    }

    // MARK: - Header

    struct Layout: Sendable {
        static let magic: UInt32 = 0x494f_4547        // "GEOI" read little-endian
        static let version = 1
        static let headerLength = 64
        static let v4IndexEntry = 8                   // start u32, stream offset u32
        static let v6IndexEntry = 20                  // start u128, stream offset u32

        var blockSize: Int
        var v4Shifts: [Int]
        var v6Shifts: [Int]
        var v4IndexOffset: Int
        var v4StreamOffset: Int
        var v4StreamEnd: Int
        var v6IndexOffset: Int
        var v6StreamOffset: Int
        var length: Int
        var v4Blocks: Int
        var v6Blocks: Int
    }

    public init(data: Data) throws {
        guard data.count >= Layout.headerLength else { throw GeoKitError.malformed("header truncated") }
        let header: (magic: UInt32, version: Int, headerLength: Int, month: String, countryCount: Int,
                     blockSize: Int, v4Shifts: [Int], v6Shifts: [Int], v4Rows: Int, v6Rows: Int,
                     offsets: [Int], reserved: Int) = data.withUnsafeBytes { raw in
            func u16(_ offset: Int) -> Int { Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) }
            func u32(_ offset: Int) -> Int { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            let monthBytes = (8..<16).map { raw.load(fromByteOffset: $0, as: UInt8.self) }.prefix { $0 != 0 }
            return (
                magic: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
                version: u16(4), headerLength: u16(6),
                month: String(decoding: monthBytes, as: UTF8.self),
                countryCount: u16(16), blockSize: u16(18),
                v4Shifts: (20..<24).map { Int(raw.load(fromByteOffset: $0, as: UInt8.self)) },
                v6Shifts: (24..<28).map { Int(raw.load(fromByteOffset: $0, as: UInt8.self)) },
                v4Rows: u32(28), v6Rows: u32(32),
                offsets: [u32(36), u32(40), u32(44), u32(48), u32(52), u32(56)],
                reserved: u32(60)
            )
        }
        guard header.magic == Layout.magic else { throw GeoKitError.malformed("not a GeoKit IP table") }
        guard header.version == Layout.version, header.headerLength == Layout.headerLength else {
            throw GeoKitError.malformed("unsupported table version \(header.version)")
        }
        guard header.offsets[5] == data.count, header.reserved == 0 else { throw GeoKitError.malformed("length mismatch") }
        guard (1...255).contains(header.countryCount), header.blockSize >= 1 else { throw GeoKitError.malformed("bad counts") }
        guard header.v4Shifts.allSatisfy({ $0 <= 31 }), header.v6Shifts.allSatisfy({ $0 <= 127 }) else {
            throw GeoKitError.malformed("bad shifts")
        }
        guard header.month.count == 7, header.month.allSatisfy({ $0.isNumber || $0 == "-" }) else {
            throw GeoKitError.malformed("bad data month")
        }
        let blockSize = header.blockSize
        let v4Blocks = (header.v4Rows + blockSize - 1) / blockSize
        let v6Blocks = (header.v6Rows + blockSize - 1) / blockSize
        let countriesOffset = header.offsets[0]
        let layout = Layout(blockSize: blockSize, v4Shifts: header.v4Shifts, v6Shifts: header.v6Shifts,
                            v4IndexOffset: header.offsets[1], v4StreamOffset: header.offsets[2],
                            v4StreamEnd: header.offsets[3], v6IndexOffset: header.offsets[3],
                            v6StreamOffset: header.offsets[4], length: header.offsets[5],
                            v4Blocks: v4Blocks, v6Blocks: v6Blocks)
        guard countriesOffset == Layout.headerLength,
              layout.v4IndexOffset == countriesOffset + header.countryCount * 2,
              layout.v4StreamOffset == layout.v4IndexOffset + v4Blocks * Layout.v4IndexEntry,
              layout.v6IndexOffset >= layout.v4StreamOffset,
              layout.v6StreamOffset == layout.v6IndexOffset + v6Blocks * Layout.v6IndexEntry,
              layout.length >= layout.v6StreamOffset,
              header.v4Rows > 0, header.v6Rows > 0
        else { throw GeoKitError.malformed("section offsets do not line up") }

        let countries: [String] = (0..<header.countryCount).map { index in
            let start = data.startIndex + countriesOffset + index * 2
            return String(decoding: data[start..<start + 2], as: UTF8.self)
        }
        guard countries.allSatisfy({ $0.count == 2 && $0.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) } }) else {
            throw GeoKitError.malformed("country table is not ASCII codes")
        }

        self.data = data
        self.layout = layout
        self.dataMonth = header.month
        self.countries = countries
        self.ipv4RowCount = header.v4Rows
        self.ipv6RowCount = header.v6Rows
        self.unknownIndex = countries.firstIndex(of: "ZZ") ?? -1
    }
}
