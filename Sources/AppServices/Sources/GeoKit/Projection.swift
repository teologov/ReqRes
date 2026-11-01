//
//  Projection.swift
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
//  Degrees → the unit square. Two projections: equirectangular (trivially
//  invertible, 2:1) and Robinson (the classic world-map look, from Robinson's
//  own 19-row table). Both put x = 0 at 180°W growing east and y = 0 at the
//  north pole growing SOUTH, i.e. screen order.
//

import Foundation

public protocol MapProjection: Sendable {
    /// Where a coordinate lands in the unit square. Out-of-range input is
    /// clamped, never NaN.
    func project(_ coordinate: GeoCoordinate) -> CGPoint
    /// width ÷ height of the whole map drawn at its natural proportions.
    var aspectRatio: Double { get }
}

public struct EquirectangularProjection: MapProjection {

    public init() {}

    public var aspectRatio: Double { 2 }

    public func project(_ coordinate: GeoCoordinate) -> CGPoint {
        let longitude = min(max(coordinate.longitude, -180), 180)
        let latitude = min(max(coordinate.latitude, -90), 90)
        return CGPoint(x: (longitude + 180) / 360, y: (90 - latitude) / 180)
    }

    /// The inverse, for hit-testing a click on the map.
    public func coordinate(at point: CGPoint) -> GeoCoordinate {
        GeoCoordinate(latitude: 90 - point.y * 180, longitude: point.x * 360 - 180)
    }
}

public struct RobinsonProjection: MapProjection {

    /// Robinson's table at 5° steps: PLEN scales the parallel's length, PDFE
    /// the distance from the equator (as a fraction of the pole's).
    static let table: [(plen: Double, pdfe: Double)] = [
        (1.0000, 0.0000), (0.9986, 0.0620), (0.9954, 0.1240), (0.9900, 0.1860), (0.9822, 0.2480),
        (0.9730, 0.3100), (0.9600, 0.3720), (0.9427, 0.4340), (0.9216, 0.4958), (0.8962, 0.5571),
        (0.8679, 0.6176), (0.8350, 0.6769), (0.7986, 0.7346), (0.7597, 0.7903), (0.7186, 0.8435),
        (0.6732, 0.8936), (0.6213, 0.9394), (0.5722, 0.9761), (0.5322, 1.0000),
    ]

    public init() {}

    /// Full width is 0.8487 · 2π · R, full height 1.3523 · 2 · R.
    public var aspectRatio: Double { (0.8487 * 2 * .pi) / (1.3523 * 2) }

    public func project(_ coordinate: GeoCoordinate) -> CGPoint {
        let longitude = min(max(coordinate.longitude, -180), 180)
        let latitude = min(max(coordinate.latitude, -90), 90)
        let steps = abs(latitude) / 5
        let index = min(Int(steps), Self.table.count - 2)
        let fraction = steps - Double(index)
        let lower = Self.table[index]
        let upper = Self.table[index + 1]
        let plen = lower.plen + (upper.plen - lower.plen) * fraction
        let pdfe = lower.pdfe + (upper.pdfe - lower.pdfe) * fraction
        let signed = latitude < 0 ? -pdfe : pdfe
        return CGPoint(x: 0.5 + plen * longitude / 360, y: 0.5 - signed / 2)
    }
}
