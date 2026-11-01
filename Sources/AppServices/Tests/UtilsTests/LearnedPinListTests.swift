//
//  LearnedPinListTests.swift
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

import XCTest
@testable import Utils

final class LearnedPinListTests: XCTestCase {
    private let whatsapp = "/Applications/WhatsApp.app/Contents/MacOS/WhatsApp"

    func testAddingKeepsOneRecordPerAppAndDomainNewestFirst() throws {
        let first = LearnedPinRecord(app: whatsapp, appName: "WhatsApp", domain: "whatsapp.net", learnedAt: Date(timeIntervalSince1970: 100))
        let later = LearnedPinRecord(app: "/x/Banking", appName: "Banking", domain: "bank.example", learnedAt: Date(timeIntervalSince1970: 200))
        var list = try XCTUnwrap(LearnedPinList().adding(first))
        list = try XCTUnwrap(list.adding(later))
        XCTAssertEqual(list.records.map(\.appName), ["Banking", "WhatsApp"], "newest first")
        XCTAssertNil(list.adding(LearnedPinRecord(app: whatsapp, appName: "WhatsApp", domain: "whatsapp.net")), "already there")
        XCTAssertNotNil(list.adding(LearnedPinRecord(app: "/x/Other", appName: "Other", domain: "whatsapp.net")), "another app is another record")
        XCTAssertEqual(list.removing(id: first.id).records, [later])
    }

    /// The extension's `pin_learned` payload, and the store's round trip.
    func testTheBusPayloadAndTheStoredList() throws {
        let record = try XCTUnwrap(LearnedPinRecord(busPayload: ["app": whatsapp, "appName": "WhatsApp", "domain": "whatsapp.net"]))
        XCTAssertEqual(record.domain, "whatsapp.net")
        XCTAssertNil(LearnedPinRecord(busPayload: ["app": whatsapp]), "no domain, no pin")
        XCTAssertNil(LearnedPinRecord(busPayload: "nonsense"))
        let list = try XCTUnwrap(LearnedPinList().adding(record))
        XCTAssertEqual(try JSONDecoder().decode(LearnedPinList.self, from: JSONEncoder().encode(list)), list)
    }

    /// What the app pushes: the core decodes app, appName and domain and
    /// ignores learnedAt.
    func testThePushedRecordCarriesTheCoresKeys() throws {
        let data = try JSONEncoder().encode([LearnedPinRecord(app: whatsapp, appName: "WhatsApp", domain: "whatsapp.net")])
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(array.first?["app"] as? String, whatsapp)
        XCTAssertEqual(array.first?["appName"] as? String, "WhatsApp")
        XCTAssertEqual(array.first?["domain"] as? String, "whatsapp.net")
    }
}
