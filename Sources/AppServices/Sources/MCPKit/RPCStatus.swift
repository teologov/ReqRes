//
//  RPCStatus.swift
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
//  The RPC's own status (protocol-engine doc §S8): gRPC's 17 codes, the
//  Connect spellings of the same codes, the HTTP-status fallback both
//  protocols define, and the `grpc` filter vocabulary shared by the agent
//  surface (`list_sessions grpc=`) and — spelled a second time in Utils,
//  pinned equal by a test — the `grpc:` search token.
//

import Foundation

/// gRPC status codes (grpc/doc/statuscodes.md). Connect uses the same codes
/// under lower-case names (and spells CANCELLED with one L).
public enum RPCStatusCode {
    /// Index = code.
    public static let names = [
        "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND",
        "ALREADY_EXISTS", "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION",
        "ABORTED", "OUT_OF_RANGE", "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS",
        "UNAUTHENTICATED",
    ]

    /// `NOT_FOUND` for 5; nil for a code outside the table (a server may send
    /// any number, and it is shown as the number).
    public static func name(_ code: Int) -> String? {
        names.indices.contains(code) ? names[code] : nil
    }

    /// "NOT_FOUND", or "code 42" for a number outside the table.
    public static func displayName(_ code: Int) -> String {
        name(code) ?? "code \(code)"
    }

    /// A code name in either spelling — `NOT_FOUND`, `not_found`,
    /// `not-found`, `NotFound`, Connect's `canceled` — to its number.
    public static func code(named raw: String) -> Int? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if key == "canceled" { return 1 }
        return names.firstIndex { $0.lowercased().replacingOccurrences(of: "_", with: "") == key }
    }

    /// When a response carries no status of its own: the mapping gRPC
    /// (http-grpc-status-mapping.md) and Connect ("HTTP to Error Code")
    /// both define for an HTTP status from something that is not the RPC
    /// server — a proxy, a load balancer. Nil for 200 (no inference).
    public static func inferred(fromHTTPStatus status: Int) -> Int? {
        switch status {
        case 200: return nil
        case 400: return 13
        case 401: return 16
        case 403: return 7
        case 404: return 12
        case 429, 502, 503, 504: return 14
        default: return 2
        }
    }
}

/// Where a row's RPC status came from.
public enum RPCStatusSource: String, Codable, Equatable, Sendable {
    /// The gRPC-Web trailer frame at the end of the body.
    case trailerFrame = "trailer_frame"
    /// The response's recorded trailers (native gRPC over HTTP/2).
    case trailers
    /// `grpc-status` in the response head (a trailers-only response).
    case responseHead = "response_head"
    /// Connect streaming's end-of-stream message.
    case endStream = "end_stream"
    /// Connect unary: the HTTP status and, for an error, the JSON body.
    case connectUnary = "connect_unary"
    /// Nothing carried one; mapped from the HTTP status (not the RPC's own).
    case httpStatus = "http_status"
}

/// The RPC's outcome.
public struct RPCStatus: Codable, Equatable, Sendable {
    public var code: Int
    /// The server's message (`grpc-message`, percent-decoded; Connect's
    /// `error.message`). Captured material.
    public var message: String?
    public var source: RPCStatusSource

    public init(code: Int, message: String? = nil, source: RPCStatusSource) {
        self.code = code
        self.message = message
        self.source = source
    }

    public var isOK: Bool { code == 0 }
    public var name: String { RPCStatusCode.displayName(code) }
}

/// The `grpc` filter: `error` (any status but OK), `ok`, a code name in
/// either spelling, or a number.
public enum RPCStatusMatch: Equatable, Sendable {
    case error
    case code(Int)

    public static func parse(_ raw: String) -> RPCStatusMatch? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // `_` and `-` are dropped before the words are compared, exactly as
        // Utils' `TrafficSearchGRPCMatch.normalize` does (`not_ok`, `notok`,
        // `not-ok`, `NotOk`), so the search field and `list_sessions grpc=`
        // accept the same spellings.
        switch trimmed.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "error", "errors", "failed", "!ok", "notok": return .error
        case "ok": return .code(0)
        default: break
        }
        if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(trimmed), number >= 0 {
            return .code(number)
        }
        return RPCStatusCode.code(named: trimmed).map { .code($0) }
    }

    /// A row with no RPC status (not an RPC, or its status was not recorded)
    /// matches nothing — not even `error`.
    public func matches(_ status: Int?) -> Bool {
        guard let status else { return false }
        switch self {
        case .error: return status != 0
        case .code(let wanted): return status == wanted
        }
    }

    /// `error`, `OK`, `NOT_FOUND`, `42` (a number outside the table) —
    /// what `parse` reads back.
    public var token: String {
        switch self {
        case .error: return "error"
        case .code(let code): return RPCStatusCode.name(code) ?? String(code)
        }
    }
}
