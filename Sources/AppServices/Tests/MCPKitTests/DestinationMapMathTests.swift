//
//  DestinationMapMathTests.swift
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
//  Destination-map UX spec §4: the dot scale's floor and ceiling, the label
//  budget and its drop-never-clip rule, the zoom past which the 1:110m wash
//  is hidden, and the camera fit that frames every dot across the SHORT way
//  round the globe.
//

import XCTest
@testable import MCPKit

final class DestinationMapMathTests: XCTestCase {

    // MARK: - Dot scale (spec §4.3)

    func testDotRadiusGrowsWithTheSquareRootOfShare() {
        XCTAssertEqual(DestinationMapScale.dotRadius(requests: 100, maxRequests: 100), 12, accuracy: 1e-9)
        XCTAssertEqual(DestinationMapScale.dotRadius(requests: 25, maxRequests: 100), 3 + 9 * 0.5, accuracy: 1e-9)
        XCTAssertEqual(DestinationMapScale.dotRadius(requests: 1, maxRequests: 10_000), 3.09, accuracy: 0.001)
    }

    func testDotRadiusIsClampedAndSurvivesAZeroMaximum() {
        XCTAssertEqual(DestinationMapScale.dotRadius(requests: 0, maxRequests: 0), 3)
        XCTAssertEqual(DestinationMapScale.dotRadius(requests: 500, maxRequests: 100), 12, "a count above the maximum never draws a bigger dot")
        XCTAssertEqual(DestinationMapScale.dotRadius(requests: -5, maxRequests: 10), 3)
    }

    func testHitRadiusIsAtLeastTwelve() {
        XCTAssertEqual(DestinationMapScale.hitRadius(dotRadius: 3), 12)
        XCTAssertEqual(DestinationMapScale.hitRadius(dotRadius: 8), 12)
        XCTAssertEqual(DestinationMapScale.hitRadius(dotRadius: 12), 16)
    }

    // MARK: - Label budget (spec §4.3)

    func testLabelBudgetIsMaxThreeOrWidthOver110() {
        XCTAssertEqual(DestinationMapScale.labelBudget(mapWidth: 628), 5)
        XCTAssertEqual(DestinationMapScale.labelBudget(mapWidth: 200), 3)
        XCTAssertEqual(DestinationMapScale.labelBudget(mapWidth: 0), 3)
        XCTAssertEqual(DestinationMapScale.labelBudget(mapWidth: 1100), 10)
    }

    func testLabelsAreDroppedNotClippedAndPriorityTakesSlotsFirst() {
        let ranked = [
            DestinationLabelLayout.Candidate(id: "US", rect: CGRect(x: 0, y: 0, width: 60, height: 12)),
            DestinationLabelLayout.Candidate(id: "DE", rect: CGRect(x: 100, y: 0, width: 60, height: 12)),
            // Overlaps DE: dropped whatever the budget.
            DestinationLabelLayout.Candidate(id: "NL", rect: CGRect(x: 130, y: 4, width: 60, height: 12)),
            DestinationLabelLayout.Candidate(id: "JP", rect: CGRect(x: 300, y: 0, width: 60, height: 12)),
            DestinationLabelLayout.Candidate(id: "BR", rect: CGRect(x: 400, y: 0, width: 60, height: 12)),
        ]
        XCTAssertEqual(DestinationLabelLayout.place(ranked: ranked, budget: 3, priority: []), ["US", "DE", "JP"])
        // The hovered/selected BR is considered first and takes a slot from JP.
        XCTAssertEqual(DestinationLabelLayout.place(ranked: ranked, budget: 3, priority: ["BR"]), ["BR", "US", "DE"])
        // A prioritised label that overlaps still wins its rect — DE is then dropped.
        XCTAssertEqual(DestinationLabelLayout.place(ranked: ranked, budget: 5, priority: ["NL"]), ["NL", "US", "JP", "BR"])
        XCTAssertEqual(DestinationLabelLayout.place(ranked: ranked, budget: 0, priority: ["US"]), [])
    }

    func testAReservedRectDropsTheLabelsItTouches() {
        let origin = CGRect(x: 90, y: -2, width: 80, height: 14)
        let ranked = [
            DestinationLabelLayout.Candidate(id: "DE", rect: CGRect(x: 100, y: 0, width: 60, height: 12)),
            DestinationLabelLayout.Candidate(id: "US", rect: CGRect(x: 0, y: 0, width: 60, height: 12)),
        ]
        // DE's only rect lies under the origin's label: with one side and no
        // priority it is NOT dropped — it is the busiest country, so it is
        // placed anyway, overlapping least (its one option). US is free.
        XCTAssertEqual(DestinationLabelLayout.place(ranked: ranked, budget: 3, priority: [], reserved: [origin]), ["DE", "US"])
        // A country that is neither busiest nor selected IS dropped.
        let quiet = [
            DestinationLabelLayout.Candidate(id: "US", rect: CGRect(x: 0, y: 0, width: 60, height: 12)),
            DestinationLabelLayout.Candidate(id: "DE", rect: CGRect(x: 100, y: 0, width: 60, height: 12)),
        ]
        XCTAssertEqual(DestinationLabelLayout.place(ranked: quiet, budget: 3, priority: [], reserved: [origin]), ["US"])
        // Selected, it survives: priority is never dropped either.
        XCTAssertEqual(DestinationLabelLayout.place(ranked: quiet, budget: 3, priority: ["DE"], reserved: [origin]), ["DE", "US"])
    }

    /// From Amsterdam, Germany's label sat under the origin's
    /// "You · approximate" and vanished from the map that showed its dot. A
    /// candidate now offers alternate sides and takes the first free one.
    func testALabelBlockedOnOneSideTakesTheNextFreeSide() {
        let right = CGRect(x: 100, y: 0, width: 60, height: 12)
        let left = CGRect(x: 20, y: 0, width: 60, height: 12)
        let below = CGRect(x: 60, y: 20, width: 60, height: 12)
        let reserved = CGRect(x: 95, y: -2, width: 90, height: 16)  // over the right rect
        let ranked = [
            DestinationLabelLayout.Candidate(id: "DE", rects: [right, left, below]),
            DestinationLabelLayout.Candidate(id: "NL", rects: [CGRect(x: 10, y: 4, width: 60, height: 12)]),  // collides with DE's left
        ]
        let placements = DestinationLabelLayout.placements(ranked: ranked, budget: 3, priority: [], reserved: [reserved])
        XCTAssertEqual(placements.map(\.id), ["DE"], "NL's only side is under DE's chosen left rect")
        XCTAssertEqual(placements.first?.rect, left)
        // With DE selected and NL busiest, NL takes its rect first and DE goes
        // to its third side.
        let nlFirst = [ranked[1], ranked[0]]
        let both = DestinationLabelLayout.placements(ranked: nlFirst, budget: 3, priority: ["DE"], reserved: [reserved])
        XCTAssertEqual(both.map(\.id), ["DE", "NL"])
        XCTAssertEqual(both.first?.rect, left, "priority is considered first, so DE still gets left")
        XCTAssertEqual(both.last?.rect, nlFirst[0].rects[0], "NL is busiest: never dropped, overlaps least (its one option)")
    }

    func testTheBusiestAndThePriorityAreExemptFromTheBudget() {
        let ranked = (0..<6).map { i in
            DestinationLabelLayout.Candidate(id: "C\(i)", rect: CGRect(x: CGFloat(i) * 100, y: 0, width: 60, height: 12))
        }
        // Budget 2, C5 hovered: C5 first (priority), then C0 (busiest, within
        // budget), and C1 fills the budget; C0 would have been kept even at
        // budget 1.
        XCTAssertEqual(DestinationLabelLayout.place(ranked: ranked, budget: 2, priority: ["C5"]), ["C5", "C0"])
        XCTAssertEqual(DestinationLabelLayout.place(ranked: ranked, budget: 1, priority: ["C5"]), ["C5", "C0"])
    }

    func testFreeRectPrefersAnUntouchedSideAndFallsBackToTheLeastOverlap() {
        let a = CGRect(x: 0, y: 0, width: 50, height: 10)
        let b = CGRect(x: 100, y: 0, width: 50, height: 10)
        XCTAssertEqual(DestinationLabelLayout.freeRect([a, b], avoiding: [CGRect(x: 10, y: 0, width: 10, height: 10)]), b)
        XCTAssertEqual(DestinationLabelLayout.freeRect([a, b], avoiding: []), a)
        // Both touched: a loses 100pt², b loses 50pt².
        XCTAssertEqual(
            DestinationLabelLayout.freeRect([a, b], avoiding: [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 100, y: 0, width: 5, height: 10)]),
            b
        )
        XCTAssertNil(DestinationLabelLayout.freeRect([], avoiding: []))
    }

    // MARK: - The wash and the zoom (spec §4, MapKit)

    func testTheWashHidesOnceTheCameraIsCloserThanAContinent() {
        XCTAssertTrue(DestinationMapScale.washIsVisible(cameraDistance: nil), "before the first camera update the world is shown")
        XCTAssertTrue(DestinationMapScale.washIsVisible(cameraDistance: 30_000_000))
        XCTAssertTrue(DestinationMapScale.washIsVisible(cameraDistance: DestinationMapScale.washMaximumCameraDistance))
        XCTAssertFalse(DestinationMapScale.washIsVisible(cameraDistance: 1_000_000), "a country-sized view shows the 110m outlines' errors")
        XCTAssertTrue(DestinationMapScale.washIsVisible(cameraDistance: .nan))
    }

    func testTheWashIsStrongEnoughToReadOverAppleTilesAndStrongerWhenHighlighted() {
        // 0.12 vanished over saturated land (looked at); a washed country must
        // read as tinted, and a selected one more so — without hiding Apple's
        // labels under it.
        XCTAssertGreaterThanOrEqual(DestinationMapScale.washOpacity, 0.2)
        XCTAssertLessThanOrEqual(DestinationMapScale.washOpacity, 0.35)
        XCTAssertGreaterThan(DestinationMapScale.washHighlightedOpacity, DestinationMapScale.washOpacity)
        XCTAssertLessThanOrEqual(DestinationMapScale.washHighlightedOpacity, 0.5)
    }

    // MARK: - Projection into the visible rect (the antimeridian)

    /// MapKit's world is `MKMapSize.world.width` wide; the numbers here are a
    /// world of 1,000 for readability — the rule does not depend on the unit.
    func testAPointInsideAnOrdinaryRectIsItsPlainOffset() {
        XCTAssertEqual(DestinationMapProjection.wrappedOffset(350, from: 300, worldWidth: 1_000), 50)
        let unit = DestinationMapProjection.unitPoint(x: 350, y: 120, visibleOriginX: 300, visibleOriginY: 100, visibleWidth: 200, visibleHeight: 80, worldWidth: 1_000)
        XCTAssertEqual(unit?.x, 0.25)
        XCTAssertEqual(unit?.y, 0.25)
    }

    func testAPointAcrossTheAntimeridianLandsOnTheFarSideOfASpanningRect() {
        // A Pacific fit: the rect starts at 90% of the world and is 40% wide,
        // so it wraps past the antimeridian; a point at 10% (California) is
        // on its far side, 20% of the world east of the origin — not a world
        // to the left of it, which is where the unwrapped offset put it.
        let offset = DestinationMapProjection.wrappedOffset(100, from: 900, worldWidth: 1_000)
        XCTAssertEqual(offset, 200)
        let unit = DestinationMapProjection.unitPoint(x: 100, y: 0, visibleOriginX: 900, visibleOriginY: 0, visibleWidth: 400, visibleHeight: 100, worldWidth: 1_000)
        XCTAssertEqual(unit?.x, 0.5)
    }

    func testAPointGenuinelyOffTheRectStaysOffIt() {
        // West of an ordinary rect: wrapped, it is most of a world to the
        // east — past the rect's width, so still not drawn.
        let unit = DestinationMapProjection.unitPoint(x: 250, y: 0, visibleOriginX: 300, visibleOriginY: 0, visibleWidth: 200, visibleHeight: 100, worldWidth: 1_000)
        XCTAssertEqual(unit?.x, 4.75)
        // And a point a full world east is the same point.
        XCTAssertEqual(DestinationMapProjection.wrappedOffset(1_350, from: 300, worldWidth: 1_000), 50)
    }

    func testAnEmptyRectProjectsNothing() {
        XCTAssertNil(DestinationMapProjection.unitPoint(x: 1, y: 1, visibleOriginX: 0, visibleOriginY: 0, visibleWidth: 0, visibleHeight: 10, worldWidth: 1_000))
        XCTAssertEqual(DestinationMapProjection.wrappedOffset(5, from: 10, worldWidth: 0), -5, "no world width, no wrap")
    }

    // MARK: - Camera fit (spec §4: the initial camera and the Fit action)

    func testAnEmptyFitIsTheWholeWorld() {
        XCTAssertEqual(DestinationCameraFit.region(framing: []), DestinationCameraFit.world)
        XCTAssertEqual(DestinationCameraFit.region(framing: [(latitude: 100, longitude: 0)]), DestinationCameraFit.world, "an invalid coordinate frames nothing")
        XCTAssertEqual(DestinationCameraFit.world.longitudeDelta, 360)
    }

    func testALoneDotIsFramedAtACountrysScale() {
        let region = DestinationCameraFit.region(framing: [(latitude: 51, longitude: 10)])
        XCTAssertEqual(region.centerLatitude, 51, accuracy: 1e-9)
        XCTAssertEqual(region.centerLongitude, 10, accuracy: 1e-9)
        XCTAssertEqual(region.latitudeDelta, DestinationCameraFit.minimumSpan)
        XCTAssertEqual(region.longitudeDelta, DestinationCameraFit.minimumSpan)
    }

    func testTheFitPadsTheBoundingBoxOnEverySide() {
        // Amsterdam, Frankfurt, Virginia: lon −78…8.7 (span 86.7), lat 39…52.4.
        let region = DestinationCameraFit.region(framing: [(52.4, 4.9), (50.1, 8.7), (39.0, -78.0)])
        XCTAssertEqual(region.centerLongitude, (-78 + 8.7) / 2, accuracy: 0.05)
        XCTAssertEqual(region.longitudeDelta, 86.7 * 1.4, accuracy: 0.05)
        XCTAssertEqual(region.centerLatitude, (39 + 52.4) / 2, accuracy: 1e-9)
        XCTAssertEqual(region.latitudeDelta, max(13.4 * 1.4, DestinationCameraFit.minimumSpan), accuracy: 1e-9)
    }

    /// Tokyo talking to California: the short way is across the Pacific,
    /// centred near the antimeridian — never the 236° the long way round.
    func testTheFitCrossesTheAntimeridianWhenThatIsShorter() {
        let region = DestinationCameraFit.region(framing: [(35.7, 139.7), (37.4, -122.1)])
        // The gap from −122.1 east to 139.7 is 261.8°, so the arc is 98.2°
        // wide, from 139.7 east through 180 to −122.1: centre 188.8 → −171.2.
        XCTAssertEqual(region.centerLongitude, -171.2, accuracy: 0.05)
        XCTAssertEqual(region.longitudeDelta, 98.2 * 1.4, accuracy: 0.05)
        // Add Frankfurt and the world's shortest cover is still not the whole circle.
        let three = DestinationCameraFit.region(framing: [(35.7, 139.7), (37.4, -122.1), (50.1, 8.7)])
        XCTAssertLessThan(three.longitudeDelta, 360)
    }

    func testTheFitNeverReachesPastAPoleOrTheFullCircle() {
        let polar = DestinationCameraFit.region(framing: [(89, 0), (-89, 0)])
        XCTAssertEqual(polar.latitudeDelta, 170)
        XCTAssertEqual(polar.centerLatitude, 0, accuracy: 1e-9)
        let north = DestinationCameraFit.region(framing: [(84, 0)])
        XCTAssertLessThanOrEqual(north.centerLatitude + north.latitudeDelta / 2, 85)
        let everywhere = DestinationCameraFit.region(framing: [(0, -179), (0, -60), (0, 60), (0, 179)])
        XCTAssertLessThanOrEqual(everywhere.longitudeDelta, 360)
    }

    func testTheSmallestLongitudeArcIsTheComplementOfTheLargestGap() {
        let arc = DestinationCameraFit.smallestLongitudeArc([-10, 0, 20])
        XCTAssertEqual(arc.center, 5, accuracy: 1e-9)
        XCTAssertEqual(arc.span, 30, accuracy: 1e-9)
        let wrapped = DestinationCameraFit.smallestLongitudeArc([170, -170])
        XCTAssertEqual(abs(wrapped.center), 180, accuracy: 1e-9)
        XCTAssertEqual(wrapped.span, 20, accuracy: 1e-9)
        let one = DestinationCameraFit.smallestLongitudeArc([42])
        XCTAssertEqual(one.center, 42)
        XCTAssertEqual(one.span, 0)
    }

    // MARK: - Spoken summary (spec §4.3)

    func testSpokenSummaryNamesTheTopTwoAndTheClassesBesideTheMap() {
        let summary = DestinationMapSummary.spoken(
            ranked: [("United States", 1204), ("Germany", 88), ("Japan", 3)],
            thisMac: 412, localNetwork: 0, unknown: 12,
            locale: Locale(identifier: "en_US")
        )
        XCTAssertEqual(summary, "3 countries. Most requests to United States, 1,204, then Germany, 88. This Mac 412, Unknown 12 are listed beside the map.")
    }

    func testSpokenSummaryWithNothingPlotted() {
        XCTAssertEqual(
            DestinationMapSummary.spoken(ranked: [], thisMac: 0, localNetwork: 0, unknown: 0, locale: Locale(identifier: "en_US")),
            "No destinations plotted."
        )
        XCTAssertEqual(
            DestinationMapSummary.spoken(ranked: [("Germany", 1)], thisMac: 0, localNetwork: 2, unknown: 0, locale: Locale(identifier: "en_US")),
            "1 country. Most requests to Germany, 1. Local Network 2 is listed beside the map."
        )
    }
}
