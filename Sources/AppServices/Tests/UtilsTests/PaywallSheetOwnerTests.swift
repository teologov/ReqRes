//
//  PaywallSheetOwnerTests.swift
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
//  Exactly one main window shows the ReqRes Pro sheet (PaywallSheetOwner;
//  the paywall review's F26): two windows and the launch flag give one
//  sheet, whichever window's view sees the flag first; a window opened while
//  the sheet is up shows none; a person opening it from another window adds
//  no second sheet and brings the one up forward; only the owner answers for
//  its dismissal; and a closed owner hands the sheet to the next claim.
//  Windows here are names: the type takes any identity.
//

import XCTest
@testable import Utils

final class PaywallSheetOwnerTests: XCTestCase {
    private typealias Owner = PaywallSheetOwner<String>

    // MARK: - LicenseManager raises the sheet (launch)

    /// Both windows' views see the flag, in either order: only the key
    /// window presents.
    func testTwoWindowsAndTheLaunchFlagShowOneSheetInTheKeyWindow() {
        for order in [["A", "B"], ["B", "A"]] {
            var owner = Owner()
            let presenting = order.filter { owner.claim($0, key: "B", frontToBack: ["A", "B"]) }
            XCTAssertEqual(presenting, ["B"], "\(order)")
            XCTAssertEqual(owner.owner, "B")
        }
    }

    /// No key main window (the Settings window is key, or the app is not
    /// active): the frontmost main window presents.
    func testWithoutAKeyMainWindowTheFrontmostPresents() {
        for order in [["A", "B"], ["B", "A"]] {
            var owner = Owner()
            let presenting = order.filter { owner.claim($0, key: nil, frontToBack: ["B", "A"]) }
            XCTAssertEqual(presenting, ["B"], "\(order)")
        }
    }

    /// No window known yet (the views appear before AppKit puts them in
    /// windows): the first view to see the flag presents, and only it.
    func testWithNoWindowKnownTheFirstToAskPresents() {
        for order in [["A", "B"], ["B", "A"]] {
            var owner = Owner()
            let presenting = order.filter { owner.claim($0, key: nil, frontToBack: []) }
            XCTAssertEqual(presenting, [order[0]], "\(order)")
        }
    }

    /// The preferred window: key, else frontmost, else the one asking.
    func testThePreferredWindow() {
        XCTAssertEqual(Owner.preferred(key: "K", frontToBack: ["F", "K"], candidate: "C"), "K")
        XCTAssertEqual(Owner.preferred(key: nil, frontToBack: ["F", "K"], candidate: "C"), "F")
        XCTAssertEqual(Owner.preferred(key: nil, frontToBack: [], candidate: "C"), "C")
    }

    /// A window opened with File ▸ New Window while the sheet is up shows
    /// none: its view sees the flag already up and asks, and is refused.
    func testAWindowOpenedWhileTheSheetIsUpShowsNone() {
        var owner = Owner()
        XCTAssertTrue(owner.claim("A", key: "A", frontToBack: ["A"]))
        XCTAssertFalse(owner.claim("C", key: "C", frontToBack: ["C", "A"]))
        XCTAssertTrue(owner.claim("A", key: "C", frontToBack: ["C", "A"]), "the owner keeps presenting")
        XCTAssertEqual(owner.owner, "A")
    }

    // MARK: - A person opens the sheet

    /// The window the person clicked in shows the sheet, whichever window is
    /// key or frontmost when the flag's views ask.
    func testThePersonsWindowShowsTheSheet() {
        var owner = Owner()
        XCTAssertNil(owner.open(from: "B"), "nothing to bring forward")
        XCTAssertEqual(owner.owner, "B")
        for order in [["A", "B"], ["B", "A"]] {
            var copy = owner
            let presenting = order.filter { copy.claim($0, key: "A", frontToBack: ["A", "B"]) }
            XCTAssertEqual(presenting, ["B"], "\(order)")
        }
    }

    /// The sheet is up in A and the person opens it from B (its gauge, its
    /// badge): no second sheet; A is the window to bring forward.
    func testOpeningFromAnotherWindowBringsTheSheetForward() {
        var owner = Owner()
        XCTAssertTrue(owner.claim("A", key: "A", frontToBack: ["A", "B"]))
        XCTAssertEqual(owner.open(from: "B"), "A")
        XCTAssertEqual(owner.owner, "A")
        XCTAssertFalse(owner.claim("B", key: "B", frontToBack: ["B", "A"]))
        XCTAssertNil(owner.open(from: "A"), "the sheet's own window is already in front")
        XCTAssertEqual(owner.open(from: nil), "A")
    }

    /// The opener's window is not known: nobody owns the sheet until the
    /// flag's views ask, and then the usual choice decides.
    func testAnUnknownOpenerLeavesTheChoiceToTheFlag() {
        var owner = Owner()
        XCTAssertNil(owner.open(from: nil))
        XCTAssertNil(owner.owner)
        XCTAssertFalse(owner.claim("A", key: "B", frontToBack: ["B", "A"]))
        XCTAssertTrue(owner.claim("B", key: "B", frontToBack: ["B", "A"]))
    }

    // MARK: - Closing

    /// The owner's window closes with the flag still up: the claim is given
    /// up, and the next window to ask takes the sheet.
    func testAClosedOwnerHandsTheSheetOn() {
        var owner = Owner()
        XCTAssertTrue(owner.claim("A", key: "A", frontToBack: ["A", "B"]))
        XCTAssertFalse(owner.release("B"), "B never owned it")
        XCTAssertEqual(owner.owner, "A")
        XCTAssertTrue(owner.release("A"))
        XCTAssertNil(owner.owner)
        XCTAssertFalse(owner.release("A"), "released once")
        XCTAssertTrue(owner.claim("B", key: nil, frontToBack: ["B"]))
        XCTAssertEqual(owner.owner, "B")
    }

    /// A fresh owner, as AppView's reset leaves it: the next sheet is chosen
    /// anew.
    func testAFreshOwnerChoosesAnew() {
        var owner = Owner()
        XCTAssertTrue(owner.claim("A", key: "A", frontToBack: ["A", "B"]))
        owner = Owner()
        XCTAssertNil(owner.owner)
        XCTAssertTrue(owner.claim("B", key: "B", frontToBack: ["B", "A"]))
        XCTAssertFalse(owner.claim("A", key: "B", frontToBack: ["B", "A"]))
    }
}
