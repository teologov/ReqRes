//
//  PaywallFailure+Core.swift
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
//  The core's failure kinds as Utils' mirror, and Utils' words as the core's
//  types.
//
//  The core reads whatever its licence calls threw as a `LicenseFailure` and
//  hands the app that kind, never a sentence. Utils cannot import the core,
//  so `PaywallFailure` mirrors it case for case, with the same labels, and
//  `PaywallCopy.failure(_:during:)` turns it into a title, a message, a
//  detail and buttons. This file only carries values across, case for case,
//  with no string literal (PaywallCopyWiringTests reads it against the
//  embedded binary's interface, so a case the core adds and this file misses
//  fails the tests as well as warning here).
//

import Utils
import XReqResCore

extension PaywallFailure {
    /// The core's `failure`, case for case.
    init(_ failure: LicenseFailure) {
        switch failure {
        case .keyFormat:
            self = .keyFormat
        case .keyNotAccepted(let serverMessage):
            self = .keyNotAccepted(serverMessage: serverMessage)
        case .licenseExpired:
            self = .licenseExpired
        case .deviceLimit(let current, let limit, let canAdd):
            self = .deviceLimit(current: current, limit: limit, canAdd: canAdd)
        case .serverUnavailable:
            self = .serverUnavailable
        case .network(let problem):
            self = .network(NetworkProblem(problem))
        case .unverifiedAnswer:
            self = .unverifiedAnswer
        case .unofficialBuild:
            self = .unofficialBuild
        case .noLicenceServer:
            self = .noLicenceServer
        case .notActivated:
            self = .notActivated
        case .unknown(let description):
            self = .unknown(description: description)
        @unknown default:
            // A kind a newer core knows and this build does not: said as an
            // unexpected error, with the kind's own description.
            self = .unknown(description: String(describing: failure))
        }
    }
}

extension PaywallFailure.NetworkProblem {
    /// The core's `problem`, case for case.
    init(_ problem: LicenseFailure.NetworkProblem) {
        switch problem {
        case .offline:
            self = .offline
        case .timedOut:
            self = .timedOut
        case .other:
            self = .other
        @unknown default:
            // "Anything else" is what `.other` already means.
            self = .other
        }
    }
}

extension PaywallOperation {
    /// The core's `operation`. Both are exhaustive with no fallback: there is
    /// no third licence action to guess at.
    init(_ operation: LicenseOperation) {
        switch operation {
        case .activate:
            self = .activate
        case .deactivate:
            self = .deactivate
        }
    }
}

extension PlanSheetContent.FailureCopy {
    /// Utils' words for a failure, as the core's views take them.
    init(_ copy: PaywallFailureCopy) {
        self.init(title: copy.title, message: copy.message, detail: copy.detail,
                  actions: copy.actions.map { action in PlanSheetContent.FailureAction(action) })
    }
}

extension PlanSheetContent.FailureAction {
    /// Utils' button, as the core's, with VoiceOver's hint for where it goes.
    init(_ action: PaywallFailureAction) {
        switch action {
        case .retry(let title):
            self = .retry(title: title)
        case .open(let title, let url, let hint):
            self = .open(title: title, url: url, hint: hint)
        }
    }
}
