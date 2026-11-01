//
//  MCPStreamEgressTests.swift
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

/// What an agent may see of a stream: complete events only, each redacted,
/// assembled values redacted whole, and the deltas that spell a redacted
/// value masked.
final class MCPStreamEgressTests: XCTestCase {
    private let facts = MCPSessionStreamFacts(isRelay: false, contentType: "text/event-stream", host: "api.anthropic.com",
                                              responseDurationMs: 4210)

    private func page(_ body: String, redacting: Bool = true, from: Int? = nil, limit: Int? = nil) -> MCPStreamEventsPage {
        let prepared = MCPStreamEgress.prepare(body: body, format: .sse, redacting: redacting)
        return MCPStreamEgress.eventsPage(uid: "u1", prepared: prepared, stream: facts, from: from, limit: limit)
    }

    private func assembled(_ body: String, redacting: Bool = true) -> MCPStreamAssembled {
        let prepared = MCPStreamEgress.prepare(body: body, format: .sse, redacting: redacting)
        return MCPStreamEgress.assembled(uid: "u1", prepared: prepared, stream: facts)
    }

    private func everything(_ page: MCPStreamEventsPage) -> String {
        page.events.map { [$0.name ?? "", $0.data, $0.id ?? ""].joined(separator: " ") }.joined(separator: "\n")
    }

    // MARK: Paging and numbering

    func testEventsAreNumberedFromOneAndPaged() {
        let first = page(StreamFixtures.anthropicToolUse, limit: 5)
        XCTAssertEqual(first.events.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(first.events.first?.name, "message_start")
        XCTAssertEqual(first.nextFrom, 6)
        XCTAssertEqual(first.facts.totalEvents, 14)
        XCTAssertEqual(first.facts.provider, .anthropicMessages)
        XCTAssertEqual(first.facts.responseDurationMs, 4210)
        XCTAssertNil(first.facts.timeToFirstEventMs, "a finished body has no arrival times")
        let last = page(StreamFixtures.anthropicToolUse, from: 11, limit: 50)
        XCTAssertEqual(last.events.map(\.number), [11, 12, 13, 14])
        XCTAssertNil(last.nextFrom)
    }

    func testAPageStopsAtItsDataBudgetButAlwaysReturnsOneEvent() {
        let big = String(repeating: "x", count: MCPStreamEgress.eventDataMaxBytes)
        let body = (0..<40).map { _ in "data: {\"text\":\"\(big)\"}\n\n" }.joined()
        let result = page(body, limit: 200)
        XCTAssertLessThan(result.events.count, 40)
        XCTAssertGreaterThan(result.events.count, 0)
        XCTAssertEqual(result.nextFrom, result.events.count + 1)
        XCTAssertTrue(result.events.allSatisfy(\.dataTruncated))
    }

    // MARK: Per-event redaction

    func testJSONInAnEventIsRedactedByKeyNameEvenWhenTheValueIsShort() {
        // The value is 7 characters: no shape detector sees it. Only parsing
        // the event and reading the key name does.
        let body = "event: config\ndata: {\"user\":\"ann\",\"api_key\":\"hunter2\",\"nested\":{\"password\":\"pw1\"}}\n\n"
        let result = page(body)
        XCTAssertFalse(everything(result).contains("hunter2"))
        XCTAssertFalse(everything(result).contains("pw1"))
        XCTAssertTrue(result.events[0].data.contains("\"user\":\"ann\""), "the rest of the event survives")
    }

    func testNonJSONDataIsRedactedByShapeAggressively() {
        let body = "data: token ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789 and Zx9Qw8Er7Ty6Ui5Op4As3Df2\n\n"
        let data = page(body).events[0].data
        XCTAssertFalse(data.contains("ghp_abcdef"))
        XCTAssertFalse(data.contains("Zx9Qw8Er7Ty6Ui5Op4As3Df2"))
    }

    func testAnEventNameAndIdAreRedactedToo() {
        let body = "event: sk_live_" + "abcdefghijklmnop\nid: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig\ndata: {}\n\n"
        let result = page(body)
        XCTAssertFalse(everything(result).contains("sk_live_abcdef"))
        XCTAssertFalse(everything(result).contains("eyJhbGciOiJIUzI1NiJ9"))
    }

    // MARK: Only complete events leave

    func testATrailingFragmentIsWithheldAsPendingBytes() {
        // The stream was cut after "sk_live_" — as an event it would be
        // unrecognisable, which is exactly why it is never one.
        let body = StreamFixtures.anthropicToolUse + "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"sk_live_"
        let result = page(body, limit: 200)
        XCTAssertEqual(result.facts.totalEvents, 14)
        XCTAssertGreaterThan(result.facts.pendingBytes, 60)
        XCTAssertFalse(everything(result).contains("sk_live_"))
        XCTAssertTrue(MCPTextFormat.streamEvents(result).contains("bytes pending — an incomplete event at the end is withheld"))
    }

    // MARK: A secret split across deltas

    func testASecretSplitAcrossTwoTextDeltasIsRedactedWholeAndItsDeltasMasked() {
        let body = anthropic(textDeltas: ["Your key is sk_live_", "4eC39HqLyjWDarjtT1zdp7dc", " — keep it safe."])
        // Each half on its own passes per-event redaction untouched:
        XCTAssertEqual(MCPStreamEgress.redactEventData("{\"t\":\"sk_live_\"}", maskingDeltasFor: nil), "{\"t\":\"sk_live_\"}")

        let whole = assembled(body)
        XCTAssertEqual(whole.text, "Your key is «redacted» — keep it safe.")
        let events = page(body)
        let text = everything(events)
        XCTAssertFalse(text.contains("4eC39HqLyjWDarjtT1zdp7dc"), "the second half must not leave through the events view")
        XCTAssertFalse(text.contains("sk_live_"))
        XCTAssertEqual(events.withheldDeltaEvents, 3, "every delta of the block that spells it")
        XCTAssertEqual(events.events.filter(\.deltaWithheld).count, 3)
        XCTAssertTrue(MCPTextFormat.streamEvents(events).contains("Withheld: the delta of 3 events is masked"))
    }

    func testASecretSplitAcrossToolArgumentDeltasIsFoundByKeyName() {
        let body = anthropic(textDeltas: [], toolDeltas: ["{\"api_k", "ey\": \"hunter2\", \"q\": \"weather\"}"])
        let whole = assembled(body)
        XCTAssertEqual(whole.blocks.first?.content, "{\"api_key\":\"«redacted»\",\"q\":\"weather\"}")
        XCTAssertEqual(whole.blocks.first?.argumentsAreJSON, true)
        let text = everything(page(body))
        XCTAssertFalse(text.contains("hunter2"))
    }

    func testCleanDeltasAreNotMasked() {
        let events = page(StreamFixtures.anthropicToolUse, limit: 200)
        XCTAssertEqual(events.withheldDeltaEvents, 0)
        XCTAssertTrue(events.events[3].data.contains("\"text\":\"Okay\""))
    }

    func testAnExceptedHostIsShownAsRecorded() {
        let body = anthropic(textDeltas: ["sk_live_", "4eC39HqLyjWDarjtT1zdp7dc"])
        XCTAssertTrue(everything(page(body, redacting: false)).contains("4eC39HqLyjWDarjtT1zdp7dc"))
        XCTAssertEqual(assembled(body, redacting: false).text, "sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc")
    }

    // MARK: Assembled view

    func testAssembledCarriesModelStopUsageAndError() {
        let result = assembled(StreamFixtures.anthropicError)
        XCTAssertEqual(result.model, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(result.error?.type, "overloaded_error")
        XCTAssertEqual(result.error?.eventNumber, 4)
        XCTAssertFalse(result.completed)
        let text = MCPTextFormat.streamAssembled(result)
        XCTAssertTrue(text.contains("Error (event #4): overloaded_error — Overloaded"))
        XCTAssertTrue(text.contains("ended without its end marker"))

        let chat = MCPTextFormat.streamAssembled(assembled(StreamFixtures.openAIChatToolCall))
        XCTAssertTrue(chat.contains("OpenAI Chat Completions · model gpt-4o-mini-2024-07-18 · stop: tool_calls · complete"))
        XCTAssertTrue(chat.contains("Usage: input 83 · output 17 · cache read 0 · reasoning 0 · total 100"))
        XCTAssertTrue(chat.contains("Tool call get_weather call_DdmO9pD3xa9XTPNJ32zg2hcA:\n{\"location\":\"Paris, France\"}"))
    }

    func testAnUnrecognisedStreamPointsAtTheEvents() {
        let text = MCPTextFormat.streamAssembled(assembled("data: hello\n\n"))
        XCTAssertTrue(text.contains("Not a recognised LLM stream"))
    }

    // MARK: The whole body, for get_session's default view

    func testRedactBodyOfAStreamRedactsInsideEachEvent() {
        // Before this step a stream body was "unknown text": the free-text
        // pass cannot see a short value under a sensitive key.
        let body = "event: config\ndata: {\"password\":\"hunter2\"}\n\ndata: [DONE]\n\n: ping\ndata: {\"cut\":"
        let redacted = MCPRedactor().redactBody(body, contentType: "text/event-stream; charset=utf-8")
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains("event: config\ndata: {\"password\":\"«redacted»\"}\n"))
        XCTAssertTrue(redacted.contains("data: [DONE]"))
        XCTAssertTrue(redacted.contains(": 1 comment line omitted"))
        XCTAssertTrue(redacted.contains(": 13 bytes pending — an incomplete event at the end is withheld"))
        XCTAssertFalse(redacted.contains("{\"cut\":"))
    }

    func testRedactBodyOfNDJSONRedactsEachLine() {
        let body = "{\"token\":\"abc\"}\n{\"ok\":true}\n{\"partial\":"
        let redacted = MCPRedactor().redactBody(body, contentType: "application/x-ndjson")
        XCTAssertEqual(redacted, "{\"token\":\"«redacted»\"}\n{\"ok\":true}\n[11 bytes pending — an incomplete line at the end is withheld]")
    }

    func testTheDetailOfAStreamIsRedactedPerEvent() {
        let summary = MCPSessionSummary(uid: "s", host: "api.example.com", method: "POST", url: "https://api.example.com/v1",
                                        scheme: "https", contentType: "text/event-stream")
        let detail = MCPSessionDetail(summary: summary, responseBodyPreview: "data: {\"secret\":\"abc123\"}\n\n")
        XCTAssertFalse(MCPRedactor().redactDetail(detail).responseBodyPreview?.contains("abc123") ?? true)
    }

    // MARK: Whole copies of a block (review finding, S5)

    /// The Responses fixture with a key-named secret in the function call:
    /// two argument deltas that split the key NAME, then the three events that
    /// repeat the arguments whole (`.done`, `output_item.done`, and the
    /// `response.completed` output).
    private var responsesWithKeyNamedSecret: String {
        StreamFixtures.openAIResponsesToolCall
            .replacingOccurrences(of: #""delta":"{\"location\":\"Pa"}"#, with: #""delta":"{\"api_k"}"#)
            .replacingOccurrences(of: #""delta":"ris, France\"}"}"#, with: #""delta":"ey\":\"hunter2\",\"location\":\"Paris\"}"}"#)
            .replacingOccurrences(of: #"{\"location\":\"Paris, France\"}"#, with: #"{\"api_key\":\"hunter2\",\"location\":\"Paris\"}"#)
            .replacingOccurrences(of: #""usage":{"input_tokens":37"#,
                                  with: #""output":[{"type":"function_call","name":"get_weather","arguments":"{\"api_key\":\"hunter2\"}"}],"usage":{"input_tokens":37"#)
    }

    func testAKeyNamedSecretInResponsesToolArgumentsIsRedactedInTheWholeCopiesToo() {
        let body = responsesWithKeyNamedSecret
        // The fixture edit took: every copy carries the secret before redaction.
        XCTAssertEqual(body.components(separatedBy: "hunter2").count - 1, 4)
        let raw = page(body, redacting: false, limit: 200)
        XCTAssertTrue(everything(raw).contains("hunter2"))

        let events = page(body, limit: 200)
        XCTAssertFalse(everything(events).contains("hunter2"), everything(events))
        XCTAssertEqual(events.withheldDeltaEvents, 2, "the two argument deltas")
        // The whole copies are redacted by key name, not masked: the rest of
        // the arguments still reads.
        XCTAssertTrue(everything(events).contains(#"{\"api_key\":\"«redacted»\",\"location\":\"Paris\"}"#))

        let whole = assembled(body)
        XCTAssertEqual(whole.blocks.last?.content, #"{"api_key":"«redacted»","location":"Paris"}"#)
        XCTAssertFalse(MCPTextFormat.streamAssembled(whole).contains("hunter2"))

        let redacted = MCPRedactor().redactBody(body, contentType: "text/event-stream")
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains("response.completed"))
    }

    func testAToolCallDeliveredOnlyWholeIsRedactedByKeyName() {
        // No deltas at all: nothing is masked, so the whole copy alone must hold.
        let body = """
        event: response.output_item.done
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"login","arguments":"{\\"password\\":\\"pw9\\",\\"user\\":\\"ann\\"}"}}


        """
        let events = page(body)
        XCTAssertEqual(events.withheldDeltaEvents, 0)
        XCTAssertFalse(everything(events).contains("pw9"))
        XCTAssertTrue(everything(events).contains("ann"))
        XCTAssertFalse(MCPRedactor().redactBody(body, contentType: "text/event-stream").contains("pw9"))
    }

    func testJSONInsideAStringIsWalkedButLeftAloneWhenClean() {
        // Chat Completions arguments sent in one piece, in an ordinary JSON body.
        let secret = #"{"choices":[{"message":{"tool_calls":[{"function":{"name":"f","arguments":"{\"api_key\": \"hunter2\", \"q\": 1}"}}]}}]}"#
        let redacted = MCPRedactor().redactBody(secret, contentType: "application/json")
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains(#"\"q\":1"#), redacted)
        // A clean nested document keeps its exact spelling (spaces, key order).
        let clean = #"{"arguments":"{\"b\": 1, \"a\": 2}"}"#
        XCTAssertEqual(MCPStreamEgress.redactEventData(clean, maskingDeltasFor: nil), #"{"arguments":"{\"b\": 1, \"a\": 2}"}"#)
        // A string that merely starts with a brace is not touched.
        XCTAssertEqual(MCPRedactor.redactJSON("{not json") as? String, "{not json")
    }

    // MARK: Tool arguments cut short (review finding, S5)

    func testCutToolArgumentsAreRedactedByKeyNameAndTheirDeltasMasked() {
        let body = anthropic(textDeltas: [], toolDeltas: [#"{"q": "weather", "password": "s3cr"#, #"etPw"#])
        let whole = assembled(body)
        let content = whole.blocks.first?.content ?? ""
        XCTAssertEqual(whole.blocks.first?.argumentsAreJSON, false)
        XCTAssertFalse(content.contains("s3cr"), content)
        XCTAssertTrue(content.contains(#""q": "weather""#), "the rest of the cut arguments still reads: \(content)")
        let events = page(body)
        XCTAssertFalse(everything(events).contains("s3cr"))
        XCTAssertFalse(everything(events).contains("etPw"))
        XCTAssertEqual(events.withheldDeltaEvents, 2)
    }

    func testPartialJSONByName() {
        let r = MCPRedactor.redactPartialJSONByName
        XCTAssertEqual(r(#"{"password": "s3cretPw"#), #"{"password": "«redacted»""#)
        XCTAssertEqual(r(#"{"a":"x","token":"abc","b":"y"#), #"{"a":"x","token":"«redacted»","b":"y"#)
        XCTAssertEqual(r(#"{"pin": 1234, "n": 5"#), #"{"pin": "«redacted»", "n": 5"#)
        XCTAssertEqual(r(#"{"secret": "ab\"#), #"{"secret": "«redacted»""#, "cut after an escape")
        XCTAssertEqual(r(#"{"q":"x","credentials":{"user":"ann","pw":"zz9"#), #"{"q":"x","credentials":"«redacted»""#)
        XCTAssertEqual(r(#"{"q": "plain", "n": 3"#), #"{"q": "plain", "n": 3"#)
        XCTAssertEqual(r(#"{"passw"#), #"{"passw"#, "a cut name has no value to hide")
    }

    // MARK: A body labelled as a stream that is not one (review finding, S5)

    func testABodyLabelledAsAStreamThatIsNotOneIsRedactedAsWhatItIs() {
        let redactor = MCPRedactor()
        let error = redactor.redactBody(#"{"error":"bad","api_key":"hunter2"}"#, contentType: "text/event-stream")
        XCTAssertTrue(error.contains(#""error" : "bad""#), error)
        XCTAssertFalse(error.contains("hunter2"))
        XCTAssertFalse(error.contains("pending"))

        let omitted = "[binary body omitted — text/event-stream, 5120 bytes]"
        XCTAssertEqual(redactor.redactBody(omitted, contentType: "text/event-stream"), omitted)
        let omittedNDJSON = "[binary body omitted — application/x-ndjson, 5120 bytes]"
        XCTAssertEqual(redactor.redactBody(omittedNDJSON, contentType: "application/x-ndjson"), omittedNDJSON)
        let ndjsonDocument = redactor.redactBody(#"{"error":"bad"}"#, contentType: "application/x-ndjson")
        XCTAssertTrue(ndjsonDocument.contains(#""error" : "bad""#), ndjsonDocument)
    }

    func testAStreamShapedBodyWithOnlyAnUnfinishedEventIsStillWithheld() {
        let redactor = MCPRedactor()
        let sse = redactor.redactBody(#"data: {"api_key":"hunter2"}"#, contentType: "text/event-stream")
        XCTAssertFalse(sse.contains("hunter2"))
        XCTAssertTrue(sse.contains("bytes pending"), sse)
        let ndjson = redactor.redactBody(#"{"token":"ab"#, contentType: "application/x-ndjson")
        XCTAssertFalse(ndjson.contains("ab\""))
        XCTAssertTrue(ndjson.contains("bytes pending"), ndjson)
    }

    // MARK: Helpers

    /// A minimal Anthropic stream with the given text and tool-argument deltas.
    private func anthropic(textDeltas: [String], toolDeltas: [String] = []) -> String {
        func json(_ value: String) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)!
        }
        var events = ["event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-x\",\"usage\":{\"input_tokens\":1}}}"]
        if !textDeltas.isEmpty {
            events.append("event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
            for delta in textDeltas {
                events.append("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\(json(delta))}}")
            }
        }
        if !toolDeltas.isEmpty {
            events.append("event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"search\",\"input\":{}}}")
            for delta in toolDeltas {
                events.append("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(json(delta))}}")
            }
        }
        events.append("event: message_stop\ndata: {\"type\":\"message_stop\"}")
        return events.joined(separator: "\n\n") + "\n\n"
    }
}

/// The bridge routes and the stdio tool's text.
final class MCPStreamRouteTests: XCTestCase {
    private let token = "t"

    private func router(contentType: String? = "text/event-stream", body: String? = StreamFixtures.anthropicToolUse,
                        relay: Bool = false, redactor: MCPRedactor = MCPRedactor()) -> MCPBridgeRouter {
        let summary = MCPSessionSummary(uid: "s1", host: "api.anthropic.com", method: "POST",
                                        url: "https://api.anthropic.com/v1/messages", scheme: "https",
                                        contentType: contentType, kind: relay ? .relay : .exchange)
        let provider = StubSessionProvider(
            summaries: [summary],
            details: ["s1": MCPSessionDetail(summary: summary)],
            bodies: body.map { ["s1:response": $0] } ?? [:]
        )
        return MCPBridgeRouter(token: token, sessions: provider, status: StubStatusProvider(), redactor: redactor)
    }

    private func get(_ router: MCPBridgeRouter, _ target: String) -> ParsedResponse? {
        parseRawResponse(router.respond(to: makeRequest(target: target, token: token)))
    }

    func testEventsRouteReturnsAPage() throws {
        let response = try XCTUnwrap(get(router(), "/v1/sessions/s1/events?from=2&limit=3"))
        XCTAssertEqual(response.status, 200)
        let page = try JSONDecoder().decode(MCPStreamEventsPage.self, from: response.body)
        XCTAssertEqual(page.events.map(\.number), [2, 3, 4])
        XCTAssertEqual(page.nextFrom, 5)
        XCTAssertEqual(page.facts.format, .sse)
    }

    func testAssembledRouteReturnsTheAnswer() throws {
        let response = try XCTUnwrap(get(router(), "/v1/sessions/s1/assembled"))
        XCTAssertEqual(response.status, 200)
        let result = try JSONDecoder().decode(MCPStreamAssembled.self, from: response.body)
        XCTAssertEqual(result.text, "Okay, let's check the weather for San Francisco, CA:")
        XCTAssertEqual(result.blocks.last?.name, "get_weather")
    }

    func testANonStreamIsRefusedWithWhatToDoInstead() throws {
        let response = try XCTUnwrap(get(router(contentType: "application/json", body: "{}"), "/v1/sessions/s1/events"))
        XCTAssertEqual(response.status, 400)
        let error = response.json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "not_a_stream")
        XCTAssertTrue((error?["message"] as? String)?.contains("call get_session without a view") ?? false)
    }

    func testARelayAndAnUnknownSessionAre404() throws {
        XCTAssertEqual(get(router(relay: true), "/v1/sessions/s1/events")?.status, 404)
        XCTAssertEqual(get(router(), "/v1/sessions/nope/assembled")?.status, 404)
        XCTAssertEqual(get(router(body: nil), "/v1/sessions/s1/events")?.status, 404)
    }

    func testTheRoutesNeedTheToken() {
        let response = router().respond(to: makeRequest(target: "/v1/sessions/s1/events"))
        XCTAssertEqual(parseRawResponse(response)?.status, 401)
    }

    func testAPerHostExceptionReachesTheStreamViews() throws {
        let body = "data: {\"api_key\":\"hunter2\"}\n\n"
        let redacting = try XCTUnwrap(get(router(body: body), "/v1/sessions/s1/events"))
        XCTAssertFalse(String(decoding: redacting.body, as: UTF8.self).contains("hunter2"))
        let excepted = router(body: body, redactor: MCPRedactor(policy: MCPRedactionPolicy(exceptedHosts: ["api.anthropic.com"])))
        let shown = try XCTUnwrap(get(excepted, "/v1/sessions/s1/events"))
        XCTAssertTrue(String(decoding: shown.body, as: UTF8.self).contains("hunter2"))
    }

    func testTheEventsTextNamesEachEventAndHowToContinue() throws {
        let response = try XCTUnwrap(get(router(), "/v1/sessions/s1/events?limit=2"))
        let page = try JSONDecoder().decode(MCPStreamEventsPage.self, from: response.body)
        let text = MCPTextFormat.streamEvents(page)
        XCTAssertTrue(text.hasPrefix("Stream s1: Anthropic Messages · 14 events · arrival times not recorded"))
        XCTAssertTrue(text.contains("#1 message_start\n  {\"message\":"))
        XCTAssertTrue(text.contains("More: call get_session with view=events and from=3."))
    }
}
