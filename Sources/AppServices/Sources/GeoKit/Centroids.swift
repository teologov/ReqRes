//
//  Centroids.swift
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
//  One point per country, for the dot on the map. Generated from the outlines
//  (largest polygon's area centroid, hand-corrected where that lands in the
//  sea or in a neighbour) plus a hand-placed table for the 75 countries too
//  small to have a polygon at 1:110m — see Resources/PROVENANCE.md.
//

import Foundation

public struct Centroids: Sendable {

    public let coordinates: [String: GeoCoordinate]

    public static func bundled() throws -> Centroids {
        try Centroids(data: Data(contentsOf: GeoKit.resourceURL("centroids", extension: "json")))
    }

    public init(data: Data) throws {
        let raw: [String: [Double]]
        do {
            raw = try JSONDecoder().decode([String: [Double]].self, from: data)
        } catch {
            throw GeoKitError.malformed("centroids.json: \(error)")
        }
        var coordinates: [String: GeoCoordinate] = [:]
        coordinates.reserveCapacity(raw.count)
        for (iso, pair) in raw {
            guard pair.count == 2, (-90...90).contains(pair[0]), (-180...180).contains(pair[1]) else {
                throw GeoKitError.malformed("centroids.json: \(iso) is not [lat, lon]")
            }
            coordinates[iso] = GeoCoordinate(latitude: pair[0], longitude: pair[1])
        }
        self.coordinates = coordinates
    }

    public var count: Int { coordinates.count }

    /// Case-insensitive on the code.
    public subscript(iso: String) -> GeoCoordinate? {
        coordinates[iso.uppercased()]
    }

    public func coordinate(for iso: String) -> GeoCoordinate? {
        self[iso]
    }
}
