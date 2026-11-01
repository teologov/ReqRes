//
//  HTTPSuccessStatus.swift
//  ReqRes
//
//  Created by OloApps on 8/27/24.
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
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

enum HTTPSuccessStatus: Int, CaseIterable, Identifiable {
    var id: Self {
        return self
    }
    
    case ok = 200
    case created = 201
    case accepted = 202
    case nonAuthoritativeInformation = 203
    case noContent = 204
    case resetContent = 205
    case partialContent = 206
    case multiStatus = 207
    case alreadyReported = 208
    case imUsed = 226
    
    var description: String {
        switch self {
        case .ok:
            return "200 OK"
        case .created:
            return "201 Created"
        case .accepted:
            return "202 Accepted"
        case .nonAuthoritativeInformation:
            return "203 Non-Authoritative Information"
        case .noContent:
            return "204 No Content"
        case .resetContent:
            return "205 Reset Content"
        case .partialContent:
            return "206 Partial Content"
        case .multiStatus:
            return "207 Multi-Status"
        case .alreadyReported:
            return "208 Already Reported"
        case .imUsed:
            return "226 IM Used"
        }
    }
}
