//
//  MCPSessionDiff.swift
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
//  Structural delta between two captured exchanges.
//
//  An agent asked to compare two sessions today pulls both full bodies into
//  its context and eyeballs them — exactly the task language models are
//  worst at. This computes the delta once, server-side, and reports only
//  what changed, so the agent's context holds a handful of lines instead of
//  two payloads.
//
//  Every value that crosses this boundary is redacted independently of
//  whatever the caller already did: a previous review found mock_from_session
//  handing a login response's Set-Cookie to an agent because it assumed
//  redaction had already run upstream. A diff of two credentials is a second
//  place the same mistake can happen, so this file owns its own MCPRedactor
//  pass rather than trusting the two MCPSessionDetail values it is given.
//

import Foundation

// MARK: - Result model

/// What differs between two captured exchanges, computed after each side has
/// been redacted on its own. Every collection is explicitly sorted: Swift
/// gives Dictionary and Set no ordering guarantee (their iteration order can
/// change between runs of the same process, let alone between processes), and
/// an agent re-running the same comparison must see the same lines twice or
/// it will "fix" a diff that never changed.
public struct MCPSessionDiff: Codable, Equatable {
    public var uidA: String
    public var uidB: String

    /// True only when every field this type COULD verify came back equal.
    /// A header or JSON key whose name is sensitive is never counted against
    /// this — after redaction its value is a constant placeholder on both
    /// sides regardless of what the real value was, so "equal" would be a
    /// fact about the placeholder, not about the traffic. Those fields are
    /// reported separately (see `MCPHeaderDiff.redactedUnverifiedCount`) and
    /// are silently absent from JSON path diffs for the same reason — see the
    /// note on `diffJSONBodies` below.
    public var identical: Bool

    public var statusCode: MCPFieldChange<Int?>?
    public var method: MCPFieldChange<String>?
    /// Scheme + host + path, with the query string removed — the query is
    /// diffed separately as a set of parameters, below.
    public var url: MCPFieldChange<String>?

    public var addedQueryParams: [MCPNamedValue]
    public var removedQueryParams: [MCPNamedValue]
    public var changedQueryParams: [MCPQueryParamChange]

    public var requestHeaders: MCPHeaderDiff
    public var responseHeaders: MCPHeaderDiff
    public var requestBody: MCPBodyDiff
    public var responseBody: MCPBodyDiff

    public init(
        uidA: String,
        uidB: String,
        identical: Bool,
        statusCode: MCPFieldChange<Int?>?,
        method: MCPFieldChange<String>?,
        url: MCPFieldChange<String>?,
        addedQueryParams: [MCPNamedValue],
        removedQueryParams: [MCPNamedValue],
        changedQueryParams: [MCPQueryParamChange],
        requestHeaders: MCPHeaderDiff,
        responseHeaders: MCPHeaderDiff,
        requestBody: MCPBodyDiff,
        responseBody: MCPBodyDiff
    ) {
        self.uidA = uidA
        self.uidB = uidB
        self.identical = identical
        self.statusCode = statusCode
        self.method = method
        self.url = url
        self.addedQueryParams = addedQueryParams
        self.removedQueryParams = removedQueryParams
        self.changedQueryParams = changedQueryParams
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestBody
        self.responseBody = responseBody
    }
}

/// A field that differed. Generic over the compared type so `Int?` (status
/// code), `String` (method, URL) and future fields share one shape instead of
/// each getting a bespoke `xChanged` / `xBefore` / `xAfter` trio.
public struct MCPFieldChange<Value: Codable & Equatable>: Codable, Equatable {
    public var before: Value
    public var after: Value

    public init(before: Value, after: Value) {
        self.before = before
        self.after = after
    }
}

public struct MCPNamedValue: Codable, Equatable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct MCPQueryParamChange: Codable, Equatable {
    public var name: String
    public var before: String
    public var after: String

    public init(name: String, before: String, after: String) {
        self.name = name
        self.before = before
        self.after = after
    }
}

public struct MCPHeaderChange: Codable, Equatable {
    public var name: String
    public var before: String
    public var after: String

    public init(name: String, before: String, after: String) {
        self.name = name
        self.before = before
        self.after = after
    }
}

/// Header names are case-insensitive (RFC 7230 §3.2), so this is built by
/// folding both sides to lowercase before comparing — "Content-Type" on one
/// capture and "content-type" on the other must never show up as one added
/// and one removed header.
public struct MCPHeaderDiff: Codable, Equatable {
    public var added: [MCPNamedValue]
    public var removed: [MCPNamedValue]
    public var changed: [MCPHeaderChange]
    public var unchangedCount: Int
    /// Present under the same name on both sides, but the name is sensitive
    /// (Authorization, Cookie, …) so both values were replaced with the same
    /// constant placeholder before comparison. Counting these as "unchanged"
    /// would report a fact about the placeholder as if it were a fact about
    /// the credential; counting them as "changed" is impossible without
    /// un-redacting them. Reporting a plain count is the only claim that is
    /// actually true.
    public var redactedUnverifiedCount: Int

    public init(added: [MCPNamedValue], removed: [MCPNamedValue], changed: [MCPHeaderChange], unchangedCount: Int, redactedUnverifiedCount: Int) {
        self.added = added
        self.removed = removed
        self.changed = changed
        self.unchangedCount = unchangedCount
        self.redactedUnverifiedCount = redactedUnverifiedCount
    }

    var hasDifferences: Bool { !added.isEmpty || !removed.isEmpty || !changed.isEmpty }
}

public struct MCPJSONPathChange: Codable, Equatable {
    public var path: String
    public var before: String
    public var after: String

    public init(path: String, before: String, after: String) {
        self.path = path
        self.before = before
        self.after = after
    }
}

public struct MCPJSONBodyDiff: Codable, Equatable {
    public var addedPaths: [String]
    public var removedPaths: [String]
    public var changed: [MCPJSONPathChange]
    /// True when the walk hit `maxReportedChanges` differences and stopped
    /// early. The count above that point is not tracked — knowing the walk
    /// was cut short is the only thing an agent can act on (ask a narrower
    /// question), and counting exactly how much more there is would mean
    /// walking the whole structure anyway, defeating the cap's purpose.
    public var truncated: Bool

    public init(addedPaths: [String], removedPaths: [String], changed: [MCPJSONPathChange], truncated: Bool) {
        self.addedPaths = addedPaths
        self.removedPaths = removedPaths
        self.changed = changed
        self.truncated = truncated
    }

    var isEmpty: Bool { addedPaths.isEmpty && removedPaths.isEmpty && changed.isEmpty }
}

/// A request or response body's delta. JSON gets a structural walk; anything
/// else — including a body that merely LOOKS like JSON on one side — falls
/// back to a coarse report, because there is no meaningful path-level diff
/// for an opaque blob.
///
/// Written by hand rather than relying on compiler-synthesized Codable for an
/// enum with associated values, matching `MCPAuditSnapshot` — this codebase's
/// established pattern for that shape.
public enum MCPBodyDiff: Codable, Equatable {
    /// Byte-identical after independent redaction, including "both non-empty
    /// and equal" — the common case when an agent is diffing a session
    /// against a mock built from it.
    case identical
    case bothEmpty
    case oneEmpty
    case sameLength(bytes: Int)
    case differentLength(before: Int, after: Int)
    /// Exactly one side parsed as JSON. `MCPRedactor.redactBody` re-serializes
    /// a JSON body it redacts (pretty-printed, sorted keys) as a side effect
    /// of walking its object graph, so the two sides' byte lengths are no
    /// longer comparable once only one of them went through that rewrite —
    /// reporting a length here would be comparing formatting, not content.
    case notComparable
    case structural(MCPJSONBodyDiff)

    private enum CodingKeys: String, CodingKey { case kind, bytes, before, after, structural }
    private enum Kind: String, Codable {
        case identical, bothEmpty, oneEmpty, sameLength, differentLength, notComparable, structural
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .identical:
            try container.encode(Kind.identical, forKey: .kind)
        case .bothEmpty:
            try container.encode(Kind.bothEmpty, forKey: .kind)
        case .oneEmpty:
            try container.encode(Kind.oneEmpty, forKey: .kind)
        case .sameLength(let bytes):
            try container.encode(Kind.sameLength, forKey: .kind)
            try container.encode(bytes, forKey: .bytes)
        case .differentLength(let before, let after):
            try container.encode(Kind.differentLength, forKey: .kind)
            try container.encode(before, forKey: .before)
            try container.encode(after, forKey: .after)
        case .notComparable:
            try container.encode(Kind.notComparable, forKey: .kind)
        case .structural(let diff):
            try container.encode(Kind.structural, forKey: .kind)
            try container.encode(diff, forKey: .structural)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .identical: self = .identical
        case .bothEmpty: self = .bothEmpty
        case .oneEmpty: self = .oneEmpty
        case .sameLength:
            self = .sameLength(bytes: try container.decode(Int.self, forKey: .bytes))
        case .differentLength:
            self = .differentLength(
                before: try container.decode(Int.self, forKey: .before),
                after: try container.decode(Int.self, forKey: .after)
            )
        case .notComparable: self = .notComparable
        case .structural:
            self = .structural(try container.decode(MCPJSONBodyDiff.self, forKey: .structural))
        }
    }
}

// MARK: - Engine

extension MCPSessionDiff {
    /// How many structural body differences a single diff will report.
    ///
    /// Its own number rather than the borrowed pagination limit it used to
    /// use: this bounds an agent's context, and tuning list paging for an
    /// unrelated reason should not silently change how much of a diff is
    /// truncated.
    static let maxReportedChanges = 200

    /// Computes the delta between two sessions.
    ///
    /// Diffing a session against itself (`a.summary.uid == b.summary.uid`, or
    /// simply two identical captures) is treated as a valid, empty diff and
    /// not an error: an agent building a before/after loop around a mock may
    /// legitimately call this before anything has changed yet, and a special
    /// error here would be one more case its caller has to branch on for a
    /// perfectly well-defined question ("what changed" — nothing did).
    public static func diff(
        _ a: MCPSessionDetail,
        _ b: MCPSessionDetail,
        redactor: MCPRedactor = MCPRedactor()
    ) -> MCPSessionDiff {
        let left = redactor.redactDetail(a)
        let right = redactor.redactDetail(b)

        let statusCode = fieldChange(left.summary.statusCode, right.summary.statusCode)
        let method: MCPFieldChange<String>? = left.summary.method.caseInsensitiveCompare(right.summary.method) == .orderedSame
            ? nil
            : MCPFieldChange(before: left.summary.method, after: right.summary.method)

        // `left`/`right` already went through redactDetail above, so their
        // URLs are already redacted — splitURL only parses, it does not redact.
        let leftURL = splitURL(left.summary.url)
        let rightURL = splitURL(right.summary.url)
        let url: MCPFieldChange<String>? = leftURL.base == rightURL.base
            ? nil
            : MCPFieldChange(before: leftURL.base, after: rightURL.base)
        let query = diffQueryParams(leftURL.queryItems, rightURL.queryItems)

        let requestHeaders = diffHeaders(left.requestHeaders, right.requestHeaders)
        let responseHeaders = diffHeaders(left.responseHeaders, right.responseHeaders)
        let requestBody = diffBody(left.requestBodyPreview, right.requestBodyPreview)
        let responseBody = diffBody(left.responseBodyPreview, right.responseBodyPreview)

        let identical = statusCode == nil
            && method == nil
            && url == nil
            && query.added.isEmpty && query.removed.isEmpty && query.changed.isEmpty
            && !requestHeaders.hasDifferences
            && !responseHeaders.hasDifferences
            && isNoDifference(requestBody)
            && isNoDifference(responseBody)

        return MCPSessionDiff(
            uidA: a.summary.uid,
            uidB: b.summary.uid,
            identical: identical,
            statusCode: statusCode,
            method: method,
            url: url,
            addedQueryParams: query.added,
            removedQueryParams: query.removed,
            changedQueryParams: query.changed,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBody,
            responseBody: responseBody
        )
    }

    private static func isNoDifference(_ diff: MCPBodyDiff) -> Bool {
        switch diff {
        case .identical, .bothEmpty:
            return true
        case .oneEmpty, .sameLength, .differentLength, .notComparable:
            return false
        case .structural(let jsonDiff):
            return jsonDiff.isEmpty
        }
    }

    private static func fieldChange<Value: Codable & Equatable>(_ before: Value, _ after: Value) -> MCPFieldChange<Value>? {
        before == after ? nil : MCPFieldChange(before: before, after: after)
    }

    // MARK: URL / query

    /// Splits an ALREADY-REDACTED URL into a base (scheme + host + path) and
    /// its query items. Takes no redactor: callers pass the `url` off an
    /// `MCPSessionDetail` that has already been through `redactDetail`, and
    /// redacting again would be redundant (idempotent, but still pointless
    /// work run on every diff).
    private static func splitURL(_ redactedURL: String) -> (base: String, queryItems: Set<MCPNamedValue>) {
        guard var components = URLComponents(string: redactedURL) else {
            // Not a well-formed URL even after redaction (rare — a body-only
            // detail path never hits this). The whole string is the best
            // available "base"; there is nothing to parse a query out of.
            return (base: redactedURL, queryItems: [])
        }
        let items = Set((components.percentEncodedQueryItems ?? []).map {
            MCPNamedValue(name: $0.name, value: $0.value ?? "")
        })
        components.percentEncodedQuery = nil
        return (base: components.string ?? redactedURL, queryItems: items)
    }

    private static func diffQueryParams(
        _ a: Set<MCPNamedValue>,
        _ b: Set<MCPNamedValue>
    ) -> (added: [MCPNamedValue], removed: [MCPNamedValue], changed: [MCPQueryParamChange]) {
        // Grouping by name lets a single-valued parameter's value change read
        // as one "changed" line instead of an unrelated-looking add+remove
        // pair. A name that repeats (a genuinely multi-valued query string)
        // has no single old value to pair against a single new one, so those
        // fall back to the plain set difference the PRD asked for.
        let byNameA = Dictionary(grouping: a, by: { $0.name.lowercased() })
        let byNameB = Dictionary(grouping: b, by: { $0.name.lowercased() })

        var added: [MCPNamedValue] = []
        var removed: [MCPNamedValue] = []
        var changed: [MCPQueryParamChange] = []

        for name in Set(byNameA.keys).union(byNameB.keys) {
            let left = byNameA[name] ?? []
            let right = byNameB[name] ?? []
            if left.count == 1, right.count == 1, left[0].value != right[0].value {
                changed.append(MCPQueryParamChange(name: right[0].name, before: left[0].value, after: right[0].value))
                continue
            }
            let leftSet = Set(left)
            let rightSet = Set(right)
            added.append(contentsOf: rightSet.subtracting(leftSet))
            removed.append(contentsOf: leftSet.subtracting(rightSet))
        }

        return (
            added.sorted(by: namedValueOrder),
            removed.sorted(by: namedValueOrder),
            changed.sorted { $0.name.lowercased() < $1.name.lowercased() }
        )
    }

    private static func namedValueOrder(_ lhs: MCPNamedValue, _ rhs: MCPNamedValue) -> Bool {
        lhs.name.lowercased() == rhs.name.lowercased()
            ? lhs.value < rhs.value
            : lhs.name.lowercased() < rhs.name.lowercased()
    }

    // MARK: Headers

    private static func diffHeaders(_ a: [String: String], _ b: [String: String]) -> MCPHeaderDiff {
        // Sorting before folding to lowercase makes the survivor of a same-name
        // collision (two spellings of one header inside a single dictionary,
        // which should not happen but is not guaranteed by the type) picked
        // deterministically instead of depending on Dictionary's enumeration
        // order.
        func normalized(_ headers: [String: String]) -> [String: (name: String, value: String)] {
            var result: [String: (name: String, value: String)] = [:]
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
                result[name.lowercased()] = (name, value)
            }
            return result
        }

        let left = normalized(a)
        let right = normalized(b)

        var added: [MCPNamedValue] = []
        var removed: [MCPNamedValue] = []
        var changed: [MCPHeaderChange] = []
        var unchanged = 0
        var redactedUnverified = 0

        for key in Set(left.keys).union(right.keys) {
            switch (left[key], right[key]) {
            case let (.some(l), .some(r)):
                if MCPRedactor.isSensitiveName(l.name) {
                    // Both sides were already forced to the same constant
                    // placeholder by redactHeaders regardless of the real
                    // value, so string equality here is always true and
                    // would always claim "unchanged" whether or not the real
                    // credential rotated. That claim would be false often
                    // enough to be worse than not making it.
                    redactedUnverified += 1
                } else if l.value == r.value {
                    unchanged += 1
                } else {
                    changed.append(MCPHeaderChange(name: r.name, before: l.value, after: r.value))
                }
            case let (.some(l), .none):
                removed.append(MCPNamedValue(name: l.name, value: l.value))
            case let (.none, .some(r)):
                added.append(MCPNamedValue(name: r.name, value: r.value))
            case (.none, .none):
                break
            }
        }

        return MCPHeaderDiff(
            added: added.sorted(by: namedValueOrder),
            removed: removed.sorted(by: namedValueOrder),
            changed: changed.sorted { $0.name.lowercased() < $1.name.lowercased() },
            unchangedCount: unchanged,
            redactedUnverifiedCount: redactedUnverified
        )
    }

    // MARK: Bodies

    private static func diffBody(_ rawBefore: String?, _ rawAfter: String?) -> MCPBodyDiff {
        let before = rawBefore ?? ""
        let after = rawAfter ?? ""
        let beforeEmpty = before.isEmpty
        let afterEmpty = after.isEmpty

        if beforeEmpty, afterEmpty { return .bothEmpty }
        if beforeEmpty != afterEmpty { return .oneEmpty }
        // Checked before attempting a JSON parse for two reasons: an agent
        // re-running the same request twice (the most common diff_sessions
        // call there is) should get the plain answer "identical" rather than
        // "structurally, nothing differs", and skipping the parse/walk
        // entirely is cheaper when it is already known there is nothing to
        // find.
        if before == after { return .identical }

        switch (MCPJSONQuery.parse(before), MCPJSONQuery.parse(after)) {
        case let (.some(beforeJSON), .some(afterJSON)):
            return diffJSONBodies(beforeJSON, afterJSON)
        case (.some, .none), (.none, .some):
            return .notComparable
        case (.none, .none):
            break
        }

        let beforeBytes = before.utf8.count
        let afterBytes = after.utf8.count
        return beforeBytes == afterBytes ? .sameLength(bytes: beforeBytes) : .differentLength(before: beforeBytes, after: afterBytes)
    }

    /// Walks both parsed JSON trees together, in lockstep, only descending
    /// where both sides agree on shape.
    ///
    /// A key whose NAME is sensitive is not given special handling here the
    /// way a sensitive header name is above, and that asymmetry is
    /// deliberate rather than an oversight: `MCPRedactor.redactJSON` replaces
    /// a sensitive key's entire value — object, array, or scalar — with the
    /// one constant placeholder string before this function ever sees it. By
    /// the time the walk reaches that key, both sides already hold the exact
    /// same scalar, so the equality check below stops the recursion there on
    /// its own; there is no separate "unverified" case to track because
    /// nothing distinguishable to mis-report survives the redaction pass.
    /// Tracking key-sensitivity a second time here, in parallel with what
    /// `MCPRedactor` already decided, would only create a second place for
    /// that logic to drift from the first.
    private static func diffJSONBodies(_ a: Any, _ b: Any) -> MCPBodyDiff {
        let accumulator = JSONDiffAccumulator(cap: maxReportedChanges)
        walkJSON(a, b, path: "", into: accumulator)
        return .structural(MCPJSONBodyDiff(
            addedPaths: accumulator.addedPaths.sorted(),
            removedPaths: accumulator.removedPaths.sorted(),
            changed: accumulator.changed.sorted { $0.path < $1.path },
            truncated: accumulator.truncated
        ))
    }

    private static func walkJSON(_ a: Any, _ b: Any, path: String, into accumulator: JSONDiffAccumulator) {
        if accumulator.isFull {
            accumulator.truncated = true
            return
        }
        if jsonValuesEqual(a, b) { return }

        switch (a, b) {
        case let (objectA as [String: Any], objectB as [String: Any]):
            for key in Set(objectA.keys).union(objectB.keys).sorted() {
                if accumulator.isFull { accumulator.truncated = true; return }
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                switch (objectA[key], objectB[key]) {
                case let (.some(av), .some(bv)):
                    walkJSON(av, bv, path: childPath, into: accumulator)
                case (.some, .none):
                    accumulator.addRemoved(childPath)
                case (.none, .some):
                    accumulator.addAdded(childPath)
                case (.none, .none):
                    break
                }
            }
        case let (arrayA as [Any], arrayB as [Any]):
            let count = max(arrayA.count, arrayB.count)
            for index in 0..<count {
                if accumulator.isFull { accumulator.truncated = true; return }
                let childPath = "\(path)[\(index)]"
                if index < arrayA.count, index < arrayB.count {
                    walkJSON(arrayA[index], arrayB[index], path: childPath, into: accumulator)
                } else if index < arrayA.count {
                    accumulator.addRemoved(childPath)
                } else {
                    accumulator.addAdded(childPath)
                }
            }
        default:
            // Scalars that differ, or a type swap (an object replaced by an
            // array, a string replaced by a number, …). `MCPJSONQuery.render`
            // already renders any of those shapes for a single extracted
            // value, so reusing it here keeps the two tools' output in the
            // same vocabulary.
            let displayPath = path.isEmpty ? "(root)" : path
            let before = MCPSessionQuery.cappedPreview(MCPJSONQuery.render(a)).preview ?? ""
            let after = MCPSessionQuery.cappedPreview(MCPJSONQuery.render(b)).preview ?? ""
            accumulator.addChanged(MCPJSONPathChange(path: displayPath, before: before, after: after))
        }
    }

    /// Deep equality over the `Any` graph `JSONSerialization` produces.
    /// `NSObject`'s own `isEqual` cannot be trusted here across the object
    /// graph (an `NSNumber` boolean and `NSNumber` 1 compare equal to some
    /// callers), so this walks the same three container/scalar cases the
    /// diff itself switches on.
    private static func jsonValuesEqual(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (numberA as NSNumber, numberB as NSNumber):
            return numberA.isBoolNumber == numberB.isBoolNumber && numberA == numberB
        case let (stringA as String, stringB as String):
            return stringA == stringB
        case (is NSNull, is NSNull):
            return true
        case let (arrayA as [Any], arrayB as [Any]):
            guard arrayA.count == arrayB.count else { return false }
            // `allSatisfy`'s closure takes zip's single tuple element, not two
            // separate arguments — `$1` is not in scope for it, unlike a
            // closure with an explicit two-name parameter list.
            return zip(arrayA, arrayB).allSatisfy { pair in jsonValuesEqual(pair.0, pair.1) }
        case let (objectA as [String: Any], objectB as [String: Any]):
            guard objectA.count == objectB.count else { return false }
            return objectA.allSatisfy { key, value in
                guard let other = objectB[key] else { return false }
                return jsonValuesEqual(value, other)
            }
        default:
            return false
        }
    }
}

private extension NSNumber {
    /// `NSNumber` erases Swift's `Bool`, so `1` and `true` are otherwise
    /// indistinguishable to `==` — the same discriminator `MCPJSONQuery` uses.
    var isBoolNumber: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}

/// Bounds how many differences a single JSON body walk can report. A
/// reference type because the recursive walk needs to stop consuming budget
/// the instant it fills up, from arbitrarily deep call frames, rather than
/// threading a running total back up through every return value.
private final class JSONDiffAccumulator {
    let cap: Int
    var addedPaths: [String] = []
    var removedPaths: [String] = []
    var changed: [MCPJSONPathChange] = []
    var truncated = false

    init(cap: Int) {
        self.cap = max(cap, 1)
    }

    var isFull: Bool {
        addedPaths.count + removedPaths.count + changed.count >= cap
    }

    func addAdded(_ path: String) {
        guard !isFull else { truncated = true; return }
        addedPaths.append(path)
    }

    func addRemoved(_ path: String) {
        guard !isFull else { truncated = true; return }
        removedPaths.append(path)
    }

    func addChanged(_ change: MCPJSONPathChange) {
        guard !isFull else { truncated = true; return }
        changed.append(change)
    }
}

// MARK: - Text rendering

/// Renders a diff as compact text for a tool result, in the style of
/// `MCPTextFormat` (kept in its own type rather than added to that file so
/// this feature stays in one file).
public enum MCPSessionDiffFormat {
    public static func render(_ diff: MCPSessionDiff) -> String {
        guard !diff.identical else {
            // An empty string here reads, on a terminal or in a chat
            // transcript, as "the tool call produced nothing" — indistinguishable
            // from a bug. Saying so plainly is the whole point of a "no
            // difference" answer: it is itself the useful result.
            var lines = ["No differences found between \(diff.uidA) and \(diff.uidB)."]
            let unverified = diff.requestHeaders.redactedUnverifiedCount + diff.responseHeaders.redactedUnverifiedCount
            if unverified > 0 {
                lines.append("\(unverified) header value\(unverified == 1 ? "" : "s") could not be compared because they are redacted.")
            }
            return lines.joined(separator: "\n")
        }

        var lines: [String] = []
        if let statusCode = diff.statusCode {
            lines.append("Status: \(statusCode.before.map(String.init) ?? "—") → \(statusCode.after.map(String.init) ?? "—")")
        }
        if let method = diff.method {
            lines.append("Method: \(method.before) → \(method.after)")
        }
        if let url = diff.url {
            lines.append("URL: \(url.before) → \(url.after)")
        }
        if !diff.addedQueryParams.isEmpty {
            lines.append("Query params added: " + diff.addedQueryParams.map { "\($0.name)=\($0.value)" }.joined(separator: ", "))
        }
        if !diff.removedQueryParams.isEmpty {
            lines.append("Query params removed: " + diff.removedQueryParams.map { "\($0.name)=\($0.value)" }.joined(separator: ", "))
        }
        if !diff.changedQueryParams.isEmpty {
            lines.append("Query params changed: " + diff.changedQueryParams.map { "\($0.name): \($0.before) → \($0.after)" }.joined(separator: ", "))
        }
        lines.append(contentsOf: headerLines("Request headers", diff.requestHeaders))
        lines.append(contentsOf: headerLines("Response headers", diff.responseHeaders))
        lines.append(contentsOf: bodyLines("Request body", diff.requestBody))
        lines.append(contentsOf: bodyLines("Response body", diff.responseBody))
        return lines.joined(separator: "\n")
    }

    private static func headerLines(_ title: String, _ diff: MCPHeaderDiff) -> [String] {
        guard diff.hasDifferences || diff.redactedUnverifiedCount > 0 else { return [] }
        var lines = ["", "\(title):"]
        // A repeated header (two `Set-Cookie`) arrives newline-joined; each
        // recorded line is printed as its own header so a diff line never
        // spans two lines of output.
        for item in diff.added {
            lines += MCPRecordedHeaders.lines(of: item.value).map { "  + \(item.name): \($0)" }
        }
        for item in diff.removed {
            lines += MCPRecordedHeaders.lines(of: item.value).map { "  - \(item.name): \($0)" }
        }
        for change in diff.changed {
            let before = MCPRecordedHeaders.lines(of: change.before).joined(separator: " ⏎ ")
            let after = MCPRecordedHeaders.lines(of: change.after).joined(separator: " ⏎ ")
            lines.append("  ~ \(change.name): \(before) → \(after)")
        }
        if diff.redactedUnverifiedCount > 0 {
            let count = diff.redactedUnverifiedCount
            lines.append("  (\(count) header\(count == 1 ? "" : "s") present on both sides could not be compared — redacted)")
        }
        return lines
    }

    private static func bodyLines(_ title: String, _ diff: MCPBodyDiff) -> [String] {
        switch diff {
        case .identical, .bothEmpty:
            return []
        case .oneEmpty:
            return ["", "\(title): present on one side only"]
        case .sameLength(let bytes):
            return ["", "\(title): same length (\(bytes) bytes) but different content"]
        case .differentLength(let before, let after):
            return ["", "\(title): length changed \(before) → \(after) bytes"]
        case .notComparable:
            return ["", "\(title): not comparable — one side is JSON, the other is not"]
        case .structural(let jsonDiff):
            guard !jsonDiff.isEmpty || jsonDiff.truncated else { return [] }
            var lines = ["", "\(title) (JSON):"]
            for path in jsonDiff.addedPaths { lines.append("  + \(path)") }
            for path in jsonDiff.removedPaths { lines.append("  - \(path)") }
            for change in jsonDiff.changed { lines.append("  ~ \(change.path): \(change.before) → \(change.after)") }
            if jsonDiff.truncated {
                lines.append("  (more differences than shown — narrow the comparison with query_session_body)")
            }
            return lines
        }
    }
}
