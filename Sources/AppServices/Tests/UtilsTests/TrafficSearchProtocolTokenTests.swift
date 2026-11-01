//
//  TrafficSearchProtocolTokenTests.swift
//  AppServices
//
//  Created by OloApps on 9/29/26.
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
import MCPKit
@testable import Utils

/// The `proto:` search token (protocol-engine doc §S9) and the HTTP/2
/// capture setting's start option.
final class TrafficSearchProtocolTokenTests: XCTestCase {
    private func matches(_ filter: TrafficSearchFilter, proto: String?) -> Bool {
        filter.matches(host: "a.com", url: "https://a.com/", method: "GET", status: "200", app: nil, pid: nil, country: nil, outcome: nil,
                       grpcStatus: nil, proto: proto)
    }

    func testTypedPrefixesBecomeChipsAndUnusableOnesStayFreeText() {
        let parsed = TrafficSearchTokenKind.parse("proto:h2")
        XCTAssertEqual(parsed?.kind, .proto)
        XCTAssertEqual(parsed.flatMap { TrafficSearchToken.parse(kind: $0.kind, query: $0.query) }, .proto("h2"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .proto, query: "HTTP/2"), .proto("h2"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .proto, query: "websocket"), .proto("ws"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .proto, query: "http/1.1"), .proto("h1"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .proto, query: "tcp"), .proto("relay"))
        XCTAssertNil(TrafficSearchToken.parse(kind: .proto, query: "h3"), "an unknown protocol stays free text")
        XCTAssertNil(TrafficSearchToken.parse(kind: .proto, query: ""))
    }

    func testChipsNameTheProtocolInWords() {
        XCTAssertEqual(TrafficSearchToken.proto("h2").displayName, "HTTP/2")
        XCTAssertEqual(TrafficSearchToken.proto("h1").displayName, "HTTP/1.x")
        XCTAssertEqual(TrafficSearchToken.proto("ws").displayName, "WebSocket")
        XCTAssertEqual(TrafficSearchToken.proto("relay").displayName, "Relay")
        XCTAssertEqual(TrafficSearchToken.proto("h2").id, "proto-h2")
        XCTAssertEqual(TrafficSearchToken.proto("h2").kind, .proto)
    }

    func testMatchingIsOrWithinTheKindAndNilNeverMatches() {
        var filter = TrafficSearchFilter()
        filter.addToken(.proto("h2"))
        XCTAssertTrue(matches(filter, proto: "h2"))
        XCTAssertFalse(matches(filter, proto: "h1"))
        XCTAssertFalse(matches(filter, proto: nil), "a row with no recorded protocol matches no chip")
        filter.addToken(.proto("ws"))
        XCTAssertTrue(matches(filter, proto: "ws"))
        XCTAssertTrue(matches(filter, proto: "h2"))
        XCTAssertFalse(matches(filter, proto: "relay"))
        // One chip per protocol, whatever spelling committed it.
        filter.addToken(.proto("HTTP/2"))
        XCTAssertEqual(filter.protocols, ["h2", "ws"])
        filter.removeToken(.proto("http2"))
        XCTAssertEqual(filter.protocols, ["ws"])
        XCTAssertEqual(filter.tokens, [.proto("ws")])
        XCTAssertTrue(filter.hasTokens)
        filter.clear()
        XCTAssertTrue(filter.isEmpty)
    }

    func testSuggestionsAreTheFourTokensAndAllParse() {
        XCTAssertEqual(TrafficSearchTokenKind.proto.staticSuggestions, ["h2", "h1", "ws", "relay"])
        for suggestion in TrafficSearchTokenKind.proto.staticSuggestions {
            XCTAssertNotNil(TrafficSearchToken.parse(kind: .proto, query: suggestion), suggestion)
        }
    }

    /// Utils spells the vocabulary a second time (it cannot import MCPKit);
    /// this pins it to `SessionProtocol.parse`, spelling for spelling.
    func testTheVocabularyIsMCPKits() {
        let spellings = ["h1", "H1", "http1", "HTTP/1.1", "http/1.0", "1", "1.1", "1.0", "http1.1", "h2", "http2", "HTTP/2", "http/2.0",
                         "2", "2.0", "ws", "wss", "WebSocket", "websockets", "relay", "tcp", "relayed", "h3", "quic", "", "banana", " h2 "]
        for raw in spellings {
            XCTAssertEqual(TrafficSearchProtocolMatch.normalize(raw), SessionProtocol.parse(raw)?.token, raw)
        }
        XCTAssertEqual(Set(TrafficSearchProtocolMatch.all), Set(SessionProtocol.allCases.map(\.token)))
        for proto in SessionProtocol.allCases {
            XCTAssertEqual(TrafficSearchProtocolMatch.displayName(forToken: proto.token), SessionProtocolPresentation.chipName(proto))
        }
    }

    // MARK: - The setting and its start option

    func testTheSettingIsOffUntilChosenAndLivesInTheGivenDefaults() throws {
        let suite = "HTTP2CaptureSettingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(HTTP2CaptureSetting.isEnabled(in: defaults), "never chosen reads as OFF (a beta)")
        HTTP2CaptureSetting.setEnabled(true, in: defaults)
        XCTAssertTrue(HTTP2CaptureSetting.isEnabled(in: defaults))
        HTTP2CaptureSetting.setEnabled(false, in: defaults)
        XCTAssertFalse(HTTP2CaptureSetting.isEnabled(in: defaults))
    }

    func testTheStartOptionsCarryTheCoresKeyEitherWay() {
        // The core's `HTTP2Capture.startOptionKey` (core C12.2(a)); the app
        // checks the two are equal at launch in DEBUG.
        XCTAssertEqual(HTTP2CaptureSetting.startOptionKey, "reqres.http2.enabled")
        for enabled in [true, false] {
            let options = HTTP2CaptureSetting.startOptions(enabled: enabled)
            XCTAssertEqual(options.count, 1)
            XCTAssertEqual((options[HTTP2CaptureSetting.startOptionKey] as? NSNumber)?.boolValue, enabled, "present when off too")
        }
    }

    func testMergingKeepsEveryOtherStartOptionAndReplacesAStaleValue() {
        let base: [String: NSObject] = [
            "crashReportingEnabled": NSNumber(value: false),
            "reqres.ca.material": "PEM" as NSString,
            HTTP2CaptureSetting.startOptionKey: NSNumber(value: false),
        ]
        let merged = HTTP2CaptureSetting.merging(into: base, enabled: true)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual((merged[HTTP2CaptureSetting.startOptionKey] as? NSNumber)?.boolValue, true)
        XCTAssertEqual(merged["reqres.ca.material"] as? NSString, "PEM")
        XCTAssertEqual((merged["crashReportingEnabled"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual((HTTP2CaptureSetting.merging(into: [:], enabled: false)[HTTP2CaptureSetting.startOptionKey] as? NSNumber)?.boolValue, false)
    }
}
