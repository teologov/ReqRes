//
//  DestinationResolver.swift
//  ReqRes
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
//  Where a session went, answered on this Mac (destination-map UX spec §1.6).
//  The FIRST of the two shell files that import GeoKit (`WorldMapGeometry` is
//  the other), so GeoKit's spelling cannot ripple: everything else asks this
//  type, in MCPKit's vocabulary.
//
//  Callable synchronously on main from the first flush. GeoKit's table is a
//  memory-mapped binary with an index (its PROVENANCE: a binary search plus at
//  most 63 varint decodes), so the first lookup is a page-in, not a parse —
//  and every lookup after the first for an address is a dictionary hit here.
//  No networking is imported; nothing about a destination leaves the Mac.
//

import Foundation
import GeoKit
import MCPKit
import XReqResCore

@MainActor
final class DestinationResolver {
    static let shared = DestinationResolver()

    /// The data month (`"2026-09"`) when the bundled table loaded, else why it
    /// did not. A failure makes every lookup Unknown, and the reason reaches
    /// the Unknown pill's tooltip, the Settings row and the diagnosis.
    let tableStatus: Result<String, Error>


    /// GeoKit's required credit line (DB-IP's CC BY 4.0 asks for it wherever
    /// the data is used) — for the legal corner and the Licenses page.
    var attribution: String { GeoKit.attribution }

    private let table: IPCountryTable?

    /// Keyed by the address STRING as the core spelled it. Distinct addresses
    /// are far fewer than sessions (a CDN edge answers thousands), and a
    /// bounded dictionary is cheaper than any smarter cache would be.
    private var cache: [String: TrafficDestination] = [:]
    private static let cacheLimit = 20_000

    private init() {
        do {
            let loaded = try IPCountryTable.bundled()
            table = loaded
            tableStatus = .success(loaded.dataMonth)
        } catch {
            table = nil
            tableStatus = .failure(error)
        }
    }

    /// The reason the table could not be read, for `DestinationCopy.unknown(tableFailure:)`.
    var tableFailureReason: String? {
        if case .failure(let error) = tableStatus { return Self.describe(error) }
        return nil
    }

    /// The table's data month when it loaded.
    var dataMonth: String? {
        if case .success(let month) = tableStatus { return month }
        return nil
    }

    var tableLoaded: Bool { table != nil }

    // MARK: - Resolution

    func destination(for session: SessionCodable) -> TrafficDestination {
        destination(forAddress: session.remoteAddressText)
    }

    /// Classifies locally first (loopback, private, unroutable) and asks the
    /// table only for a public address — `DestinationClassifier` owns those
    /// rules and their tests; this only supplies the lookup.
    func destination(forAddress address: String?) -> TrafficDestination {
        guard let address else { return .unknown }
        if let cached = cache[address] { return cached }
        let resolved = DestinationClassifier.classify(remoteAddress: address) { [table] ip in
            table?.country(for: ip).isoCode
        }
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[address] = resolved
        return resolved
    }

    // MARK: - Origin

    /// Where the user approximately is: the country the time zone belongs to,
    /// through GeoKit's tz → country table. Nil for UTC, `Etc/*` and any zone
    /// the table lacks. Never Location Services, never a network call, and
    /// NEVER handed to an agent (spec §0, §11) — the store draws it and nothing
    /// else reads it.
    func origin(for timeZone: TimeZone) -> OriginEstimate? {
        OriginEstimator.estimate(timeZone: timeZone) { TimeZoneOrigin.country(for: $0) }
    }

    private static func describe(_ error: Error) -> String {
        if let geo = error as? GeoKitError {
            switch geo {
            case .resourceMissing(let name): return "\(name) is missing from the app bundle"
            case .malformed(let detail): return detail
            }
        }
        return error.localizedDescription
    }
}
