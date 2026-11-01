//
//  MCPJSONQuery.swift
//  AppServices
//
//  Created by OloApps on 8/26/26.
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

/// Server-side querying of response bodies. The point is token economy: an
/// agent asks for the shape or one path and receives only that, instead of
/// pulling a megabyte of JSON through its context to read one field.
public enum MCPJSONQuery {
    public enum Mode: String, CaseIterable {
        /// Describe the top-level shape: keys, types, array lengths.
        case structure
        /// Extract the value at a dotted path.
        case path
    }

    public struct Result: Equatable {
        public var text: String
        public var found: Bool

        public init(text: String, found: Bool) {
            self.text = text
            self.found = found
        }
    }

    /// Entry point used by the bridge route.
    public static func query(body: String, mode: Mode, path: String?) -> Result {
        guard let json = parse(body) else {
            return Result(text: "Body is not JSON (\(body.utf8.count) bytes). Use get_session for a raw preview.", found: false)
        }
        switch mode {
        case .structure:
            return Result(text: describe(json), found: true)
        case .path:
            guard let path, !path.isEmpty else {
                return Result(text: "mode=path needs a 'path' argument, e.g. data.items[0].id", found: false)
            }
            guard let value = value(at: path, in: json) else {
                return Result(text: "No value at path '\(path)'. Call with mode=structure to see what the body contains.", found: false)
            }
            return Result(text: render(value), found: true)
        }
    }

    public static func parse(_ body: String) -> Any? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// One line per top-level entry: name, type, and size where size is the
    /// useful part (array length, string length, object key count).
    public static func describe(_ json: Any, indent: String = "") -> String {
        if let object = json as? [String: Any] {
            guard !object.isEmpty else { return "{} (empty object)" }
            let lines = object.keys.sorted().map { key in
                "\(indent)\(key): \(summarize(object[key] as Any))"
            }
            return (["object with \(object.count) key\(object.count == 1 ? "" : "s"):"] + lines).joined(separator: "\n")
        }
        if let array = json as? [Any] {
            guard let first = array.first else { return "[] (empty array)" }
            return "array of \(array.count) — first element: \(summarize(first))"
        }
        return summarize(json)
    }

    static func summarize(_ value: Any) -> String {
        switch value {
        case let object as [String: Any]:
            let keys = object.keys.sorted().prefix(8).joined(separator: ", ")
            let suffix = object.count > 8 ? ", …" : ""
            return "object(\(object.count) keys: \(keys)\(suffix))"
        case let array as [Any]:
            guard let first = array.first else { return "array(0)" }
            return "array(\(array.count) of \(typeName(first)))"
        case let string as String:
            return string.count > 60
                ? "string(\(string.count) chars): \"\(string.prefix(60))…\""
                : "string: \"\(string)\""
        case is NSNull:
            return "null"
        case let number as NSNumber:
            return isBoolean(number) ? "bool: \(number.boolValue)" : "number: \(number)"
        default:
            return "\(value)"
        }
    }

    static func typeName(_ value: Any) -> String {
        switch value {
        case is [String: Any]: return "object"
        case is [Any]: return "array"
        case is String: return "string"
        case is NSNull: return "null"
        case let number as NSNumber: return isBoolean(number) ? "bool" : "number"
        default: return "value"
        }
    }

    /// `NSNumber` erases Bool; this is the standard discriminator.
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Resolves a dotted path with bracket indices: `data.items[0].name`.
    public static func value(at path: String, in json: Any) -> Any? {
        var current: Any? = json
        for component in components(of: path) {
            guard let value = current else { return nil }
            switch component {
            case .key(let key):
                guard let object = value as? [String: Any], let next = object[key] else { return nil }
                current = next
            case .index(let index):
                guard let array = value as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        return current
    }

    enum PathComponent: Equatable {
        case key(String)
        case index(Int)
    }

    static func components(of path: String) -> [PathComponent] {
        var result: [PathComponent] = []
        for rawSegment in path.split(separator: ".", omittingEmptySubsequences: true) {
            var segment = String(rawSegment)
            // Split a trailing run of [n] indices off the key.
            var indices: [Int] = []
            while let open = segment.lastIndex(of: "["), segment.hasSuffix("]") {
                let inner = segment[segment.index(after: open)..<segment.index(before: segment.endIndex)]
                guard let index = Int(inner) else { break }
                indices.insert(index, at: 0)
                segment = String(segment[segment.startIndex..<open])
            }
            if !segment.isEmpty { result.append(.key(segment)) }
            result += indices.map(PathComponent.index)
        }
        return result
    }

    /// Renders an extracted value; containers come back as pretty JSON so the
    /// agent can read them, scalars as bare text.
    public static func render(_ value: Any) -> String {
        if value is [String: Any] || value is [Any] {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            return isBoolean(number) ? String(number.boolValue) : number.stringValue
        }
        return String(describing: value)
    }
}
