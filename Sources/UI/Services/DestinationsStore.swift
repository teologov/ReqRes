//
//  DestinationsStore.swift
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
//  What the Destinations window observes (destination-map UX spec §2.3) — and
//  the reason it exists: the window must NOT observe `SessionState`, which
//  publishes its session arrays on every 150ms capture flush (the toolbar's
//  search field lives on its own object for exactly this reason). `SessionState`
//  hands this store its `DestinationIndex` after every mutation; the store
//  publishes at most once a second while the window is open, with a trailing
//  publish so the last batch always lands, and drops everything while it is
//  closed. The window's rows and the map take VALUES from these publishes.
//
//  The origin — where the user approximately is, from the time zone — is
//  published here for the map and nowhere else (spec §0, §11): no agent
//  surface reads this object.
//
//  The map is Apple Maps (MapKit) since the rewrite, so this store also
//  watches whether there is a network path at all: without one the tiles
//  are blank while every dot, arc and label still renders, and the strip
//  says why in one line. The monitor runs only while the window is open.
//

import AppKit
import Combine
import Foundation
import MCPKit
import Network
import NetworkExtension
import XReqResCore

@MainActor
final class DestinationsStore: ObservableObject {
    static let shared = DestinationsStore()

    /// The retained sessions' destinations, as of the last publish.
    @Published private(set) var index = DestinationIndex()
    /// The country outlines and centroids, loaded off main on the first
    /// activation (~20 ms). The map draws without them — Apple's tiles need
    /// nothing from the bundle — but the dots and the wash do not.
    @Published private(set) var geometry: WorldMapGeometry?
    /// Why the outlines could not be loaded — the window shows a banner over
    /// a bare map and keeps listing destinations (spec §7 state 4).
    @Published private(set) var geometryError: String?
    /// True while `NWPathMonitor` reports no usable path — the one condition
    /// under which the map's tiles cannot load (spec §7, the offline line).
    @Published private(set) var isOffline = false
    /// Spec §7 state 6: a small spinner while the first load runs.
    @Published private(set) var isLoadingGeometry = false
    /// `TimeZone.current`'s country at init and whenever the system zone
    /// changes. Nil for UTC, `Etc/*` and unmapped zones (spec §7 state 5).
    @Published private(set) var origin: OriginEstimate?
    /// Set by `requestSelection`, consumed and cleared by the window.
    @Published var pendingSelection: TrafficDestination?

    /// Snapshots of `AppState`, so the window's placeholders (spec §7 states
    /// 1 and 2) and the Apps column (state 7) can answer without observing
    /// `AppState` — published only on change and only while active.
    @Published private(set) var isCapturing = false
    @Published private(set) var extensionReady = false
    @Published private(set) var attribution: ProcessAttributionAvailability = .unreported

    private(set) var isActive = false

    /// What the window currently has selected, written by the window. The
    /// controller's plain `show()` preselects the table's single `country:`
    /// chip only when this is nil (spec §2.2).
    var currentSelection: TrafficDestination?

    /// The window's minimum spacing between publishes.
    static let publishInterval: TimeInterval = 1

    private var latest: DestinationIndex?
    private var lastPublish = Date.distantPast
    private var trailingPublish: Task<Void, Never>?
    private var appStateSubscriptions = Set<AnyCancellable>()
    private var timeZoneSubscription: AnyCancellable?
    private var pathMonitor: NWPathMonitor?

    private init() {
        origin = DestinationResolver.shared.origin(for: .current)
        timeZoneSubscription = NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    DestinationsStore.shared.origin = DestinationResolver.shared.origin(for: .current)
                }
            }
    }

    // MARK: - Activation

    /// `true`: publish the current index NOW (the first frame must be current),
    /// start the geometry load if it has not run, and begin mirroring
    /// `AppState`. `false`: stop publishing; whatever arrives is dropped until
    /// the next activation republishes the whole index anyway.
    func setActive(_ active: Bool) {
        isActive = active
        if active {
            publish(SessionState.shared.destinationIndex)
            if geometry == nil && !isLoadingGeometry { loadGeometry() }
            mirrorAppState()
            startPathMonitor()
        } else {
            trailingPublish?.cancel()
            trailingPublish = nil
            latest = nil
            appStateSubscriptions.removeAll()
            pathMonitor?.cancel()
            pathMonitor = nil
        }
    }

    /// Called by `SessionState` after every mutation of its index, on main.
    /// Coalesced to `publishInterval` with a trailing publish.
    func indexDidChange(_ index: DestinationIndex) {
        guard isActive else { return }
        let elapsed = Date().timeIntervalSince(lastPublish)
        if elapsed >= Self.publishInterval {
            // This index supersedes whatever the trailing task was holding;
            // left in place, that older index would publish a second later
            // and the window would step backwards until the next flush.
            latest = nil
            trailingPublish?.cancel()
            trailingPublish = nil
            publish(index)
            return
        }
        latest = index
        guard trailingPublish == nil else { return }
        let delay = Self.publishInterval - elapsed
        trailingPublish = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.trailingPublish = nil
            if let pending = self.latest {
                self.latest = nil
                self.publish(pending)
            }
        }
    }

    func requestSelection(_ destination: TrafficDestination) {
        pendingSelection = destination
    }

    // MARK: - Private

    private func publish(_ index: DestinationIndex) {
        lastPublish = Date()
        if index != self.index { self.index = index }
    }

    private func loadGeometry() {
        isLoadingGeometry = true
        geometryError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try WorldMapGeometry.load() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = DestinationsStore.shared
                    store.isLoadingGeometry = false
                    switch result {
                    case .success(let geometry):
                        store.geometry = geometry
                    case .failure(let error):
                        store.geometryError = error.localizedDescription
                        AppLog.shared.debug("[Destinations] world map failed to load: \(error)")
                    }
                }
            }
        }
    }

    /// Mirrors the three `AppState` facts the window needs, de-duplicated so a
    /// publish of `AppState` about something else never reaches the window.
    /// `.reasserting` and `.connecting` count as capturing — a tunnel on its
    /// way up should show the map, not the "start capturing" placeholder.
    private func mirrorAppState() {
        appStateSubscriptions.removeAll()
        let appState = AppState.shared
        isCapturing = Self.capturing(appState.vpnStatus)
        extensionReady = appState.extensionStatus == .ready
        attribution = appState.processAttribution

        appState.$vpnStatus
            .map(Self.capturing)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { capturing in
                MainActor.assumeIsolated { DestinationsStore.shared.isCapturing = capturing }
            }
            .store(in: &appStateSubscriptions)
        appState.$extensionStatus
            .map { $0 == .ready }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { ready in
                MainActor.assumeIsolated { DestinationsStore.shared.extensionReady = ready }
            }
            .store(in: &appStateSubscriptions)
        appState.$processAttribution
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { availability in
                MainActor.assumeIsolated { DestinationsStore.shared.attribution = availability }
            }
            .store(in: &appStateSubscriptions)
    }

    /// One monitor per activation; its updates hop to main and only a CHANGE
    /// publishes, so a flapping interface cannot redraw the window faster
    /// than the index does. ONLY `.unsatisfied` is offline. `.requiresConnection`
    /// is what a VPN configuration waiting to connect reports, and ReqRes's
    /// own capture IS a VPN configuration (an NE packet tunnel that routes
    /// nothing); whether the path reads `.satisfied` while it is up has not
    /// been measured, and a false "offline" line while capturing would be a
    /// permanent strip line under a map that is loading fine. The cost of the
    /// other mistake — a captive portal not called offline — is one missing
    /// sentence.
    private func startPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let offline = path.status == .unsatisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = DestinationsStore.shared
                    guard store.pathMonitor === monitor else { return }
                    if store.isOffline != offline { store.isOffline = offline }
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    private static func capturing(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting: return true
        case .disconnected, .disconnecting, .invalid: return false
        @unknown default: return false
        }
    }
}
