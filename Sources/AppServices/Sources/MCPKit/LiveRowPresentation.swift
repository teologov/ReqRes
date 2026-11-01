//
//  LiveRowPresentation.swift
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
//  Every word a live row is shown with — the traffic table, the detail pane,
//  VoiceOver and the agent's tool text — in one place, so the human and the
//  agent read the same phase the same way (protocol-engine doc §S6).
//

import Foundation

public enum LiveRowCopy {
    /// The phase in one word, what the table's row leads with.
    public static func word(_ phase: MCPLivePhase) -> String {
        switch phase {
        case .waiting: return "Waiting"
        case .streaming: return "Streaming"
        case .ended: return "Ended"
        }
    }

    /// The SF Symbol drawn beside the word (never colour alone).
    public static func symbol(_ phase: MCPLivePhase) -> String {
        switch phase {
        case .waiting: return "hourglass"
        case .streaming: return "arrow.down.circle"
        case .ended: return "questionmark.circle"
        }
    }

    /// Seconds as the table shows them: whole seconds under a minute, then
    /// minutes and seconds. Updated at most once a second by the view.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        if whole < 60 { return "\(whole) s" }
        let minutes = whole / 60
        let rest = whole % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    /// "Streaming · 34.1 KB" — the word and what it is waiting on or has
    /// received, as the URL cell's lead-in.
    public static func tableLead(phase: MCPLivePhase, responseBytes: Int64) -> String {
        switch phase {
        case .waiting, .ended: return word(phase)
        case .streaming: return "\(word(.streaming)) \(RecordedExchangeCopy.binaryBytes(responseBytes))"
        }
    }

    /// The row's accessibility value — phase-level only, so it changes when
    /// the phase does and not with every byte or second.
    public static func accessibilityValue(phase: MCPLivePhase, endReason: LiveEndReason? = nil) -> String {
        switch phase {
        case .waiting: return "In flight, waiting for the response"
        case .streaming: return "In flight, the response is streaming"
        case .ended: return "Ended without its final row" + (endReason.map { ", \(reasonPhrase($0))" } ?? "")
        }
    }

    public static func reasonPhrase(_ reason: LiveEndReason) -> String {
        switch reason {
        case .captureStopped: return "capture stopped while it was open"
        case .stale: return "ReqRes stopped hearing about it"
        }
    }

    /// The tooltip of an ended row: what happened and what is missing.
    public static func endedExplanation(_ reason: LiveEndReason) -> String {
        switch reason {
        case .captureStopped:
            return "Capture stopped while this request was still open, so its end was never recorded. What is shown is the last thing ReqRes heard; the response body is not here."
        case .stale:
            return "ReqRes heard nothing about this request for over \(Int(LiveRowLedger<NeverRow>.staleAfter / 60)) minutes — longer than the extension keeps a silent request open — so its end was lost on the way. What is shown is the last thing ReqRes heard; the response body is not here."
        }
    }

    /// The detail pane's line over an in-flight response.
    public static func detailLine(state: LiveRowState, textHeld: Bool) -> String {
        switch state.phase {
        case .waiting:
            return state.requestComplete
                ? "Waiting for the response — the request was sent (\(RecordedExchangeCopy.binaryBytes(state.requestBytes)))."
                : "Waiting — the request is still being sent (\(RecordedExchangeCopy.binaryBytes(state.requestBytes)) so far)."
        case .streaming:
            var line = "Streaming — \(RecordedExchangeCopy.binaryBytes(state.responseBytes)) received so far"
            if let format = state.streamFormat {
                line += ", \(StreamEventsPresentation.count(state.completeMessages, format == .sse ? "complete event" : "complete line"))"
            }
            return line + ". " + textStatusSentence(state, textHeld: textHeld)
        }
    }

    /// What the live text is (or why there is none), in one sentence.
    public static func textStatusSentence(_ state: LiveRowState, textHeld: Bool) -> String {
        if state.textIncomplete {
            return "A live update was missed, so the text stops here; the whole body arrives with the final row."
        }
        switch state.textStatus {
        case .text, .awaitingResponse:
            return textHeld ? "The text grows as it arrives; the final row replaces it." : "No text yet."
        case .noBody: return "This response has no body."
        case .notText: return "The body is not text; the byte count grows and the body arrives with the final row."
        case .undecodedEncoding:
            return "The body's encoding (\(state.undecodedEncoding ?? "unknown")) is not decoded live; it arrives with the final row."
        case .unsupportedCharset: return "The body's character set is not read live; it arrives with the final row."
        case .decodeFailed: return "The body could not be decoded live; it arrives with the final row."
        case .replacedByRule: return "An override rule supplies this body; it arrives with the final row."
        case .stoppedAtRetentionCap:
            return "The live text stopped at the \(RecordedExchangeCopy.binaryBytes(CaptureEngineFacts.retainedBytesPerExchange)) ReqRes keeps per exchange; every byte is still forwarded."
        case .stoppedFellBehind:
            return "The live text fell too far behind and stopped; the final row carries the body."
        }
    }

    // MARK: Agents

    /// The `list_sessions` / `wait_for_session` row token.
    public static func agentToken(_ live: MCPLiveState) -> String {
        var parts: [String]
        switch live.phase {
        case .waiting:
            parts = ["IN_FLIGHT waiting"]
            if let elapsed = live.elapsedSeconds { parts.append("\(Int(elapsed.rounded(.down)))s") }
        case .streaming:
            parts = ["IN_FLIGHT streaming", "\(live.responseBytes)B"]
            if let messages = live.completeMessages { parts.append("\(messages) complete") }
            if let pending = live.pendingBytes, pending > 0 { parts.append("\(pending)B pending") }
        case .ended:
            parts = ["ENDED_WITHOUT_FINAL_ROW"]
            if let reason = live.endReason { parts.append(reason == .captureStopped ? "capture_stopped" : "lost") }
        }
        return parts.joined(separator: " ")
    }

    /// `get_session`'s line for a live row: the phase and what to do next.
    public static func agentDetailLine(_ live: MCPLiveState) -> String {
        switch live.phase {
        case .waiting:
            var line = "In flight: waiting for the response head"
            if let elapsed = live.elapsedSeconds { line += " (\(Int(elapsed.rounded(.down)))s so far)" }
            line += live.requestComplete ? "; the request was sent." : "; the request is still being sent (\(live.requestBytes) bytes so far)."
            return line + " Neither body is shown until it finishes. Call wait_for_session with until=headers or until=complete, or get_session again later."
        case .streaming:
            var line = "In flight: streaming — \(live.responseBytes) bytes received so far"
            if let messages = live.completeMessages {
                line += ", \(messages) complete \(messages == 1 ? "message" : "messages")"
                if let pending = live.pendingBytes, pending > 0 { line += " (\(pending) bytes of an unfinished one withheld)" }
                line += ". view=events shows the complete ones so far"
            }
            return line + ". The request and response bodies are shown when the request finishes."
        case .ended:
            let reason = live.endReason.map { " (\(reasonPhrase($0)))" } ?? ""
            return "Ended without its final row\(reason): these are the last facts ReqRes heard; the response body was never recorded, and the request body may be incomplete, so neither is shown."
        }
    }

    /// The line `export_sessions` adds when it left in-flight rows out.
    public static func exportSkippedLine(_ count: Int) -> String {
        "Skipped \(count) \(count == 1 ? "session that is" : "sessions that are") still in flight: a HAR entry needs a finished response. Export again once they finish."
    }
}

/// A row type for `LiveRowLedger`'s static members where no row is involved.
public struct NeverRow: LiveTableRow {
    public var id = UUID()
    public var exchangeID: UUID? { nil }
}
