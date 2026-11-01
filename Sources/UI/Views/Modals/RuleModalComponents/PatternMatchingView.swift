//
//  PatternMatchingView.swift
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
//  The pattern tester: a popover on the `?` beside the override form's URL
//  field. It tests the rule's REAL path and match type through
//  `OverridePattern`, which reproduces what the proxy does — the host is put
//  in front of the pattern, and the query is matched on both schemes (plain HTTP
//  too, since core C5).
//  (The first version was a separate window with its own pattern fields, so
//  what it tested had nothing to do with what the form would save.)
//

import SwiftUI
import MCPKit
import XReqResCore

struct PatternTesterPopover: View {
    /// The rule's path, exactly as it will be stored.
    let path: String
    /// The host the rule is scoped to; the proxy puts it in front of the path.
    let scheme: String
    let host: String?
    let matchType: UrlMatcherType

    @State private var url = ""

    private var proxyPattern: String {
        OverridePattern.displayed(scheme: scheme, host: host, path: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test the Pattern")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text(host == nil ? (matchType == .REGEX ? "Regex" : "Wildcard pattern") : "ReqRes matches")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(path.isEmpty ? "Type a pattern in the URL field first." : proxyPattern)
                    .font(.system(size: 12, design: path.isEmpty ? .default : .monospaced))
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Try a URL")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("https://api.example.com/users?id=1", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if !url.trimmingCharacters(in: .whitespaces).isEmpty, !path.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: matches ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(matches ? .green : .red)
                        Text(matches ? "Matches" : "Does not match")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.top, 2)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(matchType == .REGEX ? "Regex" : "Wildcard")
                    .font(.system(size: 11, weight: .semibold))
                Text(matchType == .REGEX
                     ? "Matched against the whole URL — ReqRes puts the host in front of your pattern, so start it at the path and do NOT anchor it with ^. Characters that are also URL syntax (? . /) need escaping."
                     : "* matches any run of characters, including none. Everything else matches literally, and the pattern must cover the query too — end it with * to match /search?q=…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(examples, id: \.0) { example in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(example.0)
                            .font(.system(size: 10, design: .monospaced))
                        Text(example.1)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var examples: [(String, String)] {
        switch matchType {
        case .WILDCARD:
            return [
                ("/api/*", "everything under /api/"),
                ("/items?*", "any query on /items"),
                ("/*", "every request to this host"),
            ]
        case .REGEX:
            return [
                ("/api/.*$", "everything under /api/"),
                ("/items\\?.*$", "any query on /items"),
                ("/users/\\d+$", "a numeric user id"),
            ]
        }
    }

    /// The proxy's own algorithm — see `OverridePattern.matches`.
    private var matches: Bool {
        OverridePattern.matches(url: url, path: path, isRegex: matchType == .REGEX)
    }
}

#Preview {
    PatternTesterPopover(path: "/users?*", scheme: "https", host: "api.example.com", matchType: .WILDCARD)
}
