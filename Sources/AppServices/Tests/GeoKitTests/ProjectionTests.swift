//
//  ProjectionTests.swift
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

import XCTest
@testable import GeoKit

final class ProjectionTests: XCTestCase {

    func testEquirectangularAnchors() {
        let projection = EquirectangularProjection()
        let origin = projection.project(GeoCoordinate(latitude: 0, longitude: 0))
        XCTAssertEqual(origin.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(origin.y, 0.5, accuracy: 1e-12)
        XCTAssertEqual(projection.project(GeoCoordinate(latitude: 90, longitude: 0)).y, 0, accuracy: 1e-12, "north pole at the top")
        XCTAssertEqual(projection.project(GeoCoordinate(latitude: -90, longitude: 0)).y, 1, accuracy: 1e-12, "south pole at the bottom")
        XCTAssertEqual(projection.project(GeoCoordinate(latitude: 0, longitude: -180)).x, 0, accuracy: 1e-12, "antimeridian, west edge")
        XCTAssertEqual(projection.project(GeoCoordinate(latitude: 0, longitude: 180)).x, 1, accuracy: 1e-12, "antimeridian, east edge")
        XCTAssertEqual(projection.aspectRatio, 2)
    }

    func testEquirectangularIsLinearAndInvertible() {
        let projection = EquirectangularProjection()
        let berlin = GeoCoordinate(latitude: 52.52, longitude: 13.40)
        let point = projection.project(berlin)
        XCTAssertEqual(point.x, (13.40 + 180) / 360, accuracy: 1e-12)
        XCTAssertEqual(point.y, (90 - 52.52) / 180, accuracy: 1e-12)
        let back = projection.coordinate(at: point)
        XCTAssertEqual(back.latitude, berlin.latitude, accuracy: 1e-9)
        XCTAssertEqual(back.longitude, berlin.longitude, accuracy: 1e-9)
    }

    func testOutOfRangeInputIsClamped() {
        for projection in [EquirectangularProjection(), RobinsonProjection()] as [MapProjection] {
            let point = projection.project(GeoCoordinate(latitude: 400, longitude: -900))
            XCTAssertEqual(point.y, 0, accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(point.x, 0)
            XCTAssertFalse(point.x.isNaN || point.y.isNaN)
        }
    }

    func testRobinsonAnchors() {
        let projection = RobinsonProjection()
        let origin = projection.project(GeoCoordinate(latitude: 0, longitude: 0))
        XCTAssertEqual(origin.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(origin.y, 0.5, accuracy: 1e-12)
        XCTAssertEqual(projection.project(GeoCoordinate(latitude: 90, longitude: 0)).y, 0, accuracy: 1e-12)
        XCTAssertEqual(projection.project(GeoCoordinate(latitude: -90, longitude: 0)).y, 1, accuracy: 1e-12)
        XCTAssertEqual(projection.project(GeoCoordinate(latitude: 0, longitude: 180)).x, 1, accuracy: 1e-12, "the equator spans the full width")
        XCTAssertEqual(projection.project(GeoCoordinate(latitude: 0, longitude: -180)).x, 0, accuracy: 1e-12)
        // The poles are 0.5322 of the equator's length — the flat top of a Robinson map.
        XCTAssertEqual(projection.project(GeoCoordinate(latitude: 90, longitude: 180)).x, 0.5 + 0.5322 / 2, accuracy: 1e-9)
        XCTAssertEqual(projection.project(GeoCoordinate(latitude: 60, longitude: 180)).x, 0.5 + 0.7986 / 2, accuracy: 1e-9)
        XCTAssertEqual(projection.aspectRatio, 1.9716, accuracy: 0.001)
    }

    func testRobinsonIsSymmetricMonotonicAndInsideTheSquare() {
        let projection = RobinsonProjection()
        var previousY = -1.0
        for latitude in stride(from: 90.0, through: -90.0, by: -2.5) {
            for longitude in stride(from: -180.0, through: 180.0, by: 7.5) {
                let point = projection.project(GeoCoordinate(latitude: latitude, longitude: longitude))
                XCTAssertTrue((0...1).contains(point.x) && (0...1).contains(point.y), "\(latitude),\(longitude) → \(point)")
                let mirrored = projection.project(GeoCoordinate(latitude: -latitude, longitude: -longitude))
                XCTAssertEqual(point.x, 1 - mirrored.x, accuracy: 1e-12)
                XCTAssertEqual(point.y, 1 - mirrored.y, accuracy: 1e-12)
            }
            let y = projection.project(GeoCoordinate(latitude: latitude, longitude: 0)).y
            XCTAssertGreaterThan(y, previousY, "y grows as latitude falls")
            previousY = y
        }
    }
}
