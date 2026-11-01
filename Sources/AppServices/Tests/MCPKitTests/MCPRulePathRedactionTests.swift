//
//  MCPRulePathRedactionTests.swift
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
//  The F15 class in the rule routes:
//  mock_from_session scopes its rule to the captured request's pathname AND
//  query, so a captured `?access_token=…` is stored in the rule's path — it
//  must be, or the mock would not match — and every rule an agent read
//  carried it raw: the mock's reply, list_rules, update_rule's reply, and the
//  activity log's summaries. The stored rule keeps it; everything that leaves
//  toward an agent or the log masks it; a masked path sent back never
//  overwrites the value it hid.
//

import XCTest
@testable import MCPKit

final class MCPRulePathRedactionTests: XCTestCase {
    /// Short and plain: only redaction by the parameter's NAME catches it.
    private let secret = "short-secret-42"
    private var realPath: String { "/get?access_token=\(secret)&page=2" }
    private let shownPath = "/get?access_token=REDACTED&page=2"
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghij"

    private let token = "rule-path-token"
    private var rules: StubRuleProvider!
    private var consent: StubConsent!
    private var audit: StubAudit!

    override func setUp() {
        super.setUp()
        rules = StubRuleProvider()
        consent = StubConsent()
        audit = StubAudit()
    }

    private func makeRouter(redactor: MCPRedactor = MCPRedactor(), session: MCPSessionSummary? = nil) -> MCPBridgeRouter {
        let hosts = StubHostProvider()
        hosts.stored = [MCPHost(id: 7, host: "api.example.com", scheme: "https", port: 443)]
        let sessions = StubSessionProvider()
        if let session {
            sessions.summaries = [session]
            sessions.details = [session.uid: MCPSessionDetail(summary: session)]
        }
        return MCPBridgeRouter(
            token: token, sessions: sessions, status: StubStatusProvider(), redactor: redactor,
            writes: MCPWriteSeams(rules: rules, hosts: hosts, capture: StubCaptureController(), consent: consent, audit: audit)
        )
    }

    private func send(_ router: MCPBridgeRouter, _ method: String, _ target: String, _ body: [String: Any]? = nil) throws -> ParsedResponse {
        var request = makeRequest(method: method, target: target, token: token)
        if let body {
            request.body = try JSONSerialization.data(withJSONObject: body)
            request.headers["content-type"] = "application/json"
        }
        return try XCTUnwrap(parseRawResponse(router.respond(to: request)))
    }

    private func storeRule(path: String, host: String? = "api.example.com") {
        rules.stored = [MCPRule(
            id: 3, hostId: 7, host: host, enabled: true, mode: .override, matchType: .wildcard,
            path: path, method: "", scheme: "https", responseBody: "{}"
        )]
    }

    private func text(_ response: ParsedResponse) -> String { String(decoding: response.body, as: UTF8.self) }

    // MARK: - The path, masked

    func testACredentialInARulePathIsMaskedByNameAndTheRestIsKept() {
        let redactor = MCPRedactor()
        XCTAssertEqual(redactor.redactRulePath(realPath), shownPath)
        XCTAssertEqual(redactor.redactRulePath("/v1/users?*"), "/v1/users?*", "a path with nothing to hide is unchanged")
        XCTAssertEqual(redactor.redactRulePath("/search?q=shoes&api%5Fkey=\(secret)"), "/search?q=shoes&api%5Fkey=REDACTED",
                       "the name is read percent-decoded; the encoding written is kept")
        XCTAssertEqual(redactor.redactRulePath("/app;jsessionid=\(secret)?page=2"), "/app;jsessionid=REDACTED?page=2",
                       "a matrix parameter too")
        // Any of the separators starts the next pair: a harmless pair must
        // not swallow the credential after it.
        XCTAssertEqual(redactor.redactRulePath("/get?a=1;token=\(secret)"), "/get?a=1;token=REDACTED")
        XCTAssertEqual(redactor.redactRulePath("/get?next=/a?token=\(secret)"), "/get?next=/a?token=REDACTED")
        XCTAssertEqual(redactor.redactRulePath("/magic/\(jwt)/confirm"), "/magic/\(MCPRedactor.placeholder)/confirm",
                       "a credential shape anywhere, as a URL's path gets")
        XCTAssertEqual(MCPRedactor(enabled: false).redactRulePath(realPath), realPath)
    }

    /// A regex path is no URL (`URLComponents` cannot read it); it keeps its
    /// shape around the mask — the escaped `?`, a closing group, the anchor.
    func testARegexPathKeepsItsShapeAroundTheMask() {
        let redactor = MCPRedactor()
        XCTAssertEqual(redactor.redactRulePath(#"/users/\d+\?api_key=\#(secret)$"#, matchType: .regex), #"/users/\d+\?api_key=REDACTED$"#)
        XCTAssertEqual(redactor.redactRulePath(#"/cb(\?token=\#(secret))"#, matchType: .regex), #"/cb(\?token=REDACTED)"#)
    }

    /// The review's case: every regex value was masked, `\w+` included, so an
    /// agent could neither read a regex rule's pattern nor edit its path (an
    /// edit around a mask is refused). What a regex matches LITERALLY decides:
    /// classes, shorthands and counted quantifiers match no letter literally.
    func testARegexRulesPatternValuesStayReadable() {
        let redactor = MCPRedactor()
        for path in [#"/api\?token=\w+"#, #"/api\?token=[A-Za-z0-9]{32}"#, #"/api\?token=[^&]+&page=\d+"#,
                     #"/api\?token=.{20,}"#, #"/api\?token=(?:\w|-)+$"#, #"/api\?token=[[:alnum:]_-]{8,64}"#] {
            XCTAssertEqual(redactor.redactRulePath(path, matchType: .regex), path)
        }
        // Literal text left once the syntax is out is a credential's, masked.
        for (path, shown) in [
            (#"/api\?token=abc\.def"#, #"/api\?token=REDACTED"#),
            (#"/api\?token=sk_[a-z0-9]+"#, #"/api\?token=REDACTED"#),
            // The closing group and anchor stay outside the mask, as for any value.
            (#"/api\?token=(prod|dev)$"#, #"/api\?token=REDACTED)$"#),
            (#"/api\?token=\Qshort-secret\E"#, #"/api\?token=REDACTED"#),
            (#"/api\?token=\x41\x42"#, #"/api\?token=REDACTED"#),
        ] {
            XCTAssertEqual(redactor.redactRulePath(path, matchType: .regex), shown, path)
        }
        // In a wildcard path the same characters are text, not syntax.
        XCTAssertEqual(redactor.redactRulePath(#"/api?token=\w+"#, matchType: .wildcard), "/api?token=REDACTED")
        XCTAssertEqual(MCPRedactor.regexLiterals("[abc"), "[abc", "an unterminated set is text: it fails toward masking")
        XCTAssertEqual(MCPRedactor.regexLiterals(#"a[b\]c]d{2}e{x}\.\w"#), "ad" + "e{x}.")
    }

    /// The review's case: a value ended at every `;` or `?`, so a credential
    /// holding one left its tail readable (`token=REDACTED;def`). They end a
    /// value only when another `name=` follows, as a URL's query reads them.
    func testACredentialHoldingASemicolonOrQuestionMarkIsMaskedWhole() {
        let redactor = MCPRedactor()
        XCTAssertEqual(redactor.redactRulePath("/get?token=abc;def"), "/get?token=REDACTED")
        XCTAssertEqual(redactor.redactRulePath("/get?token=abc?def"), "/get?token=REDACTED")
        XCTAssertEqual(redactor.redactRulePath("/get?token=abc;def&page=2"), "/get?token=REDACTED&page=2")
        XCTAssertEqual(redactor.redactRulePath("/get?token=abc;def;page=2"), "/get?token=REDACTED;page=2")
        XCTAssertEqual(redactor.redactRulePath("/get?token=abc?next=/a"), "/get?token=REDACTED?next=/a")
        // A value that runs through `;` and `?` holds the mask with whatever
        // an agent typed after it — still a mask, still refused.
        XCTAssertEqual(MCPRedactor.redactionMarker(in: "/get?token=REDACTED?x"), "token=REDACTED")
        XCTAssertEqual(MCPRedactor.redactionMarker(in: "/get?token=REDACTED;v2"), "token=REDACTED")
        XCTAssertNil(MCPRedactor.redactionMarker(in: "/get?token=REDACTEDv2"), "a word that starts with it is the agent's")
    }

    /// `?access_token=*` is how a rule says "any token": no letter, no digit,
    /// no credential.
    func testAWildcardValueIsAPatternAndStaysReadable() {
        let redactor = MCPRedactor()
        for path in ["/get?access_token=*", "/get?access_token=.*&page=2", "/get?token=&page=2"] {
            XCTAssertEqual(redactor.redactRulePath(path), path)
        }
    }

    func testMaskingTwiceGivesWhatMaskingOnceDid() {
        let redactor = MCPRedactor()
        for path in [realPath, "/magic/\(jwt)/confirm?token=\(secret)", #"/users/\d+\?api_key=\#(secret)$"#,
                     "/get?token=abc;def&page=2", #"/api\?token=\w+&key=abc\.def"#] {
            for matchType in [MCPMatchType.wildcard, .regex] {
                let once = redactor.redactRulePath(path, matchType: matchType)
                XCTAssertEqual(redactor.redactRulePath(once, matchType: matchType), once, path)
            }
        }
    }

    // MARK: - Every rule an agent reads

    func testListRulesShowsThePathMaskedAndTheStoreKeepsItReal() throws {
        storeRule(path: realPath)
        let response = try send(makeRouter(), "GET", "/v1/rules")
        XCTAssertEqual(response.status, 200)
        XCTAssertFalse(text(response).contains(secret), text(response))
        struct Envelope: Decodable { let rules: [MCPRule] }
        XCTAssertEqual(try JSONDecoder().decode(Envelope.self, from: response.body).rules.first?.path, shownPath)
        XCTAssertEqual(rules.stored.first?.path, realPath, "redaction is egress only: the rule still matches the real request")
    }

    /// The case the review found: the mock's path is derived from the
    /// capture, token and all, and went back to the agent raw.
    func testTheMockCreateAndUpdateRepliesShowThePathMasked() throws {
        rules.mockDerivedPath = realPath
        let mock = try send(makeRouter(), "POST", "/v1/rules/from-session", ["uid": "s1"])
        XCTAssertEqual(mock.status, 201)
        XCTAssertFalse(text(mock).contains(secret), text(mock))
        XCTAssertEqual(try JSONDecoder().decode(MCPRule.self, from: mock.body).path, shownPath)
        XCTAssertEqual(rules.stored.first?.path, realPath, "stored as derived: the mock must match the request it came from")

        // An agent's own raw path goes back to it masked too — the same rule
        // for every rule a write returns.
        let created = try send(makeRouter(), "POST", "/v1/rules", ["hostId": 7, "mode": "override", "path": realPath, "responseBody": "{}"])
        XCTAssertEqual(created.status, 201)
        XCTAssertFalse(text(created).contains(secret), text(created))

        storeRule(path: realPath)
        let updated = try send(makeRouter(), "PATCH", "/v1/rules/3", ["enabled": false])
        XCTAssertEqual(updated.status, 200)
        XCTAssertFalse(text(updated).contains(secret), text(updated))
        XCTAssertEqual(rules.stored.first?.path, realPath)
    }

    /// The user excepted the host so they could SEE its values: its rules'
    /// paths are raw, like its sessions.
    func testAnExceptedHostsRulePathIsShownRaw() throws {
        storeRule(path: realPath)
        let router = makeRouter(redactor: MCPRedactor(policy: MCPRedactionPolicy(exceptedHosts: ["api.example.com"])))
        XCTAssertTrue(text(try send(router, "GET", "/v1/rules")).contains(secret))
        storeRule(path: realPath, host: nil)
        XCTAssertFalse(text(try send(router, "GET", "/v1/rules")).contains(secret),
                       "a rule whose host filter is gone cannot be excepted: it is masked")
    }

    // MARK: - The activity log

    /// The panel is the user's own window and shows the path as it is — what
    /// makes the decision informed. The log keeps it masked: create_rule,
    /// update_rule and delete_rule name the rule's pattern in their summary.
    func testTheLogNeverKeepsAPathsCredentialAndThePanelShowsIt() throws {
        let router = makeRouter()
        XCTAssertEqual(try send(router, "POST", "/v1/rules", ["hostId": 7, "mode": "override", "path": realPath, "responseBody": "{}"]).status, 201)
        storeRule(path: realPath)
        XCTAssertEqual(try send(router, "PATCH", "/v1/rules/3", ["path": "/get?access_token=\(secret)&page=*"]).status, 200)
        storeRule(path: realPath)
        XCTAssertEqual(try send(router, "DELETE", "/v1/rules/3").status, 200)

        XCTAssertEqual(audit.entries.count, 3)
        for entry in audit.entries {
            let logged = ([entry.action.summary] + entry.action.details + [entry.detail ?? ""]).joined(separator: "\n")
            XCTAssertFalse(logged.contains(secret), "\(entry.action.kind): \(logged)")
            XCTAssertTrue(logged.contains("access_token=REDACTED"), "the reader still sees which parameter was hidden: \(logged)")
        }
        XCTAssertTrue(consent.asked.allSatisfy { ([$0.summary] + $0.details).joined().contains(secret) },
                      "the panel shows the human what they are approving")
    }

    /// What the log keeps is read back at every launch and cleaned again, so
    /// the pass must not change its own output — and a shape in a path
    /// (a JWT segment) goes like a URL's does.
    func testTheLogsPassOverAPathIsStableAndCatchesShapes() {
        let redactor = MCPRedactor()
        let entry = MCPAuditEntry(
            action: MCPAgentAction(kind: .updateRule,
                                   summary: "Change rule #3 (override Any /magic/\(jwt)/confirm?token=\(secret) on api.example.com)",
                                   details: ["Path → \(realPath)", "Pattern: \(realPath)"]),
            outcome: .performed,
            detail: "rule #3"
        )
        let once = redactor.redactLogEntry(entry)
        let logged = ([once.action.summary] + once.action.details).joined(separator: "\n")
        XCTAssertFalse(logged.contains(secret), logged)
        XCTAssertFalse(logged.contains("eyJhbGciOiJIUzI1NiJ9"), logged)
        XCTAssertTrue(once.action.summary.hasSuffix("?token=REDACTED on api.example.com)"), once.action.summary)
        XCTAssertEqual(redactor.redactLogEntry(once), once)
    }

    /// Export… reads the log AND the undo snapshot, which keeps the rule's
    /// real path for the undo that writes it back.
    func testAnExportedUndoSnapshotShowsThePathMasked() {
        let rule = MCPRule(id: 3, hostId: 7, host: "api.example.com", enabled: true, mode: .override, matchType: .wildcard,
                           path: realPath, method: "", scheme: "https")
        let entry = MCPRedactor().redactLogEntry(MCPAuditEntry(
            action: MCPAgentAction(kind: .deleteRule, summary: "Delete rule #3 (override Any \(realPath) on api.example.com)"),
            outcome: .performed, detail: "rule #3", previousState: .rule(rule)
        ))
        XCTAssertEqual(entry.previousState, .rule(rule), "the snapshot keeps the real path: an undo writes it back")
        for export in [MCPAuditExport.text([entry]), MCPAuditExport.json([entry])] {
            XCTAssertFalse(export.content.contains(secret), export.content)
        }
    }

    // MARK: - A mask sent back

    /// An agent sending the rule back as it read it — the path masked, one
    /// field changed — keeps the stored path. The mask never overwrites the
    /// credential it hid.
    func testTheShownPathSentBackKeepsTheStoredOne() throws {
        storeRule(path: realPath)
        let response = try send(makeRouter(), "PATCH", "/v1/rules/3", ["path": shownPath, "enabled": false])
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(rules.stored.first?.path, realPath)
        XCTAssertEqual(rules.stored.first?.enabled, false)
        XCTAssertFalse(consent.asked.first?.details.contains { $0.hasPrefix("Path →") } ?? true,
                       "the path does not change, so the panel does not say it does: \(consent.asked.first?.details ?? [])")
    }

    func testAPatchThatOnlySendsTheShownPathBackIsRefusedBeforeAnyoneIsAsked() throws {
        storeRule(path: realPath)
        let response = try send(makeRouter(), "PATCH", "/v1/rules/3", ["path": shownPath])
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(text(response).contains("changes nothing"), text(response))
        XCTAssertTrue(consent.asked.isEmpty)
    }

    /// Which value the mask stands for, once the agent edited around it, is
    /// not knowable: refused, before the human is interrupted.
    func testAMaskedPathThatWasEditedIsRefused() throws {
        storeRule(path: realPath)
        let response = try send(makeRouter(), "PATCH", "/v1/rules/3", ["path": "/get?access_token=REDACTED&page=3"])
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(text(response).contains("access_token=REDACTED"), text(response))
        XCTAssertTrue(text(response).contains("Leave path out"), text(response))
        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertEqual(rules.stored.first?.path, realPath)
    }

    /// Switching the match type with the path sent back as shown validates
    /// the STORED path against the new type — as when the path is left out.
    func testTheShownPathSentBackWithANewMatchTypeUsesTheStoredPath() throws {
        let patch = try MCPWriteValidation.validate(
            MCPRulePatch(matchType: .regex, path: "/v1/items?access_token=REDACTED"),
            currentMode: .override, currentMatchType: .wildcard,
            currentPath: "/v1/items?access_token=\(secret)", shownPath: "/v1/items?access_token=REDACTED"
        )
        XCTAssertEqual(patch.path, "/v1/items?access_token=\(secret)")
        XCTAssertEqual(patch.matchType, .regex)
    }

    /// As it normalises counts as shown: an agent dropping the leading slash
    /// is still sending the rule's own path back.
    func testTheShownPathWithoutItsLeadingSlashKeepsTheStoredOne() throws {
        let patch = try MCPWriteValidation.validate(
            MCPRulePatch(enabled: false, path: "get?access_token=REDACTED&page=2"),
            currentMode: .override, currentMatchType: .wildcard, currentPath: realPath, shownPath: shownPath
        )
        XCTAssertNil(patch.path)
        XCTAssertEqual(patch.enabled, false)
    }

    /// Switching a rule to regex re-validates its STORED path, and the
    /// refusal quoted it — token and all — to the agent that was shown it
    /// masked.
    func testARefusedMatchTypeSwitchQuotesThePathAsShown() throws {
        storeRule(path: "/get?access_token=\(secret)&q=(a")
        let response = try send(makeRouter(), "PATCH", "/v1/rules/3", ["matchType": "regex"])
        XCTAssertEqual(response.status, 400)
        XCTAssertFalse(text(response).contains(secret), text(response))
        XCTAssertTrue(text(response).contains("access_token=REDACTED&q=(a"), text(response))
        XCTAssertTrue(consent.asked.isEmpty)
    }

    /// Nothing was masked: the path sent back is an ordinary value.
    func testAPathSentBackUnmaskedIsAnOrdinaryValue() throws {
        let patch = try MCPWriteValidation.validate(
            MCPRulePatch(path: "/v1/users?*"),
            currentMode: .override, currentMatchType: .wildcard,
            currentPath: "/v1/users?*", shownPath: "/v1/users?*"
        )
        XCTAssertEqual(patch.path, "/v1/users?*")
    }

    /// A path copied from a redacted read into a NEW rule would match the
    /// word REDACTED; create_rule and mock_from_session refuse it before
    /// anyone is asked.
    func testCreateAndMockRefuseAMaskedPath() throws {
        let router = makeRouter(session: makeSession(uid: "s1", url: "https://api.example.com/get?access_token=\(secret)"))
        let created = try send(router, "POST", "/v1/rules", ["hostId": 7, "mode": "override", "path": shownPath, "responseBody": "{}"])
        XCTAssertEqual(created.status, 400)
        XCTAssertTrue(text(created).contains("access_token=REDACTED"), text(created))
        let mock = try send(router, "POST", "/v1/rules/from-session", ["uid": "s1", "path": shownPath])
        XCTAssertEqual(mock.status, 400)
        XCTAssertTrue(text(mock).contains("Leave path out"), text(mock))
        let shaped = try send(router, "POST", "/v1/rules", ["hostId": 7, "mode": "override",
                                                            "path": "/magic/\(MCPRedactor.placeholder)/x", "responseBody": "{}"])
        XCTAssertEqual(shaped.status, 400, "the shape pass's mask too")
        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertTrue(rules.created.isEmpty)
    }

    /// REDACTED is only a mask where redaction puts one — after a credential
    /// name. Elsewhere it is whatever the agent means by it.
    func testTheWordREDACTEDOutsideACredentialIsAllowed() throws {
        let router = makeRouter()
        for path in ["/x?status=REDACTED", "/reports/REDACTED", "/get?access_token=*"] {
            XCTAssertEqual(try send(router, "POST", "/v1/rules", ["hostId": 7, "mode": "override", "path": path, "responseBody": "{}"]).status,
                           201, path)
        }
        XCTAssertNil(MCPRedactor.redactionMarker(in: "/x?status=REDACTED"))
        XCTAssertEqual(MCPRedactor.redactionMarker(in: "/x?api%5Fkey=REDACTED)"), "api%5Fkey=REDACTED",
                       "named as written in the path, so the refusal quotes what the agent sent")
        XCTAssertEqual(MCPRedactor.redactionMarker(in: "/magic/%C2%ABredacted%C2%BB/x"), MCPRedactor.placeholder,
                       "as a URL percent-encodes it")
    }

    // MARK: - The review's cases

    /// "Or as it normalises" held only for the ASCII query mask: the shape
    /// mask is not ASCII, so a wildcard path holding it normalises to
    /// `%C2%ABredacted%C2%BB` and never equalled the text shown.
    func testTheShapeMaskSentBackWithoutItsLeadingSlashKeepsTheStoredPath() throws {
        let real = "/magic/\(jwt)/confirm"
        let shown = MCPRedactor().redactRule(MCPRule(
            id: 3, hostId: 7, host: "api.example.com", enabled: true, mode: .override, matchType: .wildcard,
            path: real, method: "", scheme: "https"
        )).path
        XCTAssertEqual(shown, "/magic/\(MCPRedactor.placeholder)/confirm")
        for sent in [shown, String(shown.dropFirst()), " \(shown) "] {
            let patch = try MCPWriteValidation.validate(
                MCPRulePatch(enabled: false, path: sent),
                currentMode: .override, currentMatchType: .wildcard, currentPath: real, shownPath: shown
            )
            XCTAssertNil(patch.path, sent)
        }
        XCTAssertThrowsError(try MCPWriteValidation.validate(
            MCPRulePatch(path: "magic/\(MCPRedactor.placeholder)/cancel"),
            currentMode: .override, currentMatchType: .wildcard, currentPath: real, shownPath: shown
        ), "a mask edited around is still refused")
    }

    /// The advice was `?access_token=*` whatever the match type — in a regex
    /// `?` and `*` are quantifiers, and a rule written that way never matches.
    /// Each refusal suggests the rule's own syntax, and the suggestion, put
    /// where the mask stood, matches the real request.
    func testTheRefusalSuggestsAPatternInTheRulesOwnSyntax() throws {
        let router = makeRouter()
        let url = "https://api.example.com/get?access_token=\(secret)&page=2"
        let cases: [(MCPMatchType, String, String, String)] = [
            (.wildcard, "/get?access_token=REDACTED&page=2", "(access_token=*)", "/get?access_token=*&page=2"),
            (.regex, #"/get\?access_token=REDACTED&page=2"#, "(access_token=[^&]*)", #"/get\?access_token=[^&]*&page=2"#),
        ]
        for (matchType, masked, suggestion, rewritten) in cases {
            let response = try send(router, "POST", "/v1/rules", ["hostId": 7, "mode": "override", "matchType": matchType.rawValue,
                                                                  "path": masked, "responseBody": "{}"])
            XCTAssertEqual(response.status, 400)
            XCTAssertTrue(text(response).contains(suggestion), "\(matchType): \(text(response))")
            XCTAssertTrue(OverridePattern.matches(url: url, path: rewritten, isRegex: matchType == .regex),
                          "\(matchType): the suggestion, where the mask stood, matches the real request")
        }
        XCTAssertFalse(OverridePattern.matches(url: url, path: "/get?access_token=*&page=2", isRegex: true),
                       "the old advice, in a regex rule, never matches")
        // The parameter as written in the path; the shape mask replaced alone.
        XCTAssertEqual(MCPWriteValidation.maskReplacement(for: "api%5Fkey=REDACTED", matchType: .wildcard), "a wildcard in its place (api%5Fkey=*)")
        XCTAssertEqual(MCPWriteValidation.maskReplacement(for: MCPRedactor.placeholder, matchType: .wildcard), "a wildcard in its place (*)")
        XCTAssertEqual(MCPWriteValidation.maskReplacement(for: MCPRedactor.placeholder, matchType: .regex), "a pattern in its place ([^/?&]+)")
        XCTAssertTrue(OverridePattern.matches(url: "https://api.example.com/magic/\(jwt)/confirm", path: "/magic/[^/?&]+/confirm", isRegex: true))
        // mock_from_session and update_rule give the same, in their own words.
        let mock = try send(router, "POST", "/v1/rules/from-session", ["uid": "s1", "matchType": "regex", "path": #"/get\?token=REDACTED"#])
        XCTAssertEqual(mock.status, 400)
        XCTAssertTrue(text(mock).contains("(token=[^&]*)"), text(mock))
        rules.stored = [MCPRule(id: 3, hostId: 7, host: "api.example.com", enabled: true, mode: .override, matchType: .regex,
                                path: #"/get\?token=\#(secret)"#, method: "", scheme: "https", responseBody: "{}")]
        let update = try send(router, "PATCH", "/v1/rules/3", ["path": #"/get/v2\?token=REDACTED"#])
        XCTAssertEqual(update.status, 400)
        XCTAssertTrue(text(update).contains("Leave path out") && text(update).contains("(token=[^&]*)"), text(update))
        XCTAssertTrue(consent.asked.isEmpty)
    }

    /// test_pattern said a masked path matched a masked URL — both read
    /// REDACTED, whatever the real tokens — for a path create_rule refuses to
    /// store. Its own comment promised the same validation as create_rule.
    func testTestPatternRefusesAMaskedPathLikeCreateRule() throws {
        let router = makeRouter()
        let masked = try send(router, "POST", "/v1/patterns/test", ["path": shownPath, "url": "https://api.example.com\(shownPath)"])
        XCTAssertEqual(masked.status, 400)
        XCTAssertTrue(text(masked).contains("access_token=REDACTED") && text(masked).contains("(access_token=*)"), text(masked))
        let wildcard = try send(router, "POST", "/v1/patterns/test", ["path": "/get?access_token=*&page=2", "url": "https://api.example.com\(shownPath)"])
        XCTAssertEqual(wildcard.status, 200)
        XCTAssertTrue(text(wildcard).contains(#""matches":true"#), text(wildcard))
    }

    /// A regex rule read through list_rules shows its pattern values, and an
    /// agent can edit the path around them — nothing in it is a mask.
    func testARegexRuleCanBeReadAndEditedByAnAgent() throws {
        let pattern = #"/api\?token=\w+&page=\d+"#
        rules.stored = [MCPRule(id: 3, hostId: 7, host: "api.example.com", enabled: true, mode: .override, matchType: .regex,
                                path: pattern, method: "", scheme: "https", responseBody: "{}")]
        let router = makeRouter()
        struct Envelope: Decodable { let rules: [MCPRule] }
        XCTAssertEqual(try JSONDecoder().decode(Envelope.self, from: send(router, "GET", "/v1/rules").body).rules.first?.path, pattern)
        let edited = #"/api/v2\?token=\w+&page=\d+"#
        XCTAssertEqual(try send(router, "PATCH", "/v1/rules/3", ["path": edited]).status, 200)
        XCTAssertEqual(rules.stored.first?.path, edited)
    }

    // MARK: - The undo's own row

    private func undoRows() -> [MCPAuditEntry] {
        let rule = MCPRule(id: 3, hostId: 7, host: "api.example.com", enabled: true, mode: .override, matchType: .wildcard,
                           path: realPath, method: "", scheme: "https")
        return [MCPUndoPlan.restoreRule(rule), .recreateRule(rule)].map {
            MCPUndo.entry(for: $0, outcome: .performed, detail: "rule #3")
        }
    }

    /// An undo's summary quotes the rule's REAL path from the snapshot ("Put
    /// rule #3 back as it was (override /get?access_token=…)"), and the app
    /// kept that row as it was — saved to UserDefaults, and exported in the
    /// same session. It goes through the log's pass like every entry.
    func testAnUndoRowIsKeptWithThePathsCredentialMasked() {
        let redactor = MCPRedactor()
        for row in undoRows() {
            XCTAssertTrue(row.action.summary.contains(secret), "the plan quotes the real path: \(row.action.summary)")
            let kept = redactor.redactLogEntry(row)
            XCTAssertFalse(kept.action.summary.contains(secret), kept.action.summary)
            XCTAssertTrue(kept.action.summary.contains("access_token=REDACTED&page=2"), kept.action.summary)
            XCTAssertEqual(redactor.redactLogEntry(kept), kept)
        }
    }

    /// Export… redacts on its own, whatever the log did: a row nobody passed
    /// through the log's pass leaves no credential in either format.
    func testAnExportMasksAPathsCredentialInARowNobodyRedacted() {
        for export in [MCPAuditExport.text(undoRows()), MCPAuditExport.json(undoRows())] {
            XCTAssertFalse(export.content.contains(secret), export.content)
            XCTAssertTrue(export.content.contains("access_token=REDACTED"), export.content)
        }
    }

    /// The app side, read from the source (Sources/UI has no test target):
    /// the undo's row is inserted through the log's pass, and nowhere raw.
    func testTheAppKeepsTheUndoRowThroughTheLogsPass() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("UI/Services/MCPAgentActivity.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line }
            .joined(separator: "\n")
        XCTAssertTrue(source.contains("self.insert(MCPRedactionSettings.shared.currentRedactor.redactLogEntry(undone))"),
                      "the undo's row is no longer kept through redactLogEntry")
        XCTAssertFalse(source.contains("self.insert(MCPUndo.entry("), "the undo's row is kept raw again")
        XCTAssertEqual(source.components(separatedBy: "self.insert(").count, 3,
                       "one insert for a recorded entry (the router redacted it), one for the undo's row — a new one needs the log's pass too")
    }
}
