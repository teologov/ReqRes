//
//  MCPJSONQueryTests.swift
//  AppServices
//
//  Created by OloApps on 8/26/26.
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

final class MCPJSONQueryTests: XCTestCase {
    let body = """
    {
      "meta": {"page": 2, "total": 137, "hasMore": true},
      "items": [
        {"id": "a1", "name": "First", "tags": ["x", "y"]},
        {"id": "b2", "name": "Second", "tags": []}
      ],
      "message": null
    }
    """

    // MARK: - Path parsing

    func testPathComponentsHandleKeysAndIndices() {
        XCTAssertEqual(MCPJSONQuery.components(of: "items[0].id"),
                       [.key("items"), .index(0), .key("id")])
        XCTAssertEqual(MCPJSONQuery.components(of: "a.b.c"),
                       [.key("a"), .key("b"), .key("c")])
        XCTAssertEqual(MCPJSONQuery.components(of: "matrix[1][2]"),
                       [.key("matrix"), .index(1), .index(2)])
    }

    // MARK: - Extraction

    func testExtractsNestedScalar() {
        let result = MCPJSONQuery.query(body: body, mode: .path, path: "items[0].name")
        XCTAssertTrue(result.found)
        XCTAssertEqual(result.text, "First")
    }

    func testExtractsNestedContainerAsPrettyJSON() {
        let result = MCPJSONQuery.query(body: body, mode: .path, path: "items[0].tags")
        XCTAssertTrue(result.found)
        XCTAssertTrue(result.text.contains("\"x\""))
        XCTAssertTrue(result.text.contains("\"y\""))
    }

    func testExtractsNumbersAndBooleansDistinctly() {
        XCTAssertEqual(MCPJSONQuery.query(body: body, mode: .path, path: "meta.total").text, "137")
        XCTAssertEqual(MCPJSONQuery.query(body: body, mode: .path, path: "meta.hasMore").text, "true")
    }

    func testMissingPathIsNotFoundAndSuggestsStructure() {
        let result = MCPJSONQuery.query(body: body, mode: .path, path: "items[9].name")
        XCTAssertFalse(result.found)
        XCTAssertTrue(result.text.contains("mode=structure"))
    }

    func testPathModeWithoutPathExplainsItself() {
        let result = MCPJSONQuery.query(body: body, mode: .path, path: nil)
        XCTAssertFalse(result.found)
        XCTAssertTrue(result.text.contains("needs a 'path'"))
    }

    // MARK: - Structure

    func testStructureListsKeysWithTypesAndSizes() {
        let result = MCPJSONQuery.query(body: body, mode: .structure, path: nil)
        XCTAssertTrue(result.found)
        XCTAssertTrue(result.text.contains("object with 3 keys"))
        XCTAssertTrue(result.text.contains("items: array(2 of object)"))
        XCTAssertTrue(result.text.contains("message: null"))
        // The whole point is NOT dumping the payload.
        XCTAssertFalse(result.text.contains("Second"))
    }

    func testStructureOfTopLevelArray() {
        let result = MCPJSONQuery.query(body: "[1,2,3]", mode: .structure, path: nil)
        XCTAssertTrue(result.text.contains("array of 3"))
    }

    func testLongStringsAreSummarizedNotDumped() {
        let long = String(repeating: "z", count: 500)
        let result = MCPJSONQuery.query(body: "{\"blob\":\"\(long)\"}", mode: .structure, path: nil)
        XCTAssertTrue(result.text.contains("string(500 chars)"))
        XCTAssertLessThan(result.text.count, 200)
    }

    // MARK: - Non-JSON

    func testNonJSONBodyIsReportedClearly() {
        let result = MCPJSONQuery.query(body: "<html><body>hi</body></html>", mode: .structure, path: nil)
        XCTAssertFalse(result.found)
        XCTAssertTrue(result.text.contains("not JSON"))
        XCTAssertTrue(result.text.contains("get_session"))
    }

    func testBooleanDiscriminationDoesNotMisreportNumbers() {
        XCTAssertEqual(MCPJSONQuery.summarize(NSNumber(value: true)), "bool: true")
        XCTAssertEqual(MCPJSONQuery.summarize(NSNumber(value: 1)), "number: 1")
    }
}
