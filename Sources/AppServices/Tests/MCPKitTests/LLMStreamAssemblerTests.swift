//
//  LLMStreamAssemblerTests.swift
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

final class StreamEventLogTests: XCTestCase {
    func testFormatDetectionIgnoresParametersAndCase() {
        XCTAssertEqual(StreamFormat.detect(contentType: "text/event-stream; charset=utf-8"), .sse)
        XCTAssertEqual(StreamFormat.detect(contentType: "Text/Event-Stream"), .sse)
        XCTAssertEqual(StreamFormat.detect(contentType: "application/x-ndjson"), .ndjson)
        XCTAssertEqual(StreamFormat.detect(contentType: "application/jsonl"), .ndjson)
        XCTAssertNil(StreamFormat.detect(contentType: "application/json"))
        XCTAssertNil(StreamFormat.detect(contentType: nil))
    }

    func testAppendReturnsOnlyTheNewEventsAndStampsTheCompletingChunksTime() {
        var log = StreamEventLog(format: .sse)
        XCTAssertEqual(log.append(text: "data: 1\n\ndata: ", receivedAt: 0.4), 0..<1)
        XCTAssertEqual(log.pendingByteCount, "data: ".utf8.count)
        XCTAssertEqual(log.append(text: "2\n\n", receivedAt: 1.5), 1..<2)
        XCTAssertEqual(log.append(text: "data: 3\n\ndata: 4\n\n", receivedAt: 1.7), 2..<4)
        XCTAssertEqual(log.events.map(\.receivedAt), [0.4, 1.5, 1.7, 1.7],
                       "an event is stamped with the time of the bytes that COMPLETED it")
        let timing = log.timing
        XCTAssertEqual(timing.timeToFirstEvent, 0.4)
        XCTAssertEqual(timing.longestGap?.duration ?? 0, 1.1, accuracy: 1e-9)
        XCTAssertEqual(timing.longestGap?.afterEventIndex, 0)
        XCTAssertEqual(timing.timedEvents, 4)
    }

    func testAFinishedBodyHasNoInventedTimes() {
        let log = StreamEventLog.parse(body: StreamFixtures.anthropicToolUse, format: .sse)
        XCTAssertEqual(log.events.count, 14)
        XCTAssertTrue(log.events.allSatisfy { $0.receivedAt == nil })
        XCTAssertNil(log.timing.timeToFirstEvent)
        XCTAssertNil(log.timing.longestGap)
        XCTAssertEqual(log.timing.timedEvents, 0)
        XCTAssertEqual(log.pendingByteCount, 0)
    }

    func testNothingIsAppendedAfterFinish() {
        var log = StreamEventLog(format: .ndjson)
        log.append(text: "{\"a\":1}\n")
        log.finish()
        XCTAssertEqual(log.append(text: "{\"b\":2}\n"), 1..<1)
        XCTAssertEqual(log.events.count, 1)
    }

    func testNDJSONLinesBecomeEvents() {
        let log = StreamEventLog.parse(body: StreamFixtures.ndjson, format: .ndjson)
        XCTAssertEqual(log.events.count, 3)
        XCTAssertNil(log.events[0].name)
        XCTAssertTrue(log.events[2].data.contains("\"done\":true"))
    }
}

final class LLMStreamAssemblerTests: XCTestCase {
    private func assemble(_ body: String) -> LLMStreamAssembly {
        LLMStreamAssembler.assemble(StreamEventLog.parse(body: body, format: .sse).events)
    }

    // MARK: Anthropic Messages

    func testAnthropicTextToolCallStopReasonUsageAndModel() {
        let assembly = assemble(StreamFixtures.anthropicToolUse)
        XCTAssertEqual(assembly.provider, .anthropicMessages)
        XCTAssertEqual(assembly.model, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(assembly.responseID, "msg_014p7gG3wDgGV9EUtLvnow3U")
        XCTAssertEqual(assembly.text, "Okay, let's check the weather for San Francisco, CA:")
        XCTAssertEqual(assembly.toolCalls.count, 1)
        let call = try? XCTUnwrap(assembly.toolCalls.first)
        XCTAssertEqual(call?.id, "toolu_01T1x1fJ34qAmk2tNTrN7Up6")
        XCTAssertEqual(call?.name, "get_weather")
        XCTAssertEqual(call?.content, "{\"location\": \"San Francisco, CA\", \"unit\": \"fahrenheit\"}")
        XCTAssertEqual(call?.deltaEventIndices, [7, 8, 9, 10], "an empty partial_json still counts")
        XCTAssertEqual(assembly.blocks.first?.deltaEventIndices, [3, 4])
        XCTAssertEqual(assembly.stopReason, "tool_use")
        XCTAssertEqual(assembly.usage, LLMStreamAssembly.Usage(inputTokens: 472, outputTokens: 89,
                                                               cacheReadInputTokens: 128, cacheCreationInputTokens: 0))
        XCTAssertTrue(assembly.completed)
        XCTAssertEqual(assembly.recognizedEvents, 14)
        XCTAssertEqual(assembly.unrecognizedEvents, 0)
        XCTAssertNil(assembly.error)
    }

    func testAnthropicErrorEvent() {
        let assembly = assemble(StreamFixtures.anthropicError)
        XCTAssertEqual(assembly.provider, .anthropicMessages)
        XCTAssertEqual(assembly.error?.type, "overloaded_error")
        XCTAssertEqual(assembly.error?.message, "Overloaded")
        XCTAssertEqual(assembly.error?.eventIndex, 3)
        XCTAssertEqual(assembly.text, "Hello")
        XCTAssertFalse(assembly.completed, "no message_stop: the stream did not finish")
    }

    func testAStreamCutShortIsNotComplete() {
        let body = StreamFixtures.anthropicToolUse.components(separatedBy: "event: message_delta")[0]
        let assembly = assemble(body)
        XCTAssertFalse(assembly.completed)
        XCTAssertNil(assembly.stopReason)
    }

    // MARK: OpenAI Chat Completions

    func testChatTextToolCallFinishReasonUsageAndDone() {
        let assembly = assemble(StreamFixtures.openAIChatToolCall)
        XCTAssertEqual(assembly.provider, .openAIChatCompletions)
        XCTAssertEqual(assembly.model, "gpt-4o-mini-2024-07-18")
        XCTAssertEqual(assembly.responseID, "chatcmpl-AyPNinnUqUDYo9SAdA52NobMflmj2")
        XCTAssertEqual(assembly.text, "Let me check.")
        XCTAssertEqual(assembly.toolCalls.map(\.id), ["call_DdmO9pD3xa9XTPNJ32zg2hcA"])
        XCTAssertEqual(assembly.toolCalls.map(\.name), ["get_weather"])
        XCTAssertEqual(assembly.toolCalls.first?.content, "{\"location\":\"Paris, France\"}")
        XCTAssertEqual(assembly.stopReason, "tool_calls")
        XCTAssertEqual(assembly.usage, LLMStreamAssembly.Usage(inputTokens: 83, outputTokens: 17, cacheReadInputTokens: 0,
                                                               reasoningTokens: 0, totalTokens: 100))
        XCTAssertTrue(assembly.completed, "[DONE] ends a Chat Completions stream")
        XCTAssertEqual(assembly.unrecognizedEvents, 0)
    }

    func testChatErrorObject() {
        let assembly = assemble(StreamFixtures.openAIChatError)
        XCTAssertEqual(assembly.provider, .openAIChatCompletions)
        XCTAssertEqual(assembly.error?.type, "server_error")
        XCTAssertEqual(assembly.error?.message, "The server had an error while processing your request. Sorry about that!")
        XCTAssertEqual(assembly.text, "The")
        XCTAssertFalse(assembly.completed)
    }

    func testChatSeveralChoicesStayApartAndTextIsTheFirst() {
        let body = """
        data: {"object":"chat.completion.chunk","model":"m","choices":[{"index":0,"delta":{"content":"A"}},{"index":1,"delta":{"content":"B"}}]}

        data: {"object":"chat.completion.chunk","model":"m","choices":[{"index":1,"delta":{"content":"b"}},{"index":0,"delta":{"content":"a"}}]}


        """
        let assembly = assemble(body)
        XCTAssertEqual(assembly.text, "Aa")
        XCTAssertEqual(assembly.blocks.filter { $0.choice == 1 }.map(\.content), ["Bb"])
    }

    // MARK: OpenAI Responses

    func testResponsesTextFunctionCallStatusAndUsage() {
        let assembly = assemble(StreamFixtures.openAIResponsesToolCall)
        XCTAssertEqual(assembly.provider, .openAIResponses)
        XCTAssertEqual(assembly.model, "gpt-4.1-2025-04-14")
        XCTAssertEqual(assembly.responseID, "resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654")
        XCTAssertEqual(assembly.text, "Checking Paris now.")
        XCTAssertEqual(assembly.toolCalls.map(\.id), ["call_12345xyz"])
        XCTAssertEqual(assembly.toolCalls.map(\.name), ["get_weather"])
        XCTAssertEqual(assembly.toolCalls.first?.content, "{\"location\":\"Paris, France\"}")
        XCTAssertEqual(assembly.stopReason, "completed")
        XCTAssertEqual(assembly.usage, LLMStreamAssembly.Usage(inputTokens: 37, outputTokens: 24, cacheReadInputTokens: 0,
                                                               reasoningTokens: 0, totalTokens: 61))
        XCTAssertTrue(assembly.completed)
        XCTAssertEqual(assembly.unrecognizedEvents, 0)
    }

    func testResponsesErrorEvent() {
        let assembly = assemble(StreamFixtures.openAIResponsesError)
        XCTAssertEqual(assembly.provider, .openAIResponses)
        XCTAssertEqual(assembly.error?.code, "ERR_SOMETHING")
        XCTAssertEqual(assembly.error?.message, "Something went wrong")
        XCTAssertFalse(assembly.completed)
    }

    func testResponsesIncompleteReasonIsTheStopReason() {
        let body = """
        event: response.incomplete
        data: {"type":"response.incomplete","response":{"id":"resp_1","status":"incomplete","model":"gpt-4.1","incomplete_details":{"reason":"max_output_tokens"}}}


        """
        XCTAssertEqual(assemble(body).stopReason, "max_output_tokens")
    }

    // MARK: Unknown shapes, and incremental equals whole

    func testAnUnknownStreamIsCountedNotGuessed() {
        let body = "data: hello\n\ndata: {\"foo\":1}\n\nevent: tick\ndata: 42\n\n"
        let assembly = assemble(body)
        XCTAssertNil(assembly.provider)
        XCTAssertEqual(assembly.unrecognizedEvents, 3)
        XCTAssertEqual(assembly.recognizedEvents, 0)
        XCTAssertTrue(assembly.blocks.isEmpty)
    }

    func testFeedingEventsAsTheyArriveEqualsAssemblingTheWhole() {
        for body in [StreamFixtures.anthropicToolUse, StreamFixtures.openAIChatToolCall, StreamFixtures.openAIResponsesToolCall] {
            var log = StreamEventLog(format: .sse)
            var assembler = LLMStreamAssembler()
            for (offset, byte) in Array(body.utf8).enumerated() {
                for index in log.append([byte], receivedAt: Double(offset)) { assembler.consume(log.events[index]) }
            }
            XCTAssertEqual(assembler.assembly, assemble(body))
        }
    }

    func testMaskingReplacesExactlyTheDeltaFields() {
        let anthropic = LLMStreamAssembler.maskingDeltas(
            in: ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "secret"]],
            provider: .anthropicMessages, placeholder: "X"
        )
        XCTAssertEqual((anthropic["delta"] as? [String: Any])?["text"] as? String, "X")
        XCTAssertEqual((anthropic["delta"] as? [String: Any])?["type"] as? String, "text_delta")

        let chat = LLMStreamAssembler.maskingDeltas(
            in: ["choices": [["index": 0, "delta": ["content": "s", "tool_calls": [["index": 0, "function": ["name": "f", "arguments": "a"]]]]]]],
            provider: .openAIChatCompletions, placeholder: "X"
        )
        let delta = ((chat["choices"] as? [Any])?.first as? [String: Any])?["delta"] as? [String: Any]
        XCTAssertEqual(delta?["content"] as? String, "X")
        let function = ((delta?["tool_calls"] as? [Any])?.first as? [String: Any])?["function"] as? [String: Any]
        XCTAssertEqual(function?["arguments"] as? String, "X")
        XCTAssertEqual(function?["name"] as? String, "f", "names are not deltas")

        let responses = LLMStreamAssembler.maskingDeltas(
            in: ["type": "response.output_text.delta", "delta": "s"], provider: .openAIResponses, placeholder: "X"
        )
        XCTAssertEqual(responses["delta"] as? String, "X")
    }

    func testCountsFromTheNetworkNeverTrap() {
        XCTAssertNil(LLMStreamAssembler.int(1e300))
        XCTAssertNil(LLMStreamAssembler.int(Double(Int.max)))
        XCTAssertNil(LLMStreamAssembler.int(true))
        XCTAssertEqual(LLMStreamAssembler.int(42), 42)
    }
}
