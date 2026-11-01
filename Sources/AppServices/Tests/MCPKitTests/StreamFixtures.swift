//
//  StreamFixtures.swift
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
//  Stream bodies written by hand from the providers' public API references
//  (Anthropic "Streaming Messages", OpenAI "Streaming" for Chat Completions
//  and "Responses streaming events"), in the exact wire shape: SSE framing,
//  blank-line separators, the providers' own ids and field order. Each has a
//  tool call; each API's error event has its own fixture.
//

import Foundation

enum StreamFixtures {
    /// Anthropic Messages: text, then a tool_use whose input arrives as
    /// input_json_delta pieces, a ping, message_delta with the stop reason
    /// and cumulative output usage, message_stop.
    static let anthropicToolUse = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_014p7gG3wDgGV9EUtLvnow3U","type":"message","role":"assistant","model":"claude-sonnet-4-5-20250929","stop_sequence":null,"usage":{"input_tokens":472,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":128},"content":[],"stop_reason":null}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: ping
    data: {"type": "ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Okay"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", let's check the weather for San Francisco, CA:"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01T1x1fJ34qAmk2tNTrN7Up6","name":"get_weather","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"location\\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \\"San Francisc"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"o, CA\\", \\"unit\\": \\"fahrenheit\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":89}}

    event: message_stop
    data: {"type":"message_stop"}


    """

    /// Anthropic Messages: the documented mid-stream error ("overloaded").
    static let anthropicError = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_01XFDUDYJgAACzvnptvVoYEL","type":"message","role":"assistant","model":"claude-sonnet-4-5-20250929","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

    event: error
    data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}


    """

    /// OpenAI Chat Completions with `stream_options.include_usage`: a role
    /// chunk, text, a function tool call streamed by `index`, finish_reason,
    /// the usage-only chunk (`choices: []`), then `[DONE]`. No `event:`
    /// fields — every chunk is a default "message" event.
    static let openAIChatToolCall = """
    data: {"id":"chatcmpl-AyPNinnUqUDYo9SAdA52NobMflmj2","object":"chat.completion.chunk","created":1738960610,"model":"gpt-4o-mini-2024-07-18","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"role":"assistant","content":"","refusal":null},"logprobs":null,"finish_reason":null}],"usage":null}

    data: {"id":"chatcmpl-AyPNinnUqUDYo9SAdA52NobMflmj2","object":"chat.completion.chunk","created":1738960610,"model":"gpt-4o-mini-2024-07-18","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"content":"Let me check."},"logprobs":null,"finish_reason":null}],"usage":null}

    data: {"id":"chatcmpl-AyPNinnUqUDYo9SAdA52NobMflmj2","object":"chat.completion.chunk","created":1738960610,"model":"gpt-4o-mini-2024-07-18","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_DdmO9pD3xa9XTPNJ32zg2hcA","type":"function","function":{"name":"get_weather","arguments":""}}]},"logprobs":null,"finish_reason":null}],"usage":null}

    data: {"id":"chatcmpl-AyPNinnUqUDYo9SAdA52NobMflmj2","object":"chat.completion.chunk","created":1738960610,"model":"gpt-4o-mini-2024-07-18","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"lo"}}]},"logprobs":null,"finish_reason":null}],"usage":null}

    data: {"id":"chatcmpl-AyPNinnUqUDYo9SAdA52NobMflmj2","object":"chat.completion.chunk","created":1738960610,"model":"gpt-4o-mini-2024-07-18","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"cation\\":\\"Paris, France\\"}"}}]},"logprobs":null,"finish_reason":null}],"usage":null}

    data: {"id":"chatcmpl-AyPNinnUqUDYo9SAdA52NobMflmj2","object":"chat.completion.chunk","created":1738960610,"model":"gpt-4o-mini-2024-07-18","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}],"usage":null}

    data: {"id":"chatcmpl-AyPNinnUqUDYo9SAdA52NobMflmj2","object":"chat.completion.chunk","created":1738960610,"model":"gpt-4o-mini-2024-07-18","system_fingerprint":"fp_44709d6fcb","choices":[],"usage":{"prompt_tokens":83,"completion_tokens":17,"total_tokens":100,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}}

    data: [DONE]


    """

    /// OpenAI Chat Completions: an error object mid-stream, no `[DONE]`.
    static let openAIChatError = """
    data: {"id":"chatcmpl-B1","object":"chat.completion.chunk","created":1738960700,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"The"},"finish_reason":null}]}

    data: {"error":{"message":"The server had an error while processing your request. Sorry about that!","type":"server_error","param":null,"code":null}}


    """

    /// OpenAI Responses: typed events — created, a message with two text
    /// deltas, a function call whose arguments arrive as deltas and are then
    /// given whole, and response.completed with usage.
    static let openAIResponsesToolCall = """
    event: response.created
    data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"model":"gpt-4.1-2025-04-14","output":[],"usage":null}}

    event: response.in_progress
    data: {"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","created_at":1741290958,"status":"in_progress","model":"gpt-4.1-2025-04-14","output":[],"usage":null}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","type":"message","status":"in_progress","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","sequence_number":3,"item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","sequence_number":4,"item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"delta":"Checking"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","sequence_number":5,"item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"delta":" Paris now."}

    event: response.output_text.done
    data: {"type":"response.output_text.done","sequence_number":6,"item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"text":"Checking Paris now."}

    event: response.output_item.added
    data: {"type":"response.output_item.added","sequence_number":7,"output_index":1,"item":{"type":"function_call","id":"fc_12345xyz","call_id":"call_12345xyz","name":"get_weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","sequence_number":8,"item_id":"fc_12345xyz","output_index":1,"delta":"{\\"location\\":\\"Pa"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","sequence_number":9,"item_id":"fc_12345xyz","output_index":1,"delta":"ris, France\\"}"}

    event: response.function_call_arguments.done
    data: {"type":"response.function_call_arguments.done","sequence_number":10,"item_id":"fc_12345xyz","output_index":1,"arguments":"{\\"location\\":\\"Paris, France\\"}"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","sequence_number":11,"output_index":1,"item":{"type":"function_call","id":"fc_12345xyz","call_id":"call_12345xyz","name":"get_weather","arguments":"{\\"location\\":\\"Paris, France\\"}","status":"completed"}}

    event: response.completed
    data: {"type":"response.completed","sequence_number":12,"response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","created_at":1741290958,"status":"completed","error":null,"incomplete_details":null,"model":"gpt-4.1-2025-04-14","usage":{"input_tokens":37,"input_tokens_details":{"cached_tokens":0},"output_tokens":24,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":61}}}


    """

    /// OpenAI Responses: the documented `error` event.
    static let openAIResponsesError = """
    event: response.created
    data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_err1","object":"response","status":"in_progress","model":"gpt-4.1","output":[]}}

    event: error
    data: {"type":"error","code":"ERR_SOMETHING","message":"Something went wrong","param":null,"sequence_number":1}


    """

    /// NDJSON (Ollama-shaped), for the splitter: not an API the assembler reads.
    static let ndjson = """
    {"model":"llama3.2","created_at":"2026-09-29T10:00:00Z","message":{"role":"assistant","content":"The"},"done":false}
    {"model":"llama3.2","created_at":"2026-09-29T10:00:01Z","message":{"role":"assistant","content":" sky"},"done":false}
    {"model":"llama3.2","created_at":"2026-09-29T10:00:02Z","message":{"role":"assistant","content":""},"done":true,"total_duration":4883583458}

    """
}
