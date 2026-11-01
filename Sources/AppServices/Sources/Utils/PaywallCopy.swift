//
//  PaywallCopy.swift
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
//  Every word of the ReqRes Pro sheet, of the same sheet after an activation
//  made in it, of Settings ▸ License and of the Activate License sheet, except
//  the offer itself (`LicenseOffer`) and what an alert says when activating or
//  deactivating fails (`PaywallCopy.failure(_:during:)`, PaywallFailure.swift).
//  Also the inspector's placeholder once the free HTTPS inspections are used
//  up, whose button opens the sheet.
//
//  The core draws these views and compiles in none of their words (PRD A1;
//  the paywall design of 2026-10-06): `PlanSheetContent+ReqRes.swift` maps
//  this file into the core's `PlanSheetContent` with no string of its own.
//  Two rules, as in LicenseOffer:
//
//   1. Every number comes from `FreeTier` (what the gates enforce) or from
//      `LicenseOffer` (what the website sells). No number is typed into a
//      sentence: PaywallCopyTests reads this file's string literals and
//      refuses a digit in one.
//   2. Every line the website also prints is the website's, word for word
//      (PricingHero.tsx, LicenseSteps.tsx, CheckoutForm.tsx), and
//      PaywallWebsiteParityTests compares them with the website's files.
//
//  None of these words says how or when the license is checked.
//

import Foundation

/// What opened the ReqRes Pro sheet: the free limit the person just reached.
///
/// The raw values are the ids of `PaywallCopy.gains`, so the sheet can put
/// "Reached" on that row (`reachedGainID`). The sheet shown at launch, from
/// the sidebar's Free Version, or from the toolbar gauge while inspections
/// are left, has no trigger.
public enum PaywallTrigger: String, CaseIterable, Sendable {
    case hostFilters
    case rules
    case httpsInspections
}

public enum PaywallCopy {
    // MARK: - The pieces

    /// One limit a license lifts: what you get, a line about it, and the free
    /// version's limit for the margin.
    public struct Gain: Equatable, Sendable {
        /// A `PaywallTrigger` raw value.
        public let id: String
        /// An SF Symbol name.
        public let symbol: String
        public let title: String
        public let detail: String
        public let freeNote: String

        public init(id: String, symbol: String, title: String, detail: String, freeNote: String) {
            self.id = id
            self.symbol = symbol
            self.title = title
            self.detail = detail
            self.freeNote = freeNote
        }
    }

    /// One step of "How a license works"; `number` is the one shown.
    public struct Step: Equatable, Sendable {
        public let number: Int
        public let title: String
        public let body: String

        public init(number: Int, title: String, body: String) {
            self.number = number
            self.title = title
            self.body = body
        }
    }

    /// A fact next to Buy: an SF Symbol, the words, and the page they link
    /// to, when they are a link.
    public struct Fact: Equatable, Sendable {
        public let symbol: String
        public let text: String
        public let url: URL?

        public init(symbol: String, text: String, url: URL?) {
            self.symbol = symbol
            self.text = text
            self.url = url
        }
    }

    /// A link that opens a page in the browser.
    public struct Link: Equatable, Sendable {
        public let title: String
        public let url: URL

        public init(title: String, url: URL) {
            self.title = title
            self.url = url
        }
    }

    // MARK: - What a license lifts

    /// The free version's 3 limits, as what a license gives, in the order the
    /// website names them. Each free note is built from its `FreeTier`
    /// constant, which is what the gates enforce.
    public static var gains: [Gain] {
        let nbsp = CopyText.nbsp
        return [
            Gain(id: PaywallTrigger.hostFilters.rawValue,
                 symbol: "globe",
                 title: "Unlimited host filters",
                 detail: "Give every host its own entry in the sidebar",
                 freeNote: "Free: \(FreeTier.hostFilters)"),
            // An agent hits the same limit: MCPFreeTier.rules is
            // FreeTier.overrideRules (MCPWriteAdapters).
            Gain(id: PaywallTrigger.rules.rawValue,
                 symbol: "arrow.triangle.branch",
                 title: "Unlimited rules",
                 detail: "Extend, Override and Map Local, made by you or your AI\(nbsp)agent",
                 freeNote: "Free: \(FreeTier.overrideRules)\(nbsp)in\(nbsp)total"),
            // "Opening": relayed, SSL-pinned and pre-certificate rows are not
            // opened in the inspector, with a license or without one
            // (FreeTier.detailAccess).
            Gain(id: PaywallTrigger.httpsInspections.rawValue,
                 symbol: "doc.text.magnifyingglass",
                 title: "Unlimited HTTPS inspections",
                 detail: "No limit on opening HTTPS requests in the inspector",
                 freeNote: "Free: \(FreeTier.httpsSessionDetailsPerLaunch)\(nbsp)per\(nbsp)launch"),
        ]
    }

    /// Over the gains: the first clause of the website hero's sentence.
    public static var gainsTitle: String { gainsTitle(count: gains.count) }

    static func gainsTitle(count: Int) -> String {
        "Lifts the \(count) \(count == 1 ? "limit" : "limits") of the free version"
    }

    /// Under the gains: the last sentence of the website hero's.
    public static let gainsNote = "Everything else is already free."

    /// After `gainsNote`: the website's list of every feature, on the page
    /// Buy opens (`id="everything-heading"` in EverythingInReqRes.tsx).
    public static let allFeaturesTitle = "See every feature"
    public static let allFeaturesURL = URL(string: "https://reqresapp.com/pricing/#everything-heading")!

    /// The capsule after the free note of the limit that opened the sheet.
    public static let reachedBadge = "Reached"

    // MARK: - How a license works

    public static let stepsTitle = "How a license works"

    /// The website's steps 1–3 (LicenseSteps.tsx). Step 3's body is the app's
    /// own: it names the sheet's Activate License… button.
    public static var steps: [Step] {
        [
            Step(number: 1,
                 title: "Pick how many people",
                 body: "Paddle takes the payment and adds the tax for your country."),
            Step(number: 2,
                 title: "The key arrives by email",
                 body: "It is also on the page you land on after checkout."),
            Step(number: 3,
                 title: activateStepTitle(macs: LicenseOffer.macsPerLicense),
                 body: "Click Activate License and enter the key."),
        ]
    }

    static func activateStepTitle(macs: Int) -> String {
        "Activate on up to \(CopyText.count(macs, "Mac", "Macs"))"
    }

    /// What VoiceOver says for a step's number, before its title: "Step 1".
    /// The ring on screen shows the number alone.
    public static func stepNumber(_ number: Int) -> String { "Step \(number)" }

    // MARK: - Next to Buy

    public static let refundURL = URL(string: "https://reqresapp.com/refund-policy/")!

    /// The sheet's facts: the 2 of the website's 4 trust facts that its steps
    /// do not already say (the steps name Paddle and the key by email).
    public static var sheetFacts: [Fact] { [refundFact, noSubscriptionFact] }

    /// Settings shows no steps, so it carries all 4 trust facts, in the
    /// website's order (CheckoutForm.tsx `trust`).
    public static var settingsFacts: [Fact] {
        [
            Fact(symbol: "checkmark.shield", text: "Checkout by Paddle", url: nil),
            refundFact,
            noSubscriptionFact,
            Fact(symbol: "key", text: "Key by email and on screen", url: nil),
        ]
    }

    private static var refundFact: Fact {
        Fact(symbol: "arrow.uturn.backward", text: "\(LicenseOffer.refundDays) days money back", url: refundURL)
    }

    private static let noSubscriptionFact = Fact(symbol: "nosign", text: "No subscription, no account", url: nil)

    public static let licenseAgreementURL = URL(string: "https://reqresapp.com/eula/")!
    public static let termsOfServiceURL = URL(string: "https://reqresapp.com/terms-of-service/")!
    public static let privacyPolicyURL = URL(string: "https://reqresapp.com/privacy-policy/")!

    /// The website's acceptance sentence under its Buy (CheckoutForm.tsx), as
    /// Markdown with its 2 links: `AttributedString(markdown:)` reads it.
    public static var acceptanceMarkdown: String {
        "Buying means you accept the [license agreement](\(licenseAgreementURL.absoluteString)) "
            + "and the [terms of service](\(termsOfServiceURL.absoluteString))."
    }

    /// The last line of Settings ▸ License, in both states.
    public static var legalLinks: [Link] {
        [
            Link(title: "License Agreement", url: licenseAgreementURL),
            Link(title: "Terms of Service", url: termsOfServiceURL),
            Link(title: "Privacy Policy", url: privacyPolicyURL),
        ]
    }

    // MARK: - The buttons

    /// The sheet's default button, and the Settings pane's Buy (with no
    /// keyboard shortcut there). It only opens a page: no money moves in the app.
    public static let buyTitle = "Buy a License"
    public static let buyURL = URL(string: "https://reqresapp.com/pricing/")!

    /// VoiceOver's hint on Buy.
    public static var buyHint: String { "Opens \(shownAddress(buyURL)) in your browser" }

    /// VoiceOver's hint on every other control that opens a page.
    public static let browserHint = "Opens in your browser"

    /// The sheet's leading button: it opens the Activate License sheet.
    public static let activateTitle = "Activate License…"

    /// Esc on the sheet.
    public static let continueTitle = "Continue with Free Version"

    /// The sheet's only button after an activation made in it.
    public static let doneTitle = "Done"

    /// Settings ▸ License's capsule without a license: the sidebar footer's
    /// badge words (`TrialBadge`).
    public static let freeBadge = "Free Version"

    /// The Activate License sheet's and the deactivate confirmation's cancel.
    public static let cancelButton = "Cancel"

    // MARK: - The license key (Settings ▸ License and the Activate License sheet)

    public static let keySheetTitle = "Activate License"
    public static let keyLabel = "License key"

    /// The key field's prompt: the shape of every license key.
    public static let keyPrompt = "XXXXX-XXXXX-XXXXX-XXXXX"

    /// Disabled while the field is empty; Return in the field is the same.
    public static let activateButton = "Activate"

    /// Under the key field. The second sentence is the website's step 3.
    public static var activationNote: String { activationNote(macs: LicenseOffer.macsPerLicense) }

    static func activationNote(macs: Int) -> String {
        "Enter the key from your email. Each license covers \(CopyText.count(macs, "Mac", "Macs")) at once."
    }

    // MARK: - While a license call is out, and after a deactivation

    public static let activatingProgress = "Activating…"
    public static let deactivatingProgress = "Deactivating…"

    /// Settings ▸ License, once Deactivate this Mac… has worked.
    public static let deactivatedNote = "This Mac is back on the free version."

    // MARK: - Licensed: the sheet after an activation made in it, and Settings

    public static let activeBadge = "Active"

    /// True of a bought, a comp and a promo license alike: never "Thank you
    /// for buying".
    public static let activeLine = "Pro is active on this Mac."

    public static let licenseSectionTitle = "License"
    public static let macsInUseLabel = "Macs in use"

    /// "1 of 2": the Macs on this license now, as the license server's answer
    /// counts them, of the limit its signed entitlement names. The count comes
    /// only with an answer this session: until the first one (Pro from the
    /// stored record, offline or before the server has answered) the count is
    /// unknown and the core hides the row (`PaywallModel.licenceDetailsKnown`).
    public static func macsInUse(_ count: Int, of limit: Int) -> String { "\(count) of \(limit)" }

    /// The label of the row whose value is `LicenseOffer.licensedTerm`.
    public static let termLabel = "Term"

    public static let macsSectionTitle = "Macs"
    public static let thisMacTitle = "This Mac"
    public static let thisMacNote = "Returns this Mac to the free version and frees its place on your license."

    /// The button as a sentence names it, with no ellipsis: the device-limit
    /// message (A8) and the docs.
    public static let deactivateName = "Deactivate this Mac"
    public static let deactivateTitle = deactivateName + "…"
    public static let deactivateConfirmTitle = "Deactivate ReqRes on this Mac?"
    public static let deactivateConfirmMessage = "This Mac returns to the free version and its place on your license is freed. "
        + "You can activate it again with your key."
    public static let deactivateConfirmButton = "Deactivate"

    public static let allMacsTitle = "All your Macs"
    public static var allMacsNote: String {
        "See every Mac on your license and remove one at \(shownAddress(licensePageURL))."
    }

    /// The button's title is the one the docs name. The device-limit alert
    /// offers it, and its message names the page the button opens.
    public static let manageTitle = "Manage your Macs…"
    public static let licensePageURL = URL(string: "https://reqresapp.com/license/")!

    // MARK: - The inspector, once the free HTTPS inspections are used up

    /// The detail pane's placeholder when this launch's free HTTPS
    /// inspections are used up. Its button opens the sheet with Reached on
    /// Unlimited HTTPS inspections (`PaywallTrigger.httpsInspections`). Its
    /// noun is that gain's and the toolbar gauge's, and it says the limit is
    /// per launch, as they do. Inspecting HTTPS is not a Pro feature: the free
    /// version includes some, and a license lifts the limit.
    public static let inspectionLimitTitle = "No Free HTTPS Inspections Left"

    public static var inspectionLimitMessage: String {
        inspectionLimitMessage(count: FreeTier.httpsSessionDetailsPerLaunch)
    }

    /// The sentence the host-filter and rule forms say at their limits, for
    /// `count` inspections.
    static func inspectionLimitMessage(count: Int) -> String {
        "The free version includes \(CopyText.count(count, "HTTPS inspection", "HTTPS inspections")) per launch. "
            + "Upgrade for unlimited HTTPS inspections."
    }

    /// It opens the sheet, so it ends with an ellipsis, as the host-filter
    /// and rule forms' Upgrade… buttons do.
    public static let inspectionLimitButton = "Upgrade…"

    // MARK: - A link the system did not open

    /// The alert shown when the system does not open a link, a page or a
    /// mail to support, so the person can still get there: the link is
    /// copied, or typed from the message. True of both kinds, so it names
    /// neither the browser nor the email app.
    public static let linkFailureTitle = "Couldn’t open that link"

    /// "Open reqresapp.com/pricing/ in your browser.": the page's address as
    /// a person would type it. A mail link names the address to write to.
    public static func linkFailureMessage(_ url: URL) -> String {
        if url.scheme?.lowercased() == "mailto",
           let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
           !address.isEmpty {
            return "Write to \(address) from your email app."
        }
        return "Open \(shownAddress(url)) in your browser."
    }

    public static let linkFailureCopyButton = "Copy Link"
    public static let linkFailureDismissButton = "OK"

    /// How a sentence writes a page's address: the host (and a port, if any)
    /// and the path, with no scheme, query or fragment, so
    /// https://reqresapp.com/pricing/#everything-heading is
    /// "reqresapp.com/pricing/". A link with no host is written whole.
    public static func shownAddress(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let host = components.host, !host.isEmpty else {
            return url.absoluteString
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return host + port + components.path
    }
}

/// Text helpers shared by `LicenseOffer` and `PaywallCopy`.
enum CopyText {
    /// A no-break space (U+00A0): invisible on screen, it keeps the words on
    /// either side on one line, as the website does.
    static let nbsp = "\u{00A0}"

    /// "1 Mac", "2 Macs": the number bound to its noun by a no-break space.
    static func count(_ number: Int, _ one: String, _ many: String) -> String {
        "\(number)\(nbsp)\(number == 1 ? one : many)"
    }
}
