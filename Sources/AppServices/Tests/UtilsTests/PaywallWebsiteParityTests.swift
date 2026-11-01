//
//  PaywallWebsiteParityTests.swift
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
//  A drift guard: every line the paywall shares with reqresapp.com/pricing/
//  is the website's, word for word, neither the paywall nor the pricing FAQ
//  nor the license agreement keeps a phrase of the per-version terms (a
//  license covers every version), and every page it opens exists there. The
//  words live twice, here and on the website, so a change on either side
//  fails these tests until both match. Run them before every release.
//
//  The website is the nearest folder named website-reqres beside the
//  repository root or beside any of its parents, or the folder that
//  REQRES_WEBSITE_ROOT names. Without one the tests are skipped. The
//  website's files are read as text and never run: a few lines of JSX
//  reading (tags dropped, `{' '}` a space, a known constant its value, JSX's
//  own whitespace rule) are enough for the lines compared.
//

import XCTest
@testable import Utils

final class PaywallWebsiteParityTests: XCTestCase {
    // MARK: - The price and its labels (src/lib/pricing.ts, components/pricing/offer.ts)

    func testThePriceAndItsLabelsAreTheWebsites() throws {
        let site = try Website.find()
        let pricing = try site.text("src/lib/pricing.ts")
        let offer = try site.text("components/pricing/offer.ts")

        XCTAssertEqual(JS.constant("UNIT_PRICE_USD", in: pricing), String(LicenseOffer.unitPriceUSD))
        XCTAssertEqual(JS.constant("MACS_PER_LICENSE", in: pricing), String(LicenseOffer.macsPerLicense))
        let priceTaxNote = try XCTUnwrap(JS.constant("PRICE_TAX_NOTE", in: pricing))
        XCTAssertEqual(JS.constant("TAX_NOTE", in: offer, known: ["PRICE_TAX_NOTE": priceTaxNote]), LicenseOffer.taxNote)
        XCTAssertEqual(JS.constant("SUPPORT_EMAIL", in: offer), PaywallCopy.supportEmail)
        // usd(): a dollar sign and the whole number, as `LicenseOffer.price` writes it.
        XCTAssertTrue(offer.contains("`$${whole.toLocaleString('en-US')}`"), "usd() changed")
        XCTAssertEqual(LicenseOffer.price, "$\(LicenseOffer.unitPriceUSD)")
    }

    // MARK: - The hero (components/pricing/PricingHero.tsx)

    func testTheHeadlineIsTheWebsitesH1() throws {
        let site = try Website.find()
        let hero = try site.text("components/pricing/PricingHero.tsx")
        let headings = JSX.elements("h1", in: hero).map { JSX.text($0.children) }
        XCTAssertEqual(headings, [plain(LicenseOffer.headline)])
    }

    /// The line beside the app's price is the line under the website's.
    func testThePriceDetailIsTheWebsitesLineUnderThePrice() throws {
        let site = try Website.find()
        let hero = try site.text("components/pricing/PricingHero.tsx")
        let constants = try heroConstants(site)
        let spans = JSX.elements("span", in: hero).map { JSX.text($0.children, constants: constants) }
        XCTAssertTrue(spans.contains(plain(LicenseOffer.priceDetail)),
                      "no line '\(plain(LicenseOffer.priceDetail))' in PricingHero.tsx: \(spans)")
        let paragraphs = JSX.elements("p", in: hero).map { JSX.text($0.children, constants: constants) }
        XCTAssertTrue(paragraphs.contains(plain(LicenseOffer.taxNote)), "the tax note under the price")
    }

    /// The website's 3 limits are the app's gains: each one's number is its
    /// `FreeTier` constant and its noun the gain's, and the sentence around
    /// them opens with the gains' title and ends with their note.
    func testTheThreeLimitsAreTheGains() throws {
        let site = try Website.find()
        let hero = try site.text("components/pricing/PricingHero.tsx")
        let constants = try heroConstants(site)

        let hostFilters = try limitPhrase(.hostFilters, FreeTier.hostFilters)
        let rules = try limitPhrase(.rules, FreeTier.overrideRules)
        let inspections = try limitPhrase(.httpsInspections, FreeTier.httpsSessionDetailsPerLaunch)
        XCTAssertEqual(constants["LIMIT_HOST_FILTERS"].map(plain), hostFilters)
        XCTAssertEqual(constants["LIMIT_RULES"].map(plain), rules)
        XCTAssertEqual(constants["LIMIT_INSPECTIONS"].map(plain), inspections)

        // "per launch" is the inspections gain's own: "Free: 10 per launch".
        let inspectionsNote = try XCTUnwrap(PaywallCopy.gains.first { $0.id == PaywallTrigger.httpsInspections.rawValue })
        XCTAssertTrue(plain(inspectionsNote.freeNote).hasSuffix(" per launch"))

        let sentence = "\(PaywallCopy.gainsTitle): \(hostFilters), \(rules) and \(inspections) per launch. "
            + PaywallCopy.gainsNote
        let paragraphs = JSX.elements("p", in: hero).map { JSX.text($0.children, constants: constants) }
        XCTAssertTrue(paragraphs.contains(plain(sentence)), "no '\(plain(sentence))' in PricingHero.tsx: \(paragraphs)")
    }

    // MARK: - How a license works (components/pricing/LicenseSteps.tsx)

    func testTheStepsAreTheWebsites() throws {
        let site = try Website.find()
        let steps = try site.text("components/pricing/LicenseSteps.tsx")
        let macs = try XCTUnwrap(JS.constant("MACS_PER_LICENSE", in: try site.text("src/lib/pricing.ts")))

        XCTAssertTrue(JSX.elements("h2", in: steps).map { JSX.text($0.children) }.contains(PaywallCopy.stepsTitle))

        let titles = JS.strings(field: "title", in: steps).map { JS.substitute($0, ["MACS_PER_LICENSE": macs]) }
        XCTAssertGreaterThanOrEqual(titles.count, PaywallCopy.steps.count)
        XCTAssertEqual(Array(titles.prefix(PaywallCopy.steps.count)), PaywallCopy.steps.map { plain($0.title) })

        // Bodies 1 and 2 are the website's; step 3's body is the app's own
        // (it names the sheet's button), and the note under the key field
        // carries the website's step 3 sentence instead.
        let bodies = JS.strings(field: "body", in: steps)
        XCTAssertEqual(Array(bodies.prefix(2)), PaywallCopy.steps.prefix(2).map(\.body))
        let stepThree = try XCTUnwrap(plain(PaywallCopy.activationNote).components(separatedBy: ". ").last)
        let fragments = JSX.elements("", in: steps).map { JSX.text($0.children, constants: ["MACS_PER_LICENSE": macs]) }
        XCTAssertTrue(fragments.contains { $0.hasSuffix(stepThree) }, "no '\(stepThree)' in step 3: \(fragments)")
    }

    // MARK: - Next to Buy (components/pricing/CheckoutForm.tsx)

    /// Settings' 4 facts are the website's trust facts, in order, the refund
    /// fact linking the same page.
    func testTheFactsAreTheWebsitesTrustFacts() throws {
        let site = try Website.find()
        let form = try site.text("components/pricing/CheckoutForm.tsx")
        let trust = JS.trustFacts(in: form)
        XCTAssertEqual(trust.map { $0.text }, PaywallCopy.settingsFacts.map(\.text))
        XCTAssertEqual(trust.map { $0.href }, PaywallCopy.settingsFacts.map { $0.url.map(Self.path) })
    }

    func testTheAcceptanceSentenceIsTheWebsites() throws {
        let site = try Website.find()
        let form = try site.text("components/pricing/CheckoutForm.tsx")
        let acceptance = try AttributedString(markdown: PaywallCopy.acceptanceMarkdown)
        let sentence = String(acceptance.characters)
        let paragraphs = JSX.elements("p", in: form).filter { JSX.text($0.children) == sentence }
        XCTAssertFalse(paragraphs.isEmpty, "no '\(sentence)' in CheckoutForm.tsx")

        var appLinks: [Link] = []
        for run in acceptance.runs {
            if let url = run.link {
                appLinks.append(Link(text: String(acceptance[run.range].characters), href: Self.path(url)))
            }
        }
        for paragraph in paragraphs {
            let anchors = JSX.elements("a", in: paragraph.children)
                .map { Link(text: JSX.text($0.children), href: JSX.attribute("href", in: $0.open) ?? "") }
            XCTAssertEqual(anchors, appLinks)
        }
    }

    // MARK: - Every version included (components/pricing/PricingFaq.tsx, src/app/eula/page.tsx)

    /// A license works with every version of ReqRes, future major versions
    /// included, so neither side states a per-version term. No sentence of
    /// the app's offer does, and the pricing FAQ and the license agreement
    /// keep no phrase of the terms they replaced: Pro on every "1.x version"
    /// (every ReqRes 1.x version too) with every "1.x update", ReqRes 2 free
    /// "within 12 months" of the purchase, otherwise the "upgrade costs"
    /// "40%" of what was paid, a "paid major" announced as a "paid upgrade",
    /// and no "major versions for life". Both sides are read in lower case
    /// with every run of white space as one space, so neither a capital nor a
    /// line break inside a phrase hides it. The offline period "from 1.1.x"
    /// and "the last 1.x build" are not such phrases.
    func testNeitherSidePricesANextVersion() throws {
        let site = try Website.find()
        let perVersionPhrases = ["1.x version", "1.x update", "within 12 months", "40%", "upgrade costs", "paid major",
                                 "paid upgrade", "major versions for life"]
        let offer = [LicenseOffer.title, LicenseOffer.price, LicenseOffer.headline, LicenseOffer.priceDetail,
                     LicenseOffer.taxNote, LicenseOffer.licensedTerm]
        for sentence in offer.map({ plain($0).lowercased() }) {
            for phrase in perVersionPhrases + ["reqres 2", "what you paid", "upgrade"] {
                XCTAssertFalse(sentence.contains(phrase), "the app's '\(sentence)' says '\(phrase)'")
            }
        }
        for file in ["components/pricing/PricingFaq.tsx", "src/app/eula/page.tsx"] {
            let text = plain(try site.text(file).replacingOccurrences(of: "&nbsp;", with: " ")).lowercased()
            for phrase in perVersionPhrases {
                XCTAssertFalse(text.contains(phrase), "\(file) still says '\(phrase)'")
            }
        }
    }

    // MARK: - The pages the app opens

    /// See every feature lands on the list of every feature, on /pricing/.
    func testSeeEveryFeatureLandsOnTheWebsitesList() throws {
        let site = try Website.find()
        let fragment = try XCTUnwrap(PaywallCopy.allFeaturesURL.fragment)
        XCTAssertTrue(try site.text("components/pricing/EverythingInReqRes.tsx").contains("id=\"\(fragment)\""))
        XCTAssertTrue(try site.text("components/PricingPage.tsx").contains("<EverythingInReqRes />"))
        XCTAssertEqual(Self.path(PaywallCopy.allFeaturesURL), Self.path(PaywallCopy.buyURL))
    }

    /// Every page the sheet, Settings and the failure alerts open exists on
    /// the website, at the trailing-slash address the site serves.
    func testEveryPageTheAppOpensExists() throws {
        let site = try Website.find()
        XCTAssertTrue(try site.text("next.config.js").contains("trailingSlash: true"))
        for url in pagesOpened {
            XCTAssertEqual(url.host, "reqresapp.com", url.absoluteString)
            let path = Self.path(url)
            XCTAssertTrue(path.hasSuffix("/"), url.absoluteString)
            let file = path.hasPrefix("/docs/")
                ? "content/docs/" + path.dropFirst("/docs/".count).dropLast() + ".mdx"
                : "src/app" + path + "page.tsx"
            XCTAssertTrue(site.exists(file), "\(url.absoluteString): no \(file) in the website")
        }
    }

    /// Download ReqRes opens the page with the website's download button.
    func testTheDownloadPageOffersTheDownload() throws {
        let site = try Website.find()
        let install = try site.text("content/docs/getting-started/install.mdx")
        XCTAssertTrue(install.contains("<Download />"))
        XCTAssertTrue(install.contains("title: Install ReqRes"))
    }

    // MARK: - Helpers

    private struct Link: Equatable {
        let text: String
        let href: String
    }

    /// `PricingHero.tsx`'s constants, `MACS_PER_LICENSE` and `TAX_NOTE`.
    private func heroConstants(_ site: Website) throws -> [String: String] {
        let pricing = try site.text("src/lib/pricing.ts")
        let hero = try site.text("components/pricing/PricingHero.tsx")
        var constants = [
            "MACS_PER_LICENSE": try XCTUnwrap(JS.constant("MACS_PER_LICENSE", in: pricing)),
            "TAX_NOTE": try XCTUnwrap(JS.constant(
                "TAX_NOTE", in: try site.text("components/pricing/offer.ts"),
                known: ["PRICE_TAX_NOTE": try XCTUnwrap(JS.constant("PRICE_TAX_NOTE", in: pricing))])),
        ]
        for name in ["LIMIT_HOST_FILTERS", "LIMIT_RULES", "LIMIT_INSPECTIONS"] {
            constants[name] = try XCTUnwrap(JS.constant(name, in: hero), name)
        }
        return constants
    }

    /// "2 host filters", "1 rule": the free number and the gain's noun.
    private func limitPhrase(_ trigger: PaywallTrigger, _ number: Int) throws -> String {
        let gain = try XCTUnwrap(PaywallCopy.gains.first { $0.id == trigger.rawValue })
        var noun = plain(gain.title)
        XCTAssertTrue(noun.hasPrefix("Unlimited "), noun)
        noun.removeFirst("Unlimited ".count)
        if number == 1, noun.hasSuffix("s") { noun.removeLast() }
        return "\(number) \(noun)"
    }

    private var pagesOpened: [URL] {
        var urls = [PaywallCopy.buyURL, PaywallCopy.allFeaturesURL, PaywallCopy.refundURL, PaywallCopy.licensePageURL,
                    PaywallCopy.licenseAgreementURL, PaywallCopy.termsOfServiceURL, PaywallCopy.privacyPolicyURL,
                    PaywallCopy.downloadPageURL]
        urls += PaywallCopy.legalLinks.map(\.url) + PaywallCopy.settingsFacts.compactMap(\.url)
        let failures: [PaywallFailure] = [.deviceLimit(current: 2, limit: 2, canAdd: true), .unofficialBuild]
        for failure in failures {
            for operation in PaywallOperation.allCases {
                for case .open(_, let url, _) in PaywallCopy.failure(failure, during: operation).actions
                    where url.scheme == "https" {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private static func path(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
            .deletingLastPathComponent() // the repository root
    }

    /// A website checkout, read as text.
    private struct Website {
        struct NotAWebsite: Error, CustomStringConvertible {
            let description: String
        }

        let root: URL

        /// $REQRES_WEBSITE_ROOT, or the nearest website-reqres beside the
        /// repository root or one of its parents; skips without either.
        static func find() throws -> Website {
            let fileManager = FileManager.default
            func isWebsite(_ folder: URL) -> Bool {
                fileManager.fileExists(atPath: folder.appendingPathComponent("components/pricing").path)
            }
            if let named = ProcessInfo.processInfo.environment["REQRES_WEBSITE_ROOT"], !named.isEmpty {
                let root = URL(fileURLWithPath: named, isDirectory: true)
                guard isWebsite(root) else {
                    throw NotAWebsite(description: "REQRES_WEBSITE_ROOT=\(named) has no components/pricing")
                }
                return Website(root: root)
            }
            var folder = PaywallWebsiteParityTests.repositoryRoot.deletingLastPathComponent()
            while folder.pathComponents.count > 1 {
                let candidate = folder.appendingPathComponent("website-reqres", isDirectory: true)
                if isWebsite(candidate) {
                    return Website(root: candidate)
                }
                folder.deleteLastPathComponent()
            }
            throw XCTSkip("No website-reqres beside the repository or its parents, and no REQRES_WEBSITE_ROOT: "
                + "the paywall is not compared with the website.")
        }

        func text(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        }
    }
}

/// Text as a page renders it, for comparing: no-break spaces read as spaces,
/// every run of whitespace one space, nothing at either end.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

/// The few TypeScript shapes the website's copy is written in.
private enum JS {
    /// The value of `const NAME = 'text';`, `export const NAME = 60;`, or a
    /// template literal whose `${OTHER}` is in `known`.
    static func constant(_ name: String, in source: String, known: [String: String] = [:]) -> String? {
        let pattern = #"(?:export\s+)?const\s+"# + name
            + #"\s*(?::[^=]+)?=\s*(?:'([^'\n]*)'|"([^"\n]*)"|`([^`]*)`|([0-9_]+))\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else {
            return nil
        }
        for group in 1...4 {
            guard let range = Range(match.range(at: group), in: source) else { continue }
            let value = String(source[range])
            switch group {
            case 3: return substitute(value, known)
            case 4: return value.replacingOccurrences(of: "_", with: "")
            default: return value
            }
        }
        return nil
    }

    /// `${NAME}` replaced by `values[NAME]`, when there is one.
    static func substitute(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { text, entry in text.replacingOccurrences(of: "${\(entry.key)}", with: entry.value) }
    }

    /// Every quoted value of `field: '…'` (or a template or double-quoted
    /// one), in order.
    static func strings(field: String, in source: String) -> [String] {
        let pattern = #"\b"# + field + #":\s*(?:'([^'\n]*)'|`([^`]*)`|"([^"\n]*)")"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            (1...3).lazy.compactMap { Range(match.range(at: $0), in: source) }.first.map { String(source[$0]) }
        }
    }

    /// CheckoutForm.tsx's `trust` list: each fact's text and link.
    static func trustFacts(in source: String) -> [(text: String, href: String?)] {
        guard let start = source.range(of: "const trust"),
              let end = source.range(of: "];", range: start.upperBound..<source.endIndex) else { return [] }
        let list = String(source[start.upperBound..<end.lowerBound])
        let pattern = #"\{\s*Icon:\s*\w+,\s*text:\s*'([^']*)'(?:,\s*href:\s*'([^']*)')?\s*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: list, range: NSRange(list.startIndex..., in: list)).compactMap { match in
            guard let text = Range(match.range(at: 1), in: list) else { return nil }
            let href = Range(match.range(at: 2), in: list).map { String(list[$0]) }
            return (String(list[text]), href)
        }
    }
}

/// Just enough JSX to read the words an element renders.
private enum JSX {
    /// Every `<tag …>…</tag>` in `source`, nested ones included: its opening
    /// tag and its children. `tag` "" is a fragment, `<>…</>`.
    static func elements(_ tag: String, in source: String) -> [(open: String, children: String)] {
        let characters = Array(source)
        var found: [(open: String, children: String)] = []
        for start in characters.indices where characters[start] == "<" {
            guard let opening = openingTag(tag, characters, start), !opening.selfClosing else { continue }
            var depth = 1
            var index = opening.end
            while index < characters.count {
                if let nested = openingTag(tag, characters, index) {
                    if !nested.selfClosing { depth += 1 }
                    index = nested.end
                } else if let closingEnd = closingTag(tag, characters, index) {
                    depth -= 1
                    if depth == 0 {
                        found.append((String(characters[start..<opening.end]),
                                      String(characters[opening.end..<index])))
                        break
                    }
                    index = closingEnd
                } else {
                    index += 1
                }
            }
        }
        return found
    }

    /// The value of `name="…"` in an opening tag.
    static func attribute(_ name: String, in openingTag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b"# + name + #"="([^"]*)""#),
              let match = regex.firstMatch(in: openingTag, range: NSRange(openingTag.startIndex..., in: openingTag)),
              let range = Range(match.range(at: 1), in: openingTag) else { return nil }
        return String(openingTag[range])
    }

    /// The text `children` render: tags dropped, a quoted string in braces
    /// (`{' '}`) its text, `{NAME}` its value from `constants`, a comment
    /// nothing, any other expression kept as written; each run of text
    /// cleaned by JSX's rule (lines trimmed, blank lines dropped, lines
    /// joined by one space), then `plain`.
    static func text(_ children: String, constants: [String: String] = [:]) -> String {
        let characters = Array(children)
        var rendered = ""
        var run = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "<", let end = anyTagEnd(characters, index) {
                rendered += cleaned(run)
                run = ""
                index = end
            } else if characters[index] == "{", let end = expressionEnd(characters, index) {
                rendered += cleaned(run)
                run = ""
                let expression = String(characters[(index + 1)..<(end - 1)]).trimmingCharacters(in: .whitespacesAndNewlines)
                rendered += value(of: expression, constants)
                index = end
            } else {
                run.append(characters[index])
                index += 1
            }
        }
        rendered += cleaned(run)
        return plain(rendered)
    }

    private static func value(of expression: String, _ constants: [String: String]) -> String {
        if expression.count >= 2, let first = expression.first, first == expression.last, "'\"`".contains(first) {
            return String(expression.dropFirst().dropLast())
        }
        if expression.hasPrefix("/*") && expression.hasSuffix("*/") {
            return ""
        }
        if let constant = constants[expression] {
            return constant
        }
        return "{\(expression)}"
    }

    /// JSX text: tabs read as spaces; every line but the first loses its
    /// leading spaces, every line but the last its trailing ones; blank
    /// lines go; the lines left are joined by one space.
    private static func cleaned(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let lastWithText = lines.lastIndex { line in line.contains { $0 != " " && $0 != "\t" } }
        var result = ""
        for (number, line) in lines.enumerated() {
            var kept = Substring(line.replacingOccurrences(of: "\t", with: " "))
            if number != 0 { kept = kept.drop { $0 == " " } }
            if number != lines.count - 1 { while kept.last == " " { kept = kept.dropLast() } }
            guard !kept.isEmpty else { continue }
            result += kept
            if number != lastWithText { result += " " }
        }
        return result
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&rsquo;", with: "’")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `<tag` followed by a space, `>` or `/`, to its `>`: where it ends and
    /// whether it closes itself.
    private static func openingTag(_ tag: String, _ characters: [Character], _ start: Int) -> (end: Int, selfClosing: Bool)? {
        guard characters[start] == "<" else { return nil }
        if tag.isEmpty {
            return start + 1 < characters.count && characters[start + 1] == ">" ? (start + 2, false) : nil
        }
        let name = Array(tag)
        let after = start + 1 + name.count
        guard after < characters.count, Array(characters[(start + 1)..<after]) == name else { return nil }
        guard characters[after] == ">" || characters[after] == "/" || characters[after].isWhitespace else { return nil }
        guard let end = tagEnd(characters, after) else { return nil }
        return (end, characters[end - 2] == "/")
    }

    /// `</tag>` (or `</>`) at `start`: where it ends.
    private static func closingTag(_ tag: String, _ characters: [Character], _ start: Int) -> Int? {
        let closing = Array("</\(tag)")
        let after = start + closing.count
        guard after < characters.count, Array(characters[start..<after]) == closing else { return nil }
        var index = after
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        return index < characters.count && characters[index] == ">" ? index + 1 : nil
    }

    /// Any tag at `start` (opening, closing, self-closing or a fragment's): where it ends.
    private static func anyTagEnd(_ characters: [Character], _ start: Int) -> Int? {
        guard start + 1 < characters.count else { return nil }
        let next = characters[start + 1]
        guard next.isLetter || next == "/" || next == ">" else { return nil }
        return tagEnd(characters, start + 1)
    }

    /// From inside a tag to just past its `>`, skipping quoted attribute
    /// values and `{…}` expressions, so `=>` in an attribute does not end it.
    private static func tagEnd(_ characters: [Character], _ start: Int) -> Int? {
        var index = start
        var braces = 0
        var quote: Character?
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if "\"'`".contains(character) {
                quote = character
            } else if character == "{" {
                braces += 1
            } else if character == "}" {
                braces -= 1
            } else if character == ">" && braces == 0 {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    /// From `{` to just past its matching `}`, skipping quoted strings and
    /// `/* … */` comments (an apostrophe in a comment opens no string).
    private static func expressionEnd(_ characters: [Character], _ start: Int) -> Int? {
        var index = start
        var depth = 0
        var quote: Character?
        while index < characters.count {
            let character = characters[index]
            if quote == nil, character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index += 2
                continue
            }
            if let open = quote {
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == open { quote = nil }
            } else if "\"'`".contains(character) {
                quote = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return nil
    }
}
