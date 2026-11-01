//
//  MCPRedactor.swift
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

/// Default-on redaction of credential-shaped values before captured traffic
/// leaves the bridge toward an AI client.
///
/// Design rule learned the hard way: **never redact by regexing a serialized
/// format.** Bodies are parsed (JSON object graph, or form pairs) and rewritten
/// structurally, so nesting, non-string values, and escaped quotes are all
/// covered. Formats we cannot parse fall back to shape detection, which fails
/// closed on things that merely *look* like secrets.
///
/// `enabled` is the master switch; `policy` (`MCPRedactionPolicy`) sits above
/// it and lets one named host opt out — checked fresh per record in
/// `redactSummary`/`redactDetail`/`redactRule`, so one excepted host in a
/// batch never touches any other record's redaction.
public struct MCPRedactor {
    public static let placeholder = "«redacted»"
    /// URL query values must stay percent-encodable ASCII — the guillemets in
    /// `placeholder` are rejected outright by `percentEncodedQueryItems`.
    public static let urlPlaceholder = "REDACTED"

    /// Normalized (lowercased, `-`/`_` stripped) fragments that mark a name as
    /// sensitive when they appear anywhere in it — `x-refresh-token-v2` included.
    static let sensitiveNameFragments: [String] = [
        "authorization", "token", "secret", "password", "passwd",
        "apikey", "credential", "cookie", "privatekey", "accesskey",
        "sessionid", "signature",
    ]

    /// Normalized names that are sensitive only as an exact match, because as
    /// substrings they would swallow innocent names ("key" in "keyboard").
    static let sensitiveNamesExact: Set<String> = [
        "auth", "key", "pwd", "sig", "session", "sid", "otp", "pin",
    ]

    /// Names that contain a sensitive fragment but are not secrets.
    /// `Access-Control-Allow-Credentials` carries only `true` (a CORS flag);
    /// masking it hid a fact an agent debugging CORS needs (2026-09-29 live run).
    static let benignNames: Set<String> = [
        "idempotencykey", "keyboard", "publickey", "tokentype", "keepalive",
        "accesscontrolallowcredentials",
    ]

    /// Unambiguous vendor credential prefixes, redacted wherever they appear.
    static let credentialPrefixes: [String] = [
        "sk_live_", "sk_test_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_",
        "github_pat_", "glpat-", "shpat_", "xoxb-", "xoxa-", "xoxp-", "AKIA",
        "ASIA", "AIza", "ya29.",
    ]

    private static let jwtPattern = try! NSRegularExpression(
        pattern: #"eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{4,}(\.[A-Za-z0-9_-]*)?"#
    )

    private static let prefixPattern: NSRegularExpression = {
        let alternatives = credentialPrefixes
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?:\(alternatives))[A-Za-z0-9_\\-\\.]{6,}")
    }()

    public let enabled: Bool

    /// Per-host exception on top of `enabled`. Defaults to `.redactAll` — no
    /// exceptions — so a call site built before this existed (every one in
    /// the tree today) keeps redacting every host exactly as before; nobody
    /// gets a surprise exemption just because this type learned to check one.
    public let policy: MCPRedactionPolicy

    public init(enabled: Bool = true, policy: MCPRedactionPolicy = .redactAll) {
        self.enabled = enabled
        self.policy = policy
    }

    /// The one place `enabled` and `policy` combine. `enabled` stays the
    /// master switch it always was (off skips redaction for every entry
    /// point, host included); `policy` only gets a vote once that switch is
    /// on. A host this process cannot pin down — nil, empty, or otherwise
    /// unparseable — is a case the policy can never except (`normalize`
    /// returns nil for it), so it always redacts: an exception is granted to
    /// a specific host the user named, never to "we don't know whose traffic
    /// this is".
    private func shouldRedact(host: String?) -> Bool {
        enabled && policy.shouldRedact(host: host)
    }

    /// Whether a record from `host` is redacted at all — for surfaces that
    /// build their own output (the stream views) and must honour the same
    /// switch and per-host exception as `redactDetail`.
    public func redacts(host: String?) -> Bool {
        shouldRedact(host: host)
    }

    // MARK: - Name classification

    static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    }

    /// True when a header/query/JSON key name should have its value hidden.
    public static func isSensitiveName(_ name: String) -> Bool {
        let normalized = normalize(name)
        if benignNames.contains(normalized) { return false }
        if sensitiveNamesExact.contains(normalized) { return true }
        return sensitiveNameFragments.contains { normalized.contains($0) }
    }

    // MARK: - Headers, URLs

    public func redactHeaders(_ headers: [String: String]) -> [String: String] {
        guard enabled else { return headers }
        var result: [String: String] = [:]
        result.reserveCapacity(headers.count)
        for (rawName, value) in headers {
            // A header NAME is sent by the client like its value; a
            // credential shape in it is masked too (never an ordinary name).
            let name = Self.redactStatic(rawName, aggressive: false)
            // A name recorded more than once arrives newline-joined
            // (`MCPRecordedHeaders` — only `Set-Cookie`, whose values hold
            // commas). Each line is its own header on the wire, so each is
            // redacted on its own: two cookies stay two placeholders instead
            // of collapsing into one line that reads as a single cookie.
            let lines = MCPRecordedHeaders.lines(of: value)
            result[name] = lines
                .map { Self.isSensitiveName(rawName) ? Self.placeholder : redactFreeText($0) }
                .joined(separator: "\n")
        }
        return result
    }

    /// Ordered header pairs, for the one surface that keeps them ordered.
    ///
    /// A separate overload rather than a conversion through `[String: String]`
    /// because a held request's headers are shown to the agent as they sit on
    /// the wire: `Cookie` twice is legal, and a dictionary would keep one of
    /// them and say nothing.
    public func redactHeaders(_ headers: [MCPHeaderPair]) -> [MCPHeaderPair] {
        guard enabled else { return headers }
        return headers.map { header in
            MCPHeaderPair(
                name: Self.redactStatic(header.name, aggressive: false),
                value: Self.isSensitiveName(header.name) ? Self.placeholder : redactFreeText(header.value)
            )
        }
    }

    /// A held request on its way to an agent.
    ///
    /// Same shape as `redactDetail`, including the per-host exception: a user
    /// who excepted a host did it so they could SEE the values, and a
    /// breakpoint is the surface where that matters most — the whole point of
    /// stopping a request is to look at what is in it.
    public func redactPaused(_ request: MCPPausedRequest) -> MCPPausedRequest {
        guard shouldRedact(host: request.host) else { return request }
        var redacted = request
        redacted.url = redactURL(request.url)
        // The request-target — the same query string as `url`, without the
        // origin. `redactURL` reads a relative `/path?query` too, so a token
        // in it is masked by name like the URL's (F15: this field carried
        // `?access_token=…` raw to any client reading the bridge JSON).
        redacted.path = redactURL(request.path)
        // The same shape-only pass `redactSummary` gives a row's host and
        // method: they came off the wire, and an ordinary one is never
        // touched.
        redacted.host = Self.redactStatic(request.host, aggressive: false)
        redacted.method = Self.redactStatic(request.method, aggressive: false)
        redacted.headers = redactHeaders(request.headers)
        let contentType = request.headers.first { $0.name.lowercased() == "content-type" }?.value
        redacted.bodyPreview = request.bodyPreview.map { redactBody($0, contentType: contentType) }
        return redacted
    }

    /// What an agent is told after it answers a held request.
    ///
    /// The app builds the outcome from the RAW held request — the user's own
    /// Breakpoints panel shows the same sentence, raw by design — so the
    /// reply is redacted here, by the same per-host rule as `redactPaused`
    /// (F15). The agent read this request's URL redacted a moment earlier in
    /// list_paused_requests; answering it must not hand back the raw one
    /// (measured live on build 51: `?access_token=…` verbatim in the reply).
    /// The summary is prose around that URL ("Resumed GET https://… untouched."),
    /// so its URLs are masked in place and the rest gets the shape pass.
    public func redactOutcome(_ outcome: MCPBreakpointOutcome) -> MCPBreakpointOutcome {
        guard shouldRedact(host: outcome.host) else { return outcome }
        var redacted = outcome
        redacted.url = redactURL(outcome.url)
        redacted.summary = Self.redactStatic(redactURLs(in: outcome.summary), aggressive: false)
        redacted.host = Self.redactStatic(outcome.host, aggressive: false)
        redacted.method = Self.redactStatic(outcome.method, aggressive: false)
        return redacted
    }

    public func redactURL(_ url: String) -> String {
        guard enabled else { return url }
        guard var components = URLComponents(string: url) else { return redactFreeText(url) }

        // Credentials can hide in userinfo (https://user:pass@host/…).
        if components.user != nil || components.password != nil {
            components.user = nil
            components.password = nil
        }
        // Rewrite only sensitive values; percent-encoding of everything else is
        // preserved so the agent is shown the URL that was actually sent.
        if let items = components.percentEncodedQueryItems, !items.isEmpty {
            components.percentEncodedQueryItems = items.map { item in
                let name = item.name.removingPercentEncoding ?? item.name
                if Self.isSensitiveName(name), item.value?.isEmpty == false {
                    return URLQueryItem(name: item.name, value: Self.urlPlaceholder)
                }
                return item
            }
        }
        // A URL masked once already can hold the placeholder — the shape pass
        // below puts it where a JWT sat in a path or an ordinary parameter —
        // and `URLComponents` percent-encodes it on the way back out
        // (`%C2%ABredacted%C2%BB`). Put back as written, so a second pass over
        // a line gives the first pass's text: the activity log is redacted
        // again at every launch (`redactLogEntry`).
        let rebuilt = components.string?.replacingOccurrences(of: Self.encodedPlaceholder, with: Self.placeholder)
        return redactFreeText(rebuilt ?? Self.placeholder)
    }

    /// `placeholder` as `URLComponents` writes it inside a URL.
    private static let encodedPlaceholder = placeholder.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? placeholder

    // MARK: - Query pairs outside a URL

    /// `name=value` after `?`, `&` or `;`: a query parameter, or a path's
    /// matrix parameter (`;jsessionid=…`). The value runs to the next `&`,
    /// `#` or whitespace, and through a `;` or `?` unless another `name=`
    /// follows it: a harmless pair must not swallow the credential after it
    /// (`?a=1;token=…`, `?next=/a?token=…`), and a credential that holds a
    /// `;` or `?` of its own must not leave its tail readable (`token=abc;def`
    /// is masked whole, as `redactURL` masks it in a URL).
    private static let queryPairPattern = try! NSRegularExpression(
        pattern: #"(?<=[?&;])([^=&?;#\s]+)=((?:[^&;?#\s]|[;?](?![^=&?;#\s]+=))*)"#
    )

    /// Each pair's name (percent-decoded, as `isSensitiveName` reads it; and
    /// as written), and its value's range with trailing punctuation left out —
    /// part of the sentence around it, as `redactURLs(in:)` treats a URL's, or
    /// a regex path's closing group or end anchor (`\?token=[^&]+)$`).
    private static func queryPairs(in text: String) -> [(name: String, written: String, value: Range<String.Index>)] {
        queryPairPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { return nil }
            var end = valueRange.upperBound
            while end > valueRange.lowerBound, ".,;:)]$".contains(text[text.index(before: end)]) {
                end = text.index(before: end)
            }
            let rawName = String(text[nameRange])
            return (rawName.removingPercentEncoding ?? rawName, rawName, valueRange.lowerBound..<end)
        }
    }

    /// Query pairs whose NAME is a credential name, their values masked as
    /// `redactURL` masks a URL's — for the query strings that are not in a
    /// URL: a rule's path (`/get?access_token=…&page=2`) and the log lines
    /// that quote one. The shape pass cannot see a short token; the name can.
    /// A value that matches no letter or digit literally is a PATTERN, never a
    /// credential, and stays readable (`isPatternValue`): `?access_token=*` is
    /// how a wildcard rule says "any token", `\?token=\w+` how a regex rule
    /// does. `regex` is true only for a regex rule's own path: anywhere else
    /// `\w` is two characters of text. Applied twice it gives what applying it
    /// once did.
    static func redactQueryPairs(in text: String, regex: Bool = false) -> String {
        var output = ""
        var last = text.startIndex
        for pair in queryPairs(in: text) where isSensitiveName(pair.name) {
            let value = text[pair.value]
            guard value != urlPlaceholder, !isPatternValue(value, regex: regex) else { continue }
            output += text[last..<pair.value.lowerBound]
            output += urlPlaceholder
            last = pair.value.upperBound
        }
        output += text[last...]
        return output
    }

    /// Whether a credential-named value in a rule's path is a pattern rather
    /// than a credential: nothing in it matches a letter or a digit literally.
    ///
    /// For a wildcard path that is the value as written (`*`, `.`). For a
    /// regex path, what the pattern matches literally once its syntax is
    /// taken out (`regexLiterals`): `\w+`, `[A-Za-z0-9]{32}` and `[^&]*` match
    /// no letter literally and stay readable, so an agent can read the rule
    /// and edit it; `abc\.def`, `sk_[a-z]+` or `(prod|dev)` keep literal text
    /// and are masked.
    static func isPatternValue(_ value: Substring, regex: Bool) -> Bool {
        let literal = regex ? regexLiterals(value) : String(value)
        return !literal.contains { $0.isLetter || $0.isNumber }
    }

    /// The characters a regex fragment matches literally: character classes
    /// (`[…]`, nested sets included, and the shorthands `\w \d \s \b \h \v`
    /// and their negations) and counted quantifiers (`{n}`, `{n,}`, `{n,m}`)
    /// are taken out, an escaped character (`\.`) is kept as itself. Anything
    /// it does not recognise — `\p{L}`, `(?i)`, an unterminated `[` — is kept
    /// as text, so it fails toward masking.
    static func regexLiterals(_ fragment: Substring) -> String {
        var result = ""
        var index = fragment.startIndex
        while index < fragment.endIndex {
            let character = fragment[index]
            let next = fragment.index(after: index)
            switch character {
            case "\\":
                guard next < fragment.endIndex else { return result }
                let escaped = fragment[next]
                if !"wWdDsSbBhHvV".contains(escaped) { result.append(escaped) }
                index = fragment.index(after: next)
            case "[":
                guard let close = closingBracket(in: fragment, from: index) else {
                    result.append(character)
                    index = next
                    continue
                }
                index = fragment.index(after: close)
            case "{":
                if let close = fragment[next...].firstIndex(of: "}"), close > next,
                   fragment[next..<close].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ",") }) {
                    index = fragment.index(after: close)
                } else {
                    result.append(character)
                    index = next
                }
            default:
                result.append(character)
                index = next
            }
        }
        return result
    }

    /// The `]` that closes the bracket expression opening at `open`, counting
    /// nested sets and skipping escaped characters; nil when none does.
    private static func closingBracket(in fragment: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = open
        while index < fragment.endIndex {
            switch fragment[index] {
            case "\\":
                index = fragment.index(after: index)
                guard index < fragment.endIndex else { return nil }
            case "[":
                depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            index = fragment.index(after: index)
        }
        return nil
    }

    /// What redaction writes in place of a credential, found in `text` — a
    /// credential-named pair holding `urlPlaceholder`, as written in `text`
    /// (`api%5Fkey=REDACTED`), or `placeholder` as written or as a URL
    /// percent-encodes it — or nil.
    ///
    /// A rule's path is shown to agents with its credentials masked
    /// (`redactRule`). A path sent back holding a mask would be stored as the
    /// literal text, and the rule would match that text, never the request
    /// whose credential it hid — so the write routes refuse one
    /// (`MCPWriteValidation.refuseRedactionMarker`).
    static func redactionMarker(in text: String) -> String? {
        if text.contains(placeholder) || text.range(of: encodedPlaceholder, options: .caseInsensitive) != nil {
            return placeholder
        }
        for pair in queryPairs(in: text) where holdsMask(text[pair.value]) && isSensitiveName(pair.name) {
            return "\(pair.written)=\(urlPlaceholder)"
        }
        return nil
    }

    /// A value that is the mask `redactQueryPairs` writes — whole, or with a
    /// `;` or `?` and more after it: a value runs through those unless another
    /// `name=` follows, so an agent's text typed after the mask
    /// (`token=REDACTED?v=2`) is part of the same value, and still a mask.
    private static func holdsMask(_ value: Substring) -> Bool {
        guard value.hasPrefix(urlPlaceholder) else { return false }
        let rest = value.dropFirst(urlPlaceholder.count)
        return rest.first.map { $0 == ";" || $0 == "?" } ?? true
    }

    /// A rule's path on its way to an agent: credential-named query values
    /// masked (`redactQueryPairs`, reading a regex rule's pattern values as
    /// patterns), then the shape pass a URL gets — JWTs and vendor-prefixed
    /// keys, anywhere, a path segment included. The same treatment
    /// `redactURL` gives a URL, done without `URLComponents`, which cannot
    /// read a regex path (`/users/\d+\?token=…`) and would re-encode a
    /// wildcard one — so an agent sending the path back as shown can be told
    /// apart from one that changed it (`MCPWriteValidation.validate(_:currentMode:…)`).
    func redactRulePath(_ path: String, matchType: MCPMatchType = .wildcard) -> String {
        guard enabled else { return path }
        return Self.redactStatic(Self.redactQueryPairs(in: path, regex: matchType == .regex), aggressive: false)
    }

    // MARK: - Bodies

    /// Redacts a body by PARSING it. `contentType` is a hint; detection still
    /// runs so a mislabelled body is handled correctly.
    public func redactBody(_ body: String, contentType: String? = nil) -> String {
        guard enabled, !body.isEmpty else { return body }

        // A stream (SSE, NDJSON) is many JSON documents, not one: parsed as a
        // whole it is "unknown text", and the free-text pass cannot see
        // `"api_key":"abc"` inside a data line. Redact it event by event,
        // with the pending tail withheld (protocol-engine doc §S5).
        //
        // A body that is not a stream at all despite its label — a JSON error
        // sent as text/event-stream, or the "[binary body omitted — …]" line
        // the app writes for a stream kept as data — continues into the
        // detection below instead of being reduced to "N bytes pending".
        if let format = StreamFormat.detect(contentType: contentType),
           let redacted = MCPStreamEgress.redactedStreamBody(body, format: format) {
            return redacted
        }

        if let json = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed]) {
            let redacted = Self.redactJSON(json)
            if let data = try? JSONSerialization.data(
                withJSONObject: redacted,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
            ), let text = String(data: data, encoding: .utf8) {
                return text
            }
        }

        // JSON inside a wrapper: an anti-XSSI prefix (`)]}'`, `while(1);`)
        // or a JSONP callback. The document inside is ordinary JSON and is
        // walked like one; the wrapper is kept byte for byte.
        if let wrapped = Self.unwrappedJSON(body) {
            let redacted = Self.redactJSON(wrapped.json)
            if let data = try? JSONSerialization.data(
                withJSONObject: redacted,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
            ), let text = String(data: data, encoding: .utf8) {
                return wrapped.prefix + text + wrapped.suffix
            }
        }

        if Self.looksFormEncoded(body, contentType: contentType) {
            return Self.redactFormEncoded(body)
        }

        // JSON that did not parse: cut short by a retention cap (the 16 MB
        // per-exchange cap, the HTTP/2 connection pool), two documents back
        // to back, or a wrapper not recognised above. The shape pass cannot
        // see `"password":"hunter22"` (short, no prefix), so names are
        // matched leniently first. Only ever masks more.
        let byName = Self.redactPartialJSONByName(body)

        if byName.contains("<"), byName.contains(">") {
            // XML/HTML-ish: named fields are still structural, so short secrets
            // like <password>hunter2</password> are caught by NAME, not entropy.
            return redactFreeText(Self.redactTaggedMarkup(byName), aggressive: true)
        }

        // Unknown format: fail closed on anything shaped like a credential.
        return redactFreeText(byName, aggressive: true)
    }

    /// Anti-XSSI prefixes servers put before JSON so a `<script>` include
    /// cannot read it (Google's `)]}'`, Facebook's `for (;;);`).
    private static let xssiPrefixes = [")]}',", ")]}'", "while(1);", "while (1);", "for(;;);", "for (;;);"]

    /// A JSONP callback: `name(` … `)` with an optional `;`.
    private static let jsonpPattern = try! NSRegularExpression(
        pattern: #"^(\s*(?:/\*\*/\s*)?[A-Za-z_$][\w$.]*\s*\()([\s\S]*)(\)\s*;?\s*)$"#
    )

    /// The JSON document inside an anti-XSSI prefix or a JSONP call, with
    /// the text around it, or nil when the body is neither.
    static func unwrappedJSON(_ body: String) -> (prefix: String, json: Any, suffix: String)? {
        let leading = body.prefix(while: { $0.isWhitespace })
        let rest = body.dropFirst(leading.count)
        for marker in xssiPrefixes where rest.hasPrefix(marker) {
            let inner = rest.dropFirst(marker.count)
            if let json = try? JSONSerialization.jsonObject(with: Data(inner.utf8), options: [.fragmentsAllowed]) {
                return (String(leading) + marker, json, "")
            }
        }
        let range = NSRange(body.startIndex..., in: body)
        if let match = jsonpPattern.firstMatch(in: body, range: range),
           let head = Range(match.range(at: 1), in: body),
           let inner = Range(match.range(at: 2), in: body),
           let tail = Range(match.range(at: 3), in: body),
           let json = try? JSONSerialization.jsonObject(with: Data(body[inner].utf8), options: [.fragmentsAllowed]) {
            return (String(body[head]), json, String(body[tail]))
        }
        return nil
    }

    /// Kept for call sites that only have a preview string.
    public func redactBodyPreview(_ body: String) -> String {
        redactBody(body)
    }

    /// How deep JSON-inside-a-string is followed (a string holding JSON that
    /// holds a string holding JSON …). Past it, strings get the shape pass only.
    static let nestedJSONDepthLimit = 4

    /// Walks the object graph; sensitive keys lose their value whatever its type.
    ///
    /// A string value that is itself a JSON object or array is walked too:
    /// that is how tool-call arguments travel (`"arguments":"{\"api_key\":…}"`
    /// in OpenAI Chat and Responses, including the Responses events that
    /// repeat the whole arguments after the deltas). Without this the key
    /// `arguments` is not a sensitive name, and the shape pass cannot see a
    /// short secret under `api_key` inside the encoded string. Such a string
    /// is re-encoded (compact, sorted keys) only when redaction changed it;
    /// otherwise it is returned exactly as it was.
    static func redactJSON(_ value: Any) -> Any {
        redactJSON(value, depth: 0)
    }

    private static func redactJSON(_ value: Any, depth: Int) -> Any {
        switch value {
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            result.reserveCapacity(object.count)
            for (key, child) in object {
                result[key] = isSensitiveName(key) ? placeholder : redactJSON(child, depth: depth)
            }
            return result
        case let array as [Any]:
            return array.map { redactJSON($0, depth: depth) }
        case let string as String:
            if depth < nestedJSONDepthLimit, let nested = redactedNestedJSON(string, depth: depth) {
                return nested
            }
            return redactStatic(string, aggressive: false)
        default:
            return value
        }
    }

    /// The string redacted as the JSON document it holds, or nil when it holds
    /// none or redaction left it unchanged.
    private static func redactedNestedJSON(_ string: String, depth: Int) -> String? {
        guard let first = string.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
              JSONSerialization.isValidJSONObject(object) else { return nil }
        let redacted = redactJSON(object, depth: depth + 1)
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard let before = try? JSONSerialization.data(withJSONObject: object, options: options),
              let after = try? JSONSerialization.data(withJSONObject: redacted, options: options),
              before != after else { return nil }
        return String(data: after, encoding: .utf8)
    }

    // MARK: - JSON cut short

    /// `"name": value` pairs inside text that is JSON cut off mid-way (a tool
    /// call whose stream ended inside its arguments). A string value is
    /// matched up to its closing quote or the end of the text, a bare value
    /// (number, true/false/null) up to the next delimiter.
    private static let partialPairPattern = try! NSRegularExpression(
        pattern: #""((?:[^"\\]|\\.)*)"\s*:\s*("(?:[^"\\]|\\.)*(?:"|\\?$)|[^,{}\[\]\s"]+)"#
    )

    /// A sensitive name whose value is an object or array.
    private static let partialContainerPattern = try! NSRegularExpression(
        pattern: #""((?:[^"\\]|\\.)*)"\s*:\s*[\{\[]"#
    )

    /// Redacts by NAME inside JSON that does not parse because it was cut
    /// short. The structural walk cannot run on it and the shape pass cannot
    /// see `"password": "s3cretPw` (8 characters, no vendor prefix), so the
    /// pairs are found leniently: a sensitive name's string or bare value is
    /// replaced, and a sensitive name whose value is an object or array hides
    /// everything from there to the end of the text (its closing bracket may
    /// never have arrived, so where it ends is unknown). Only ever masks more.
    static func redactPartialJSONByName(_ text: String) -> String {
        var result = text
        let full = NSRange(result.startIndex..., in: result)
        if let container = partialContainerPattern.matches(in: result, range: full).first(where: { match in
            Range(match.range(at: 1), in: result).map { isSensitiveName(String(result[$0])) } ?? false
        }), let range = Range(container.range, in: result) {
            let keep = String(result[..<range.lowerBound])
            let head = String(result[range].dropLast())
            result = keep + head + "\"" + placeholder + "\""
        }
        return rewrite(result, with: partialPairPattern) { match, text in
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text),
                  isSensitiveName(String(text[nameRange])),
                  text[valueRange] != "\"\(placeholder)\"" else { return nil }
            return text.replacingCharacters(in: valueRange, with: "\"\(placeholder)\"")
        }
    }

    /// Key characters permitted in a real form body; anything else (markup,
    /// whitespace) means this is some other format that merely contains "=".
    private static let formKeyCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.[]%+")

    static func looksFormEncoded(_ body: String, contentType: String?) -> Bool {
        if let contentType, contentType.lowercased().contains("application/x-www-form-urlencoded") {
            return true
        }
        guard body.contains("="),
              !body.contains("\n"),
              !body.contains("<"),
              !body.contains(">") else { return false }
        // Every segment must be key=value with a plausible key. Without this the
        // XML fragment `<auth apiKey="x" mode="y"/>` parses as one giant "pair".
        let pairs = body.split(separator: "&")
        return pairs.allSatisfy { segment in
            let parts = segment.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, !parts[0].isEmpty else { return false }
            return parts[0].unicodeScalars.allSatisfy(formKeyCharacters.contains)
        }
    }

    static func redactFormEncoded(_ body: String) -> String {
        body.split(separator: "&", omittingEmptySubsequences: false).map { segment -> String in
            let parts = segment.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return String(segment) }
            let rawKey = String(parts[0])
            let key = rawKey.removingPercentEncoding ?? rawKey
            if isSensitiveName(key) {
                return "\(rawKey)=\(placeholder)"
            }
            return "\(rawKey)=\(redactStatic(String(parts[1]), aggressive: false))"
        }.joined(separator: "&")
    }

    /// Redacts `<secret>value</secret>` element text and `secret="value"`
    /// attributes wherever the NAME is sensitive.
    static func redactTaggedMarkup(_ body: String) -> String {
        var result = body

        if let elements = try? NSRegularExpression(pattern: #"<([A-Za-z_][\w.:-]*)([^>]*)>([^<]*)</\1\s*>"#) {
            result = rewrite(result, with: elements) { match, text in
                guard let nameRange = Range(match.range(at: 1), in: text),
                      let valueRange = Range(match.range(at: 3), in: text),
                      isSensitiveName(String(text[nameRange])),
                      !text[valueRange].isEmpty else { return nil }
                return text.replacingCharacters(in: valueRange, with: placeholder)
            }
        }

        if let attributes = try? NSRegularExpression(pattern: #"([A-Za-z_][\w.:-]*)\s*=\s*"([^"]*)""#) {
            result = rewrite(result, with: attributes) { match, text in
                guard let nameRange = Range(match.range(at: 1), in: text),
                      let valueRange = Range(match.range(at: 2), in: text),
                      isSensitiveName(String(text[nameRange])),
                      !text[valueRange].isEmpty else { return nil }
                return text.replacingCharacters(in: valueRange, with: placeholder)
            }
        }

        return result
    }

    /// Applies `transform` to each match, last-first so earlier ranges stay valid.
    private static func rewrite(
        _ text: String,
        with regex: NSRegularExpression,
        transform: (NSTextCheckingResult, String) -> String?
    ) -> String {
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            if let updated = transform(match, result) {
                result = updated
            }
        }
        return result
    }

    // MARK: - Free text

    func redactFreeText(_ text: String, aggressive: Bool = false) -> String {
        Self.redactStatic(text, aggressive: aggressive)
    }

    /// JWTs and known vendor prefixes always; long high-entropy blobs only when
    /// the body format is unknown (aggressive), where a false positive is
    /// cheaper than a leaked secret.
    static func redactStatic(_ text: String, aggressive: Bool) -> String {
        var result = replaceMatches(of: jwtPattern, in: text)
        result = replaceMatches(of: prefixPattern, in: result)
        guard aggressive else { return result }
        return redactHighEntropyRuns(in: result)
    }

    private static func replaceMatches(of regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: placeholder
        )
    }

    /// A run of >=24 token characters mixing letter cases or letters+digits is
    /// treated as a secret in unparseable bodies.
    static func redactHighEntropyRuns(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9_\-]{24,}"#) else { return text }
        let full = NSRange(text.startIndex..., in: text)
        var output = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            let candidate = String(text[range])
            output += text[last..<range.lowerBound]
            output += looksHighEntropy(candidate) ? placeholder : candidate
            last = range.upperBound
        }
        output += text[last...]
        return output
    }

    static func looksHighEntropy(_ candidate: String) -> Bool {
        let hasLower = candidate.contains { $0.isLowercase }
        let hasUpper = candidate.contains { $0.isUppercase }
        let hasDigit = candidate.contains { $0.isNumber }
        // Mixed case, or letters mixed with digits — plain lowercase words are left alone.
        return (hasLower && hasUpper) || ((hasLower || hasUpper) && hasDigit)
    }

    // MARK: - Consent actions on their way to the LOG

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s]+"#)

    /// The log-safe copy of an approval.
    ///
    /// The approval PANEL deliberately shows raw values: it is the user's own
    /// window, and a query string is exactly where a token hides, so hiding it
    /// there would remove the one thing that makes the decision informed. The
    /// ACTIVITY LOG is a different place — persisted to UserDefaults, kept for
    /// 100 entries and exportable to a file — and a raw captured URL in it is
    /// a credential that outlives the decision.
    ///
    /// `MCPAuditExport` cannot catch these on its own: it redacts by field
    /// name in "Name: value" prose, and a URL has "://", not ": ". Its
    /// shape-based pass only sees JWTs, vendor prefixes and 24+ character
    /// high-entropy runs, so `?access_token=live-secret-9912` goes straight
    /// through. This is where that stops.
    public func redactAction(_ action: MCPAgentAction) -> MCPAgentAction {
        guard enabled else { return action }
        return MCPAgentAction(
            kind: action.kind,
            summary: logSafe(action.summary),
            details: action.details.map(logSafe)
        )
    }

    /// An activity-log entry as the log may keep it: what
    /// `MCPBridgeRouter.performWrite` records, and what `MCPAgentActivity`
    /// applies again to every entry it loads — so a row an earlier build
    /// persisted is held to the same rule as a new one.
    ///
    /// - The action (summary and details) gets `redactAction`.
    /// - The RESULT line (`detail`) was left raw by `redactAction`, and on one
    ///   route it quotes captured traffic: answering a held request records
    ///   the outcome's sentence, "Resumed GET https://…?access_token=…
    ///   untouched." (F15, measured live — build 51 persisted it). A result
    ///   is `performWrite`'s own `detail:` rendering ("rule #12", that
    ///   sentence) and gets the action's treatment. A REASON — a failure's
    ///   message, a refusal's — is a sentence from a seam, often around a
    ///   system error's description, and gets the URL pass only: the name
    ///   pass parses "Name: value" as the consent layer renders it, and in
    ///   anyone else's prose it takes the last word before a colon for a
    ///   field name. "Could not save the session: The database is locked."
    ///   lost its reason to «redacted» that way — "session" is a credential
    ///   name.
    /// - Nothing else changes. `previousState` keeps its REAL values on
    ///   purpose — an undo writes them back into live traffic, where a
    ///   placeholder would go in as if it were a credential — and
    ///   `MCPAuditExport` redacts the snapshot on its way to a file.
    ///
    /// Like `redactAction` it ignores the per-host exception: an excepted
    /// host's reply to the agent is raw, its log line is not (the log fails
    /// toward more redaction, as `MCPAuditExport` does). Applied twice it
    /// gives what applying it once did, which is what lets the app run it
    /// over the whole log at every launch.
    public func redactLogEntry(_ entry: MCPAuditEntry) -> MCPAuditEntry {
        guard enabled else { return entry }
        var logged = entry
        logged.action = redactAction(entry.action)
        logged.detail = entry.detail.map { entry.outcome == .performed ? logSafe($0) : redactURLs(in: $0) }
        return logged
    }

    /// URLs masked by `redactURL`, then query pairs outside a URL masked by
    /// name and credential shapes masked where they stand, and then the
    /// "Name: value" pairs the consent layer renders masked by NAME.
    ///
    /// The last part was missing and the export path was carrying it alone:
    /// a detail line like `Header set: X-Api-Key: abc123` is not URL-shaped,
    /// so it reached UserDefaults verbatim and only `MCPAuditExport` cleaned
    /// it on the way to a file. The persisted copy is the one that outlives
    /// the decision, so it is cleaned here too. Every write route benefits —
    /// `create_rule` has always had this exposure through its header lines.
    ///
    /// The query pairs and shapes are a rule's PATH: `create_rule`,
    /// `update_rule` and `delete_rule` name the rule's pattern in their
    /// summary ("… Any /get?access_token=… → 200", "Path → …"), and a path
    /// `mock_from_session` derived from a captured URL carries that URL's
    /// query. With no scheme in front the URL pass never saw it, so the token
    /// was persisted — the F15 class, in the rule routes. The same treatment
    /// the path gets on its way to the agent (`redactRulePath`).
    private func logSafe(_ text: String) -> String {
        let urls = redactURLs(in: text)
        return MCPAuditExport.redactNamedValues(in: Self.redactStatic(Self.redactQueryPairs(in: urls), aggressive: false))
    }

    /// Runs `redactURL` over every URL-shaped run in free text, leaving the
    /// rest of the sentence alone.
    func redactURLs(in text: String) -> String {
        let full = NSRange(text.startIndex..., in: text)
        var output = ""
        var last = text.startIndex
        for match in Self.urlPattern.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            output += text[last..<range.lowerBound]
            // Trailing punctuation is part of the sentence, not the URL.
            var candidate = String(text[range])
            var tail = ""
            while let final = candidate.last, ".,;:)]".contains(final) {
                tail = String(final) + tail
                candidate.removeLast()
            }
            output += redactURL(candidate) + tail
            last = range.upperBound
        }
        output += text[last...]
        return output
    }

    // MARK: - Aggregates

    public func redactSummary(_ summary: MCPSessionSummary) -> MCPSessionSummary {
        guard shouldRedact(host: summary.host) else { return summary }
        var redacted = summary
        redacted.url = redactURL(summary.url)
        // Every other free-form string a row carries came off the wire or out
        // of the core (a Host header, a request-line token, a Content-Type,
        // a process name, a failure sentence). Unambiguous credential shapes
        // only — JWTs and vendor prefixes — so an ordinary host or type is
        // never touched (`MCPAgentFacingRedactionTests` walks every field).
        redacted.host = Self.redactStatic(summary.host, aggressive: false)
        redacted.method = Self.redactStatic(summary.method, aggressive: false)
        redacted.contentType = summary.contentType.map { Self.redactStatic($0, aggressive: false) }
        redacted.app = summary.app.map { Self.redactStatic($0, aggressive: false) }
        redacted.failureDetail = summary.failureDetail.map { Self.redactStatic($0, aggressive: false) }
        // Printed by the core from two integers NIO parsed, so it cannot hold
        // text today — shape-masked anyway, like the method, because it
        // travels in a String the canary test walks.
        redacted.httpVersion = summary.httpVersion.map { Self.redactStatic($0, aggressive: false) }
        return redacted
    }

    /// A rule on its way to an agent. Rules carry captured material —
    /// `mock_from_session` copies a response's headers and body verbatim, and
    /// a human's extend rule may hold a real Authorization value — so the
    /// write surface redacts exactly like the read surface. The body is
    /// redacted BEFORE it is capped (a cut secret is unrecognisable).
    ///
    /// `rule.host` is nil for a legacy row whose host filter is gone — that
    /// is exactly the "cannot be determined" case, so it redacts rather than
    /// passing a captured response through unchecked because the row is old.
    ///
    /// The PATH too: `mock_from_session` scopes its rule to the captured
    /// request's pathname AND query, so a captured `?access_token=…` is
    /// stored in the path — it has to be, or the mock would not match — and
    /// a person may type one into a pattern. The stored rule keeps it; the
    /// agent reads it masked (`redactRulePath`), in list_rules and in every
    /// rule a write returns.
    public func redactRule(_ rule: MCPRule) -> MCPRule {
        let redacting = shouldRedact(host: rule.host)
        var result = rule
        if redacting {
            result.path = redactRulePath(rule.path, matchType: rule.matchType)
            // The filter's name: mock_from_session names it after the
            // captured Host. The shape pass a row's host gets.
            result.host = rule.host.map { Self.redactStatic($0, aggressive: false) }
            result.requestHeaders = redactHeaders(rule.requestHeaders)
            result.responseHeaders = redactHeaders(rule.responseHeaders)
        }
        // The cap runs for an excepted host too. Excepting a host says "show
        // me its values", not "let this rule's body be any size it likes" —
        // and a mock_from_session rule carries a whole captured response with
        // no length limit anywhere upstream, so this is the only bound on
        // what a list_rules page or an exported log can grow to.
        if let body = rule.responseBody, !body.isEmpty {
            let contentType = rule.responseHeaders.first { $0.key.caseInsensitiveCompare("content-type") == .orderedSame }?.value
            let material = redacting ? redactBody(body, contentType: contentType) : body
            result.responseBody = MCPSessionQuery.cappedPreview(material).preview
        }
        return result
    }

    public func redactDetail(_ detail: MCPSessionDetail) -> MCPSessionDetail {
        guard shouldRedact(host: detail.summary.host) else { return detail }
        var redacted = detail
        redacted.summary = redactSummary(detail.summary)
        redacted.requestHeaders = redactHeaders(detail.requestHeaders)
        redacted.responseHeaders = redactHeaders(detail.responseHeaders)
        // Trailers are header fields that arrive after the body (core C13):
        // a new egress surface, redacted exactly like headers — by name, then
        // by shape — so `grpc-message`, a checksum or a server-timing value
        // gets the treatment its header twin would.
        redacted.requestTrailers = detail.requestTrailers.map(redactHeaders)
        redacted.responseTrailers = detail.responseTrailers.map(redactHeaders)
        let requestType = detail.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value
        redacted.requestBodyPreview = detail.requestBodyPreview.map { redactBody($0, contentType: requestType) }
        redacted.responseBodyPreview = detail.responseBodyPreview.map { redactBody($0, contentType: detail.summary.contentType) }
        // cURL strings embed raw headers; safest is to drop them when redacting.
        redacted.curl = nil
        return redacted
    }
}
