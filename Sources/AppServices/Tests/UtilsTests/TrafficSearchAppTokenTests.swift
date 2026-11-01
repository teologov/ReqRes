//
//  TrafficSearchAppTokenTests.swift
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
//  The `app:` token: the process that opened a captured connection, as a
//  search dimension. Two rules carry everything here — a process NAME is
//  matched as a case-insensitive substring, and a session with NO name is
//  matched by the table's own placeholder, `Unknown`, and by nothing else.
//  The last tests in each group pin that adding the kind changed nothing for
//  `host:`, `method:`, `status:`, `path:` or the free text.
//

import XCTest
@testable import Utils

final class TrafficSearchAppTokenTests: XCTestCase {

    // MARK: - Prefix parsing

    func testAppPrefixIsRecognisedCaseInsensitivelyWithSurroundingWhitespace() {
        let parsed = TrafficSearchTokenKind.parse("  App: Claude ")
        XCTAssertEqual(parsed?.kind, .app)
        XCTAssertEqual(parsed?.query, "Claude")
        XCTAssertEqual(TrafficSearchTokenKind.app.prefix, "app:")
    }

    func testBareAppPrefixHasAnEmptyQuery() {
        let parsed = TrafficSearchTokenKind.parse("app:")
        XCTAssertEqual(parsed?.kind, .app)
        XCTAssertEqual(parsed?.query, "")
    }

    func testAppPrefixNearMissesStayFreeText() {
        XCTAssertNil(TrafficSearchTokenKind.parse("application:Xcode"),
                     "must match the prefix, not merely start with its letters")
        XCTAssertNil(TrafficSearchTokenKind.parse("apps:Xcode"))
        XCTAssertNil(TrafficSearchTokenKind.parse("appclaude"))
    }

    /// The kind was appended, not inserted: `allCases` drives prefix parsing,
    /// and every earlier prefix still parses to itself. (`pid` was appended
    /// after it, by the same rule — UX spec §3.)
    func testAddingTheKindLeftTheOtherPrefixesAlone() {
        XCTAssertEqual(TrafficSearchTokenKind.allCases, [.host, .method, .status, .path, .app, .pid, .country, .outcome, .grpc, .proto])
        XCTAssertEqual(TrafficSearchTokenKind.parse("host:a.com")?.kind, .host)
        XCTAssertEqual(TrafficSearchTokenKind.parse("method:get")?.kind, .method)
        XCTAssertEqual(TrafficSearchTokenKind.parse("status:404")?.kind, .status)
        XCTAssertEqual(TrafficSearchTokenKind.parse("path:/v1")?.kind, .path)
    }

    // MARK: - Token

    func testAppTokenIdentityIgnoresCaseButDisplayKeepsIt() {
        let token = TrafficSearchToken.app("Claude")
        XCTAssertEqual(token.id, TrafficSearchToken.app("claude").id)
        XCTAssertNotEqual(token.id, TrafficSearchToken.host("claude").id,
                          "an app chip and a host chip with the same text are different chips")
        XCTAssertEqual(token.displayName, "Claude")
        XCTAssertEqual(token.kind, .app)
    }

    func testAppTokenParsesATrimmedQueryAndRefusesABlankOne() {
        XCTAssertEqual(TrafficSearchToken.parse(kind: .app, query: "  claude-code "), .app("claude-code"))
        XCTAssertNil(TrafficSearchToken.parse(kind: .app, query: "   "),
                     "a blank chip could never match, and must fall back to free text")
    }

    func testAppKindOffersNoStaticVocabulary() {
        XCTAssertTrue(TrafficSearchTokenKind.app.staticSuggestions.isEmpty, "apps come from the traffic, like hosts")
        XCTAssertTrue(TrafficSearchTokenKind.method.staticSuggestions.contains("GET"))
        XCTAssertTrue(TrafficSearchTokenKind.status.staticSuggestions.contains("5xx"))
    }

    // MARK: - The matching rule

    private func tokenMatches(_ wanted: String, app: String?) -> Bool {
        TrafficSearchToken.app(wanted).matches(
            host: "api.anthropic.com", url: "https://api.anthropic.com/v1/messages", method: "POST", status: "200", app: app
        )
    }

    func testAppTokenIsACaseInsensitiveSubstringOfTheProcessName() {
        XCTAssertTrue(tokenMatches("claude", app: "Claude"), "the desktop app")
        XCTAssertTrue(tokenMatches("claude", app: "claude-code"), "the CLI")
        XCTAssertTrue(tokenMatches("CLAUDE", app: "claude-code"), "case-insensitive both ways")
        XCTAssertTrue(tokenMatches("Brave", app: "Brave Browser Helper"), "a helper process carries its parent's name")
        XCTAssertFalse(tokenMatches("claude", app: "Safari"))
        XCTAssertFalse(tokenMatches("safari", app: "Xcode"))
    }

    func testASessionWithNoAppNameMatchesOnlyTheUnknownToken() {
        for spelling in ["unknown", "Unknown", "UNKNOWN", " unknown "] {
            XCTAssertTrue(tokenMatches(spelling, app: nil), "'\(spelling)' must select an unattributed session")
        }
        XCTAssertFalse(tokenMatches("unk", app: nil), "the placeholder is matched whole, not as a substring")
        XCTAssertFalse(tokenMatches("nown", app: nil))
        XCTAssertFalse(tokenMatches("claude", app: nil))
    }

    func testABlankAppNameCountsAsNoAppName() {
        for blank in ["", "   "] {
            XCTAssertTrue(tokenMatches("unknown", app: blank), "'\(blank)' is no name")
            XCTAssertFalse(tokenMatches("claude", app: blank))
        }
    }

    func testTheUnknownTokenIsTheTablesOwnWordForIt() {
        XCTAssertEqual(TrafficSearchAppMatch.unknown, "Unknown")
        XCTAssertTrue(TrafficSearchAppMatch.matches(TrafficSearchAppMatch.unknown, appName: nil),
                      "whatever the table prints for an unattributed row, typing it after app: must select the row")
    }

    func testANamedProcessMatchesTheUnknownTokenOnlyByItsOwnName() {
        XCTAssertFalse(tokenMatches("unknown", app: "Safari"), "a named process is not unknown")
        XCTAssertTrue(tokenMatches("unknown", app: "unknown-helper"), "but the substring rule still applies to a real name")
    }

    func testABlankQueryNeverMatches() {
        XCTAssertFalse(TrafficSearchAppMatch.matches("", appName: "Safari"), "an empty needle is not 'every app'")
        XCTAssertFalse(TrafficSearchAppMatch.matches("  ", appName: nil))
    }

    func testTheOtherTokensIgnoreTheAppInput() {
        let tokens: [TrafficSearchToken] = [
            .host("api.anthropic.com"), .method("post"), .status(.exact(200)), .path("/v1/messages"),
        ]
        for token in tokens {
            let without = token.matches(
                host: "api.anthropic.com", url: "https://api.anthropic.com/v1/messages", method: "POST", status: "200"
            )
            let with = token.matches(
                host: "api.anthropic.com", url: "https://api.anthropic.com/v1/messages", method: "POST", status: "200", app: "Claude"
            )
            XCTAssertTrue(without, "\(token) should match this session")
            XCTAssertEqual(without, with, "\(token) must not read the app")
        }
    }

    // MARK: - Filter matching

    private func matches(
        _ filter: TrafficSearchFilter,
        host: String = "api.anthropic.com",
        url: String = "https://api.anthropic.com/v1/messages",
        method: String = "POST",
        status: String? = "200",
        app: String? = "Claude"
    ) -> Bool {
        filter.matches(host: host, url: url, method: method, status: status, app: app, pid: nil, country: nil, outcome: nil, grpcStatus: nil, proto: nil)
    }

    func testAnEmptyFilterMatchesASessionWithOrWithoutAnApp() {
        XCTAssertTrue(matches(TrafficSearchFilter()))
        XCTAssertTrue(matches(TrafficSearchFilter(), app: nil))
    }

    func testAppTokensAreOrEdAmongThemselves() {
        let filter = TrafficSearchFilter(apps: ["claude", "xcode"])
        XCTAssertTrue(matches(filter, app: "Claude"))
        XCTAssertTrue(matches(filter, app: "Xcode"))
        XCTAssertTrue(matches(filter, app: "claude-code"))
        XCTAssertFalse(matches(filter, app: "Safari"))
        XCTAssertFalse(matches(filter, app: nil), "neither chip is Unknown")
    }

    func testUnknownAndANamedAppCanBeOrEdTogether() {
        let filter = TrafficSearchFilter(apps: ["Unknown", "claude"])
        XCTAssertTrue(matches(filter, app: nil))
        XCTAssertTrue(matches(filter, app: "Claude"))
        XCTAssertFalse(matches(filter, app: "Safari"))
    }

    func testAppTokenIsAndEdWithTheOtherKindsAndTheFreeText() {
        let withHost = TrafficSearchFilter(hosts: ["api.anthropic.com"], apps: ["claude"])
        XCTAssertTrue(matches(withHost))
        XCTAssertFalse(matches(withHost, host: "api.openai.com"), "right app, wrong host")
        XCTAssertFalse(matches(withHost, app: "Safari"), "right host, wrong app")

        let withMethod = TrafficSearchFilter(methods: ["POST"], apps: ["claude"])
        XCTAssertTrue(matches(withMethod))
        XCTAssertFalse(matches(withMethod, method: "GET"))

        let withStatus = TrafficSearchFilter(statuses: [.range(500...599)], apps: ["claude"])
        XCTAssertTrue(matches(withStatus, status: "503"))
        XCTAssertFalse(matches(withStatus, status: "200"))

        let withPath = TrafficSearchFilter(paths: ["/v1/messages"], apps: ["claude"])
        XCTAssertTrue(matches(withPath))
        XCTAssertFalse(matches(withPath, url: "https://api.anthropic.com/v1/complete"))

        let withText = TrafficSearchFilter(freeText: "messages", apps: ["claude"])
        XCTAssertTrue(matches(withText))
        XCTAssertFalse(matches(withText, url: "https://api.anthropic.com/v1/complete"), "right app, wrong text")
        XCTAssertFalse(matches(withText, app: "Safari"), "right text, wrong app")
    }

    /// The free text searches the URL, method, status and host — not the
    /// process. `claude` typed bare finds claude.ai, not Claude's traffic;
    /// that is what the token is for, and what keeps attribution from
    /// changing the meaning of a search that predates it.
    func testFreeTextDoesNotSearchTheAppName() {
        XCTAssertFalse(matches(TrafficSearchFilter(freeText: "claude"), app: "Claude"))
        XCTAssertTrue(matches(TrafficSearchFilter(freeText: "anthropic"), app: "Claude"), "still found in the host")
    }

    /// A caller with no attribution passes `app: nil` EXPLICITLY (the filter's
    /// `matches` has no default for it — UX spec errata 6 — so a call site
    /// cannot silently pass nothing), and nil means "no app name": only
    /// `app:unknown` can select those sessions.
    func testACallerThatPassesANilAppIsTreatedAsUnattributed() {
        let unknown = TrafficSearchFilter(apps: ["unknown"])
        XCTAssertTrue(unknown.matches(host: "a.com", url: "https://a.com/", method: "GET", status: "200", app: nil, pid: nil, country: nil, outcome: nil, grpcStatus: nil, proto: nil))
        let claude = TrafficSearchFilter(apps: ["claude"])
        XCTAssertFalse(claude.matches(host: "a.com", url: "https://a.com/", method: "GET", status: "200", app: nil, pid: nil, country: nil, outcome: nil, grpcStatus: nil, proto: nil))
        XCTAssertTrue(TrafficSearchFilter(hosts: ["a.com"]).matches(host: "a.com", url: "https://a.com/", method: "GET", status: "200", app: nil, pid: nil, country: nil, outcome: nil, grpcStatus: nil, proto: nil),
                      "a filter without an app chip is untouched by the omission")
    }

    /// Would catch the app input leaking into another kind's check: every
    /// filter without an `app:` chip answers the same whatever the app is.
    func testFiltersWithoutAppTokensAnswerTheSameWhateverTheApp() {
        let filters: [TrafficSearchFilter] = [
            TrafficSearchFilter(hosts: ["api.anthropic.com"]),
            TrafficSearchFilter(hosts: ["other.com"]),
            TrafficSearchFilter(methods: ["POST"]),
            TrafficSearchFilter(methods: ["GET"]),
            TrafficSearchFilter(statuses: [.exact(200)]),
            TrafficSearchFilter(statuses: [.range(400...499)]),
            TrafficSearchFilter(paths: ["/v1/messages"]),
            TrafficSearchFilter(paths: ["/v1/complete"]),
            TrafficSearchFilter(freeText: "messages"),
            TrafficSearchFilter(freeText: "orders"),
            TrafficSearchFilter(freeText: "post", hosts: ["api.anthropic.com"], statuses: [.range(200...299)]),
        ]
        for filter in filters {
            let baseline = matches(filter, app: nil)
            for app in ["Claude", "Safari", "", "Unknown"] {
                XCTAssertEqual(matches(filter, app: app), baseline, "\(filter) changed its answer for app '\(app)'")
            }
        }
    }

    // MARK: - Filter editing

    func testAddingTheSameAppTwiceKeepsOneChip() {
        var filter = TrafficSearchFilter()
        filter.addToken(.app("claude"))
        filter.addToken(.app("CLAUDE"))
        filter.addToken(.app("  claude "))
        XCTAssertEqual(filter.apps, ["claude"])
        XCTAssertEqual(filter.tokens, [.app("claude")])
    }

    func testDifferentAppFragmentsAreSeparateChipsEvenWhenOneContainsTheOther() {
        var filter = TrafficSearchFilter()
        filter.addToken(.app("claude"))
        filter.addToken(.app("claude-code"))
        XCTAssertEqual(filter.apps, ["claude", "claude-code"], "dedupe is exact, not substring")
    }

    func testBlankAppIsNeverCommitted() {
        var filter = TrafficSearchFilter()
        filter.addToken(.app("   "))
        XCTAssertTrue(filter.isEmpty)
        XCTAssertFalse(filter.hasTokens)
    }

    func testRemovingAnAppIsCaseInsensitive() {
        var filter = TrafficSearchFilter(apps: ["Claude", "Xcode"])
        filter.removeToken(.app("CLAUDE"))
        XCTAssertEqual(filter.apps, ["Xcode"])
    }

    func testAnAppChipAloneCountsAsATokenAndClearDropsIt() {
        var filter = TrafficSearchFilter(apps: ["claude"])
        XCTAssertTrue(filter.hasTokens)
        XCTAssertFalse(filter.isEmpty)
        filter.clear()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertEqual(filter.apps, [])
    }

    func testContainsAppIsCaseInsensitiveAndExact() {
        let filter = TrafficSearchFilter(apps: ["Claude"])
        XCTAssertTrue(filter.containsApp("claude"))
        XCTAssertFalse(filter.containsApp("claude-code"))
        XCTAssertFalse(filter.containsHost("Claude"), "an app chip is not a host chip")
    }

    func testAppChipsComeLastSoEarlierChipsDoNotReshuffle() {
        var filter = TrafficSearchFilter(hosts: ["a.com"], methods: ["GET"], statuses: [.exact(200)], paths: ["/v1"])
        let before = filter.tokens
        filter.addToken(.app("claude"))
        XCTAssertEqual(Array(filter.tokens.prefix(before.count)), before)
        XCTAssertEqual(filter.tokens.last, .app("claude"))
        XCTAssertEqual(filter.tokens.count, 5)
    }

    // MARK: - Suggestions

    private let candidates = ["Safari", "Claude", "claude-code", "Xcode", "Unknown", "Brave Browser Helper", "CLAUDE"]

    func testEmptyQueryOffersTheLeadingCandidatesInOrder() {
        XCTAssertEqual(
            TrafficSearchSuggestions.apps(matching: "", in: candidates, excluding: [], limit: 3),
            ["Safari", "Claude", "claude-code"]
        )
    }

    func testPrefixMatchesComeBeforeSubstringMatchesEachKeepingCandidateOrder() {
        // "c": Claude and claude-code start with it; Xcode merely contains it.
        XCTAssertEqual(
            TrafficSearchSuggestions.apps(matching: "c", in: candidates, excluding: []),
            ["Claude", "claude-code", "Xcode"]
        )
    }

    func testCommittedAppsAreExcludedExactlyAndDuplicatesCollapse() {
        let apps = TrafficSearchSuggestions.apps(matching: "cla", in: candidates, excluding: ["claude"])
        XCTAssertEqual(apps, ["claude-code"], "the committed chip is gone in any case; the longer name it prefixes stays")
        let all = TrafficSearchSuggestions.apps(matching: "", in: candidates, excluding: [])
        XCTAssertEqual(all.count, 6, "CLAUDE collapses into Claude")
    }

    func testUnknownIsOfferedLikeAnyOtherCandidateWhenTheCallerSuppliesIt() {
        XCTAssertEqual(TrafficSearchSuggestions.apps(matching: "unk", in: candidates, excluding: []), ["Unknown"])
        XCTAssertEqual(TrafficSearchSuggestions.apps(matching: "unk", in: ["Safari", "Xcode"], excluding: []), [],
                       "not invented when the caller has no unattributed sessions to offer")
    }

    func testAppQueryIsCaseInsensitiveAndTrimmedAndTheLimitIsRespected() {
        XCTAssertEqual(TrafficSearchSuggestions.apps(matching: "  XC ", in: candidates, excluding: []), ["Xcode"])
        XCTAssertEqual(TrafficSearchSuggestions.apps(matching: "", in: candidates, excluding: [], limit: 1), ["Safari"])
        XCTAssertEqual(TrafficSearchSuggestions.apps(matching: "", in: candidates, excluding: [], limit: 0), [])
    }

    /// Both panels rank through one function; if they ever diverge this fails.
    func testAppAndHostSuggestionsRankIdentically() {
        for query in ["", "c", "de", "  XC "] {
            XCTAssertEqual(
                TrafficSearchSuggestions.apps(matching: query, in: candidates, excluding: ["Safari"], limit: 4),
                TrafficSearchSuggestions.hosts(matching: query, in: candidates, excluding: ["Safari"], limit: 4),
                "query '\(query)'"
            )
        }
    }
}
