//
//  PaywallCopyTests.swift
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
//  The words of the ReqRes Pro sheet, the licensed sheet, Settings ▸ License
//  and the Activate License sheet (`PaywallCopy`; the paywall design of
//  2026-10-06, "Copy deck"), pinned word for word. Every number is computed
//  here from the constant the copy must read (`FreeTier`, `LicenseOffer`),
//  and the source files are read to make sure no number is typed into a
//  sentence. What a failed activation or deactivation says has its own rules
//  and tests (PaywallFailureCopyTests); the lines the website prints too are
//  compared with its files in PaywallWebsiteParityTests.
//

import XCTest
@testable import Utils

final class PaywallCopyTests: XCTestCase {
    private let nbsp = "\u{00A0}"

    // MARK: - What a license lifts

    func testEachFreeNoteIsBuiltFromItsFreeTierConstant() {
        let notes = Dictionary(uniqueKeysWithValues: PaywallCopy.gains.map { ($0.id, $0.freeNote) })
        XCTAssertEqual(notes[PaywallTrigger.hostFilters.rawValue], "Free: \(FreeTier.hostFilters)")
        XCTAssertEqual(notes[PaywallTrigger.rules.rawValue],
                       "Free: \(FreeTier.overrideRules)\(nbsp)in\(nbsp)total")
        XCTAssertEqual(notes[PaywallTrigger.httpsInspections.rawValue],
                       "Free: \(FreeTier.httpsSessionDetailsPerLaunch)\(nbsp)per\(nbsp)launch")
    }

    func testTheGainsSayExactlyThis() {
        XCTAssertEqual(PaywallCopy.gains.map(\.title),
                       ["Unlimited host filters", "Unlimited rules", "Unlimited HTTPS inspections"])
        XCTAssertEqual(PaywallCopy.gains.map(\.detail), [
            "Give every host its own entry in the sidebar",
            "Extend, Override and Map Local, made by you or your AI\(nbsp)agent",
            "No limit on opening HTTPS requests in the inspector",
        ])
        XCTAssertEqual(PaywallCopy.gains.map(\.symbol),
                       ["globe", "arrow.triangle.branch", "doc.text.magnifyingglass"])
    }

    /// The ids are the triggers' raw values, so a limit's Upgrade… marks its
    /// own row; and they are stable from one read to the next (the old
    /// `Gain.id = UUID()` was not).
    func testTheGainIDsAreTheTriggers() {
        XCTAssertEqual(PaywallCopy.gains.map(\.id), PaywallTrigger.allCases.map(\.rawValue))
        XCTAssertEqual(PaywallTrigger.allCases.map(\.rawValue), ["hostFilters", "rules", "httpsInspections"])
        XCTAssertEqual(PaywallCopy.gains, PaywallCopy.gains)
    }

    func testTheGainsTitleCountsTheGains() {
        XCTAssertEqual(PaywallCopy.gainsTitle, "Lifts the \(PaywallCopy.gains.count) limits of the free version")
        XCTAssertEqual(PaywallCopy.gainsTitle(count: 1), "Lifts the 1 limit of the free version")
        XCTAssertEqual(PaywallCopy.gainsTitle(count: 2), "Lifts the 2 limits of the free version")
        XCTAssertEqual(PaywallCopy.gainsNote, "Everything else is already free.")
        XCTAssertEqual(PaywallCopy.allFeaturesTitle, "See every feature")
        XCTAssertEqual(PaywallCopy.allFeaturesURL.absoluteString, "https://reqresapp.com/pricing/#everything-heading")
        XCTAssertEqual(PaywallCopy.reachedBadge, "Reached")
    }

    // MARK: - How a license works

    func testTheStepsAreTheWebsites() {
        XCTAssertEqual(PaywallCopy.stepsTitle, "How a license works")
        XCTAssertEqual(PaywallCopy.steps.map(\.number), Array(1...PaywallCopy.steps.count))
        XCTAssertEqual(PaywallCopy.steps.map(\.title), [
            "Pick how many people",
            "The key arrives by email",
            "Activate on up to \(LicenseOffer.macsPerLicense)\(nbsp)Macs",
        ])
        XCTAssertEqual(PaywallCopy.steps.map(\.body), [
            "Paddle takes the payment and adds the tax for your country.",
            "It is also on the page you land on after checkout.",
            "Click Activate License and enter the key.",
        ])
    }

    /// What VoiceOver says before each step's title: "Step 1", where the ring
    /// on screen shows the number alone.
    func testEachStepIsSpokenWithItsNumber() {
        XCTAssertEqual(PaywallCopy.stepNumber(1), "Step 1")
        XCTAssertEqual(PaywallCopy.stepNumber(12), "Step 12")
        XCTAssertEqual(PaywallCopy.steps.map { PaywallCopy.stepNumber($0.number) }, ["Step 1", "Step 2", "Step 3"])
    }

    /// Step 3 names the sheet's own button, without its ellipsis.
    func testStepThreeNamesTheActivateButton() throws {
        let button = PaywallCopy.activateTitle.replacingOccurrences(of: "…", with: "")
        let step = try XCTUnwrap(PaywallCopy.steps.last)
        XCTAssertTrue(step.body.hasPrefix("Click \(button) "), step.body)
    }

    /// 1 Mac, 2 Macs: step 3 and the note under the key field follow the
    /// number of Macs a license covers.
    func testThePluralsFollowTheNumberOfMacs() {
        XCTAssertEqual(PaywallCopy.activateStepTitle(macs: 1), "Activate on up to 1\(nbsp)Mac")
        XCTAssertEqual(PaywallCopy.activateStepTitle(macs: 2), "Activate on up to 2\(nbsp)Macs")
        XCTAssertEqual(PaywallCopy.activationNote(macs: 1),
                       "Enter the key from your email. Each license covers 1\(nbsp)Mac at once.")
        XCTAssertEqual(PaywallCopy.activationNote(macs: 2),
                       "Enter the key from your email. Each license covers 2\(nbsp)Macs at once.")
        XCTAssertEqual(PaywallCopy.steps.last?.title, PaywallCopy.activateStepTitle(macs: LicenseOffer.macsPerLicense))
        XCTAssertEqual(PaywallCopy.activationNote, PaywallCopy.activationNote(macs: LicenseOffer.macsPerLicense))
    }

    // MARK: - Next to Buy

    /// Settings shows the website's 4 trust facts, in its order (CheckoutForm.tsx).
    func testTheSettingsFactsAreTheWebsitesFourInOrder() {
        XCTAssertEqual(PaywallCopy.settingsFacts.map(\.text), [
            "Checkout by Paddle",
            "\(LicenseOffer.refundDays) days money back",
            "No subscription, no account",
            "Key by email and on screen",
        ])
        XCTAssertEqual(PaywallCopy.settingsFacts.map(\.symbol), ["checkmark.shield", "arrow.uturn.backward", "nosign", "key"])
        XCTAssertEqual(PaywallCopy.settingsFacts.map(\.url), [nil, PaywallCopy.refundURL, nil, nil])
        XCTAssertEqual(PaywallCopy.refundURL.absoluteString, "https://reqresapp.com/refund-policy/")
    }

    /// The sheet's facts are Settings' facts that its steps do not already
    /// say: steps 1 and 2 name Paddle and the key by email.
    func testTheSheetsFactsAreTheOnesItsStepsDoNotSay() {
        for fact in PaywallCopy.sheetFacts {
            XCTAssertTrue(PaywallCopy.settingsFacts.contains(fact), "\(fact.text) is not a Settings fact")
        }
        XCTAssertEqual(PaywallCopy.sheetFacts.map(\.text),
                       ["\(LicenseOffer.refundDays) days money back", "No subscription, no account"])
        let steps = PaywallCopy.steps.map { "\($0.title) \($0.body)" }.joined(separator: " ")
        XCTAssertTrue(steps.contains("Paddle"))
        XCTAssertTrue(steps.contains("email"))
    }

    func testTheAcceptanceSentenceAndItsLinks() throws {
        let acceptance = try AttributedString(markdown: PaywallCopy.acceptanceMarkdown)
        XCTAssertEqual(String(acceptance.characters),
                       "Buying means you accept the license agreement and the terms of service.")
        var links: [String: URL] = [:]
        for run in acceptance.runs {
            if let url = run.link {
                links[String(acceptance[run.range].characters)] = url
            }
        }
        XCTAssertEqual(links, ["license agreement": PaywallCopy.licenseAgreementURL,
                               "terms of service": PaywallCopy.termsOfServiceURL])
    }

    /// "License Agreement" opens /eula/ and "Terms of Service" the terms: the
    /// old sheet's "Terms of Service" opened /eula/.
    func testTheLegalLinks() {
        XCTAssertEqual(PaywallCopy.legalLinks.map(\.title), ["License Agreement", "Terms of Service", "Privacy Policy"])
        XCTAssertEqual(PaywallCopy.legalLinks.map(\.url.absoluteString), [
            "https://reqresapp.com/eula/",
            "https://reqresapp.com/terms-of-service/",
            "https://reqresapp.com/privacy-policy/",
        ])
    }

    /// Every page the sheet and Settings open is on reqresapp.com, with the
    /// trailing slash the site serves its pages at (`trailingSlash: true`).
    func testEveryPageOpenedIsOnTheWebsite() {
        for url in pagesOpened {
            XCTAssertEqual(url.scheme, "https", url.absoluteString)
            XCTAssertEqual(url.host, "reqresapp.com", url.absoluteString)
            XCTAssertNil(url.query, url.absoluteString)
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
            XCTAssertTrue(path.hasPrefix("/") && path.hasSuffix("/"), url.absoluteString)
        }
    }

    // MARK: - Buttons, the key, progress

    func testTheButtonsSayExactlyThis() {
        XCTAssertEqual(PaywallCopy.buyTitle, "Buy a License")
        XCTAssertEqual(PaywallCopy.buyURL.absoluteString, "https://reqresapp.com/pricing/")
        XCTAssertEqual(PaywallCopy.buyHint, "Opens reqresapp.com/pricing/ in your browser")
        XCTAssertEqual(PaywallCopy.browserHint, "Opens in your browser")
        XCTAssertEqual(PaywallCopy.activateTitle, "Activate License…")
        XCTAssertEqual(PaywallCopy.continueTitle, "Continue with Free Version")
        XCTAssertEqual(PaywallCopy.doneTitle, "Done")
        XCTAssertEqual(PaywallCopy.freeBadge, "Free Version")
        XCTAssertEqual(PaywallCopy.cancelButton, "Cancel")
    }

    /// The Activate License sheet and the key row in Settings.
    func testTheKeyEntrySaysExactlyThis() {
        XCTAssertEqual(PaywallCopy.keySheetTitle, "Activate License")
        XCTAssertEqual(PaywallCopy.keyLabel, "License key")
        XCTAssertEqual(PaywallCopy.keyPrompt, "XXXXX-XXXXX-XXXXX-XXXXX")
        XCTAssertEqual(PaywallCopy.activateButton, "Activate")
        XCTAssertEqual(PaywallCopy.activationNote,
                       "Enter the key from your email. Each license covers \(LicenseOffer.macsPerLicense)\(nbsp)Macs at once.")
    }

    func testTheProgressAndTheDeactivatedNote() {
        XCTAssertEqual(PaywallCopy.activatingProgress, "Activating…")
        XCTAssertEqual(PaywallCopy.deactivatingProgress, "Deactivating…")
        XCTAssertEqual(PaywallCopy.deactivatedNote, "This Mac is back on the free version.")
    }

    // MARK: - Licensed

    func testTheLicensedWordsSayExactlyThis() {
        XCTAssertEqual(PaywallCopy.activeBadge, "Active")
        XCTAssertEqual(PaywallCopy.activeLine, "Pro is active on this Mac.")
        XCTAssertEqual(PaywallCopy.licenseSectionTitle, "License")
        XCTAssertEqual(PaywallCopy.macsInUseLabel, "Macs in use")
        XCTAssertEqual(PaywallCopy.macsInUse(1, of: LicenseOffer.macsPerLicense), "1 of \(LicenseOffer.macsPerLicense)")
        XCTAssertEqual(PaywallCopy.macsInUse(3, of: 10), "3 of 10")
        XCTAssertEqual(PaywallCopy.termLabel, "Term")
        XCTAssertEqual(PaywallCopy.macsSectionTitle, "Macs")
        XCTAssertEqual(PaywallCopy.thisMacTitle, "This Mac")
        XCTAssertEqual(PaywallCopy.thisMacNote,
                       "Returns this Mac to the free version and frees its place on your license.")
        XCTAssertEqual(PaywallCopy.deactivateTitle, "Deactivate this Mac…")
        XCTAssertEqual(PaywallCopy.deactivateName, "Deactivate this Mac")
        XCTAssertEqual(PaywallCopy.deactivateConfirmTitle, "Deactivate ReqRes on this Mac?")
        XCTAssertEqual(PaywallCopy.deactivateConfirmMessage,
                       "This Mac returns to the free version and its place on your license is freed. "
                           + "You can activate it again with your key.")
        XCTAssertEqual(PaywallCopy.deactivateConfirmButton, "Deactivate")
        XCTAssertEqual(PaywallCopy.allMacsTitle, "All your Macs")
        XCTAssertEqual(PaywallCopy.allMacsNote,
                       "See every Mac on your license and remove one at reqresapp.com/license/.")
        XCTAssertEqual(PaywallCopy.manageTitle, "Manage your Macs…")
        XCTAssertEqual(PaywallCopy.licensePageURL.absoluteString, "https://reqresapp.com/license/")
    }

    /// The inspector's placeholder once the free HTTPS inspections are used
    /// up, in the sheet's words: the gain's noun, "per launch" as the gain and
    /// the gauge say it, the number read from the limit the inspector
    /// enforces, and the sentence the host-filter and rule forms say at their
    /// own limits. The free version inspects HTTPS too, so it is never a "Pro
    /// Feature".
    func testTheInspectorsLimitPlaceholderSaysExactlyThis() throws {
        XCTAssertEqual(PaywallCopy.inspectionLimitTitle, "No Free HTTPS Inspections Left")
        let count = FreeTier.httpsSessionDetailsPerLaunch
        XCTAssertEqual(PaywallCopy.inspectionLimitMessage,
                       "The free version includes \(count)\(nbsp)HTTPS inspections per launch. "
                           + "Upgrade for unlimited HTTPS inspections.")
        XCTAssertEqual(PaywallCopy.inspectionLimitMessage(count: 1),
                       "The free version includes 1\(nbsp)HTTPS inspection per launch. "
                           + "Upgrade for unlimited HTTPS inspections.")
        XCTAssertEqual(PaywallCopy.inspectionLimitMessage(count: 10),
                       "The free version includes 10\(nbsp)HTTPS inspections per launch. "
                           + "Upgrade for unlimited HTTPS inspections.")
        XCTAssertEqual(PaywallCopy.inspectionLimitButton, "Upgrade…")

        // The gain the button marks Reached: its noun, and its "per launch".
        let gain = try XCTUnwrap(PaywallCopy.gains.first { $0.id == PaywallTrigger.httpsInspections.rawValue })
        XCTAssertTrue(gain.title.hasPrefix("Unlimited "), gain.title)
        let noun = String(gain.title.dropFirst("Unlimited ".count))
        XCTAssertEqual(noun, "HTTPS inspections")
        XCTAssertTrue(PaywallCopy.inspectionLimitMessage.contains("\(count)\(nbsp)\(noun) per launch. "))
        XCTAssertTrue(PaywallCopy.inspectionLimitMessage.hasSuffix("Upgrade for unlimited \(noun)."))
        XCTAssertTrue(gain.freeNote.hasSuffix("\(nbsp)per\(nbsp)launch"))
        XCTAssertTrue(PaywallCopy.inspectionLimitTitle.lowercased().contains(noun.lowercased()))
    }

    /// The words the redesign replaced stay gone: the placeholder's "Pro
    /// Feature" and "session details", "premium", the link alert's browser.
    func testTheOldWordsAreGone() {
        for string in paywallStrings + offerStrings {
            for old in ["Pro Feature", "session details", "premium", "Upgrade Now", "Upgrade now",
                        "Couldn’t open your browser"] {
                XCTAssertFalse(string.contains(old), "'\(string)' says '\(old)'")
            }
        }
    }

    /// Never "Thank you for buying": comp and promo licenses were not bought.
    func testTheLicensedSheetThanksNobody() {
        for string in [PaywallCopy.activeLine, PaywallCopy.activeBadge, PaywallCopy.doneTitle] {
            XCTAssertFalse(string.lowercased().contains("thank"), string)
            XCTAssertFalse(string.lowercased().contains("purchas"), string)
        }
    }

    // MARK: - A link the system did not open

    /// The title is true of a page and of a mail to support alike, so it
    /// names neither the browser nor the email app; the message names the
    /// address to type, or the address to write to.
    func testTheLinkFailureNamesTheAddressToType() throws {
        XCTAssertEqual(PaywallCopy.linkFailureTitle, "Couldn’t open that link")
        for word in ["browser", "email", "mail"] {
            XCTAssertFalse(PaywallCopy.linkFailureTitle.lowercased().contains(word))
        }
        XCTAssertEqual(PaywallCopy.linkFailureCopyButton, "Copy Link")
        XCTAssertEqual(PaywallCopy.linkFailureDismissButton, "OK")
        XCTAssertEqual(PaywallCopy.linkFailureMessage(PaywallCopy.buyURL),
                       "Open reqresapp.com/pricing/ in your browser.")
        XCTAssertEqual(PaywallCopy.linkFailureMessage(PaywallCopy.licensePageURL),
                       "Open reqresapp.com/license/ in your browser.")
        // A query and a fragment are the copied link's business, not the sentence's.
        XCTAssertEqual(PaywallCopy.linkFailureMessage(try XCTUnwrap(URL(string: "https://reqresapp.com/pricing/?licenses=1"))),
                       "Open reqresapp.com/pricing/ in your browser.")
        XCTAssertEqual(PaywallCopy.linkFailureMessage(PaywallCopy.allFeaturesURL),
                       "Open reqresapp.com/pricing/ in your browser.")
        XCTAssertEqual(PaywallCopy.linkFailureMessage(try XCTUnwrap(URL(string: "https://reqresapp.com"))),
                       "Open reqresapp.com in your browser.")
        XCTAssertEqual(PaywallCopy.linkFailureMessage(try XCTUnwrap(URL(string: "http://localhost:3000/api/"))),
                       "Open localhost:3000/api/ in your browser.")
        XCTAssertEqual(PaywallCopy.linkFailureMessage(PaywallCopy.supportURL),
                       "Write to support@oloapps.com from your email app.")
    }

    func testTheShownAddressIsHostAndPath() throws {
        XCTAssertEqual(PaywallCopy.shownAddress(PaywallCopy.allFeaturesURL), "reqresapp.com/pricing/")
        XCTAssertEqual(PaywallCopy.shownAddress(PaywallCopy.downloadPageURL), "reqresapp.com/docs/getting-started/install/")
        XCTAssertEqual(PaywallCopy.shownAddress(try XCTUnwrap(URL(string: "https://reqresapp.com/a%20b/"))), "reqresapp.com/a b/")
        XCTAssertEqual(PaywallCopy.shownAddress(PaywallCopy.supportURL), "mailto:support@oloapps.com")
    }

    // MARK: - Every string

    /// No price but `LicenseOffer.price`, and nothing about how or when the
    /// license is checked ("check" alone is allowed: "Checkout by Paddle").
    func testNoStringNamesAPriceOrSaysHowTheLicenseIsChecked() {
        for string in paywallStrings {
            XCTAssertNil(string.range(of: #"\$[0-9]"#, options: .regularExpression), "a price in '\(string)'")
        }
        for string in paywallStrings + offerStrings {
            let plain = string.replacingOccurrences(of: nbsp, with: " ").lowercased()
            for word in ["online", "offline", "internet", "serial", "checks", "once a day", "30 days"] {
                XCTAssertFalse(plain.contains(word), "'\(string)' says '\(word)'")
            }
        }
    }

    /// The typographic apostrophe and ellipsis, single spaces, nothing to trim.
    func testTheTypographyIsTheDesigns() {
        for string in paywallStrings + offerStrings {
            XCTAssertFalse(string.contains("'"), "a straight apostrophe in '\(string)'")
            XCTAssertFalse(string.contains("\""), "a straight quote in '\(string)'")
            XCTAssertFalse(string.contains("..."), "three dots for an ellipsis in '\(string)'")
            XCTAssertFalse(string.contains("  "), "two spaces in '\(string)'")
            XCTAssertEqual(string, string.trimmingCharacters(in: .whitespacesAndNewlines), "'\(string)'")
        }
    }

    /// No number is typed into a sentence: in the files that hold the words,
    /// no string literal has a digit, so every number reaches a sentence
    /// through an interpolation of its constant. The one exception is the
    /// development server's address (a port, not a selling number).
    func testNoNumberIsTypedIntoASentence() throws {
        let allowed: Set<String> = ["REQRES_DEV_LICENSE_API=http://localhost:3000/api"]
        for file in ["LicenseOffer.swift", "PaywallCopy.swift", "PaywallFailure.swift"] {
            let source = try String(contentsOf: Self.utilsSources.appendingPathComponent(file), encoding: .utf8)
            let literals = try SwiftStringLiterals.scan(source)
            XCTAssertFalse(literals.isEmpty, "no string literal found in \(file)")
            for literal in literals where literal.contains(where: { $0.isASCII && $0.isNumber }) {
                XCTAssertTrue(allowed.contains(literal), "\(file): a number typed into \"\(literal)\"")
            }
        }
        // The scan does see the sentences.
        let copy = try SwiftStringLiterals.scan(
            String(contentsOf: Self.utilsSources.appendingPathComponent("PaywallCopy.swift"), encoding: .utf8))
        XCTAssertTrue(copy.contains("Unlimited host filters"))
        XCTAssertTrue(copy.contains("Free: "), "the free note's literal, without its interpolation")
    }

    /// The scanner itself: an interpolation's code is not literal text, its
    /// own string literals are, escapes are decoded, comments are skipped.
    func testTheStringLiteralScanner() throws {
        let source = #"""
        // "Free: 2" in a comment is not a literal
        let a = "Free: \(FreeTier.hostFilters)"
        let b = "Lifts the \(n) \(n == 1 ? "limit" : "limits") of the free version"
        /* "10" in a block comment */ let c = "a\u{00A0}b\"c\\d"
        let d = "Free: 2"
        """#
        XCTAssertEqual(try SwiftStringLiterals.scan(source), [
            "Free: ", "limit", "limits", "Lifts the   of the free version", "a\u{00A0}b\"c\\d", "Free: 2",
        ])
        XCTAssertThrowsError(try SwiftStringLiterals.scan("let s = \"\"\"\nmulti\n\"\"\""))
        XCTAssertThrowsError(try SwiftStringLiterals.scan(##"let s = #"raw"#"##))
        XCTAssertThrowsError(try SwiftStringLiterals.scan("let s = \"unterminated\nlet t = 1"))
    }

    // MARK: - Helpers

    private static var utilsSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .appendingPathComponent("Sources/Utils")
    }

    private var pagesOpened: [URL] {
        [PaywallCopy.allFeaturesURL, PaywallCopy.refundURL, PaywallCopy.buyURL, PaywallCopy.licensePageURL,
         PaywallCopy.licenseAgreementURL, PaywallCopy.termsOfServiceURL, PaywallCopy.privacyPolicyURL]
            + PaywallCopy.legalLinks.map(\.url)
            + PaywallCopy.settingsFacts.compactMap(\.url)
            + PaywallCopy.sheetFacts.compactMap(\.url)
    }

    /// Every word `PaywallCopy` supplies to the sheet, the licensed sheet,
    /// Settings ▸ License and the Activate License sheet.
    private var paywallStrings: [String] {
        var strings = [
            PaywallCopy.gainsTitle, PaywallCopy.gainsNote, PaywallCopy.allFeaturesTitle, PaywallCopy.reachedBadge,
            PaywallCopy.stepsTitle, PaywallCopy.acceptanceMarkdown,
            PaywallCopy.buyTitle, PaywallCopy.buyHint, PaywallCopy.browserHint, PaywallCopy.activateTitle,
            PaywallCopy.continueTitle, PaywallCopy.doneTitle, PaywallCopy.freeBadge, PaywallCopy.cancelButton,
            PaywallCopy.keySheetTitle, PaywallCopy.keyLabel, PaywallCopy.keyPrompt, PaywallCopy.activateButton,
            PaywallCopy.activationNote, PaywallCopy.activatingProgress, PaywallCopy.deactivatingProgress,
            PaywallCopy.deactivatedNote,
            PaywallCopy.activeBadge, PaywallCopy.activeLine, PaywallCopy.licenseSectionTitle, PaywallCopy.macsInUseLabel,
            PaywallCopy.macsInUse(1, of: LicenseOffer.macsPerLicense), PaywallCopy.termLabel,
            PaywallCopy.macsSectionTitle, PaywallCopy.thisMacTitle, PaywallCopy.thisMacNote,
            PaywallCopy.deactivateTitle, PaywallCopy.deactivateName, PaywallCopy.deactivateConfirmTitle,
            PaywallCopy.deactivateConfirmMessage,
            PaywallCopy.deactivateConfirmButton, PaywallCopy.allMacsTitle, PaywallCopy.allMacsNote,
            PaywallCopy.manageTitle, PaywallCopy.mailHint,
            PaywallCopy.linkFailureTitle, PaywallCopy.linkFailureCopyButton, PaywallCopy.linkFailureDismissButton,
            PaywallCopy.inspectionLimitTitle, PaywallCopy.inspectionLimitMessage, PaywallCopy.inspectionLimitButton,
        ]
        strings += pagesOpened.map(PaywallCopy.linkFailureMessage)
        strings += PaywallCopy.gains.flatMap { [$0.title, $0.detail, $0.freeNote] }
        strings += PaywallCopy.steps.flatMap { [$0.title, $0.body, PaywallCopy.stepNumber($0.number)] }
        strings += PaywallCopy.settingsFacts.map(\.text)
        strings += PaywallCopy.legalLinks.map(\.title)
        return strings
    }

    private var offerStrings: [String] {
        [LicenseOffer.title, LicenseOffer.price, LicenseOffer.headline, LicenseOffer.priceDetail,
         LicenseOffer.taxNote, LicenseOffer.licensedTerm]
    }
}

/// The text of every string literal in a Swift source file. An
/// interpolation's code is not literal text, but the string literals inside
/// it are (each its own entry); escapes are decoded; `//` and `/* */`
/// comments are skipped. A multi-line or raw literal is refused rather than
/// read wrong, so a file cannot slip a number past the scan by using one.
enum SwiftStringLiterals {
    struct Unsupported: Error, CustomStringConvertible {
        let description: String
    }

    static func scan(_ source: String) throws -> [String] {
        var reader = LiteralReader(characters: Array(source))
        try reader.code(untilCloseParenthesis: false)
        return reader.literals
    }

    private struct LiteralReader {
        let characters: [Character]
        var index = 0
        var literals: [String] = []

        init(characters: [Character]) {
            self.characters = characters
        }

        private func peek(_ offset: Int = 0) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        /// Code, up to the end of the file or, inside an interpolation, the
        /// parenthesis that closes it.
        mutating func code(untilCloseParenthesis: Bool) throws {
            var depth = 0
            while let character = peek() {
                switch character {
                case "/" where peek(1) == "/":
                    while let next = peek(), next != "\n" { index += 1 }
                case "/" where peek(1) == "*":
                    try blockComment()
                    continue
                case "#" where peek(1) == "\"" || peek(1) == "#":
                    throw Unsupported(description: "a raw string literal at character \(index)")
                case "\"":
                    if peek(1) == "\"" && peek(2) == "\"" {
                        throw Unsupported(description: "a multi-line string literal at character \(index)")
                    }
                    index += 1
                    literals.append(try literal())
                    continue
                case "(" where untilCloseParenthesis:
                    depth += 1
                case ")" where untilCloseParenthesis:
                    if depth == 0 {
                        index += 1
                        return
                    }
                    depth -= 1
                default:
                    break
                }
                index += 1
            }
            if untilCloseParenthesis {
                throw Unsupported(description: "an interpolation that never closes")
            }
        }

        /// A `/* … */` comment, which may nest.
        private mutating func blockComment() throws {
            var depth = 0
            while let character = peek() {
                if character == "/" && peek(1) == "*" {
                    depth += 1
                    index += 2
                } else if character == "*" && peek(1) == "/" {
                    depth -= 1
                    index += 2
                    if depth == 0 { return }
                } else {
                    index += 1
                }
            }
            throw Unsupported(description: "a block comment that never closes")
        }

        /// A single-line literal's text, from after its opening quote to its
        /// closing one.
        private mutating func literal() throws -> String {
            var text = ""
            while let character = peek() {
                switch character {
                case "\"":
                    index += 1
                    return text
                case "\n":
                    throw Unsupported(description: "a string literal that never closes")
                case "\\":
                    try escape(into: &text)
                default:
                    text.append(character)
                    index += 1
                }
            }
            throw Unsupported(description: "a string literal that never closes")
        }

        private mutating func escape(into text: inout String) throws {
            guard let next = peek(1) else { throw Unsupported(description: "an escape at the end of the file") }
            index += 2
            switch next {
            case "(":
                // The interpolation's code is not literal text; any string
                // literal inside it is read as one of its own.
                try code(untilCloseParenthesis: true)
            case "u":
                guard peek() == "{" else { throw Unsupported(description: "a \\u escape without braces") }
                var hex = ""
                index += 1
                while let character = peek(), character != "}" {
                    hex.append(character)
                    index += 1
                }
                index += 1
                guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
                    throw Unsupported(description: "a \\u escape that is not a scalar: \(hex)")
                }
                text.unicodeScalars.append(scalar)
            case "n": text.append("\n")
            case "t": text.append("\t")
            case "r": text.append("\r")
            case "0": text.append("\0")
            default: text.append(next)
            }
        }
    }
}
