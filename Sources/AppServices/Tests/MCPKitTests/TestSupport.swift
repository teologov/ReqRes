//
//  TestSupport.swift
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
@testable import MCPKit

final class StubSessionProvider: MCPSessionProviding {
    var summaries: [MCPSessionSummary]
    var details: [String: MCPSessionDetail]
    /// Keyed by "uid:side" so tests can stage request and response bodies apart.
    var bodies: [String: String]

    init(
        summaries: [MCPSessionSummary] = [],
        details: [String: MCPSessionDetail] = [:],
        bodies: [String: String] = [:]
    ) {
        self.summaries = summaries
        self.details = details
        self.bodies = bodies
    }

    func sessionSummaries() -> [MCPSessionSummary] { summaries }
    func sessionDetail(uid: String) -> MCPSessionDetail? { details[uid] }
    func sessionBody(uid: String, side: MCPBodySide) -> String? { bodies["\(uid):\(side.rawValue)"] }
}

final class StubStatusProvider: MCPStatusProviding {
    var status: MCPBridgeStatus

    init(status: MCPBridgeStatus = MCPBridgeStatus(
        captureActive: true,
        vpnStatus: "connected",
        extensionStatus: "ready",
        caCertificateInstalled: true,
        caCertificateTrusted: true,
        sessionCount: 2,
        appVersion: "1.0.5"
    )) {
        self.status = status
    }

    func bridgeStatus() -> MCPBridgeStatus { status }
}

func makeSession(
    uid: String,
    host: String = "api.example.com",
    method: String = "GET",
    url: String? = nil,
    scheme: String = "https",
    statusCode: Int? = 200,
    app: String? = nil,
    pid: Int? = nil,
    country: String? = nil
) -> MCPSessionSummary {
    MCPSessionSummary(
        uid: uid,
        host: host,
        method: method,
        url: url ?? "https://\(host)/v1/resource/\(uid)",
        scheme: scheme,
        statusCode: statusCode,
        app: app,
        pid: pid,
        country: country
    )
}

struct ParsedResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// Parses the raw HTTP/1.1 bytes produced by MCPHTTPResponse for assertions.
func parseRawResponse(_ data: Data) -> ParsedResponse? {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
          let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
        return nil
    }
    var lines = head.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return nil }
    let statusLine = lines.removeFirst()
    let statusParts = statusLine.split(separator: " ")
    guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return nil }
    var headers: [String: String] = [:]
    for line in lines {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[line.startIndex..<colon]).lowercased()
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        headers[name] = value
    }
    let body = Data(data[headerEnd.upperBound...])
    return ParsedResponse(status: status, headers: headers, body: body)
}

func makeRequest(
    method: String = "GET",
    target: String,
    token: String? = nil,
    host: String? = "127.0.0.1",
    origin: String? = nil
) -> MCPHTTPRequest {
    var headers: [String: String] = [:]
    if let token { headers["authorization"] = "Bearer \(token)" }
    if let host { headers["host"] = host }
    if let origin { headers["origin"] = origin }
    return MCPHTTPRequest(method: method, target: target, headers: headers)
}
