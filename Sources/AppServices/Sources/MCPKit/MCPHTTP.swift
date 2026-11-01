//
//  MCPHTTP.swift
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

/// Minimal HTTP/1.1 message handling for the loopback bridge. Deliberately
/// dependency-free: one short-lived connection per request, Connection: close.
public struct MCPHTTPRequest: Equatable {
    public var method: String
    /// Raw request target, e.g. "/v1/sessions?host=api.example.com".
    public var target: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public var path: String {
        target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }

    public var queryItems: [URLQueryItem] {
        guard let components = URLComponents(string: target) else { return [] }
        return components.queryItems ?? []
    }

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }
}

public enum MCPHTTPParseResult: Equatable {
    case request(MCPHTTPRequest)
    /// The buffer does not yet hold a complete message; read more bytes.
    case needMoreData
    case invalid(reason: String)
}

public enum MCPHTTPParser {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 1024 * 1024

    public static func parse(_ data: Data) -> MCPHTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            if data.count > maxHeaderBytes { return .invalid(reason: "headers too large") }
            return .needMoreData
        }
        if headerEnd.lowerBound > maxHeaderBytes { return .invalid(reason: "headers too large") }

        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(reason: "headers not UTF-8")
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid(reason: "empty request") }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            return .invalid(reason: "malformed request line")
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(reason: "malformed header")
            }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(reason: "malformed header") }
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            return .invalid(reason: "chunked bodies not supported")
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= maxBodyBytes else {
            return .invalid(reason: "body too large")
        }

        let bodyStart = headerEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        if available < contentLength { return .needMoreData }

        let body = contentLength > 0
            ? Data(data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)])
            : Data()
        return .request(MCPHTTPRequest(method: method, target: target, headers: headers, body: body))
    }
}

public enum MCPHTTPResponse {
    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Status \(status)"
        }
    }

    public static func raw(status: Int, headers: [String: String] = [:], body: Data = Data()) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(for: status))\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        allHeaders["Cache-Control"] = "no-store"
        for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    public static func json<T: Encodable>(status: Int, _ payload: T, extraHeaders: [String: String] = [:]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(payload)) ?? Data("{}".utf8)
        var headers = extraHeaders
        headers["Content-Type"] = "application/json"
        return raw(status: status, headers: headers, body: body)
    }

    public static func error(status: Int, code: String, message: String, extraHeaders: [String: String] = [:]) -> Data {
        struct ErrorBody: Encodable {
            struct Inner: Encodable {
                let code: String
                let message: String
            }
            let error: Inner
        }
        return json(status: status, ErrorBody(error: .init(code: code, message: message)), extraHeaders: extraHeaders)
    }
}
