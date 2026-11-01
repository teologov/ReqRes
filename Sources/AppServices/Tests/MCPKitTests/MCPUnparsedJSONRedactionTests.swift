//
//  MCPUnparsedJSONRedactionTests.swift
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

/// JSON that does not parse as one document — cut short by a retention cap,
/// behind an anti-XSSI prefix, inside a JSONP call, or two documents back to
/// back — must still lose its values by NAME (release review, 2026-09-29).
final class MCPUnparsedJSONRedactionTests: XCTestCase {
    let redactor = MCPRedactor()

    static let shapes: [(String, String)] = [
        ("cut short", #"{"password":"hunter22","items":[1,2"#),
        ("cut inside the value", #"{"user":"a","password":"hunter2"#),
        ("XSSI prefix", ")]}'\n{\"password\":\"hunter22\"}"),
        ("while(1) prefix", #"while(1);{"password":"hunter22"}"#),
        ("JSONP", #"cb({"password":"hunter22"});"#),
        ("concatenated", "{\"a\":1}\n{\"password\":\"hunter22\"}"),
        ("NDJSON as application/json", "{\"a\":1}\n{\"refresh_token\":\"hunter22\"}\n"),
    ]

    func testEveryUnparsedShapeLosesTheNamedValue() {
        for (name, body) in Self.shapes {
            let out = redactor.redactBody(body, contentType: "application/json")
            XCTAssertFalse(out.contains("hunter2"), "\(name): \(out)")
            XCTAssertTrue(out.contains(MCPRedactor.placeholder), "\(name): \(out)")
        }
    }

    func testAWrapperIsKeptAndTheInsideIsWalkedStructurally() {
        let xssi = redactor.redactBody(")]}'\n{\"password\":\"hunter22\",\"ok\":true}", contentType: "application/json")
        XCTAssertTrue(xssi.hasPrefix(")]}'"), xssi)
        XCTAssertTrue(xssi.contains("\"ok\" : true"), xssi)

        let jsonp = redactor.redactBody(#"cb({"token":{"value":"x"},"ok":1});"#, contentType: "text/javascript")
        XCTAssertTrue(jsonp.hasPrefix("cb("), jsonp)
        XCTAssertTrue(jsonp.hasSuffix(");"), jsonp)
        XCTAssertFalse(jsonp.contains("\"x\""), jsonp)
    }

    func testAWholeDocumentIsUnchangedInBehaviour() {
        let out = redactor.redactBody(#"{"password":"hunter22","name":"ann"}"#, contentType: "application/json")
        XCTAssertFalse(out.contains("hunter22"))
        XCTAssertTrue(out.contains("ann"))
    }

    /// The two egress paths that used plain `redactBody` before: an agent's
    /// session detail and a HAR written to disk.
    func testDetailAndHARDoNotCarryACutShortSecret() throws {
        for (name, body) in Self.shapes {
            var summary = makeSession(uid: "s1")
            summary.contentType = "application/json"
            var detail = MCPSessionDetail(
                summary: summary,
                requestHeaders: ["Content-Type": "application/json"],
                responseHeaders: ["Content-Type": "application/json"],
                requestBodyPreview: body,
                responseBodyPreview: body
            )
            detail.responseBodyNotRetainedBytes = 1_000
            let redacted = redactor.redactDetail(detail)
            XCTAssertFalse(redacted.requestBodyPreview?.contains("hunter2") ?? false, name)
            XCTAssertFalse(redacted.responseBodyPreview?.contains("hunter2") ?? false, name)

            let har = MCPHARExport.encode(sessions: [detail], redactor: redactor, creatorVersion: "test").data
            let text = String(decoding: har, as: UTF8.self)
            XCTAssertFalse(text.contains("hunter2"), "\(name): HAR carried the secret")
        }
    }
}
