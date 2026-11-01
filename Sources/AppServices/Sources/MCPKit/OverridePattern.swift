//
//  OverridePattern.swift
//  ReqRes
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
//  The override form's URL-pattern rules as pure functions, so `swift test`
//  covers the path that once saved every "All traffic" override with an
//  empty path — and so the pattern tester answers what the PROXY does
//  (verified against XReqResCore's GlueHandler/HTTPConnectHandler) rather
//  than a plausible-looking approximation.
//

import Foundation

public enum OverridePattern {

    /// The path as stored on a rule: pathname + query, with a leading slash.
    ///
    /// A wildcard pattern is normalised through `URL` so "path?*" becomes
    /// "/path?*"; anything `URL` rejects (a space, say) is kept as typed with
    /// the slash added. A regex is stored VERBATIM — `^`, `\` and friends are
    /// not URL characters, and running them through `URL(string:)` used to
    /// fail silently and save "".
    public static func storedPath(_ typed: String, isRegex: Bool) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !isRegex else { return trimmed }
        let relative = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        // `percentEncodedPath`/`percentEncodedQuery`, not `path`/`query`: the
        // proxy compares the pattern against the RAW request URI, so decoding
        // here would make "/files/my%20doc.pdf" a pattern that never matches.
        guard let components = URLComponents(string: "https://host.invalid" + relative) else { return relative }
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        let encodedPath = components.percentEncodedPath
        return (encodedPath.isEmpty ? "/" : encodedPath) + query
    }

    /// The path `mock_from_session` scopes its rule to: the captured request's
    /// pathname and query, percent-encoding preserved (the proxy compares the
    /// RAW request URI), on BOTH schemes. Until core C5 plain HTTP matched the
    /// pathname only, so the query was dropped for `http://`; now it matches
    /// `head.uri` with its query, and a derived pattern without it would miss
    /// the very request the mock was made from.
    public static func derivedPath(fromCapturedURL urlString: String) -> String {
        guard let components = URLComponents(string: urlString) else { return "/" }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    /// The pattern string the proxy actually compiles.
    ///
    /// The core builds BOTH sides of the comparison as `scheme://host + …`
    /// (`constructFullURL` in GlueHandler/HTTPConnectHandler): the pattern is
    /// `scheme://host` + the rule's stored path, and the text is
    /// `scheme://host` + the request's URI. So a rule's path is always a
    /// pathname (+query) — a host written into it ends up matched twice.
    public static func proxyPattern(scheme: String, host: String, path: String) -> String {
        "\(scheme.lowercased())://\(host)\(path)"
    }

    /// What the form shows beside the URL field: the pattern as the proxy
    /// will compile it.
    public static func displayed(scheme: String, host: String?, path: String) -> String {
        let typed = path.trimmingCharacters(in: .whitespaces)
        guard let host, !host.isEmpty else { return typed }
        return proxyPattern(scheme: scheme, host: host, path: typed)
    }

    /// Whether a rule with `path` scoped to the URL's own host would match
    /// that URL — the proxy's algorithm, reproduced:
    ///
    ///  * wildcard: the whole `scheme://host + path` is regex-escaped, `*`
    ///    becomes `.*`, and the result is anchored `^…$`;
    ///  * regex: `scheme://host + path` is compiled AS IS and SEARCHED for
    ///    (unanchored) — which is why a leading `^` in the path can never
    ///    match: it would have to anchor mid-string, after the host;
    ///  * the text is the request's origin-form URI, pathname AND query, on
    ///    BOTH schemes. Plain HTTP used to compare the pathname alone (the old
    ///    `getPathname(from:)`), so a pattern with a query never matched an
    ///    `http://` request; since core ef40bdf (C5) plain HTTP runs on the
    ///    HTTPS exchange engine and matches `head.uri` exactly as HTTPS
    ///    always did. The user-visible change: an anchored wildcard without a
    ///    query (`/api/users`) no longer matches `/api/users?page=2` over
    ///    plain HTTP — it never did over HTTPS.
    public static func matches(url: String, path: String, isRegex: Bool) -> Bool {
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !trimmedURL.isEmpty else { return false }
        guard let parsed = URL(string: trimmedURL), let host = parsed.host else { return false }
        let scheme = (parsed.scheme ?? "https").lowercased()
        let pathname = parsed.path.isEmpty ? "/" : parsed.path
        let uri = pathname + (parsed.query.map { "?" + $0 } ?? "")
        let text = proxyPattern(scheme: scheme, host: host, path: uri)
        let pattern = proxyPattern(scheme: scheme, host: host, path: path)
        let regexPattern = isRegex
            ? pattern
            : "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
        guard let regex = try? NSRegularExpression(pattern: regexPattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }
}
