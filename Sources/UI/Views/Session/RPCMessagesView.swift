//
//  RPCMessagesView.swift
//  ReqRes
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
//  gRPC-Web, Connect and native gRPC rows (protocol-engine doc §S8): the
//  row's RPC status beside its HTTP status in the table, and the RPC tab —
//  every message's field tree and the call's status. Every word comes from
//  `RPCPresentation` (MCPKit); the decoding is `RPCExchange` (MCPKit,
//  Foundation-only — the app links no NIO).
//

import MCPKit
import SwiftUI
import XReqResCore

// MARK: - A row as an RPC

extension SessionCodable {
    /// The row's bytes and headers as the RPC decoder reads them: a binary
    /// body's bytes (`…BodyData`), a text body's UTF-8 (grpc-web-text and
    /// Connect JSON are text).
    var rpcInput: RPCExchangeInput {
        let requestHeaders = MCPRecordedHeaders.pairs(from: reqHeaders).map { RPCHeaderPair(name: $0.name.lowercased(), value: $0.value) }
        let responseHeaders = MCPRecordedHeaders.pairs(from: rspHeaders).map { RPCHeaderPair(name: $0.name.lowercased(), value: $0.value) }
        let hasRequestType = requestHeaders.contains { $0.name == "content-type" }
        let hasResponseType = responseHeaders.contains { $0.name == "content-type" }
        let requestBody: Data? = reqBodyIsBinary ? reqBodyData : (reqBody.isEmpty ? nil : Data(reqBody.utf8))
        let responseBody: Data? = rspBodyIsBinary ? rspBodyData : (rspBody.isEmpty ? rspBodyData : Data(rspBody.utf8))
        return RPCExchangeInput(
            path: uri,
            httpStatus: rspStatus.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            // Native gRPC's status lives here (core C13 records it); the
            // decoder falls back to the head for a trailers-only answer.
            responseTrailers: RPCExchangeInput.recordedTrailers(from: rspTrailers),
            requestContentType: hasRequestType || reqContentType.isEmpty ? nil : reqContentType,
            responseContentType: hasResponseType || rspContentType.isEmpty ? nil : rspContentType,
            requestBody: requestBody,
            responseBody: responseBody,
            requestNotRetainedBytes: reqBodyTruncatedBytes,
            responseNotRetainedBytes: rspBodyTruncatedBytes,
            // The embedded core records trailers (C13).
            trailersRecorded: true
        )
    }

    /// A first look — media types and one header name — so the rows that
    /// are not RPCs never build an input. One ASCII pass (`RPCCandidate`),
    /// and asked only on a cache miss: its answer is cached, "no" included.
    var mightBeRPC: Bool {
        guard !relayed else { return false }
        return RPCCandidate.mightBeRPC(requestType: reqContentType, responseType: rspContentType, requestHeads: reqHeaders)
    }

    /// The RPC tab is offered for a finished row that reads as an RPC.
    var isRPC: Bool { RPCStatusCache.shared.facts(for: self) != nil }

    /// The row's RPC status (nil: not an RPC, or none recorded).
    var rpcStatus: RPCStatus? { RPCStatusCache.shared.facts(for: self)?.status }
}

/// A row's protocol and status, remembered per row content: the table draws
/// it per visible row, the `grpc:` chip asks it of every row per flush, and
/// the agent list asks it of every row per call. The status needs no message
/// decoding (framing only — `RPCExchange.status`), and the answer is cached
/// by id + `detailRevision`, so a live row that grows is read again.
final class RPCStatusCache: @unchecked Sendable {
    static let shared = RPCStatusCache()

    struct Facts: Equatable {
        var rpcProtocol: RPCProtocol
        var status: RPCStatus?
    }

    /// Past 20,000 rows the cache starts over (the table keeps 5,000). The
    /// cache is looked in FIRST and remembers "not an RPC" too: the pre-check
    /// used to run before it on every call, and a non-RPC row — nearly every
    /// row — was never cached, so the agent list and the `grpc:` chip paid a
    /// header scan per row per call (release review, 2026-09-29).
    private let cache = RevisionedCache<Facts>()

    func facts(for session: SessionCodable) -> Facts? {
        cache.value(id: session.id, revision: session.detailRevision) {
            guard session.mightBeRPC else { return nil }
            return RPCExchange.decode(session.rpcInput, decodingMessages: false)
                .map { Facts(rpcProtocol: $0.rpcProtocol, status: $0.status) }
        }
    }
}

// MARK: - The table

/// "NOT_FOUND" with its symbol, before the URL — first, so a long URL
/// truncates before the word does (the failure word's rule). Nil when the RPC
/// status says what the HTTP status already says.
enum RPCStatusWord {
    static func text(_ facts: RPCStatusCache.Facts, httpStatus: Int?, isSelected: Bool) -> Text? {
        guard let status = facts.status, let word = RPCPresentation.tableWord(status: status, httpStatus: httpStatus) else { return nil }
        let color: Color = isSelected ? .white : (status.isOK ? .secondary : .orange)
        return (Text(Image(systemName: RPCPresentation.symbolName(status))) + Text(verbatim: " \(word)"))
            .fontWeight(.semibold)
            .foregroundColor(color)
            + Text(verbatim: "  ")
    }

    /// Tooltip / VoiceOver: "HTTP 200, gRPC status NOT_FOUND — user 42 not found".
    static func label(_ facts: RPCStatusCache.Facts, httpStatus: Int?) -> String? {
        guard let status = facts.status, RPCPresentation.tableWord(status: status, httpStatus: httpStatus) != nil else { return nil }
        var label = RPCPresentation.accessibilityLabel(protocol: facts.rpcProtocol, httpStatus: httpStatus, status: status)
        if let message = status.message, !message.isEmpty { label += " — \(message)" }
        return label
    }
}

// MARK: - The RPC tab

/// One row's decoded RPC, built off the main thread (a body can be 16 MB).
@MainActor
final class RPCMessagesModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String
        var message: RPCMessage
        var title: String
        var accessibilityLabel: String
        var lines: [RPCPresentation.Line]
    }

    struct Snapshot: Equatable {
        var header: String
        var status: String
        var statusSymbol: String
        var statusIsError: Bool
        var counts: String
        var notes: [String]
        var trailers: String?
        var items: [Item]
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var notAnRPC = false

    func load(_ session: SessionCodable) async {
        let input = session.rpcInput
        let built: Snapshot? = await Task.detached(priority: .userInitiated) {
            guard let rpc = RPCExchange.decode(input) else { return nil }
            let items = (rpc.requestMessages + rpc.responseMessages).map { message in
                Item(id: "\(message.direction.rawValue)-\(message.number)", message: message,
                     title: RPCPresentation.messageTitle(message),
                     accessibilityLabel: RPCPresentation.accessibilityLabel(message),
                     lines: RPCPresentation.lines(message))
            }
            return Snapshot(
                header: RPCPresentation.headerLine(rpc),
                status: RPCPresentation.statusLine(rpc),
                statusSymbol: rpc.status.map(RPCPresentation.symbolName) ?? "questionmark.circle",
                statusIsError: rpc.status.map { !$0.isOK } ?? false,
                counts: RPCPresentation.countsLine(rpc),
                notes: rpc.notes,
                trailers: rpc.trailers.isEmpty ? nil : "Trailers: " + rpc.trailers.map { "\($0.name): \($0.value)" }.joined(separator: " · "),
                items: items
            )
        }.value
        snapshot = built
        notAnRPC = built == nil
    }
}

struct RPCMessagesView: View {
    let session: SessionCodable
    @StateObject private var model = RPCMessagesModel()

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                content(snapshot)
            } else if model.notAnRPC {
                PlaceholderView(imageName: "exclamationmark.circle", title: "Not an RPC")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: session.detailRevision) { await model.load(session) }
    }

    private func content(_ snapshot: RPCMessagesModel.Snapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: snapshot.header)
                        .font(.system(size: 12, weight: .semibold))
                        .textSelection(.enabled)
                    Label {
                        Text(verbatim: snapshot.status).textSelection(.enabled)
                    } icon: {
                        Image(systemName: snapshot.statusSymbol)
                            .foregroundStyle(snapshot.statusIsError ? Color.orange : Color.secondary)
                    }
                    .font(.system(size: 11))
                    .accessibilityElement(children: .combine)
                    Text(verbatim: snapshot.counts)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let trailers = snapshot.trailers {
                        Text(verbatim: trailers)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(snapshot.notes.enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "scissors")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(snapshot.items) { item in
                    RPCMessageBlock(item: item)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One message: its direction (symbol AND word), size, then its field tree
/// in monospace. `Equatable` so the tab does not rebuild every block when
/// one changes.
private struct RPCMessageBlock: View, Equatable {
    let item: RPCMessagesModel.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(verbatim: item.title).font(.system(size: 11, weight: .semibold))
            } icon: {
                Image(systemName: RPCPresentation.directionSymbol(item.message.direction))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityLabel)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(item.lines) { line in
                    (Text(verbatim: line.text)
                        + (line.secondary.map { Text(verbatim: "   \($0)").foregroundColor(.secondary) } ?? Text(verbatim: "")))
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.leading, CGFloat(line.depth) * 14)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
    }
}
