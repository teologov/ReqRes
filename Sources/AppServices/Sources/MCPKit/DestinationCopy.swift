//
//  DestinationCopy.swift
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
//  Every honesty string the destination map shows, once (destination-map UX
//  spec §6). Tooltips, Help, Settings, the diagnosis and the agent's
//  `list_destinations` note all quote from here, so what the map claims about
//  itself cannot drift between surfaces — and a sentence about what a country
//  "means" that is wrong is wrong in one place.
//

import Foundation

public enum DestinationCopy {
    // MARK: - The three classes

    /// This Mac (`desktopcomputer`).
    public static let thisMac =
        "Requests to this Mac itself — 127.0.0.1 or ::1: a local dev server, a simulator, another proxy."

    /// Local Network (`wifi.router`).
    public static let localNetwork =
        "Requests to a private address on your network — 10.x, 172.16–31.x, 192.168.x, link-local or another private range: a router, a NAS, a phone, a colleague's machine."

    /// Unknown (`questionmark.circle.dashed`).
    public static let unknown =
        "ReqRes could not place these requests. It knows the address only when the extension reports it, it places an address only if the offline country table lists it, and a request a rule answered contacted no server at all. No address is ever looked up online; only the map tiles come from Apple."

    /// The Unknown explanation, with the table failure appended when the
    /// resolver's `tableStatus` is a failure — the one case where "not in the
    /// table" is really "there is no table".
    public static func unknown(tableFailure reason: String?) -> String {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return unknown }
        return unknown + " The country table could not be read: \(reason)."
    }

    /// The tooltip for a class row, pill or header (spec §3.2, §6).
    public static func classDescription(_ destination: TrafficDestination, tableFailure: String? = nil) -> String? {
        switch destination {
        case .country: return nil
        case .thisMac: return thisMac
        case .localNetwork: return localNetwork
        case .unknown: return unknown(tableFailure: tableFailure)
        }
    }

    // MARK: - Origin

    /// The You marker's tooltip and the Settings row.
    public static func origin(countryName: String, timeZone: String) -> String {
        "You, approximately: the centre of \(countryName), because your Mac's time zone is \(timeZone). ReqRes never asks Location Services and never looks this up online."
    }

    /// The strip's sentence when there is no origin (spec §4.3, §7 state 5):
    /// the time zone is named so the user can see WHY — `UTC`, `Etc/GMT+2`
    /// and a zone the table lacks all read the same otherwise.
    public static func originUnknown(timeZone: String) -> String {
        "Your location is not shown: the time zone \(timeZone) names no country."
    }

    // MARK: - The map, and what leaves the Mac (Help, Settings — identical)

    /// The one privacy sentence that changed when the map became Apple Maps:
    /// the lookup is still offline, the tiles are not. Help and Settings ▸
    /// Capture print this verbatim; a claim that nothing leaves the Mac is
    /// no longer true and must not survive anywhere. The framing clause is
    /// there because it is true: the initial camera and Fit are the bounding
    /// box of every dot plus the origin, so the viewport Apple receives is
    /// derived from the destinations (a trans-Pacific fit says as much).
    public static let mapPrivacy =
        "The country lookup runs on this Mac from an offline table; the map itself is Apple Maps, so Apple receives the map area you view — which ReqRes frames around your destinations — never the addresses themselves."

    /// What happens to the tile fetches while capture is on: an excluded
    /// host is relayed byte-for-byte and the core records NOTHING for it
    /// (`relayForExcludedHost`), so they are not in the traffic list — the
    /// same pane says so about every excluded host. Why the exclusion exists
    /// is stated as the observation (the map keeps working), not the
    /// mechanism: Apple pinning its map servers' certificates is the likely
    /// reason but was not measured — geod's hosts were observed WITHOUT
    /// capture running (2026-09-25).
    public static let mapTilesInTraffic =
        "While capture is on, the map's tile requests (made by geod, Apple's map service) pass through ReqRes untouched and are not listed — *.ls.apple.com is excluded from interception by default so the map keeps working while capture is on."

    /// The strip's one line when there is no network (spec §7): the tiles
    /// are the only thing this window fetches, so it is the only thing that
    /// stops working.
    public static let mapTilesOffline =
        "Map tiles need a network connection; destinations are still listed."

    // MARK: - What a country means (Help, Settings, the list_destinations note — identical)

    public static let whatACountryMeans =
        "The country is where the address your Mac connected to is registered, at country level, from a table inside the app — a CDN answers from a nearby edge, so a site's country is where its server answered from, not where the company is."

    /// The credit the agent's report ends with (spec §8.3). The app's own
    /// windows show GeoKit's full attribution line; this is the short form
    /// for text an agent pays for by the token.
    public static let agentAttribution = "IP Geolocation by DB-IP."

    /// The Unknown row's trailing note in the agent's report.
    public static let agentUnknownNote = "address missing or not in the offline table"

    // MARK: - Lines assembled from numbers

    /// A row's second line (spec §3.2): `"38.2 MB · 14 hosts · Brave Browser,
    /// claude +1"` — up to TWO app names busiest first, then ` +N`; the nil
    /// bucket prints `Unknown` and comes last (`topApps` already orders it
    /// so). No apps at all (attribution unavailable, spec §7 state 7) omits
    /// the third part.
    public static func metaLine(bytes: Int64, hostCount: Int, appNames: [String?], locale: Locale = .current) -> String {
        var parts = [Self.bytes(bytes), CountryPresentation.plural(hostCount, "host", locale: locale)]
        if !appNames.isEmpty {
            let shown = appNames.prefix(2).map { $0 ?? TrafficDestination.unknownLabel }
            var apps = shown.joined(separator: ", ")
            if appNames.count > 2 { apps += " +\(appNames.count - 2)" }
            parts.append(apps)
        }
        return parts.joined(separator: " · ")
    }

    /// The header's meta text (spec §3.4).
    /// - no selection: `"\(destinations) destinations · \(requests) requests · \(bytes)"`,
    ///   ending `"· not placeable"` when `allUnknown` (spec §7 state 3: the one
    ///   "destination" counted is the Unknown class)
    /// - a country or a class: `"\(requests) requests · \(bytes) · \(hosts) hosts · \(apps) apps"`
    /// - Unknown: `"\(requests) requests · \(bytes) · \(hosts) hosts · not placeable"`
    /// `appCount` nil omits the apps part (attribution unavailable).
    public static func headerMeta(
        selection: TrafficDestination?,
        destinationCount: Int,
        requests: Int,
        bytes: Int64,
        hostCount: Int,
        appCount: Int?,
        allUnknown: Bool = false,
        locale: Locale = .current
    ) -> String {
        guard let selection else {
            var parts = [
                CountryPresentation.plural(destinationCount, "destination", locale: locale),
                CountryPresentation.plural(requests, "request", locale: locale),
                Self.bytes(bytes),
            ]
            if allUnknown && requests > 0 { parts.append("not placeable") }
            return parts.joined(separator: " · ")
        }
        var parts = [
            CountryPresentation.plural(requests, "request", locale: locale),
            Self.bytes(bytes),
            CountryPresentation.plural(hostCount, "host", locale: locale),
        ]
        if selection == .unknown {
            parts.append("not placeable")
        } else if let appCount {
            parts.append(CountryPresentation.plural(appCount, "app", locale: locale))
        }
        return parts.joined(separator: " · ")
    }

    /// The list footer (spec §3.1). `shown` nil means no query is active.
    /// `retentionCap` is `SessionState.maxRetainedSessions` when the buffer
    /// is full — the footer then says "the 5,000 most recent requests" so
    /// "All captured traffic" stays true.
    public static func footerSummary(
        destinationCount: Int,
        requests: Int,
        shown: Int?,
        retentionCap: Int?,
        locale: Locale = .current
    ) -> String {
        if let shown {
            return "\(CountryPresentation.groupedDigits(shown, locale: locale)) of \(CountryPresentation.plural(destinationCount, "destination", locale: locale)) shown"
        }
        let requestsPart = retentionCap.map { "the \(CountryPresentation.groupedDigits($0, locale: locale)) most recent requests" }
            ?? CountryPresentation.plural(requests, "request", locale: locale)
        return "All captured traffic · \(CountryPresentation.plural(destinationCount, "destination", locale: locale)) · \(requestsPart)"
    }

    /// `512 B`, `40 KB`, `1.1 MB`, `38.2 MB`, `2.0 GB` — decimal units, one
    /// decimal from a megabyte up, locale-independent so the agent's columns
    /// and the tests read the same on every Mac.
    public static func bytes(_ count: Int64) -> String {
        let value = Double(max(0, count))
        switch value {
        case ..<1_000:
            return "\(Int(value)) B"
        case ..<1_000_000:
            return "\(Int((value / 1_000).rounded())) KB"
        case ..<1_000_000_000:
            return String(format: "%.1f MB", value / 1_000_000)
        default:
            return String(format: "%.1f GB", value / 1_000_000_000)
        }
    }
}
