//
//  ExcludedHostsSettings.swift
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
//  Roadmap item 14. The list lives here; the engine that honours it lives in
//  the extension, a separate process that starts empty every time the tunnel
//  does. So this pushes on every edit AND on every status update — an
//  exclusion that silently stopped applying after a restart would be worse
//  than not having the feature, because the user would go on trusting it.
//
//  The matching rules are `ExcludedHostList`'s (in Utils, tested there); the
//  core implements the same ones against the live connection.
//

import Foundation
import Utils
import XReqResCore

@MainActor
final class ExcludedHostsSettings: ObservableObject {
    static let shared = ExcludedHostsSettings()

    static let defaultsKey = "CaptureExcludedHosts"

    @Published private(set) var list: ExcludedHostList

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent means a first run, which gets the recommended entry. An
        // explicitly EMPTY stored list stays empty: the user removed it.
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(ExcludedHostList.self, from: data) {
            list = stored
        } else {
            list = ExcludedHostList()
        }
    }

    /// True when the host was added. False means the text cannot exclude
    /// anything or is already covered — the caller says which.
    @discardableResult
    func exclude(_ host: String) -> Bool {
        guard let updated = list.adding(host) else { return false }
        apply(updated)
        return true
    }

    func stopExcluding(_ host: String) {
        apply(list.removing(host))
    }

    func restoreRecommended() {
        apply(ExcludedHostList())
    }

    private func apply(_ updated: ExcludedHostList) {
        list = updated
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        Task { await push() }
    }

    /// Sends the current list to the extension. Safe to call when no tunnel is
    /// running — the bus drops it, and the next status update sends it again.
    func push() async {
        let hosts = list.hosts
        AppController.shared.notifyExtension(
            message: ServerBusMessage(action: .excludedHostsChanged, payload: ["data": hosts])
        )
        AppLog.shared.debug("[ExcludedHostsSettings] pushed \(hosts.count, privacy: .public) excluded hosts")
    }
}
