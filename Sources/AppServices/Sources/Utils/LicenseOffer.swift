//
//  LicenseOffer.swift
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
//  What a ReqRes license costs and on what terms, as the paywall states it.
//
//  The closed core compiles in no price and no offer text (PRD A1): the app
//  hands it a `PlanSheetContent`, which `PlanSheetContent+ReqRes.swift` maps
//  from this file and from `PaywallCopy` (every other word on the sheet and in
//  Settings ▸ License). It is plain Swift in Utils, which cannot import the
//  core, so every number and sentence is pinned by tests (`LicenseOfferTests`)
//  and compared with the website's own files (`PaywallWebsiteParityTests`).
//
//  The sentences are the website's, word for word: `headline` is the H1 of
//  /pricing/ and `priceDetail` the line under its price (PricingHero.tsx),
//  `taxNote` is its `TAX_NOTE` (components/pricing/offer.ts). The numbers
//  mirror src/lib/pricing.ts (`UNIT_PRICE_USD`, `MACS_PER_LICENSE`) and the
//  checkout's trust facts (CheckoutForm.tsx, the refund days). The website is
//  the source of truth: a price, a term or a sentence changed there is
//  changed here in the same release.
//
//  A license is a one-time purchase that works with every version of ReqRes,
//  future major versions included. So nothing here prices a next version, and
//  the licensed sheet shows no note under its Term row.
//  PaywallWebsiteParityTests checks that the pricing FAQ
//  (components/pricing/PricingFaq.tsx) and the license agreement
//  (src/app/eula/page.tsx) keep none of the phrases of the per-version terms
//  they replaced (Pro on every 1.x version, ReqRes 2 free within 12 months of
//  the purchase or else 40% of what was paid, a paid major).
//
//  Volume pricing is not in the app. The page Buy opens shows it beside the
//  quantity picker, and step 1 of "How a license works" says the quantity is
//  picked there; on a sheet shown at every unlicensed launch, "20% off" would
//  read as a sale.
//
//  "forever" is in one sentence only, `headline`; the line beside the price
//  and the licensed Term row say what it covers: every future version.
//  Nothing here says how or when the license is checked.
//
//  A no-break space (U+00A0) binds the words that must not be split across a
//  line break, wherever the design's copy deck marks one.
//

import Foundation

public enum LicenseOffer {
    // MARK: The numbers

    /// What 1 license costs, in whole US dollars, before VAT and sales tax.
    /// The website's `UNIT_PRICE_USD`.
    public static let unitPriceUSD = 60

    /// 1 license is 1 person on up to this many Macs activated at once.
    /// The website's `MACS_PER_LICENSE`.
    public static let macsPerLicense = 2

    /// Refunds, for any reason, within this many days of purchase.
    public static let refundDays = 14

    // MARK: The words

    /// The product's name, beside the app icon.
    public static let title = "ReqRes Pro"

    public static var price: String { "$\(unitPriceUSD)" }

    /// The promise, in the brand gradient: /pricing/'s H1. The one sentence
    /// with "forever"; `priceDetail` and `licensedTerm` say what it covers.
    public static let headline = "Pay once, use forever."

    /// Beside the price: who and what the price covers, the website hero's
    /// line under its price. The no-break spaces put the line break after
    /// "at once,".
    public static var priceDetail: String { priceDetail(macs: macsPerLicense) }

    static func priceDetail(macs: Int) -> String {
        let nbsp = CopyText.nbsp
        return "per person, for use on up to \(CopyText.count(macs, "Mac", "Macs")) at\(nbsp)once, "
            + "with\(nbsp)every\(nbsp)future\(nbsp)version\(nbsp)included."
    }

    /// Under the facts beside the price: what the price leaves out. The
    /// website's `TAX_NOTE` (`PRICE_TAX_NOTE` and a period).
    public static let taxNote = "USD, excl. VAT/sales tax."

    /// The licensed Term row: the README's own sentence. The core shows it
    /// only once the license server's answer this session says the license
    /// has no expiry date; before that answer the expiry is unknown, not
    /// absent (`PaywallModel.showsPerpetualTerms`).
    public static var licensedTerm: String {
        let nbsp = CopyText.nbsp
        return "Yours permanently, with\(nbsp)every\(nbsp)future\(nbsp)version\(nbsp)included"
    }
}
