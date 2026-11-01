//
//  HeldRequestHeaders.swift
//  AppServices
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
//  A held request's headers as the Paused Requests panel reads them: ONE
//  reading, for the Headers tab that edits them and for the Body tab that says
//  what they declare about the body.
//
//  It lived in `BreakpointRequestDraft` (Sources/UI, no test target), and the
//  Body tab's size depended on the draft handing its headers over: with none
//  handed over, the panel printed "Body (not shown)" beside the request's own
//  `Content-Length: 76`, and a claim that the headers could not be read — and
//  no test noticed (F19 review). Here, the core's payload is read end to end
//  by `swift test`.
//
//  Three wire shapes exist in this codebase, and the reader accepts all of
//  them, because a shape it cannot read is a request the user cannot answer:
//   - `[{"Accept": "*/*"}, …]` — what the core sends for a held request
//     (`GlueHandler.headersJSON`), and what `SessionCodable.reqHeaders` holds
//     since 1.1.0: order and duplicates survive;
//   - `{"Accept": "*/*", …}`: the object-map shape of `reqHeaders` before the 1.1.0 core;
//   - `[{"key": …, "value": …, "isEnabled": …}, …]` — the rules' own shape.
//  It does NOT decide how a decision goes back: `GlueHandler.headersFromJSON`
//  reads one shape only, and the draft's `editedHeaders()` is the one way out.
//

import Foundation

public enum HeldRequestHeaders {
    /// The wire shape the headers arrived in.
    public enum Format: Equatable, Sendable {
        /// `{"Accept": "*/*", …}`: the object-map shape of `SessionCodable.reqHeaders` before the 1.1.0 core.
        case objectMap
        /// `[{"Accept": "*/*"}, …]` — order survives, duplicates survive.
        case pairArray
        /// `[{"key": …, "value": …, "isEnabled": …}, …]` — the rules' own shape.
        case entryArray
        /// Not JSON at all. The headers are shown verbatim and cannot be
        /// edited: re-encoding something we could not read is how a resumed
        /// request gets a header block the server rejects.
        case unreadable
    }

    /// One header as read. `isEnabled` is false only for an entry-array row
    /// that is switched off — not a header on the wire.
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var value: String
        public var isEnabled: Bool

        public init(name: String, value: String, isEnabled: Bool = true) {
            self.name = name
            self.value = value
            self.isEnabled = isEnabled
        }
    }

    /// What was read, and in which shape.
    public struct Decoded: Equatable, Sendable {
        public let entries: [Entry]
        public let format: Format

        /// The headers as they arrived, for what they say about the body: the
        /// enabled ones, in order — or nil when they could not be read, which
        /// is a different answer from "no headers" (`HeldRequestBody.Declared`
        /// `.unknown` against `.undeclared`).
        public var arrived: [MCPHeaderPair]? {
            guard format != .unreadable else { return nil }
            return entries.filter(\.isEnabled).map { MCPHeaderPair(name: $0.name, value: $0.value) }
        }
    }

    /// Reads `raw`, the `headers` string of a held request.
    public static func decode(_ raw: String) -> Decoded {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to read is not the same as unreadable: with no headers the
        // user can still ADD one, so pick the shape the rest of the app uses
        // for request headers rather than locking the editor.
        if trimmed.isEmpty { return Decoded(entries: [], format: .objectMap) }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return Decoded(entries: [], format: .unreadable)
        }

        if let map = json as? [String: Any] {
            // A JSON object has no order to preserve, so sort it — a header
            // list someone has to scan under a countdown should at least be
            // in a predictable place.
            let entries = map
                .map { Entry(name: $0.key, value: text($0.value)) }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
            return Decoded(entries: entries, format: .objectMap)
        }

        if let array = json as? [[String: Any]] {
            if !array.isEmpty, array.allSatisfy({ $0["key"] is String && $0["value"] != nil }) {
                let entries = array.map {
                    Entry(name: $0["key"] as? String ?? "",
                          value: text($0["value"] ?? ""),
                          isEnabled: ($0["isEnabled"] as? Bool) ?? true)
                }
                return Decoded(entries: entries, format: .entryArray)
            }
            // `[{"Name": "value"}, …]`: the array's order IS the header order,
            // so it is kept as-is rather than sorted. Within one object — the
            // core never sends more than one pair per object — by name, so
            // two reads of the same text agree.
            let entries = array.flatMap { element in
                element.sorted { $0.key < $1.key }.map { Entry(name: $0.key, value: text($0.value)) }
            }
            // An EMPTY array stays an array: re-encoding `[]` as `{}` would
            // hand the core a shape it never sent, on the one request where
            // there is nothing to look at and so nothing to notice it by.
            return Decoded(entries: entries, format: .pairArray)
        }

        return Decoded(entries: [], format: .unreadable)
    }

    private static func text(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }
}

extension HeldRequestBody {
    /// A held request as the Paused Requests panel reads it: its method, the
    /// core's body fields, and the headers its Headers tab shows — as they
    /// ARRIVED, so nothing typed in the header editor changes what the held
    /// body is.
    public init(method: String, preview: String?, byteCount: Int, previewIsPrefix: Bool,
                decodedHeaders: HeldRequestHeaders.Decoded, bodyExpected: Bool?, declaredBodyLength: Int?) {
        self.init(method: method, preview: preview, byteCount: byteCount, previewIsPrefix: previewIsPrefix,
                  headers: decodedHeaders.arrived, bodyExpected: bodyExpected, declaredBodyLength: declaredBodyLength)
    }
}
