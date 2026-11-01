//
//  ExcludeHostTests.swift
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
//  `exclude_host` (protocol PRD 3.5, protocol-engine doc §S3): its own consent
//  kind at the rewritesTraffic severity, the consent copy "ReqRes will stop
//  recording <host>; you will no longer see its traffic", an audit snapshot
//  of the list before, and an undo plan that takes exactly that entry back
//  off the list.
//

import XCTest
@testable import MCPKit

/// The app's exclusion list, in memory, with the app's rules approximated:
/// canonical = trimmed + lower-cased, and a `*.` entry covers subdomains.
final class StubExclusions: MCPExclusionProviding {
    var hosts: [String]
    var added: [String] = []

    init(hosts: [String] = ["timestamp.apple.com", "*.ls.apple.com"]) {
        self.hosts = hosts
    }

    func excludedHosts() throws -> [String] { hosts }

    func check(_ raw: String) -> MCPExclusionCheck {
        let entry = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard entry.contains("."), !entry.contains("/"), !entry.contains(" ") else {
            return .invalid("'\(raw)' is not a host name.")
        }
        if let covering = hosts.first(where: { $0 == entry || ($0.hasPrefix("*.") && entry.hasSuffix(String($0.dropFirst(1)))) }) {
            return .alreadyExcluded(entry: covering)
        }
        return .add(entry: entry)
    }

    func exclude(_ entry: String) throws -> [String] {
        added.append(entry)
        hosts.append(entry)
        return hosts
    }
}

final class ExcludeHostTests: XCTestCase {
    private let token = "t"
    private var exclusions: StubExclusions!
    private var consent: StubConsent!
    private var audit: StubAudit!

    override func setUp() {
        super.setUp()
        exclusions = StubExclusions()
        consent = StubConsent()
        audit = StubAudit()
    }

    private func router(wired: Bool = true) -> MCPBridgeRouter {
        MCPBridgeRouter(
            token: token,
            sessions: StubSessionProvider(),
            status: StubStatusProvider(),
            writes: MCPWriteSeams(
                rules: StubRuleProvider(), hosts: StubHostProvider(), capture: StubCaptureController(),
                consent: consent, audit: audit, exclusions: wired ? exclusions : nil
            )
        )
    }

    private func post(_ router: MCPBridgeRouter, host: String) throws -> ParsedResponse {
        var request = makeRequest(method: "POST", target: "/v1/exclusions", token: token)
        request.body = try JSONSerialization.data(withJSONObject: ["host": host])
        return try XCTUnwrap(parseRawResponse(router.respond(to: request)))
    }

    // MARK: - The kind

    func testTheKindIsItsOwnAtTheRewritesTrafficSeverity() {
        XCTAssertEqual(MCPAgentAction.Kind.excludeHost.rawValue, "exclude_host")
        XCTAssertEqual(MCPAgentAction.Kind.excludeHost.severity, .rewritesTraffic)
        let note = MCPAgentAction.Kind.excludeHost.consentNote
        XCTAssertTrue(note.contains("rewrites live traffic"))
        XCTAssertTrue(note.contains("neither you nor the user will see its traffic"), note)
        XCTAssertTrue(note.contains("EVERY time"), "the agent is told the standing grant does not cover it: \(note)")
        XCTAssertFalse(note.contains("unless they have allowed agent changes"), note)
        XCTAssertTrue(MCPAgentAction.Severity.rewritesTraffic.canBeCoveredByStandingGrant)
    }

    /// The one write that hides traffic from the human always asks: the
    /// standing grant ("change rules and hosts without asking") and "Allow
    /// for this session" never answer for it, though they still answer for a
    /// rule of the same weight.
    func testTheStandingGrantNeverCoversAnExclusion() {
        XCTAssertFalse(MCPAgentAction(kind: .excludeHost, summary: "x").canBeCoveredByStandingGrant)
        XCTAssertFalse(MCPAgentAction.Kind.excludeHost.canBeCoveredByStandingGrant)
        XCTAssertTrue(MCPAgentAction(kind: .createRule, summary: "x").canBeCoveredByStandingGrant)
        XCTAssertFalse(MCPAgentAction(kind: .replayRequest, summary: "x").canBeCoveredByStandingGrant,
                       "the severity rule still applies")
        for kind in MCPAgentAction.Kind.allCases where kind != .excludeHost {
            XCTAssertEqual(MCPAgentAction(kind: kind, summary: "x").canBeCoveredByStandingGrant,
                           kind.severity.canBeCoveredByStandingGrant, "\(kind)")
        }
    }

    // MARK: - The route

    func testExcludingAHostAsksWithTheConsentCopyAndSnapshotsTheListBefore() throws {
        let response = try post(router(), host: " API.Bank.example ")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json?["host"] as? String, "api.bank.example")
        XCTAssertEqual(response.json?["alreadyExcluded"] as? Bool, false)
        XCTAssertEqual(exclusions.added, ["api.bank.example"])

        let asked = try XCTUnwrap(consent.asked.first)
        XCTAssertEqual(asked.kind, .excludeHost)
        XCTAssertEqual(asked.summary, "ReqRes will stop recording api.bank.example; you will no longer see its traffic.")
        // Doc §S10 review: the panel said every connection passes through
        // "not changed" from the next connection — false for plain http://,
        // which the plain-HTTP front still rewrites (hop-by-hop headers) and
        // which follows the list from the next REQUEST.
        XCTAssertTrue(asked.details.contains(FailureRowCopy.exclusionScope), "\(asked.details)")
        XCTAssertFalse(asked.details.joined(separator: " ").contains("not changed"), "\(asked.details)")

        let entry = try XCTUnwrap(audit.entries.first)
        XCTAssertEqual(entry.outcome, .performed)
        XCTAssertEqual(entry.previousState, .exclusion(MCPExclusionSnapshot(host: "api.bank.example", before: ["timestamp.apple.com", "*.ls.apple.com"])))
        XCTAssertTrue(entry.isReversible)
    }

    /// A bad name must not raise a panel.
    func testAnInvalidHostIsA400AndNobodyIsAsked() throws {
        let response = try post(router(), host: "https://x/y")
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertTrue(audit.entries.isEmpty)
    }

    /// Nothing to approve and nothing to log when nothing changes.
    func testAHostAlreadyExcludedChangesNothingAndAsksNoOne() throws {
        let response = try post(router(), host: "gspe19-ssl.ls.apple.com")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json?["alreadyExcluded"] as? Bool, true)
        XCTAssertEqual(response.json?["host"] as? String, "*.ls.apple.com")
        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertTrue(audit.entries.isEmpty)
        XCTAssertTrue(exclusions.added.isEmpty)
    }

    // MARK: - reqresapp.com (pay-once PRD A16)

    /// ReqRes's license server is always excluded (the engine relays it in
    /// code), so an agent asking to exclude it is answered "already
    /// excluded": no panel, no log, no change. The stub holds what the app's
    /// adapter answers with, `ExcludedHostList.allEntries` (built-in first);
    /// the adapter's wiring is pinned below.
    func testExcludingTheLicenseServerAnswersAlreadyExcluded() throws {
        exclusions = StubExclusions(hosts: ["reqresapp.com", "*.reqresapp.com", "timestamp.apple.com", "*.ls.apple.com"])
        for (host, entry) in [("reqresapp.com", "reqresapp.com"), ("api.reqresapp.com", "*.reqresapp.com")] {
            let response = try post(router(), host: host)
            XCTAssertEqual(response.status, 200, host)
            XCTAssertEqual(response.json?["alreadyExcluded"] as? Bool, true, host)
            XCTAssertEqual(response.json?["host"] as? String, entry, host)
            XCTAssertEqual((response.json?["excludedHosts"] as? [String])?.prefix(2), ["reqresapp.com", "*.reqresapp.com"], host)
        }
        XCTAssertTrue(consent.asked.isEmpty)
        XCTAssertTrue(audit.entries.isEmpty)
        XCTAssertTrue(exclusions.added.isEmpty)

        let text = MCPTextFormat.exclusion(MCPExclusionResult(host: "reqresapp.com", alreadyExcluded: true, excludedHosts: ["reqresapp.com", "*.reqresapp.com"]))
        XCTAssertTrue(text.hasPrefix("reqresapp.com is already excluded — nothing changed and no one was asked."), text)
    }

    /// The app's adapter (UI, not built here) asks Utils' tested
    /// `coveringEntry(for:)`, which answers built-in entries first, and shows
    /// the agent `allEntries`. Read from its source with comment lines dropped.
    func testTheAppsAdapterAsksTheListThatKnowsTheLicenseServer() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../UI/Services/MCPWriteAdapters.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct MCPExclusionAdapter: MCPExclusionProviding {"))
        let end = try XCTUnwrap(source.range(of: "private static func bareHost", range: start.upperBound..<source.endIndex))
        let adapter = source[start.upperBound..<end.lowerBound]
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")

        XCTAssertTrue(adapter.contains("ExcludedHostsSettings.shared.list.allEntries"), "the agent is shown the built-in entries too")
        XCTAssertTrue(adapter.contains("if let covering = list.coveringEntry(for: entry) {\n            return .alreadyExcluded(entry: covering)"), adapter)
        XCTAssertFalse(adapter.contains("list.hosts"), "a lookup over the user's entries alone would let reqresapp.com through to the panel")
    }

    func testADeniedExclusionChangesNothingAndIsLogged() throws {
        consent.decision = .denied(reason: "no")
        let response = try post(router(), host: "api.bank.example")
        XCTAssertEqual(response.status, 403)
        XCTAssertTrue(exclusions.added.isEmpty)
        XCTAssertEqual(audit.entries.first?.outcome, .denied)
        XCTAssertFalse(audit.entries.first?.isReversible ?? true)
    }

    func testABuildWithoutTheListAnswers503() throws {
        XCTAssertEqual(try post(router(wired: false), host: "api.bank.example").status, 503)
    }

    // MARK: - Undo

    func testTheUndoTakesExactlyThatEntryBackOff() throws {
        _ = try post(router(), host: "api.bank.example")
        let entry = try XCTUnwrap(audit.entries.first)
        let plan = try XCTUnwrap(MCPUndo.plan(for: entry))
        XCTAssertEqual(plan, .removeExclusion(host: "api.bank.example"))
        XCTAssertTrue(MCPUndo.summary(for: plan).hasPrefix("Record api.bank.example again"))
        let undoEntry = MCPUndo.entry(for: plan, outcome: .performed)
        XCTAssertTrue(undoEntry.byUser)
        XCTAssertEqual(undoEntry.action.kind, .excludeHost)
        XCTAssertFalse(undoEntry.isReversible, "an undo is not itself undone from the log")
    }

    /// A snapshot whose host was already on the list means the call changed
    /// nothing, and removing it would take away the user's own entry.
    func testAnEntryThatAddedNothingIsNotReversible() {
        let entry = MCPAuditEntry(
            action: MCPAgentAction(kind: .excludeHost, summary: "x"),
            outcome: .performed,
            previousState: .exclusion(MCPExclusionSnapshot(host: "a.example", before: ["a.example"]))
        )
        XCTAssertFalse(entry.isReversible)
        XCTAssertNil(MCPUndo.plan(for: entry))
    }

    func testTheSnapshotRoundTripsAndOlderSnapshotsStillDecode() throws {
        let snapshot = MCPAuditSnapshot.exclusion(MCPExclusionSnapshot(host: "a.example", before: ["b.example"]))
        XCTAssertEqual(try JSONDecoder().decode(MCPAuditSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        let host = MCPAuditSnapshot.host(MCPHost(id: 1, host: "c.example", scheme: "https", port: 443))
        XCTAssertEqual(try JSONDecoder().decode(MCPAuditSnapshot.self, from: JSONEncoder().encode(host)), host)
        XCTAssertEqual(snapshot.summary, "excluded hosts b.example (before a.example was added)")
    }

    // MARK: - The approval panel

    /// An exclusion shares a rule's severity but not its consequence: the
    /// apps still get the real response. A panel of exclusions says so; a
    /// burst that also holds a rule keeps the rule's sentence (the rule is
    /// the part that changes what the apps receive).
    func testThePanelStatesTheExclusionConsequenceNotARulesOne() {
        let exclusion = MCPAgentAction(kind: .excludeHost, summary: FailureRowCopy.exclusionConsequence("a.example"))
        let alone = MCPAgentActionPresentation(actions: [exclusion])
        XCTAssertEqual(alone.title, "An AI agent wants ReqRes to stop recording a host")
        XCTAssertTrue(alone.consequence.contains("you will no longer see their traffic"))
        XCTAssertEqual(alone.rows.first?.symbolName, "eye.slash")
        XCTAssertTrue(alone.rows.first?.accessibilityLabel.hasPrefix("Stops recording a host") ?? false)

        let withRoutine = MCPAgentActionPresentation(actions: [exclusion, MCPAgentAction(kind: .addHost, summary: "Add")])
        XCTAssertTrue(withRoutine.title.contains("hosts ReqRes stops recording"), withRoutine.title)

        let withRule = MCPAgentActionPresentation(actions: [exclusion, MCPAgentAction(kind: .createRule, summary: "Rule")])
        XCTAssertEqual(withRule.consequence, MCPAgentAction.Severity.rewritesTraffic.consequence)
    }

    // MARK: - Agent text

    func testTheAgentIsToldTheHostLeavesItsViewToo() {
        let text = MCPTextFormat.exclusion(MCPExclusionResult(host: "a.example", alreadyExcluded: false, excludedHosts: ["a.example"]))
        XCTAssertTrue(text.contains("no longer appears for the user or for you"), text)
        XCTAssertTrue(text.contains("HTTPS connections opened from now on and to plain http:// from the next request"), text)
        let already = MCPTextFormat.exclusion(MCPExclusionResult(host: "*.a.example", alreadyExcluded: true, excludedHosts: ["*.a.example"]))
        XCTAssertTrue(already.contains("nothing changed"), already)
    }

    /// The audit export prints the snapshot's summary; nothing in it is
    /// secret, so it is not redacted away.
    func testTheAuditExportPrintsTheListBefore() throws {
        let entry = MCPAuditEntry(
            action: MCPAgentAction(kind: .excludeHost, summary: FailureRowCopy.exclusionConsequence("a.example")),
            outcome: .performed,
            previousState: .exclusion(MCPExclusionSnapshot(host: "a.example", before: []))
        )
        let text = MCPAuditExport.text([entry]).content
        XCTAssertTrue(text.contains("Previous state: no excluded hosts (before a.example was added)"), text)
    }
}
