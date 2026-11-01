//
//  TimeZoneOrigin.swift
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
//  Where the user is, without asking: the Mac's time zone names a country for
//  every zone the tz database assigns one. There is no public tz → country
//  API, so the table is generated from the tz database's zone.tab (one
//  country per zone) and backward (the old names ICU still hands out, such as
//  Asia/Calcutta and US/Pacific). Nil for UTC, Etc/*, and anything unlisted —
//  the map then simply draws no origin.
//

import Foundation

public enum TimeZoneOrigin {

    /// "Europe/London" → "GB". Nil when the zone names no single country.
    public static func country(for identifier: String) -> String? {
        table[identifier]
    }

    /// The country of `TimeZone.current`, if it has one.
    public static var currentCountry: String? {
        country(for: TimeZone.current.identifier)
    }

    /// The centroid of the zone's country.
    public static func coordinate(for identifier: String, in centroids: Centroids) -> GeoCoordinate? {
        country(for: identifier).flatMap { centroids[$0] }
    }

    /// Where to draw "you" on the map; nil when the time zone does not say.
    public static func current(in centroids: Centroids) -> GeoCoordinate? {
        coordinate(for: TimeZone.current.identifier, in: centroids)
    }

    static var rowCount: Int { table.count }

    /// Loaded once, on first use. An unreadable resource yields an empty table
    /// — no origin on the map — rather than a failure to launch.
    static let table: [String: String] = {
        guard let url = try? GeoKit.resourceURL("tz-countries", extension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var table: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t")
            if columns.count == 2 { table[String(columns[0])] = String(columns[1]) }
        }
        return table
    }()
}
