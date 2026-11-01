//
//  GeoResolution.swift
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

import Foundation

/// Where an address points, as far as the map is concerned.
///
/// The three non-country cases are decided BEFORE the table is consulted, from
/// the address alone, so they never depend on what DB-IP happens to say about
/// reserved space.
public enum GeoResolution: Hashable, Sendable {
    /// ISO 3166-1 alpha-2, uppercase — "US", "DE". Never "ZZ".
    case country(String)
    /// RFC 1918 / RFC 4193 / link-local / carrier-grade NAT: another device on
    /// the user's network.
    case localNetwork
    /// Loopback — the request went to this Mac.
    case thisMac
    /// Unparseable, reserved (multicast, documentation, unspecified), or not in
    /// the table.
    case unknown

    /// The country code when this is a country, else nil.
    public var isoCode: String? {
        if case .country(let code) = self { return code }
        return nil
    }
}

/// A point on the globe in degrees. Latitude north-positive, longitude
/// east-positive — the order every API in this module uses.
public struct GeoCoordinate: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
