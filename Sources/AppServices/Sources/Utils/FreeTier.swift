//
//  FreeTier.swift
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
//  What the free version limits — in one place, because it is quoted to people
//  who are deciding whether to pay.
//
//  These three numbers were written out four times: the host-filter gate in
//  `AddHostModal`, the rule gate in `RuleModal`, the inspection counter on
//  `AppState`, and a second copy of the first two in `MCPWriteAdapters` for the
//  agent surface. A paywall that states a limit is a fifth copy, and the one
//  nobody would notice going stale.
//
//  So the paywall reads these, and so does every gate. Changing the free tier
//  is now one edit, and the screen that sells the licence cannot describe a
//  product the app does not enforce.
//

import Foundation

public enum FreeTier {
    /// Host filters in the sidebar. Checked against the whole store, not per
    /// window: the third one is refused.
    public static let hostFilters = 2

    /// Override rules — ONE in total, across every host, not one per host.
    /// Editing an existing rule is never limited, only creating another.
    public static let overrideRules = 1

    /// How many HTTPS sessions can be opened in the detail pane per launch.
    ///
    /// Per LAUNCH, in memory, reset on every restart — by design. And it gates
    /// only the app's own detail pane: capture, recording and the traffic
    /// table are never limited, so a free user still sees every request go by.
    public static let httpsSessionDetailsPerLaunch = 10

    /// True when `count` existing rows means the next one is refused.
    public static func hostFilterLimitReached(existing count: Int) -> Bool {
        count >= hostFilters
    }

    public static func overrideRuleLimitReached(existing count: Int) -> Bool {
        count >= overrideRules
    }

    /// What the traffic detail pane shows for a selected row, and whether
    /// opening it spends one of the per-launch HTTPS inspections.
    public enum DetailAccess: Equatable {
        /// A connection relayed without decrypting it: its own view, always,
        /// and never counted — there is nothing inside it to inspect, so a
        /// free user must not lose an inspection to a row that says so.
        case relay
        /// An HTTPS row while no ReqRes certificate is installed.
        case certificateRequired
        /// The whole detail; unlicensed HTTPS spends one inspection.
        case inspect(counted: Bool)
        /// The free inspections are used up.
        case limitReached
        /// A request that failed, was aborted or timed out (protocol PRD 3.4):
        /// its failure banner over whatever the row recorded, always, and
        /// never counted (decision D14) — a row whose point is "this broke,
        /// and here is why" must not cost a free user an inspection, nor be
        /// hidden behind the certificate gate when the failure IS about a
        /// certificate.
        case failure
    }

    /// The one decision the detail pane makes, in the order that matters: a
    /// relay first (it is HTTPS, recorded with NO certificate installed, and
    /// is neither a certificate problem nor an inspection), then the
    /// certificate, then the licence.
    ///
    /// A failure row comes second: after a relay (a relay that failed is still
    /// a connection with nothing inside it) and before everything else —
    /// unless it carries a decrypted body from an exchange that got under way
    /// (`failureCarriesDecryptedBody`: an aborted or timed-out row with a
    /// request or response body recorded). That row IS an inspection — a
    /// download or a stream cut mid-way holds up to 16 MB of the server's
    /// content, and "Show cancelled requests" would otherwise list every one
    /// of them uncounted — so it goes through the certificate and the licence
    /// like any exchange; the pane still shows its failure banner above.
    /// A FAILED row (it never got a response; any 502 body is ReqRes's own
    /// sentence) is never counted (decision D14).
    public static func detailAccess(
        isRelay: Bool,
        isFailure: Bool,
        failureCarriesDecryptedBody: Bool,
        isHTTPS: Bool,
        certificateInstalled: Bool,
        licensed: Bool,
        inspectionsUsedUp: Bool
    ) -> DetailAccess {
        if isRelay { return .relay }
        if isFailure && !failureCarriesDecryptedBody { return .failure }
        guard isHTTPS else { return .inspect(counted: false) }
        if !certificateInstalled { return .certificateRequired }
        if licensed { return .inspect(counted: false) }
        return inspectionsUsedUp ? .limitReached : .inspect(counted: true)
    }
}

extension FreeTier {
    /// Which rows have already spent a free inspection this launch.
    ///
    /// Keyed by the ROW's id, which a live row keeps through every update and
    /// its final row (protocol-engine doc §S6): opening a streaming request
    /// and watching it grow, then finish, spends ONE inspection — not one per
    /// progress message, and not a second when the final replaces it. Only an
    /// access that is `.inspect(counted: true)` spends one; a relay or a
    /// failure never does (decision D14).
    public struct InspectionTally: Equatable {
        public private(set) var counted = Set<UUID>()

        public init() {}

        /// Records that `rowID` is being shown under `access`. True when this
        /// view spends an inspection (the caller increments the counter).
        public mutating func recordView(rowID: UUID, access: DetailAccess) -> Bool {
            guard access == .inspect(counted: true) else { return false }
            return counted.insert(rowID).inserted
        }

        public func hasCounted(_ rowID: UUID) -> Bool { counted.contains(rowID) }
    }
}
