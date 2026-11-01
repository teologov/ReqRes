//
//  RPCExchange.swift
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
//  One captured exchange read as an RPC (protocol PRD Phase 6.1–6.3,
//  decision D12; protocol-engine doc §S8): which protocol, which method, each
//  message decoded, and the RPC's own status — which for gRPC-Web lives in a
//  trailer frame at the END of a body whose HTTP status is 200.
//
//  Protocols: gRPC-Web (binary and text), Connect (unary and streaming), and
//  native gRPC: its status normally arrives in HTTP/2 trailers, which the
//  core records since C13 (`rspTrailers`, read through
//  `RPCExchangeInput.recordedTrailers`); a "trailers-only" answer (status in
//  the head, as most errors are) is read from the head. A row from an older
//  core has no trailers, and then only the head can say.
//

import Foundation

public enum RPCProtocol: String, Codable, Equatable, Sendable, CaseIterable {
    /// `application/grpc` — native gRPC (HTTP/2).
    case grpc
    /// `application/grpc-web`.
    case grpcWeb = "grpc_web"
    /// `application/grpc-web-text` — the same frames, base64.
    case grpcWebText = "grpc_web_text"
    /// Connect unary: a plain `application/proto` / `application/json` body.
    case connectUnary = "connect_unary"
    /// `application/connect+proto|json` — enveloped messages.
    case connectStreaming = "connect_streaming"

    public var displayName: String {
        switch self {
        case .grpc: return "gRPC"
        case .grpcWeb: return "gRPC-Web"
        case .grpcWebText: return "gRPC-Web (text)"
        case .connectUnary: return "Connect"
        case .connectStreaming: return "Connect streaming"
        }
    }

    /// Messages are 5-byte framed (everything but Connect unary).
    public var isFramed: Bool { self != .connectUnary }
}

/// How the messages are serialised.
public enum RPCCodec: String, Codable, Equatable, Sendable {
    case proto
    case json
    /// A codec suffix ReqRes does not read (`+thrift`, …): messages are bytes.
    case other
}

/// What the decoder needs from a row — built by the app from a
/// `SessionCodable` (bodies as BYTES: a binary body's `…BodyData`, a text
/// body's UTF-8) and by tests by hand.
public struct RPCExchangeInput: Equatable, Sendable {
    /// The request target (`/pkg.Service/Method`, query allowed).
    public var path: String
    public var httpStatus: Int?
    public var requestHeaders: [RPCHeaderPair]
    public var responseHeaders: [RPCHeaderPair]
    /// The response's trailers (native gRPC's HTTP/2 trailers, or HTTP/1.1
    /// chunked trailers), when the capture recorded them. Empty from a core
    /// that does not record trailers — then a native gRPC row has a status
    /// only when the server answered trailers-only (status in the head).
    public var responseTrailers: [RPCHeaderPair]
    /// True when the capture that wrote this row records trailers (core C13
    /// and later — the app passes true). It only changes the note a native
    /// gRPC row with no status gets: "not recorded by this version" is a lie
    /// once they are, and the true reason is then that the server sent none.
    public var trailersRecorded: Bool
    /// The request's media type: as given, else its headers' Content-Type.
    public var requestContentType: String? {
        get { requestContentTypeOverride ?? RPCHeaderBlock.value("content-type", in: requestHeaders) }
        set { requestContentTypeOverride = newValue }
    }
    public var responseContentType: String? {
        get { responseContentTypeOverride ?? RPCHeaderBlock.value("content-type", in: responseHeaders) }
        set { responseContentTypeOverride = newValue }
    }
    private var requestContentTypeOverride: String?
    private var responseContentTypeOverride: String?
    public var requestBody: Data?
    public var responseBody: Data?
    /// Bytes of each body as sent that the capture did not keep (D10).
    public var requestNotRetainedBytes: Int64
    public var responseNotRetainedBytes: Int64

    public init(path: String, httpStatus: Int? = nil, requestHeaders: [RPCHeaderPair] = [], responseHeaders: [RPCHeaderPair] = [],
                responseTrailers: [RPCHeaderPair] = [], requestContentType: String? = nil, responseContentType: String? = nil,
                requestBody: Data? = nil, responseBody: Data? = nil,
                requestNotRetainedBytes: Int64 = 0, responseNotRetainedBytes: Int64 = 0, trailersRecorded: Bool = false) {
        self.path = path
        self.trailersRecorded = trailersRecorded
        self.httpStatus = httpStatus
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.responseTrailers = responseTrailers
        self.requestContentTypeOverride = requestContentType
        self.responseContentTypeOverride = responseContentType
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.requestNotRetainedBytes = max(0, requestNotRetainedBytes)
        self.responseNotRetainedBytes = max(0, responseNotRetainedBytes)
    }

    /// A row's recorded trailers (`reqTrailers` / `rspTrailers`: the core's
    /// ordered-pairs JSON, nil when the message had none) as the decoder
    /// reads headers — names lower-cased, wire order and repeats kept. The
    /// app builds `responseTrailers` through this, so the table's RPC word,
    /// the RPC tab and `list_sessions grpc=` all read native gRPC's status
    /// from where the server put it.
    public static func recordedTrailers(from raw: String?) -> [RPCHeaderPair] {
        MCPRecordedHeaders.pairs(from: raw).map { RPCHeaderPair(name: $0.name.lowercased(), value: $0.value) }
    }
}

public enum RPCDirection: String, Codable, Equatable, Sendable {
    case request
    case response
}

public enum RPCMessageContent: Equatable, Sendable {
    /// Decoded, schema-less.
    case protobuf(ProtoMessage)
    /// A JSON-codec message, as text.
    case text(String)
    /// Not decoded; the sentence says why. The bytes are the payload as far
    /// as ReqRes could take it (still compressed when the encoding is not one
    /// it reads).
    case bytes(Data, reason: String)
}

public struct RPCMessage: Equatable, Sendable {
    public var direction: RPCDirection
    /// 1-based within its direction.
    public var number: Int
    /// The payload's size as sent (compressed, when it was).
    public var wireBytes: Int
    public var compressed: Bool
    public var content: RPCMessageContent

    public init(direction: RPCDirection, number: Int, wireBytes: Int, compressed: Bool, content: RPCMessageContent) {
        self.direction = direction
        self.number = number
        self.wireBytes = wireBytes
        self.compressed = compressed
        self.content = content
    }
}

public struct RPCDecodedExchange: Equatable, Sendable {
    public var rpcProtocol: RPCProtocol
    public var codec: RPCCodec
    /// `pkg.Service` and `Method`, from the path's last two segments.
    public var service: String?
    public var method: String?
    public var requestMessages: [RPCMessage]
    public var responseMessages: [RPCMessage]
    /// Messages beyond `RPCExchange.maxMessagesPerSide` that were not decoded.
    public var requestMessagesNotShown: Int
    public var responseMessagesNotShown: Int
    public var status: RPCStatus?
    /// Why there is no status, when there is none.
    public var statusNote: String?
    /// The trailer frame's (or end-of-stream metadata's) other entries.
    public var trailers: [RPCHeaderPair]
    /// What was incomplete or not read — ReqRes's sentences (they may name a
    /// message encoding as sent).
    public var notes: [String]

    public var messageCount: Int { requestMessages.count + responseMessages.count }
}

public enum RPCExchange {
    /// Messages decoded per direction; a long stream says how many more.
    public static let maxMessagesPerSide = 1_000

    /// The protocol and codec a row speaks, or nil for anything else. The
    /// request's type decides (a Connect unary error answers
    /// `application/json` whatever the codec); the response's is the
    /// fallback for a row whose request head carried none.
    public static func detect(_ input: RPCExchangeInput) -> (RPCProtocol, RPCCodec)? {
        let connectHeader = RPCHeaderBlock.value("connect-protocol-version", in: input.requestHeaders) != nil
        if let found = detect(contentType: input.requestContentType, connectHeader: connectHeader) { return found }
        return detect(contentType: input.responseContentType, connectHeader: false, responseSide: true)
    }

    /// Cheap: media types only. `connectHeader` = the request carried
    /// `Connect-Protocol-Version` — what tells a Connect unary call from any
    /// other JSON or protobuf POST. It is required for `application/proto`
    /// too: without it an ordinary protobuf API answering 503 would be shown
    /// as `UNAVAILABLE` and match `grpc:error`. Every Connect client sends it.
    public static func detect(contentType: String?, connectHeader: Bool, responseSide: Bool = false) -> (RPCProtocol, RPCCodec)? {
        guard let contentType else { return nil }
        let media = contentType.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        func codec(after prefix: String) -> RPCCodec? {
            guard media.hasPrefix(prefix) else { return nil }
            let rest = media.dropFirst(prefix.count)
            if rest.isEmpty || rest == "+proto" { return .proto }
            if rest == "+json" { return .json }
            return rest.hasPrefix("+") ? .other : nil
        }
        // Longest prefixes first: grpc-web-text before grpc-web before grpc.
        if let c = codec(after: "application/grpc-web-text") { return (.grpcWebText, c) }
        if let c = codec(after: "application/grpc-web") { return (.grpcWeb, c) }
        if let c = codec(after: "application/grpc") { return (.grpc, c) }
        if let c = codec(after: "application/connect") { return (.connectStreaming, c) }
        if !responseSide {
            if media == "application/proto", connectHeader { return (.connectUnary, .proto) }
            if media == "application/json", connectHeader { return (.connectUnary, .json) }
        }
        return nil
    }

    /// `("pkg.Service", "Method")` from `/pkg.Service/Method` — the last two
    /// path segments, so a gateway prefix (`/api/pkg.Service/Method`) still
    /// reads.
    public static func serviceAndMethod(path: String) -> (String, String)? {
        let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let parts = pathOnly.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[parts.count - 2], parts[parts.count - 1])
    }

    /// The row's RPC status without decoding a single message — what the
    /// table, the `grpc:` token and `list_sessions grpc=` need. Nil for a
    /// row that is not an RPC.
    public static func status(of input: RPCExchangeInput) -> RPCStatus? {
        decode(input, decodingMessages: false)?.status
    }

    /// The whole reading, or nil for a row that is not an RPC.
    public static func decode(_ input: RPCExchangeInput, decodingMessages: Bool = true) -> RPCDecodedExchange? {
        guard let (proto, codec) = detect(input) else { return nil }
        let names = serviceAndMethod(path: input.path)
        var result = RPCDecodedExchange(
            rpcProtocol: proto, codec: codec, service: names?.0, method: names?.1,
            requestMessages: [], responseMessages: [], requestMessagesNotShown: 0, responseMessagesNotShown: 0,
            status: nil, statusNote: nil, trailers: [], notes: []
        )

        if proto.isFramed {
            decodeFramed(input, proto: proto, codec: codec, decodingMessages: decodingMessages, into: &result)
        } else {
            decodeConnectUnary(input, codec: codec, decodingMessages: decodingMessages, into: &result)
        }

        for (side, missing) in [("request", input.requestNotRetainedBytes), ("response", input.responseNotRetainedBytes)] where missing > 0 {
            result.notes.append("ReqRes kept only part of the \(side) body (\(missing) bytes as sent are not in the app); later messages are missing.")
        }
        return result
    }

    // MARK: - Framed protocols

    private static func frames(of body: Data?, text: Bool, side: String, notes: inout [String]) -> [RPCFrame] {
        guard let body, !body.isEmpty else { return [] }
        var bytes = body
        if text {
            let decoded = GRPCWebTextDecoder.decode(body)
            bytes = decoded.bytes
            if !decoded.isValid {
                notes.append("The \(side) body is not valid base64 past byte \(decoded.bytes.count) of its decoding; the messages before that point are shown.")
            } else if decoded.pendingCharacters > 0 {
                notes.append("The \(side) body ends in \(decoded.pendingCharacters) base64 characters that are not a whole group.")
            }
        }
        let split = RPCFrameReader.frames(in: bytes)
        if split.pendingBytes > 0 {
            if let declared = split.pendingDeclaredLength {
                notes.append("The \(side) body ends inside a message: \(split.pendingBytes - RPCFrameReader.headerLength) of its \(declared) bytes arrived (withheld, not decoded).")
            } else {
                notes.append("The \(side) body ends in \(split.pendingBytes) bytes that are not a whole message header.")
            }
        }
        return split.frames
    }

    private static func decodeFramed(_ input: RPCExchangeInput, proto: RPCProtocol, codec: RPCCodec, decodingMessages: Bool, into result: inout RPCDecodedExchange) {
        let text = proto == .grpcWebText
        let encodingHeader = proto == .connectStreaming ? "connect-content-encoding" : "grpc-encoding"
        let requestEncoding = RPCHeaderBlock.value(encodingHeader, in: input.requestHeaders)
        let responseEncoding = RPCHeaderBlock.value(encodingHeader, in: input.responseHeaders)

        // The request is framed only when its messages are asked for: the
        // status — all the table and the `grpc:` chip need — is in the
        // response, and framing a large grpc-web-text request for it cost
        // the main thread the whole decode (release review, 2026-09-29).
        // Its notes still come first, as they always have.
        let requestNotesAt = result.notes.count
        let responseFrames = frames(of: input.responseBody, text: text, side: "response", notes: &result.notes)

        // The status first: it is all the table needs.
        var trailerFrame: RPCFrame?
        var endStream: RPCFrame?
        var dataFrames: [RPCFrame] = []
        for frame in responseFrames {
            if proto == .grpcWeb || proto == .grpcWebText, frame.isGRPCWebTrailer {
                if trailerFrame == nil { trailerFrame = frame }
            } else if proto == .connectStreaming, frame.isConnectEndStream {
                if endStream == nil { endStream = frame }
            } else {
                dataFrames.append(frame)
            }
        }

        if let trailerFrame {
            var payload = trailerFrame.payload
            if trailerFrame.isCompressed, case .decoded(let inflated) = RPCMessageCompression.decompress(payload, encoding: responseEncoding) {
                payload = inflated
            }
            let pairs = RPCHeaderBlock.parse(payload)
            result.trailers = pairs.filter { $0.name != "grpc-status" && $0.name != "grpc-message" }
            if let raw = RPCHeaderBlock.value("grpc-status", in: pairs), let code = Int(raw.trimmingCharacters(in: .whitespaces)), code >= 0 {
                result.status = RPCStatus(code: code, message: RPCHeaderBlock.value("grpc-message", in: pairs).map(RPCHeaderBlock.percentDecoded),
                                          source: .trailerFrame)
            }
        } else if let endStream {
            var payload = endStream.payload
            if endStream.isCompressed, case .decoded(let inflated) = RPCMessageCompression.decompress(payload, encoding: responseEncoding) {
                payload = inflated
            }
            let parsed = connectEndStream(payload)
            result.status = parsed.status
            result.trailers = parsed.metadata
            if parsed.status == nil {
                result.statusNote = "The end-of-stream message is not the JSON Connect defines."
            }
        }
        if result.status == nil, let raw = RPCHeaderBlock.value("grpc-status", in: input.responseTrailers),
           let code = Int(raw.trimmingCharacters(in: .whitespaces)), code >= 0 {
            result.status = RPCStatus(code: code, message: RPCHeaderBlock.value("grpc-message", in: input.responseTrailers).map(RPCHeaderBlock.percentDecoded),
                                      source: .trailers)
            result.trailers = input.responseTrailers.filter { $0.name != "grpc-status" && $0.name != "grpc-message" }
        }
        if result.status == nil, let raw = RPCHeaderBlock.value("grpc-status", in: input.responseHeaders),
           let code = Int(raw.trimmingCharacters(in: .whitespaces)), code >= 0 {
            result.status = RPCStatus(code: code, message: RPCHeaderBlock.value("grpc-message", in: input.responseHeaders).map(RPCHeaderBlock.percentDecoded),
                                      source: .responseHead)
        }
        if result.status == nil, let http = input.httpStatus, let code = RPCStatusCode.inferred(fromHTTPStatus: http) {
            result.status = RPCStatus(code: code, message: nil, source: .httpStatus)
        }
        if result.status == nil, result.statusNote == nil {
            switch proto {
            case .grpc:
                result.statusNote = input.trailersRecorded
                    ? (input.httpStatus == nil
                        ? "No response yet."
                        : "The response ended without trailers and its head carries no grpc-status — the stream was cut before the server finished.")
                    : "Native gRPC sends its status in HTTP/2 trailers, which the capture that recorded this row did not keep; a status shows only when the server put it in the response head (a trailers-only response)."
            case .connectStreaming:
                result.statusNote = input.httpStatus == nil
                    ? "No response yet."
                    : "The stream ended without its end-of-stream message."
            default:
                result.statusNote = input.httpStatus == nil
                    ? "No response yet."
                    : "The response ended without a trailer frame and its head carries no grpc-status."
            }
        }

        guard decodingMessages else { return }
        var requestNotes: [String] = []
        let requestFrames = frames(of: input.requestBody, text: text, side: "request", notes: &requestNotes)
        result.notes.insert(contentsOf: requestNotes, at: requestNotesAt)
        let (requests, requestsNotShown) = messages(requestFrames, direction: .request, codec: codec, encoding: requestEncoding, encodingHeader: encodingHeader)
        let (responses, responsesNotShown) = messages(dataFrames, direction: .response, codec: codec, encoding: responseEncoding, encodingHeader: encodingHeader)
        result.requestMessages = requests
        result.responseMessages = responses
        result.requestMessagesNotShown = requestsNotShown
        result.responseMessagesNotShown = responsesNotShown
    }

    private static func messages(_ frames: [RPCFrame], direction: RPCDirection, codec: RPCCodec, encoding: String?, encodingHeader: String) -> ([RPCMessage], Int) {
        var out: [RPCMessage] = []
        for (index, frame) in frames.prefix(maxMessagesPerSide).enumerated() {
            var payload = frame.payload
            var failure: String?
            if frame.isCompressed {
                switch RPCMessageCompression.decompress(payload, encoding: encoding) {
                case .decoded(let inflated): payload = inflated
                case .unsupported(let name): failure = "Compressed with \(name), which ReqRes does not decode; shown as sent."
                case .unnamed: failure = "Marked compressed, but the \(direction.rawValue) names no \(encodingHeader); shown as sent."
                case .failed(let name): failure = "Marked compressed with \(name), but it does not inflate; shown as sent."
                case .tooLarge(let name): failure = "Compressed with \(name) and would inflate past \(RPCMessageCompression.maxDecodedBytes / (1024 * 1024)) MB; shown as sent."
                }
            }
            let content: RPCMessageContent = failure.map { .bytes(payload, reason: $0) } ?? content(of: payload, codec: codec)
            out.append(RPCMessage(direction: direction, number: index + 1, wireBytes: frame.payload.count, compressed: frame.isCompressed, content: content))
        }
        return (out, max(0, frames.count - maxMessagesPerSide))
    }

    static func content(of payload: Data, codec: RPCCodec) -> RPCMessageContent {
        switch codec {
        case .proto:
            if let message = ProtobufDecoder.decode(payload) { return .protobuf(message) }
            return .bytes(payload, reason: "Not a protobuf message (it does not parse as one); shown as bytes.")
        case .json:
            return .text(String(decoding: payload, as: UTF8.self))
        case .other:
            return .bytes(payload, reason: "A codec ReqRes does not read; shown as bytes.")
        }
    }

    // MARK: - Connect

    /// `{"error": {"code": "not_found", "message": "…"}, "metadata": {"k": ["v"]}}`
    /// → the status (OK when there is no error) and the metadata as pairs.
    static func connectEndStream(_ payload: Data) -> (status: RPCStatus?, metadata: [RPCHeaderPair]) {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return (nil, []) }
        var metadata: [RPCHeaderPair] = []
        if let raw = object["metadata"] as? [String: Any] {
            for (name, value) in raw.sorted(by: { $0.key < $1.key }) {
                let values = (value as? [Any])?.compactMap { $0 as? String } ?? [(value as? String) ?? ""]
                for v in values { metadata.append(RPCHeaderPair(name: name.lowercased(), value: v)) }
            }
        }
        guard let error = object["error"] as? [String: Any] else {
            return (RPCStatus(code: 0, source: .endStream), metadata)
        }
        let code = (error["code"] as? String).flatMap(RPCStatusCode.code(named:)) ?? 2
        return (RPCStatus(code: code, message: error["message"] as? String, source: .endStream), metadata)
    }

    private static func decodeConnectUnary(_ input: RPCExchangeInput, codec: RPCCodec, decodingMessages: Bool, into result: inout RPCDecodedExchange) {
        if let http = input.httpStatus {
            if http == 200 {
                result.status = RPCStatus(code: 0, source: .connectUnary)
            } else if let body = input.responseBody,
                      let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      let name = object["code"] as? String, let code = RPCStatusCode.code(named: name) {
                result.status = RPCStatus(code: code, message: object["message"] as? String, source: .connectUnary)
            } else if let code = RPCStatusCode.inferred(fromHTTPStatus: http) {
                result.status = RPCStatus(code: code, source: .httpStatus)
            }
        } else {
            result.statusNote = "No response yet."
        }

        guard decodingMessages else { return }
        if let body = input.requestBody, !body.isEmpty {
            result.requestMessages = [RPCMessage(direction: .request, number: 1, wireBytes: body.count, compressed: false,
                                                 content: content(of: body, codec: codec))]
        } else if input.path.contains("connect=v1") {
            result.notes.append("A Connect GET carries its message in the query string; ReqRes does not decode it there.")
        }
        // An error's body is the error, not a message.
        if input.httpStatus == 200, let body = input.responseBody, !body.isEmpty {
            let responseCodec = detect(contentType: input.responseContentType, connectHeader: true)?.1 ?? codec
            result.responseMessages = [RPCMessage(direction: .response, number: 1, wireBytes: body.count, compressed: false,
                                                  content: content(of: body, codec: responseCodec))]
        }
    }
}
