//
//  WebSocketMessagesProbe.swift
//  ReqRes
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
//  DEBUG render probe for the Messages tab (protocol-engine doc §S7):
//  `REQRES_UI_PROBE=websocket-messages` (with `REQRES_TOOLBAR_APPEARANCE=
//  light|dark`) seeds a chat socket through the REAL bus delegate — the 101
//  row as `send_session`, then three `websocket_messages` batches encoded as
//  the extension encodes them (the core's own types) — so what renders went
//  through the decoder, the message center and its 150 ms notification.
//  `websocket-messages-binary` selects the binary frame instead of the JSON
//  message; `websocket-messages-search` types a search.
//

#if DEBUG
import AppKit
import MCPKit
import SwiftUI
import XReqResCore

struct WebSocketMessagesProbe: View {
    let target: String
    @ObservedObject private var state = SessionState.shared

    static let exchange = UUID()

    static func seed() {
        let now = Date().timeIntervalSince1970 - 30
        var row = SESSION_MOCK
        row.id = UUID()
        row.exchangeID = exchange
        row.host = "chat.example.com"
        row.uri = "/v1/realtime?model=voice-1"
        row.scheme = "https"
        row.method = "GET"
        row.rspStatus = "101"
        row.rspReasonPhrase = "Switching Protocols"
        row.rspContentType = ""
        row.rspBody = ""
        row.reqBody = ""
        row.rspHeaders = """
        {"Upgrade": "websocket", "Connection": "Upgrade", "Sec-WebSocket-Accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "Sec-WebSocket-Extensions": "permessage-deflate"}
        """
        row.startTime = NSNumber(value: now)
        row.reqStartTime = NSNumber(value: now)
        row.rspStartTime = NSNumber(value: now + 0.12)
        row.rspEndTime = NSNumber(value: now + 0.12)
        LiveProbeMessages.deliver(.sendSession, row)

        let up = now + 0.12
        func text(_ seq: Int64, _ at: Double, _ body: String, sent: Bool = false, compressed: Bool = false) -> WebSocketMessage {
            WebSocketMessage(seq: seq, direction: sent ? .clientToServer : .serverToClient, opcode: .text, time: up + at,
                             size: Int64(body.utf8.count), wireSize: compressed ? Int64(body.utf8.count / 3) : Int64(body.utf8.count),
                             compressed: compressed, frames: 1, preview: body, previewEncoding: .text, truncated: false)
        }
        let audio = Data((0..<320).map { UInt8(($0 * 37) & 0xff) })
        let first = WebSocketMessageBatch(
            exchangeID: exchange, batch: 1,
            messages: [
                text(0, 0.004, #"{"type":"session.update","session":{"voice":"alloy","modalities":["text","audio"],"instructions":"Be brief."}}"#, sent: true),
                text(1, 0.051, #"{"type":"session.created","session":{"id":"sess_8Hq2","model":"voice-1","expires_at":1790003600}}"#, compressed: true),
                WebSocketMessage(seq: 2, direction: .clientToServer, opcode: .binary, time: up + 0.212, size: Int64(audio.count),
                                 wireSize: Int64(audio.count), compressed: false, frames: 2, preview: audio.base64EncodedString(),
                                 previewEncoding: .base64, truncated: false),
                text(3, 0.640, #"{"type":"transcript.delta","delta":"Hel"}"#),
                text(4, 0.702, #"{"type":"transcript.delta","delta":"lo there"}"#),
                WebSocketMessage(seq: 5, direction: .serverToClient, opcode: .ping, time: up + 1.0, size: 0, wireSize: 0, compressed: false,
                                 frames: 1, preview: "", previewEncoding: .text, truncated: false),
                WebSocketMessage(seq: 6, direction: .clientToServer, opcode: .pong, time: up + 1.001, size: 0, wireSize: 0, compressed: false,
                                 frames: 1, preview: "", previewEncoding: .text, truncated: false),
            ],
            evictedMessages: 0, gaveUp: [], extensions: "permessage-deflate", final: false, close: nil, sentAt: up + 1.1)
        LiveProbeMessages.deliver(.websocketMessages, first)
        // The extension fell behind for a moment: three messages dropped there.
        let second = WebSocketMessageBatch(
            exchangeID: exchange, batch: 2,
            messages: [
                text(10, 2.420, #"{"type":"transcript.final","text":"Hello there, how can I help?","confidence":0.97}"#, compressed: true),
                text(11, 2.980, "typing…", sent: true),
            ],
            evictedMessages: 3, gaveUp: [], extensions: nil, final: false, close: nil, sentAt: up + 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            LiveProbeMessages.deliver(.websocketMessages, second)
        }
        let last = WebSocketMessageBatch(
            exchangeID: exchange, batch: 3,
            messages: [
                WebSocketMessage(seq: 12, direction: .clientToServer, opcode: .close, time: up + 4.2, size: 9, wireSize: 9, compressed: false,
                                 frames: 1, preview: "bye now", previewEncoding: .text, truncated: false, closeCode: 1000, closeReason: "bye now"),
                WebSocketMessage(seq: 13, direction: .serverToClient, opcode: .close, time: up + 4.25, size: 2, wireSize: 2, compressed: false,
                                 frames: 1, preview: "", previewEncoding: .text, truncated: false, closeCode: 1000, closeReason: nil),
            ],
            evictedMessages: 0, gaveUp: [], extensions: "permessage-deflate", final: true,
            close: WebSocketCloseSummary(end: .closeHandshake, code: 1000, reason: "bye now", initiatedBy: .clientToServer,
                                         totalMessages: 14, bytesFromClient: 1_214, bytesFromServer: 986),
            sentAt: up + 4.3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            LiveProbeMessages.deliver(.websocketMessages, last)
        }
    }

    var body: some View {
        Group {
            if let session = state.sessions.first(where: { $0.exchangeID == Self.exchange }) {
                VStack(alignment: .leading, spacing: 0) {
                    SessionDetailHeaderView(session: session, attribution: .available, onClose: {})
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            RequestToolbar(title: .Request, selection: .constant(.headers))
                            Divider()
                            SessionRequestTabView(session: session, selectedTabRequest: .constant(.headers))
                        }
                        .frame(width: 330)
                        Divider()
                        VStack(alignment: .leading, spacing: 0) {
                            ResponseToolbar(title: .Response, selection: .constant(.messages),
                                            items: NetworkInspectorTabResponse.tabs(for: session))
                            Divider()
                            WebSocketMessagesView(
                                session: session,
                                initialSelection: target.hasSuffix("binary") ? "m2" : "m1",
                                initialQuery: target.hasSuffix("search") ? "transcript" : ""
                            )
                        }
                    }
                }
            } else {
                Text("seeding…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
