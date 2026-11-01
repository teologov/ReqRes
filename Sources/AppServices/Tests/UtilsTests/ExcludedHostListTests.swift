//
//  ExcludedHostListTests.swift
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
//  These pin the semantics for BOTH sides: the settings UI here and the
//  core's `MitmService.isExcluded`, which implements the same rules against a
//  live connection and cannot import this module.
//
//  The asymmetry to keep in mind while reading: a false positive here stops
//  traffic being captured (annoying, visible), a false negative re-signs a
//  connection the user asked us not to touch (silent, and breaks codesign).
//  Both are bad, which is why matching is exact and wildcards are narrow.
//

import XCTest
@testable import Utils

final class ExcludedHostListTests: XCTestCase {
    func testTheDefaultCoversTheCodesignTimestampService() {
        let list = ExcludedHostList()

        XCTAssertTrue(list.excludes("timestamp.apple.com"))
        XCTAssertEqual(list.hosts, ExcludedHostList.recommended)
    }

    /// The Destinations map is Apple Maps; its tiles are fetched by `geod`,
    /// and every host the daemon was measured talking to (2026-09-25,
    /// capture off) is under `ls.apple.com`. Whether those fetches reach the
    /// proxy, and whether Apple pins the certificates, is for the live run.
    func testTheDefaultRelaysAppleMapsUntouched() {
        let list = ExcludedHostList()

        for host in ["gspe19-ssl.ls.apple.com", "gspe19-2-ssl.ls.apple.com", "gsp-ssl.ls.apple.com", "gspe35-ssl.ls.apple.com", "gspe21-ssl.ls.apple.com", "gspe85-ssl.ls.apple.com", "configuration.ls.apple.com"] {
            XCTAssertTrue(list.excludes(host), "\(host) is a map host and must be relayed")
        }
        XCTAssertFalse(list.excludes("ls.apple.com"), "the wildcard covers subdomains only")
        XCTAssertFalse(list.excludes("apple.com"), "the rest of Apple is still captured")
        XCTAssertFalse(list.excludes("api.apple-cloudkit.com"))
    }

    func testEveryRecommendedEntryHasAReasonAndNothingElseDoes() {
        for entry in ExcludedHostList.recommended {
            XCTAssertNotNil(ExcludedHostList.recommendedReason(for: entry), "\(entry) needs the sentence the Settings row shows")
        }
        XCTAssertEqual(ExcludedHostList.recommendedReason(for: "*.LS.apple.com"), ExcludedHostList.recommendedReason(for: "*.ls.apple.com"), "reasons are matched on the canonical spelling")
        XCTAssertNil(ExcludedHostList.recommendedReason(for: "api.example.com"))
    }

    /// A stored list from before `*.ls.apple.com` was recommended lacks it;
    /// the pane offers it back. A list the user emptied lacks both.
    func testMissingRecommendedNamesWhatAnOlderListLacks() {
        XCTAssertEqual(ExcludedHostList(hosts: ["timestamp.apple.com"]).missingRecommended, ["*.ls.apple.com"])
        XCTAssertEqual(ExcludedHostList(hosts: ["TIMESTAMP.apple.com.", "*.ls.apple.com"]).missingRecommended, [])
        XCTAssertEqual(ExcludedHostList(hosts: []).missingRecommended, ExcludedHostList.recommended)
        XCTAssertEqual(ExcludedHostList().missingRecommended, [])
    }

    func testMatchingIsExactAndCaseInsensitive() {
        let list = ExcludedHostList(hosts: ["API.Example.com"])

        XCTAssertTrue(list.excludes("api.example.com"))
        XCTAssertTrue(list.excludes("API.EXAMPLE.COM"))
        XCTAssertTrue(list.excludes("api.example.com."), "an FQDN's trailing dot is the same host")
        XCTAssertTrue(list.excludes("api.example.com:443"), "a port does not change which host it is")
        XCTAssertFalse(list.excludes("other.example.com"))
        XCTAssertFalse(list.excludes("api.example.com.evil.test"))
    }

    /// A wildcard covers subdomains, not the bare domain — the shape a TLS
    /// wildcard certificate covers.
    func testALeadingWildcardCoversSubdomainsOnly() {
        let list = ExcludedHostList(hosts: ["*.apple.com"])

        XCTAssertTrue(list.excludes("timestamp.apple.com"))
        XCTAssertTrue(list.excludes("a.b.apple.com"))
        XCTAssertFalse(list.excludes("apple.com"), "the bare domain is not a subdomain of itself")
        XCTAssertFalse(list.excludes("evil-apple.com"), "a plain suffix match would have let this through")
    }

    func testAnUnusableEntryExcludesNothingRatherThanEverything() {
        let list = ExcludedHostList(hosts: ["", "   ", "*", "*.", "two words"])

        for host in ["api.example.com", "apple.com", "anything.test"] {
            XCTAssertFalse(list.excludes(host), "a broken row must never turn into \"stop capturing\"")
        }
    }

    func testAnUnknownHostIsNeverExcluded() {
        let list = ExcludedHostList()

        XCTAssertFalse(list.excludes(nil))
        XCTAssertFalse(list.excludes(""))
    }

    // MARK: - Editing

    func testCanonicalEntryAcceptsHostsAndNarrowWildcards() {
        XCTAssertEqual(ExcludedHostList.canonicalEntry(" API.Example.com. "), "api.example.com")
        XCTAssertEqual(ExcludedHostList.canonicalEntry("*.Apple.com"), "*.apple.com")
        XCTAssertEqual(ExcludedHostList.canonicalEntry("api.example.com:8443"), "api.example.com")
    }

    /// A single-label entry is refused: "localhost" or a typo like "apple"
    /// matches nothing, and the user would read that as the feature failing.
    func testCanonicalEntryRejectsWhatCouldNeverMatch() {
        for raw in ["", "  ", "*", "*.", "*.com*", "ap*le.com", "two words", "apple"] {
            XCTAssertNil(ExcludedHostList.canonicalEntry(raw), "\(raw) should be refused")
        }
    }

    func testAddingStoresTheCanonicalFormAndRefusesDuplicates() throws {
        let list = try XCTUnwrap(ExcludedHostList(hosts: []).adding(" API.Example.com "))

        XCTAssertEqual(list.hosts, ["api.example.com"])
        XCTAssertNil(list.adding("api.example.com."), "the same host in another spelling is not a second entry")
        XCTAssertNil(list.adding("nonsense"))
    }

    func testRemovingTakesEverySpellingOfTheHost() {
        let list = ExcludedHostList(hosts: ["API.example.com", "api.example.com.", "other.example.com"])

        let updated = list.removing("api.example.com")

        XCTAssertEqual(updated.hosts, ["other.example.com"])
        XCTAssertFalse(updated.excludes("api.example.com"), "a leftover spelling would keep relaying it")
    }

    // MARK: - The note under the field (F13)

    /// The refusal is `adding(_:)`'s, named: nil exactly when an Add succeeds.
    func testTheRefusalSaysWhyAddingFailsAndNothingElse() {
        let list = ExcludedHostList(hosts: ["api.example.com", "*.cdn.example.com"])

        XCTAssertEqual(list.refusal(toAdd: "API.example.com."), .alreadyExcluded, "another spelling of a listed host")
        XCTAssertEqual(list.refusal(toAdd: "*.CDN.example.com"), .alreadyExcluded)
        XCTAssertEqual(list.refusal(toAdd: "two words"), .unmatchable)
        XCTAssertEqual(list.refusal(toAdd: "apple"), .unmatchable, "a single label never matches")
        XCTAssertNil(list.refusal(toAdd: "other.example.com"))
        for raw in ["api.example.com", "API.example.com.", "*.cdn.example.com", "img.cdn.example.com", "two words", "apple", "other.example.com", "  "] {
            XCTAssertEqual(list.refusal(toAdd: raw) == nil, list.adding(raw) != nil, raw)
        }
    }

    /// The defect: "“example.net” is already excluded." stayed after
    /// example.net was removed and the field emptied — the note was stored
    /// text only a later successful Add cleared. Derived now from
    /// the text Add refused, the field and the list, each of which moves it.
    func testTheAlreadyExcludedNoteBelongsToTheRefusedTextAndTheListAsItIs() {
        let list = ExcludedHostList(hosts: ["example.net"])

        XCTAssertEqual(list.refusalNote(submitted: "example.net", current: "example.net"), "“example.net” is already excluded.")
        XCTAssertNil(list.refusalNote(submitted: "example.net", current: ""), "the field emptied")
        XCTAssertNil(list.refusalNote(submitted: "example.net", current: "example.ne"), "the field edited")
        XCTAssertNil(list.removing("example.net").refusalNote(submitted: "example.net", current: "example.net"),
                     "removed from the list: the text can be added now, so nothing is refused")
        XCTAssertNil(list.refusalNote(submitted: nil, current: "example.net"), "typing is not adding")
    }

    func testTheCannotMatchNoteStaysWhateverTheListUntilTheFieldChanges() {
        let expected = "ReqRes cannot match “apple”. Use a host like api.example.com, or *.example.com for its subdomains."
        for list in [ExcludedHostList(), ExcludedHostList(hosts: [])] {
            XCTAssertEqual(list.refusalNote(submitted: "apple", current: "apple"), expected)
            XCTAssertNil(list.refusalNote(submitted: "apple", current: "apple.com"))
        }
    }

    /// The note quotes the host as typed, without the spaces around it.
    func testTheNoteQuotesTheTextWithoutItsSurroundingSpaces() {
        XCTAssertEqual(ExcludedHostList(hosts: ["example.net"]).refusalNote(submitted: " example.net ", current: " example.net "),
                       "“example.net” is already excluded.")
    }

    func testTheSummarySaysWhatIsActuallyExcluded() {
        XCTAssertEqual(ExcludedHostList(hosts: []).summary, "Every host but ReqRes's license server is intercepted.")
        XCTAssertTrue(ExcludedHostList(hosts: ["a.test"]).summary.contains("1 host"))
        XCTAssertTrue(ExcludedHostList(hosts: ["a.test", "b.test"]).summary.contains("a.test, b.test"))
    }

    func testAStoredListSurvivesARoundTrip() throws {
        let list = try XCTUnwrap(ExcludedHostList().adding("*.staging.example.com"))

        let restored = try JSONDecoder().decode(ExcludedHostList.self, from: JSONEncoder().encode(list))

        XCTAssertEqual(restored, list)
        XCTAssertTrue(restored.excludes("api.staging.example.com"))
    }
    // MARK: - reqresapp.com, always excluded (pay-once PRD A16)

    /// The engine relays the license server in code whatever list it is
    /// pushed (core C2); this is the row that says so, and it must agree.
    func testTheLicenseServerIsExcludedWithNothingListed() {
        XCTAssertEqual(ExcludedHostList.builtIn, ["reqresapp.com", "*.reqresapp.com"])
        XCTAssertEqual(ExcludedHostList.builtInReason, "ReqRes's license server: never intercepted")
        let list = ExcludedHostList(hosts: [])

        XCTAssertEqual(list.hosts, [], "the built-in entries are not the user's")
        for host in ["reqresapp.com", "REQRESAPP.com.", "reqresapp.com:443", "api.reqresapp.com", "a.b.reqresapp.com"] {
            XCTAssertTrue(list.excludes(host), "\(host) is the license server")
        }
        XCTAssertEqual(list.allEntries, ["reqresapp.com", "*.reqresapp.com"])
        XCTAssertEqual(ExcludedHostList().allEntries, ExcludedHostList.builtIn + ExcludedHostList.recommended, "built-in first")
    }

    func testALookAlikeHostIsStillCaptured() {
        let list = ExcludedHostList(hosts: [])

        for host in ["evil-reqresapp.com", "reqresapp.com.evil.test", "reqresapp.co", "notreqresapp.com"] {
            XCTAssertFalse(list.excludes(host), "\(host) is not the license server")
            XCTAssertNil(ExcludedHostList.builtInEntry(covering: host), host)
            XCTAssertNotNil(list.adding(host), "\(host) can be excluded like any host")
        }
        XCTAssertNil(ExcludedHostList.builtInEntry(covering: "*.evil-reqresapp.com"))
    }

    func testTheBuiltInEntriesCannotBeRemoved() {
        for list in [ExcludedHostList(), ExcludedHostList(hosts: [])] {
            for raw in ExcludedHostList.builtIn + ["REQRESAPP.COM.", "api.reqresapp.com"] {
                let updated = list.removing(raw)
                XCTAssertTrue(updated.excludes("reqresapp.com"), "removing \(raw)")
                XCTAssertTrue(updated.excludes("api.reqresapp.com"), "removing \(raw)")
                XCTAssertEqual(updated.hosts, list.hosts, "removing \(raw) touches nothing the user listed")
            }
        }
    }

    /// Adding is refused as ALREADY excluded (not as unmatchable), for the
    /// entries themselves and for anything under them.
    func testAddingTheLicenseServerIsRefusedAsAlreadyExcluded() {
        let list = ExcludedHostList()
        let covered = ["reqresapp.com": "reqresapp.com", " ReqResApp.com. ": "reqresapp.com",
                       "*.reqresapp.com": "*.reqresapp.com", "api.reqresapp.com": "*.reqresapp.com",
                       "*.api.reqresapp.com": "*.reqresapp.com", "reqresapp.com:8443": "reqresapp.com"]
        for (raw, entry) in covered {
            XCTAssertNil(list.adding(raw), raw)
            XCTAssertEqual(list.refusal(toAdd: raw), .alreadyExcluded, raw)
            XCTAssertEqual(ExcludedHostList.builtInEntry(covering: raw), entry, raw)
            XCTAssertEqual(list.coveringEntry(for: raw), entry, raw)
        }
        XCTAssertEqual(list.refusalNote(submitted: "reqresapp.com", current: "reqresapp.com"),
                       "“reqresapp.com” is already excluded: ReqRes's license server is never intercepted.")
        XCTAssertEqual(list.refusalNote(submitted: "example.net", current: "example.net"), nil, "an ordinary host is still added")
    }

    /// What exclude_host asks before anyone approves: the user's own entries
    /// keep their old answers (exact spelling, or a listed wildcard above a
    /// plain host), and the built-in ones come first.
    func testTheCoveringEntryIsTheBuiltInOneOrTheListedOne() {
        let list = ExcludedHostList(hosts: ["API.example.com", "*.cdn.example.com"])

        XCTAssertEqual(list.coveringEntry(for: "api.example.com."), "API.example.com")
        XCTAssertEqual(list.coveringEntry(for: "img.cdn.example.com"), "*.cdn.example.com")
        XCTAssertEqual(list.coveringEntry(for: "*.CDN.example.com"), "*.cdn.example.com")
        XCTAssertNil(list.coveringEntry(for: "*.img.cdn.example.com"), "a narrower wildcard was always added, as before")
        XCTAssertNil(list.coveringEntry(for: "other.example.com"))
        XCTAssertNil(list.coveringEntry(for: "two words"))
        XCTAssertEqual(list.coveringEntry(for: "reqresapp.com"), "reqresapp.com")
    }

    /// The stored shape is unchanged and never holds a built-in entry; one a
    /// user typed into an older build is dropped on reading, and the server
    /// stays excluded either way.
    func testTheBuiltInEntriesSurviveAStoredListRoundTrip() throws {
        let data = try JSONEncoder().encode(ExcludedHostList(hosts: []))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"hosts":[]}"#)
        let restored = try JSONDecoder().decode(ExcludedHostList.self, from: data)
        XCTAssertTrue(restored.excludes("reqresapp.com"))
        XCTAssertTrue(restored.excludes("api.reqresapp.com"))

        let older = Data(#"{"hosts":["timestamp.apple.com","reqresapp.com","api.reqresapp.com","*.REQRESAPP.com","example.net"]}"#.utf8)
        let decoded = try JSONDecoder().decode(ExcludedHostList.self, from: older)
        XCTAssertEqual(decoded.hosts, ["timestamp.apple.com", "example.net"])
        XCTAssertTrue(decoded.excludes("reqresapp.com"))
        XCTAssertEqual(ExcludedHostList(hosts: ["reqresapp.com", "a.test"]).hosts, ["a.test"])
    }

    func testTheLicenseServerIsNeverOfferedAsRecommended() {
        for list in [ExcludedHostList(), ExcludedHostList(hosts: []), ExcludedHostList(hosts: ["timestamp.apple.com"])] {
            for entry in list.missingRecommended {
                XCTAssertNil(ExcludedHostList.builtInEntry(covering: entry), entry)
            }
        }
        for entry in ExcludedHostList.builtIn {
            XCTAssertFalse(ExcludedHostList.recommended.contains(entry))
            XCTAssertNil(ExcludedHostList.recommendedReason(for: entry), "the built-in row has its own reason")
        }
    }
}
