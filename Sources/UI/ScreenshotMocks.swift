//
//  ScreenshotMocks.swift
//  ReqRes
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
//  A believable capture for screenshots, DEBUG only and behind
//  `REQRES_SCREENSHOT=1` so an ordinary Debug run is unaffected.
//
//  Everything here is seeded IN MEMORY — no host, rule or session is written to
//  the store. Debug and Release share one bundle id and one app group, so a
//  seeding path that persisted would push fake hosts and rules into an
//  installed copy of ReqRes.
//
//  The traffic tells the story the product is sold on: someone debugging their
//  own checkout against a third-party API, with a rule already rewriting one
//  response — and, in the App column, WHO made each request: the shop's own
//  debug build, a Brave tab, Safari's traffic under the name it really arrives
//  with, and two claude command-line processes talking to their API (UX spec
//  §12.7 with errata 1). Statuses, sizes and timings are plausible rather
//  than round.
//
//  Every row also carries WHERE it went (destination-map UX spec §10): the
//  server address as the core records it — a BARE IP, no port. The shop's
//  API answers from Frankfurt (DE); Stripe and Anthropic from the US, the CDN (a Fastly edge) from Canada per DB-IP, the rest from the
//  US; the Vite dev server is this Mac; a warehouse box on the office network
//  is Local Network; and the checkout row that the OVERRIDE rule answers has
//  no address at all, because no upstream connection was ever made — the
//  honest Unknown. The `REQRES_UI_PROBE=destinations` probe prints each
//  row's resolved token, so a table that disagrees is visible, not assumed.
//

#if DEBUG

import Foundation
import XReqResCore

enum ScreenshotMocks {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["REQRES_SCREENSHOT"] == "1"
    }

    /// Host filters for the sidebar. `hostDbId` is set because rules key off it,
    /// but nothing is saved.
    static func hosts() -> [HostCodable] {
        [
            HostCodable(host: "api.myshop.dev", port: 443, hostDbId: 101, requestProtocol: "https", modelRealId: 101),
            HostCodable(host: "api.stripe.com", port: 443, hostDbId: 102, requestProtocol: "https", modelRealId: 102),
            HostCodable(host: "cdn.myshop.dev", port: 443, hostDbId: 103, requestProtocol: "https", modelRealId: 103),
            HostCodable(host: "localhost", port: 3000, hostDbId: 104, requestProtocol: "http", modelRealId: 104),
        ]
    }

    /// Overrides for the middle pane, one per mode so the column reads as a
    /// real working set rather than a list of the same thing.
    static func rules() -> [RuleCodable] {
        [
            RuleCodable(
                id: UUID(),
                path: "/v1/checkout/session",
                hostId: 101,
                enabled: NSNumber(value: true),
                isRegexp: NSNumber(value: false),
                isWildCard: NSNumber(value: true),
                ruleMode: .OVERRIDE,
                reqProtocol: "https",
                reqMethod: "POST",
                reqHeaders: "[]",
                rspHeaders: "[]",
                rspCode: 500,
                rspBody: """
                {
                  "error": "card_declined",
                  "message": "Your card was declined."
                }
                """,
                rspPath: "",
                modelRealId: 201
            ),
            RuleCodable(
                id: UUID(),
                path: "/v1/cart/items",
                hostId: 101,
                enabled: NSNumber(value: true),
                isRegexp: NSNumber(value: false),
                isWildCard: NSNumber(value: true),
                ruleMode: .MAP_LOCAL,
                reqProtocol: "https",
                reqMethod: "GET",
                reqHeaders: "[]",
                rspHeaders: "[]",
                rspCode: 200,
                rspBody: "",
                rspPath: "~/Fixtures/empty-cart.json",
                modelRealId: 202
            ),
            RuleCodable(
                id: UUID(),
                path: "/v1/*",
                hostId: 101,
                enabled: NSNumber(value: false),
                isRegexp: NSNumber(value: false),
                isWildCard: NSNumber(value: true),
                ruleMode: .EXTEND,
                reqProtocol: "https",
                reqMethod: "GET",
                reqHeaders: "[]",
                rspHeaders: "[]",
                rspCode: 200,
                rspBody: "",
                rspPath: "",
                modelRealId: 203
            ),
        ]
    }

    // MARK: - Processes

    /// The process behind each row. The shop's own API and Stripe are called
    /// by the debug build under test; the CDN by a Brave tab and by Safari —
    /// whose requests arrive from the shared WebKit networking service, not
    /// from Safari, so that is what the column says (errata 1); Anthropic by
    /// two `claude` processes, told apart only by pid; and one row the
    /// extension could not attribute at all.
    private struct Process {
        let name: String
        let pid: Int
        let path: String

        static let myShop = Process(
            name: "MyShop",
            pid: 48213,
            path: "/Users/dev/Library/Developer/Xcode/DerivedData/MyShop-gqxkzvbmxjqhpwbzwzqmfufzcvxi/Build/Products/Debug/MyShop.app/Contents/MacOS/MyShop"
        )
        static let brave = Process(
            name: "Brave Browser",
            pid: 4127,
            path: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/140.1.83.109/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"
        )
        static let webKitNetworking = Process(
            name: "com.apple.WebKit.Networking",
            pid: 40213,
            path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
        )
        static func claude(_ pid: Int) -> Process {
            Process(name: "claude", pid: pid, path: "/usr/local/bin/claude")
        }
    }

    // MARK: - Servers

    /// The address each host answered from, as `SessionCodable.remoteAddress`
    /// carries it: a bare IP literal. `DestinationClassifier` refuses a port
    /// suffix as Unknown, by the core's contract, so none is spelled here.
    private enum Server {
        /// api.myshop.dev — an AWS eu-central-1 address: Germany.
        static let myShop = "3.120.12.34"
        /// api.stripe.com — United States.
        static let stripe = "54.187.174.169"
        /// cdn.myshop.dev — a Fastly edge; DB-IP's 2026-09 table places it in Canada.
        static let cdn = "151.101.1.69"
        /// api.anthropic.com — United States.
        static let anthropic = "160.79.104.10"
        /// The Vite dev server: This Mac.
        static let thisMac = "127.0.0.1"
        /// A warehouse service on the office network: Local Network.
        static let localNetwork = "192.168.1.20"
    }

    private static let myShopUserAgent = "MyShop/2.4.1 (macOS 26.0)"
    private static let braveUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    private static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let claudeUserAgent = "claude-cli/1.0.129 (external, cli)"

    /// Newest last; `SessionState` reverses for display.
    static func sessions() -> [SessionCodable] {
        let now = Date().timeIntervalSince1970
        return [
            session(now - 41.2, "api.myshop.dev", "GET", "/v1/products?collection=autumn&limit=24", 200,
                    ms: 214, up: 486, down: 18_942, type: "application/json",
                    body: productsBody, app: .myShop, server: Server.myShop),
            session(now - 38.9, "cdn.myshop.dev", "GET", "/assets/hero-autumn@2x.webp", 200,
                    ms: 96, up: 312, down: 214_880, type: "image/webp", body: "",
                    app: .brave, server: Server.cdn, userAgent: braveUserAgent),
            session(now - 36.4, "api.myshop.dev", "GET", "/v1/cart/items", 200,
                    ms: 8, up: 402, down: 74, type: "application/json",
                    body: #"{"items":[],"subtotal":0}"#, app: .myShop, server: Server.myShop),
            // Unattributed: a 3ms exchange whose socket was gone before the
            // table could be read. The row the column prints as Unknown.
            session(now - 33.1, "localhost", "GET", "/__vite_ping", 204,
                    ms: 3, up: 168, down: 0, type: "", body: "", scheme: "http", port: 3000,
                    app: nil, server: Server.thisMac, userAgent: braveUserAgent),
            session(now - 30.7, "api.myshop.dev", "POST", "/v1/cart/items", 201,
                    ms: 187, up: 743, down: 512, type: "application/json",
                    body: #"{"id":"li_8Fq2","sku":"AW-2291-M","qty":1,"subtotal":8900}"#, app: .myShop, server: Server.myShop),
            session(now - 29.0, "api.anthropic.com", "POST", "/v1/messages", 200,
                    ms: 2_314, up: 1_842, down: 1_106, type: "application/json",
                    body: messagesBody, app: .claude(9437), server: Server.anthropic,
                    userAgent: claudeUserAgent, requestBody: messagesRequestBody),
            session(now - 27.5, "api.stripe.com", "GET", "/v1/payment_methods?customer=cus_QjN2", 200,
                    ms: 331, up: 604, down: 1_284, type: "application/json",
                    body: paymentMethodsBody, app: .myShop, server: Server.stripe),
            session(now - 24.9, "api.myshop.dev", "GET", "/v1/shipping/quote?postcode=SW1A1AA", 200,
                    ms: 142, up: 458, down: 388, type: "application/json",
                    body: #"{"options":[{"id":"std","label":"Standard","days":3,"price":399}]}"#, app: .myShop, server: Server.myShop),
            session(now - 21.3, "api.myshop.dev", "GET", "/v1/session", 401,
                    ms: 76, up: 512, down: 96, type: "application/json",
                    body: #"{"error":"token_expired"}"#, app: .myShop, server: Server.myShop),
            session(now - 19.8, "api.myshop.dev", "POST", "/v1/auth/refresh", 200,
                    ms: 268, up: 690, down: 742, type: "application/json",
                    body: #"{"access_token":"eyJhbGciOi…","expires_in":3600}"#, app: .myShop, server: Server.myShop),
            // The shop app checking stock on a warehouse box on the office
            // network: the map's Local Network pill, never a dot.
            session(now - 17.4, "192.168.1.20", "GET", "/v1/inventory/AW-2291-M", 200,
                    ms: 23, up: 226, down: 164, type: "application/json",
                    body: #"{"sku":"AW-2291-M","onHand":12,"warehouse":"office"}"#, scheme: "http", port: 8080,
                    app: .myShop, server: Server.localNetwork),
            session(now - 16.2, "api.stripe.com", "POST", "/v1/payment_intents", 200,
                    ms: 512, up: 1_104, down: 2_316, type: "application/json",
                    body: paymentIntentBody, app: .myShop, server: Server.stripe),
            session(now - 14.8, "api.anthropic.com", "POST", "/v1/messages", 200,
                    ms: 1_907, up: 1_640, down: 984, type: "application/json",
                    body: messagesBody, app: .claude(9767), server: Server.anthropic,
                    userAgent: claudeUserAgent, requestBody: messagesRequestBody),
            // Answered by the OVERRIDE rule in `rules()`: 4ms, no upstream
            // connection, so the core recorded no address — the row the
            // Destinations window lists under Unknown.
            session(now - 12.6, "api.myshop.dev", "POST", "/v1/checkout/session", 500,
                    ms: 4, up: 862, down: 88, type: "application/json",
                    body: #"{"error":"card_declined","message":"Your card was declined."}"#, app: .myShop, server: nil),
            session(now - 9.4, "api.myshop.dev", "GET", "/v1/orders/recent", 304,
                    ms: 62, up: 476, down: 0, type: "application/json", body: "", app: .myShop, server: Server.myShop),
            session(now - 6.1, "cdn.myshop.dev", "GET", "/assets/app.6f2c91.js", 200,
                    ms: 118, up: 298, down: 486_204, type: "application/javascript", body: "",
                    app: .webKitNetworking, server: Server.cdn, userAgent: safariUserAgent),
            session(now - 3.4, "api.myshop.dev", "DELETE", "/v1/cart/items/li_8Fq2", 204,
                    ms: 91, up: 388, down: 0, type: "", body: "", app: .myShop, server: Server.myShop),
        ]
    }

    // MARK: - Bodies

    private static let productsBody = """
    {
      "products": [
        {
          "id": "prd_2291",
          "sku": "AW-2291-M",
          "title": "Merino Overshirt",
          "price": 8900,
          "currency": "GBP",
          "inStock": true,
          "sizes": ["S", "M", "L", "XL"]
        },
        {
          "id": "prd_2288",
          "sku": "AW-2288-L",
          "title": "Waxed Canvas Tote",
          "price": 12500,
          "currency": "GBP",
          "inStock": false,
          "sizes": ["One size"]
        }
      ],
      "page": { "limit": 24, "total": 47, "next": "/v1/products?collection=autumn&cursor=cD0y" }
    }
    """

    private static let paymentMethodsBody = """
    {
      "object": "list",
      "data": [
        { "id": "pm_1QaBc2", "type": "card", "card": { "brand": "visa", "last4": "4242", "exp_month": 11, "exp_year": 2029 } }
      ],
      "has_more": false
    }
    """

    private static let paymentIntentBody = """
    {
      "id": "pi_3QdEf4Gh",
      "object": "payment_intent",
      "amount": 9299,
      "currency": "gbp",
      "status": "requires_confirmation",
      "client_secret": "pi_3QdEf4Gh_secret_9Kz",
      "charges": { "data": [], "total_count": 0 }
    }
    """

    private static let messagesRequestBody = """
    {
      "model": "claude-sonnet-4-5",
      "max_tokens": 1024,
      "messages": [
        { "role": "user", "content": "Why does POST /v1/checkout/session return 500 when the card is declined?" }
      ]
    }
    """

    private static let messagesBody = """
    {
      "id": "msg_01Xk9Ff2Qz",
      "type": "message",
      "role": "assistant",
      "model": "claude-sonnet-4-5",
      "content": [
        { "type": "text", "text": "The override rule for /v1/checkout/session answers 500 with card_declined before the request reaches the server." }
      ],
      "stop_reason": "end_turn",
      "usage": { "input_tokens": 412, "output_tokens": 38 }
    }
    """

    // MARK: - Builder

    private static func session(
        _ start: TimeInterval,
        _ host: String,
        _ method: String,
        _ uri: String,
        _ status: Int,
        ms: Int,
        up: Int,
        down: Int,
        type: String,
        body: String,
        scheme: String = "https",
        port: Int = 443,
        app: Process?,
        /// The bare IP the server answered from; nil when no upstream
        /// connection was made (a rule answered). No default, so a new row
        /// has to say where it went.
        server: String?,
        userAgent: String = myShopUserAgent,
        requestBody: String? = nil
    ) -> SessionCodable {
        let duration = Double(ms) / 1000.0
        // A plausible split of the exchange: queue, DNS, TCP, TLS, then the
        // server thinking, then the body arriving.
        let connect = start + duration * 0.04
        let connected = start + duration * 0.07
        let handshake = start + duration * 0.31
        let reqEnd = start + duration * 0.38
        let rspStart = start + duration * 0.82
        let downloadStart = start + duration * 0.86

        let requestHeaders = """
        {
          "Host": "\(host)",
          "User-Agent": "\(userAgent)",
          "Accept": "application/json",
          "Accept-Encoding": "gzip, deflate, br",
          "Authorization": "Bearer sk_live_9f2a…",
          "Content-Type": "application/json",
          "Connection": "keep-alive"
        }
        """

        let responseHeaders = """
        {
          "Content-Type": "\(type.isEmpty ? "text/plain" : type)",
          "Content-Length": "\(down)",
          "Cache-Control": "no-store",
          "x-request-id": "req_\(String(UUID().uuidString.prefix(8)).lowercased())",
          "Server": "nginx"
        }
        """

        return SessionCodable(
            startTime: NSNumber(value: start),
            host: port == 443 ? host : "\(host):\(port)",
            localAddress: "127.0.0.1",
            method: method,
            uri: uri,
            reqHTTPVersion: "HTTP/1.1",
            userAgentProduct: host,
            reqHeaders: requestHeaders,
            reqContentEncoding: "gzip",
            reqContentType: "application/json",
            reqBody: requestBody ?? (method == "POST" ? #"{"sku":"AW-2291-M","qty":1}"# : ""),
            rspHTTPVersion: "HTTP/1.1",
            rspStatus: String(status),
            rspReasonPhrase: message(for: status),
            rspContentType: type,
            rspContentEncoding: "gzip",
            rspContentDisposition: "",
            rspHeaders: responseHeaders,
            rspBody: body,
            scheme: scheme,
            reqStartTime: NSNumber(value: start + duration * 0.01),
            reqBodyStartTime: NSNumber(value: start + duration * 0.02),
            rspStartTime: NSNumber(value: rspStart),
            rspEndTime: NSNumber(value: start + duration),
            connectStartTime: NSNumber(value: connect),
            connectEndTime: NSNumber(value: connected),
            tlsEndTime: NSNumber(value: handshake),
            reqEndTime: NSNumber(value: reqEnd),
            requestBytes: NSNumber(value: up),
            responseBytes: NSNumber(value: down),
            downloadStartTime: NSNumber(value: downloadStart),
            downloadEndTime: NSNumber(value: start + duration),
            processName: app?.name,
            processID: app?.pid,
            processPath: app?.path,
            remoteAddress: server
        )
    }

    private static func message(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 304: return "Not Modified"
        case 401: return "Unauthorized"
        case 500: return "Internal Server Error"
        default: return ""
        }
    }
}

#endif
