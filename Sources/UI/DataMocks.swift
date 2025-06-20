//
//  DataMocks.swift
//  ReqRes
//
//  Created by OloApps on 6/10/24.
//
//  Copyright © 2025 OloApps. All rights reserved.
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
import XReqResCore

let SESSION_MOCK = SessionCodable(
        startTime: NSNumber(value: mockNow),
        host: "reqresapp.com",
        localAddress: "127.0.0.1",
        method: "GET",
        uri: "/test",
        reqHttpVersion: "1.0",
        target: "target",
        reqHeads: """
    {
    "Origin": "https://mail.superhuman.com",
    "sec-ch-ua-mobile": "?0",
    "Host": "content.googleapis.com",
    "Accept-Encoding": "gzip, deflate, br",
    "sec-ch-ua-platform": "",
    "Sec-Fetch-Site": "cross-site",
    "Connection": "keep-alive",
    "Sec-Fetch-Mode": "cors",
    "Authorization": "Bearer 123",
    "Accept-Language": "en-GB",
    "Accept": "*/*",
    "Sec-Fetch-Dest": "empty"
    }
    """,
        reqEncoding: "gzip",
        reqType: "application/json; charset=utf-8",
        reqBody: """
        {
            "reqRes": true,
            "test": 1
        }
        """,
        rspHttpVersion: "Http/1.1",
    state: "200",
        rspMessage: "ok",
        rspType: "application/json; charset=utf-8",
    rspHeads: """
    {
    "Cache-Control": "max-age=0, private, must-revalidate",
    "Content-Encoding": "gzip"
    }
    """,
    rspBody: """
    {
        "rsp": true,
        "test": 1,
        "string": "my string",
        "array": ["one", "two", "three"]
    }
    """,
    scheme: "https",
    reqStartTime: NSNumber(value: mockNow + 0.01),
    reqBodyStartTime: NSNumber(value: mockNow + 0.02),
    rspStartTime: NSNumber(value: mockNow + 0.276),      // +31ms for request
    rspEndTime: NSNumber(value: mockNow + 0.309),        // +33ms for response
    connectTime: NSNumber(value: mockNow + 0.008),       // +8ms for queuing
    connectedTime: NSNumber(value: mockNow + 0.009),     // +1ms for DNS
    handshakeEndTime: NSNumber(value: mockNow + 0.147),  // +118ms for TCP
    reqEndTime: NSNumber(value: mockNow + 0.245),        // +98ms for TLS handshake
    uploadTraffic: NSNumber(value: 973),             // 973 bytes sent
    downloadFlow: NSNumber(value: 1264),              // 1.2KB received
    downloadStartTime: NSNumber(value: mockNow + 0.285), // +9ms after rspStartTime for server processing
    downloadEndTime: NSNumber(value: mockNow + 0.309)   // Same as rspEndTime (download completes)
)
