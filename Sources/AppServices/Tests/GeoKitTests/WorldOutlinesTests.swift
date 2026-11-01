//
//  WorldOutlinesTests.swift
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
//  The outlines and the centroids are one system: every centroid computed
//  from an outline must be INSIDE that outline (the converter checks this on
//  its side too, but the Swift ring test is the one the map's hit-testing
//  uses), and every country the IP table can name must have a point to draw.
//

import XCTest
@testable import GeoKit

final class WorldOutlinesTests: XCTestCase {

    private static let outlines: WorldOutlines = {
        do { return try WorldOutlines.bundled() } catch { fatalError("bundled outlines: \(error)") }
    }()
    private static let centroids: Centroids = {
        do { return try Centroids.bundled() } catch { fatalError("bundled centroids: \(error)") }
    }()

    private var outlines: WorldOutlines { Self.outlines }
    private var centroids: Centroids { Self.centroids }

    func testCountsAndShape() {
        XCTAssertEqual(outlines.countries.count, 177)
        XCTAssertEqual(outlines.countries.filter { $0.iso != nil }.count, 175)
        XCTAssertEqual(outlines.countries.filter { $0.iso == nil }.map(\.name).sorted(), ["N. Cyprus", "Somaliland"])
        XCTAssertEqual(outlines.countries.map(\.name), outlines.countries.map(\.name).sorted(), "sorted by name")
        XCTAssertGreaterThan(outlines.vertexCount, 9_000)
        XCTAssertLessThan(outlines.vertexCount, 12_000)
        let codes = outlines.countries.compactMap(\.iso)
        XCTAssertEqual(Set(codes).count, codes.count, "ISO codes are unique")
    }

    func testRingsAreClosedAndInRange() {
        for country in outlines.countries {
            for ring in country.polygons + country.holes {
                XCTAssertGreaterThanOrEqual(ring.count, 4, country.name)
                XCTAssertEqual(ring.first?.x, ring.last?.x, country.name)
                XCTAssertEqual(ring.first?.y, ring.last?.y, country.name)
                for point in ring {
                    XCTAssertTrue((-180...180).contains(point.x) && (-90...90).contains(point.y), "\(country.name) \(point)")
                    XCTAssertEqual(point.x, (point.x * 100).rounded() / 100, accuracy: 1e-9, "\(country.name) longitude has more than 2 decimals")
                    XCTAssertEqual(point.y, (point.y * 100).rounded() / 100, accuracy: 1e-9, "\(country.name) latitude has more than 2 decimals")
                }
            }
        }
    }

    func testGermany() throws {
        let germany = try XCTUnwrap(outlines.outline(for: "de"))
        XCTAssertEqual(germany.name, "Germany")
        XCTAssertEqual(germany.polygons.count, 1)
        XCTAssertTrue(germany.contains(GeoCoordinate(latitude: 52.52, longitude: 13.40)), "Berlin")
        XCTAssertTrue(germany.contains(GeoCoordinate(latitude: 48.14, longitude: 11.58)), "Munich")
        XCTAssertFalse(germany.contains(GeoCoordinate(latitude: 48.86, longitude: 2.35)), "Paris")
        XCTAssertFalse(germany.contains(GeoCoordinate(latitude: 52.37, longitude: 4.90)), "Amsterdam")
        let centroid = try XCTUnwrap(centroids["DE"])
        XCTAssertTrue(germany.contains(centroid), "Germany's centroid \(centroid) is outside Germany")
        XCTAssertEqual(centroid.latitude, 51.1, accuracy: 0.5)
        XCTAssertEqual(centroid.longitude, 10.4, accuracy: 0.5)
    }

    func testHolesAreRespected() throws {
        let southAfrica = try XCTUnwrap(outlines.outline(for: "ZA"))
        let lesotho = try XCTUnwrap(outlines.outline(for: "LS"))
        XCTAssertFalse(southAfrica.holes.isEmpty, "Lesotho should be a hole in South Africa")
        let maseru = GeoCoordinate(latitude: -29.31, longitude: 27.48)
        XCTAssertTrue(lesotho.contains(maseru))
        XCTAssertFalse(southAfrica.contains(maseru))
        XCTAssertTrue(southAfrica.contains(GeoCoordinate(latitude: -26.20, longitude: 28.04)), "Johannesburg")
        XCTAssertEqual(outlines.country(containing: maseru)?.iso, "LS")
    }

    func testMultiPolygonsAndTheAntimeridian() throws {
        let usa = try XCTUnwrap(outlines.outline(for: "US"))
        XCTAssertGreaterThan(usa.polygons.count, 2, "mainland + Alaska + Hawaii")
        XCTAssertTrue(usa.contains(GeoCoordinate(latitude: 61.22, longitude: -149.90)), "Anchorage")
        XCTAssertTrue(usa.contains(GeoCoordinate(latitude: 21.31, longitude: -157.86)), "Honolulu")
        let russia = try XCTUnwrap(outlines.outline(for: "RU"))
        XCTAssertTrue(russia.contains(GeoCoordinate(latitude: 55.75, longitude: 37.62)), "Moscow")
        XCTAssertTrue(russia.contains(GeoCoordinate(latitude: 64.73, longitude: 177.50)), "Anadyr, east of 180°'s split")
        let fiji = try XCTUnwrap(outlines.outline(for: "FJ"))
        XCTAssertGreaterThan(fiji.polygons.count, 1, "Fiji is split at the antimeridian")
    }

    func testEveryComputedCentroidIsInsideItsOutline() {
        var outside: [String] = []
        for country in outlines.countries {
            guard let iso = country.iso else { continue }
            guard let centroid = centroids[iso] else {
                XCTFail("\(iso) has an outline but no centroid")
                continue
            }
            if !country.contains(centroid) { outside.append("\(iso) \(centroid)") }
        }
        XCTAssertEqual(outside, [], "centroids outside their own outline")
    }

    func testEveryTableCountryHasACentroid() throws {
        let table = try IPCountryTable.bundled()
        let missing = table.countries.filter { $0 != "ZZ" && centroids[$0] == nil }
        XCTAssertEqual(missing, [], "IP table countries with no point to draw")
        XCTAssertEqual(centroids.count, table.countries.count - 1, "one centroid per country, none for ZZ")
        XCTAssertNil(centroids["ZZ"])
    }

    func testHandPlacedMicroStates() throws {
        // No polygon at 1:110m, so these come from the converter's hand table.
        XCTAssertNil(outlines.outline(for: "SG"))
        XCTAssertNil(outlines.outline(for: "HK"))
        let singapore = try XCTUnwrap(centroids["SG"])
        XCTAssertEqual(singapore.latitude, 1.35, accuracy: 0.2)
        XCTAssertEqual(singapore.longitude, 103.82, accuracy: 0.2)
        XCTAssertEqual(centroids["hk"]?.latitude ?? 0, 22.3, accuracy: 0.2)
    }

    func testMalformedGeoJSONThrows() {
        XCTAssertThrowsError(try WorldOutlines(data: Data()))
        XCTAssertThrowsError(try WorldOutlines(data: Data("{}".utf8)))
        XCTAssertThrowsError(try WorldOutlines(data: Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"iso":"XX","name":"X"},"geometry":{"type":"Point","coordinates":[0,0]}}]}"#.utf8)))
        XCTAssertThrowsError(try Centroids(data: Data("[]".utf8)))
        XCTAssertThrowsError(try Centroids(data: Data(#"{"DE":[91,0]}"#.utf8)))
    }
}
