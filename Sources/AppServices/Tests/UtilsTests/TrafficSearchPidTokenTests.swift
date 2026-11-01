//
//  TrafficSearchPidTokenTests.swift
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
//  The `pid:` token (UX spec §3): one process by id. Exact match, OR-ed with
//  other pid chips, AND-ed with every other kind; a session without a pid
//  never satisfies one; digits-only parse, so `pid:curl` stays free text.
//

import XCTest
@testable import Utils

final class TrafficSearchPidTokenTests: XCTestCase {

    // MARK: - Prefix parsing

    func testPidPrefixIsRecognisedCaseInsensitivelyWithSurroundingWhitespace() {
        let parsed = TrafficSearchTokenKind.parse("  PID: 9437 ")
        XCTAssertEqual(parsed?.kind, .pid)
        XCTAssertEqual(parsed?.query, "9437")
        XCTAssertEqual(TrafficSearchTokenKind.pid.prefix, "pid:")
    }

    func testPidPrefixNearMissesStayFreeText() {
        XCTAssertNil(TrafficSearchTokenKind.parse("pids:9437"))
        XCTAssertNil(TrafficSearchTokenKind.parse("pid9437"))
        XCTAssertNil(TrafficSearchTokenKind.parse("process:9437"))
    }

    /// Appended at the END: `allCases` drives prefix parsing, and every
    /// earlier prefix still parses to itself.
    func testTheKindWasAppendedLast() {
        // `country` and then `outcome` were appended after it, by the same
        // rule (destination-map UX spec §5.2, protocol PRD 3.4); pid still
        // parses to itself.
        XCTAssertEqual(TrafficSearchTokenKind.allCases.last, .proto)
        XCTAssertEqual(TrafficSearchTokenKind.parse("pid:9437")?.kind, .pid)
        XCTAssertEqual(TrafficSearchTokenKind.parse("app:claude")?.kind, .app)
        XCTAssertEqual(TrafficSearchTokenKind.parse("path:/v1")?.kind, .path)
    }

    func testPidKindOffersNoStaticVocabulary() {
        XCTAssertTrue(TrafficSearchTokenKind.pid.staticSuggestions.isEmpty, "pids come from the traffic")
    }

    // MARK: - Token

    func testPidTokenIdentityAndDisplay() {
        let token = TrafficSearchToken.pid(9437)
        XCTAssertEqual(token.id, "pid-9437")
        XCTAssertEqual(token.displayName, "pid 9437", "always written `pid N`, never a bare number")
        XCTAssertEqual(token.kind, .pid)
        XCTAssertNotEqual(token.id, TrafficSearchToken.app("9437").id, "a pid chip and an app chip with the same digits differ")
    }

    func testPidTokenParsesDigitsOnly() {
        XCTAssertEqual(TrafficSearchToken.parse(kind: .pid, query: " 9437 "), .pid(9437))
        XCTAssertNil(TrafficSearchToken.parse(kind: .pid, query: "0"), "pid 0 is the kernel — free text, like the registry's processID rule")
        for rejected in ["curl", "94a37", "-5", "+5", "9437 9438", "", "   ", "9437.0", "٩٤٣٧"] {
            XCTAssertNil(TrafficSearchToken.parse(kind: .pid, query: rejected),
                         "'\(rejected)' cannot be a pid and must fall back to free text")
        }
        XCTAssertNil(TrafficSearchToken.parse(kind: .pid, query: String(repeating: "9", count: 40)), "overflow is not a pid")
    }

    // MARK: - The matching rule, per token

    private func tokenMatches(_ wanted: Int, pid: Int?) -> Bool {
        TrafficSearchToken.pid(wanted).matches(
            host: "api.anthropic.com", url: "https://api.anthropic.com/v1/messages", method: "POST", status: "200",
            app: "claude", pid: pid
        )
    }

    func testPidTokenMatchesExactlyAndNeverANilPid() {
        XCTAssertTrue(tokenMatches(9437, pid: 9437))
        XCTAssertFalse(tokenMatches(9437, pid: 9767), "a second claude process is a different pid")
        XCTAssertFalse(tokenMatches(9437, pid: nil), "an unattributed session matches no pid token")
        XCTAssertFalse(tokenMatches(943, pid: 9437), "no prefix or substring on digits")
    }

    /// The token-level defaults stay: a token's semantics can be stated
    /// without an attribution in hand, and omitting the pid means none.
    func testATokenCalledWithoutAPidTreatsItAsNone() {
        XCTAssertFalse(TrafficSearchToken.pid(1).matches(host: "a.com", url: "https://a.com/", method: "GET", status: "200"))
        XCTAssertTrue(TrafficSearchToken.host("a.com").matches(host: "a.com", url: "https://a.com/", method: "GET", status: "200"))
    }

    func testTheOtherTokensIgnoreThePidInput() {
        let tokens: [TrafficSearchToken] = [
            .host("api.anthropic.com"), .method("post"), .status(.exact(200)), .path("/v1/messages"), .app("claude"),
        ]
        for token in tokens {
            let without = token.matches(
                host: "api.anthropic.com", url: "https://api.anthropic.com/v1/messages", method: "POST", status: "200", app: "claude", pid: nil
            )
            let with = token.matches(
                host: "api.anthropic.com", url: "https://api.anthropic.com/v1/messages", method: "POST", status: "200", app: "claude", pid: 9437
            )
            XCTAssertTrue(without, "\(token) should match this session")
            XCTAssertEqual(without, with, "\(token) must not read the pid")
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
        pid: Int? = 9437
    ) -> Bool {
        filter.matches(host: host, url: url, method: method, status: status, app: app, pid: pid, country: nil, outcome: nil, grpcStatus: nil, proto: nil)
    }

    func testAnEmptyFilterMatchesWithOrWithoutAPid() {
        XCTAssertTrue(matches(TrafficSearchFilter()))
        XCTAssertTrue(matches(TrafficSearchFilter(), pid: nil))
    }

    func testPidChipsAreORedAmongThemselves() {
        let filter = TrafficSearchFilter(pids: [9437, 9767])
        XCTAssertTrue(matches(filter, pid: 9437))
        XCTAssertTrue(matches(filter, pid: 9767))
        XCTAssertFalse(matches(filter, pid: 4127))
        XCTAssertFalse(matches(filter, pid: nil), "nil pid never matches a pid chip")
    }

    func testPidChipsAreANDedWithEveryOtherKind() {
        let filter = TrafficSearchFilter(hosts: ["api.anthropic.com"], methods: ["POST"], statuses: [.exact(200)], paths: ["/v1"], apps: ["claude"], pids: [9437])
        XCTAssertTrue(matches(filter))
        XCTAssertFalse(matches(filter, host: "other.com"))
        XCTAssertFalse(matches(filter, method: "GET"))
        XCTAssertFalse(matches(filter, status: "500"))
        XCTAssertFalse(matches(filter, url: "https://api.anthropic.com/v2/x"))
        XCTAssertFalse(matches(filter, app: "Safari"))
        XCTAssertFalse(matches(filter, pid: 9767))
    }

    /// `app:claude pid:9437` is "this one claude process"; the app chip does
    /// not widen the pid chip and the pid chip does not narrow the app chip.
    func testAppAndPidTogetherSelectOneProcess() {
        let filter = TrafficSearchFilter(apps: ["claude"], pids: [9437])
        XCTAssertTrue(matches(filter, app: "claude", pid: 9437))
        XCTAssertFalse(matches(filter, app: "claude", pid: 9767))
        XCTAssertTrue(matches(filter, app: "Claude Helper", pid: 9437), "the app chip is still a substring match")
        XCTAssertFalse(matches(filter, app: "Safari", pid: 9437), "the right pid under the wrong app is not this process")
    }

    func testFreeTextIsANDedWithAPidChip() {
        XCTAssertTrue(matches(TrafficSearchFilter(freeText: "messages", pids: [9437])))
        XCTAssertFalse(matches(TrafficSearchFilter(freeText: "nowhere", pids: [9437])))
    }

    /// Free text never reads the pid: typing 9437 does not find a process.
    func testFreeTextDoesNotSearchThePid() {
        XCTAssertFalse(matches(TrafficSearchFilter(freeText: "9437"), pid: 9437))
    }

    /// Every filter without a pid chip answers the same for any pid — the
    /// input cannot leak into another kind's check.
    func testFiltersWithoutAPidChipIgnoreThePidInput() {
        let filters: [TrafficSearchFilter] = [
            TrafficSearchFilter(),
            TrafficSearchFilter(freeText: "messages"),
            TrafficSearchFilter(hosts: ["api.anthropic.com"]),
            TrafficSearchFilter(methods: ["POST"]),
            TrafficSearchFilter(statuses: [.range(200...299)]),
            TrafficSearchFilter(paths: ["/v1"]),
            TrafficSearchFilter(apps: ["claude"]),
        ]
        for filter in filters {
            let baseline = matches(filter, pid: nil)
            for pid in [1, 9437, 99_999] {
                XCTAssertEqual(matches(filter, pid: pid), baseline, "\(filter) changed its answer for pid \(pid)")
            }
        }
    }

    // MARK: - Filter editing

    func testAddingTheSamePidTwiceKeepsOneChip() {
        var filter = TrafficSearchFilter()
        filter.addToken(.pid(9437))
        filter.addToken(.pid(9437))
        XCTAssertEqual(filter.pids, [9437])
        XCTAssertEqual(filter.tokens, [.pid(9437)])
    }

    func testRemovingAPidChip() {
        var filter = TrafficSearchFilter(pids: [9437, 9767])
        filter.removeToken(.pid(9437))
        XCTAssertEqual(filter.pids, [9767])
        XCTAssertTrue(filter.containsPid(9767))
        XCTAssertFalse(filter.containsPid(9437))
    }

    func testAPidChipAloneCountsAsATokenAndClearDropsIt() {
        var filter = TrafficSearchFilter(pids: [9437])
        XCTAssertTrue(filter.hasTokens)
        XCTAssertFalse(filter.isEmpty)
        filter.clear()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertEqual(filter.pids, [])
    }

    /// Token order is hosts, methods, statuses, paths, apps, pids — the pid
    /// chip lands last so no earlier chip reshuffles when one is added.
    func testPidChipsComeLastInTokenOrder() {
        var filter = TrafficSearchFilter(hosts: ["a.com"], methods: ["GET"], statuses: [.exact(200)], paths: ["/v1"], apps: ["claude"])
        let before = filter.tokens
        filter.addToken(.pid(9437))
        XCTAssertEqual(Array(filter.tokens.prefix(before.count)), before)
        XCTAssertEqual(filter.tokens, [.host("a.com"), .method("GET"), .status(.exact(200)), .path("/v1"), .app("claude"), .pid(9437)])
    }

    /// Adding a pid chip changes nothing for `app:`: the two are independent
    /// lists edited independently.
    func testAddingAPidLeavesTheAppChipsAlone() {
        var filter = TrafficSearchFilter(apps: ["claude"])
        filter.addToken(.pid(9437))
        filter.removeToken(.pid(9437))
        XCTAssertEqual(filter.apps, ["claude"])
        XCTAssertTrue(filter.containsApp("claude"))
        XCTAssertEqual(filter.pids, [])
    }
}
