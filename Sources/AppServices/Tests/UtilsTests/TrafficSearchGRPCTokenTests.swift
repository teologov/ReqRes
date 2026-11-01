//
//  TrafficSearchGRPCTokenTests.swift
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

import MCPKit
import XCTest
@testable import Utils

/// The `grpc:` search token (protocol-engine doc §S8).
final class TrafficSearchGRPCTokenTests: XCTestCase {
    private func matches(_ filter: TrafficSearchFilter, grpc: Int?) -> Bool {
        filter.matches(host: "a.com", url: "https://a.com/a.B/C", method: "POST", status: "200", app: nil, pid: nil, country: nil, outcome: nil,
                       grpcStatus: grpc, proto: nil)
    }

    func testParsing() {
        XCTAssertEqual(TrafficSearchTokenKind.parse("grpc:error")?.kind, .grpc)
        XCTAssertEqual(TrafficSearchToken.parse(kind: .grpc, query: "error"), .grpc("error"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .grpc, query: "ok"), .grpc("OK"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .grpc, query: "not_found"), .grpc("NOT_FOUND"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .grpc, query: "NotFound"), .grpc("NOT_FOUND"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .grpc, query: "5"), .grpc("NOT_FOUND"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .grpc, query: "canceled"), .grpc("CANCELLED"))
        XCTAssertEqual(TrafficSearchToken.parse(kind: .grpc, query: "42"), .grpc("42"))
        XCTAssertNil(TrafficSearchToken.parse(kind: .grpc, query: "banana"), "free text, the status:banana contract")
        XCTAssertNil(TrafficSearchToken.parse(kind: .grpc, query: "-1"))
        XCTAssertEqual(TrafficSearchToken.grpc("NOT_FOUND").displayName, "gRPC NOT_FOUND")
        XCTAssertEqual(TrafficSearchToken.grpc("error").displayName, "gRPC error")
        XCTAssertEqual(TrafficSearchToken.grpc("error").id, "grpc-error")
    }

    func testMatching() {
        let errors = TrafficSearchFilter(grpcStatuses: ["error"])
        XCTAssertTrue(matches(errors, grpc: 5))
        XCTAssertTrue(matches(errors, grpc: 14))
        XCTAssertFalse(matches(errors, grpc: 0))
        XCTAssertFalse(matches(errors, grpc: nil), "a row that is not an RPC is not an RPC error")
        XCTAssertTrue(matches(TrafficSearchFilter(grpcStatuses: ["OK"]), grpc: 0))
        XCTAssertTrue(matches(TrafficSearchFilter(grpcStatuses: ["NOT_FOUND", "UNAVAILABLE"]), grpc: 14), "OR-ed among themselves")
        XCTAssertFalse(matches(TrafficSearchFilter(grpcStatuses: ["NOT_FOUND"]), grpc: 14))
        XCTAssertTrue(matches(TrafficSearchFilter(grpcStatuses: ["42"]), grpc: 42))
        XCTAssertTrue(TrafficSearchToken.grpc("error").matches(host: "a", url: "https://a/", method: "POST", status: "200", grpcStatus: 3))
        XCTAssertFalse(TrafficSearchToken.grpc("error").matches(host: "a", url: "https://a/", method: "POST", status: "200"))
    }

    func testTheFilterKeepsTheChipOnce() {
        var filter = TrafficSearchFilter()
        filter.addToken(.grpc("not_found"))
        filter.addToken(.grpc("5"))
        XCTAssertEqual(filter.grpcStatuses, ["NOT_FOUND"])
        XCTAssertEqual(filter.tokens, [.grpc("NOT_FOUND")])
        XCTAssertTrue(filter.hasTokens)
        filter.removeToken(.grpc("not_found"))
        XCTAssertTrue(filter.grpcStatuses.isEmpty)
        filter.addToken(.grpc("banana"))
        XCTAssertTrue(filter.grpcStatuses.isEmpty, "a token that can never match is refused")
    }

    func testSuggestions() {
        let suggestions = TrafficSearchTokenKind.grpc.staticSuggestions
        XCTAssertEqual(Array(suggestions.prefix(3)), ["error", "OK", "NOT_FOUND"])
        XCTAssertEqual(Set(suggestions), Set(["error"] + TrafficSearchGRPCMatch.names), "every name, once")
        XCTAssertEqual(suggestions.count, 18)
        for suggestion in suggestions {
            XCTAssertNotNil(TrafficSearchToken.parse(kind: .grpc, query: suggestion), suggestion)
        }
    }

    /// Utils cannot import MCPKit; the two vocabularies must stay one.
    func testTheVocabularyIsMCPKits() {
        XCTAssertEqual(TrafficSearchGRPCMatch.names, RPCStatusCode.names)
        for raw in ["error", "ok", "OK", "not_found", "NotFound", "canceled", "5", "16", "42", "banana", "", "-1", "UNAUTHENTICATED", "notok", "not-ok", "NotOk", "not_ok", "Not-Found", "permission-denied"] {
            let utils = TrafficSearchGRPCMatch.normalize(raw)
            let mcp = RPCStatusMatch.parse(raw)
            XCTAssertEqual(utils, mcp?.token, raw)
            for code in [nil, 0, 5, 14, 42] {
                XCTAssertEqual(utils.map { TrafficSearchGRPCMatch.matches($0, grpcStatus: code) }, mcp.map { $0.matches(code) }, "\(raw) vs \(String(describing: code))")
            }
        }
    }
}
