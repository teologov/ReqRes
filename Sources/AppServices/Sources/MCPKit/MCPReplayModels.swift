//
//  MCPReplayModels.swift
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
//  Horizon 3, item 17: `replay_request` — the agent sends a captured request
//  again and reads the new response, instead of creating a rule and waiting
//  for the human to re-trigger it.
//
//  THIS IS THE FIRST TOOL THAT ACTS ON SOMEONE ELSE'S SERVER. Everything
//  else on this surface changes what happens on this Mac; a replay leaves it.
//  Four invariants hold that down, and all four live here so they can be
//  tested without a window, a network or a running app:
//
//  1. IDEMPOTENT METHODS ONLY (GET, HEAD, OPTIONS). A replayed POST can
//     place a second order, send a second email, charge a second time — the
//     ordinary failure of replaying captured traffic, not a hypothetical.
//     Anything else is REFUSED, by name, with what to do instead.
//  2. THE HOST CANNOT CHANGE. The replay carries the captured request's real
//     credentials (redacting them would make it fail), so the one thing it
//     must never do is carry them somewhere they were never sent. An agent
//     may rewrite the path and the query; a different host is a 400.
//  3. ITS OWN SEVERITY, ABOVE EVERYTHING ELSE (`.actsOnThirdParty`), which
//     the standing grant cannot cover: "allow all agent changes" is a
//     statement about THIS app, and must not silently become "send that
//     request again".
//  4. THE RESPONSE COMES BACK REDACTED, like every other read. The request
//     goes out in the clear; nothing unredacted comes back.
//

import Foundation

public enum MCPReplayLimits {
    /// How long one replay may take on the wire. Well inside the client's
    /// own budget (`MCPBridgeClient.writeTimeout` plus this), so a slow
    /// server times out with a message rather than the agent giving up on a
    /// request that is still in flight.
    /// 12 seconds, and the number is a BUDGET, not a preference.
    ///
    /// The whole call is consent (up to `MCPLimits.consentTimeout`, 45s) plus
    /// this, and `MCPLimits.consentTimeout` was itself sized to stay under the
    /// ~60s a client like Claude Desktop waits before giving up on a tool. At
    /// 30s the worst case was 75s: the client gives up while the request is
    /// already on the wire, the agent retries, a second panel appears, and it
    /// goes out twice. Idempotent-only is what makes that survivable rather
    /// than harmful — it is not a reason to leave the arithmetic wrong.
    public static let timeout: TimeInterval = 12
    /// How much of the response body is read back. The preview cap on the way
    /// out is smaller still (`MCPLimits.bodyPreviewMaxBytes`); this one bounds
    /// what the app holds in memory for a replay of something large.
    public static let maxBodyBytes = 1_048_576
    /// Agent-supplied header edits. Bounded because every one of them is
    /// rendered in the approval panel the human is reading to decide.
    public static let maxHeaderEdits = 32
}

// MARK: - What an agent sends

/// What an agent asks ReqRes to send again.
public struct MCPReplayRequest: Codable, Equatable, Sendable {
    /// A uid from `list_sessions` — a session in the CURRENT run.
    public var uid: String
    /// Replace the method. Must still be idempotent (GET, HEAD, OPTIONS).
    public var method: String?
    /// Replace the full URL. Same scheme and host as the captured request:
    /// the path and query are the agent's to change, the destination is not.
    public var url: String?
    /// Headers set on top of the captured ones, by name.
    public var headers: [String: String]?
    /// Captured headers to drop before sending (case-insensitive).
    public var removeHeaders: [String]?

    public init(
        uid: String,
        method: String? = nil,
        url: String? = nil,
        headers: [String: String]? = nil,
        removeHeaders: [String]? = nil
    ) {
        self.uid = uid
        self.method = method
        self.url = url
        self.headers = headers
        self.removeHeaders = removeHeaders
    }
}

// MARK: - How it went out

/// Which way the replay reached the server.
public enum MCPReplayRoute: String, Codable, Sendable {
    /// Through ReqRes's own proxy on 127.0.0.1. The user's rules apply to it
    /// and it lands in the traffic list like any other request.
    case proxy
    /// Straight out. Capture was not running, so there was no proxy to go
    /// through — which means no rule applied and nothing was recorded. An
    /// agent that does not know which happened cannot explain "my mock did
    /// not apply", so the result always says.
    case direct
    /// Through the proxy, but RELAYED without being decrypted: the ReqRes CA
    /// is not installed AND trusted, so the extension intercepts no HTTPS
    /// (core C7/C8, decision D7). The server's own certificate reached the
    /// replay, TLS succeeded, no rule applied, and only a relay row — the
    /// connection's endpoint and bytes — was recorded.
    case relayedWithoutCertificate = "relayed_without_certificate"
    /// Through the proxy, but the host is on Settings ▸ Capture's exclusion
    /// list: relayed untouched, no rule applied, nothing recorded at all.
    case relayedExcluded = "relayed_excluded"

    /// Which way a replay goes, decided before it is sent (release review,
    /// 2026-09-29: the result used to say "rules applied" whenever capture
    /// ran, which is false for the no-CA default and for excluded hosts).
    /// `caInstalledAndTrusted` nil means the app could not read it — then
    /// the proxy route is assumed, as before.
    public static func decide(captureRunning: Bool, scheme: String, excluded: Bool,
                              caInstalledAndTrusted: Bool?) -> MCPReplayRoute {
        guard captureRunning else { return .direct }
        if excluded { return .relayedExcluded }
        if scheme.lowercased() == "https", caInstalledAndTrusted == false { return .relayedWithoutCertificate }
        return .proxy
    }
}

/// The resolved request, ready to send. Built here from the captured session
/// plus the agent's overrides so that what the human approves and what goes
/// on the wire are the same object.
///
/// `headers` holds the REAL captured values, credentials included: this
/// travels app-ward, never agent-ward.
public struct MCPReplayPlan: Equatable, Sendable {
    public var method: String
    public var url: String
    public var scheme: String
    public var host: String
    public var headers: [String: String]
    /// The session this was built from, for the audit line and the result.
    public var sourceUID: String
    /// Names carried over from the capture that look like credentials. The
    /// approval panel says these out loud — "replays a request" hides the
    /// only fact that makes a replay dangerous.
    public var carriedCredentialHeaders: [String]
    /// What the agent changed, one line each, for the panel.
    public var modifications: [String]

    public init(
        method: String,
        url: String,
        scheme: String,
        host: String,
        headers: [String: String],
        sourceUID: String,
        carriedCredentialHeaders: [String] = [],
        modifications: [String] = []
    ) {
        self.method = method
        self.url = url
        self.scheme = scheme
        self.host = host
        self.headers = headers
        self.sourceUID = sourceUID
        self.carriedCredentialHeaders = carriedCredentialHeaders
        self.modifications = modifications
    }
}

/// What the app got back, unredacted. The router turns this into an
/// `MCPReplayResult` and redacts it on the way out — the seam must not be
/// the thing that decides what an agent may see.
public struct MCPReplayResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    /// Text, or a description of a binary body — never raw bytes.
    public var bodyPreview: String?
    public var bodyTruncated: Bool
    public var bodyBytes: Int
    public var contentType: String?
    public var durationMs: Double
    public var route: MCPReplayRoute
    /// Where the request finished after redirects, when that differs.
    public var finalURL: String?

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        bodyPreview: String? = nil,
        bodyTruncated: Bool = false,
        bodyBytes: Int = 0,
        contentType: String? = nil,
        durationMs: Double = 0,
        route: MCPReplayRoute,
        finalURL: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.bodyPreview = bodyPreview
        self.bodyTruncated = bodyTruncated
        self.bodyBytes = bodyBytes
        self.contentType = contentType
        self.durationMs = durationMs
        self.route = route
        self.finalURL = finalURL
    }
}

/// What leaves the bridge: the new exchange in the same shape as a captured
/// one, plus the two facts an agent cannot infer — how it was sent, and
/// whether what it is reading was masked.
public struct MCPReplayResult: Codable, Equatable {
    /// The replayed exchange. Its `uid` is the SOURCE session's: the replay
    /// itself has no uid of its own here. When it went through the proxy it
    /// was captured too, under a new uid, and `list_sessions` is where that
    /// one shows up.
    public var session: MCPSessionDetail
    public var route: MCPReplayRoute
    /// The uid this was replayed from.
    public var replayedFrom: String
    /// True when the values in `session` were masked on the way out. False
    /// means the user excepted this host from redaction, not that nothing
    /// sensitive was there.
    public var redacted: Bool

    public init(session: MCPSessionDetail, route: MCPReplayRoute, replayedFrom: String, redacted: Bool) {
        self.session = session
        self.route = route
        self.replayedFrom = replayedFrom
        self.redacted = redacted
    }
}

// MARK: - The seam the app implements

/// Sends a replay. Synchronous like the other write seams, and called on a
/// bridge connection queue — never on main.
///
/// Optional on `MCPWriteSeams` for the same reason the exporter is: a build
/// that has not wired it answers 503 for this one route and keeps every
/// other write working.
public protocol MCPReplaying {
    func replay(_ plan: MCPReplayPlan) throws -> MCPReplayResponse
}

// MARK: - Validation and plan building

public enum MCPReplayValidation {
    /// What v1 will replay. Idempotent in the RFC 9110 sense: sending it
    /// twice is meant to be indistinguishable from sending it once.
    ///
    /// PUT and DELETE are idempotent by that definition too, and are still
    /// refused: idempotent means the SERVER's state ends up the same, not
    /// that nothing happened — a replayed DELETE still deletes, and a
    /// replayed PUT still overwrites whatever the user changed in between.
    /// The safe set is the one that is also SAFE: read-only.
    public static let allowedMethods = ["GET", "HEAD", "OPTIONS"]

    /// Headers the transport owns. Carrying a captured `Content-Length` or
    /// `Host` over into a new request is how a replay turns into a malformed
    /// one — URLSession sets these itself, and a stale value either conflicts
    /// or is silently dropped depending on the OS.
    static let transportOwnedHeaders: Set<String> = [
        "host", "content-length", "connection", "transfer-encoding",
        "keep-alive", "upgrade", "expect", "te", "trailer",
        "proxy-authorization", "proxy-connection",
    ]

    /// The method, upper-cased, or a refusal that NAMES it and says what to
    /// do instead. The name matters: an agent told "unsupported method" tries
    /// again; one told "POST is refused" reports it to the user.
    public static func validatedMethod(_ raw: String) throws -> String {
        let method = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !method.isEmpty else {
            throw MCPWriteError.invalid("method cannot be empty. Replay accepts \(allowedMethods.joined(separator: ", ")).")
        }
        guard allowedMethods.contains(method) else {
            throw MCPWriteError.invalid(
                "\(method) cannot be replayed. Sending a captured \(method) again can repeat whatever it did the first time — place a second order, send a second email, delete something twice — on a server ReqRes does not control. "
                + "Replay accepts \(allowedMethods.joined(separator: ", ")) only. "
                + "To exercise a \(method) endpoint, either create_rule/mock_from_session and have the user trigger it once, or ask the user to re-send it themselves."
            )
        }
        return method
    }

    /// The URL to send to. Defaults to the captured one; an override may
    /// change the path and query and nothing else.
    ///
    /// The host check is the load-bearing one. The replay carries the
    /// captured request's real Authorization and Cookie headers, so allowing
    /// the host to change would turn this tool into a credential exfiltration
    /// path: capture a login, replay it at a host the agent picked, and the
    /// token has left. There is no version of that which consent copy fixes,
    /// because the panel would be showing a plausible-looking hostname.
    public static func validatedURL(
        _ raw: String?,
        capturedURL: String,
        capturedHost: String,
        capturedScheme fallbackScheme: String
    ) throws -> URLComponents {
        // An EMPTY captured URL is refused rather than rebuilt: the scheme
        // fallback below exists for a row that has a host and a path but no
        // scheme, and turning "" into the host's root would replay a request
        // to a path nobody captured.
        guard !capturedURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPWriteError.invalid("The captured session's URL is empty, so there is nothing to replay. Pick another session.")
        }
        guard var captured = URLComponents(string: capturedURL) else {
            throw MCPWriteError.invalid("The captured session's URL (\(capturedURL)) cannot be parsed, so there is nothing to replay. Pick another session.")
        }
        // A captured URL really can arrive with no scheme: the core writes
        // `host + uri` when the session's scheme is empty
        // (SessionEncodable.fullUrl), and those rows used to be unreplayable
        // with an error blaming the URL. The summary carries the scheme, so
        // rebuild rather than refuse — and only fall back to https when even
        // that is empty, because a replay must be sent SOMEWHERE and the
        // plaintext choice is not the safe default.
        if captured.scheme == nil || captured.scheme?.isEmpty == true {
            let scheme = fallbackScheme.isEmpty ? "https" : fallbackScheme.lowercased()
            let rebuilt = "\(scheme)://\(capturedURL)"
            guard let parsed = URLComponents(string: rebuilt) else {
                throw MCPWriteError.invalid("The captured session's URL (\(capturedURL)) cannot be parsed, so there is nothing to replay. Pick another session.")
            }
            captured = parsed
        }
        guard let capturedScheme = captured.scheme else {
            throw MCPWriteError.invalid("The captured session's URL (\(capturedURL)) has no scheme, so there is nothing to replay against.")
        }
        // The summary's host is the authoritative one; a captured URL is
        // occasionally path-only for HTTP rows.
        let host = (captured.host?.isEmpty == false ? captured.host! : capturedHost)
        guard !host.isEmpty else {
            throw MCPWriteError.invalid("The captured session has no host recorded, so there is nothing to replay against.")
        }

        guard let override = raw?.trimmingCharacters(in: .whitespaces), !override.isEmpty else {
            var resolved = captured
            resolved.host = host
            resolved.scheme = capturedScheme
            return resolved
        }
        guard let parsed = URLComponents(string: override), let scheme = parsed.scheme, let overrideHost = parsed.host else {
            throw MCPWriteError.invalid("url must be a full URL, e.g. \(capturedScheme)://\(host)/v1/users?limit=1")
        }
        guard parsed.user == nil, parsed.password == nil else {
            throw MCPWriteError.invalid("url must not carry a username or password. Send credentials as headers if you mean to.")
        }
        guard overrideHost.caseInsensitiveCompare(host) == .orderedSame else {
            throw MCPWriteError.invalid(
                "url must stay on \(host) — a replay carries the captured request's own credentials, and sending those to \(overrideHost) would put them somewhere they have never been. "
                + "Change the path and query instead: \(capturedScheme)://\(host)\(parsed.path.isEmpty ? "/" : parsed.path)"
            )
        }
        guard scheme.caseInsensitiveCompare(capturedScheme) == .orderedSame else {
            throw MCPWriteError.invalid("url must use \(capturedScheme), the scheme the request was captured on. Replaying an \(capturedScheme) request over \(scheme.lowercased()) would change how its credentials travel.")
        }
        if let port = parsed.port, port != captured.port {
            throw MCPWriteError.invalid("url must keep the captured port (\(captured.port.map(String.init) ?? "the default")). Change the path and query only.")
        }
        var resolved = parsed
        resolved.scheme = capturedScheme
        resolved.host = host
        resolved.port = captured.port
        return resolved
    }

    /// The header set that actually goes out: the captured headers, minus the
    /// ones the transport owns, minus what the agent dropped, plus what it
    /// set.
    static func resolvedHeaders(
        captured: [String: String],
        overrides: [String: String],
        removing: [String]
    ) throws -> [String: String] {
        guard overrides.count + removing.count <= MCPReplayLimits.maxHeaderEdits else {
            throw MCPReplayValidation.tooManyEdits
        }
        try MCPWriteValidation.validateHeaders(overrides, label: "headers")
        for name in removing {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains(":"), !MCPWriteValidation.hasLineBreak(trimmed) else {
                throw MCPWriteError.invalid("remove_headers contains an invalid header name '\(name)'.")
            }
        }
        for name in overrides.keys where transportOwnedHeaders.contains(name.lowercased()) {
            throw MCPWriteError.invalid("\(name) is set by the transport and cannot be overridden on a replay. Change the url instead if you meant to reach a different path.")
        }

        let dropped = Set(removing.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var headers: [String: String] = [:]
        for (name, value) in captured {
            let lower = name.lowercased()
            if transportOwnedHeaders.contains(lower) || dropped.contains(lower) { continue }
            headers[name] = value
        }
        // An override replaces a captured header whatever its capitalisation:
        // two entries differing only in case would both reach URLSession and
        // the last one set wins silently.
        for (name, value) in overrides {
            let lower = name.lowercased()
            for existing in headers.keys where existing.lowercased() == lower {
                headers.removeValue(forKey: existing)
            }
            headers[name] = value
        }
        return headers
    }

    static var tooManyEdits: MCPWriteError {
        .invalid("A replay may change at most \(MCPReplayLimits.maxHeaderEdits) headers; every one of them is shown to the user for approval.")
    }
}

extension MCPReplayValidation {
    /// Refuses a session that was CAPTURED with a method a replay must not
    /// repeat, whatever the agent asks the wire method to be.
    public static func validateCapturedMethod(_ method: String) throws {
        let normalized = method.trimmingCharacters(in: .whitespaces).uppercased()
        guard !normalized.isEmpty, !allowedMethods.contains(normalized) else { return }
        throw MCPWriteError.invalid(
            "That session is a captured \(normalized), so it cannot be replayed even as a GET. "
            + "The endpoint was built to change something, and many act on the query string whatever the verb is. "
            + "Use create_rule or mock_from_session and have the user trigger it once."
        )
    }
}

extension MCPReplayPlan {
    /// Builds the request that will be sent, or throws the refusal the agent
    /// should read. Pure: given the same captured session and the same
    /// overrides it always produces the same plan, which is what makes the
    /// refusals testable without a network.
    public static func make(replaying detail: MCPSessionDetail, request: MCPReplayRequest) throws -> MCPReplayPlan {
        let captured = detail.summary
        // BOTH are checked, and that is the point. Validating only the
        // override let a captured POST through by passing method: "GET" —
        // the wire method was then safe, but the target was still an endpoint
        // built to change something, and plenty of them act on the query
        // string regardless of verb (`/api/delete?id=5`). SKILL.md promised
        // this could not happen; now it cannot.
        try MCPReplayValidation.validateCapturedMethod(captured.method)
        let method = try MCPReplayValidation.validatedMethod(request.method ?? captured.method)
        let components = try MCPReplayValidation.validatedURL(
            request.url,
            capturedURL: captured.url,
            capturedHost: captured.host,
            capturedScheme: captured.scheme
        )
        guard let url = components.string, let host = components.host, let scheme = components.scheme else {
            throw MCPWriteError.invalid("The resulting URL is not valid. Send url as a full URL such as https://\(captured.host)/v1/users.")
        }
        let overrides = request.headers ?? [:]
        let removing = request.removeHeaders ?? []
        let headers = try MCPReplayValidation.resolvedHeaders(
            captured: detail.requestHeaders,
            overrides: overrides,
            removing: removing
        )

        var modifications: [String] = []
        if method != captured.method.uppercased() {
            modifications.append("Method changed: \(captured.method.uppercased()) → \(method)")
        }
        if url != captured.url {
            modifications.append("URL changed: \(Self.truncate(captured.url)) → \(Self.truncate(url))")
        }
        for (name, value) in overrides.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            // The VALUE, not just the name: "sets a header" is exactly the
            // description that hides an agent attaching its own bearer token.
            modifications.append("Header set: \(name): \(Self.truncate(value, limit: 120))")
        }
        for name in removing.sorted() {
            modifications.append("Header removed: \(name)")
        }

        return MCPReplayPlan(
            method: method,
            url: url,
            scheme: scheme.lowercased(),
            host: host,
            headers: headers,
            sourceUID: captured.uid,
            carriedCredentialHeaders: headers.keys
                .filter { MCPRedactor.isSensitiveName($0) && overrides[$0] == nil }
                .sorted { $0.lowercased() < $1.lowercased() },
            modifications: modifications
        )
    }

    /// The one line the approval panel leads with. Names the method, the host
    /// and the path, because "replay a request" tells the human nothing they
    /// can decide on.
    public var consentSummary: String {
        "Send \(method) \(Self.truncate(url)) to the real server again"
    }

    /// The rest of the panel: what is being carried, and what the agent
    /// changed.
    public var consentDetails: [String] {
        var details: [String] = ["Replayed from the captured session \(sourceUID)"]
        if headers.isEmpty {
            details.append("No headers are carried over.")
        } else {
            details.append("Carries \(headers.count) header\(headers.count == 1 ? "" : "s") from the captured request.")
        }
        if !carriedCredentialHeaders.isEmpty {
            // The whole reason a replay works, and the whole reason it is
            // worth a second look.
            details.append("Including the captured credentials: \(carriedCredentialHeaders.joined(separator: ", ")) — these are sent to the server exactly as they were the first time.")
        }
        details.append(contentsOf: modifications)
        return details
    }

    static func truncate(_ text: String, limit: Int = 160) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

extension MCPReplayResponse {
    /// The replayed exchange as a session detail, so it renders, redacts and
    /// caps through exactly the same path a captured one does. The request
    /// headers included are the ones that WERE SENT — masked on the way out
    /// like everything else, so the agent can see the shape of what it sent
    /// without reading the credential back.
    public func detail(for plan: MCPReplayPlan, now: Date = Date()) -> MCPSessionDetail {
        let summary = MCPSessionSummary(
            uid: plan.sourceUID,
            host: plan.host,
            method: plan.method,
            url: finalURL ?? plan.url,
            scheme: plan.scheme,
            statusCode: statusCode,
            startedAt: now,
            durationMs: durationMs,
            responseBodySize: bodyBytes,
            contentType: contentType
        )
        return MCPSessionDetail(
            summary: summary,
            requestHeaders: plan.headers,
            responseHeaders: headers,
            responseBodyPreview: bodyPreview,
            responseBodyTruncated: bodyTruncated
        )
    }
}
