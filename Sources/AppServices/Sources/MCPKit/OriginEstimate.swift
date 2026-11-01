//
//  OriginEstimate.swift
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
//  Where the user approximately is (destination-map UX spec §1.5): the
//  country the Mac's time zone belongs to, through a tz → country table the
//  app injects (GeoKit's; this module never imports it). Never Location
//  Services, never a network call — and NEVER reported to an agent (§0, §11):
//  it is drawn in the app's own window and nowhere else. The type is here so
//  the rule is testable; nothing in the MCP surface reads it.
//

import Foundation

public struct OriginEstimate: Equatable, Sendable {
    /// Upper-cased ISO 3166-1 alpha-2.
    public let isoCode: String
    /// The time zone the estimate came from, so the UI can say why
    /// (`DestinationCopy.origin(countryName:timeZone:)`).
    public let timeZoneIdentifier: String

    public init(isoCode: String, timeZoneIdentifier: String) {
        self.isoCode = isoCode
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public enum OriginEstimator {
    /// nil for UTC, GMT and `Etc/*` — zones that belong to no country — and
    /// for any identifier `table` has no answer for. `table` is asked with
    /// the identifier as Foundation spells it; GeoKit's table resolves the
    /// `backward` links (`Europe/Kiev` → `Europe/Kyiv`) itself.
    public static func estimate(timeZone: TimeZone, table: (String) -> String?) -> OriginEstimate? {
        let identifier = timeZone.identifier
        guard isCountryZone(identifier) else { return nil }
        guard let raw = table(identifier),
              let code = TrafficDestination.isoCode(from: raw.trimmingCharacters(in: .whitespaces)),
              code != "ZZ" else {
            return nil
        }
        return OriginEstimate(isoCode: code, timeZoneIdentifier: identifier)
    }

    /// The zones that name a place. `TimeZone(identifier: "UTC")` reports its
    /// identifier as `GMT`, so both spellings are refused, as is the whole
    /// `Etc/` family (`Etc/GMT+2` is an offset, not a country).
    static func isCountryZone(_ identifier: String) -> Bool {
        let upper = identifier.uppercased()
        if upper == "UTC" || upper == "GMT" || upper == "Z" { return false }
        if upper.hasPrefix("ETC/") { return false }
        return true
    }
}
