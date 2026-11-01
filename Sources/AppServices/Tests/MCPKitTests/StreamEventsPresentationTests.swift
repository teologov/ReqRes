//
//  StreamEventsPresentationTests.swift
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

/// The Events tab's words and numbers.
final class StreamEventsPresentationTests: XCTestCase {
    func testOffsetsAreWholeGroupedMilliseconds() {
        XCTAssertEqual(StreamEventsPresentation.offset(1.2044), "+1,204 ms")
        XCTAssertEqual(StreamEventsPresentation.offset(0), "+0 ms")
        XCTAssertNil(StreamEventsPresentation.offset(nil))
    }

    func testTheSummaryOfATimedStream() {
        var log = StreamEventLog(format: .sse)
        log.append(text: StreamFixtures.anthropicToolUse.components(separatedBy: "event: content_block_start")[0], receivedAt: 0.412)
        log.append(text: "event: ping\ndata: {\"type\":\"ping\"}\n\n", receivedAt: 1.442)
        log.append(text: "event: ping\ndata: {\"type\":\"ping\"}\n\n", receivedAt: 1.5)
        let assembly = LLMStreamAssembler.assemble(log.events)
        XCTAssertEqual(StreamEventsPresentation.summary(log: log, assembly: assembly, responseDurationMs: 2000),
                       "Anthropic Messages · 3 events · first event +412 ms · longest gap 1,030 ms (after #1)")
    }

    func testTheSummaryOfAFinishedBodySaysTimesWereNotRecorded() {
        let log = StreamEventLog.parse(body: "data: a\n\ndata: b\n\n", format: .sse)
        XCTAssertEqual(StreamEventsPresentation.summary(log: log, assembly: LLMStreamAssembler.assemble(log.events), responseDurationMs: 4210),
                       "Server-sent events · 2 events · streamed for 4,210 ms · arrival times not recorded")
    }

    func testTheAssemblyLine() {
        let log = StreamEventLog.parse(body: StreamFixtures.anthropicToolUse, format: .sse)
        let line = StreamEventsPresentation.assemblyLine(LLMStreamAssembler.assemble(log.events))
        XCTAssertEqual(line, "claude-sonnet-4-5-20250929 · stop: tool_use · tokens 472 in / 89 out / 128 cached · 1 tool call · complete")
        XCTAssertEqual(StreamEventsPresentation.grouped(12288), "12,288")
        XCTAssertNil(StreamEventsPresentation.assemblyLine(LLMStreamAssembly()))
    }

    func testTitlesPreferTheEventFieldThenTheJSONType() {
        let named = StreamEvent(index: 0, name: "content_block_delta", data: "{}")
        let chat = StreamEvent(index: 1, data: "{\"object\":\"chat.completion.chunk\"}")
        let typed = StreamEvent(index: 2, data: "{\"type\":\"response.completed\"}")
        let plain = StreamEvent(index: 3, data: "[DONE]")
        XCTAssertEqual(StreamEventsPresentation.title(of: named, format: .sse), "content_block_delta")
        XCTAssertEqual(StreamEventsPresentation.title(of: chat, format: .sse), "chat.completion.chunk")
        XCTAssertEqual(StreamEventsPresentation.title(of: typed, format: .sse), "response.completed")
        XCTAssertEqual(StreamEventsPresentation.title(of: plain, format: .sse), "message")
        XCTAssertEqual(StreamEventsPresentation.title(of: plain, format: .ndjson), "line")
    }

    func testErrorsAreRecognisedInEachShape() {
        XCTAssertTrue(StreamEventsPresentation.isError(StreamEvent(index: 0, name: "error", data: "{}")))
        XCTAssertTrue(StreamEventsPresentation.isError(StreamEvent(index: 0, data: "{\"error\":{\"message\":\"x\"}}")))
        XCTAssertTrue(StreamEventsPresentation.isError(StreamEvent(index: 0, data: "{\"type\":\"error\",\"code\":\"E\"}")))
        XCTAssertFalse(StreamEventsPresentation.isError(StreamEvent(index: 0, data: "{\"type\":\"ping\"}")))
    }

    func testAccessibilityLabelSaysNumberNameErrorAndTime() {
        let event = StreamEvent(index: 3, name: "error", data: "{}", receivedAt: 1.2)
        XCTAssertEqual(StreamEventsPresentation.accessibilityLabel(for: event, format: .sse),
                       "Event 4, error, error, 1,200 ms after the response started")
    }

    func testPendingLine() {
        let log = StreamEventLog.parse(body: "data: a\n\ndata: {\"b\"", format: .sse)
        XCTAssertEqual(StreamEventsPresentation.pendingLine(log), "10 bytes pending — an incomplete event at the end is withheld")
    }

    func testALongEventIsCutOnACharacterBoundaryAndSaysHowMuchIsLeft() {
        let data = String(repeating: "é", count: 10) // 20 bytes
        let (text, hidden) = StreamEventsPresentation.displayData(data, maxBytes: 5)
        XCTAssertEqual(text, "éé")
        XCTAssertEqual(hidden, 16)
        XCTAssertEqual(StreamEventsPresentation.displayData("{\"a\":1}", maxBytes: 100).hiddenBytes, 0)
        XCTAssertTrue(StreamEventsPresentation.hiddenLine(2048).hasSuffix("more — the Body tab shows the whole event"))
    }

    // MARK: JSONReindent

    func testReindentKeepsKeyOrderNumbersAndEscapes() {
        let text = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a \"q\" {x}, [y]: z"},"n":1.50,"e":[],"o":{}}"#
        XCTAssertEqual(JSONReindent.pretty(text), """
        {
          "type": "content_block_delta",
          "index": 0,
          "delta": {
            "type": "text_delta",
            "text": "a \\"q\\" {x}, [y]: z"
          },
          "n": 1.50,
          "e": [],
          "o": {}
        }
        """)
    }

    func testReindentLeavesNonJSONAlone() {
        XCTAssertNil(JSONReindent.pretty("[DONE]"))
        XCTAssertNil(JSONReindent.pretty("{\"cut\":"))
        XCTAssertEqual(StreamEventsPresentation.displayData("plain text"), "plain text")
    }

    func testReindentIsNotFooledByACombiningMarkAfterAQuote() {
        // "\u{301}" after a closing quote makes quote+mark ONE Character.
        let text = "{\"a\":\"x\"\u{301},\"b\":1}"
        // Not valid JSON (the mark sits outside the string) → untouched.
        XCTAssertNil(JSONReindent.pretty(text))
        let valid = "{\"a\":\"\u{301}\",\"b\":[1,2]}"
        XCTAssertEqual(JSONReindent.pretty(valid), "{\n  \"a\": \"\u{301}\",\n  \"b\": [\n    1,\n    2\n  ]\n}")
    }
}
