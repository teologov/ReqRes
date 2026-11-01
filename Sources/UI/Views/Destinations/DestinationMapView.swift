//
//  DestinationMapView.swift
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
//  The world map, on Apple Maps: a SwiftUI `Map` (MapKit, macOS 14) with an
//  `Annotation` per plotted country at GeoKit's centroid, sized by the square
//  root of its share of requests; geodesic `MapPolyline` arcs from the user's
//  approximate origin to the busiest destinations; a `MapPolygon` wash over the
//  countries with traffic at world zoom only (the 1:110m outlines do not match
//  Apple's coastlines up close, so the wash hides below
//  `washMaximumCameraDistance`); MapKit's own zoom stepper plus a Fit button;
//  and — beside the map, never on it — pills for the three destinations that
//  are not places.
//
//  What MapKit does NOT do and this file still does: the country LABELS.
//  MapKit does not collision-avoid custom annotation content, and Western
//  Europe's dots would stack four names on top of each other at world zoom,
//  so `DestinationLabelLayout` still decides which labels show and on which
//  side, in the map's own point space, on every camera change. The points
//  are NOT converted by `MapProxy`: on this OS its conversion is right only
//  for `.global`, and that space is 32pt off SwiftUI's own `.global`
//  (measured 2026-09-25 against `MKMapView.visibleMapRect`). Instead the
//  visible `MKMapRect` from `onMapCameraChange` and plain Mercator
//  arithmetic give the point — the same numbers the map view's own
//  `convert` returns — through `DestinationMapProjection` (MCPKit), which
//  also wraps x by the world's width: a visible rect that spans the 180th
//  meridian (the Pacific fit `DestinationCameraFit` produces for a Mac in
//  Tokyo talking to California) has its far side at x < origin, and an
//  unwrapped offset put every American dot's label a world to the left.
//  The callout is positioned the same way. Nothing here animates.
//
//  Privacy (spec §11, amended): the address lookup is still offline, but the
//  tiles are Apple's — Apple receives the map AREA being viewed, never an
//  address. The tile fetches are made by Apple's `geod` daemon through the
//  system proxy, so `*.ls.apple.com` is excluded from interception by
//  default (Utils `ExcludedHostList.recommended`). The map shows no hostname
//  or URL, so it is safe in a screen share.
//
//  The map is an accessibility CONTAINER with a spoken summary as its value;
//  the list beside it is the navigable surface and carries every value. A
//  container, not one ignored element, because the map now holds controls —
//  MapKit's zoom stepper and the Fit button — that VoiceOver must reach.
//

import GeoKit
import MapKit
import MCPKit
import SwiftUI

struct DestinationMapView: View {
    /// nil in spec §7 state 4 (outlines/centroids failed): the bare Apple
    /// map with no dots, wash or arcs — but the pills, the origin sentence
    /// and the legal corner still render, and the banner above said why.
    let geometry: WorldMapGeometry?
    /// A VALUE from the store's publish — never an observed object.
    let index: DestinationIndex
    let origin: OriginEstimate?
    let selection: TrafficDestination?
    @Binding var hovered: TrafficDestination?
    let onSelect: (TrafficDestination?) -> Void
    let onOpenInTraffic: (TrafficDestination) -> Void
    /// For the Unknown pill's tooltip (spec §6).
    var tableFailure: String? = nil
    /// Spec §7 state 7: `.unavailable` drops "· N apps" from the callout.
    var attribution: ProcessAttributionAvailability = .unreported
    /// The store's `NWPathMonitor` verdict: the strip gains one line.
    var isOffline: Bool = false

    /// Never persisted (spec: nothing about the camera survives the window).
    @State private var camera: MapCameraPosition
    /// MapKit's selection, tagged by `TrafficDestination.token`. Mirrors
    /// `selection` for plotted countries; a pill selection leaves it nil.
    @State private var mapSelection: String?
    /// `MapCamera.distance` when the camera last came to rest (`.onEnd`,
    /// not per frame: it only toggles the wash and the label budget, and the
    /// 41 polygons should leave or return once, not flicker mid-pinch); nil
    /// until the first, which counts as the world view.
    @State private var cameraDistance: Double?
    /// The Mercator extent the map shows, updated continuously while the
    /// camera moves; every label and callout point is derived from it. Nil
    /// until the first camera update, when nothing is labelled yet.
    @State private var visibleRect: MKMapRect?
    /// The map's frame and the pills' frames in this view's named space.
    @State private var mapFrame: CGRect = .zero
    @State private var calloutSize: CGSize = .zero
    @State private var pillFrames: [TrafficDestination: CGRect] = [:]

    private static let coordinateSpace = "destinationMap"

    private static let cornerInset: CGFloat = 12
    private static let labelFont = NSFont.systemFont(ofSize: 10)

    init(
        geometry: WorldMapGeometry?,
        index: DestinationIndex,
        origin: OriginEstimate?,
        selection: TrafficDestination?,
        hovered: Binding<TrafficDestination?>,
        onSelect: @escaping (TrafficDestination?) -> Void,
        onOpenInTraffic: @escaping (TrafficDestination) -> Void,
        tableFailure: String? = nil,
        attribution: ProcessAttributionAvailability = .unreported,
        isOffline: Bool = false
    ) {
        self.geometry = geometry
        self.index = index
        self.origin = origin
        self.selection = selection
        self._hovered = hovered
        self.onSelect = onSelect
        self.onOpenInTraffic = onOpenInTraffic
        self.tableFailure = tableFailure
        self.attribution = attribution
        self.isOffline = isOffline
        let layout = MapLayout(geometry: geometry, index: index, origin: origin)
        _camera = State(initialValue: Self.initialCamera(layout: layout))
        _mapSelection = State(initialValue: layout.dot(for: selection)?.destination.token)
    }

    var body: some View {
        let layout = MapLayout(geometry: geometry, index: index, origin: origin)
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                map(layout: layout)
                    .overlay { labels(layout: layout) }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: MapFrameKey.self, value: geometry.frame(in: .named(Self.coordinateSpace)))
                        }
                    )
                    .padding(.horizontal, Self.cornerInset)
                    .padding(.top, Self.cornerInset)
                bottomBlock
                    .padding(Self.cornerInset)
            }
            callout(layout: layout)
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(MapFrameKey.self) { mapFrame = $0 }
        .onPreferenceChange(PillFramesKey.self) { pillFrames = $0 }
        .onPreferenceChange(CalloutSizeKey.self) { calloutSize = $0 }
        .onChange(of: mapSelection) { _, token in
            let destination = token.flatMap(TrafficDestination.parseToken)
            guard destination != selection else { return }
            // nil from the map is a click on water: it deselects a dot, but a
            // pill's selection was never MapKit's to clear.
            if destination == nil && selection?.isoCode == nil { return }
            onSelect(destination)
        }
        .onChange(of: selection) { _, current in
            let token = layout.dot(for: current)?.destination.token
            if mapSelection != token { mapSelection = token }
        }
        // The first destinations to arrive after an empty map are framed;
        // afterwards the camera is the user's until Fit (spec §4: nothing
        // yanks the view out from under a zoom).
        .onChange(of: layout.dots.count) { previous, count in
            if previous == 0 && count > 0 { camera = Self.fitCamera(layout: layout) }
        }
    }

    // MARK: - The map

    private func map(layout: MapLayout) -> some View {
        Map(position: $camera, interactionModes: [.pan, .zoom], selection: $mapSelection) {
            if DestinationMapScale.washIsVisible(cameraDistance: cameraDistance) {
                ForEach(layout.washes) { wash in
                    // Fill only, no outline: an outline is what shows the
                    // 1:110m ring sitting a few points off Apple's coastline
                    // (Florida, Hudson Bay — looked at, 2026-09-25); a soft
                    // tint edge does not read as a wrong border.
                    ForEach(Array(wash.polygons.enumerated()), id: \.offset) { _, polygon in
                        MapPolygon(polygon)
                            .foregroundStyle(Color.accentColor.opacity(highlighted.contains(wash.destination)
                                ? DestinationMapScale.washHighlightedOpacity
                                : DestinationMapScale.washOpacity))
                    }
                }
            }
            if let originCoordinate = layout.originCoordinate {
                ForEach(layout.arcs) { dot in
                    let isHighlighted = highlighted.contains(dot.destination)
                    MapPolyline(coordinates: [originCoordinate, dot.coordinate], contourStyle: .geodesic)
                        .stroke(Color.accentColor.opacity(isHighlighted ? 0.8 : 0.3), lineWidth: isHighlighted ? 1.5 : 1)
                }
                Annotation(coordinate: originCoordinate) {
                    originMarker
                } label: {
                    EmptyView()
                }
                .annotationTitles(.hidden)
            }
            // Largest first so the small dots stay on top.
            ForEach(layout.dots.sorted { $0.radius > $1.radius }) { dot in
                Annotation(coordinate: dot.coordinate) {
                    dotView(dot)
                } label: {
                    EmptyView()
                }
                .tag(dot.destination.token)
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            // No compass: rotation is off (`interactionModes`), so it would
            // never appear.
            MapZoomStepper()
        }
        // The visible rect every frame — the labels and callout follow the
        // map as it moves; the distance only once the camera rests.
        .onMapCameraChange(frequency: .continuous) { context in
            visibleRect = context.rect
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            cameraDistance = context.camera.distance
        }
        // A container (not `.ignore`): the stepper inside the map and the
        // Fit button over it must stay reachable to VoiceOver, and the Fit
        // overlay is applied AFTER this so it is never folded into the map.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("World map of destinations")
        .accessibilityValue(summary)
        .overlay(alignment: .topLeading) {
            fitButton(layout: layout)
                .padding(8)
        }
    }

    /// The dot: accent, sized by share, a window-background ring, the
    /// selected halo — inside a hit target of at least 24pt (spec §4.3).
    ///
    /// Two limits accepted with MapKit: the `contentShape(Circle())` is
    /// SwiftUI's hit shape inside the annotation, while MapKit selects on the
    /// annotation view's FRAME, so the target is really the square; and the
    /// "largest first" content order below is what keeps a small dot inside a
    /// large one's frame (Singapore in Malaysia) on top — content order is
    /// not documented as z-order, and no probe pins it.
    ///
    /// Click-to-select is NOT verifiable headlessly (`REQRES_UI_PROBE_CLICK`,
    /// 2026-09-25): MapKit selects through `NSClickGestureRecognizer`s on
    /// the map view, and a synthesized mouse event — `window.sendEvent` or
    /// `NSApp.postEvent`, with or without these SwiftUI gestures — never
    /// fires them. What IS proven: MapKit's `selectAnnotation` reaches the
    /// binding, the store and the rendered selected state. The reason to
    /// expect the real click to work: AppKit runs an ancestor's gesture
    /// recognisers BEFORE the hit view's `mouseDown`, so nothing this hosted
    /// content does with the event can starve the map's recognisers. A
    /// physical click is the confirmation.
    private func dotView(_ dot: Dot) -> some View {
        let isSelected = dot.destination == selection
        let hit = DestinationMapScale.hitRadius(dotRadius: dot.radius)
        return ZStack {
            if isSelected {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: (dot.radius + 4) * 2, height: (dot.radius + 4) * 2)
            }
            Circle()
                .fill(Color.accentColor.opacity(isSelected ? 1 : 0.9))
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                .frame(width: dot.radius * 2, height: dot.radius * 2)
        }
        .frame(width: hit * 2, height: hit * 2)
        .contentShape(Circle())
        .onHover { inside in
            if inside { hovered = dot.destination } else if hovered == dot.destination { hovered = nil }
        }
        // Double-click opens the traffic list; the single click is MapKit's
        // selection (`Map(selection:)`), which also gives "a dot wins over
        // the wash under it" for free — polygons are not selectable here.
        .onTapGesture(count: 2) { onOpenInTraffic(dot.destination) }
        .accessibilityHidden(true)
    }

    /// Dashed, secondary, under the dots, with a window-background halo so
    /// it reads on a country's wash (spec §4.3).
    private var originMarker: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
                .frame(width: 18, height: 18)
            Circle()
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(width: 14, height: 14)
            Circle()
                .fill(Color.secondary)
                .frame(width: 4, height: 4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Our own, beside MapKit's stepper: the region that encloses every dot
    /// and the origin, or the world when there is nothing to plot.
    private func fitButton(layout: MapLayout) -> some View {
        Button {
            camera = Self.fitCamera(layout: layout)
        } label: {
            Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Fit the map to every destination")
        .accessibilityLabel("Fit to destinations")
    }

    /// Land, selected OR hovered (spec §4.3): hovering another country must
    /// not drop the selection's wash and arc.
    private var highlighted: Set<TrafficDestination> {
        Set([hovered, selection].compactMap { $0 })
    }

    // MARK: - Camera

    /// Every dot and the origin; the WORLD when there is no dot — the
    /// origin alone is not worth zooming onto (everything Unknown, or
    /// capture just started, would otherwise open on the user's own
    /// country with nothing on it).
    private static func fitRegion(layout: MapLayout) -> DestinationMapRegion {
        guard !layout.dots.isEmpty else { return DestinationCameraFit.world }
        var points = layout.dots.map { (latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        if let origin = layout.originCoordinate {
            points.append((latitude: origin.latitude, longitude: origin.longitude))
        }
        return DestinationCameraFit.region(framing: points)
    }

    /// Known limit, measured 2026-09-25: MapKit will not zoom out past
    /// ~16,700 km, which at the 555pt default map is exactly 180° of
    /// longitude — asked as a region OR as a map rect (both were tried). A
    /// Tokyo→Germany fit (325° by the smallest arc) therefore opens on the
    /// Pacific with the Americas framed and both the origin and Germany off
    /// the map until the user widens the window or pans; the wrap-safe
    /// projection is what keeps the Americas' labels on it.
    private static func fitCamera(layout: MapLayout) -> MapCameraPosition {
        let region = fitRegion(layout: layout)
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.centerLatitude, longitude: region.centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta)
        ))
    }

    /// The fit, or — DEBUG only — `REQRES_UI_PROBE_ZOOM=DE`: a camera on
    /// that centroid spanning `REQRES_UI_PROBE_SPAN` degrees (default 8, a
    /// country), so the zoomed-in state can be looked at headlessly (the
    /// wash must be hidden there, and visible at a continent's span).
    private static func initialCamera(layout: MapLayout) -> MapCameraPosition {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let code = environment["REQRES_UI_PROBE_ZOOM"],
           let coordinate = layout.geometry?.centroid(forISO: code) {
            let span = environment["REQRES_UI_PROBE_SPAN"].flatMap(Double.init) ?? 8
            return .region(MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span * 1.25)))
        }
        #endif
        return fitCamera(layout: layout)
    }

    // MARK: - Layout (computed per body: ≤ 1 Hz publish, selection, hover, camera)

    fileprivate struct Dot: Identifiable {
        let destination: TrafficDestination
        let entry: DestinationEntry
        let coordinate: CLLocationCoordinate2D
        let radius: CGFloat
        var id: String { destination.token }
    }

    fileprivate struct Wash: Identifiable {
        let destination: TrafficDestination
        let polygons: [MKPolygon]
        var id: String { destination.token }
    }

    fileprivate struct MapLayout {
        let geometry: WorldMapGeometry?
        /// Every plotted country, busiest first.
        let dots: [Dot]
        /// The outlines of the plotted countries that have one.
        let washes: [Wash]
        /// The user's approximate position, when the zone names a country the
        /// centroid table has.
        let originCoordinate: CLLocationCoordinate2D?
        /// The busiest `maxArcs` dots whose centroid is not the origin's.
        let arcs: [Dot]

        init(geometry: WorldMapGeometry?, index: DestinationIndex, origin: OriginEstimate?) {
            self.geometry = geometry
            let maxRequests = index.maxCountryRequests
            var dots: [Dot] = []
            var washes: [Wash] = []
            if let geometry {
                for entry in index.plottable {
                    guard let iso = entry.destination.isoCode,
                          let coordinate = geometry.centroid(forISO: iso) else { continue }
                    dots.append(Dot(
                        destination: entry.destination,
                        entry: entry,
                        coordinate: coordinate,
                        radius: DestinationMapScale.dotRadius(requests: entry.requests, maxRequests: maxRequests)
                    ))
                    if let feature = geometry.feature(forISO: iso) {
                        washes.append(Wash(destination: entry.destination, polygons: feature.polygons))
                    }
                }
            }
            self.dots = dots
            self.washes = washes
            originCoordinate = origin.flatMap { geometry?.centroid(forISO: $0.isoCode) }
            if let originCode = origin?.isoCode, originCoordinate != nil {
                arcs = Array(dots.filter { $0.destination.isoCode != originCode }.prefix(DestinationMapScale.maxArcs))
            } else {
                arcs = []
            }
        }

        func dot(for destination: TrafficDestination?) -> Dot? {
            guard let destination else { return nil }
            return dots.first { $0.destination == destination }
        }
    }

    // MARK: - Labels (the map's point space, on every camera change)

    /// Where a coordinate is on the map, in the map's own points: the
    /// visible Mercator rect scaled to the map's size — exactly what
    /// `MKMapView.convert(_:toPointTo:)` returns (measured), x wrapped by
    /// the world's width for a rect that spans the antimeridian
    /// (`DestinationMapProjection`, tested). Nil before the first camera
    /// update.
    private func mapPoint(_ coordinate: CLLocationCoordinate2D) -> CGPoint? {
        guard let visibleRect, mapFrame.width > 0, mapFrame.height > 0 else { return nil }
        let point = MKMapPoint(coordinate)
        guard let unit = DestinationMapProjection.unitPoint(
            x: point.x, y: point.y,
            visibleOriginX: visibleRect.origin.x, visibleOriginY: visibleRect.origin.y,
            visibleWidth: visibleRect.size.width, visibleHeight: visibleRect.size.height,
            worldWidth: MKMapSize.world.width
        ) else { return nil }
        return CGPoint(x: unit.x * mapFrame.width, y: unit.y * mapFrame.height)
    }

    /// Labels: a budget in rank order, the selected and hovered first. Each
    /// has four sides (right, left, below, above) and takes the first that
    /// touches no dot and no placed label; a quiet country with no free side
    /// is dropped — the callout and the list carry it — but the busiest, the
    /// selected and the hovered are never dropped. The origin's label goes
    /// last, on a free side, over a backdrop. An overlay on the map, so a dot
    /// panned off the map has no label and the map's clip is the labels'.
    @ViewBuilder
    private func labels(layout: MapLayout) -> some View {
        let placed = labelPlacements(layout: layout)
        ZStack(alignment: .topLeading) {
            ForEach(placed.countries, id: \.id) { placement in
                Text(placement.text)
                    .font(.system(size: 10))
                    .foregroundStyle(placement.isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(0.9), radius: 1.5)
                    .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(0.9), radius: 1.5)
                    .fixedSize()
                    .offset(x: placement.rect.minX, y: placement.rect.minY)
            }
            if let originRect = placed.origin {
                Text("You · approximate")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 3))
                    .offset(x: originRect.minX - 4, y: originRect.minY - 1.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct LabelPlacement {
        let id: String
        let text: String
        let rect: CGRect
        let isSelected: Bool
    }

    private struct Placements {
        var countries: [LabelPlacement] = []
        var origin: CGRect?
    }

    private func labelPlacements(layout: MapLayout) -> Placements {
        guard mapFrame.width > 0, mapFrame.height > 0 else { return Placements() }
        let bounds = CGRect(origin: .zero, size: mapFrame.size)
        let canvas = bounds.insetBy(dx: 2, dy: 2)
        // Country names only at the world's and a continent's scale: closer
        // in, Apple's own country labels are on the tiles and ours sat on
        // top of "GERMANY" (looked at, 2026-09-25). The dots are still
        // theirs to hover, and the origin's label has no Apple equivalent.
        let budget = DestinationMapScale.washIsVisible(cameraDistance: cameraDistance)
            ? DestinationMapScale.labelBudget(mapWidth: mapFrame.width)
            : 0

        var dotRects: [CGRect] = []
        var candidates: [DestinationLabelLayout.Candidate] = []
        var texts: [String: (text: String, isSelected: Bool)] = [:]
        for dot in layout.dots {
            guard let iso = dot.destination.isoCode,
                  let center = mapPoint(dot.coordinate),
                  bounds.insetBy(dx: -dot.radius, dy: -dot.radius).contains(center) else { continue }
            dotRects.append(CGRect(x: center.x - dot.radius, y: center.y - dot.radius, width: dot.radius * 2, height: dot.radius * 2))
            let name = CountryPresentation.name(for: iso)
            let size = Self.measure(name)
            texts[iso] = (name, dot.destination == selection)
            candidates.append(.init(id: iso, rects: Self.labelSides(around: center, clearance: dot.radius + 4, size: size, within: canvas)))
        }
        var priority = Set<String>()
        if let code = selection?.isoCode { priority.insert(code) }
        if let code = hovered?.isoCode { priority.insert(code) }
        var placements = Placements()
        let placed = DestinationLabelLayout.placements(ranked: candidates, budget: budget, priority: priority, reserved: dotRects)
        for placement in placed {
            guard let text = texts[placement.id] else { continue }
            placements.countries.append(LabelPlacement(id: placement.id, text: text.text, rect: placement.rect, isSelected: text.isSelected))
        }

        if let originCoordinate = layout.originCoordinate,
           let originPoint = mapPoint(originCoordinate),
           bounds.contains(originPoint) {
            let size = Self.measure("You · approximate")
            let sides = Self.labelSides(around: originPoint, clearance: 11, size: size, within: canvas, diagonals: true)
            // The callout counts as taken too (Germany selected, from
            // Amsterdam); its rect is in the named space, the labels' in the
            // map's.
            let callout = calloutRect(layout: layout).map { $0.offsetBy(dx: -mapFrame.minX, dy: -mapFrame.minY) }
            let occupied = dotRects + placed.map(\.rect) + (callout.map { [$0] } ?? [])
            placements.origin = DestinationLabelLayout.freeRect(sides, avoiding: occupied)
        }
        return placements
    }

    /// Label sizes, measured once per string: `labelPlacements` runs on
    /// every body evaluation, which is every frame of a pan while the
    /// visible rect updates continuously, and `NSAttributedString.size()`
    /// per dot per frame was the one unbounded cost in it. The font is fixed
    /// (10pt system) and the names are a few hundred at most, so the cache
    /// never needs clearing. Main-actor only, like `body`.
    @MainActor private static var labelSizes: [String: CGSize] = [:]

    @MainActor
    private static func measure(_ text: String) -> CGSize {
        if let cached = labelSizes[text] { return cached }
        let measured = NSAttributedString(string: text, attributes: [.font: labelFont]).size()
        let size = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        labelSizes[text] = size
        return size
    }

    /// A label's possible rects around a point — right, left, below, above,
    /// in that order of preference, then (for the origin, whose label may sit
    /// anywhere near its marker) the four diagonals — minus the ones that
    /// leave the map. The preferred side is kept if every side would.
    private static func labelSides(around center: CGPoint, clearance: CGFloat, size: CGSize, within bounds: CGRect, diagonals: Bool = false) -> [CGRect] {
        var sides = [
            CGRect(x: center.x + clearance, y: center.y - size.height / 2, width: size.width, height: size.height),
            CGRect(x: center.x - clearance - size.width, y: center.y - size.height / 2, width: size.width, height: size.height),
            CGRect(x: center.x - size.width / 2, y: center.y + clearance - 1, width: size.width, height: size.height),
            CGRect(x: center.x - size.width / 2, y: center.y - clearance + 1 - size.height, width: size.width, height: size.height),
        ]
        if diagonals {
            let d = clearance * 0.75
            sides += [
                CGRect(x: center.x + d, y: center.y + d, width: size.width, height: size.height),
                CGRect(x: center.x - d - size.width, y: center.y + d, width: size.width, height: size.height),
                CGRect(x: center.x + d, y: center.y - d - size.height, width: size.width, height: size.height),
                CGRect(x: center.x - d - size.width, y: center.y - d - size.height, width: size.width, height: size.height),
            ]
        }
        let inside = sides.filter { bounds.contains($0) }
        return inside.isEmpty ? [sides[0]] : inside
    }

    // MARK: - Callout (hover wins over selection; one at a time), in the named space

    @ViewBuilder
    private func callout(layout: MapLayout) -> some View {
        if let destination = hovered ?? selection, let entry = index.entries[destination],
           let anchor = calloutAnchor(for: destination, layout: layout) {
            calloutContent(for: destination, entry: entry)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: CalloutSizeKey.self, value: proxy.size)
                    }
                )
                .position(calloutCenter(anchor: anchor))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The callout's rect, once it has measured itself — for the origin
    /// label to keep clear of.
    private func calloutRect(layout: MapLayout) -> CGRect? {
        guard calloutSize.width > 1, calloutSize.height > 1,
              let destination = hovered ?? selection, index.entries[destination] != nil,
              let anchor = calloutAnchor(for: destination, layout: layout) else { return nil }
        let center = calloutCenter(anchor: anchor)
        return CGRect(x: center.x - calloutSize.width / 2, y: center.y - calloutSize.height / 2, width: calloutSize.width, height: calloutSize.height)
    }

    /// Where the callout points: a dot's top edge (only while the dot is on
    /// the map), or a pill's top edge.
    private func calloutAnchor(for destination: TrafficDestination, layout: MapLayout) -> (point: CGPoint, clearance: CGFloat)? {
        if let dot = layout.dot(for: destination) {
            guard let local = mapPoint(dot.coordinate), CGRect(origin: .zero, size: mapFrame.size).contains(local) else { return nil }
            return (CGPoint(x: mapFrame.minX + local.x, y: mapFrame.minY + local.y), dot.radius)
        }
        if let pill = pillFrames[destination] {
            return (CGPoint(x: pill.midX, y: pill.minY), 0)
        }
        return nil
    }

    /// Bottom-centre 8pt above the anchor, clamped inside the map frame;
    /// flipped below when there is no room above.
    private func calloutCenter(anchor: (point: CGPoint, clearance: CGFloat)) -> CGPoint {
        let width = max(calloutSize.width, 1)
        let height = max(calloutSize.height, 1)
        let bounds = mapFrame.insetBy(dx: 4, dy: 4)
        let x = min(max(anchor.point.x, bounds.minX + width / 2), bounds.maxX - width / 2)
        var top = anchor.point.y - anchor.clearance - 8 - height
        if top < bounds.minY { top = anchor.point.y + anchor.clearance + 8 }
        return CGPoint(x: x, y: top + height / 2)
    }

    private func calloutContent(for destination: TrafficDestination, entry: DestinationEntry) -> some View {
        let code = destination.isoCode ?? ""
        let flag = code.isEmpty ? "" : CountryPresentation.flag(for: code)
        let title = CountryPresentation.title(for: destination)
        var parts = [
            CountryPresentation.plural(entry.requests, "request"),
            CountryPresentation.plural(entry.hostCount, "host"),
        ]
        if attribution != .unavailable {
            parts.append(CountryPresentation.plural(entry.appCount, "app"))
        }
        parts.append(DestinationCopy.bytes(entry.bytes))
        return VStack(alignment: .leading, spacing: 2) {
            Text(flag.isEmpty ? title : "\(flag) \(title)")
                .font(.system(size: 11, weight: .medium))
            Text(parts.joined(separator: " · "))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .fixedSize()
    }

    // MARK: - The bottom band: the off-map strip over the legal line

    /// The three classes with any requests, in the strip's order.
    private var pillDestinations: [TrafficDestination] {
        [TrafficDestination.thisMac, .localNetwork, .unknown].filter { (index.entries[$0]?.requests ?? 0) > 0 }
    }

    /// Whether the strip has anything to show: a class pill, the sentence
    /// for a time zone that names no country, or the offline line.
    private var hasStrip: Bool {
        origin == nil || isOffline || !pillDestinations.isEmpty
    }

    private var bottomBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasStrip {
                offMapStrip
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                legalCorner
            }
        }
    }

    // MARK: - Off-map strip: the three destinations that are not places

    /// The sentences come FIRST, each on its own line — the origin one
    /// shared the pill row once and truncated to "GMT…" at 660pt, which is
    /// the one word it exists to show.
    private var offMapStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            if origin == nil {
                Text(DestinationCopy.originUnknown(timeZone: TimeZone.current.identifier))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isOffline {
                Text(DestinationCopy.mapTilesOffline)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !pillDestinations.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pillDestinations, id: \.self) { destination in
                        if let entry = index.entries[destination] {
                            pill(for: destination, entry: entry)
                        }
                    }
                }
            }
        }
    }

    /// The breakpoint queue's pill: TinyShield's "Local Network" put where a
    /// thing without a place belongs — beside the map, never over the Pacific.
    private func pill(for destination: TrafficDestination, entry: DestinationEntry) -> some View {
        let isSelected = selection == destination
        return Button {
            onSelect(destination)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: CountryPresentation.symbolName(for: destination) ?? "questionmark")
                    .font(.system(size: 10))
                Text(CountryPresentation.title(for: destination))
                    .font(.system(size: 10, weight: .medium))
                Text(CountryPresentation.groupedDigits(entry.requests))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpenInTraffic(destination) })
        .onHover { inside in
            if inside { hovered = destination } else if hovered == destination { hovered = nil }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PillFramesKey.self, value: [destination: proxy.frame(in: .named(Self.coordinateSpace))])
            }
        )
        .help(DestinationCopy.classDescription(destination, tableFailure: tableFailure) ?? "")
        .accessibilityLabel(CountryPresentation.title(for: destination))
        .accessibilityValue(CountryPresentation.plural(entry.requests, "request"))
    }

    // MARK: - Legal corner (DB-IP's CC BY 4.0 requires the credit where the data is used)

    /// Under the map, never over it: MapKit draws Apple's own legal link in
    /// the map's corner and both must stay readable.
    private var legalCorner: some View {
        HStack(spacing: 4) {
            Link("IP Geolocation by DB-IP", destination: URL(string: "https://db-ip.com")!)
                .underline()
            Text("·")
            // CC BY 4.0 asks for a modification to be indicated: the table
            // is a converted, compacted form of DB-IP's CSV.
            Text("CC BY 4.0, converted")
            Text("·")
            Text("Natural Earth")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .tint(.secondary)
        .help("\(geometry?.attribution ?? GeoKit.attribution) The IP table is bundled in a converted, compact form of DB-IP's monthly CSV. The map tiles are Apple Maps; \(DestinationCopy.mapPrivacy)")
    }

    // MARK: - Accessibility

    private var summary: String {
        DestinationMapSummary.spoken(
            ranked: index.plottable.map { (CountryPresentation.name(for: $0.destination.isoCode ?? ""), $0.requests) },
            thisMac: index.entries[.thisMac]?.requests ?? 0,
            localNetwork: index.entries[.localNetwork]?.requests ?? 0,
            unknown: index.entries[.unknown]?.requests ?? 0
        )
    }
}

// MARK: - Preferences

private struct MapFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct PillFramesKey: PreferenceKey {
    static var defaultValue: [TrafficDestination: CGRect] = [:]
    static func reduce(value: inout [TrafficDestination: CGRect], nextValue: () -> [TrafficDestination: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct CalloutSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
