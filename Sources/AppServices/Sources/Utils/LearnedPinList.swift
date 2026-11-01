//
//  LearnedPinList.swift
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
//  The apps that refused ReqRes's certificate, per domain (WhatsApp's media
//  downloads failed while capturing). The extension learns one when an app
//  refuses the certificate (core `LearnedPins`) and relays that app's
//  connections to that domain from then on, marked SSL pinned; it forgets
//  everything when the tunnel stops, so THIS list — kept by the app, shown in
//  Settings ▸ Capture — is the one that lasts, and is pushed back on every edit
//  and every status update (the exclusion list's shape).
//

import Foundation

/// One app and one domain. Encodes to the bus payload the core decodes
/// (`app`, `appName`, `domain`; the core ignores `learnedAt`).
public struct LearnedPinRecord: Codable, Hashable, Sendable, Identifiable {
    /// The app's executable path, else its process name; "" = any app.
    public var app: String
    public var appName: String
    /// The registrable domain, e.g. "whatsapp.net".
    public var domain: String
    public var learnedAt: Date

    public var id: String { "\(app)\u{0}\(domain)" }

    public init(app: String, appName: String, domain: String, learnedAt: Date = Date()) {
        self.app = app
        self.appName = appName
        self.domain = domain
        self.learnedAt = learnedAt
    }

    /// Reads the extension's `pin_learned` payload (`["app", "appName",
    /// "domain"]`); nil when it is not one.
    public init?(busPayload: Any?, learnedAt: Date = Date()) {
        guard let dictionary = busPayload as? [String: Any],
              let app = dictionary["app"] as? String,
              let domain = dictionary["domain"] as? String, !domain.isEmpty else { return nil }
        self.init(app: app, appName: dictionary["appName"] as? String ?? "", domain: domain, learnedAt: learnedAt)
    }
}

public struct LearnedPinList: Codable, Equatable, Sendable {
    /// Newest first.
    public private(set) var records: [LearnedPinRecord]

    public init(records: [LearnedPinRecord] = []) {
        self.records = []
        for record in records.sorted(by: { $0.learnedAt > $1.learnedAt }) {
            self = self.adding(record) ?? self
        }
    }

    /// The list with `record` added, or nil when that app and domain are
    /// already there (the earlier date is kept).
    public func adding(_ record: LearnedPinRecord) -> LearnedPinList? {
        guard !records.contains(where: { $0.id == record.id }) else { return nil }
        var copy = self
        copy.records.insert(record, at: 0)
        copy.records.sort { $0.learnedAt > $1.learnedAt }
        return copy
    }

    public func removing(id: String) -> LearnedPinList {
        var copy = self
        copy.records.removeAll { $0.id == id }
        return copy
    }

    public var isEmpty: Bool { records.isEmpty }
}
