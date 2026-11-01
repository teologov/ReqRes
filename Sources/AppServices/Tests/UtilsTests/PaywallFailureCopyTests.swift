//
//  PaywallFailureCopyTests.swift
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
//  What an alert says when activating a license or deactivating this Mac
//  fails (`PaywallCopy.failure(_:during:)`). Every failure, for both
//  operations, is pinned word for word, and each rule of PaywallFailure.swift
//  is asserted over all of them: short titles that blame nobody, one or two
//  sentences that say what did not change and what to do next, no word about
//  how or when the license is checked, a detail that never shows a key, a
//  device id, a serial number, a token or a nonce, Try Again only on a
//  deactivation a retry can fix, and buttons that open reqresapp.com (never
//  /pricing/) or write to support, each with VoiceOver's hint for where it
//  goes.
//

import XCTest
@testable import Utils

final class PaywallFailureCopyTests: XCTestCase {
    private let serverMessage = "Invalid or inactive license"
    private let errorDescription = "The data couldn’t be read because it isn’t in the correct format."

    // MARK: - Every failure, word for word

    func testEveryActivationFailureSaysExactlyThis() {
        let nothingChanged = "Nothing changed on this Mac."
        let expected: [(PaywallFailure, PaywallFailureCopy)] = [
            (.keyFormat, PaywallFailureCopy(
                title: "That isn’t a license key",
                message: "License keys look like \(PaywallCopy.keyPrompt). "
                    + "Copy the key from your purchase email and try again.")),
            (.keyNotAccepted(serverMessage: serverMessage), PaywallFailureCopy(
                title: "This key wasn’t accepted",
                message: "Check it against your purchase email. "
                    + "If it’s right, contact support and include the email you bought with.",
                detail: serverMessage,
                actions: [support])),
            (.keyNotAccepted(serverMessage: nil), PaywallFailureCopy(
                title: "This key wasn’t accepted",
                message: "Check it against your purchase email. "
                    + "If it’s right, contact support and include the email you bought with.",
                actions: [support])),
            (.licenseExpired, PaywallFailureCopy(
                title: "This license is no longer active",
                message: "Contact support and include the email you bought with. \(nothingChanged)",
                actions: [support])),
            (.deviceLimit(current: 2, limit: 2, canAdd: false), PaywallFailureCopy(
                title: "Device limit reached (2/2)",
                message: "Click Deactivate this Mac in Settings ▸ License on another Mac, then try again. "
                    + "Or remove a Mac at \(licensePage).",
                actions: [manage])),
            (.deviceLimit(current: 2, limit: 2, canAdd: true), PaywallFailureCopy(
                title: "Device limit reached (2/2)",
                message: "Click Deactivate this Mac in Settings ▸ License on another Mac, then try again. "
                    + "Or remove a Mac or add licenses at \(licensePage).",
                actions: [manage])),
            (.serverUnavailable, PaywallFailureCopy(
                title: "reqresapp.com didn’t answer",
                message: "\(nothingChanged) Try again in a minute.")),
            (.network(.offline), PaywallFailureCopy(
                title: "This Mac is offline",
                message: "Connect to the internet, then try again. \(nothingChanged)")),
            (.network(.timedOut), PaywallFailureCopy(
                title: "reqresapp.com took too long to answer",
                message: "\(nothingChanged) Try again in a minute.")),
            (.network(.other), PaywallFailureCopy(
                title: "ReqRes couldn’t reach reqresapp.com",
                message: "Check your network connection, then try again. \(nothingChanged)")),
            (.unverifiedAnswer, PaywallFailureCopy(
                title: "ReqRes couldn’t confirm the answer",
                message: "The answer from reqresapp.com couldn’t be confirmed, so nothing changed. "
                    + "Try again; if it keeps happening, contact support.",
                actions: [support])),
            (.unofficialBuild, unofficialBuild),
            (.noLicenceServer, noLicenceServer),
            (.notActivated, PaywallFailureCopy(
                title: "Activation didn’t work",
                message: "\(nothingChanged) Enter your license key, then try again.")),
            (.unknown(description: errorDescription), PaywallFailureCopy(
                title: "Activation didn’t work",
                message: "\(nothingChanged) Try again; if it keeps happening, contact support.",
                detail: errorDescription,
                actions: [support])),
        ]
        for (failure, copy) in expected {
            XCTAssertEqual(PaywallCopy.failure(failure, during: .activate), copy, "\(failure)")
        }
        XCTAssertEqual(Set(expected.map { caseName($0.0) }).count, Self.caseCount, "a case without its words")
    }

    func testEveryDeactivationFailureSaysExactlyThis() {
        let stillActive = "This Mac is still active"
        let notDeactivated = "reqresapp.com didn’t deactivate this Mac"
        let expected: [(PaywallFailure, PaywallFailureCopy)] = [
            (.keyFormat, PaywallFailureCopy(
                title: stillActive,
                message: "Its license key isn’t in the right form, so nothing changed. "
                    + "You can remove this Mac at \(licensePage).")),
            (.keyNotAccepted(serverMessage: serverMessage), PaywallFailureCopy(
                title: notDeactivated,
                message: "\(stillActive).",
                detail: serverMessage,
                actions: [support])),
            (.keyNotAccepted(serverMessage: nil), PaywallFailureCopy(
                title: notDeactivated,
                message: "\(stillActive).",
                actions: [support])),
            (.licenseExpired, PaywallFailureCopy(
                title: notDeactivated,
                message: "\(stillActive). Contact support and include the email you bought with.",
                actions: [support])),
            (.deviceLimit(current: 2, limit: 2, canAdd: false), PaywallFailureCopy(
                title: notDeactivated,
                message: "\(stillActive). You can remove a Mac at \(licensePage).",
                actions: [manage])),
            (.deviceLimit(current: 2, limit: 2, canAdd: true), PaywallFailureCopy(
                title: notDeactivated,
                message: "\(stillActive). You can remove a Mac at \(licensePage).",
                actions: [manage])),
            (.serverUnavailable, PaywallFailureCopy(
                title: stillActive,
                message: "reqresapp.com didn’t answer, so nothing changed. Try again in a minute.",
                actions: [tryAgain])),
            (.network(.offline), PaywallFailureCopy(
                title: stillActive,
                message: "This Mac is offline, so nothing changed. Connect to the internet, then try again.",
                actions: [tryAgain])),
            (.network(.timedOut), PaywallFailureCopy(
                title: stillActive,
                message: "reqresapp.com took too long to answer, so nothing changed. Try again in a minute.",
                actions: [tryAgain])),
            (.network(.other), PaywallFailureCopy(
                title: stillActive,
                message: "ReqRes couldn’t reach reqresapp.com, so nothing changed. "
                    + "Check your network connection, then try again.",
                actions: [tryAgain])),
            (.unverifiedAnswer, PaywallFailureCopy(
                title: stillActive,
                message: "The answer from reqresapp.com couldn’t be confirmed, so nothing changed. "
                    + "Try again; if it keeps happening, contact support.",
                actions: [tryAgain, support])),
            (.unofficialBuild, unofficialBuild),
            (.noLicenceServer, noLicenceServer),
            (.notActivated, PaywallFailureCopy(
                title: "This Mac has no license",
                message: "There’s nothing to deactivate.")),
            (.unknown(description: errorDescription), PaywallFailureCopy(
                title: stillActive,
                message: "Something went wrong, so nothing changed. Try again; if it keeps happening, contact support.",
                detail: errorDescription,
                actions: [tryAgain, support])),
        ]
        for (failure, copy) in expected {
            XCTAssertEqual(PaywallCopy.failure(failure, during: .deactivate), copy, "\(failure)")
        }
        XCTAssertEqual(Set(expected.map { caseName($0.0) }).count, Self.caseCount, "a case without its words")
    }

    /// "Device limit reached (2/2)", as the server, the core's own text and
    /// the docs say it (PRD A8): the Macs the server counted, its limit when
    /// the count is missing, of the limit; with no limit, no number at all.
    func testTheDeviceLimitTitleCountsTheMacsOfTheLimit() {
        let macs = LicenseOffer.macsPerLicense
        let titles: [(current: Int, limit: Int, title: String)] = [
            (1, 1, "Device limit reached (1/1)"),
            (2, 2, "Device limit reached (2/2)"),
            (0, macs, "Device limit reached (\(macs)/\(macs))"),
            (macs + 1, macs, "Device limit reached (\(macs + 1)/\(macs))"),
            (0, 0, "Device limit reached"),
            (1, 0, "Device limit reached"),
        ]
        for (current, limit, title) in titles {
            for canAdd in [false, true] {
                let failure = PaywallFailure.deviceLimit(current: current, limit: limit, canAdd: canAdd)
                XCTAssertEqual(PaywallCopy.failure(failure, during: .activate).title, title, "\(failure)")
            }
            XCTAssertEqual(PaywallCopy.deviceLimitTitle(current: current, limit: limit), title)
        }
        XCTAssertFalse(PaywallCopy.deviceLimitTitle(current: 0, limit: 0).contains(where: \.isNumber))
    }

    /// The message names the button that frees a place, as a sentence names
    /// it (the title without its ellipsis), where it is and on which Mac (A8),
    /// and the page that frees one from anywhere. Adding licenses is named
    /// only when the server says the key can take more, and then on that
    /// same page, which adds them to this key.
    func testTheDeviceLimitNamesTheButtonThePageAndAddingLicenses() {
        XCTAssertEqual(PaywallCopy.deactivateName, "Deactivate this Mac")
        XCTAssertEqual(PaywallCopy.deactivateTitle, PaywallCopy.deactivateName + "…")
        let anotherMac = "Click \(PaywallCopy.deactivateName) in Settings ▸ License on another Mac, then try again."
        for (current, limit) in [(1, 1), (2, 2), (0, 2), (3, 2), (0, 0)] {
            let kept = PaywallCopy.failure(.deviceLimit(current: current, limit: limit, canAdd: false), during: .activate)
            XCTAssertEqual(kept.message, "\(anotherMac) Or remove a Mac at \(licensePage).")
            let more = PaywallCopy.failure(.deviceLimit(current: current, limit: limit, canAdd: true), during: .activate)
            XCTAssertEqual(more.message, "\(anotherMac) Or remove a Mac or add licenses at \(licensePage).")
        }
        for failure in allFailures {
            for operation in PaywallOperation.allCases {
                let copy = PaywallCopy.failure(failure, during: operation)
                let adds = "\(copy.title) \(copy.message)".contains("add licenses")
                if case .deviceLimit(_, _, true) = failure, operation == .activate {
                    XCTAssertTrue(adds, "\(failure), \(operation)")
                } else {
                    XCTAssertFalse(adds, "\(failure), \(operation)")
                }
            }
        }
    }

    // MARK: - The buttons

    /// The Activate button is the retry: an activation failure never offers one.
    func testAnActivationFailureNeverOffersARetry() {
        for failure in allFailures {
            let actions = PaywallCopy.failure(failure, during: .activate).actions
            XCTAssertFalse(actions.contains(where: isRetry), "\(failure)")
        }
    }

    /// Exactly one Try Again, first, where trying again can work: no answer,
    /// an answer that could not be confirmed, or an unexpected error.
    func testADeactivationOffersOneRetryOnlyWhereARetryCanHelp() {
        for failure in allFailures {
            let actions = PaywallCopy.failure(failure, during: .deactivate).actions
            if retryCanHelp(failure) {
                XCTAssertEqual(actions.filter(isRetry), [tryAgain], "\(failure)")
                XCTAssertEqual(actions.first, tryAgain, "\(failure)")
            } else {
                XCTAssertEqual(actions.filter(isRetry), [], "\(failure)")
            }
        }
    }

    /// Manage your Macs… is the device limit's one button, whatever the
    /// count, the operation or the key: its page frees a place and, for a key
    /// that can take more, adds licenses to that key. No failure opens
    /// reqresapp.com/pricing/, which sells a second key that the activation
    /// still trying the first one would never use.
    func testTheDeviceLimitOffersManageYourMacsOnly() {
        for operation in PaywallOperation.allCases {
            for (current, limit) in [(1, 1), (2, 2), (0, 2), (3, 2), (0, 0)] {
                for canAdd in [false, true] {
                    XCTAssertEqual(
                        PaywallCopy.failure(.deviceLimit(current: current, limit: limit, canAdd: canAdd),
                                            during: operation).actions,
                        [manage], "\(operation) \(current)/\(limit), canAdd \(canAdd)")
                }
            }
        }
        for failure in allFailures {
            if case .deviceLimit = failure { continue }
            for operation in PaywallOperation.allCases {
                let actions = PaywallCopy.failure(failure, during: operation).actions
                XCTAssertFalse(actions.contains(manage), "\(failure), \(operation)")
            }
        }
        for (failure, operation, copy) in everyCopy {
            for case .open(let title, let url, _) in copy.actions {
                XCTAssertNotEqual(url, PaywallCopy.buyURL, "\(failure), \(operation)")
                XCTAssertFalse(path(url).hasPrefix("/pricing"), "\(failure), \(operation): \(url)")
                XCTAssertNotEqual(title, PaywallCopy.buyTitle, "\(failure), \(operation)")
            }
        }
    }

    func testContactSupportIsOfferedExactlyWhereTheRulesSay() {
        for operation in PaywallOperation.allCases {
            for failure in allFailures {
                let offered = PaywallCopy.failure(failure, during: operation).actions.contains(support)
                XCTAssertEqual(offered, supportCanHelp(failure), "\(failure), \(operation)")
            }
        }
    }

    /// A copy not built by OloApps is pointed at the website's download page;
    /// nothing else is, and a development build without a server gets no button.
    func testOnlyAnUnofficialBuildIsOfferedTheDownload() {
        for operation in PaywallOperation.allCases {
            XCTAssertEqual(PaywallCopy.failure(.unofficialBuild, during: operation).actions, [download])
            XCTAssertEqual(PaywallCopy.failure(.noLicenceServer, during: operation).actions, [])
            for failure in allFailures where failure != .unofficialBuild {
                XCTAssertFalse(PaywallCopy.failure(failure, during: operation).actions.contains(download), "\(failure)")
            }
        }
        XCTAssertEqual(PaywallCopy.downloadPageURL.absoluteString, "https://reqresapp.com/docs/getting-started/install/")
    }

    /// Every button opens a page on reqresapp.com, or writes to support, and
    /// carries VoiceOver's hint for where it goes: the core hides the glyph
    /// after its title (↗ or an envelope) from VoiceOver. A mail's hint never
    /// says "browser".
    func testEveryButtonOpensTheWebsiteOrWritesToSupport() {
        for (failure, operation, copy) in everyCopy {
            for action in copy.actions {
                switch action {
                case .retry(let title):
                    XCTAssertEqual(title, PaywallCopy.tryAgainTitle, "\(failure), \(operation)")
                case .open(let title, let url, let hint):
                    XCTAssertFalse(title.isEmpty)
                    if url.scheme == "mailto" {
                        XCTAssertEqual(url.absoluteString, "mailto:support@oloapps.com", "\(failure), \(operation)")
                        XCTAssertEqual(hint, PaywallCopy.mailHint, "\(failure), \(operation)")
                    } else {
                        XCTAssertEqual(url.scheme, "https", "\(failure), \(operation): \(url)")
                        XCTAssertEqual(url.host, "reqresapp.com", "\(failure), \(operation): \(url)")
                        XCTAssertEqual(hint, PaywallCopy.browserHint, "\(failure), \(operation): \(url)")
                    }
                }
            }
        }
        XCTAssertEqual(PaywallCopy.supportURL.absoluteString, "mailto:\(PaywallCopy.supportEmail)")
        XCTAssertEqual(PaywallCopy.supportEmail, "support@oloapps.com")
        XCTAssertEqual(PaywallCopy.mailHint, "Starts an email to support@oloapps.com in your email app")
        XCTAssertFalse(PaywallCopy.mailHint.lowercased().contains("browser"))
        XCTAssertEqual(PaywallCopy.browserHint, "Opens in your browser")
    }

    /// An activation that failed for a reason other than the server's verdict
    /// on the key never says the key was refused or sends the person to their
    /// purchase email: trying again is the fix. The core reads a key the
    /// server accepted and this Mac's Keychain would not store as `unknown`
    /// with LicenseManager's own words, which the alert then shows as its
    /// detail; a retry is safe, since the server answers the Mac it registered.
    func testAnUnexpectedErrorNeverBlamesTheKey() {
        let keyNotStored = "Failed to save license key"
        for description in [keyNotStored, errorDescription, ""] {
            let copy = PaywallCopy.failure(.unknown(description: description), during: .activate)
            // The app's own words; the detail is the error's.
            let text = "\(copy.title) \(copy.message)"
            for word in ["accepted", "purchase email", "Check it", "isn’t a license key", "license key"] {
                XCTAssertFalse(text.contains(word), "'\(description)': '\(text)' says '\(word)'")
            }
            XCTAssertTrue(copy.message.contains("Try again"), copy.message)
            XCTAssertEqual(copy.actions, [support])
        }
        let copy = PaywallCopy.failure(.unknown(description: keyNotStored), during: .activate)
        XCTAssertEqual(copy.title, "Activation didn’t work")
        XCTAssertEqual(copy.detail, keyNotStored)
        XCTAssertNotEqual(copy, PaywallCopy.failure(.keyNotAccepted(serverMessage: keyNotStored), during: .activate))
    }

    // MARK: - The rules for the words

    /// What happened, from the person's side: at most 6 words, no final
    /// punctuation, and never addressed to the person ("you", "your"), so it
    /// cannot blame them.
    func testTitlesAreShortAndBlameNobody() {
        for (failure, operation, copy) in everyCopy {
            let words = copy.title.split(whereSeparator: \.isWhitespace)
            XCTAssertLessThanOrEqual(words.count, 6, "\(failure), \(operation): '\(copy.title)'")
            XCTAssertFalse(words.isEmpty)
            XCTAssertFalse(copy.title.hasSuffix("."), "'\(copy.title)'")
            XCTAssertFalse(copy.title.hasSuffix("!"), "'\(copy.title)'")
            XCTAssertFalse(copy.title.hasSuffix("?"), "'\(copy.title)'")
            let lowered = words.map { $0.lowercased() }
            XCTAssertFalse(lowered.contains("you") || lowered.contains("your"), "'\(copy.title)'")
        }
    }

    /// One or two short sentences, the last ending with a period. The
    /// longest is the device limit's one sentence with its two remedies.
    func testMessagesAreOneOrTwoShortSentences() {
        for (failure, operation, copy) in everyCopy {
            XCTAssertTrue(copy.message.hasSuffix("."), "'\(copy.message)'")
            let sentences = copy.message.components(separatedBy: ". ")
            XCTAssertTrue((1...2).contains(sentences.count), "\(failure), \(operation): '\(copy.message)'")
            for sentence in sentences {
                XCTAssertLessThanOrEqual(sentence.count, 120, "'\(sentence)'")
            }
            XCTAssertLessThanOrEqual(copy.message.count, 140, "'\(copy.message)'")
        }
    }

    /// When an activation that reached for the server fails, the message says
    /// nothing changed; a deactivation that could not happen says this Mac is
    /// still active. Where the title already makes that plain (a key in the
    /// wrong form or refused, a full license, a copy that cannot use one, a
    /// development build), it is not repeated.
    func testTheMessageSaysWhatDidNotChange() {
        for failure in allFailures {
            let activation = PaywallCopy.failure(failure, during: .activate)
            switch failure {
            case .licenseExpired, .serverUnavailable, .network, .unverifiedAnswer, .notActivated, .unknown:
                XCTAssertTrue(activation.message.lowercased().contains("nothing changed"), "\(failure)")
            case .keyFormat, .keyNotAccepted, .deviceLimit, .unofficialBuild, .noLicenceServer:
                break
            }
            XCTAssertFalse("\(activation.title) \(activation.message)".contains("still active"), "\(failure)")

            let deactivation = PaywallCopy.failure(failure, during: .deactivate)
            switch failure {
            case .notActivated, .unofficialBuild, .noLicenceServer:
                break
            default:
                XCTAssertTrue("\(deactivation.title) \(deactivation.message)".contains("still active"), "\(failure)")
            }
            XCTAssertFalse(deactivation.message.contains("Nothing changed on this Mac."), "\(failure)")
        }
    }

    /// Nothing says how or when the license is checked, even when the server's
    /// message or an error's description does.
    func testNothingSaysHowOrWhenTheLicenseIsChecked() {
        let forbidden = ["30 days", "once a day", "every day", "24 hours", "serial", "token", "entitlement",
                         "nonce", "signature", "keychain"]
        let tellTales = [
            "Your token has expired", "The Keychain item could not be read", "Signature check failed",
            "Pro lasts 30 days offline", "Checked once a day", "Checked every day", "Valid for 24 hours",
            "Serial number not found", "Entitlement missing", "Nonce mismatch",
        ]
        let inputs = allFailures
            + tellTales.map { PaywallFailure.keyNotAccepted(serverMessage: $0) }
            + tellTales.map { PaywallFailure.unknown(description: $0) }
        for failure in inputs {
            for operation in PaywallOperation.allCases {
                let copy = PaywallCopy.failure(failure, during: operation)
                for text in words(of: copy) {
                    for word in forbidden {
                        XCTAssertFalse(text.lowercased().contains(word), "\(failure), \(operation): '\(text)' says '\(word)'")
                    }
                }
            }
        }
    }

    // MARK: - The detail

    /// A detail with a license key, a device id, a serial number, a token, a
    /// nonce or a hash in it is left out, for both operations.
    func testTheDetailNeverShowsAPrivateValue() {
        let secrets = [
            "ABCDE-12345-FGHIJ-67890",
            "abcde-fghij-klmno-pqrst",
            "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
            "C02XL0GHJGH5",
            "K9JQ2X7Y4W",
            "eyJ2IjoxLCJhbGciOiJFZERTQSJ9.eyJsa2giOiJhYmMifQ.c2lnbmF0dXJl",
            "q8Zr1_xK-pL2vW9yBn3TuA",
            "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        ]
        for secret in secrets {
            let inputs: [PaywallFailure] = [
                .keyNotAccepted(serverMessage: "No license for \(secret) here"),
                .unknown(description: "No license for \(secret) here"),
            ]
            for failure in inputs {
                for operation in PaywallOperation.allCases {
                    let copy = PaywallCopy.failure(failure, during: operation)
                    XCTAssertNil(copy.detail, "\(secret) shown during \(operation)")
                    for text in words(of: copy) {
                        XCTAssertFalse(text.contains(secret), "'\(text)' shows \(secret)")
                    }
                }
            }
        }
    }

    /// Ordinary words pass: the server's messages, an error's description,
    /// the key field's prompt (the shape, not a key), long words and
    /// variable names.
    func testTheDetailShowsOrdinaryWords() {
        let messages = [
            "Invalid or inactive license",
            "Device not activated for this license",
            "Missing license key or device ID",
            "Too many requests",
            "License keys look like \(PaywallCopy.keyPrompt)",
            errorDescription,
            "REQRES_DEV_LICENSE_API is not set",
            "Internationalization failed",
            "The operation couldn’t be completed. (XReqResCore.LicenseError error 3.)",
        ]
        for message in messages {
            XCTAssertEqual(PaywallCopy.failure(.keyNotAccepted(serverMessage: message), during: .activate).detail, message)
            XCTAssertEqual(PaywallCopy.failure(.unknown(description: message), during: .deactivate).detail, message)
        }
    }

    /// One line, no blank detail, and at most `detailLimit` characters.
    func testTheDetailIsOneShortLine() {
        XCTAssertEqual(PaywallCopy.shownDetail("  Invalid\n  or inactive \t license  "), "Invalid or inactive license")
        XCTAssertNil(PaywallCopy.shownDetail(""))
        XCTAssertNil(PaywallCopy.shownDetail(" \n\t "))
        XCTAssertNil(PaywallCopy.shownDetail(nil))
        let long = String(repeating: "word ", count: PaywallCopy.detailLimit)
        let cut = PaywallCopy.shownDetail(long)
        XCTAssertEqual(cut?.count, PaywallCopy.detailLimit)
        XCTAssertEqual(cut?.hasSuffix("…"), true)
        let exact = String(repeating: "a", count: PaywallCopy.detailLimit)
        XCTAssertEqual(PaywallCopy.shownDetail(exact), exact)
    }

    /// Only the server's words for a refused key, or an unexpected error's
    /// description, are shown as a detail.
    func testOnlyARefusedKeyOrAnUnexpectedErrorHasADetail() {
        for (failure, operation, copy) in everyCopy {
            switch failure {
            case .keyNotAccepted(let message?) where !message.isEmpty:
                XCTAssertEqual(copy.detail, message, "\(operation)")
            case .unknown(let description) where !description.isEmpty:
                XCTAssertEqual(copy.detail, description, "\(operation)")
            default:
                XCTAssertNil(copy.detail, "\(failure), \(operation)")
            }
        }
    }

    // MARK: - Typography and shape

    func testTheTypographyIsTheDesigns() {
        for (failure, operation, copy) in everyCopy {
            for text in words(of: copy) {
                XCTAssertFalse(text.contains("'"), "\(failure), \(operation): a straight apostrophe in '\(text)'")
                XCTAssertFalse(text.contains("..."), "'\(text)'")
                XCTAssertFalse(text.contains("  "), "'\(text)'")
                XCTAssertEqual(text, text.trimmingCharacters(in: .whitespacesAndNewlines), "'\(text)'")
            }
        }
        XCTAssertEqual(PaywallCopy.tryAgainTitle, "Try Again")
        XCTAssertEqual(PaywallCopy.contactSupportTitle, "Contact Support")
        XCTAssertEqual(PaywallCopy.downloadTitle, "Download ReqRes")
    }

    /// The mirror of the core's `LicenseFailure` and `LicenseOperation`.
    func testTheEnumsMirrorTheCore() {
        XCTAssertEqual(PaywallOperation.allCases, [.activate, .deactivate])
        XCTAssertEqual(PaywallFailure.NetworkProblem.allCases, [.offline, .timedOut, .other])
        XCTAssertEqual(Set(allFailures.map(caseName)).count, Self.caseCount)
        XCTAssertEqual(Set(allFailures.compactMap { failure -> PaywallFailure.NetworkProblem? in
            if case .network(let problem) = failure { return problem }
            return nil
        }), Set(PaywallFailure.NetworkProblem.allCases))
    }

    // MARK: - Helpers

    /// The license page as the messages write it, pinned as text: what the
    /// person reads and types.
    private let licensePage = "reqresapp.com/license/"

    private var support: PaywallFailureAction {
        .open(title: "Contact Support", url: URL(string: "mailto:support@oloapps.com")!,
              hint: "Starts an email to support@oloapps.com in your email app")
    }

    private var manage: PaywallFailureAction {
        .open(title: "Manage your Macs…", url: URL(string: "https://reqresapp.com/license/")!,
              hint: "Opens in your browser")
    }

    private var download: PaywallFailureAction {
        .open(title: "Download ReqRes", url: URL(string: "https://reqresapp.com/docs/getting-started/install/")!,
              hint: "Opens in your browser")
    }

    private func path(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
    }

    private let tryAgain = PaywallFailureAction.retry(title: "Try Again")

    private var unofficialBuild: PaywallFailureCopy {
        PaywallFailureCopy(
            title: "This copy can’t use a license",
            message: "It wasn’t built by OloApps, so it runs as the free version. "
                + "Download ReqRes from reqresapp.com to use your license.",
            actions: [download])
    }

    private var noLicenceServer: PaywallFailureCopy {
        PaywallFailureCopy(
            title: "No license server",
            message: "This development build has no license server. "
                + "Quit ReqRes and open it again with REQRES_DEV_LICENSE_API=http://localhost:3000/api.")
    }

    /// Every case, the network problems each, and the device limit and the
    /// server's message both ways.
    private var allFailures: [PaywallFailure] {
        [
            .keyFormat,
            .keyNotAccepted(serverMessage: serverMessage),
            .keyNotAccepted(serverMessage: nil),
            .licenseExpired,
            .deviceLimit(current: 2, limit: 2, canAdd: false),
            .deviceLimit(current: 2, limit: 2, canAdd: true),
            .deviceLimit(current: 1, limit: 1, canAdd: false),
            .deviceLimit(current: 0, limit: 0, canAdd: true),
            .serverUnavailable,
        ]
            + PaywallFailure.NetworkProblem.allCases.map { PaywallFailure.network($0) }
            + [
                .unverifiedAnswer,
                .unofficialBuild,
                .noLicenceServer,
                .notActivated,
                .unknown(description: errorDescription),
                .unknown(description: ""),
            ]
    }

    private var everyCopy: [(PaywallFailure, PaywallOperation, PaywallFailureCopy)] {
        allFailures.flatMap { failure in
            PaywallOperation.allCases.map { (failure, $0, PaywallCopy.failure(failure, during: $0)) }
        }
    }

    private func words(of copy: PaywallFailureCopy) -> [String] {
        var texts = [copy.title, copy.message]
        if let detail = copy.detail { texts.append(detail) }
        for action in copy.actions {
            switch action {
            case .retry(let title): texts.append(title)
            case .open(let title, _, let hint): texts += [title, hint]
            }
        }
        return texts
    }

    private func isRetry(_ action: PaywallFailureAction) -> Bool {
        if case .retry = action { return true }
        return false
    }

    private func retryCanHelp(_ failure: PaywallFailure) -> Bool {
        switch failure {
        case .serverUnavailable, .network, .unverifiedAnswer, .unknown:
            return true
        case .keyFormat, .keyNotAccepted, .licenseExpired, .deviceLimit, .unofficialBuild, .noLicenceServer, .notActivated:
            return false
        }
    }

    private func supportCanHelp(_ failure: PaywallFailure) -> Bool {
        switch failure {
        case .keyNotAccepted, .licenseExpired, .unverifiedAnswer, .unknown:
            return true
        case .keyFormat, .deviceLimit, .serverUnavailable, .network, .unofficialBuild, .noLicenceServer, .notActivated:
            return false
        }
    }

    /// The number of `PaywallFailure` cases. `caseName` must name each one, so
    /// a new case does not compile here until it has its words above.
    private static let caseCount = 11

    private func caseName(_ failure: PaywallFailure) -> String {
        switch failure {
        case .keyFormat: return "keyFormat"
        case .keyNotAccepted: return "keyNotAccepted"
        case .licenseExpired: return "licenseExpired"
        case .deviceLimit: return "deviceLimit"
        case .serverUnavailable: return "serverUnavailable"
        case .network: return "network"
        case .unverifiedAnswer: return "unverifiedAnswer"
        case .unofficialBuild: return "unofficialBuild"
        case .noLicenceServer: return "noLicenceServer"
        case .notActivated: return "notActivated"
        case .unknown: return "unknown"
        }
    }
}
