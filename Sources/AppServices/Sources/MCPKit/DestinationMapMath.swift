//
//  DestinationMapMath.swift
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
//  The arithmetic behind the destination map (destination-map UX spec §4),
//  kept out of the view so it can be tested with a plain `swift test`: the
//  dot scale, the label budget and its overlap rule, the zoom past which the
//  1:110m country wash is hidden and how strong it is, the camera region
//  that frames every dot, the wrap-safe projection of a map point into the
//  visible rect, and the spoken summary. The map itself is MapKit's (Apple Maps tiles,
//  Mercator, its own hit-testing on annotations); the view measures text and
//  places what MapKit does not — nothing here knows about SwiftUI or MapKit.
//

import CoreGraphics
import Foundation

/// The map's sizes, from the spec's numbers.
public enum DestinationMapScale {
    public static let minDotRadius: CGFloat = 3
    public static let maxDotRadius: CGFloat = 12
    /// Every hit target is at least this wide (24pt across).
    public static let minHitRadius: CGFloat = 12
    /// At most this many arcs, the busiest destinations first.
    public static let maxArcs = 40
    /// The camera distance (metres, `MapCamera.distance`) below which the
    /// country wash is hidden. Natural Earth's 1:110m outlines sit up to tens
    /// of kilometres off Apple's coastlines; at this distance the view is
    /// roughly a continent tall and the mismatch is under a few points, and
    /// any closer it reads as a drawing error over a real map (measured on
    /// the rendered probe, 2026-09-25).
    public static let washMaximumCameraDistance: Double = 5_000_000

    /// `r = 3 + 9·√(n / max)`: AREA grows with the share of requests, so the
    /// busiest destination is always the 12pt dot and one request is never
    /// invisible. Clamped so a stray count above the maximum cannot draw a
    /// dot that swallows its neighbours.
    public static func dotRadius(requests: Int, maxRequests: Int) -> CGFloat {
        let share = Double(max(requests, 0)) / Double(max(maxRequests, 1))
        let radius = 3 + 9 * sqrt(share)
        return CGFloat(min(max(radius, Double(minDotRadius)), Double(maxDotRadius)))
    }

    /// `max(r + 4, 12)` — a 3pt dot is still a 24pt target.
    public static func hitRadius(dotRadius: CGFloat) -> CGFloat {
        max(dotRadius + 4, minHitRadius)
    }

    /// `max(3, ⌊width / 110⌋)`: a 628pt map labels five destinations.
    public static func labelBudget(mapWidth: CGFloat) -> Int {
        max(3, Int(mapWidth / 110))
    }

    /// Whether the wash of accent over countries with traffic is drawn at
    /// this camera distance. Fails toward drawing it: an unknown distance
    /// (the first frame, before any camera update) shows the world view,
    /// where the wash belongs.
    public static func washIsVisible(cameraDistance: Double?) -> Bool {
        guard let cameraDistance, cameraDistance.isFinite else { return true }
        return cameraDistance >= washMaximumCameraDistance
    }

    /// The wash's fill opacity over Apple's tiles. 0.12 was invisible over
    /// saturated land in both appearances (looked at, 2026-09-25: Canada and
    /// Mexico indistinguishable at world zoom); at 0.24 a washed country
    /// reads as tinted without hiding Apple's own labels. The view and the
    /// probe's composite draw from the same two numbers.
    public static let washOpacity: Double = 0.24
    /// The selected or hovered country's wash.
    public static let washHighlightedOpacity: Double = 0.42
}

/// Where a Mercator map point is inside the visible extent — the arithmetic
/// `DestinationMapView` uses instead of `MapProxy` (see its header). Pure
/// so the one rule that is easy to get wrong is pinned: a visible rect that
/// spans the 180th meridian has `originX + width > worldWidth`, and a point
/// on its far side has `x < originX`. Without the wrap, a Pacific fit
/// (Tokyo talking to California — exactly what `DestinationCameraFit`
/// produces) puts every American dot at a negative x, and its label and
/// callout vanish while MapKit draws the dot correctly.
public enum DestinationMapProjection {
    /// `x`'s distance east of `originX`, wrapped into `0 ..< worldWidth`
    /// so a point across the antimeridian lands on the far side of the
    /// visible rect rather than a world to the left of it. A point that is
    /// genuinely off the rect stays past its width.
    public static func wrappedOffset(_ x: Double, from originX: Double, worldWidth: Double) -> Double {
        var offset = x - originX
        guard worldWidth > 0, offset.isFinite else { return offset }
        if offset < 0 { offset += worldWidth }
        if offset >= worldWidth { offset -= worldWidth }
        return offset
    }

    /// The point's position as a fraction of the visible rect (0…1 inside
    /// it), x wrapped as above. Nil for an empty rect.
    public static func unitPoint(
        x: Double, y: Double,
        visibleOriginX: Double, visibleOriginY: Double,
        visibleWidth: Double, visibleHeight: Double,
        worldWidth: Double
    ) -> (x: Double, y: Double)? {
        guard visibleWidth > 0, visibleHeight > 0 else { return nil }
        return (
            wrappedOffset(x, from: visibleOriginX, worldWidth: worldWidth) / visibleWidth,
            (y - visibleOriginY) / visibleHeight
        )
    }
}

/// A camera region in degrees — MapKit's `MKCoordinateRegion` without
/// MapKit, so the fit can be tested here and the view converts.
public struct DestinationMapRegion: Equatable, Sendable {
    public var centerLatitude: Double
    public var centerLongitude: Double
    public var latitudeDelta: Double
    public var longitudeDelta: Double

    public init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }
}

/// The camera that frames every plotted dot and the origin (spec §4: the
/// initial camera, and the Fit action). Pure so the antimeridian rule can be
/// pinned: the longitudes are covered by the SMALLEST arc that contains
/// them all, so a Mac in Tokyo talking to California is framed across the
/// Pacific rather than the long way round through Europe.
public enum DestinationCameraFit {
    /// The whole world, for nothing to frame. Centred a little north of the
    /// equator because the land is; the longitude span is the full circle
    /// and MapKit clamps the latitude span to what Mercator can show.
    public static let world = DestinationMapRegion(centerLatitude: 20, centerLongitude: 0, latitudeDelta: 140, longitudeDelta: 360)
    /// A lone dot is framed at a country's scale, never a street's.
    public static let minimumSpan: Double = 16
    /// Each side gets this fraction of the span as margin, so a dot on the
    /// edge of the fit has room for its label and its hit radius.
    public static let padding: Double = 0.2

    public static func region(framing coordinates: [(latitude: Double, longitude: Double)]) -> DestinationMapRegion {
        let valid = coordinates.filter { (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }
        guard !valid.isEmpty else { return world }

        let minLat = valid.map(\.latitude).min()!
        let maxLat = valid.map(\.latitude).max()!
        let (centerLongitude, longitudeSpan) = smallestLongitudeArc(valid.map(\.longitude))

        var latitudeDelta = max((maxLat - minLat) * (1 + 2 * padding), minimumSpan)
        var longitudeDelta = max(longitudeSpan * (1 + 2 * padding), minimumSpan)
        latitudeDelta = min(latitudeDelta, 170)
        longitudeDelta = min(longitudeDelta, 360)
        // The centre stays where the span can still be shown: a region that
        // reaches past a pole is clamped by MapKit into a different view.
        let centerLatitude = min(max((minLat + maxLat) / 2, -85 + latitudeDelta / 2), 85 - latitudeDelta / 2)
        return DestinationMapRegion(
            centerLatitude: centerLatitude,
            centerLongitude: centerLongitude,
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }

    /// The centre and width (degrees) of the smallest arc of the circle
    /// covering every longitude: the complement of the largest gap between
    /// neighbouring longitudes once sorted, the wrap-around gap included.
    static func smallestLongitudeArc(_ longitudes: [Double]) -> (center: Double, span: Double) {
        let sorted = longitudes.sorted()
        guard let first = sorted.first, let last = sorted.last else { return (0, 360) }
        guard sorted.count > 1 else { return (first, 0) }
        var largestGap = first + 360 - last
        var gapStart = last  // the arc runs from the gap's END round to its START
        for index in 1..<sorted.count {
            let gap = sorted[index] - sorted[index - 1]
            if gap > largestGap {
                largestGap = gap
                gapStart = sorted[index - 1]
            }
        }
        let span = 360 - largestGap
        // The arc starts where the largest gap ends.
        let start = gapStart + largestGap
        var center = start + span / 2
        if center > 180 { center -= 360 }
        if center < -180 { center += 360 }
        return (center, span)
    }
}

/// Which labels fit (spec §4.3): in rank order, the selected and hovered
/// destinations take budget slots first, and a label whose rect intersects a
/// placed one is DROPPED — its value lives in the callout and the list.
public enum DestinationLabelLayout {
    public struct Candidate: Equatable {
        public var id: String
        /// Where the label may go, preferred first (right of the dot, then
        /// left, below, above). The view has already dropped the sides that
        /// leave the canvas.
        public var rects: [CGRect]
        public init(id: String, rect: CGRect) {
            self.init(id: id, rects: [rect])
        }
        public init(id: String, rects: [CGRect]) {
            self.id = id
            self.rects = rects
        }
    }

    public struct Placement: Equatable {
        public var id: String
        public var rect: CGRect
        public init(id: String, rect: CGRect) {
            self.id = id
            self.rect = rect
        }
    }

    /// `ranked` is busiest first. A candidate takes the first of its rects
    /// that touches nothing placed so far (nor anything in `reserved`); one
    /// with no free side is dropped — the callout and the list carry it —
    /// EXCEPT the busiest country and the `priority` ids (selected, hovered),
    /// which are never dropped and never budgeted: with every side taken they
    /// go where they overlap least. Returns the placements in the order they
    /// were considered.
    public static func placements(ranked: [Candidate], budget: Int, priority: Set<String>, reserved: [CGRect] = []) -> [Placement] {
        guard budget > 0 else { return [] }
        let ordered = ranked.filter { priority.contains($0.id) } + ranked.filter { !priority.contains($0.id) }
        var placed = reserved
        var out: [Placement] = []
        for candidate in ordered {
            let mustPlace = priority.contains(candidate.id) || candidate.id == ranked.first?.id
            guard out.count < budget || mustPlace else { continue }
            guard !candidate.rects.isEmpty else { continue }
            if let rect = candidate.rects.first(where: { rect in !placed.contains { $0.intersects(rect) } }) {
                placed.append(rect)
                out.append(Placement(id: candidate.id, rect: rect))
            } else if mustPlace {
                let rect = leastOverlapping(candidate.rects, against: placed)
                placed.append(rect)
                out.append(Placement(id: candidate.id, rect: rect))
            }
        }
        return out
    }

    /// The ids that get a label, in the order they were considered.
    public static func place(ranked: [Candidate], budget: Int, priority: Set<String>, reserved: [CGRect] = []) -> [String] {
        placements(ranked: ranked, budget: budget, priority: priority, reserved: reserved).map(\.id)
    }

    /// For a label that is always drawn (the origin's "You · approximate"):
    /// the first of `rects` touching none of `occupied`, or the one that
    /// overlaps least when every side is taken.
    public static func freeRect(_ rects: [CGRect], avoiding occupied: [CGRect]) -> CGRect? {
        guard !rects.isEmpty else { return nil }
        return rects.first(where: { rect in !occupied.contains { $0.intersects(rect) } }) ?? leastOverlapping(rects, against: occupied)
    }

    private static func leastOverlapping(_ rects: [CGRect], against placed: [CGRect]) -> CGRect {
        func overlap(_ rect: CGRect) -> CGFloat {
            placed.reduce(0) { total, other in
                let i = other.intersection(rect)
                return total + (i.isNull ? 0 : i.width * i.height)
            }
        }
        return rects.min { overlap($0) < overlap($1) } ?? rects[0]
    }
}

/// The one VoiceOver element's value (spec §4.3): the list beside the map is
/// the navigable surface, so this says what the picture shows and where the
/// rest is.
public enum DestinationMapSummary {
    /// `ranked` is the plotted countries busiest first as `(name, requests)`;
    /// the three class counts are dropped from the sentence when zero.
    public static func spoken(
        ranked: [(name: String, requests: Int)],
        thisMac: Int,
        localNetwork: Int,
        unknown: Int,
        locale: Locale = .current
    ) -> String {
        var sentences: [String] = []
        if ranked.isEmpty {
            sentences.append("No destinations plotted.")
        } else {
            // `CountryPresentation.plural` adds an `s`; this unit does not.
            sentences.append("\(CountryPresentation.groupedDigits(ranked.count, locale: locale)) \(ranked.count == 1 ? "country" : "countries").")
            var most = "Most requests to \(ranked[0].name), \(CountryPresentation.groupedDigits(ranked[0].requests, locale: locale))"
            if ranked.count > 1 {
                most += ", then \(ranked[1].name), \(CountryPresentation.groupedDigits(ranked[1].requests, locale: locale))"
            }
            sentences.append(most + ".")
        }
        var beside: [String] = []
        if thisMac > 0 { beside.append("\(TrafficDestination.thisMacLabel) \(CountryPresentation.groupedDigits(thisMac, locale: locale))") }
        if localNetwork > 0 { beside.append("\(TrafficDestination.localNetworkLabel) \(CountryPresentation.groupedDigits(localNetwork, locale: locale))") }
        if unknown > 0 { beside.append("\(TrafficDestination.unknownLabel) \(CountryPresentation.groupedDigits(unknown, locale: locale))") }
        if !beside.isEmpty {
            sentences.append(beside.joined(separator: ", ") + (beside.count == 1 ? " is" : " are") + " listed beside the map.")
        }
        return sentences.joined(separator: " ")
    }
}
