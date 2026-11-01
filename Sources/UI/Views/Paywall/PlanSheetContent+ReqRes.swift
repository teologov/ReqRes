//
//  PlanSheetContent+ReqRes.swift
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
//  What the ReqRes Pro sheet, the licensed sheet, Settings ▸ License and the
//  Activate License sheet say (the paywall design of 2026-10-06, shell step 3).
//
//  The closed core draws those views and compiles in none of their words
//  (PRD A1): a sentence baked into the binary costs a core rebuild, an ABI
//  diff, a re-embed and a release to correct, which is how "Limited time
//  discount ends soon!" stayed on a purchase screen for a year. This file is
//  a mapping and nothing else. It has no string literal of its own
//  (PaywallCopyWiringTests reads it and refuses one): the offer comes from
//  `LicenseOffer` and every other word, including what a failed activation or
//  deactivation says, from `PaywallCopy`, both in Utils, where tests pin
//  every number against `FreeTier` and every shared line against the
//  website's own files. The failure kinds cross from the core's types to
//  Utils' mirror in PaywallFailure+Core.swift.
//

import Foundation
import Utils
import XReqResCore

extension PlanSheetContent {
    static var reqres: PlanSheetContent {
        let browserHint = PaywallCopy.browserHint
        return PlanSheetContent(
            productName: LicenseOffer.title,
            headline: LicenseOffer.headline,
            price: LicenseOffer.price,
            priceDetail: LicenseOffer.priceDetail,
            taxNote: LicenseOffer.taxNote,
            gainsTitle: PaywallCopy.gainsTitle,
            gains: PaywallCopy.gains.map { gain in
                Gain(id: gain.id, symbol: gain.symbol, title: gain.title, detail: gain.detail,
                     freeNote: gain.freeNote)
            },
            gainsNote: PaywallCopy.gainsNote,
            allFeatures: Link(title: PaywallCopy.allFeaturesTitle, url: PaywallCopy.allFeaturesURL, hint: browserHint),
            reachedBadge: PaywallCopy.reachedBadge,
            stepsTitle: PaywallCopy.stepsTitle,
            steps: PaywallCopy.steps.map { step in Step(id: step.number, title: step.title, body: step.body) },
            // What VoiceOver says before a step's title, "Step 1": the ring
            // shows the number alone.
            stepNumber: { number in PaywallCopy.stepNumber(number) },
            sheetFacts: PaywallCopy.sheetFacts.map { fact in Fact(symbol: fact.symbol, text: fact.text, url: fact.url) },
            settingsFacts: PaywallCopy.settingsFacts.map { fact in
                Fact(symbol: fact.symbol, text: fact.text, url: fact.url)
            },
            acceptance: acceptance,
            legalLinks: PaywallCopy.legalLinks.map { link in Link(title: link.title, url: link.url, hint: browserHint) },
            buy: Link(title: PaywallCopy.buyTitle, url: PaywallCopy.buyURL, hint: PaywallCopy.buyHint),
            activateTitle: PaywallCopy.activateTitle,
            continueTitle: PaywallCopy.continueTitle,
            freeBadge: PaywallCopy.freeBadge,
            keyEntry: KeyEntry(label: PaywallCopy.keyLabel,
                               prompt: PaywallCopy.keyPrompt,
                               activateButton: PaywallCopy.activateButton,
                               note: PaywallCopy.activationNote,
                               sheetTitle: PaywallCopy.keySheetTitle,
                               cancelButton: PaywallCopy.cancelButton),
            licensed: Licensed(
                activeBadge: PaywallCopy.activeBadge,
                activeLine: PaywallCopy.activeLine,
                sectionTitle: PaywallCopy.licenseSectionTitle,
                macsInUseLabel: PaywallCopy.macsInUseLabel,
                macsInUse: { count, limit in PaywallCopy.macsInUse(count, of: limit) },
                // Shown only once the license server's answer this session
                // says the license has no expiry date, which is what makes the
                // term true; before that answer the expiry is unknown, so the
                // core hides the row (`PaywallModel.showsPerpetualTerms`), as
                // it hides the Macs in use until the answer has counted them.
                perpetualTerms: [Row(label: PaywallCopy.termLabel, value: LicenseOffer.licensedTerm)],
                // No note under the rows: a license covers every version, so
                // there is no next version to price, and the core draws
                // nothing for an empty note (`PaywallModel.showsLicensedNote`).
                note: String(),
                macsSectionTitle: PaywallCopy.macsSectionTitle,
                thisMacTitle: PaywallCopy.thisMacTitle,
                thisMacNote: PaywallCopy.thisMacNote,
                deactivateTitle: PaywallCopy.deactivateTitle,
                deactivateConfirmTitle: PaywallCopy.deactivateConfirmTitle,
                deactivateConfirmMessage: PaywallCopy.deactivateConfirmMessage,
                deactivateConfirmButton: PaywallCopy.deactivateConfirmButton,
                allMacsTitle: PaywallCopy.allMacsTitle,
                allMacsNote: PaywallCopy.allMacsNote,
                manage: Link(title: PaywallCopy.manageTitle, url: PaywallCopy.licensePageURL, hint: browserHint),
                doneTitle: PaywallCopy.doneTitle
            ),
            // The core hands over a kind, never a sentence; the words are
            // Utils', held to their rules by PaywallFailureCopyTests.
            failureCopy: { failure, operation in
                FailureCopy(PaywallCopy.failure(PaywallFailure(failure), during: PaywallOperation(operation)))
            },
            progress: Progress(activating: PaywallCopy.activatingProgress,
                               deactivating: PaywallCopy.deactivatingProgress),
            deactivatedNote: PaywallCopy.deactivatedNote,
            linkFailure: LinkFailure(title: PaywallCopy.linkFailureTitle,
                                     message: { url in PaywallCopy.linkFailureMessage(url) },
                                     copyButton: PaywallCopy.linkFailureCopyButton,
                                     dismissButton: PaywallCopy.linkFailureDismissButton)
        )
    }

    /// The website's acceptance sentence, with its 2 links. PaywallCopyTests
    /// parses the same Markdown; were it ever to stop parsing, the sentence
    /// would still be shown as written rather than vanish from beside Buy.
    private static var acceptance: AttributedString {
        (try? AttributedString(markdown: PaywallCopy.acceptanceMarkdown))
            ?? AttributedString(PaywallCopy.acceptanceMarkdown)
    }
}
