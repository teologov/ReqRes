//
//  MCPSessionDiffTests.swift
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
@testable import MCPKit

final class MCPSessionDiffTests: XCTestCase {
    // MARK: - Fixtures

    /// `makeSession`'s own default URL bakes in the uid
    /// ("…/resource/<uid>"), which is exactly wrong for diff fixtures: two
    /// captures of the SAME endpoint necessarily have different uids, and a
    /// test that varies only a header or a body must not also, silently, be
    /// varying the URL.
    private func makeDetail(
        uid: String,
        host: String = "api.example.com",
        method: String = "GET",
        url: String? = nil,
        statusCode: Int? = 200,
        requestHeaders: [String: String] = [:],
        responseHeaders: [String: String] = [:],
        requestBody: String? = nil,
        responseBody: String? = nil
    ) -> MCPSessionDetail {
        MCPSessionDetail(
            summary: makeSession(
                uid: uid,
                host: host,
                method: method,
                url: url ?? "https://\(host)/v1/resource",
                statusCode: statusCode
            ),
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBodyPreview: requestBody,
            responseBodyPreview: responseBody
        )
    }

    /// `{"k0": "<value>0", "k1": "<value>1", …}` — used to blow past the cap
    /// with a controlled, exact count of differing keys.
    private func manyKeysBody(value: String, count: Int) -> String {
        let pairs = (0..<count).map { "\"k\($0)\": \"\(value)\($0)\"" }.joined(separator: ", ")
        return "{\(pairs)}"
    }

    // MARK: - No difference

    func testIdenticalSessionsProduceAnEmptyDiff() {
        let detail = makeDetail(
            uid: "s1",
            requestHeaders: ["Accept": "application/json"],
            responseHeaders: ["Content-Type": "application/json"],
            requestBody: "{}",
            responseBody: #"{"ok": true}"#
        )
        let diff = MCPSessionDiff.diff(detail, detail)
        XCTAssertTrue(diff.identical)
        XCTAssertNil(diff.statusCode)
        XCTAssertNil(diff.method)
        XCTAssertNil(diff.url)
        XCTAssertTrue(diff.requestHeaders.added.isEmpty && diff.requestHeaders.changed.isEmpty)
        XCTAssertEqual(diff.responseBody, .identical)
    }

    /// Design decision: comparing a session to itself is a well-defined
    /// question with a well-defined (empty) answer, not an error case a
    /// caller has to branch around.
    func testDiffOfASessionAgainstItselfIsAnEmptyDiffNotAnError() {
        let detail = makeDetail(uid: "same", responseBody: #"{"a": 1}"#)
        let diff = MCPSessionDiff.diff(detail, detail)
        XCTAssertTrue(diff.identical)
        XCTAssertEqual(diff.uidA, "same")
        XCTAssertEqual(diff.uidB, "same")
    }

    /// An empty string return would be indistinguishable, on a terminal, from
    /// the tool call having produced nothing at all.
    func testRenderOfNoDifferenceIsAnExplicitSentenceNotAnEmptyString() {
        let detail = makeDetail(uid: "s1")
        let diff = MCPSessionDiff.diff(detail, detail)
        let text = MCPSessionDiffFormat.render(diff)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("No differences"))
    }

    // MARK: - Status / method / URL

    func testStatusOnlyChangeIsReportedAndNothingElseIs() {
        let a = makeDetail(uid: "a", statusCode: 200)
        let b = makeDetail(uid: "b", statusCode: 404)
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertFalse(diff.identical)
        XCTAssertEqual(diff.statusCode, MCPFieldChange<Int?>(before: 200, after: 404))
        XCTAssertNil(diff.method)
        XCTAssertNil(diff.url)
    }

    func testQueryParamsAreComparedAsASetNotAsAString() {
        // Same parameters, different order: a naive string compare of the
        // raw query would flag this as changed.
        let a = makeDetail(uid: "a", url: "https://api.example.com/search?a=1&b=2")
        let b = makeDetail(uid: "b", url: "https://api.example.com/search?b=2&a=1")
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertNil(diff.url)
        XCTAssertTrue(diff.addedQueryParams.isEmpty)
        XCTAssertTrue(diff.removedQueryParams.isEmpty)
        XCTAssertTrue(diff.changedQueryParams.isEmpty)
    }

    func testQueryParamAddedRemovedAndChanged() {
        let a = makeDetail(uid: "a", url: "https://api.example.com/search?page=1&sort=asc")
        let b = makeDetail(uid: "b", url: "https://api.example.com/search?page=2&limit=10")
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(diff.changedQueryParams, [MCPQueryParamChange(name: "page", before: "1", after: "2")])
        XCTAssertEqual(diff.removedQueryParams, [MCPNamedValue(name: "sort", value: "asc")])
        XCTAssertEqual(diff.addedQueryParams, [MCPNamedValue(name: "limit", value: "10")])
    }

    // MARK: - Headers

    func testHeaderAdded() {
        let a = makeDetail(uid: "a", responseHeaders: ["Content-Type": "application/json"])
        let b = makeDetail(uid: "b", responseHeaders: ["Content-Type": "application/json", "ETag": "\"v1\""])
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(diff.responseHeaders.added, [MCPNamedValue(name: "ETag", value: "\"v1\"")])
        XCTAssertTrue(diff.responseHeaders.removed.isEmpty)
        XCTAssertTrue(diff.responseHeaders.changed.isEmpty)
    }

    func testHeaderRemoved() {
        let a = makeDetail(uid: "a", responseHeaders: ["Content-Type": "application/json", "ETag": "\"v1\""])
        let b = makeDetail(uid: "b", responseHeaders: ["Content-Type": "application/json"])
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(diff.responseHeaders.removed, [MCPNamedValue(name: "ETag", value: "\"v1\"")])
        XCTAssertTrue(diff.responseHeaders.added.isEmpty)
    }

    func testHeaderChanged() {
        let a = makeDetail(uid: "a", responseHeaders: ["Cache-Control": "no-store"])
        let b = makeDetail(uid: "b", responseHeaders: ["Cache-Control": "max-age=60"])
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(diff.responseHeaders.changed, [MCPHeaderChange(name: "Cache-Control", before: "no-store", after: "max-age=60")])
    }

    /// "Content-Type" on one capture and "content-type" on the other must
    /// read as the same header, not as one removed and one added.
    func testHeaderNameCaseDifferencesAreNotFlaggedAsChanged() {
        let a = makeDetail(uid: "a", responseHeaders: ["Content-Type": "application/json"])
        let b = makeDetail(uid: "b", responseHeaders: ["content-type": "application/json"])
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertTrue(diff.responseHeaders.added.isEmpty)
        XCTAssertTrue(diff.responseHeaders.removed.isEmpty)
        XCTAssertTrue(diff.responseHeaders.changed.isEmpty)
        XCTAssertEqual(diff.responseHeaders.unchangedCount, 1)
        XCTAssertTrue(diff.identical)
    }

    /// The safety-critical case: two DIFFERENT real credentials must never be
    /// reported as "changed" (that would print them) or silently claimed
    /// "unchanged" (that would assert a fact about them that redaction makes
    /// unknowable). They must be counted, and the real values must never
    /// appear in either the model or the rendered text.
    func testSensitiveHeaderPresentOnBothSidesIsCountedNotComparedOrLeaked() {
        let a = makeDetail(uid: "a", requestHeaders: ["Authorization": "Bearer aaa-secret-111"])
        let b = makeDetail(uid: "b", requestHeaders: ["Authorization": "Bearer bbb-secret-222"])
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertTrue(diff.requestHeaders.changed.isEmpty)
        XCTAssertTrue(diff.requestHeaders.added.isEmpty)
        XCTAssertTrue(diff.requestHeaders.removed.isEmpty)
        XCTAssertEqual(diff.requestHeaders.redactedUnverifiedCount, 1)
        // identical stays true: nothing this type could verify differed.
        XCTAssertTrue(diff.identical)

        let text = MCPSessionDiffFormat.render(diff)
        XCTAssertFalse(text.contains("aaa-secret-111"))
        XCTAssertFalse(text.contains("bbb-secret-222"))
    }

    // MARK: - JSON bodies

    func testJSONBodyWithAChangedNestedValue() {
        let a = makeDetail(uid: "a", responseBody: #"{"user": {"id": 1, "name": "Alice"}}"#)
        let b = makeDetail(uid: "b", responseBody: #"{"user": {"id": 1, "name": "Bob"}}"#)
        let diff = MCPSessionDiff.diff(a, b)
        guard case .structural(let jsonDiff) = diff.responseBody else {
            return XCTFail("expected a structural JSON diff")
        }
        XCTAssertTrue(jsonDiff.addedPaths.isEmpty)
        XCTAssertTrue(jsonDiff.removedPaths.isEmpty)
        XCTAssertEqual(jsonDiff.changed, [MCPJSONPathChange(path: "user.name", before: "Alice", after: "Bob")])
    }

    func testJSONBodyWithAnAddedArrayElement() {
        let a = makeDetail(uid: "a", responseBody: #"{"items": ["a", "b"]}"#)
        let b = makeDetail(uid: "b", responseBody: #"{"items": ["a", "b", "c"]}"#)
        let diff = MCPSessionDiff.diff(a, b)
        guard case .structural(let jsonDiff) = diff.responseBody else {
            return XCTFail("expected a structural JSON diff")
        }
        XCTAssertEqual(jsonDiff.addedPaths, ["items[2]"])
        XCTAssertTrue(jsonDiff.removedPaths.isEmpty)
        XCTAssertTrue(jsonDiff.changed.isEmpty)
    }

    func testJSONBodyWithARemovedKey() {
        let a = makeDetail(uid: "a", responseBody: #"{"a": 1, "b": 2}"#)
        let b = makeDetail(uid: "b", responseBody: #"{"a": 1}"#)
        let diff = MCPSessionDiff.diff(a, b)
        guard case .structural(let jsonDiff) = diff.responseBody else {
            return XCTFail("expected a structural JSON diff")
        }
        XCTAssertEqual(jsonDiff.removedPaths, ["b"])
    }

    // MARK: - Non-JSON / coarse bodies

    func testNonJSONBodiesOfEqualLengthButDifferentContentAreCoarselyReportedAsSameLength() {
        let a = makeDetail(uid: "a", responseBody: "hello world")
        let b = makeDetail(uid: "b", responseBody: "hello there")
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(diff.responseBody, .sameLength(bytes: 11))
    }

    func testNonJSONBodiesOfDifferentLength() {
        let a = makeDetail(uid: "a", responseBody: "short")
        let b = makeDetail(uid: "b", responseBody: "a fair bit longer than that")
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(diff.responseBody, .differentLength(before: 5, after: 27))
    }

    func testIdenticalNonJSONBodiesAreReportedIdentical() {
        let a = makeDetail(uid: "a", responseBody: "plain text, not json")
        let b = makeDetail(uid: "b", responseBody: "plain text, not json")
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(diff.responseBody, .identical)
    }

    func testOneEmptyBody() {
        let a = makeDetail(uid: "a", responseBody: nil)
        let b = makeDetail(uid: "b", responseBody: #"{"a": 1}"#)
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(diff.responseBody, .oneEmpty)
    }

    func testBothEmptyBodiesAreNotFlaggedAsADifference() {
        let a = makeDetail(uid: "a", responseBody: nil)
        let b = makeDetail(uid: "b", responseBody: "")
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(diff.responseBody, .bothEmpty)
        XCTAssertTrue(diff.identical)
    }

    /// Redaction re-serializes a JSON body (pretty-printed, sorted keys) as a
    /// side effect of walking it; a byte-length compare against the
    /// untouched non-JSON side would be comparing formatting, not content.
    func testOnlyOneSideBeingJSONIsNotComparableRatherThanCoarselyLengthCompared() {
        let a = makeDetail(uid: "a", responseBody: #"{"a": 1}"#)
        let b = makeDetail(uid: "b", responseBody: "not json at all")
        let diff = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(diff.responseBody, .notComparable)
    }

    // MARK: - Cap

    func testCapIsHitAndReportedAsTruncated() {
        // Driven by the diff's own cap, not a page-size constant: the two
        // are unrelated and this test used to break when they diverged.
        let count = MCPSessionDiff.maxReportedChanges + 50
        let a = makeDetail(uid: "a", responseBody: manyKeysBody(value: "old", count: count))
        let b = makeDetail(uid: "b", responseBody: manyKeysBody(value: "new", count: count))
        let diff = MCPSessionDiff.diff(a, b)
        guard case .structural(let jsonDiff) = diff.responseBody else {
            return XCTFail("expected a structural JSON diff")
        }
        XCTAssertTrue(jsonDiff.truncated)
        XCTAssertEqual(jsonDiff.changed.count, MCPSessionDiff.maxReportedChanges)

        let text = MCPSessionDiffFormat.render(diff)
        XCTAssertTrue(text.contains("more differences than shown"))
    }

    func testWellUnderTheCapIsNotReportedAsTruncated() {
        let a = makeDetail(uid: "a", responseBody: manyKeysBody(value: "old", count: 5))
        let b = makeDetail(uid: "b", responseBody: manyKeysBody(value: "new", count: 5))
        let diff = MCPSessionDiff.diff(a, b)
        guard case .structural(let jsonDiff) = diff.responseBody else {
            return XCTFail("expected a structural JSON diff")
        }
        XCTAssertFalse(jsonDiff.truncated)
        XCTAssertEqual(jsonDiff.changed.count, 5)
    }

    // MARK: - Determinism

    func testSameInputsProduceTheSameDiffAndTheSameRenderTwice() {
        let a = makeDetail(
            uid: "a",
            statusCode: 200,
            requestHeaders: ["Accept": "application/json", "X-Trace": "1"],
            responseHeaders: ["Content-Type": "application/json", "ETag": "\"v1\""],
            requestBody: #"{"page": 1, "filters": {"active": true, "tags": ["x", "y"]}}"#,
            responseBody: #"{"page": 1, "items": ["a", "b"], "total": 2}"#
        )
        let b = makeDetail(
            uid: "b",
            statusCode: 404,
            requestHeaders: ["Accept": "application/json", "X-Trace": "2", "X-New": "1"],
            responseHeaders: ["Content-Type": "text/plain"],
            requestBody: #"{"page": 2, "filters": {"active": false, "tags": ["x", "z"]}}"#,
            responseBody: #"{"page": 2, "items": ["a"], "total": 1}"#
        )

        let first = MCPSessionDiff.diff(a, b)
        let second = MCPSessionDiff.diff(a, b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(MCPSessionDiffFormat.render(first), MCPSessionDiffFormat.render(second))
        // Rendering the same value twice must also be stable, independent of
        // whether recomputing the diff itself is.
        XCTAssertEqual(MCPSessionDiffFormat.render(first), MCPSessionDiffFormat.render(first))
    }
}
