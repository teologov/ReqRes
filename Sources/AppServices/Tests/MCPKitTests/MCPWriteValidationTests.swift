//
//  MCPWriteValidationTests.swift
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

import XCTest
@testable import MCPKit

final class MCPWriteValidationTests: XCTestCase {

    private func invalidMessage(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch let error as MCPWriteError {
            if case .invalid(let message) = error { return message }
            return "wrong case: \(error)"
        } catch { return "wrong error: \(error)" }
    }

    // MARK: - Rule drafts

    func testDraftIsNormalisedLikeTheAppsForm() throws {
        let draft = MCPRuleDraft(hostId: 1, mode: .override, path: "users?*", method: "post", scheme: "HTTPS", responseStatus: 503)
        let normalized = try MCPWriteValidation.validate(draft)
        XCTAssertEqual(normalized.path, "/users?*", "the form stores a leading slash")
        XCTAssertEqual(normalized.method, "POST")
        XCTAssertEqual(normalized.scheme, "https")
        XCTAssertEqual(normalized.responseStatus, 503)
    }

    func testRegexPathIsKeptVerbatimAndMustCompile() throws {
        let ok = try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .extend, matchType: .regex, path: " /users/\\d+$ "))
        XCTAssertEqual(ok.path, "/users/\\d+$", "a regex is stored verbatim, not URL-normalised")
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .extend, matchType: .regex, path: "/(users")) })
    }

    func testEmptyPathUnknownMethodSchemeAndStatusAreRejectedWithGuidance() {
        XCTAssertTrue(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .override, path: "  ")) }?.contains("/users?*") ?? false)
        XCTAssertTrue(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .override, path: "/x", method: "FETCH")) }?.contains("GET, POST") ?? false)
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .override, path: "/x", scheme: "ftp")) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .override, path: "/x", responseStatus: 99)) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .override, path: "/x", responseStatus: 600)) })
        XCTAssertTrue(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: -1, mode: .override, path: "/x")) }?.contains("hostId is required") ?? false)
        XCTAssertTrue(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .override, path: "/x")) }?.contains("add_host") ?? false, "no host id: the message says how to get one")
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 0, mode: .override, path: "/x")) })
    }

    /// The proxy compiles `scheme://host + path`; a host in the path is
    /// matched twice, so it is refused with the path to use instead.
    func testAHostWrittenIntoThePathIsRejected() {
        let message = invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, path: "api.example.com/users?*")) }
        XCTAssertTrue(message?.contains("host comes from host_id") ?? false, "\(message ?? "nil")")
        XCTAssertTrue(message?.contains("/users?*") ?? false, "it suggests the corrected path")
        XCTAssertNoThrow(try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, path: "users?*")), "a plain segment is still fine")
        XCTAssertNoThrow(try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, path: "/v1.0/users")))
    }

    /// The proxy SEARCHES for `scheme://host + path`, so a leading ^ can never
    /// match — the rule would be silently dead.
    func testRegexPathCannotStartWithCaret() {
        let message = invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, matchType: .regex, path: "^/users/\\d+$")) }
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, matchType: .regex, path: "users/\\d+$")) }, "and it must start at the path")
        XCTAssertTrue(message?.contains("anchors the pattern after the host") ?? false, "\(message ?? "nil")")
        XCTAssertTrue(message?.contains("/users/\\d+$") ?? false, "it suggests the pattern without the caret")
        XCTAssertNoThrow(try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, matchType: .regex, path: "/users/\\d+$")))
    }

    func testAgentStringsAreBounded() {
        let longPath = "/" + String(repeating: "a", count: MCPWriteValidation.maxPathLength)
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, path: longPath)) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, path: "/a\nb")) })
        let longValue = String(repeating: "v", count: MCPWriteValidation.maxHeaderValueLength + 1)
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .extend, path: "/x", requestHeaders: ["X-A": longValue])) })
        let longFilePath = "/" + String(repeating: "f", count: MCPWriteValidation.maxFilePathLength)
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .mapLocal, path: "/x", localFile: MCPLocalFile(path: longFilePath))) })
    }

    func testHeaderNamesAndValuesCannotSmuggleLineBreaks() {
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .extend, path: "/x", requestHeaders: ["": "v"])) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .extend, path: "/x", requestHeaders: ["X-A: b": "v"])) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .extend, path: "/x", responseHeaders: ["X-A": "v\r\nInjected: yes"])) })
        XCTAssertNoThrow(try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .extend, path: "/x", responseHeaders: ["X-A": "fine"])))
    }

    func testMapLocalNeedsExactlyOneFileSourceAndNoInlineBody() throws {
        XCTAssertTrue(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .mapLocal, path: "/x")) }?.contains("localFile") ?? false)
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .mapLocal, path: "/x", localFile: MCPLocalFile())) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .mapLocal, path: "/x", localFile: MCPLocalFile(content: "{}", path: "/tmp/a.json"))) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .mapLocal, path: "/x", localFile: MCPLocalFile(path: "relative/a.json"))) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .mapLocal, path: "/x", responseBody: "{}", localFile: MCPLocalFile(content: "{}"))) })

        let inline = try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .mapLocal, path: "/x", localFile: MCPLocalFile(content: "{\"ok\":true}")))
        XCTAssertEqual(inline.localFile?.contentType, "application/json", "inline content defaults to JSON")
        let typed = try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .mapLocal, path: "/x", localFile: MCPLocalFile(content: "<p/>", contentType: "text/html")))
        XCTAssertEqual(typed.localFile?.contentType, "text/html")
    }

    func testInlineContentIsCappedBelowTheTransportBodyLimit() {
        let big = String(repeating: "x", count: MCPWriteValidation.maxInlineFileBytes + 1)
        XCTAssertTrue(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .mapLocal, path: "/x", localFile: MCPLocalFile(content: big))) }?.contains("KB") ?? false)
        XCTAssertLessThan(MCPWriteValidation.maxInlineFileBytes, MCPHTTPParser.maxBodyBytes)
    }

    func testOverrideAndExtendRejectALocalFile() {
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .override, path: "/x", localFile: MCPLocalFile(content: "{}"))) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(mode: .extend, path: "/x", localFile: MCPLocalFile(path: "/a"))) })
    }

    // MARK: - Patches

    private func patch(_ p: MCPRulePatch, mode: MCPRuleMode = .override, matchType: MCPMatchType = .wildcard, path: String = "/users?*") throws -> MCPRulePatch {
        try MCPWriteValidation.validate(p, currentMode: mode, currentMatchType: matchType, currentPath: path)
    }

    func testEmptyPatchIsRejected() {
        XCTAssertNotNil(invalidMessage { try self.patch(MCPRulePatch()) })
    }

    func testPatchNormalisesOnlyWhatItCarries() throws {
        let result = try patch(MCPRulePatch(path: "orders?*", method: "delete"))
        XCTAssertEqual(result.path, "/orders?*")
        XCTAssertEqual(result.method, "DELETE")
        XCTAssertNil(result.scheme)
        XCTAssertNil(result.responseStatus)
    }

    func testPatchPathUsesTheNewMatchTypeWhenBothChange() throws {
        let result = try patch(MCPRulePatch(matchType: .regex, path: "/a/.*$"))
        XCTAssertEqual(result.path, "/a/.*$")
        XCTAssertNotNil(invalidMessage { try self.patch(MCPRulePatch(path: "/(a"), matchType: .regex) })
    }

    /// Switching to regex without a path would leave "/users?*" to be compiled
    /// as a regex by the proxy; the current path must survive that switch.
    func testSwitchingToRegexValidatesTheExistingPath() {
        XCTAssertNotNil(invalidMessage { try self.patch(MCPRulePatch(matchType: .regex), path: "/users?*(") },
                        "a stored wildcard path that is not a valid regex cannot become a regex rule")
        XCTAssertNoThrow(try patch(MCPRulePatch(matchType: .regex), path: "/users"))
    }

    func testPatchEnforcesTheModePayloadRulesAgainstTheResultingMode() {
        // localFile on a rule that stays override
        XCTAssertTrue(invalidMessage { try self.patch(MCPRulePatch(localFile: MCPLocalFile(content: "{}"))) }?.contains("map_local") ?? false)
        // responseBody on a rule that stays map_local
        XCTAssertNotNil(invalidMessage { try self.patch(MCPRulePatch(responseBody: "{}"), mode: .mapLocal) })
        // switching to map_local without a file
        XCTAssertNotNil(invalidMessage { try self.patch(MCPRulePatch(mode: .mapLocal)) })
        // both together is fine
        XCTAssertNoThrow(try patch(MCPRulePatch(mode: .mapLocal, localFile: MCPLocalFile(content: "{}"))))
        // and a map_local rule may keep its mode while replacing the file
        XCTAssertNoThrow(try patch(MCPRulePatch(localFile: MCPLocalFile(content: "{}")), mode: .mapLocal))
    }

    // MARK: - Hosts

    func testHostDraftIsLowercasedTrimmedAndValidated() throws {
        let host = try MCPWriteValidation.validate(MCPHostDraft(host: "  API.Example.com ", scheme: "HTTP", port: 8080))
        XCTAssertEqual(host.host, "api.example.com")
        XCTAssertEqual(host.scheme, "http")
        XCTAssertEqual(host.port, 8080)
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPHostDraft(host: "https://api.example.com")) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPHostDraft(host: "api.example.com/path")) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPHostDraft(host: "api.example.com", port: 0)) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPHostDraft(host: "api.example.com", scheme: "ws")) })
    }

    /// Exactly the app's `String.isValidHostname`, so the bridge cannot create
    /// a host filter the sidebar form would reject.
    func testHostnameRuleMatchesTheAppsForm() {
        XCTAssertTrue(MCPWriteValidation.isValidHostname("api-1.example.co.uk"))
        XCTAssertTrue(MCPWriteValidation.isValidHostname("example.com"))
        XCTAssertFalse(MCPWriteValidation.isValidHostname("localhost"), "the form requires a dot")
        XCTAssertFalse(MCPWriteValidation.isValidHostname("a.b"), "the form requires a TLD of 2+")
        XCTAssertFalse(MCPWriteValidation.isValidHostname(""))
        XCTAssertFalse(MCPWriteValidation.isValidHostname("-bad.example.com"))
        XCTAssertFalse(MCPWriteValidation.isValidHostname("bad-.example.com"))
        XCTAssertFalse(MCPWriteValidation.isValidHostname("a..b.com"))
        XCTAssertFalse(MCPWriteValidation.isValidHostname(".example.com"))
        XCTAssertFalse(MCPWriteValidation.isValidHostname("example.com."))
        XCTAssertFalse(MCPWriteValidation.isValidHostname("exa mple.com"))
        XCTAssertFalse(MCPWriteValidation.isValidHostname("api.example.com:3000"), "a port is not part of a hostname")
        XCTAssertFalse(MCPWriteValidation.isValidHostname(String(repeating: "a", count: 64) + ".com"))
    }

    // MARK: - Any method (1.1.0)

    func testAnyMethodIsStoredAsEmptyAndASpecificOneStaysSpecific() throws {
        for spelling in ["", "  ", "*", "any", "ANY", "Any"] {
            let draft = MCPRuleDraft(hostId: 1, mode: .override, path: "/x", method: spelling)
            XCTAssertEqual(try MCPWriteValidation.validate(draft).method, "", "'\(spelling)' means any method")
        }
        XCTAssertEqual(try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, path: "/x", method: "put")).method, "PUT")
        let message = invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, path: "/x", method: "FETCH")) }
        XCTAssertTrue(message?.contains("any") ?? false, "the error names the any-method option: \(message ?? "nil")")
    }

    func testAPatchCanWidenARuleToAnyMethod() throws {
        let normalized = try MCPWriteValidation.validate(MCPRulePatch(method: "any"), currentMode: .override, currentMatchType: .wildcard, currentPath: "/x")
        XCTAssertEqual(normalized.method, "")
    }

    func testRuleMethodReadsAndEditsLikeTheCore() {
        XCTAssertEqual(RuleMethod.displayName(""), "Any", "an any-method rule used to render as a blank")
        XCTAssertEqual(RuleMethod.displayName("*"), "Any")
        XCTAssertEqual(RuleMethod.displayName("post"), "POST")
        XCTAssertEqual(RuleMethod.formSelection(forStored: ""), "", "a migrated rule opens as Any, not GET")
        XCTAssertEqual(RuleMethod.formSelection(forStored: "get"), "GET")
        XCTAssertEqual(RuleMethod.formChoices(forStored: ""), ["", "GET", "POST", "PUT", "PATCH", "DELETE"])
        XCTAssertEqual(RuleMethod.formChoices(forStored: "PURGE").last, "PURGE",
                       "a stored method the picker does not list is kept, so saving does not change the rule")
        XCTAssertEqual(MCPWriteValidation.methods, RuleMethod.specific)
    }

    func testAnAnyMethodRuleReadsAsAnyToAgentsAndInTheConsentPanel() {
        let rule = MCPRule(id: 3, hostId: 1, host: "api.test", enabled: true, mode: .override, matchType: .wildcard,
                           path: "/x", method: "", scheme: "https", requestHeaders: [:], responseStatus: 200,
                           responseHeaders: [:], responseBody: nil, localFilePath: nil)
        XCTAssertTrue(MCPTextFormat.ruleRow(rule).contains("Any https://api.test/x"), MCPTextFormat.ruleRow(rule))
        XCTAssertTrue(MCPBridgeRouter.describe(rule).contains("override Any /x"), MCPBridgeRouter.describe(rule))
        let draft = MCPRuleDraft(hostId: 1, mode: .override, path: "/x")
        XCTAssertTrue(MCPBridgeRouter.describe(draft, host: "api.test").contains(": Any /x"))
    }

    // MARK: - Decoding defaults

    func testDraftDecodesWithFormDefaults() throws {
        let json = #"{"mode":"override","path":"/users?*"}"#.data(using: .utf8)!
        let draft = try JSONDecoder().decode(MCPRuleDraft.self, from: json)
        // Any method (""), not GET: the core honours a rule's method since
        // 1.1.0, so an agent's omitted method used to make its POST mock
        // never match (core step C4, decision D4).
        XCTAssertEqual(draft.method, RuleMethod.any)
        XCTAssertEqual(MCPRuleDraft(mode: .override, path: "/x").method, RuleMethod.any, "the Swift default agrees")
        XCTAssertEqual(draft.scheme, "https")
        XCTAssertEqual(draft.matchType, .wildcard)
        XCTAssertEqual(draft.responseStatus, 200)
        XCTAssertTrue(draft.enabled)
        XCTAssertNil(draft.hostId, "absent on the wire; validation demands it")
    }

    /// Left out, the status is the mode's start (core 95062d1): an extend
    /// rule keeps the server's — the core's migration leaves an agent's
    /// extend rule at 200 alone, and it would go on answering every response
    /// on its path as 200 (F17) — an override answers 200, and a map_local
    /// rule, which does not use it, stores 0. Resolved at the first decode,
    /// the helper's: it encodes the draft for the bridge.
    func testAnOmittedStatusIsTheModesStart() throws {
        func decoded(_ json: String) throws -> MCPRuleDraft {
            try JSONDecoder().decode(MCPRuleDraft.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decoded(#"{"mode":"extend","path":"/x"}"#).responseStatus, 0)
        XCTAssertEqual(try decoded(#"{"mode":"override","path":"/x"}"#).responseStatus, 200)
        XCTAssertEqual(try decoded(#"{"mode":"map_local","path":"/x"}"#).responseStatus, 0)
        XCTAssertEqual(try decoded(#"{"mode":"extend","path":"/x","responseStatus":null}"#).responseStatus, 0)
        XCTAssertEqual(try decoded(#"{"mode":"extend","path":"/x","responseStatus":404}"#).responseStatus, 404)
        XCTAssertEqual(MCPRuleDraft(mode: .extend, path: "/x").responseStatus, 0, "the Swift default agrees")
        XCTAssertEqual(MCPRuleDraft(mode: .override, path: "/x").responseStatus, 200)
        XCTAssertEqual(MCPRuleDraft(mode: .mapLocal, path: "/x").responseStatus, 0)
        XCTAssertEqual(MCPRuleDraft(mode: .extend, path: "/x", responseStatus: 418).responseStatus, 418)

        // What the helper sends the bridge is the resolved status, not a gap
        // the bridge would fill with another default.
        let wire = try JSONEncoder().encode(try decoded(#"{"mode":"extend","path":"/x"}"#))
        XCTAssertEqual(try JSONDecoder().decode(MCPRuleDraft.self, from: wire).responseStatus, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        XCTAssertEqual(object["responseStatus"] as? Int, 0)
    }

    /// Only a final status, 200…599, is one the core answers with — it reads
    /// anything else as "keep" where it forwards and 200 where it answers,
    /// and a 1xx crashed the extension; 0 keeps the server's, on extend.
    func testAStatusIsCheckedAgainstTheRulesMode() {
        func check(_ status: Int, _ mode: MCPRuleMode) -> String? {
            invalidMessage { try MCPWriteValidation.validateStatus(status, mode: mode) }
        }
        for mode in MCPRuleMode.allCases {
            for status in [200, 204, 302, 404, 500, 599] {
                XCTAssertNil(check(status, mode), "\(mode) \(status)")
            }
            for status in [-1, 1, 99, 100, 101, 103, 199, 600, 999] {
                XCTAssertNotNil(check(status, mode), "\(mode) \(status)")
            }
        }
        XCTAssertNil(check(0, .extend), "keep the server's status")
        XCTAssertNil(check(0, .mapLocal), "not used; what its missing file does")
        XCTAssertTrue(check(0, .override)?.contains("use mode extend") ?? false, check(0, .override) ?? "nil")
        XCTAssertTrue(check(101, .extend)?.contains("0 to keep the server's status") ?? false, check(101, .extend) ?? "nil")
        XCTAssertTrue(check(101, .mapLocal)?.contains("does not use responseStatus") ?? false, check(101, .mapLocal) ?? "nil")

        // Through the draft: the status against the draft's own mode.
        XCTAssertNoThrow(try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .extend, path: "/x", responseStatus: 0)))
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, path: "/x", responseStatus: 0)) })
        XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validate(MCPRuleDraft(hostId: 1, mode: .override, path: "/x", responseStatus: 101)) },
                        "build 52 accepted 100…599")
    }

    /// A patch keeps the stored status unless it sends one — through a change
    /// of mode too — and a status kept or sent is checked against the mode
    /// the rule will have.
    func testAPatchesStatusIsCheckedAgainstTheModeTheRuleWillHave() throws {
        func validated(_ p: MCPRulePatch, from mode: MCPRuleMode, stored: Int?) throws -> MCPRulePatch {
            try MCPWriteValidation.validate(p, currentMode: mode, currentMatchType: .wildcard, currentPath: "/x", currentStatus: stored)
        }
        // Kept through a change of mode.
        let keep = invalidMessage { try validated(MCPRulePatch(mode: .override), from: .extend, stored: 0) }
        XCTAssertTrue(keep?.contains("keeps the server's status") ?? false, keep ?? "nil")
        XCTAssertTrue(keep?.contains("Send responseStatus (200–599) with the mode change") ?? false, keep ?? "nil")
        let legacy = invalidMessage { try validated(MCPRulePatch(mode: .override), from: .extend, stored: 101) }
        XCTAssertTrue(legacy?.contains("stored status, 101") ?? false, legacy ?? "nil")
        XCTAssertNoThrow(try validated(MCPRulePatch(mode: .override), from: .extend, stored: 404))
        XCTAssertNoThrow(try validated(MCPRulePatch(mode: .extend), from: .override, stored: 200), "kept, and told (the panel)")
        XCTAssertNoThrow(try validated(MCPRulePatch(mode: .mapLocal, localFile: MCPLocalFile(content: "x")), from: .extend, stored: 0))
        XCTAssertNoThrow(try validated(MCPRulePatch(enabled: false), from: .override, stored: 101),
                         "no change of mode and no status sent: nothing about the status changes")
        // Sent, against the mode the rule will have.
        XCTAssertNoThrow(try validated(MCPRulePatch(mode: .override, responseStatus: 201), from: .extend, stored: 0))
        XCTAssertNotNil(invalidMessage { try validated(MCPRulePatch(responseStatus: 0), from: .override, stored: 200) })
        XCTAssertNoThrow(try validated(MCPRulePatch(mode: .extend, responseStatus: 0), from: .override, stored: 200))
        XCTAssertNotNil(invalidMessage { try validated(MCPRulePatch(mode: .override, responseStatus: 0), from: .extend, stored: 404) })
        XCTAssertNotNil(invalidMessage { try validated(MCPRulePatch(responseStatus: 100), from: .extend, stored: 0) })
        XCTAssertEqual(try validated(MCPRulePatch(responseStatus: 0), from: .extend, stored: 404).responseStatus, 0)
    }

    /// A map_local rule's status is not one it HAS: the core never uses it
    /// and list_rules never shows it. Made extend or override without one, a
    /// map_local rule starts with the new mode's — the form's behaviour, and
    /// create_rule's — whatever was stored: build 53's 0 refused the change
    /// to override ("this rule keeps the server's status"), an earlier
    /// form's 200 was let through and, on extend, answered every response
    /// with 200 (review of 261703b).
    func testAMapLocalRuleLeavingItStartsWithTheNewModesStatus() throws {
        func validated(_ p: MCPRulePatch, stored: Int?) throws -> MCPRulePatch {
            try MCPWriteValidation.validate(p, currentMode: .mapLocal, currentMatchType: .wildcard, currentPath: "/x", currentStatus: stored)
        }
        for stored in [0, 200, 404, nil] as [Int?] {
            let label = stored.map(String.init) ?? "nil"
            XCTAssertEqual(try validated(MCPRulePatch(mode: .override, responseBody: "{}"), stored: stored).responseStatus, 200,
                           "an override's start, whatever was stored (\(label))")
            XCTAssertEqual(try validated(MCPRulePatch(mode: .extend), stored: stored).responseStatus, 0,
                           "extend's start: the server's status (\(label))")
            // A status sent is the one checked and stored.
            XCTAssertEqual(try validated(MCPRulePatch(mode: .override, responseStatus: 503), stored: stored).responseStatus, 503)
            XCTAssertEqual(try validated(MCPRulePatch(mode: .extend, responseStatus: 404), stored: stored).responseStatus, 404)
            XCTAssertNotNil(invalidMessage { try validated(MCPRulePatch(mode: .override, responseStatus: 0), stored: stored) })
            // No change of mode: nothing about the status is touched.
            XCTAssertNil(try validated(MCPRulePatch(enabled: false), stored: stored).responseStatus, label)
            XCTAssertNil(try validated(MCPRulePatch(mode: .mapLocal, localFile: MCPLocalFile(content: "x")), stored: stored).responseStatus, label)
        }
        // Only map_local's: the other modes keep what they store, as before.
        let fromExtend = try MCPWriteValidation.validate(MCPRulePatch(mode: .override), currentMode: .extend, currentMatchType: .wildcard,
                                                         currentPath: "/x", currentStatus: 404)
        XCTAssertNil(fromExtend.responseStatus, "an extend rule's 404 is kept: no status in the patch")
        XCTAssertNil(try MCPWriteValidation.validate(MCPRulePatch(mode: .extend), currentMode: .override, currentMatchType: .wildcard,
                                                     currentPath: "/x", currentStatus: 200).responseStatus)
    }

    /// Each tool's refusal says what leaving the status out does THERE.
    /// create_rule's sentences ("200 when you leave it out", "use mode
    /// extend") were returned by update_rule, where leaving it out keeps the
    /// rule's own, and by mock_from_session, where it replays the captured
    /// status and an extend rule is refused (review of 261703b).
    func testEachRoutesStatusRefusalSaysWhatLeavingItOutDoesThere() {
        func message(_ status: Int, _ mode: MCPRuleMode, _ route: MCPWriteValidation.StatusRoute) -> String {
            invalidMessage { try MCPWriteValidation.validateStatus(status, mode: mode, route: route) } ?? "accepted"
        }
        // create_rule: the mode's start.
        XCTAssertTrue(message(101, .extend, .create).contains("what an extend rule does when you leave it out"))
        XCTAssertTrue(message(0, .override, .create).contains("(200 when you leave it out)"))
        XCTAssertTrue(message(0, .override, .create).contains("use mode extend"))
        XCTAssertTrue(message(700, .override, .create).contains("an override answers 200 when you leave it out"))

        // update_rule, no change of mode: the rule's current status is kept.
        let update = MCPWriteValidation.StatusRoute.update(changingMode: false)
        XCTAssertEqual(message(101, .extend, update),
                       "responseStatus must be a final HTTP status, 200–599, or 0 to keep the server's status; leave it out to keep the rule's current status.")
        XCTAssertEqual(message(700, .override, update),
                       "responseStatus must be a final HTTP status, 200–599; leave it out to keep the rule's current status.")
        XCTAssertEqual(message(0, .override, update),
                       "An override answers with its own status, so responseStatus must be 200–599, or left out to keep the rule's current status. Only an extend rule keeps the server's status (mode extend, responseStatus 0).")
        // update_rule changing the mode: nothing is said about leaving it out
        // — a status kept through the change can still be refused, and a
        // map_local rule's is not kept at all.
        let changing = MCPWriteValidation.StatusRoute.update(changingMode: true)
        for (status, mode) in [(101, MCPRuleMode.extend), (700, .override), (0, .override)] {
            let text = message(status, mode, changing)
            XCTAssertFalse(text.contains("leave it out") || text.contains("left out"), "\(mode) \(status): \(text)")
        }
        XCTAssertTrue(message(0, .override, changing).contains("Only an extend rule keeps the server's status"))

        // mock_from_session: the captured status, when a mock can replay it;
        // no server status to keep, and no extend advice (the route refuses
        // an extend rule).
        XCTAssertEqual(message(0, .override, .mock(replays: 404)),
                       "A mock answers instead of the server, so it has no server status to keep: responseStatus must be a final HTTP status, 200–599; leave it out to replay the captured 404.")
        XCTAssertEqual(message(101, .override, .mock(replays: 404)),
                       "responseStatus must be a final HTTP status, 200–599; leave it out to replay the captured 404.")
        XCTAssertEqual(message(101, .override, .mock(replays: nil)), "responseStatus must be a final HTTP status, 200–599.",
                       "a capture with no status a mock can answer with: nothing said about leaving it out")

        // No route but create_rule's speaks of the mode's start, and none
        // sends a mock to extend.
        for route in [update, changing, .mock(replays: 404), .mock(replays: nil)] {
            for (status, mode) in [(101, MCPRuleMode.extend), (700, .override), (0, .override)] {
                let text = message(status, mode, route)
                XCTAssertFalse(text.contains("when you leave it out"), "\(route) \(mode) \(status): \(text)")
                if case .mock = route { XCTAssertFalse(text.contains("extend"), "\(route) \(mode) \(status): \(text)") }
            }
        }
        // A map_local rule uses none, on every route; and what a mode answers
        // with is accepted on every route.
        for route in [MCPWriteValidation.StatusRoute.create, update, changing, .mock(replays: 404)] {
            XCTAssertTrue(message(101, .mapLocal, route).contains("does not use responseStatus"), "\(route)")
            XCTAssertEqual(message(404, .override, route), "accepted", "\(route)")
            XCTAssertEqual(message(0, .extend, route), "accepted", "\(route)")
        }
    }

    /// A mock that names no status replays the captured one, so a captured
    /// status no mock can answer with (a WebSocket's 101) is refused before
    /// anyone is asked — not by the rule's validation after the human
    /// approved it, as a status the agent never sent. A map_local mock uses
    /// none; a capture with no status leaves the mock its 200.
    func testAMockLeftWithoutAStatusNeedsACapturedOneItCanAnswerWith() {
        let refused = invalidMessage { try MCPWriteValidation.validateReplayedStatus(101, uid: "s1", mode: .override) }
        XCTAssertEqual(refused, "Session s1's captured status, 101, is not one a mock can answer with: a mock answers with a final status, 200–599. Pass response_status: the status the mock should answer with.")
        for captured in [0, 100, 199, 600] {
            XCTAssertNotNil(invalidMessage { try MCPWriteValidation.validateReplayedStatus(captured, uid: "s1", mode: .override) }, "\(captured)")
        }
        XCTAssertNoThrow(try MCPWriteValidation.validateReplayedStatus(101, uid: "s1", mode: .mapLocal))
        XCTAssertNoThrow(try MCPWriteValidation.validateReplayedStatus(nil, uid: "s1", mode: .override))
        for captured in [200, 302, 404, 599] {
            XCTAssertNoThrow(try MCPWriteValidation.validateReplayedStatus(captured, uid: "s1", mode: .override), "\(captured)")
        }
    }

    func testModeAndMatchTypeUseTheirWireNames() throws {
        let json = #"{"mode":"map_local","matchType":"regex","path":"^/a$","localFile":{"content":"{}"}}"#.data(using: .utf8)!
        let draft = try JSONDecoder().decode(MCPRuleDraft.self, from: json)
        XCTAssertEqual(draft.mode, .mapLocal)
        XCTAssertEqual(draft.matchType, .regex)
    }
}

/// The agent names the file; ReqRes names the folder. Everything that could
/// turn a name into a path is rejected rather than sanitised — a silently
/// rewritten name means the agent is told one path and the user has another.
final class MCPExportFilenameTests: XCTestCase {
    func testABareNameIsKeptAndGainsTheExtension() throws {
        XCTAssertEqual(try MCPWriteValidation.exportFilename("login-flow"), "login-flow.har")
        XCTAssertEqual(try MCPWriteValidation.exportFilename("login-flow.har"), "login-flow.har")
        XCTAssertEqual(try MCPWriteValidation.exportFilename("  checkout 2.har  "), "checkout 2.har")
        XCTAssertEqual(try MCPWriteValidation.exportFilename("FLOW.HAR"), "FLOW.HAR",
                       "an extension already there in any case is not doubled")
    }

    func testAnythingThatCouldBeAPathIsRejected() {
        for raw in ["", "   ", "../escape.har", "/tmp/x.har", "sub/dir.har", "back\\slash.har",
                    ".hidden.har", "a..b.har", "Volume:file.har", "emoji🙂.har"] {
            XCTAssertThrowsError(try MCPWriteValidation.exportFilename(raw), "\(raw) must be refused")
        }
    }

    func testAnOverlongNameIsRejected() {
        let long = String(repeating: "a", count: MCPWriteValidation.maxExportFilenameLength + 1)
        XCTAssertThrowsError(try MCPWriteValidation.exportFilename(long))
    }

    /// The message has to say what to send instead — an agent that only hears
    /// "invalid" retries the same thing.
    func testTheRefusalSaysWhatToSendInstead() {
        do {
            _ = try MCPWriteValidation.exportFilename("/tmp/x.har")
            XCTFail("expected a refusal")
        } catch let error as MCPWriteError {
            XCTAssertTrue(error.message.contains("bare file name"), "got: \(error.message)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
