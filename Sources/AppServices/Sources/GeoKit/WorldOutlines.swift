//
//  WorldOutlines.swift
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
//  The country shapes behind the map: Natural Earth 1:110m, trimmed to
//  {iso, name} + geometry by the converter. Points are (x: longitude,
//  y: latitude) in degrees, the order GeoJSON uses; a projection turns them
//  into screen space.
//

import Foundation

public struct CountryOutline: Sendable, Identifiable {

    /// ISO 3166-1 alpha-2, or nil for the two shapes Natural Earth draws but
    /// the standard does not code (N. Cyprus, Somaliland).
    public let iso: String?
    /// Natural Earth's short name — "Germany", "Dem. Rep. Congo".
    public let name: String
    /// Exterior rings, one per polygon, each closed (first == last).
    public let polygons: [[CGPoint]]
    /// Interior rings — Lesotho's hole in South Africa is the notable one.
    public let holes: [[CGPoint]]

    public var id: String { iso ?? name }

    public var vertexCount: Int {
        polygons.reduce(0) { $0 + $1.count } + holes.reduce(0) { $0 + $1.count }
    }

    /// Inside one of the exterior rings and outside every hole. Ray casting;
    /// a point exactly on an edge may fall either way.
    public func contains(_ coordinate: GeoCoordinate) -> Bool {
        guard polygons.contains(where: { Self.ring($0, contains: coordinate) }) else { return false }
        return !holes.contains(where: { Self.ring($0, contains: coordinate) })
    }

    static func ring(_ ring: [CGPoint], contains coordinate: GeoCoordinate) -> Bool {
        let x = coordinate.longitude
        let y = coordinate.latitude
        var inside = false
        var index = 0
        while index + 1 < ring.count {
            let a = ring[index]
            let b = ring[index + 1]
            index += 1
            if (a.y > y) != (b.y > y) {
                let crossing = a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
                if x < crossing { inside.toggle() }
            }
        }
        return inside
    }
}

public struct WorldOutlines: Sendable {

    /// Sorted by name, as the converter writes them.
    public let countries: [CountryOutline]
    private let indexByISO: [String: Int]

    public static func bundled() throws -> WorldOutlines {
        try WorldOutlines(data: Data(contentsOf: GeoKit.resourceURL("world-110m", extension: "geojson")))
    }

    public init(data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "FeatureCollection",
              let features = root["features"] as? [[String: Any]] else {
            throw GeoKitError.malformed("world-110m.geojson is not a FeatureCollection")
        }
        var countries: [CountryOutline] = []
        countries.reserveCapacity(features.count)
        var indexByISO: [String: Int] = [:]
        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let name = properties["name"] as? String,
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else {
                throw GeoKitError.malformed("world-110m.geojson: feature without name or geometry")
            }
            let iso = properties["iso"] as? String
            let polygons: [[[[Double]]]]
            switch type {
            case "Polygon":
                guard let polygon = geometry["coordinates"] as? [[[Double]]] else {
                    throw GeoKitError.malformed("world-110m.geojson: \(name) has malformed coordinates")
                }
                polygons = [polygon]
            case "MultiPolygon":
                guard let multi = geometry["coordinates"] as? [[[[Double]]]] else {
                    throw GeoKitError.malformed("world-110m.geojson: \(name) has malformed coordinates")
                }
                polygons = multi
            default:
                throw GeoKitError.malformed("world-110m.geojson: \(name) is a \(type)")
            }
            var exteriors: [[CGPoint]] = []
            var holes: [[CGPoint]] = []
            for rings in polygons {
                for (ringIndex, ring) in rings.enumerated() {
                    let points = try ring.map { pair -> CGPoint in
                        guard pair.count == 2 else { throw GeoKitError.malformed("world-110m.geojson: \(name) has a non-2D vertex") }
                        return CGPoint(x: pair[0], y: pair[1])
                    }
                    guard points.count >= 4, let first = points.first, let last = points.last,
                          first.x == last.x, first.y == last.y else {
                        throw GeoKitError.malformed("world-110m.geojson: \(name) has an open ring")
                    }
                    if ringIndex == 0 { exteriors.append(points) } else { holes.append(points) }
                }
            }
            if let iso = iso {
                guard indexByISO[iso] == nil else { throw GeoKitError.malformed("world-110m.geojson: \(iso) appears twice") }
                indexByISO[iso] = countries.count
            }
            countries.append(CountryOutline(iso: iso, name: name, polygons: exteriors, holes: holes))
        }
        self.countries = countries
        self.indexByISO = indexByISO
    }

    /// Case-insensitive on the code.
    public func outline(for iso: String) -> CountryOutline? {
        indexByISO[iso.uppercased()].map { countries[$0] }
    }

    public var vertexCount: Int {
        countries.reduce(0) { $0 + $1.vertexCount }
    }

    /// The country whose outline contains the coordinate, for hit-testing.
    public func country(containing coordinate: GeoCoordinate) -> CountryOutline? {
        countries.first { $0.contains(coordinate) }
    }
}
