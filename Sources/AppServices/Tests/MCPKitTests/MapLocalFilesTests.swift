//
//  MapLocalFilesTests.swift
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
//  F24 (2026-10-26): the bookmark store and the answer an unreadable Map Local
//  file gets. The bookmark bytes themselves come from macOS and are not made
//  here; what is pinned is the store's shape and the words.
//

import XCTest
@testable import MCPKit

final class MapLocalFilesTests: XCTestCase {
    func testTheStoreIsKeyedByTheRulesPathAndAFileChosenAgainReplacesItsBookmark() {
        let first = Data([1, 2, 3]), second = Data([4, 5])
        var store: [String: Data] = [:]
        store = MapLocalBookmarks.storing(first, for: "/Users/me/mocks/a.json", in: store)
        store = MapLocalBookmarks.storing(second, for: "/Users/me/mocks/b.json", in: store)

        XCTAssertEqual(MapLocalBookmarks.bookmark(for: "/Users/me/mocks/a.json", in: store), first)
        XCTAssertEqual(MapLocalBookmarks.bookmark(for: "/Users/me/mocks/b.json", in: store), second)
        XCTAssertNil(MapLocalBookmarks.bookmark(for: "/Users/me/mocks/c.json", in: store))

        store = MapLocalBookmarks.storing(second, for: "/Users/me/mocks/a.json", in: store)
        XCTAssertEqual(MapLocalBookmarks.bookmark(for: "/Users/me/mocks/a.json", in: store), second)
        XCTAssertEqual(store.count, 2)
    }

    func testPruningKeepsOnlyTheFilesRulesStillName() {
        let store = [
            "/a.json": Data([1]),
            "/b.json": Data([2]),
            "/gone.json": Data([3]),
        ]
        // A disabled rule's path is still a rule's path: the caller passes every
        // stored Map Local rule, not the pushed ones.
        let kept = MapLocalBookmarks.pruned(store, keeping: ["/a.json", "/b.json", "/never-stored.json"])
        XCTAssertEqual(Set(kept.keys), ["/a.json", "/b.json"])
        XCTAssertEqual(kept["/a.json"], Data([1]))

        XCTAssertEqual(MapLocalBookmarks.pruned(store, keeping: [String]()), [:], "no Map Local rule left: no bookmark kept")
        XCTAssertEqual(MapLocalBookmarks.pruned([:], keeping: ["/a.json"]), [:])
    }

    func testTheDefaultsKeyIsStable() {
        // The bookmarks survive an update only while the key does.
        XCTAssertEqual(MapLocalBookmarks.defaultsKey, "MapLocalFileBookmarks")
    }

    func testTheUnreadableAnswerIsReqRessOwnFailureNotTheServers() {
        XCTAssertEqual(MapLocalUnreadable.status, 500, "ReqRes could not serve the configured file; 502 is the core's word for a server it could not reach")
        XCTAssertTrue(MapLocalUnreadable.contentType.hasPrefix("text/plain"), MapLocalUnreadable.contentType)

        let body = MapLocalUnreadable.body(path: "/Users/me/mocks/flags on.json")
        XCTAssertTrue(body.contains("/Users/me/mocks/flags on.json"), "the body names the file")
        XCTAssertTrue(body.contains("choose the file again"), "and the fix")
        XCTAssertTrue(body.contains("was not sent to the server"), "and that no request reached the server")
        XCTAssertFalse(body.contains("502"))
    }

    func testTheAppsWordsNameTheFileAndTheFix() {
        XCTAssertEqual(MapLocalUnreadable.listRowLabel, "File can't be read")

        let help = MapLocalUnreadable.listRowHelp(fileName: "flags.json")
        XCTAssertTrue(help.contains("flags.json"))
        XCTAssertTrue(help.contains("choose the file again"))
        XCTAssertTrue(help.contains("\(MapLocalUnreadable.status)"), "the tooltip says what a matching request gets")

        let form = MapLocalUnreadable.formMessage(fileName: "flags.json")
        XCTAssertTrue(form.contains("flags.json"))
        XCTAssertTrue(form.contains("Choose it again"))
        XCTAssertFalse(form.contains("Status"), "the form's file rows must not mention a status (RuleResponseDefaultsTests)")
    }
}
