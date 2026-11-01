//
//  RPCCandidateTests.swift
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
@testable import MCPKit

/// The per-row RPC pre-check and its cache (release review, 2026-09-29):
/// an ordinary row is examined once, not on every call, and one pass over
/// 5,000 rows of 1 KB headers stays cheap.
final class RPCCandidateTests: XCTestCase {
    private func heads(_ extra: String = "") -> String {
        let filler = String(repeating: "x", count: 900)
        return #"[{"Host":"api.example.com"},{"Accept":"*/*"},{"User-Agent":"Mozilla/5.0 \#(filler)"}\#(extra)]"#
    }

    func testEveryRPCMarkerIsFoundInAnyCase() {
        for marker in [#",{"Content-Type":"application/grpc-web+proto"}"#,
                       #",{"content-type":"Application/Connect+json"}"#,
                       #",{"Connect-Protocol-Version":"1"}"#,
                       #",{"content-type":"APPLICATION/PROTO"}"#] {
            XCTAssertTrue(RPCCandidate.mightBeRPC(requestType: "", responseType: "", requestHeads: heads(marker)), marker)
        }
        XCTAssertTrue(RPCCandidate.mightBeRPC(requestType: "", responseType: "application/grpc", requestHeads: ""))
        XCTAssertTrue(RPCCandidate.mightBeRPC(requestType: "application/connect+proto", responseType: "", requestHeads: ""))
    }

    func testAnOrdinaryRowIsNotACandidate() {
        XCTAssertFalse(RPCCandidate.mightBeRPC(requestType: "application/json", responseType: "text/html", requestHeads: heads()))
        XCTAssertFalse(RPCCandidate.mightBeRPC(requestType: "", responseType: "", requestHeads: "applicatio"))
        XCTAssertFalse(RPCCandidate.mightBeRPC(requestType: "", responseType: "", requestHeads: #"{"x":"application/grp"}"#))
        XCTAssertFalse(RPCCandidate.mightBeRPC(requestType: "", responseType: "", requestHeads: "é application/gr\u{00FC}pc"))
    }

    /// A second pass over the same rows at the same revisions computes
    /// nothing — the "not an RPC" answer included. Before the fix, the
    /// pre-check ran ahead of the cache and a "no" was never stored.
    func testASecondPassComputesNothingAndNoIsCached() {
        let cache = RevisionedCache<Int>()
        let ids = (0..<5_000).map { _ in UUID() }
        var computed = 0
        for (index, id) in ids.enumerated() {
            _ = cache.value(id: id, revision: 1) { computed += 1; return index % 50 == 0 ? index : nil }
        }
        XCTAssertEqual(computed, 5_000)
        for (index, id) in ids.enumerated() {
            let value = cache.value(id: id, revision: 1) { computed += 1; return -1 }
            XCTAssertEqual(value, index % 50 == 0 ? index : nil)
        }
        XCTAssertEqual(computed, 5_000, "the second pass recomputed")
        // A new revision is read again.
        _ = cache.value(id: ids[1], revision: 2) { computed += 1; return nil }
        XCTAssertEqual(computed, 5_001)
    }

    /// One full cold pass over 5,000 ordinary rows with ~1 KB of headers.
    /// The old four Foundation searches took 0.6–2 s in an optimised build;
    /// this bound is for a DEBUG test build.
    func testOneColdPassOverFiveThousandRowsIsCheap() {
        let rows = (0..<5_000).map { _ in heads() }
        let start = Date()
        var hits = 0
        for row in rows where RPCCandidate.mightBeRPC(requestType: "application/json", responseType: "text/html", requestHeads: row) {
            hits += 1
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(hits, 0)
        XCTAssertLessThan(elapsed, 0.5, "\(elapsed) s")
    }
}
