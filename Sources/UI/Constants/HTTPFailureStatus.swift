//
//  HTTPFailureStatus.swift
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

enum HTTPFailureStatus: Int, CaseIterable, Identifiable {
    var id: Self {
        return self
    }
    case badRequest = 400
    case unauthorized = 401
    case paymentRequired = 402
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case notAcceptable = 406
    case proxyAuthenticationRequired = 407
    case requestTimeout = 408
    case conflict = 409
    case gone = 410
    case lengthRequired = 411
    case preconditionFailed = 412
    case payloadTooLarge = 413
    case uriTooLong = 414
    case unsupportedMediaType = 415
    case rangeNotSatisfiable = 416
    case expectationFailed = 417
    case imATeapot = 418
    case misdirectedRequest = 421
    case unprocessableEntity = 422
    case locked = 423
    case failedDependency = 424
    case tooEarly = 425
    case upgradeRequired = 426
    case preconditionRequired = 428
    case tooManyRequests = 429
    case requestHeaderFieldsTooLarge = 431
    case unavailableForLegalReasons = 451
    case internalServerError = 500
    case notImplemented = 501
    case badGateway = 502
    case serviceUnavailable = 503
    case gatewayTimeout = 504
    case httpVersionNotSupported = 505
    case variantAlsoNegotiates = 506
    case insufficientStorage = 507
    case loopDetected = 508
    case notExtended = 510
    case networkAuthenticationRequired = 511
    
    var description: String {
        switch self {
        case .badRequest:
            return "400 Bad Request"
        case .unauthorized:
            return "401 Unauthorized"
        case .paymentRequired:
            return "402 Payment Required"
        case .forbidden:
            return "403 Forbidden"
        case .notFound:
            return "404 Not Found"
        case .methodNotAllowed:
            return "405 Method Not Allowed"
        case .notAcceptable:
            return "406 Not Acceptable"
        case .proxyAuthenticationRequired:
            return "407 Proxy Authentication Required"
        case .requestTimeout:
            return "408 Request Timeout"
        case .conflict:
            return "409 Conflict"
        case .gone:
            return "410 Gone"
        case .lengthRequired:
            return "411 Length Required"
        case .preconditionFailed:
            return "412 Precondition Failed"
        case .payloadTooLarge:
            return "413 Payload Too Large"
        case .uriTooLong:
            return "414 URI Too Long"
        case .unsupportedMediaType:
            return "415 Unsupported Media Type"
        case .rangeNotSatisfiable:
            return "416 Range Not Satisfiable"
        case .expectationFailed:
            return "417 Expectation Failed"
        case .imATeapot:
            return "418 I'm a teapot"
        case .misdirectedRequest:
            return "421 Misdirected Request"
        case .unprocessableEntity:
            return "422 Unprocessable Entity"
        case .locked:
            return "423 Locked"
        case .failedDependency:
            return "424 Failed Dependency"
        case .tooEarly:
            return "425 Too Early"
        case .upgradeRequired:
            return "426 Upgrade Required"
        case .preconditionRequired:
            return "428 Precondition Required"
        case .tooManyRequests:
            return "429 Too Many Requests"
        case .requestHeaderFieldsTooLarge:
            return "431 Request Header Fields Too Large"
        case .unavailableForLegalReasons:
            return "451 Unavailable For Legal Reasons"
        case .internalServerError:
            return "500 Internal Server Error"
        case .notImplemented:
            return "501 Not Implemented"
        case .badGateway:
            return "502 Bad Gateway"
        case .serviceUnavailable:
            return "503 Service Unavailable"
        case .gatewayTimeout:
            return "504 Gateway Timeout"
        case .httpVersionNotSupported:
            return "505 HTTP Version Not Supported"
        case .variantAlsoNegotiates:
            return "506 Variant Also Negotiates"
        case .insufficientStorage:
            return "507 Insufficient Storage"
        case .loopDetected:
            return "508 Loop Detected"
        case .notExtended:
            return "510 Not Extended"
        case .networkAuthenticationRequired:
            return "511 Network Authentication Required"
        }
    }
}
