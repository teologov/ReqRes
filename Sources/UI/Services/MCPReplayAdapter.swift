//
//  MCPReplayAdapter.swift
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
//  Horizon 3, item 17: the app side of `replay_request`. Everything that
//  decides WHETHER a replay may happen is in MCPKit and has already run by
//  the time this is called — the method was checked, the host was pinned to
//  the captured one, and a human approved the exact plan below. This type
//  only puts it on the wire and reports what came back.
//
//  THE ROUTE IS THE DESIGN DECISION HERE. While capture is running the
//  replay goes THROUGH ReqRes's own proxy on 127.0.0.1:8034, which buys two
//  things that are worth the complication:
//
//   * the user's own rules apply to it, so an agent testing a mock is
//     testing the mock rather than bypassing it;
//   * it is captured, so the replay shows up in the traffic list like any
//     other request and the user can see what their agent sent.
//
//  With capture stopped there is no proxy to use, so it goes direct — and
//  the result says which happened, because "my mock did not apply" is
//  otherwise an unsolvable mystery for the agent AND the user.
//
//  Going through the proxy is not the same as being intercepted. Since
//  1.1.0 (core C7/C8, decision D7) the extension decrypts only while the
//  ReqRes CA is installed AND trusted; otherwise every HTTPS connection is
//  RELAYED — the server's own certificate reaches the replay, TLS succeeds,
//  no rule applies and only a relay row is recorded. An excluded host is
//  relayed and not recorded at all. `MCPReplayRoute.decide` names both, so
//  the result never says "rules applied" when none could (release review,
//  2026-09-29).
//

import Foundation
import MCPKit
import NetworkExtension
import Utils
import XReqResCore

struct MCPReplayAdapter: MCPReplaying {
    func replay(_ plan: MCPReplayPlan) throws -> MCPReplayResponse {
        guard let url = URL(string: plan.url) else {
            throw MCPWriteError.invalid("The replay URL could not be built from \(plan.url).")
        }
        // Read once, before the request: the route reported back has to be
        // the one actually used, and the tunnel can change state underneath
        // a long replay.
        let (running, excludedHosts) = MCPSync.onMain {
            (AppState.shared.vpnStatus == .connected, MainActor.assumeIsolated { ExcludedHostsSettings.shared.list })
        }
        let route = MCPReplayRoute.decide(
            captureRunning: running,
            scheme: plan.scheme,
            excluded: excludedHosts.excludes(plan.host),
            caInstalledAndTrusted: running && plan.scheme.lowercased() == "https" ? Self.certificateInstalledAndTrusted() : nil
        )

        var request = URLRequest(url: url)
        request.httpMethod = plan.method
        // A cached answer is not a replay. The whole point is to see what the
        // server says NOW, after whatever the agent changed.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = MCPReplayLimits.timeout
        for (name, value) in plan.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        // A DELEGATE, not a bare session: without one, URLSession follows
        // redirects itself and the redirected request keeps the headers.
        // MEASURED on this machine (macOS 27, CFNetwork 3896): a 302 to a
        // different host delivered `Cookie` and `X-Api-Key` to the second
        // host — CFNetwork strips only `Authorization`. Since the agent picks
        // the path and query, any open redirect on the captured host would
        // have turned this tool into a way to post someone's session cookie
        // to a host of the agent's choosing, which is exactly what pinning
        // the host was supposed to prevent.
        let pin = MCPReplayRedirectPin(plan: plan)
        let session = URLSession(configuration: Self.configuration(for: route), delegate: pin, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let started = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try MCPSync.wait { try await session.data(for: request) }
        } catch {
            throw Self.failure(error, route: route, plan: plan)
        }
        let durationMs = Date().timeIntervalSince(started) * 1000

        guard let http = response as? HTTPURLResponse else {
            throw MCPWriteError.failed("The replay produced no HTTP response. Nothing was recorded.")
        }
        let headers = Self.headers(from: http)
        let contentType = headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        let body = Self.bodyPreview(data, contentType: contentType)

        return MCPReplayResponse(
            statusCode: http.statusCode,
            headers: headers,
            bodyPreview: body.text,
            bodyTruncated: body.truncated,
            bodyBytes: data.count,
            contentType: contentType,
            durationMs: durationMs,
            route: route,
            // Same-host redirects are followed, so the agent is told where it
            // ended up rather than where it aimed. A cross-host one is NOT
            // followed (see the pin above) and arrives here as the 3xx itself,
            // which is the right thing for a debugging tool to show anyway.
            finalURL: http.url.map(\.absoluteString) != plan.url ? http.url?.absoluteString : nil
        )
    }

    /// An ephemeral session every time, with the app's cookie jar left out.
    ///
    /// The captured `Cookie` header is what a replay is supposed to send —
    /// the one the request carried. A shared jar would quietly add or replace
    /// cookies the user never sent, which makes the replay a different
    /// request from the one the human approved.
    /// Installed AND trusted — what the extension decrypts on (core
    /// CertHelper.caState). Nil when the keychain could not be read.
    private static func certificateInstalledAndTrusted() -> Bool? {
        guard CertHelper.getInstalledCertificate() != nil else { return false }
        return MCPStatusAdapter.certificateTrusted()
    }

    private static func configuration(for route: MCPReplayRoute) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = MCPReplayLimits.timeout
        configuration.timeoutIntervalForResource = MCPReplayLimits.timeout
        if route != .direct {
            // The loopback listener the extension's MitmService binds. Both
            // halves are set because URLSession picks by the request's own
            // scheme, and a replay of an https session must go through the
            // CONNECT path or it is not the same request.
            // The running capture's port (Settings ▸ Capture can change it).
            let port = CaptureProxyPort.active(tunnelUp: true)
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        return configuration
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String else { continue }
            headers[name] = String(describing: value)
        }
        return headers
    }

    /// Text, or a description of the bytes. Binary bodies are described and
    /// never inlined, exactly as captured sessions are (`MCPSessionAdapter`),
    /// so a replayed image cannot blow up an agent's context.
    private static func bodyPreview(_ data: Data, contentType: String?) -> (text: String?, truncated: Bool) {
        guard !data.isEmpty else { return (nil, false) }
        // Trimmed back to a character boundary before it is decoded: a cut at
        // an arbitrary byte offset lands mid-UTF-8-sequence often enough, and
        // the decode then fails and reports a perfectly ordinary JSON body as
        // "[binary body omitted]". Dropping up to three bytes off the end of a
        // preview costs nothing; mislabelling the body costs the agent the
        // answer it asked for.
        let slice = Self.trimmedToCharacterBoundary(data.prefix(MCPReplayLimits.maxBodyBytes))
        if let text = String(data: slice, encoding: .utf8) {
            return (text, data.count > slice.count)
        }
        let type = contentType?.isEmpty == false ? contentType! : "binary"
        return ("[binary body omitted — \(type), \(data.count) bytes]", false)
    }

    /// Turns a transport failure into something the agent can act on. A bare
    /// "An SSL error has occurred" sends it looking at the server, when the
    /// likely cause is local and named by `diagnose_setup`.
    private static func failure(_ error: Error, route: MCPReplayRoute, plan: MCPReplayPlan) -> MCPWriteError {
        let urlError = error as? URLError
        switch urlError?.code {
        case .some(.timedOut):
            return .failed("\(plan.host) did not answer within \(Int(MCPReplayLimits.timeout))s. The request was sent; whether the server acted on it is unknown.")
        case .some(.secureConnectionFailed), .some(.serverCertificateUntrusted),
             .some(.serverCertificateHasBadDate), .some(.serverCertificateNotYetValid),
             .some(.serverCertificateHasUnknownRoot), .some(.clientCertificateRejected):
            guard route == .proxy else {
                return .failed("TLS to \(plan.host) failed: \(error.localizedDescription)")
            }
            // Intercepted: ReqRes re-signed the connection with its CA, which
            // this Mac trusts, so the failure is upstream of ReqRes — the
            // server refused ReqRes (a client certificate, a pinned or broken
            // chain), which the captured row names.
            return .failed(
                "TLS failed on the way through ReqRes's proxy. ReqRes re-signs with its CA, which this Mac trusts, so the likely cause is between ReqRes and \(plan.host) (it asks for a client certificate, or its certificate did not verify) — list_sessions shows the replay's row with the reason. "
                + "(\(error.localizedDescription))"
            )
        case .some(.cannotConnectToHost), .some(.cannotFindHost):
            guard route != .direct else {
                return .failed("Could not reach \(plan.host): \(error.localizedDescription)")
            }
            return .failed("Could not reach ReqRes's proxy on 127.0.0.1:\(CaptureProxyPort.active(tunnelUp: true)) although capture is running. Call diagnose_setup — it checks that port with a real connection. (\(error.localizedDescription))")
        case .some(.cancelled):
            return .failed("The replay was cancelled before it completed.")
        default:
            return .failed("The replay to \(plan.host) failed: \(error.localizedDescription)")
        }
    }
}

/// Refuses to follow a redirect that leaves the host the plan pinned.
///
/// A replay carries the captured request's real credentials — that is what
/// makes it useful — so where those credentials are allowed to travel is the
/// security boundary of the whole feature. The plan pins scheme, host and
/// port; this is what keeps the SERVER from moving them anyway.
private final class MCPReplayRedirectPin: NSObject, URLSessionTaskDelegate {
    private let plan: MCPReplayPlan

    init(plan: MCPReplayPlan) {
        self.plan = plan
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url,
              let pinned = URL(string: plan.url),
              target.host?.lowercased() == pinned.host?.lowercased(),
              target.scheme?.lowercased() == pinned.scheme?.lowercased(),
              target.port == pinned.port
        else {
            // nil means "stop here and hand me the 3xx". The agent sees the
            // redirect and its Location header and can decide for itself,
            // which is more useful than silently following it would have been.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

extension MCPReplayAdapter {
    /// Drops up to three trailing bytes so `data` ends on a whole UTF-8
    /// scalar. A continuation byte is `10xxxxxx`; a truncated sequence can
    /// only be that long.
    static func trimmedToCharacterBoundary(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var end = data.endIndex
        var dropped = 0
        while end > data.startIndex, dropped < 4 {
            let byte = data[data.index(before: end)]
            if byte & 0b1100_0000 == 0b1000_0000 {   // continuation byte
                end = data.index(before: end)
                dropped += 1
                continue
            }
            // A lead byte: keep it only if its whole sequence is present.
            let expected: Int
            switch byte {
            case 0x00...0x7F: expected = 1
            case 0xC0...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF7: expected = 4
            default: return data.prefix(upTo: data.index(before: end))
            }
            let available = data.distance(from: data.index(before: end), to: data.endIndex)
            return available >= expected ? data : data.prefix(upTo: data.index(before: end))
        }
        return data.prefix(upTo: end)
    }
}
