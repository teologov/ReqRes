//
//  DestinationsWindowController.swift
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
//  The Destinations window (destination-map UX spec §2.2), built exactly
//  like SavedSessionsWindowController: an AppKit NSWindow around an
//  NSHostingView rather than a SwiftUI `Window` scene (this app's forms are
//  sheets, never `Window` scenes). An ordinary activating,
//  closable, resizable window that remembers where it was left.
//
//  What differs from the saved controller is the store's lifecycle: the
//  window is the only thing that reads `DestinationsStore`, so the store
//  publishes only while this window is open — activated BEFORE the window
//  is shown (the first frame must be current) and deactivated by the window
//  delegate when it closes.
//

import AppKit
import MCPKit
import SwiftUI

@MainActor
final class DestinationsWindowController: NSObject, NSWindowDelegate {
    static let shared = DestinationsWindowController()

    private var window: NSWindow?

    private override init() {}

    /// The one entry point for every caller (the Window menu, the toolbar
    /// button, the traffic row's context item). Built lazily: most launches
    /// never open this window.
    func show() {
        let window = self.window ?? makeWindow()
        let store = DestinationsStore.shared
        // Before ordering front: the store publishes the whole index on
        // activation, so the first frame is current rather than empty.
        store.setActive(true)
        // The map opens on what the table is already filtered to — one
        // `country:` chip — unless the window already has a selection.
        if store.currentSelection == nil {
            let countries = TrafficSearchState.shared.filter.countries
            if countries.count == 1, let destination = TrafficDestination.parseToken(countries[0]) {
                store.requestSelection(destination)
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the window with `destination` selected — the traffic row's
    /// "Show Destination on Map", Unknown included (the window then opens on
    /// the Unknown pill with its hosts in the breakdown: the answer to "why
    /// is this unplaceable").
    func show(selecting destination: TrafficDestination) {
        show()
        DestinationsStore.shared.requestSelection(destination)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        DestinationsStore.shared.setActive(false)
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingView(rootView: DestinationsWindow())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Destinations"
        window.contentView = hosting
        // List 280 + divider + map pane 520 (spec §3.4's arithmetic); the
        // height fits header 36 + map 200 + divider + breakdown 148 under
        // the title bar.
        window.minSize = NSSize(width: 860, height: 440)
        // Not released on close: `show()` reuses this instance, so the
        // selection, the filter text and the split position survive being
        // closed and reopened within a session.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        // Restores the saved frame if there is one; otherwise keeps the
        // centred frame set above.
        window.setFrameAutosaveName("ReqResDestinationsWindow")
        self.window = window
        return window
    }
}

#if DEBUG
import MapKit
import XReqResCore

// MARK: - Probe capture
//
// The map is a MapKit view drawn by Metal, which `cacheDisplay` does not
// rasterise (it shows the tile placeholder grid and none of the annotations
// or overlays), and every window-level capture on this OS needs a Screen
// Recording grant a headless run must not prompt for. So the probe assembles
// what CAN be shown, and says so: the real `MKMapView`'s content as a text
// dump (annotations, overlays, selection, camera, controls, annotation-view
// frames), an `MKMapSnapshotter` render of the same region, size, style and
// appearance with the map view's REAL overlays drawn through the same
// projection and each REAL annotation view rasterised at its coordinate, and
// the SwiftUI layer (labels, callout, strip, Fit) from `cacheDisplay` keyed
// over it. The composite is a faithful picture of geometry and appearance;
// the only thing it cannot prove is that MapKit's own overlay renderer draws
// the wash and arcs in the live window — the dump's overlay list is the
// evidence for that.
extension DestinationsProbe {
    /// Prints the dump and returns the composite, or nil when no map view is
    /// in the tree (spec §7 state 1, the placeholder).
    @MainActor
    static func capture(hosting: NSView, appearance: NSAppearance) async -> Data? {
        guard let mapView = firstMapView(in: hosting) else {
            print("[probe] map: no MKMapView in the view tree")
            return nil
        }
        // The SwiftUI layer is cached with the map view HIDDEN: asked to
        // draw offscreen a second time, MKMapView rasterises its tile layer
        // at 2x and unclipped (measured), which no keying can remove. Hidden,
        // its rect is the flat window colour; the labels, callout and Fit
        // button are SwiftUI siblings, not its subviews, so they still draw.
        mapView.isHidden = true
        hosting.displayIfNeeded()
        guard let cached = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: cached)
        mapView.isHidden = false
        let mapRect = mapView.convert(mapView.bounds, to: hosting)
        let annotations = mapView.annotations
        let overlays = mapView.overlays
        let camera = mapView.camera
        print("[probe] map: frame=\(mapRect.integral) camera distance=\(Int(camera.centerCoordinateDistance))m center=\(camera.centerCoordinate.latitude),\(camera.centerCoordinate.longitude) span=\(mapView.region.span.latitudeDelta)x\(mapView.region.span.longitudeDelta)")
        print("[probe] map: \(annotations.count) annotations, \(overlays.count) overlays (\(Dictionary(grouping: overlays) { String(describing: type(of: $0)) }.map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", "))), selected=\(mapView.selectedAnnotations.count)")
        let visible = mapView.visibleMapRect
        for annotation in annotations {
            let view = mapView.view(for: annotation)
            let point = mapView.convert(annotation.coordinate, toPointTo: hosting)
            // Ground truth: the exact Mercator extent the live view shows,
            // through the view's own projection (wrapped at the antimeridian
            // — a Pacific fit has its far side at x < the rect's origin).
            let unit = Self.project(annotation.coordinate, in: visible)
            let truth = CGPoint(x: mapRect.minX + unit.x * mapRect.width, y: mapRect.minY + unit.y * mapRect.height)
            // Off the map, the two may name different copies of the world
            // (MapKit the nearest, the view's wrap the one east of the
            // rect's origin); on the map they must be equal.
            let onMap = (0...1).contains(unit.x) && (0...1).contains(unit.y)
            print("[probe] map annotation: \(annotation.coordinate.latitude),\(annotation.coordinate.longitude) convert=\(Int(point.x)),\(Int(point.y)) visibleMapRect=\(Int(truth.x)),\(Int(truth.y)) onMap=\(onMap) size=\(view.map { "\(Int($0.bounds.width))" } ?? "none") selected=\(view?.isSelected ?? false)")
        }
        print("[probe] map: visibleMapRect \(visible) aspect=\(visible.width / visible.height) frame aspect=\(mapRect.width / mapRect.height)")
        let controls = mapView.subviews.filter { !($0 is MKAnnotationView) && $0.frame.width < 200 && $0.frame.height < 200 }
        print("[probe] map controls: \(controls.map { "\(type(of: $0)) \($0.convert($0.bounds, to: hosting).integral)" }.joined(separator: "; "))")

        let options = MKMapSnapshotter.Options()
        // The live view's exact Mercator extent, not its region or camera:
        // both are refitted by the snapshotter and land the tiles 30–90pt
        // off the live framing (measured). The frame's aspect equals the
        // rect's, so this reproduces the view.
        options.mapRect = visible
        options.size = mapView.bounds.size
        options.mapType = mapView.mapType
        options.pointOfInterestFilter = mapView.pointOfInterestFilter
        options.showsBuildings = false
        options.appearance = appearance
        // Twice: the first snapshot on a cold cache returns with Apple's
        // low-resolution fallback where a vector tile has not arrived; the
        // second, a moment later, has the tiles the map view just fetched.
        var snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await MKMapSnapshotter(options: options).start()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            snapshot = try await MKMapSnapshotter(options: options).start()
        } catch {
            print("[probe] map: snapshot failed: \(error)")
            return nil
        }
        print("[probe] map: snapshot \(snapshot.image.size) reps=\(snapshot.image.representations.map { "\(type(of: $0)) \($0.pixelsWide)x\($0.pixelsHigh) size=\($0.size)" })")
        if ProcessInfo.processInfo.environment["REQRES_UI_PROBE_LAYERS"] != nil,
           let tiff = snapshot.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            print("<<<PNG snapshot-raw\n\(png.base64EncodedString())\nPNG>>>")
        }

        // What the view hands MapKit, drawn from the same store values the
        // view reads: the washes are `MapPolygon`s (a private overlay class
        // on the map view, so their coordinates are taken from the geometry
        // directly), the dots are `Annotation`s whose hosted content does
        // not rasterise; both are drawn here with the view's own numbers.
        let store = DestinationsStore.shared
        let index = store.index
        let maxRequests = index.maxCountryRequests
        let selected = store.currentSelection
        let hovered: TrafficDestination? = nil

        // One CGContext, bottom-left origin, 2x: the tiles, then the wash and
        // dots from the store, the real polylines through the snapshot's
        // projection, the map's control subviews (MapKit's zoom stepper),
        // and the keyed SwiftUI layer on top. Every point-space coordinate
        // (the projection, view frames) is flipped once, here.
        let scale: CGFloat = 2
        let size = hosting.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        func cg(_ point: CGPoint) -> CGPoint { CGPoint(x: mapRect.minX + point.x, y: size.height - (mapRect.minY + point.y)) }
        // The live view's projection (verified equal to `convert`), so the
        // composite's dots sit where the window's do and the labels' offsets
        // are a real check.
        func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            let unit = Self.project(coordinate, in: visible)
            return CGPoint(x: unit.x * mapRect.width, y: unit.y * mapRect.height)
        }
        func cgRect(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height) }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        // The snapshot's NSImage carries more than one representation on
        // this OS; the largest bitmap is the one with the tiles at 2x.
        let tileRep = snapshot.image.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        if let tiles = (tileRep as? NSBitmapImageRep)?.cgImage ?? tileRep?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            print("[probe] map: drawing tiles \(tiles.width)x\(tiles.height) into \(cgRect(mapRect))")
            if ProcessInfo.processInfo.environment["REQRES_UI_PROBE_LAYERS"] != nil,
               let png = NSBitmapImageRep(cgImage: tiles).representation(using: .png, properties: [:]) {
                print("<<<PNG tiles-cg\n\(png.base64EncodedString())\nPNG>>>")
            }
            context.saveGState()
            context.clip(to: cgRect(mapRect))
            context.draw(tiles, in: cgRect(mapRect))
            context.restoreGState()
            stage("after-tiles")
        }
        func stage(_ name: String) {
            guard ProcessInfo.processInfo.environment["REQRES_UI_PROBE_LAYERS"] != nil,
                  let image = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            print("<<<PNG stage-\(name)\n\(png.base64EncodedString())\nPNG>>>")
        }
        let accent = NSColor.controlAccentColor
        // Everything from here to the controls stays inside the map: a ring
        // that leaves the snapshot's region (Alaska, the Canadian Arctic)
        // projects to points far outside it.
        context.saveGState()
        context.clip(to: cgRect(mapRect))
        if DestinationMapScale.washIsVisible(cameraDistance: camera.centerCoordinateDistance), let geometry = store.geometry {
            for entry in index.plottable {
                guard let iso = entry.destination.isoCode, let feature = geometry.feature(forISO: iso) else { continue }
                let path = CGMutablePath()
                for polygon in feature.polygons {
                    Self.append(polygon, to: path, project: { cg(project($0)) })
                    for hole in polygon.interiorPolygons ?? [] { Self.append(hole, to: path, project: { cg(project($0)) }) }
                }
                let isHighlighted = entry.destination == selected || entry.destination == hovered
                context.addPath(path)
                context.setFillColor(accent.withAlphaComponent(isHighlighted ? DestinationMapScale.washHighlightedOpacity : DestinationMapScale.washOpacity).cgColor)
                context.fillPath(using: .evenOdd)
            }
        }
        for overlay in overlays {
            guard let line = overlay as? MKPolyline else { continue }
            let path = CGMutablePath()
            Self.append(line, to: path, project: { cg(project($0)) })
            context.addPath(path)
            context.setStrokeColor(accent.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
        for annotation in annotations {
            guard let view = mapView.view(for: annotation) else { continue }
            let point = cg(project(annotation.coordinate))
            let viewSize = view.bounds.size
            let frame = CGRect(x: point.x - viewSize.width / 2, y: point.y - viewSize.height / 2, width: viewSize.width, height: viewSize.height)
            if let rendered = Self.render(view) {
                context.draw(rendered, in: frame)
                continue
            }
            // Not rasterisable: the view's own numbers. 18pt is the origin.
            if viewSize.width <= 18 {
                context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor)
                context.fillEllipse(in: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
                context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
                context.setLineDash(phase: 0, lengths: [3, 2])
                context.setLineWidth(1)
                context.strokeEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
                context.setLineDash(phase: 0, lengths: [])
                context.setFillColor(NSColor.secondaryLabelColor.cgColor)
                context.fillEllipse(in: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
            } else {
                let entry = index.plottable.first { entry in
                    guard let iso = entry.destination.isoCode, let c = store.geometry?.centroid(forISO: iso) else { return false }
                    return abs(c.latitude - annotation.coordinate.latitude) < 1e-6 && abs(c.longitude - annotation.coordinate.longitude) < 1e-6
                }
                let radius = entry.map { DestinationMapScale.dotRadius(requests: $0.requests, maxRequests: maxRequests) } ?? 3
                let isSelected = entry?.destination == selected
                if isSelected {
                    context.setFillColor(accent.withAlphaComponent(0.25).cgColor)
                    context.fillEllipse(in: CGRect(x: point.x - radius - 4, y: point.y - radius - 4, width: (radius + 4) * 2, height: (radius + 4) * 2))
                }
                let dot = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.setFillColor(accent.withAlphaComponent(isSelected ? 1 : 0.9).cgColor)
                context.fillEllipse(in: dot)
                context.setStrokeColor(NSColor.windowBackgroundColor.cgColor)
                context.setLineWidth(1)
                context.strokeEllipse(in: dot)
            }
        }
        for control in controls where !(control is MKAnnotationView) {
            guard let rendered = Self.render(control) else { continue }
            context.draw(rendered, in: cgRect(control.convert(control.bounds, to: hosting)))
        }
        context.restoreGState()
        stage("after-overlays-and-controls")

        // The SwiftUI layer over it: the cached hosting view with the map
        // rect's placeholder palette (the two flat colours MapKit paints
        // before any tile arrives) keyed out. Antialiased text edges keep
        // a hint of that colour; nothing else is touched.
        guard let keyed = Self.keyingOutPlaceholder(in: cached, rect: mapRect) else { return nil }
        if ProcessInfo.processInfo.environment["REQRES_UI_PROBE_LAYERS"] != nil,
           let magenta = CGContext(data: nil, width: keyed.width, height: keyed.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            // Over magenta, so transparency is visible in the dump.
            magenta.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
            magenta.fill(CGRect(x: 0, y: 0, width: keyed.width, height: keyed.height))
            magenta.draw(keyed, in: CGRect(x: 0, y: 0, width: keyed.width, height: keyed.height))
            if let image = magenta.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                print("<<<PNG keyed-layer\n\(png.base64EncodedString())\nPNG>>>")
            }
        }
        context.draw(keyed, in: CGRect(origin: .zero, size: size))
        guard let composite = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: composite).representation(using: .png, properties: [:])
    }

    /// `cacheDisplay`, then the layer tree — nil when neither produces a
    /// pixel (hosted SwiftUI content inside an annotation view does not).
    private static func render(_ view: NSView) -> CGImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let cg = rep.cgImage, hasPixels(cg) { return cg }
        }
        if let layer = view.layer {
            let scale = view.window?.backingScaleFactor ?? 2
            let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            if let cg = context.makeImage(), hasPixels(cg) { return cg }
        }
        return nil
    }

    private static func hasPixels(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let count = CFDataGetLength(data)
        var i = 3
        while i < count {
            if bytes[i] != 0 { return true }
            i += 4
        }
        return false
    }

    /// The view's projection, as a fraction of the visible rect — the same
    /// `DestinationMapProjection` call `DestinationMapView.mapPoint` makes,
    /// so a disagreement between the composite and the live view would be
    /// MapKit's, not this instrument's.
    private static func project(_ coordinate: CLLocationCoordinate2D, in visible: MKMapRect) -> CGPoint {
        let point = MKMapPoint(coordinate)
        guard let unit = DestinationMapProjection.unitPoint(
            x: point.x, y: point.y,
            visibleOriginX: visible.origin.x, visibleOriginY: visible.origin.y,
            visibleWidth: visible.size.width, visibleHeight: visible.size.height,
            worldWidth: MKMapSize.world.width
        ) else { return .zero }
        return CGPoint(x: unit.x, y: unit.y)
    }

    /// `REQRES_UI_PROBE_CLICK=DE`: a synthesized left click on that country's
    /// dot, and what it found (2026-09-25). MapKit's SwiftUI `Map` selects
    /// annotations through gesture recognisers on `_SwiftUIMKMapView`
    /// (`_MKMouseDownGestureRecognizer` + three `NSClickGestureRecognizer`s —
    /// printed below), and a synthesized `NSEvent` fires NONE of them: not
    /// through `window.sendEvent`, not enqueued with `NSApp.postEvent`
    /// (`REQRES_UI_PROBE_CLICK_MODE=send|post`), and not with every SwiftUI
    /// gesture stripped from the dot's content — so the click cannot be
    /// verified headlessly, and the hosted gestures are not what stops it.
    /// `REQRES_UI_PROBE_CLICK_FALLBACK=1` then calls MapKit's own
    /// `selectAnnotation`, which DOES reach the binding and the store: that
    /// half is proven, and the composite renders the selected state from it.
    /// A physical click has to confirm it.
    @MainActor
    static func click(token: String, hosting: NSView) async {
        guard let mapView = firstMapView(in: hosting), let window = hosting.window else {
            print("[probe] click: no map view or window")
            return
        }
        guard let destination = TrafficDestination.parseToken(token), let iso = destination.isoCode,
              let coordinate = DestinationsStore.shared.geometry?.centroid(forISO: iso) else {
            print("[probe] click: \(token) is not a plotted country")
            return
        }
        guard let annotation = mapView.annotations.first(where: { abs($0.coordinate.latitude - coordinate.latitude) < 1e-6 && abs($0.coordinate.longitude - coordinate.longitude) < 1e-6 }),
              let view = mapView.view(for: annotation) else {
            print("[probe] click: no annotation view for \(token)")
            return
        }
        // NOT the annotation view's frame: under SwiftUI's `Map` it reports
        // the map's origin (measured — `convert(bounds, to:)` gave the
        // top-left 32×32 for a dot drawn at 908,223); the coordinate's point
        // is where the dot is.
        let centreInHosting = mapView.convert(annotation.coordinate, toPointTo: hosting)
        let centreInWindow = hosting.convert(centreInHosting, to: nil)
        let hit = window.contentView?.hitTest(centreInWindow)
        func recognisers(_ v: NSView?) -> String { (v?.gestureRecognizers ?? []).map { String(describing: type(of: $0)) }.joined(separator: ",") }
        print("[probe] click: \(token) at \(Int(centreInHosting.x)),\(Int(centreInHosting.y)) (annotation view frame reads \(view.convert(view.bounds, to: hosting).integral)) hit-test=\(hit.map { String(describing: type(of: $0)) } ?? "nil") selected-before=\(mapView.selectedAnnotations.count) store-before=\(DestinationsStore.shared.currentSelection?.token ?? "nil")")
        print("[probe] click: map recognisers=[\(recognisers(mapView))] annotation recognisers=[\(recognisers(view))] hit recognisers=[\(recognisers(hit))] enabled=\(view.isEnabled) chain=\(sequence(first: hit as NSView?, next: { $0?.superview }).prefix(5).compactMap { $0 }.map { String(describing: type(of: $0)) }.joined(separator: " > "))")
        // `sendEvent` hands the event straight to the window's dispatch;
        // `post` enqueues it like the HID system does, so a tracking loop
        // inside MapKit (`nextEvent(matching:)`) can consume the mouse-up.
        let mode = ProcessInfo.processInfo.environment["REQRES_UI_PROBE_CLICK_MODE"] ?? "post"
        var events: [NSEvent] = []
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
            if let event = NSEvent.mouseEvent(
                with: type, location: centreInWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 4242, clickCount: 1, pressure: pressure
            ) { events.append(event) }
        }
        if mode == "post" {
            events.forEach { NSApp.postEvent($0, atStart: false) }
        } else {
            for event in events {
                window.sendEvent(event)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        print("[probe] click(\(mode)): after — MapKit selected=\(mapView.selectedAnnotations.count) view.isSelected=\(view.isSelected) store=\(DestinationsStore.shared.currentSelection?.token ?? "nil")")
        if mapView.selectedAnnotations.isEmpty, ProcessInfo.processInfo.environment["REQRES_UI_PROBE_CLICK_FALLBACK"] != nil {
            // Separates the two halves: MapKit's own `selectAnnotation` is
            // what a click ends in; if the store follows it, the binding
            // path is sound and only the click delivery is in question.
            mapView.selectAnnotation(annotation, animated: false)
            try? await Task.sleep(nanoseconds: 600_000_000)
            print("[probe] click: selectAnnotation fallback — MapKit selected=\(mapView.selectedAnnotations.count) store=\(DestinationsStore.shared.currentSelection?.token ?? "nil")")
        }
    }

    private static func firstMapView(in view: NSView) -> MKMapView? {
        if let map = view as? MKMapView { return map }
        for child in view.subviews {
            if let map = firstMapView(in: child) { return map }
        }
        return nil
    }

    /// A ring is projected CONTIGUOUSLY: its first vertex through the
    /// wrapped projection, every other vertex by its offset from that one
    /// (normalised to the nearer copy of the world). Projecting each vertex
    /// independently sent Alaska's westernmost Aleutian vertex (−179°) a
    /// world to the right of an Atlantic view and dragged a filled sliver
    /// across the whole map (looked at, 2026-09-25). MapKit itself draws
    /// polygons in unwrapped map-point space, and every Natural Earth ring
    /// but Antarctica's (dropped) is already split at ±180°, so the live
    /// wash never streaks — this keeps the instrument as honest.
    private static func append(_ shape: MKMultiPoint, to path: CGMutablePath, project: (CLLocationCoordinate2D) -> CGPoint) {
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: shape.pointCount)
        shape.getCoordinates(&coordinates, range: NSRange(location: 0, length: shape.pointCount))
        guard let first = coordinates.first else { return }
        let origin = project(first)
        let firstPoint = MKMapPoint(first)
        // Points per map-point unit, from a second projected sample.
        let east = project(CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude + (first.longitude < 0 ? 1 : -1)))
        let eastPoint = MKMapPoint(CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude + (first.longitude < 0 ? 1 : -1)))
        let scaleX = (east.x - origin.x) / (eastPoint.x - firstPoint.x)
        let world = MKMapSize.world.width
        for (index, coordinate) in coordinates.enumerated() {
            var dx = MKMapPoint(coordinate).x - firstPoint.x
            if dx > world / 2 { dx -= world }
            if dx < -world / 2 { dx += world }
            let point = CGPoint(x: origin.x + dx * scaleX, y: project(coordinate).y)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if shape is MKPolygon { path.closeSubpath() }
    }

    /// With the map view hidden, the map rect is the hosting view's flat
    /// background (plus the Fit button's material in a corner); every pixel
    /// near either of the two dominant colours becomes transparent. `rect`
    /// is in the hosting view's flipped space, and so is the bitmap's row
    /// order.
    private static func keyingOutPlaceholder(in rep: NSBitmapImageRep, rect: CGRect) -> CGImage? {
        guard let cg = rep.cgImage else { return nil }
        let width = cg.width, height = cg.height
        let scale = CGFloat(width) / rep.size.width
        // A CG-owned buffer: an image made from a context over a Swift array
        // keeps pointing at that array after it is freed, and the composite
        // then shows whatever the tile data was reused for (measured).
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // The buffer's row 0 is the TOP row (CG's y axis is bottom-up only
        // for drawing), and the hosting view is flipped too: rows match.
        let px = Int(rect.minX * scale), pw = Int(rect.width * scale)
        let py = Int(rect.minY * scale), ph = Int(rect.height * scale)
        var histogram: [UInt32: Int] = [:]
        for y in max(py, 0)..<min(py + ph, height) {
            for x in max(px, 0)..<min(px + pw, width) {
                let i = (y * width + x) * 4
                let key = UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
                histogram[key, default: 0] += 1
            }
        }
        // The two dominant colours are the background (the hosting view's
        // fill and, in a corner, the Fit button's material); anything within
        // a small distance of either is background too — a flat fill is not
        // bit-identical across a hosting view's layers (measured: the top of
        // the map rect stayed opaque with an exact match).
        let dominant = histogram.sorted { $0.value > $1.value }.prefix(2).map { key -> (Int, Int, Int) in
            (Int(key.key >> 16 & 0xff), Int(key.key >> 8 & 0xff), Int(key.key & 0xff))
        }
        let tolerance = 10
        for y in max(py, 0)..<min(py + ph, height) {
            for x in max(px, 0)..<min(px + pw, width) {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                let isBackground = dominant.contains { abs($0.0 - r) <= tolerance && abs($0.1 - g) <= tolerance && abs($0.2 - b) <= tolerance }
                if isBackground { pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0 }
            }
        }
        return context.makeImage()
    }
}

// MARK: - Probe seed
//
// `REQRES_UI_PROBE=destinations|destinations-unknown|destinations-empty`
// (spec §10) seeds `SessionState` with the screenshot mocks. They carry their
// server addresses already (`ScreenshotMocks.Server`, bare IPs by the core's
// contract); the `-unknown` variant overwrites every address with something
// unparseable so the whole window reads Unknown (spec §7 state 3). Every
// mock's resolved token is printed, so a table that disagrees is visible, not
// assumed.
//
// `AppView`'s own DEBUG launch path also seeds three address-less mock
// sessions a moment later; `settle` removes whatever this probe did not seed
// at +0.9s — before the 1.5s capture and inside the store's 1s publish
// window — so the picture is exactly the seed, and the empty state is empty.
enum DestinationsProbe {
    @MainActor
    static func seed(unparseable: Bool) {
        var sessions = ScreenshotMocks.sessions()
        if unparseable {
            for index in sessions.indices { sessions[index].remoteAddress = "not-an-address" }
        }
        let resolver = DestinationResolver.shared
        print("[probe] country table: \(resolver.dataMonth ?? "FAILED: \(resolver.tableFailureReason ?? "?")")")
        for session in sessions {
            print("[probe] \(session.host) \(session.remoteAddressText ?? "nil") -> \(resolver.destination(for: session).token)")
            SessionState.shared.addSession(session: session)
        }
        settle(keeping: Set(sessions.map(\.id)))
    }

    @MainActor
    static func seedEmpty() {
        settle(keeping: [])
    }

    @MainActor
    private static func settle(keeping ids: Set<UUID>) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            MainActor.assumeIsolated {
                let state = SessionState.shared
                let strays = Set(state.sessions.map(\.id)).subtracting(ids)
                if ids.isEmpty {
                    _ = state.clearAllSessions()
                } else if !strays.isEmpty {
                    state.removeSession(sessionUids: strays)
                }
                // `REQRES_UI_PROBE_SELECT=DE|mac|unknown…` renders the selected
                // state: the halo, the header's buttons, the scoped breakdown
                // and the callout. Requested once the seed is in place.
                if let token = ProcessInfo.processInfo.environment["REQRES_UI_PROBE_SELECT"],
                   let destination = TrafficDestination.parseToken(token) {
                    DestinationsStore.shared.requestSelection(destination)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated {
                        let index = DestinationsStore.shared.index
                        let rows = index.sorted().map { "\($0.destination.token)=\($0.requests)" }.joined(separator: " ")
                        print("[probe] index: \(index.entries.count) destinations, \(index.totalRequests) requests, \(index.totalBytes) bytes; \(rows); origin=\(DestinationsStore.shared.origin?.isoCode ?? "nil") tz=\(TimeZone.current.identifier) geometry=\(DestinationsStore.shared.geometry.map { "\($0.features.count) features, \($0.centroids.count) centroids" } ?? DestinationsStore.shared.geometryError ?? "loading") offline=\(DestinationsStore.shared.isOffline)")
                    }
                }
            }
        }
    }
}
#endif
