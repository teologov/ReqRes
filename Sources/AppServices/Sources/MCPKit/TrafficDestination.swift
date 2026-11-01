//
//  TrafficDestination.swift
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
//  Where a captured request went (destination-map UX spec §1.2): a country,
//  or one of three classes that are not places. MCPKit rather than Utils
//  because the agent needs the same vocabulary as the search field, MCPKit
//  has no dependencies, and Utils cannot import it without dragging Sentry
//  and Sparkle into the sandboxed helper.
//
//  The classifier takes the address the core recorded and a lookup closure.
//  The IP → country table lives in GeoKit, which this module never imports:
//  the app injects the table, so the helper binary carries none of it and a
//  test can hand in any table it likes.
//

import Foundation

/// A destination: a country (ISO 3166-1 alpha-2, upper-cased) or one of the
/// three classes — This Mac, Local Network, Unknown — that are listed beside
/// the map and never plotted on it.
public enum TrafficDestination: Hashable, Sendable, Codable {
    case country(String)
    case thisMac
    case localNetwork
    case unknown

    /// The three class tokens. Lower-case words, so they can never collide
    /// with a two-letter code (spec §1: `US | local | mac | unknown`).
    public static let localToken = "local"
    public static let macToken = "mac"
    public static let unknownToken = "unknown"
    public static let specialTokens = [localToken, macToken, unknownToken]

    /// What the three classes are called, Title Case, everywhere (spec §1).
    /// Never "localhost", "LAN" or "private range" in UI text.
    public static let thisMacLabel = "This Mac"
    public static let localNetworkLabel = "Local Network"
    public static let unknownLabel = "Unknown"

    /// The one spelling the search grammar and MCP share: `"US"` | `"mac"` |
    /// `"local"` | `"unknown"`.
    public var token: String {
        switch self {
        case .country(let code): return code.uppercased()
        case .thisMac: return Self.macToken
        case .localNetwork: return Self.localToken
        case .unknown: return Self.unknownToken
        }
    }

    /// Two ASCII letters (any case) → `.country(upper)`; `local` / `mac` /
    /// `unknown` case-insensitively → the class; anything else nil. Country
    /// NAMES are not accepted here — the search field resolves them before
    /// it parses (spec §5.3), and the agent is told to send codes.
    public static func parseToken(_ text: String) -> TrafficDestination? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let code = Self.isoCode(from: trimmed) {
            return .country(code)
        }
        switch trimmed.lowercased() {
        case localToken: return .localNetwork
        case macToken: return .thisMac
        case unknownToken: return .unknown
        default: return nil
        }
    }

    /// `"us"` → `"US"`; nil unless exactly two ASCII letters.
    static func isoCode(from text: String) -> String? {
        guard text.count == 2, text.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return text.uppercased()
    }

    /// Only a country has a place on the map.
    public var isPlottable: Bool {
        if case .country = self { return true }
        return false
    }

    public var isoCode: String? {
        if case .country(let code) = self { return code }
        return nil
    }
}

/// Turns the address the core recorded into a destination.
///
/// The core's `SessionCodable.remoteAddress` is a BARE IP literal (IPv4 or
/// IPv6, no port; nil when the upstream connect never happened). Anything
/// that is not a bare literal — a hostname, a stray `ip:port`, a bracketed
/// `[v6]:port`, an interface scope — parses as nothing and reads Unknown,
/// never crashes, never guesses.
public enum DestinationClassifier {
    /// Classifies locally first, then asks `lookup` for a public address.
    ///
    /// 127/8, `::1`, `::ffff:127.x` → This Mac. 10/8, 172.16/12, 192.168/16,
    /// 169.254/16, 100.64/10, `fe80::/10`, `fc00::/7` → Local Network. 0/8,
    /// 224/4, 255.255.255.255, `::`, `ff00::/8`, unparseable, nil, "" →
    /// Unknown. Otherwise `lookup(canonicalAddress)` → `.country(code)`, or
    /// Unknown when the table has nothing (nil) or says "ZZ".
    public static func classify(remoteAddress: String?, lookup: (String) -> String?) -> TrafficDestination {
        guard let raw = remoteAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unknown
        }
        guard let address = IPLiteral(raw) else { return .unknown }
        switch address.localClass {
        case .thisMac: return .thisMac
        case .localNetwork: return .localNetwork
        case .unroutable: return .unknown
        case .none: break
        }
        guard let code = lookup(address.canonical), let iso = TrafficDestination.isoCode(from: code.trimmingCharacters(in: .whitespaces)),
              iso != "ZZ" else {
            return .unknown
        }
        return .country(iso)
    }

    /// The parts of the address the classifier needs, from `inet_pton` so
    /// the validation is the system's, not a regex.
    struct IPLiteral {
        enum LocalClass { case thisMac, localNetwork, unroutable }

        /// The four IPv4 octets — the real ones, or the ones embedded in a
        /// `::ffff:a.b.c.d` IPv6 address, which is an IPv4 connection seen
        /// through a dual-stack socket.
        let v4: (UInt8, UInt8, UInt8, UInt8)?
        /// The sixteen IPv6 bytes when the literal was IPv6 and not v4-mapped.
        let v6: [UInt8]?
        /// What the lookup is asked with: `inet_ntop`'s spelling, so
        /// `2001:DB8::1` and `2001:db8:0:0:0:0:0:1` share one cache entry.
        let canonical: String

        init?(_ text: String) {
            // macOS's inet_pton accepts a `%scope` suffix on an IPv6 literal
            // (`fe80::1%en0`); a scoped literal is not the bare literal the
            // core emits, so it is refused here rather than classified —
            // the same rule as a stray `:port`.
            guard !text.contains("%") else { return nil }
            var addr4 = in_addr()
            if text.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 {
                let bytes = withUnsafeBytes(of: addr4.s_addr) { Array($0) }
                v4 = (bytes[0], bytes[1], bytes[2], bytes[3])
                v6 = nil
                canonical = "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
                return
            }
            var addr6 = in6_addr()
            guard text.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 else { return nil }
            let bytes = withUnsafeBytes(of: addr6) { Array($0) }
            guard bytes.count == 16 else { return nil }
            let isV4Mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            if isV4Mapped {
                v4 = (bytes[12], bytes[13], bytes[14], bytes[15])
                v6 = nil
                canonical = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
                return
            }
            v4 = nil
            v6 = bytes
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let spelled = inet_ntop(AF_INET6, &addr6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil
            canonical = spelled ? String(cString: buffer) : text.lowercased()
        }

        var localClass: LocalClass? {
            if let v4 {
                let (a, b, c, d) = v4
                if a == 127 { return .thisMac }
                if a == 10 { return .localNetwork }
                if a == 172, (16...31).contains(b) { return .localNetwork }
                if a == 192, b == 168 { return .localNetwork }
                if a == 169, b == 254 { return .localNetwork }
                if a == 100, (64...127).contains(b) { return .localNetwork }
                if a == 0 { return .unroutable }
                if (224...239).contains(a) { return .unroutable }
                if a == 255, b == 255, c == 255, d == 255 { return .unroutable }
                return nil
            }
            guard let bytes = v6 else { return nil }
            let allZero = bytes.allSatisfy { $0 == 0 }
            if allZero { return .unroutable }                                   // ::
            if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return .thisMac }   // ::1
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return .localNetwork }       // fe80::/10
            if bytes[0] & 0xfe == 0xfc { return .localNetwork }                          // fc00::/7
            if bytes[0] == 0xff { return .unroutable }                                   // ff00::/8
            return nil
        }
    }
}
