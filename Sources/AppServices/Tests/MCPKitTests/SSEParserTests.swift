//
//  SSEParserTests.swift
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

/// The WHATWG "interpreting an event stream" rules, one test each, plus the
/// property the live transport depends on: any chunking gives the same events.
final class SSEParserTests: XCTestCase {
    private func parse(_ text: String) -> (events: [SSEParser.Event], parser: SSEParser) {
        var parser = SSEParser()
        let events = parser.feed(text)
        parser.finish()
        return (events, parser)
    }

    private func parse(bytes: [UInt8]) -> [SSEParser.Event] {
        var parser = SSEParser()
        let events = parser.feed(bytes)
        parser.finish()
        return events
    }

    // MARK: The spec's own examples

    func testMultipleDataLinesJoinWithLF() {
        // WHATWG example: "data: YHOO / data: +2 / data: 10".
        let events = parse("data: YHOO\ndata: +2\ndata: 10\n\n").events
        XCTAssertEqual(events.map(\.data), ["YHOO\n+2\n10"])
        XCTAssertEqual(events.first?.type, "message")
        XCTAssertNil(events.first?.name)
    }

    func testCommentsIdsAndOneStrippedSpace() {
        // WHATWG example: a comment, an id, an empty id resetting it, and a
        // value that keeps its SECOND space.
        let text = ": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n"
        let (events, parser) = parse(text)
        XCTAssertEqual(events.map(\.data), ["first event", "second event", " third event"])
        XCTAssertEqual(events.map(\.id), ["1", nil, nil])
        XCTAssertEqual(parser.commentCount, 1)
    }

    func testEmptyDataFieldsAndAnUnterminatedLastBlock() {
        // WHATWG example: "data" alone is a data field with an empty value.
        // The final "data:" has no blank line after it: never dispatched.
        let (events, parser) = parse("data\n\ndata\ndata\n\ndata:")
        XCTAssertEqual(events.map(\.data), ["", "\n"])
        XCTAssertEqual(parser.pendingByteCount, 5, "the unterminated 'data:' is pending, not an event")
    }

    func testSpaceAfterColonIsOptional() {
        XCTAssertEqual(parse("data:test\n\ndata: test\n\n").events.map(\.data), ["test", "test"])
    }

    // MARK: Line endings

    func testCRLFAndCRAndLFAreEquivalent() {
        let lf = parse("event: a\ndata: 1\n\ndata: 2\n\n").events
        let crlf = parse("event: a\r\ndata: 1\r\n\r\ndata: 2\r\n\r\n").events
        let cr = parse("event: a\rdata: 1\r\rdata: 2\r\r").events
        XCTAssertEqual(lf.map(\.data), ["1", "2"])
        XCTAssertEqual(crlf.map(\.data), lf.map(\.data))
        XCTAssertEqual(cr.map(\.data), lf.map(\.data))
        XCTAssertEqual(crlf.map(\.name), ["a", nil])
        XCTAssertEqual(cr.map(\.name), ["a", nil])
    }

    func testACRLFSplitAcrossChunksIsOneLineEnding() {
        // The LF of "data: a\r\n" arrives in the next chunk. Read as a second
        // line ending it would be a blank line and dispatch "a" alone.
        var parser = SSEParser()
        var events = parser.feed("data: a\r")
        events += parser.feed("\ndata: b\r\n\r\n")
        XCTAssertEqual(events.map(\.data), ["a\nb"])
    }

    // MARK: BOM

    func testOneLeadingBOMIsIgnored() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)
        XCTAssertEqual(parse(bytes: bytes).map(\.data), ["x"])
    }

    func testABOMSplitAcrossChunksIsStillIgnored() {
        var parser = SSEParser()
        var events = parser.feed([0xEF])
        events += parser.feed([0xBB])
        events += parser.feed([0xBF] + Array("data: x\n\n".utf8))
        XCTAssertEqual(events.map(\.data), ["x"])
    }

    func testASecondBOMIsNotStripped() {
        // Only ONE leading BOM goes; the next one is part of the field name,
        // so "\u{FEFF}data" is an unknown field and nothing dispatches.
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)
        XCTAssertEqual(parse(bytes: bytes), [])
    }

    func testAStreamThatIsOnlyPartOfABOMLosesNothing() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed([0xEF, 0xBB]), [])
        parser.finish()
        XCTAssertEqual(parser.pendingByteCount, 2, "a partial BOM at the end is content, pending")
    }

    // MARK: Fields

    func testEventTypeResetsAfterDispatchAndAnEmptyBlockResetsItToo() {
        let events = parse("event: first\ndata: 1\n\ndata: 2\n\nevent: dropped\n\ndata: 3\n\n").events
        XCTAssertEqual(events.map(\.name), ["first", nil, nil])
        XCTAssertEqual(events.map(\.data), ["1", "2", "3"])
    }

    func testIDPersistsAcrossEventsAndNULIsRefused() {
        let events = parse("id: 7\ndata: a\n\ndata: b\n\nid: bad\u{0}id\ndata: c\n\nid\ndata: d\n\n").events
        XCTAssertEqual(events.map(\.id), ["7", "7", "7", nil])
    }

    func testRetryOnlyForASCIIDigits() {
        let (events, parser) = parse("retry: 10a\ndata: a\n\nretry: 3000\ndata: b\n\nretry: -1\ndata: c\n\n")
        XCTAssertEqual(events.map(\.retry), [nil, 3000, nil])
        XCTAssertEqual(parser.reconnectionTime, 3000)
    }

    func testARetryTooLargeForIntSaturatesInsteadOfTrapping() {
        let (events, _) = parse("retry: 99999999999999999999999999\ndata: a\n\n")
        XCTAssertEqual(events.first?.retry, Int.max)
    }

    func testUnknownFieldsAndColonlessLinesAreIgnored() {
        XCTAssertEqual(parse("foo: bar\ndata: x\nbaz\n\n").events.map(\.data), ["x"])
    }

    func testInvalidUTF8DecodesToReplacementCharacters() {
        let bytes = Array("data: a".utf8) + [0xFF] + Array("b\n\n".utf8)
        XCTAssertEqual(parse(bytes: bytes).map(\.data), ["a\u{FFFD}b"])
    }

    // MARK: Offsets and pending bytes

    func testByteRangesCoverTheEventsLinesAndTheirBlankLine() {
        let text = ": hi\ndata: one\n\nevent: e\ndata: two\n\n"
        let events = parse(text).events
        let bytes = Array(text.utf8)
        XCTAssertEqual(String(decoding: bytes[events[0].byteRange], as: UTF8.self), "data: one\n\n")
        XCTAssertEqual(String(decoding: bytes[events[1].byteRange], as: UTF8.self), "event: e\ndata: two\n\n")
    }

    func testPendingCountsTheUndispatchedBlockButNotComments() {
        var parser = SSEParser()
        _ = parser.feed(": keepalive\n")
        XCTAssertEqual(parser.pendingByteCount, 0, "a comment is never an event")
        _ = parser.feed("event: delta\r\ndata: {\"a\":")
        XCTAssertEqual(parser.pendingByteCount, "event: delta\r\ndata: {\"a\":".utf8.count)
        let events = parser.feed("1}\n\n")
        XCTAssertEqual(events.map(\.data), ["{\"a\":1}"])
        XCTAssertEqual(parser.pendingByteCount, 0)
    }

    // MARK: Chunking never changes the result

    /// Every fixture, fed one byte at a time, then in every two-piece split,
    /// gives exactly the events of the whole body — BOM, CRLF and multi-byte
    /// characters included.
    func testAnyChunkingGivesTheSameEvents() {
        let tricky = "\u{FEFF}event: grüße\r\ndata: {\"t\":\"日本語 ✓ 🚀\"}\r\n\r\n: c\rdata: é\r\rid: x\ndata: last\n\ndata: tail"
        for body in [tricky, StreamFixtures.anthropicToolUse, StreamFixtures.openAIChatToolCall, StreamFixtures.openAIResponsesToolCall] {
            let bytes = Array(body.utf8)
            var whole = SSEParser()
            let expected = whole.feed(bytes)
            whole.finish()
            XCTAssertFalse(expected.isEmpty)

            var single = SSEParser()
            var byByte: [SSEParser.Event] = []
            for byte in bytes { byByte += single.feed([byte]) }
            single.finish()
            XCTAssertEqual(byByte, expected, "byte-at-a-time")
            XCTAssertEqual(single.pendingByteCount, whole.pendingByteCount)

            let step = max(1, bytes.count / 97)
            for cut in stride(from: 0, through: bytes.count, by: step) {
                var parser = SSEParser()
                var events = parser.feed(bytes[..<cut])
                events += parser.feed(bytes[cut...])
                parser.finish()
                XCTAssertEqual(events, expected, "split at \(cut)")
            }
        }
    }
}

final class NDJSONSplitterTests: XCTestCase {
    private func split(_ bytes: [UInt8]) -> (lines: [NDJSONSplitter.Line], splitter: NDJSONSplitter) {
        var splitter = NDJSONSplitter()
        let lines = splitter.feed(bytes)
        splitter.finish()
        return (lines, splitter)
    }

    func testOneValuePerLineBlankLinesSkippedCRStripped() {
        let (lines, _) = split(Array("{\"a\":1}\r\n\n  \n{\"b\":2}\n".utf8))
        XCTAssertEqual(lines.map(\.text), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testTheUnterminatedLastLineIsPendingNotARecord() {
        let (lines, splitter) = split(Array("{\"a\":1}\n{\"b\":".utf8))
        XCTAssertEqual(lines.map(\.text), ["{\"a\":1}"])
        XCTAssertEqual(splitter.pendingByteCount, 5)
    }

    func testBOMAndRecordSeparatorAreStripped() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("{\"a\":1}\n".utf8) + [0x1E] + Array("{\"b\":2}\n".utf8)
        XCTAssertEqual(split(bytes).lines.map(\.text), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testByteAtATimeMatchesWhole() {
        let bytes = Array((StreamFixtures.ndjson + "{\"ü\":\"🚀\"}\r\n{\"cut\":").utf8)
        let expected = split(bytes).lines
        var splitter = NDJSONSplitter()
        var lines: [NDJSONSplitter.Line] = []
        for byte in bytes { lines += splitter.feed([byte]) }
        XCTAssertEqual(lines, expected)
        XCTAssertEqual(expected.count, 4)
        XCTAssertEqual(splitter.pendingByteCount, "{\"cut\":".utf8.count)
    }
}
