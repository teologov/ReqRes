//
//  PaywallFailure.swift
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
//  What an alert says when activating a license or deactivating this Mac does
//  not work.
//
//  The core sorts every error its license calls throw into `LicenseFailure`
//  (XReqResCore). Utils cannot import the core, so `PaywallFailure` mirrors
//  that enum case for case, with the same labels, and the app maps one onto
//  the other. `PaywallCopy.failure(_:during:)` turns a failure into the
//  alert's words and buttons, under these rules (PaywallFailureCopyTests):
//
//   - The title says what happened, from the person's side, in at most 6
//     words, blaming nobody, with no final period.
//   - The message is one or two short sentences, each ending with a period:
//     what did not change ("Nothing changed on this Mac." when an activation
//     fails, "This Mac is still active." when a deactivation does) wherever
//     the title leaves it open, and what to do next.
//   - The detail is the license server's own words, for a key it did not
//     accept, or an unexpected error's description, and nothing else. It never
//     shows a license key, a device id, a serial number, a token or a nonce:
//     a detail with anything shaped like one is left out
//     (PaywallFailureDetail.swift).
//   - Nothing says how or when the license is checked. Saying that this Mac is
//     offline, or that reqresapp.com did not answer, is allowed: it describes
//     this attempt.
//   - An activation failure never offers Try Again: its Activate button is
//     the retry. A deactivation failure that a retry can fix offers exactly
//     one. Every other button opens a page on reqresapp.com or writes to
//     support, and carries VoiceOver's hint for where it goes
//     (`browserHint`, or `mailHint` for support). None opens
//     reqresapp.com/pricing/: a key at its device limit gets more licenses
//     on reqresapp.com/license/, where they are added to the same key.
//
//  Some failures cannot happen during a deactivation today (a malformed key,
//  an expired license, the device limit, an answer that cannot be confirmed),
//  but the copy is total: each one still says that this Mac is still active.
//

import Foundation

/// Which license call failed.
public enum PaywallOperation: Equatable, CaseIterable, Sendable {
    /// Activate License…, or Activate in Settings ▸ License.
    case activate
    /// Deactivate this Mac…
    case deactivate
}

/// Why a license call failed: the core's `LicenseFailure`, case for case.
public enum PaywallFailure: Equatable, Sendable {
    /// Why no answer came at all.
    public enum NetworkProblem: Equatable, CaseIterable, Sendable {
        case offline
        case timedOut
        case other
    }

    /// The key is not shaped XXXXX-XXXXX-XXXXX-XXXXX.
    case keyFormat
    /// reqresapp.com refused the key: a 2xx `valid: false`, or a 4xx that
    /// says it is not valid, refused, or needs activating. `serverMessage` is
    /// the server's own words, when it sent some.
    case keyNotAccepted(serverMessage: String?)
    /// A dated license that has run out.
    case licenseExpired
    /// The license has no free place for this Mac: `current` Macs of
    /// `limit`, as the server counts them. `canAdd`: the server says this key
    /// can take more licenses, which reqresapp.com/license/ adds to it.
    case deviceLimit(current: Int, limit: Int, canAdd: Bool)
    /// A 5xx, a 429, or a body that is not the server's JSON.
    case serverUnavailable
    /// No answer at all.
    case network(NetworkProblem)
    /// An answer that could not be confirmed as reqresapp.com's (A13).
    case unverifiedAnswer
    /// A copy of ReqRes not built by OloApps (A18): it runs as the free
    /// version and makes no license call.
    case unofficialBuild
    /// A development build with no license server to call.
    case noLicenceServer
    /// No license on this Mac to deactivate.
    case notActivated
    /// Anything else, with the error's own description.
    case unknown(description: String)
}

/// What the alert says, and its buttons besides OK.
public struct PaywallFailureCopy: Equatable, Sendable {
    public let title: String
    public let message: String
    /// Under the message, smaller: the server's own words, or an unexpected
    /// error's description. Nil when there is nothing to add.
    public let detail: String?
    public let actions: [PaywallFailureAction]

    public init(title: String, message: String, detail: String? = nil, actions: [PaywallFailureAction] = []) {
        self.title = title
        self.message = message
        self.detail = detail
        self.actions = actions
    }
}

/// A button the alert offers besides OK.
public enum PaywallFailureAction: Equatable, Sendable {
    /// Run the call that failed again.
    case retry(title: String)
    /// Open a page on reqresapp.com, or write to support. `hint` is what
    /// VoiceOver says the button does: the glyph after its title (↗ for a
    /// page, an envelope for a mail) is hidden from VoiceOver.
    case open(title: String, url: URL, hint: String)
}

extension PaywallCopy {
    // MARK: - The buttons a failure offers

    /// Repeats a deactivation that a retry can fix.
    public static let tryAgainTitle = "Try Again"

    public static let contactSupportTitle = "Contact Support"

    /// The address the website gives everywhere (components/pricing/offer.ts
    /// `SUPPORT_EMAIL`).
    public static let supportEmail = "support@oloapps.com"
    public static var supportURL: URL { URL(string: "mailto:\(supportEmail)")! }

    /// VoiceOver's hint on Contact Support. It writes a mail, so it never
    /// says "browser"; every other button a failure offers opens a page and
    /// carries `browserHint`.
    public static var mailHint: String { "Starts an email to \(supportEmail) in your email app" }

    public static let downloadTitle = "Download ReqRes"

    /// The website's page for getting ReqRes: "Install ReqRes", with the
    /// download button and the steps after it (content/docs/getting-started/
    /// install.mdx). The site has no /download/ page, and the disk image's own
    /// address changes with every release.
    public static let downloadPageURL = URL(string: "https://reqresapp.com/docs/getting-started/install/")!

    /// How a development build is pointed at the website's local license
    /// server (the core's DevLicenseServer).
    static let devLicenseServerSetting = "REQRES_DEV_LICENSE_API=http://localhost:3000/api"

    /// Where Deactivate this Mac… is, as a sentence names it.
    static let licenseSettingsPath = "Settings ▸ License"

    // MARK: - The copy

    /// The alert for `failure` during `operation`. Total: every failure has
    /// words for both operations.
    public static func failure(_ failure: PaywallFailure, during operation: PaywallOperation) -> PaywallFailureCopy {
        switch operation {
        case .activate:
            return activationFailure(failure)
        case .deactivate:
            return deactivationFailure(failure)
        }
    }

    private static func activationFailure(_ failure: PaywallFailure) -> PaywallFailureCopy {
        let nothingChanged = "Nothing changed on this Mac."
        switch failure {
        case .keyFormat:
            return PaywallFailureCopy(
                title: "That isn’t a license key",
                message: "License keys look like \(keyPrompt). Copy the key from your purchase email and try again.")
        case .keyNotAccepted(let serverMessage):
            return PaywallFailureCopy(
                title: "This key wasn’t accepted",
                message: "Check it against your purchase email. "
                    + "If it’s right, contact support and include the email you bought with.",
                detail: shownDetail(serverMessage),
                actions: [contactSupport])
        case .licenseExpired:
            return PaywallFailureCopy(
                title: "This license is no longer active",
                message: "Contact support and include the email you bought with. \(nothingChanged)",
                actions: [contactSupport])
        case .deviceLimit(let current, let limit, let canAdd):
            return deviceLimitCopy(current: current, limit: limit, canAdd: canAdd)
        case .serverUnavailable:
            return PaywallFailureCopy(
                title: "reqresapp.com didn’t answer",
                message: "\(nothingChanged) Try again in a minute.")
        case .network(.offline):
            return PaywallFailureCopy(
                title: "This Mac is offline",
                message: "Connect to the internet, then try again. \(nothingChanged)")
        case .network(.timedOut):
            return PaywallFailureCopy(
                title: "reqresapp.com took too long to answer",
                message: "\(nothingChanged) Try again in a minute.")
        case .network(.other):
            return PaywallFailureCopy(
                title: "ReqRes couldn’t reach reqresapp.com",
                message: "Check your network connection, then try again. \(nothingChanged)")
        case .unverifiedAnswer:
            return PaywallFailureCopy(
                title: "ReqRes couldn’t confirm the answer",
                message: "The answer from reqresapp.com couldn’t be confirmed, so nothing changed. "
                    + "Try again; if it keeps happening, contact support.",
                actions: [contactSupport])
        case .unofficialBuild:
            return unofficialBuildCopy
        case .noLicenceServer:
            return noLicenceServerCopy
        case .notActivated:
            return PaywallFailureCopy(
                title: "Activation didn’t work",
                message: "\(nothingChanged) Enter your license key, then try again.")
        case .unknown(let description):
            return PaywallFailureCopy(
                title: "Activation didn’t work",
                message: "\(nothingChanged) Try again; if it keeps happening, contact support.",
                detail: shownDetail(description),
                actions: [contactSupport])
        }
    }

    private static func deactivationFailure(_ failure: PaywallFailure) -> PaywallFailureCopy {
        let stillActive = "This Mac is still active"
        let notDeactivated = "reqresapp.com didn’t deactivate this Mac"
        let tryAgain = PaywallFailureAction.retry(title: tryAgainTitle)
        let licensePage = shownAddress(licensePageURL)
        switch failure {
        case .keyFormat:
            return PaywallFailureCopy(
                title: stillActive,
                message: "Its license key isn’t in the right form, so nothing changed. "
                    + "You can remove this Mac at \(licensePage).")
        case .keyNotAccepted(let serverMessage):
            return PaywallFailureCopy(
                title: notDeactivated,
                message: "\(stillActive).",
                detail: shownDetail(serverMessage),
                actions: [contactSupport])
        case .licenseExpired:
            return PaywallFailureCopy(
                title: notDeactivated,
                message: "\(stillActive). Contact support and include the email you bought with.",
                actions: [contactSupport])
        case .deviceLimit:
            // Adding licenses would not deactivate this Mac, so a key that can
            // take more is told nothing more here.
            return PaywallFailureCopy(
                title: notDeactivated,
                message: "\(stillActive). You can remove a Mac at \(licensePage).",
                actions: [manageYourMacs])
        case .serverUnavailable:
            return PaywallFailureCopy(
                title: stillActive,
                message: "reqresapp.com didn’t answer, so nothing changed. Try again in a minute.",
                actions: [tryAgain])
        case .network(.offline):
            return PaywallFailureCopy(
                title: stillActive,
                message: "This Mac is offline, so nothing changed. Connect to the internet, then try again.",
                actions: [tryAgain])
        case .network(.timedOut):
            return PaywallFailureCopy(
                title: stillActive,
                message: "reqresapp.com took too long to answer, so nothing changed. Try again in a minute.",
                actions: [tryAgain])
        case .network(.other):
            return PaywallFailureCopy(
                title: stillActive,
                message: "ReqRes couldn’t reach reqresapp.com, so nothing changed. "
                    + "Check your network connection, then try again.",
                actions: [tryAgain])
        case .unverifiedAnswer:
            return PaywallFailureCopy(
                title: stillActive,
                message: "The answer from reqresapp.com couldn’t be confirmed, so nothing changed. "
                    + "Try again; if it keeps happening, contact support.",
                actions: [tryAgain, contactSupport])
        case .unofficialBuild:
            return unofficialBuildCopy
        case .noLicenceServer:
            return noLicenceServerCopy
        case .notActivated:
            return PaywallFailureCopy(
                title: "This Mac has no license",
                message: "There’s nothing to deactivate.")
        case .unknown(let description):
            return PaywallFailureCopy(
                title: stillActive,
                message: "Something went wrong, so nothing changed. Try again; if it keeps happening, contact support.",
                detail: shownDetail(description),
                actions: [tryAgain, contactSupport])
        }
    }

    // MARK: - Shared

    private static var contactSupport: PaywallFailureAction {
        .open(title: contactSupportTitle, url: supportURL, hint: mailHint)
    }

    /// The device limit's one button, whatever the key. A key the server says
    /// can take more licenses (`canAdd`) gets them on this same page, which
    /// adds them to this key; reqresapp.com/pricing/ would sell a second key,
    /// which this Mac's activation, still trying the first, never uses.
    private static var manageYourMacs: PaywallFailureAction {
        .open(title: manageTitle, url: licensePageURL, hint: browserHint)
    }

    /// "Device limit reached (2/2)": the server's words, which the core's own
    /// text and the docs use too (A8), with the Macs the server counted (the
    /// limit when the count is missing) of the limit. With no limit, no
    /// number: never "(0/0)".
    static func deviceLimitTitle(current: Int, limit: Int) -> String {
        guard limit > 0 else { return "Device limit reached" }
        return "Device limit reached (\(current > 0 ? current : limit)/\(limit))"
    }

    /// Names the button that frees a place from another Mac (A8) and the page
    /// that frees one from anywhere; when the server says the key can take
    /// more licenses, that page adds them too.
    private static func deviceLimitCopy(current: Int, limit: Int, canAdd: Bool) -> PaywallFailureCopy {
        let licensePage = shownAddress(licensePageURL)
        let anotherMac = "Click \(deactivateName) in \(licenseSettingsPath) on another Mac, then try again."
        let page = canAdd
            ? "Or remove a Mac or add licenses at \(licensePage)."
            : "Or remove a Mac at \(licensePage)."
        return PaywallFailureCopy(title: deviceLimitTitle(current: current, limit: limit),
                                  message: "\(anotherMac) \(page)",
                                  actions: [manageYourMacs])
    }

    private static var unofficialBuildCopy: PaywallFailureCopy {
        PaywallFailureCopy(
            title: "This copy can’t use a license",
            message: "It wasn’t built by OloApps, so it runs as the free version. "
                + "Download ReqRes from reqresapp.com to use your license.",
            actions: [.open(title: downloadTitle, url: downloadPageURL, hint: browserHint)])
    }

    /// Words for a developer: only a development build ever has no server.
    private static var noLicenceServerCopy: PaywallFailureCopy {
        PaywallFailureCopy(
            title: "No license server",
            message: "This development build has no license server. "
                + "Quit ReqRes and open it again with \(devLicenseServerSetting).")
    }
}
