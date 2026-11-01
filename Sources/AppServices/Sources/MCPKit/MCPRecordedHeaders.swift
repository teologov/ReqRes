//
//  MCPRecordedHeaders.swift
//  AppServices
//
//  Created by OloApps on 9/28/26.
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
//  Reads a session's recorded headers (`SessionCodable.reqHeaders` /
//  `rspHeaders`) into the `[String: String]` the MCP models carry.
//
//  Two shapes exist, and both must read:
//    - `[{"Set-Cookie":"a=1"},{"Set-Cookie":"b=2"}, …]` — what the core records
//      since 1.1.0 (its `SessionHeaderList`): ordered pairs, duplicates kept;
//    - `{"Host":"example.com", …}` — what it recorded before, and what every
//      session saved before 1.1.0 still holds.
//  Reading only the object shape (what this used to do, inline in
//  `MCPSessionAdapter.headers(from:)`) returns NOTHING for a new row: every
//  header silently gone from `get_session`, saved sessions, HAR and
//  `mock_from_session`.
//
//  A dictionary holds one value per name, so a name recorded more than once is
//  combined — never dropped — the way HTTP itself permits (RFC 9110 §5.3,
//  `", "`), except the two fields that rule does not cover: `Set-Cookie`,
//  whose values contain commas (`Expires=Wed, 21 Oct …`) and so are joined by a
//  newline (RFC 6265 §3), and `Cookie`, joined by `"; "` (RFC 6265 §5.4). Names
//  are matched case-insensitively (they are, in HTTP) and keep the first
//  spelling seen.
//
//  Pure Foundation (no XReqResCore) so it is tested in `swift test`.
//

import Foundation

public enum MCPRecordedHeaders {
    /// Recorded header JSON (either shape) → one value per name.
    /// nil, empty or unreadable input is `[:]`, never a trap.
    public static func dictionary(from raw: String?) -> [String: String] {
        var result: [String: String] = [:]
        var spelling: [String: String] = [:]      // lowercased name → first spelling
        for (name, value) in pairs(from: raw) {
            let key = name.lowercased()
            if let existingName = spelling[key], let existing = result[existingName] {
                result[existingName] = existing + separator(for: key) + value
            } else {
                spelling[key] = name
                result[name] = value
            }
        }
        return result
    }

    /// Recorded response headers → what a RULE can carry: one value per name,
    /// and no value containing a line break.
    ///
    /// `mock_from_session` copies a captured response's headers into a rule.
    /// `dictionary(from:)` joins a repeated `Set-Cookie` with a newline, which
    /// `MCPWriteValidation.validateHeaders` rightly refuses (header injection),
    /// so every login response — two or more `Set-Cookie` — failed with a 400
    /// once the core started recording repeated headers (1.1.0). A rule could
    /// not carry two anyway: the proxy applies a rule's headers with
    /// `replaceOrAdd`, one value per name. So a repeated `Set-Cookie` keeps its
    /// LAST value — what the pre-1.1.0 core recorded, so a mock is exactly what
    /// it was before — and every other name combines as `dictionary` does
    /// (`", "`, `"; "` for `Cookie`), which never introduces a line break.
    public static func ruleHeaders(from raw: String?) -> [String: String] {
        var result = dictionary(from: raw)
        guard let name = result.keys.first(where: { $0.lowercased() == "set-cookie" }) else { return result }
        if let last = pairs(from: raw).last(where: { $0.name.lowercased() == "set-cookie" }) {
            result[name] = last.value
        }
        return result
    }

    /// Recorded header JSON (either shape) → ordered pairs. The pair array
    /// keeps wire order; the old object shape has none, so it is read in name
    /// order (stable across reads).
    public static func pairs(from raw: String?) -> [(name: String, value: String)] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let entries = object as? [[String: Any]] {
            return entries.flatMap { entry in
                entry.sorted { $0.key < $1.key }.map { (name: $0.key, value: text($0.value)) }
            }
        }
        if let map = object as? [String: Any] {
            return map.sorted { $0.key < $1.key }.map { (name: $0.key, value: text($0.value)) }
        }
        return []
    }

    /// The header lines one dictionary value stands for. `dictionary(from:)`
    /// joins a repeated `Set-Cookie` with a newline; no value on the wire can
    /// contain one, so splitting on it gives back exactly the recorded lines.
    /// Every other value is one line (a repeated `Vary` was joined with
    /// `", "` and stays joined — HTTP allows that for every field but
    /// `Set-Cookie`). Anything that prints headers one per line (the agent's
    /// text, the diff, HAR) goes through this, so two `Set-Cookie` read as two
    /// headers everywhere.
    public static func lines(of value: String) -> [String] {
        guard value.contains("\n") else { return [value] }
        return value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// `name: value` lines for a header dictionary, sorted by name
    /// (case-insensitively, the raw name breaking ties so two encodes are
    /// identical). A repeated `Set-Cookie` gets one line per recorded cookie;
    /// any other repeated name stays ONE line, its values already joined by
    /// `dictionary(from:)` (`", "`, or `"; "` for `Cookie`).
    public static func displayLines(_ headers: [String: String]) -> [String] {
        headers.sorted { ($0.key.lowercased(), $0.key) < ($1.key.lowercased(), $1.key) }
            .flatMap { name, value in lines(of: value).map { "\(name): \($0)" } }
    }

    private static func separator(for lowercasedName: String) -> String {
        switch lowercasedName {
        case "set-cookie": return "\n"
        case "cookie": return "; "
        default: return ", "
        }
    }

    private static func text(_ value: Any) -> String {
        if let string = value as? String { return string }
        return String(describing: value)
    }
}
