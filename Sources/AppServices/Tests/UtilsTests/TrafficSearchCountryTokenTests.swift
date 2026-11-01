//
//  TrafficSearchCountryTokenTests.swift
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
//  The `country:` token (destination-map UX spec §5.2): exactly two ASCII
//  letters or one of `local` / `mac` / `unknown`, OR-ed among country chips,
//  AND-ed with every other kind; a session whose destination was not
//  resolved (nil) satisfies none of them, `unknown` included. Names are
//  resolved BEFORE parse by the field model, never here.
//
//  The last section is the one place Utils and MCPKit meet for this feature:
//  Utils cannot import MCPKit (it would drag Sentry and Sparkle into the
//  sandboxed helper), so the class words are spelled twice, and this test is
//  what keeps the two spellings the same (the `ProcessIdentityLabelTests`
//  pattern).
//

import XCTest
import MCPKit
@testable import Utils

final class TrafficSearchCountryTokenTests: XCTestCase {

    // MARK: - Prefix parsing

    func testCountryPrefixIsRecognisedCaseInsensitivelyWithSurroundingWhitespace() {
        let parsed = TrafficSearchTokenKind.parse("  COUNTRY: us ")
        XCTAssertEqual(parsed?.kind, .country)
        XCTAssertEqual(parsed?.query, "us")
        XCTAssertEqual(TrafficSearchTokenKind.country.prefix, "country:")
    }

    func testCountryPrefixNearMissesStayFreeText() {
        XCTAssertNil(TrafficSearchTokenKind.parse("countries:us"))
        XCTAssertNil(TrafficSearchTokenKind.parse("countryus"))
        XCTAssertNil(TrafficSearchTokenKind.parse("destination:us"))
    }

    /// Appended at the END: `allCases` drives prefix parsing, and every
    /// earlier prefix still parses to itself.
    func testTheKindWasAppendedLast() {
        XCTAssertEqual(TrafficSearchTokenKind.allCases, [.host, .method, .status, .path, .app, .pid, .country, .outcome, .grpc, .proto])
        XCTAssertEqual(TrafficSearchTokenKind.allCases.last, .proto, "outcome was appended after country (protocol PRD 3.4), then grpc (doc §S8), then proto (doc §S9)")
        XCTAssertEqual(TrafficSearchTokenKind.parse("host:a.com")?.kind, .host)
        XCTAssertEqual(TrafficSearchTokenKind.parse("method:get")?.kind, .method)
        XCTAssertEqual(TrafficSearchTokenKind.parse("status:404")?.kind, .status)
        XCTAssertEqual(TrafficSearchTokenKind.parse("path:/v1")?.kind, .path)
        XCTAssertEqual(TrafficSearchTokenKind.parse("app:claude")?.kind, .app)
        XCTAssertEqual(TrafficSearchTokenKind.parse("pid:9437")?.kind, .pid)
    }

    func testCountryKindOffersNoStaticVocabulary() {
        XCTAssertTrue(TrafficSearchTokenKind.country.staticSuggestions.isEmpty, "destinations come from the traffic")
    }

    // MARK: - Token

    func testCountryTokenIdentityAndDisplay() {
        let code = TrafficSearchToken.country("US")
        XCTAssertEqual(code.id, "country-us")
        XCTAssertEqual(code.displayName, "US", "a code shows itself; the chip view upgrades it to the name")
        XCTAssertEqual(code.kind, .country)
        XCTAssertNotEqual(code.id, TrafficSearchToken.host("us").id)

        XCTAssertEqual(TrafficSearchToken.country("mac").displayName, "This Mac")
        XCTAssertEqual(TrafficSearchToken.country("local").displayName, "Local Network")
        XCTAssertEqual(TrafficSearchToken.country("unknown").displayName, "Unknown")
        XCTAssertEqual(TrafficSearchToken.country("mac").id, "country-mac")
    }

    func testCountryTokenParsesTwoLettersOrAClassWordStrictly() {
        XCTAssertEqual(TrafficSearchToken.parse(kind: .country, query: " us "), .country("US"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .country, query: "De"), .country("DE"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .country, query: "LOCAL"), .country("local"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .country, query: "Mac"), .country("mac"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .country, query: "unknown"), .country("unknown"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .country, query: "xx"), .country("XX"), "a code is a code; the table decides what matches")
        for rejected in ["Germany", "USA", "u1", "1", "", "   ", "us de", "ü$", "üs", "this mac", "localhost"] {
            XCTAssertNil(TrafficSearchToken.parse(kind: .country, query: rejected),
                         "'\(rejected)' is not a token and must fall back to free text")
        }
    }

    // MARK: - The matching rule, per token

    private func tokenMatches(_ wanted: String, country: String?) -> Bool {
        TrafficSearchToken.country(wanted).matches(
            host: "api.anthropic.com", url: "https://api.anthropic.com/v1/messages", method: "POST", status: "200",
            app: "claude", pid: 9437, country: country
        )
    }

    func testCountryTokenMatchesExactlyAndNeverANilCountry() {
        XCTAssertTrue(tokenMatches("US", country: "US"))
        XCTAssertTrue(tokenMatches("US", country: "us"), "the caller's spelling is normalised too")
        XCTAssertFalse(tokenMatches("US", country: "DE"))
        XCTAssertFalse(tokenMatches("US", country: nil), "an unresolved session matches no country token")
        XCTAssertFalse(tokenMatches("U", country: "US"), "no prefix on codes")
    }

    /// `unknown` is the resolver's verdict ("could not place"); nil is
    /// "nobody resolved this". Only the first is selectable.
    func testUnknownSelectsOnlyTheResolversUnknownNeverNil() {
        XCTAssertTrue(tokenMatches("unknown", country: "unknown"))
        XCTAssertFalse(tokenMatches("unknown", country: nil))
        XCTAssertFalse(tokenMatches("unknown", country: "US"))
        XCTAssertTrue(tokenMatches("mac", country: "mac"))
        XCTAssertTrue(tokenMatches("local", country: "LOCAL"))
        XCTAssertFalse(tokenMatches("mac", country: "local"))
    }

    /// The token-level defaults stay: a token's semantics can be stated
    /// without a resolution in hand, and omitting the country means none.
    func testATokenCalledWithoutACountryTreatsItAsNone() {
        XCTAssertFalse(TrafficSearchToken.country("US").matches(host: "a.com", url: "https://a.com/", method: "GET", status: "200"))
        XCTAssertTrue(TrafficSearchToken.host("a.com").matches(host: "a.com", url: "https://a.com/", method: "GET", status: "200"))
    }

    func testTheOtherTokensIgnoreTheCountryInput() {
        let tokens: [TrafficSearchToken] = [
            .host("api.anthropic.com"), .method("post"), .status(.exact(200)), .path("/v1/messages"), .app("claude"), .pid(9437),
        ]
        for token in tokens {
            let without = token.matches(
                host: "api.anthropic.com", url: "https://api.anthropic.com/v1/messages", method: "POST", status: "200", app: "claude", pid: 9437, country: nil
            )
            let with = token.matches(
                host: "api.anthropic.com", url: "https://api.anthropic.com/v1/messages", method: "POST", status: "200", app: "claude", pid: 9437, country: "US"
            )
            XCTAssertTrue(without, "\(token) should match this session")
            XCTAssertEqual(without, with, "\(token) must not read the country")
        }
    }

    // MARK: - Filter matching

    private func matches(
        _ filter: TrafficSearchFilter,
        host: String = "api.anthropic.com",
        url: String = "https://api.anthropic.com/v1/messages",
        method: String = "POST",
        status: String? = "200",
        app: String? = "claude",
        pid: Int? = 9437,
        country: String? = "US"
    ) -> Bool {
        filter.matches(host: host, url: url, method: method, status: status, app: app, pid: pid, country: country, outcome: nil, grpcStatus: nil, proto: nil)
    }

    func testAnEmptyFilterMatchesWithOrWithoutACountry() {
        XCTAssertTrue(matches(TrafficSearchFilter(), country: "US"))
        XCTAssertTrue(matches(TrafficSearchFilter(), country: nil))
    }

    func testCountryChipsAreORedAmongThemselves() {
        let filter = TrafficSearchFilter(countries: ["US", "DE"])
        XCTAssertTrue(matches(filter, country: "US"))
        XCTAssertTrue(matches(filter, country: "DE"))
        XCTAssertFalse(matches(filter, country: "JP"))
        XCTAssertFalse(matches(filter, country: nil))
    }

    func testCountryChipsAreANDedWithEveryOtherKindAndTheFreeText() {
        let withHost = TrafficSearchFilter(hosts: ["api.anthropic.com"], countries: ["US"])
        XCTAssertTrue(matches(withHost, country: "US"))
        XCTAssertFalse(matches(withHost, host: "cdn.example.com", country: "US"))
        XCTAssertFalse(matches(withHost, country: "DE"))

        let withApp = TrafficSearchFilter(apps: ["claude"], pids: [9437], countries: ["US"])
        XCTAssertTrue(matches(withApp))
        XCTAssertFalse(matches(withApp, app: "Safari"))
        XCTAssertFalse(matches(withApp, pid: 1))
        XCTAssertFalse(matches(withApp, country: "DE"))

        let withText = TrafficSearchFilter(freeText: "messages", countries: ["US"])
        XCTAssertTrue(matches(withText))
        XCTAssertFalse(matches(withText, url: "https://api.anthropic.com/v1/models"))
    }

    /// A caller that did not resolve the destination passes `country: nil`
    /// EXPLICITLY (the filter's `matches` has no default for it — errata 6 —
    /// so a call site cannot silently pass nothing), and nil satisfies no
    /// country chip, `unknown` included.
    func testANilCountryNeverSatisfiesACountryChip() {
        for token in ["US", "mac", "local", "unknown"] {
            XCTAssertFalse(matches(TrafficSearchFilter(countries: [token]), country: nil), "country:\(token) must not select an unresolved session")
        }
        XCTAssertTrue(matches(TrafficSearchFilter(countries: ["unknown"]), country: "unknown"))
        XCTAssertTrue(matches(TrafficSearchFilter(hosts: ["api.anthropic.com"]), country: nil), "a filter without a country chip is untouched by the omission")
    }

    /// Free text searches the URL, method, status and host — never the
    /// destination: `country:` and the map are the discovery paths.
    func testFreeTextDoesNotSearchTheCountry() {
        XCTAssertFalse(matches(TrafficSearchFilter(freeText: "US"), url: "https://api.anthropic.com/v1/messages", country: "US"))
        XCTAssertFalse(matches(TrafficSearchFilter(freeText: "United States"), country: "US"))
        XCTAssertFalse(matches(TrafficSearchFilter(freeText: "mac"), url: "https://api.anthropic.com/v1/messages", country: "mac"))
        XCTAssertTrue(matches(TrafficSearchFilter(freeText: "anthropic"), country: "US"), "still found in the host")
    }

    // MARK: - Adding, removing, ordering

    func testAddTokenNormalisesAndDeduplicatesCaseInsensitively() {
        var filter = TrafficSearchFilter()
        filter.addToken(.country("us"))
        filter.addToken(.country("US"))
        filter.addToken(.country("Us"))
        XCTAssertEqual(filter.countries, ["US"])
        filter.addToken(.country("MAC"))
        XCTAssertEqual(filter.countries, ["US", "mac"])
        XCTAssertTrue(filter.containsCountry("us"))
        XCTAssertTrue(filter.containsCountry("Mac"))
        XCTAssertFalse(filter.containsCountry("DE"))
    }

    /// A value that is not a token (a name, a typo) is refused rather than
    /// kept as a chip that can never match.
    func testAddTokenRefusesAValueThatIsNotAToken() {
        var filter = TrafficSearchFilter()
        filter.addToken(.country("Germany"))
        filter.addToken(.country("USA"))
        filter.addToken(.country(""))
        XCTAssertTrue(filter.countries.isEmpty)
        XCTAssertFalse(filter.hasTokens)
    }

    func testRemoveTokenIsCaseInsensitiveAndClearDropsCountries() {
        var filter = TrafficSearchFilter(countries: ["US", "DE"])
        filter.removeToken(.country("us"))
        XCTAssertEqual(filter.countries, ["DE"])
        XCTAssertTrue(filter.hasTokens)
        filter.clear()
        XCTAssertTrue(filter.countries.isEmpty)
        XCTAssertFalse(filter.hasTokens)
    }

    func testCountryChipsRenderLastInTheStableOrder() {
        let filter = TrafficSearchFilter(
            hosts: ["a.com"], methods: ["get"], statuses: [.exact(200)], paths: ["/v1"], apps: ["claude"], pids: [1], countries: ["US", "mac"]
        )
        let kinds = filter.tokens.map(\.kind)
        XCTAssertEqual(kinds, [.host, .method, .status, .path, .app, .pid, .country, .country])
        XCTAssertEqual(filter.tokens.suffix(2), [.country("US"), .country("mac")])
    }

    // MARK: - TrafficSearchCountryMatch on its own

    func testNormalizeRules() {
        XCTAssertEqual(TrafficSearchCountryMatch.normalize(" de "), "DE")
        XCTAssertEqual(TrafficSearchCountryMatch.normalize("Local"), "local")
        XCTAssertEqual(TrafficSearchCountryMatch.normalize("MAC"), "mac")
        XCTAssertEqual(TrafficSearchCountryMatch.normalize("Unknown"), "unknown")
        XCTAssertNil(TrafficSearchCountryMatch.normalize("germany"))
        XCTAssertNil(TrafficSearchCountryMatch.normalize("d1"))
        XCTAssertNil(TrafficSearchCountryMatch.normalize(""))
    }

    func testDisplayNameForEachToken() {
        XCTAssertEqual(TrafficSearchCountryMatch.displayName(forToken: "us"), "US")
        XCTAssertEqual(TrafficSearchCountryMatch.displayName(forToken: "mac"), "This Mac")
        XCTAssertEqual(TrafficSearchCountryMatch.displayName(forToken: "local"), "Local Network")
        XCTAssertEqual(TrafficSearchCountryMatch.displayName(forToken: "unknown"), "Unknown")
        XCTAssertEqual(TrafficSearchCountryMatch.displayName(forToken: "Germany"), "Germany", "an unnormalised value is shown as typed")
    }

    func testMatchesRefusesAWantedValueThatIsNotAToken() {
        XCTAssertFalse(TrafficSearchCountryMatch.matches("Germany", country: "DE"))
        XCTAssertFalse(TrafficSearchCountryMatch.matches("DE", country: "Germany"))
        XCTAssertTrue(TrafficSearchCountryMatch.matches("de", country: "DE"))
    }

    // MARK: - The two modules share one vocabulary (spec §1.3, §5.2)

    /// `TrafficSearchCountryMatch` (Utils) and `TrafficDestination` (MCPKit)
    /// each spell the three class words; the search field and the agent
    /// must mean the same thing by `local`, `mac` and `unknown`.
    func testTheClassWordsAreTheSameStringsInUtilsAndMCPKit() {
        XCTAssertEqual(TrafficSearchCountryMatch.local, TrafficDestination.localNetwork.token)
        XCTAssertEqual(TrafficSearchCountryMatch.mac, TrafficDestination.thisMac.token)
        XCTAssertEqual(TrafficSearchCountryMatch.unknown, TrafficDestination.unknown.token)
        XCTAssertEqual(Set(TrafficDestination.specialTokens), [TrafficSearchCountryMatch.local, TrafficSearchCountryMatch.mac, TrafficSearchCountryMatch.unknown])
    }

    /// And the Title Case labels the chip shows are the ones the window,
    /// the list rows and the agent's report print.
    func testTheClassLabelsAreTheSameStringsInUtilsAndMCPKit() {
        XCTAssertEqual(TrafficSearchCountryMatch.macDisplayName, TrafficDestination.thisMacLabel)
        XCTAssertEqual(TrafficSearchCountryMatch.localDisplayName, TrafficDestination.localNetworkLabel)
        XCTAssertEqual(TrafficSearchCountryMatch.unknownDisplayName, TrafficDestination.unknownLabel)
        for destination in [TrafficDestination.thisMac, .localNetwork, .unknown] {
            XCTAssertEqual(
                TrafficSearchCountryMatch.displayName(forToken: destination.token),
                CountryPresentation.title(for: destination),
                "the chip and the window must agree on \(destination.token)"
            )
        }
    }

    /// Whatever MCPKit parses as a token, Utils normalises to the same
    /// string, and vice versa — a `country:` chip and a `country=` filter
    /// select the same rows.
    func testEveryTokenParsesTheSameOnBothSides() {
        for input in ["us", "US", "De", "local", "MAC", "Unknown", "xx", "Germany", "USA", "", "u1"] {
            XCTAssertEqual(
                TrafficSearchCountryMatch.normalize(input),
                TrafficDestination.parseToken(input)?.token,
                "'\(input)' must normalise identically in Utils and MCPKit"
            )
        }
    }
}
