//
//  WorldMapGeometry.swift
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
//  The world's shapes and points, in MapKit's terms (destination-map UX spec
//  §4.1). The SECOND of the two shell files that import GeoKit. Loaded off
//  main on the store's first activation: every country of Natural Earth's
//  1:110m outlines becomes `MKPolygon`s (its holes — South Africa's Lesotho —
//  as interior polygons of the largest ring), and every centroid a
//  `CLLocationCoordinate2D`. The map itself is Apple's since the MapKit
//  rewrite, so nothing here is projected or fitted: MapKit places a polygon
//  and an annotation from coordinates, and the view projects the rest
//  (labels, callout) itself from the visible `MKMapRect` — never with a
//  `MapProxy`, see `DestinationMapView`'s header.
//
//  Facts read from the resources and honoured here: 177 features keyed
//  `properties.iso` (`ISO_A2_EH` first, `null` for N. Cyprus and Somaliland —
//  drawable, never highlighted, and never washed because they have no
//  destination); `centroids.json` is `ISO2 → [lat, lon]`, latitude FIRST
//  (GeoKit's `GeoCoordinate` already names the two); 75 hand-placed centroids
//  belong to countries with no polygon at all, so a dot must never depend on
//  a polygon existing. Antarctica is dropped at load: no request goes there
//  and its wash would be a third of the world.
//

import Foundation
import GeoKit
import MapKit
import MCPKit

struct WorldMapGeometry {
    struct Feature: Identifiable {
        /// The ISO code, or the name for the two uncoded shapes.
        let id: String
        let iso: String?
        let name: String
        /// One per exterior ring, holes attached to the largest ring. Built
        /// once here because `MKPolygon` construction copies every vertex.
        let polygons: [MKPolygon]
    }

    let features: [Feature]
    /// By upper-cased ISO code.
    let centroids: [String: CLLocationCoordinate2D]
    /// GeoKit's required credit line, carried so the view that draws the data
    /// can show it without importing GeoKit itself.
    let attribution: String

    private static let droppedISOCodes: Set<String> = ["AQ"]

    // MARK: - Loading

    /// Reads the bundled resources. ~20 ms; call off main, once.
    static func load() throws -> WorldMapGeometry {
        let outlines = try WorldOutlines.bundled()
        let centroidTable = try Centroids.bundled()

        var features: [Feature] = []
        features.reserveCapacity(outlines.countries.count)
        for country in outlines.countries {
            if let iso = country.iso, droppedISOCodes.contains(iso.uppercased()) { continue }
            let polygons = Self.polygons(exteriors: country.polygons, holes: country.holes)
            guard !polygons.isEmpty else { continue }
            features.append(Feature(id: country.id, iso: country.iso?.uppercased(), name: country.name, polygons: polygons))
        }
        guard !features.isEmpty else {
            throw GeoKitError.malformed("world-110m.geojson: no drawable polygons")
        }

        var centroids: [String: CLLocationCoordinate2D] = [:]
        centroids.reserveCapacity(centroidTable.count)
        for (iso, coordinate) in centroidTable.coordinates {
            centroids[iso.uppercased()] = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }

        return WorldMapGeometry(features: features, centroids: centroids, attribution: GeoKit.attribution)
    }

    /// GeoJSON order: x is longitude, y is latitude. A ring of fewer than
    /// three vertices is not a polygon and is skipped rather than handed to
    /// MapKit, which would draw nothing and log.
    private static func polygons(exteriors: [[CGPoint]], holes: [[CGPoint]]) -> [MKPolygon] {
        let rings = exteriors.map(coordinates).filter { $0.count >= 3 }
        guard !rings.isEmpty else { return [] }
        let interior = holes.map(coordinates).filter { $0.count >= 3 }.map { MKPolygon(coordinates: $0, count: $0.count) }
        // The largest ring gets the holes: Natural Earth's one hole (Lesotho)
        // is in South Africa's mainland, and a hole assigned to an island it
        // does not touch is simply ignored by MapKit.
        let largestIndex = rings.indices.max { rings[$0].count < rings[$1].count } ?? 0
        return rings.enumerated().map { index, ring in
            index == largestIndex && !interior.isEmpty
                ? MKPolygon(coordinates: ring, count: ring.count, interiorPolygons: interior)
                : MKPolygon(coordinates: ring, count: ring.count)
        }
    }

    private static func coordinates(_ ring: [CGPoint]) -> [CLLocationCoordinate2D] {
        ring.map { CLLocationCoordinate2D(latitude: $0.y, longitude: $0.x) }
    }

    // MARK: - Lookup

    /// Where a country's dot goes; nil for a code the table lacks.
    func centroid(forISO iso: String) -> CLLocationCoordinate2D? {
        centroids[iso.uppercased()]
    }

    /// The outline to wash for a destination, if Natural Earth drew one at
    /// 1:110m (Singapore, Hong Kong, Malta and the micro-states did not get a
    /// polygon — their dot is all there is, by design).
    func feature(forISO iso: String) -> Feature? {
        let code = iso.uppercased()
        return features.first { $0.iso == code }
    }
}
