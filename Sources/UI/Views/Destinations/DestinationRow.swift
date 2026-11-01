//
//  DestinationRow.swift
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
//  One row of the destinations list (destination-map UX spec §3.2), on
//  `SavedSessionRow`'s metrics: a 20pt glyph, a 12pt title, a 10pt meta line,
//  the request count as the sidebar rows' `.badge`. Cheap on purpose — no
//  GeometryReader, no formatter objects, no observation — the list can hold
//  every country there is and re-renders on each ≤ 1 Hz publish.
//

import MCPKit
import SwiftUI

struct DestinationRow: View {
    let entry: DestinationEntry
    /// The resolver's table failure, for the Unknown row's tooltip (spec §6).
    var tableFailure: String? = nil
    /// Spec §7 state 7: with attribution unavailable the meta line omits apps.
    var showsApps = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DestinationGlyph(destination: entry.destination, flagSize: 16, symbolSize: 14)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(CountryPresentation.title(for: entry.destination))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.metaLine(for: entry, showsApps: showsApps))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)
        }
        .padding(.vertical, 4)
        .badge(entry.requests)
        .help(Self.tooltip(for: entry, tableFailure: tableFailure))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Text

    /// `"38.2 MB · 14 hosts · Brave Browser, claude +1"` — every app the
    /// entry saw goes in, busiest first, so the `+N` counts the rest.
    static func metaLine(for entry: DestinationEntry, showsApps: Bool) -> String {
        let apps: [String?] = showsApps ? entry.topApps(entry.appCount).map(\.name) : []
        return DestinationCopy.metaLine(bytes: entry.bytes, hostCount: entry.hostCount, appNames: apps)
    }

    /// Countries: `"🇩🇪 Germany · 38 requests · 1.2 MB"` (flag omitted when
    /// there is none); the three classes: their §6 sentence.
    static func tooltip(for entry: DestinationEntry, tableFailure: String?) -> String {
        if let description = DestinationCopy.classDescription(entry.destination, tableFailure: tableFailure) {
            return description
        }
        let code = entry.destination.isoCode ?? ""
        let flag = CountryPresentation.flag(for: code)
        let name = CountryPresentation.name(for: code)
        let lead = flag.isEmpty ? name : "\(flag) \(name)"
        return "\(lead) · \(CountryPresentation.plural(entry.requests, "request")) · \(DestinationCopy.bytes(entry.bytes))"
    }

    /// The list's filter (spec §3.1): name, ISO code, token, every host and
    /// every app name — typing `stripe` shows the row whose hosts include
    /// `api.stripe.com`, which is the question "which country is this host in".
    static func matches(_ entry: DestinationEntry, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        var fields = [CountryPresentation.title(for: entry.destination), entry.destination.token]
        if let code = entry.destination.isoCode { fields.append(code) }
        fields.append(contentsOf: entry.hostsByCount.keys)
        fields.append(contentsOf: entry.appsByCount.keys.map { $0 == DestinationIndex.unknownAppKey ? TrafficDestination.unknownLabel : $0 })
        return fields.contains { $0.range(of: needle, options: .caseInsensitive) != nil }
    }
}

/// A destination's glyph: the regional-indicator flag for a country that has
/// one, else the class symbol — or the `flag` symbol for a country without a
/// flag glyph (XK, ZZ). Shared by the row, the header and the callout so the
/// three cannot disagree about what a destination looks like.
struct DestinationGlyph: View {
    let destination: TrafficDestination
    var flagSize: CGFloat = 16
    var symbolSize: CGFloat = 14

    var body: some View {
        if let symbol = CountryPresentation.symbolName(for: destination) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(.secondary)
        } else {
            let flag = CountryPresentation.flag(for: destination.isoCode ?? "")
            if flag.isEmpty {
                Image(systemName: "flag")
                    .font(.system(size: symbolSize))
                    .foregroundStyle(.secondary)
            } else {
                Text(flag)
                    .font(.system(size: flagSize))
            }
        }
    }
}
