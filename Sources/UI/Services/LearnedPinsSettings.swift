//
//  LearnedPinsSettings.swift
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
//  The apps that refused ReqRes's certificate, per domain (`LearnedPinList`,
//  Utils). The extension learns one when an app refuses the certificate and
//  tells the app (`pin_learned`); it forgets them all when the tunnel stops,
//  so this list is pushed back on every edit and every status update — the
//  shape `ExcludedHostsSettings` has, for the same reason.
//

import Foundation
import Utils
import XReqResCore

@MainActor
final class LearnedPinsSettings: ObservableObject {
    static let shared = LearnedPinsSettings()

    static let defaultsKey = "CaptureLearnedPins"

    @Published private(set) var list: LearnedPinList

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(LearnedPinList.self, from: data) {
            list = stored
        } else {
            list = LearnedPinList()
        }
    }

    /// The extension learned one (`pin_learned`). Already known: nothing
    /// changes, and nothing is pushed.
    func learned(_ record: LearnedPinRecord) {
        guard let updated = list.adding(record) else { return }
        apply(updated)
    }

    func forget(id: String) {
        apply(list.removing(id: id))
    }

    func forgetAll() {
        apply(LearnedPinList())
    }

    private func apply(_ updated: LearnedPinList) {
        list = updated
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        Task { await push() }
    }

    /// Sends the whole list to the extension; the core reads `app`,
    /// `appName` and `domain` of each record. Safe with no tunnel running.
    func push() async {
        let records = list.records
        AppController.shared.notifyExtension(
            message: ServerBusMessage(action: .learnedPinsChanged, payload: ["data": records])
        )
        AppLog.shared.debug("[LearnedPinsSettings] pushed \(records.count, privacy: .public) learned pins")
    }
}
