//
//  HelpPatternExamples.swift
//  AppServices
//
//  Created by OloApps on 21.09.2026.
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
//  The in-app Help window's "pattern syntax and its traps" section is a set
//  of worked examples, not prose — kept here, not in the SwiftUI view, so
//  HelpPatternExamplesTests can check each one against OverridePattern (the
//  proxy's own matching algorithm) with a plain `swift test`. A doc that
//  claims a pattern matches, or doesn't, and is wrong is worse than no doc:
//  it sends someone chasing a rule that was never going to fire for a
//  different reason than the one they were told.
//

import Foundation

/// One "this looks right but isn't" path pattern for the Help window: what
/// someone reasonably types (`badPath`), why the proxy never fires it, and
/// the fix (`goodPath`). Both paths are checked against `exampleURL` with
/// `OverridePattern.matches`, which mirrors the matching algorithm of
/// XReqResCore's GlueHandler/HTTPConnectHandler.
public struct HelpPatternExample: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let isRegex: Bool
    public let exampleURL: String
    public let badPath: String
    public let goodPath: String
    /// Why the proxy treats `badPath` this way, in user terms — the traps
    /// are all silent, so the explanation is the only thing standing
    /// between "it doesn't work" and "here is why".
    public let explanation: String
}

extension HelpPatternExample {
    /// The four traps in the core's rule matching —
    /// each one a rule that silently never fires, found by reading
    /// XReqResCore's matcher rather than guessing at it.
    public static let all: [HelpPatternExample] = [
        HelpPatternExample(
            id: "leading-caret",
            title: "A regex path starting with ^",
            isRegex: true,
            exampleURL: "https://api.example.com/users/42",
            badPath: "^/users/\\d+$",
            goodPath: "/users/\\d+$",
            explanation: "ReqRes compiles the pattern as scheme://host, then your path — so ^ would have to anchor in the middle of that string, right after the host. It never can, so the rule never fires. Drop the leading ^."
        ),
        HelpPatternExample(
            id: "missing-leading-slash",
            title: "A regex path that doesn't start with /",
            isRegex: true,
            exampleURL: "https://api.example.com/users/42",
            badPath: "users/\\d+$",
            goodPath: "/users/\\d+$",
            explanation: "Your path is appended directly onto the host with nothing in between, so \"users\" runs straight into \"api.example.com\" and the pattern looks for a host that doesn't exist. Start the path with /."
        ),
        HelpPatternExample(
            id: "host-in-path",
            title: "The host typed into the path",
            isRegex: false,
            exampleURL: "https://api.example.com/users?id=1",
            badPath: "/api.example.com/users?*",
            goodPath: "/users?*",
            explanation: "The host is already on both sides of the comparison — ReqRes adds it from the filter the rule belongs to. Typing it into the path too matches it twice, against a URL that only has it once. The path is the pathname and query alone."
        ),
        // Replaces "a query over plain HTTP never matches", which stopped
        // being true when plain HTTP moved onto the HTTPS exchange engine
        // (core C5): both schemes now compare the path AND the query. That
        // move made this one the trap instead — an exact wildcard path used
        // to cover `?page=2` over http:// and no longer does, on either.
        HelpPatternExample(
            id: "query-not-covered",
            title: "A wildcard path that stops before the query",
            isRegex: false,
            exampleURL: "http://api.example.com/search?q=widgets",
            badPath: "/search",
            goodPath: "/search*",
            explanation: "A wildcard path must match the whole path and query — over HTTPS and plain http:// alike — so /search matches only a request with no query at all. End it with * (or ?*) to cover the query too. Before ReqRes 1.1.0 plain http:// ignored the query, so a rule like this that used to fire on http:// now needs the *."
        ),
    ]
}
