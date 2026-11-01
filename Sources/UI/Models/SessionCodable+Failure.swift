//
//  SessionCodable+Failure.swift
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
//  The ONE place the views and the agent adapters read the core's outcome
//  fields (protocol PRD 3.4; core §C6: `outcome`, `failurePhase`,
//  `failureDetail`, `clientCancelled`). The core's enums are mapped by raw
//  value onto MCPKit's, whose words every surface prints — so a failure reads
//  the same in the table, the detail banner, an agent's text and a HAR file.
//
//  Under library evolution the core's `SessionOutcome` / `SessionFailurePhase`
//  are non-frozen: going through `rawValue` means a case a later core adds
//  maps (to `.failed` / `.other`) instead of needing an `@unknown default`.
//

import Foundation
import MCPKit
import XReqResCore

extension SessionCodable {
    /// How the exchange ended, in MCPKit's vocabulary.
    var sessionOutcome: MCPSessionOutcome {
        MCPSessionOutcome(rawValue: outcome.rawValue) ?? .failed
    }

    /// Where it broke; nil for a completed row.
    var sessionFailurePhase: MCPFailurePhase? {
        failurePhase.map { MCPFailurePhase(rawValue: $0.rawValue) ?? .other }
    }

    /// Failed, aborted or timed out.
    var isFailure: Bool { sessionOutcome.isFailure }

    /// The failure's facts, or nil for a completed row.
    var failureFacts: FailureRowFacts? {
        guard isFailure else { return nil }
        return FailureRowFacts(
            outcome: sessionOutcome,
            phase: sessionFailurePhase,
            detail: failureDetail,
            clientCancelled: clientCancelled,
            status: rspStatus,
            hasServerAddress: remoteAddressText != nil
        )
    }

    /// An aborted or timed-out row that kept a request or response body: its
    /// detail is an HTTPS inspection like any exchange's (D14's limit, see
    /// `FreeTier.detailAccess`).
    var failureCarriesDecryptedBody: Bool {
        let hasBody = !reqBody.isEmpty || !rspBody.isEmpty || !(rspBodyData?.isEmpty ?? true)
        return failureFacts?.carriesDecryptedBody(hasRecordedBody: hasBody) ?? false
    }

    /// Failed before connecting to any server: left out of the Destinations
    /// map and `list_destinations` (it went nowhere).
    var neverConnected: Bool { failureFacts?.neverConnected ?? false }

    /// D8: hidden from the traffic list while Settings ▸ Capture ▸ "Show
    /// cancelled requests" is off.
    func isHiddenFromTraffic(showCancelled: Bool) -> Bool {
        failureFacts?.isHidden(showCancelled: showCancelled) ?? false
    }

    /// The token the `outcome:` chip compares (`failed`, …).
    var outcomeToken: String { sessionOutcome.token }
}

/// The D8 setting: whether client-cancelled requests are listed.
enum CancelledRequestsSetting {
    /// Absent means OFF (decision D8: hidden by default).
    static let defaultsKey = "traffic-show-cancelled"

    static var showCancelled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
