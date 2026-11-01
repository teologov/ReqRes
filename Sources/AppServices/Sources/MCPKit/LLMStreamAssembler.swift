//
//  LLMStreamAssembler.swift
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

import Foundation

/// What an LLM stream said, put back together from its deltas.
public struct LLMStreamAssembly: Equatable, Sendable {
    public enum Provider: String, Codable, Equatable, Sendable {
        case anthropicMessages = "anthropic_messages"
        case openAIChatCompletions = "openai_chat_completions"
        case openAIResponses = "openai_responses"

        public var displayName: String {
            switch self {
            case .anthropicMessages: return "Anthropic Messages"
            case .openAIChatCompletions: return "OpenAI Chat Completions"
            case .openAIResponses: return "OpenAI Responses"
            }
        }
    }

    public enum BlockKind: String, Codable, Equatable, Sendable {
        case text
        case toolCall = "tool_call"
        case thinking
        case refusal
    }

    /// One piece of output: a text block, a tool call's arguments, a thinking
    /// block, a refusal. In the order the stream opened them.
    public struct Block: Equatable, Sendable {
        public var kind: BlockKind
        /// The provider's own identity for it ("a:0", "c:0:t:1", "r:2").
        public var key: String
        /// Chat Completions choice (`n` > 1); nil for the other APIs.
        public var choice: Int?
        /// The tool call's id (`toolu_…`, `call_…`).
        public var id: String?
        /// The tool's name.
        public var name: String?
        /// The text, or the tool call's arguments as sent (JSON text).
        public var content: String
        /// Indices of the events whose DELTA built `content`. Egress masks
        /// exactly these when the assembled value holds a credential.
        public var deltaEventIndices: [Int]

        public init(kind: BlockKind, key: String, choice: Int? = nil, id: String? = nil, name: String? = nil,
                    content: String = "", deltaEventIndices: [Int] = []) {
            self.kind = kind
            self.key = key
            self.choice = choice
            self.id = id
            self.name = name
            self.content = content
            self.deltaEventIndices = deltaEventIndices
        }
    }

    public struct Usage: Codable, Equatable, Sendable {
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheReadInputTokens: Int?
        public var cacheCreationInputTokens: Int?
        public var reasoningTokens: Int?
        public var totalTokens: Int?

        public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadInputTokens: Int? = nil,
                    cacheCreationInputTokens: Int? = nil, reasoningTokens: Int? = nil, totalTokens: Int? = nil) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
        }

        public var isEmpty: Bool {
            inputTokens == nil && outputTokens == nil && cacheReadInputTokens == nil
                && cacheCreationInputTokens == nil && reasoningTokens == nil && totalTokens == nil
        }
    }

    /// An error the stream itself reported (an `error` event, a failed
    /// response) — distinct from a transport failure, which is the row's
    /// outcome.
    public struct StreamError: Codable, Equatable, Sendable {
        public var type: String?
        public var code: String?
        public var message: String?
        /// 0-based index of the event that carried it.
        public var eventIndex: Int

        public init(type: String? = nil, code: String? = nil, message: String? = nil, eventIndex: Int) {
            self.type = type
            self.code = code
            self.message = message
            self.eventIndex = eventIndex
        }
    }

    public var provider: Provider?
    public var model: String?
    public var responseID: String?
    public var blocks: [Block] = []
    /// `stop_reason` (Anthropic), `finish_reason` (Chat), or the response's
    /// final status / incomplete reason (Responses).
    public var stopReason: String?
    public var usage: Usage?
    public var error: StreamError?
    /// The stream's own end marker arrived (`message_stop`, `[DONE]`,
    /// `response.completed|incomplete|failed`). False for a stream cut short.
    public var completed = false
    public var recognizedEvents = 0
    public var unrecognizedEvents = 0

    public init() {}

    /// The answer's text: every text block of the first choice, in order.
    public var text: String {
        blocks.filter { $0.kind == .text && ($0.choice ?? 0) == 0 }.map(\.content).joined()
    }

    public var toolCalls: [Block] { blocks.filter { $0.kind == .toolCall } }
}

/// Puts an Anthropic Messages, OpenAI Chat Completions or OpenAI Responses
/// stream back together, one event at a time (so the live transport can
/// feed it as events arrive). Anything it does not recognise is counted,
/// never guessed at — the raw events remain the truth.
///
/// Shapes, from the public API references:
/// - **Anthropic Messages**: `message_start` (model, id, input usage) →
///   `content_block_start` (index; text | tool_use with id+name | thinking)
///   → `content_block_delta` (text_delta.text | input_json_delta.partial_json
///   | thinking_delta.thinking) → `content_block_stop` → `message_delta`
///   (stop_reason, cumulative output_tokens) → `message_stop`; `ping`;
///   `error` (`{"type":"error","error":{"type","message"}}`).
/// - **Chat Completions**: `chat.completion.chunk` objects with
///   `choices[].delta` (content, refusal, tool_calls[].function.arguments by
///   `index`), `finish_reason`, a final `usage` chunk, then `[DONE]`; an
///   error is `{"error":{…}}`.
/// - **Responses**: typed events — `response.created`,
///   `response.output_item.added`, `response.output_text.delta`,
///   `response.function_call_arguments.delta|done`,
///   `response.completed|incomplete|failed` (status, usage), `error`.
public struct LLMStreamAssembler: Sendable {
    public private(set) var assembly = LLMStreamAssembly()
    private var blockIndexByKey: [String: Int] = [:]

    public init() {}

    public static func assemble(_ events: [StreamEvent]) -> LLMStreamAssembly {
        var assembler = LLMStreamAssembler()
        events.forEach { assembler.consume($0) }
        return assembler.assembly
    }

    static let anthropicTypes: Set<String> = [
        "message_start", "content_block_start", "content_block_delta", "content_block_stop",
        "message_delta", "message_stop", "ping",
    ]

    public mutating func consume(_ event: StreamEvent) {
        let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" {
            if assembly.provider == nil || assembly.provider == .openAIChatCompletions {
                assembly.completed = true
                assembly.recognizedEvents += 1
            } else {
                assembly.unrecognizedEvents += 1
            }
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
            assembly.unrecognizedEvents += 1
            return
        }
        let type = (object["type"] as? String) ?? event.name
        if assembly.provider == nil {
            assembly.provider = Self.detectProvider(object: object, type: type, eventName: event.name)
        }
        let recognized: Bool
        switch assembly.provider {
        case .anthropicMessages?: recognized = consumeAnthropic(object, type: type, event: event)
        case .openAIChatCompletions?: recognized = consumeChat(object, event: event)
        case .openAIResponses?: recognized = consumeResponses(object, type: type, event: event)
        case nil: recognized = false
        }
        if recognized { assembly.recognizedEvents += 1 } else { assembly.unrecognizedEvents += 1 }
    }

    static func detectProvider(object: [String: Any], type: String?, eventName: String?) -> LLMStreamAssembly.Provider? {
        if let type {
            if anthropicTypes.contains(type) { return .anthropicMessages }
            if type.hasPrefix("response.") { return .openAIResponses }
            if type == "error" {
                // Anthropic nests the error; Responses puts code and message
                // at the top level.
                if object["error"] is [String: Any] { return .anthropicMessages }
                if object["message"] != nil || object["code"] != nil { return .openAIResponses }
            }
        }
        if (object["object"] as? String) == "chat.completion.chunk" || object["choices"] is [Any] {
            return .openAIChatCompletions
        }
        if object["error"] is [String: Any], type == nil { return .openAIChatCompletions }
        return nil
    }

    // MARK: - Blocks

    private mutating func block(_ key: String, kind: LLMStreamAssembly.BlockKind, choice: Int? = nil) -> Int {
        if let index = blockIndexByKey[key] { return index }
        assembly.blocks.append(LLMStreamAssembly.Block(kind: kind, key: key, choice: choice))
        blockIndexByKey[key] = assembly.blocks.count - 1
        return assembly.blocks.count - 1
    }

    private mutating func appendDelta(_ text: String, to key: String, kind: LLMStreamAssembly.BlockKind,
                                      choice: Int? = nil, event: StreamEvent) {
        let index = block(key, kind: kind, choice: choice)
        assembly.blocks[index].content += text
        if assembly.blocks[index].deltaEventIndices.last != event.index {
            assembly.blocks[index].deltaEventIndices.append(event.index)
        }
    }

    // MARK: - Anthropic Messages

    private mutating func consumeAnthropic(_ object: [String: Any], type: String?, event: StreamEvent) -> Bool {
        switch type {
        case "message_start":
            guard let message = object["message"] as? [String: Any] else { return false }
            assembly.model = (message["model"] as? String) ?? assembly.model
            assembly.responseID = (message["id"] as? String) ?? assembly.responseID
            mergeAnthropicUsage(message["usage"])
            return true
        case "content_block_start":
            guard let index = Self.int(object["index"]), let content = object["content_block"] as? [String: Any] else { return false }
            let key = "a:\(index)"
            switch content["type"] as? String {
            case "text":
                let position = block(key, kind: .text)
                if let initial = content["text"] as? String { assembly.blocks[position].content += initial }
            case "tool_use", "server_tool_use", "mcp_tool_use":
                let position = block(key, kind: .toolCall)
                assembly.blocks[position].id = content["id"] as? String
                assembly.blocks[position].name = content["name"] as? String
            case "thinking":
                let position = block(key, kind: .thinking)
                if let initial = content["thinking"] as? String { assembly.blocks[position].content += initial }
            default:
                // redacted_thinking, tool results: nothing to assemble.
                break
            }
            return true
        case "content_block_delta":
            guard let index = Self.int(object["index"]), let delta = object["delta"] as? [String: Any] else { return false }
            let key = "a:\(index)"
            switch delta["type"] as? String {
            case "text_delta":
                appendDelta(delta["text"] as? String ?? "", to: key, kind: .text, event: event)
            case "input_json_delta":
                appendDelta(delta["partial_json"] as? String ?? "", to: key, kind: .toolCall, event: event)
            case "thinking_delta":
                appendDelta(delta["thinking"] as? String ?? "", to: key, kind: .thinking, event: event)
            case "signature_delta", "citations_delta":
                break
            default:
                return false
            }
            return true
        case "content_block_stop", "ping":
            return true
        case "message_delta":
            if let delta = object["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                assembly.stopReason = reason
            }
            mergeAnthropicUsage(object["usage"])
            return true
        case "message_stop":
            assembly.completed = true
            return true
        case "error":
            let error = object["error"] as? [String: Any]
            assembly.error = LLMStreamAssembly.StreamError(
                type: error?["type"] as? String, message: error?["message"] as? String, eventIndex: event.index
            )
            return true
        default:
            return false
        }
    }

    /// `message_start` carries input usage; `message_delta` carries the
    /// CUMULATIVE output count — later values replace, never add.
    private mutating func mergeAnthropicUsage(_ value: Any?) {
        guard let usage = value as? [String: Any] else { return }
        var merged = assembly.usage ?? LLMStreamAssembly.Usage()
        if let v = Self.int(usage["input_tokens"]) { merged.inputTokens = v }
        if let v = Self.int(usage["output_tokens"]) { merged.outputTokens = v }
        if let v = Self.int(usage["cache_read_input_tokens"]) { merged.cacheReadInputTokens = v }
        if let v = Self.int(usage["cache_creation_input_tokens"]) { merged.cacheCreationInputTokens = v }
        assembly.usage = merged
    }

    // MARK: - OpenAI Chat Completions

    private mutating func consumeChat(_ object: [String: Any], event: StreamEvent) -> Bool {
        if let error = object["error"] as? [String: Any] {
            assembly.error = LLMStreamAssembly.StreamError(
                type: error["type"] as? String, code: Self.string(error["code"]),
                message: error["message"] as? String, eventIndex: event.index
            )
            return true
        }
        guard object["choices"] is [Any] || (object["object"] as? String) == "chat.completion.chunk" else { return false }
        if let model = object["model"] as? String, !model.isEmpty { assembly.model = model }
        if let id = object["id"] as? String, !id.isEmpty { assembly.responseID = id }
        for case let choice as [String: Any] in object["choices"] as? [Any] ?? [] {
            let number = Self.int(choice["index"]) ?? 0
            if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty {
                    appendDelta(text, to: "c:\(number):text", kind: .text, choice: number, event: event)
                }
                for field in ["reasoning_content", "reasoning"] {
                    if let text = delta[field] as? String, !text.isEmpty {
                        appendDelta(text, to: "c:\(number):thinking", kind: .thinking, choice: number, event: event)
                    }
                }
                if let text = delta["refusal"] as? String, !text.isEmpty {
                    appendDelta(text, to: "c:\(number):refusal", kind: .refusal, choice: number, event: event)
                }
                for (position, element) in (delta["tool_calls"] as? [Any] ?? []).enumerated() {
                    guard let call = element as? [String: Any] else { continue }
                    let key = "c:\(number):t:\(Self.int(call["index"]) ?? position)"
                    let index = block(key, kind: .toolCall, choice: number)
                    if let id = call["id"] as? String, !id.isEmpty { assembly.blocks[index].id = id }
                    let function = call["function"] as? [String: Any]
                    if let name = function?["name"] as? String, !name.isEmpty { assembly.blocks[index].name = name }
                    if let arguments = function?["arguments"] as? String, !arguments.isEmpty {
                        appendDelta(arguments, to: key, kind: .toolCall, choice: number, event: event)
                    }
                }
                if let function = delta["function_call"] as? [String: Any] {
                    let key = "c:\(number):fc"
                    let index = block(key, kind: .toolCall, choice: number)
                    if let name = function["name"] as? String, !name.isEmpty { assembly.blocks[index].name = name }
                    if let arguments = function["arguments"] as? String, !arguments.isEmpty {
                        appendDelta(arguments, to: key, kind: .toolCall, choice: number, event: event)
                    }
                }
            }
            if let reason = choice["finish_reason"] as? String, number == 0 || assembly.stopReason == nil {
                assembly.stopReason = reason
            }
        }
        if let usage = object["usage"] as? [String: Any] {
            assembly.usage = LLMStreamAssembly.Usage(
                inputTokens: Self.int(usage["prompt_tokens"]),
                outputTokens: Self.int(usage["completion_tokens"]),
                cacheReadInputTokens: Self.int((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]),
                reasoningTokens: Self.int((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"]),
                totalTokens: Self.int(usage["total_tokens"])
            )
        }
        return true
    }

    // MARK: - OpenAI Responses

    private mutating func consumeResponses(_ object: [String: Any], type: String?, event: StreamEvent) -> Bool {
        let output = Self.int(object["output_index"]) ?? 0
        switch type {
        case "response.created", "response.in_progress", "response.queued":
            readResponse(object["response"])
            return true
        case "response.output_item.added", "response.output_item.done":
            guard let item = object["item"] as? [String: Any] else { return false }
            if ["function_call", "custom_tool_call"].contains(item["type"] as? String) {
                let key = "r:\(output)"
                let index = block(key, kind: .toolCall)
                assembly.blocks[index].id = (item["call_id"] as? String) ?? (item["id"] as? String) ?? assembly.blocks[index].id
                assembly.blocks[index].name = (item["name"] as? String) ?? assembly.blocks[index].name
                // The done item carries the whole arguments; the added one
                // usually an empty string. Only fill what the deltas did not.
                let whole = (item["arguments"] as? String) ?? (item["input"] as? String) ?? ""
                if assembly.blocks[index].content.isEmpty, !whole.isEmpty {
                    assembly.blocks[index].content = whole
                }
            }
            return true
        case "response.output_text.delta":
            let part = Self.int(object["content_index"]) ?? 0
            appendDelta(object["delta"] as? String ?? "", to: "r:\(output):\(part)", kind: .text, event: event)
            return true
        case "response.output_text.done":
            let part = Self.int(object["content_index"]) ?? 0
            let index = block("r:\(output):\(part)", kind: .text)
            if assembly.blocks[index].content.isEmpty, let whole = object["text"] as? String {
                assembly.blocks[index].content = whole
            }
            return true
        case "response.refusal.delta":
            let part = Self.int(object["content_index"]) ?? 0
            appendDelta(object["delta"] as? String ?? "", to: "r:\(output):\(part):refusal", kind: .refusal, event: event)
            return true
        case "response.function_call_arguments.delta", "response.custom_tool_call_input.delta":
            appendDelta(object["delta"] as? String ?? "", to: "r:\(output)", kind: .toolCall, event: event)
            return true
        case "response.function_call_arguments.done":
            let index = block("r:\(output)", kind: .toolCall)
            if let whole = object["arguments"] as? String { assembly.blocks[index].content = whole }
            return true
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            appendDelta(object["delta"] as? String ?? "", to: "r:\(output):reasoning", kind: .thinking, event: event)
            return true
        case "response.completed", "response.incomplete", "response.failed":
            readResponse(object["response"])
            assembly.completed = true
            if let response = object["response"] as? [String: Any] {
                let status = response["status"] as? String
                let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
                assembly.stopReason = reason ?? status ?? assembly.stopReason
                if let error = response["error"] as? [String: Any] {
                    assembly.error = LLMStreamAssembly.StreamError(
                        type: error["type"] as? String, code: Self.string(error["code"]),
                        message: error["message"] as? String, eventIndex: event.index
                    )
                }
            }
            return true
        case "error":
            assembly.error = LLMStreamAssembly.StreamError(
                type: "error", code: Self.string(object["code"]),
                message: object["message"] as? String, eventIndex: event.index
            )
            return true
        default:
            // The API has many more typed events (tool progress, annotations,
            // content parts); they are its own, just not assembled.
            return type?.hasPrefix("response.") == true
        }
    }

    private mutating func readResponse(_ value: Any?) {
        guard let response = value as? [String: Any] else { return }
        if let model = response["model"] as? String, !model.isEmpty { assembly.model = model }
        if let id = response["id"] as? String, !id.isEmpty { assembly.responseID = id }
        if let usage = response["usage"] as? [String: Any] {
            assembly.usage = LLMStreamAssembly.Usage(
                inputTokens: Self.int(usage["input_tokens"]),
                outputTokens: Self.int(usage["output_tokens"]),
                cacheReadInputTokens: Self.int((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"]),
                reasoningTokens: Self.int((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"]),
                totalTokens: Self.int(usage["total_tokens"])
            )
        }
    }

    // MARK: - Masking deltas

    /// A copy of one event's parsed data with the delta fields the assembler
    /// reads replaced by `placeholder`.
    ///
    /// Why: per-event redaction cannot see a credential the model emitted
    /// across two deltas (`"sk_live_"` then `"4eC39Hq…"`) — each half is
    /// harmless on its own. The assembled value CAN be redacted by shape, and
    /// when that changes it, egress masks every delta that built it.
    static func maskingDeltas(in object: [String: Any], provider: LLMStreamAssembly.Provider,
                              placeholder: String) -> [String: Any] {
        var result = object
        switch provider {
        case .anthropicMessages:
            if var delta = result["delta"] as? [String: Any] {
                for field in ["text", "partial_json", "thinking"] where delta[field] is String {
                    delta[field] = placeholder
                }
                result["delta"] = delta
            }
        case .openAIChatCompletions:
            if let choices = result["choices"] as? [Any] {
                result["choices"] = choices.map { element -> Any in
                    guard var choice = element as? [String: Any], var delta = choice["delta"] as? [String: Any] else { return element }
                    for field in ["content", "reasoning_content", "reasoning", "refusal"] where delta[field] is String {
                        delta[field] = placeholder
                    }
                    if let calls = delta["tool_calls"] as? [Any] {
                        delta["tool_calls"] = calls.map { element -> Any in
                            guard var call = element as? [String: Any], var function = call["function"] as? [String: Any],
                                  function["arguments"] is String else { return element }
                            function["arguments"] = placeholder
                            call["function"] = function
                            return call
                        }
                    }
                    if var function = delta["function_call"] as? [String: Any], function["arguments"] is String {
                        function["arguments"] = placeholder
                        delta["function_call"] = function
                    }
                    choice["delta"] = delta
                    return choice
                }
            }
        case .openAIResponses:
            if result["delta"] is String { result["delta"] = placeholder }
        }
        return result
    }

    // MARK: - JSON helpers

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            // NSNumber wraps Bool too; a Bool is not a count.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let double = number.doubleValue
            // `Double(Int.max)` rounds UP to 2^63, which `Int(_:)` traps on —
            // hence the strict upper bound. Data from the network never traps.
            guard double.isFinite, double >= Double(Int.min), double < Double(Int.max) else { return nil }
            return Int(double)
        default:
            return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
}
