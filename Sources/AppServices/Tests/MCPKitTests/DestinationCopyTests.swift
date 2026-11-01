//
//  DestinationCopyTests.swift
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
//  Destination-map UX spec §6: every honesty string, pinned verbatim. These
//  are the claims the map makes about itself; a change here is a product
//  decision, and this file is where it becomes visible.
//

import XCTest
@testable import MCPKit

final class DestinationCopyTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func testTheThreeClassExplanations() {
        XCTAssertEqual(
            DestinationCopy.thisMac,
            "Requests to this Mac itself — 127.0.0.1 or ::1: a local dev server, a simulator, another proxy."
        )
        XCTAssertEqual(
            DestinationCopy.localNetwork,
            "Requests to a private address on your network — 10.x, 172.16–31.x, 192.168.x, link-local or another private range: a router, a NAS, a phone, a colleague's machine."
        )
        XCTAssertEqual(
            DestinationCopy.unknown,
            "ReqRes could not place these requests. It knows the address only when the extension reports it, it places an address only if the offline country table lists it, and a request a rule answered contacted no server at all. No address is ever looked up online; only the map tiles come from Apple."
        )
    }

    /// The map is Apple Maps since the MapKit rewrite: the lookup stays
    /// offline, the tiles do not, and every surface says exactly that.
    func testTheMapPrivacySentencesAdmitAppleMaps() {
        XCTAssertEqual(
            DestinationCopy.mapPrivacy,
            "The country lookup runs on this Mac from an offline table; the map itself is Apple Maps, so Apple receives the map area you view — which ReqRes frames around your destinations — never the addresses themselves."
        )
        // An excluded host is relayed and NOT recorded by the core, so the
        // sentence must not put the tile fetches in the traffic list; and the
        // pinning explanation is unmeasured, so it must not be stated.
        XCTAssertEqual(
            DestinationCopy.mapTilesInTraffic,
            "While capture is on, the map's tile requests (made by geod, Apple's map service) pass through ReqRes untouched and are not listed — *.ls.apple.com is excluded from interception by default so the map keeps working while capture is on."
        )
        XCTAssertFalse(DestinationCopy.mapTilesInTraffic.contains("appear in the traffic list"))
        XCTAssertFalse(DestinationCopy.mapTilesInTraffic.lowercased().contains("pins"))
        XCTAssertEqual(DestinationCopy.mapTilesOffline, "Map tiles need a network connection; destinations are still listed.")
        // The strings that still deny a network lookup must not deny the map.
        for claim in [DestinationCopy.unknown, DestinationCopy.origin(countryName: "X", timeZone: "Y"), DestinationCopy.whatACountryMeans] {
            XCTAssertFalse(claim.contains("Nothing is looked up online"), "\(claim) overclaims — the map tiles are online")
            XCTAssertFalse(claim.lowercased().contains("leaves the mac"))
        }
    }

    func testTheUnknownExplanationNamesATableFailureWhenThereIsOne() {
        XCTAssertEqual(DestinationCopy.unknown(tableFailure: nil), DestinationCopy.unknown)
        XCTAssertEqual(DestinationCopy.unknown(tableFailure: "  "), DestinationCopy.unknown)
        XCTAssertEqual(
            DestinationCopy.unknown(tableFailure: "dbip-country.bin is missing"),
            DestinationCopy.unknown + " The country table could not be read: dbip-country.bin is missing."
        )
    }

    func testClassDescriptionsComeFromTheSameStrings() {
        XCTAssertNil(DestinationCopy.classDescription(.country("US")))
        XCTAssertEqual(DestinationCopy.classDescription(.thisMac), DestinationCopy.thisMac)
        XCTAssertEqual(DestinationCopy.classDescription(.localNetwork), DestinationCopy.localNetwork)
        XCTAssertEqual(DestinationCopy.classDescription(.unknown, tableFailure: "corrupt"), DestinationCopy.unknown(tableFailure: "corrupt"))
    }

    func testTheOriginSentenceNamesTheCountryAndTheTimeZoneAndDeniesLocationServices() {
        XCTAssertEqual(
            DestinationCopy.origin(countryName: "Netherlands", timeZone: "Europe/Amsterdam"),
            "You, approximately: the centre of Netherlands, because your Mac's time zone is Europe/Amsterdam. ReqRes never asks Location Services and never looks this up online."
        )
    }

    func testWhatACountryMeansIsTheCDNSentence() {
        XCTAssertEqual(
            DestinationCopy.whatACountryMeans,
            "The country is where the address your Mac connected to is registered, at country level, from a table inside the app — a CDN answers from a nearby edge, so a site's country is where its server answered from, not where the company is."
        )
        XCTAssertEqual(DestinationCopy.agentAttribution, "IP Geolocation by DB-IP.")
    }

    // MARK: - Assembled lines

    func testBytesReadAsDecimalUnits() {
        XCTAssertEqual(DestinationCopy.bytes(0), "0 B")
        XCTAssertEqual(DestinationCopy.bytes(512), "512 B")
        XCTAssertEqual(DestinationCopy.bytes(40_000), "40 KB")
        XCTAssertEqual(DestinationCopy.bytes(1_100_000), "1.1 MB")
        XCTAssertEqual(DestinationCopy.bytes(38_200_000), "38.2 MB")
        XCTAssertEqual(DestinationCopy.bytes(2_000_000_000), "2.0 GB")
        XCTAssertEqual(DestinationCopy.bytes(-5), "0 B", "a negative total is a bookkeeping bug, not a size to print")
    }

    func testMetaLineShowsTwoAppsThenACount() {
        XCTAssertEqual(
            DestinationCopy.metaLine(bytes: 38_200_000, hostCount: 14, appNames: ["Brave Browser", "claude", "Safari"], locale: english),
            "38.2 MB · 14 hosts · Brave Browser, claude +1"
        )
        XCTAssertEqual(
            DestinationCopy.metaLine(bytes: 1_100_000, hostCount: 1, appNames: ["claude"], locale: english),
            "1.1 MB · 1 host · claude"
        )
        XCTAssertEqual(
            DestinationCopy.metaLine(bytes: 40_000, hostCount: 2, appNames: ["node", nil], locale: english),
            "40 KB · 2 hosts · node, Unknown",
            "the nil bucket prints Unknown"
        )
        XCTAssertEqual(
            DestinationCopy.metaLine(bytes: 40_000, hostCount: 2, appNames: [], locale: english),
            "40 KB · 2 hosts",
            "attribution unavailable omits the app part (spec §7 state 7)"
        )
    }

    func testHeaderMetaForEachSelectionShape() {
        XCTAssertEqual(
            DestinationCopy.headerMeta(selection: nil, destinationCount: 12, requests: 3_812, bytes: 41_300_000, hostCount: 30, appCount: 4, locale: english),
            "12 destinations · 3,812 requests · 41.3 MB"
        )
        XCTAssertEqual(
            DestinationCopy.headerMeta(selection: .country("US"), destinationCount: 12, requests: 1_204, bytes: 38_200_000, hostCount: 14, appCount: 3, locale: english),
            "1,204 requests · 38.2 MB · 14 hosts · 3 apps"
        )
        XCTAssertEqual(
            DestinationCopy.headerMeta(selection: .thisMac, destinationCount: 12, requests: 1, bytes: 900, hostCount: 1, appCount: 1, locale: english),
            "1 request · 900 B · 1 host · 1 app"
        )
        XCTAssertEqual(
            DestinationCopy.headerMeta(selection: .unknown, destinationCount: 12, requests: 12, bytes: 40_000, hostCount: 1, appCount: 1, locale: english),
            "12 requests · 40 KB · 1 host · not placeable"
        )
        XCTAssertEqual(
            DestinationCopy.headerMeta(selection: .country("DE"), destinationCount: 12, requests: 88, bytes: 1_100_000, hostCount: 2, appCount: nil, locale: english),
            "88 requests · 1.1 MB · 2 hosts",
            "attribution unavailable omits the apps part"
        )
        // Spec §7 state 3: everything Unknown, nothing selected — the one
        // "destination" is the class, and the header says so.
        XCTAssertEqual(
            DestinationCopy.headerMeta(selection: nil, destinationCount: 1, requests: 12, bytes: 40_000, hostCount: 0, appCount: nil, allUnknown: true, locale: english),
            "1 destination · 12 requests · 40 KB · not placeable"
        )
        XCTAssertEqual(
            DestinationCopy.headerMeta(selection: nil, destinationCount: 0, requests: 0, bytes: 0, hostCount: 0, appCount: nil, allUnknown: true, locale: english),
            "0 destinations · 0 requests · 0 B",
            "nothing captured is state 2, not state 3"
        )
    }

    func testFooterSummaryNamesAllCapturedTrafficAndTheCap() {
        XCTAssertEqual(
            DestinationCopy.footerSummary(destinationCount: 12, requests: 3_812, shown: nil, retentionCap: nil, locale: english),
            "All captured traffic · 12 destinations · 3,812 requests"
        )
        XCTAssertEqual(
            DestinationCopy.footerSummary(destinationCount: 1, requests: 1, shown: nil, retentionCap: nil, locale: english),
            "All captured traffic · 1 destination · 1 request"
        )
        XCTAssertEqual(
            DestinationCopy.footerSummary(destinationCount: 12, requests: 5_000, shown: nil, retentionCap: 5_000, locale: english),
            "All captured traffic · 12 destinations · the 5,000 most recent requests"
        )
        XCTAssertEqual(
            DestinationCopy.footerSummary(destinationCount: 12, requests: 3_812, shown: 3, retentionCap: nil, locale: english),
            "3 of 12 destinations shown"
        )
        XCTAssertEqual(
            DestinationCopy.footerSummary(destinationCount: 0, requests: 0, shown: nil, retentionCap: nil, locale: english),
            "All captured traffic · 0 destinations · 0 requests"
        )
    }

    /// Spec §4.3: the strip names the time zone, so `UTC`, `Etc/GMT+2` and a
    /// zone the table lacks do not all read the same.
    func testTheOriginUnknownSentenceNamesTheTimeZone() {
        XCTAssertEqual(
            DestinationCopy.originUnknown(timeZone: "Etc/GMT+2"),
            "Your location is not shown: the time zone Etc/GMT+2 names no country."
        )
    }
}
