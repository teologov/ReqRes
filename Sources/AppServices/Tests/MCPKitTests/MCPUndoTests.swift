//
//  MCPUndoTests.swift
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
//  Roadmap item 13. An undo that does the wrong thing is worse than no undo:
//  it is a write the user believes is safe. These pin what each logged action
//  reverses to, and — the part that is easy to get wrong — what it does NOT
//  offer to reverse.
//

import XCTest
@testable import MCPKit

final class MCPUndoTests: XCTestCase {
    private func rule(id: Int64 = 12, enabled: Bool = true, path: String = "/v1/users?*") -> MCPRule {
        MCPRule(
            id: id,
            hostId: 3,
            host: "api.example.com",
            enabled: enabled,
            mode: .override,
            matchType: .wildcard,
            path: path,
            method: "GET",
            scheme: "https",
            requestHeaders: ["X-Debug": "1"],
            responseStatus: 500,
            responseHeaders: ["Content-Type": "application/json"],
            responseBody: #"{"error":true}"#
        )
    }

    private let host = MCPHost(id: 3, host: "api.example.com", scheme: "https", port: 443)

    private func entry(
        _ kind: MCPAgentAction.Kind,
        outcome: MCPAuditOutcome = .performed,
        previousState: MCPAuditSnapshot? = nil,
        created: MCPAuditTarget? = nil,
        undone: Bool = false
    ) -> MCPAuditEntry {
        MCPAuditEntry(
            action: MCPAgentAction(kind: kind, summary: "…"),
            outcome: outcome,
            previousState: previousState,
            created: created,
            undone: undone
        )
    }

    // MARK: - Snapshots from before rules matched on method (release review, 2026-09-29)

    /// A persisted entry with no `rulesMatchMethod` key, as a build before
    /// core C4 wrote it: its rule's "GET" is the old default, never read.
    private func legacyEntry(_ kind: MCPAgentAction.Kind, previous: MCPRule) throws -> MCPAuditEntry {
        let modern = MCPAuditEntry(action: MCPAgentAction(kind: kind, summary: "…"), outcome: .performed,
                                   previousState: .rule(previous))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(modern)) as? [String: Any])
        json.removeValue(forKey: "rulesMatchMethod")
        return try JSONDecoder().decode(MCPAuditEntry.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testALegacyGETSnapshotIsRestoredAsAnyMethod() throws {
        let previous = rule()
        XCTAssertEqual(previous.method, "GET")
        guard case .restoreRule(let restored)? = MCPUndo.plan(for: try legacyEntry(.updateRule, previous: previous)) else {
            return XCTFail("expected a restore")
        }
        XCTAssertEqual(restored.method, RuleMethod.any)
        XCTAssertEqual(MCPUndo.patch(restoring: restored).method, "")

        guard case .recreateRule(let recreated)? = MCPUndo.plan(for: try legacyEntry(.deleteRule, previous: previous)) else {
            return XCTFail("expected a recreate")
        }
        XCTAssertEqual(MCPUndo.draft(recreating: recreated).method, "")
    }

    /// A legacy snapshot with another method keeps it (the old default was
    /// GET only), and a modern entry keeps GET: it was chosen and is matched.
    func testOnlyALegacyGETIsRewritten() throws {
        var post = rule()
        post.method = "POST"
        XCTAssertEqual(MCPUndo.plan(for: try legacyEntry(.updateRule, previous: post)), .restoreRule(post))
        XCTAssertEqual(MCPUndo.plan(for: entry(.updateRule, previousState: .rule(rule()))), .restoreRule(rule()))
        XCTAssertTrue(entry(.updateRule).rulesMatchMethod, "new entries are written by a build that matches on method")
    }

    // MARK: - What each action reverses to

    func testAnUpdateIsUndoneByRestoringTheSnapshot() {
        let previous = rule(enabled: true)
        let plan = MCPUndo.plan(for: entry(.updateRule, previousState: .rule(previous)))

        XCTAssertEqual(plan, .restoreRule(previous))
    }

    /// A deleted rule's row is gone, so it comes back as a new one — and the
    /// summary says so rather than letting the user believe #12 is back.
    func testADeleteIsUndoneByRecreating() throws {
        let plan = try XCTUnwrap(MCPUndo.plan(for: entry(.deleteRule, previousState: .rule(rule()))))

        XCTAssertEqual(plan, .recreateRule(rule()))
        XCTAssertTrue(MCPUndo.summary(for: plan).contains("new id"))
    }

    func testACreationIsUndoneByDeletingWhatItMade() {
        XCTAssertEqual(MCPUndo.plan(for: entry(.createRule, created: .rule(41))), .deleteRule(id: 41))
        XCTAssertEqual(MCPUndo.plan(for: entry(.mockFromSession, created: .rule(42))), .deleteRule(id: 42))
        XCTAssertEqual(MCPUndo.plan(for: entry(.addHost, created: .host(7))), .removeHost(id: 7))
    }

    /// Removing a host takes its rules with it and the log keeps no copy of
    /// them, so the summary must not imply they come back.
    func testARestoredHostDoesNotPromiseItsRules() throws {
        let plan = try XCTUnwrap(MCPUndo.plan(for: entry(.removeHost, previousState: .host(host))))

        XCTAssertEqual(plan, .restoreHost(host))
        XCTAssertTrue(MCPUndo.summary(for: plan).contains("rules are not restored"))
    }

    // MARK: - Removing a host an agent added (F18)

    /// Removing a filter deletes every rule scoped to it, and by the time
    /// someone clicks Undo those can include rules they made by hand in the
    /// Override form. The undo takes back the agent's filter and nothing
    /// else: while anything hangs off it, it refuses and says where the
    /// deliberate version lives — worded as the sidebar row's context menu
    /// labels it (AppView's "Delete host...").
    func testUndoingAnAddedHostIsRefusedWhileItHasRules() throws {
        let plan = try XCTUnwrap(MCPUndo.plan(for: entry(.addHost, created: .host(7))))

        let two = try XCTUnwrap(MCPUndo.refusal(for: plan, rulesOnHost: 2, hostName: "api.example.com"))
        XCTAssertTrue(two.contains("2 rules"), two)
        XCTAssertTrue(two.contains("whoever made them"), "the user's own rules are the loss: \(two)")
        XCTAssertTrue(two.hasSuffix("choose Delete host..."), two)

        let one = try XCTUnwrap(MCPUndo.refusal(for: plan, rulesOnHost: 1, hostName: "api.example.com"))
        XCTAssertTrue(one.contains("1 rule now"), one)
        XCTAssertTrue(one.contains("that rule too, whoever made it"), one)
        XCTAssertTrue(one.contains("with its rule,"), one)
        XCTAssertFalse(one.contains("rules"), "one rule is not spoken of in the plural: \(one)")
    }

    /// The refusal is logged at the top of the Activity list, away from the
    /// entry it answers, and "Delete host..." is in a context menu, not on
    /// screen: it names the filter as the sidebar shows it — never by the
    /// database id the sidebar does not — and says how to open that menu.
    func testTheRefusalSaysWhereTheDeliberateDeleteIs() throws {
        let named = try XCTUnwrap(MCPUndo.refusal(for: .removeHost(id: 7), rulesOnHost: 1, hostName: "api.example.com"))
        XCTAssertEqual(named, "The host filter api.example.com has 1 rule now, and removing the filter would delete "
            + "that rule too, whoever made it. To delete the filter with its rule, right-click api.example.com "
            + "in the sidebar and choose Delete host...")
        XCTAssertFalse(named.contains("#7"), named)

        // Without a name it still says how.
        let unnamed = try XCTUnwrap(MCPUndo.refusal(for: .removeHost(id: 7), rulesOnHost: 3))
        XCTAssertTrue(unnamed.hasPrefix("This host filter has 3 rules now"), unnamed)
        XCTAssertTrue(unnamed.contains("right-click the filter in the sidebar and choose Delete host..."), unnamed)
    }

    /// Following that advice deletes the filter, and with it the rules on it
    /// — and every agent entry that made one of them still offered an Undo
    /// that could only fail, in words written for an agent ("Use list_hosts
    /// to see the current ids."). A removal whose target is gone has nothing
    /// left to do; putting something back that is gone cannot be done.
    func testARemovalWhoseTargetIsGoneIsAlreadyDone() {
        XCTAssertEqual(MCPUndo.alreadyDone(.removeHost(id: 7)), "host #7 was already gone")
        XCTAssertEqual(MCPUndo.alreadyDone(.deleteRule(id: 41)), "rule #41 was already gone")

        let restorations: [MCPUndoPlan] = [
            .restoreRule(rule()), .recreateRule(rule()), .restoreHost(host), .removeExclusion(host: "api.example.com"),
        ]
        for plan in restorations {
            XCTAssertNil(MCPUndo.alreadyDone(plan), "\(plan)")
        }
    }

    func testUndoingAnAddedHostThatIsStillEmptyIsAllowed() {
        XCTAssertNil(MCPUndo.refusal(for: .removeHost(id: 7), rulesOnHost: 0))
    }

    /// Only a host removal takes anything with it. The rest act on the one
    /// rule, filter or exclusion the entry names, so a count of the filter's
    /// rules is no reason to refuse them.
    func testOnlyRemovingAHostIsRefusedForItsRules() {
        let others: [MCPUndoPlan] = [
            .deleteRule(id: 41), .restoreRule(rule()), .recreateRule(rule()),
            .restoreHost(host), .removeExclusion(host: "api.example.com"),
        ]
        for plan in others {
            XCTAssertNil(MCPUndo.refusal(for: plan, rulesOnHost: 5), "\(plan)")
        }
    }

    /// The tooltip, the note after the click and the log row all read this
    /// line, and it once named only the filter — by an id the sidebar never
    /// shows — while the click deleted every rule on it.
    func testTheRemoveHostSummaryStatesItsCondition() {
        XCTAssertEqual(MCPUndo.summary(for: .removeHost(id: 7)), "Remove the host filter this added (#7) if it has no rules")
        XCTAssertTrue(MCPUndo.entry(for: .removeHost(id: 7), outcome: .failed).action.summary.hasSuffix("if it has no rules"))
    }

    // MARK: - What has no undo

    func testNothingThatCannotBePutBackOffersAnUndo() {
        for kind in [MCPAgentAction.Kind.clearSessions, .startCapture, .stopCapture, .exportSessions] {
            XCTAssertNil(MCPUndo.plan(for: entry(kind)), "\(kind.rawValue) must not offer an undo")
        }
    }

    func testADeniedOrFailedActionHasNothingToUndo() {
        XCTAssertNil(MCPUndo.plan(for: entry(.createRule, outcome: .denied, created: nil)))
        XCTAssertNil(MCPUndo.plan(for: entry(.deleteRule, outcome: .failed, previousState: nil)))
    }

    /// A log written before `created` existed cannot say what to delete —
    /// better no button than one that deletes the wrong rule.
    func testALegacyCreationEntryIsNotUndoable() {
        XCTAssertNil(MCPUndo.plan(for: entry(.createRule, created: nil)))
    }

    func testAnAlreadyUndoneEntryDoesNotOfferItTwice() {
        let done = entry(.deleteRule, previousState: .rule(rule()), undone: true)

        XCTAssertFalse(done.isReversible)
        XCTAssertNil(MCPUndo.plan(for: done))
    }

    // MARK: - The writes it produces

    /// Every field, not just the ones that look changed: the log records what
    /// the rule WAS, not which fields the agent touched, so a nil here would
    /// silently keep the agent's value.
    func testARestorePatchSetsEveryField() {
        let previous = rule(enabled: false, path: "/v1/orders")
        let patch = MCPUndo.patch(restoring: previous)

        XCTAssertEqual(patch.enabled, false)
        XCTAssertEqual(patch.mode, previous.mode)
        XCTAssertEqual(patch.matchType, previous.matchType)
        XCTAssertEqual(patch.path, "/v1/orders")
        XCTAssertEqual(patch.method, previous.method)
        XCTAssertEqual(patch.scheme, previous.scheme)
        XCTAssertEqual(patch.requestHeaders, previous.requestHeaders)
        XCTAssertEqual(patch.responseStatus, previous.responseStatus)
        XCTAssertEqual(patch.responseHeaders, previous.responseHeaders)
        XCTAssertEqual(patch.responseBody, previous.responseBody)
    }

    func testARecreateDraftCarriesTheRuleBackIncludingItsHostAndState() {
        let previous = rule(enabled: false)
        let draft = MCPUndo.draft(recreating: previous)

        XCTAssertEqual(draft.hostId, previous.hostId, "a rule with no host filter cannot be stored at all")
        XCTAssertEqual(draft.enabled, false, "a disabled rule must not come back switched on")
        XCTAssertEqual(draft.path, previous.path)
        XCTAssertEqual(draft.responseBody, previous.responseBody)
    }

    func testAMapLocalRuleKeepsItsFile() {
        var mapLocal = rule()
        mapLocal.mode = .mapLocal
        mapLocal.localFilePath = "/fixtures/a.json"

        XCTAssertEqual(MCPUndo.patch(restoring: mapLocal).localFile?.path, "/fixtures/a.json")
        XCTAssertEqual(MCPUndo.draft(recreating: mapLocal).localFile?.path, "/fixtures/a.json")
    }

    // MARK: - The entry it writes

    func testTheUndoIsLoggedAsTheUsers() {
        let logged = MCPUndo.entry(for: .deleteRule(id: 41), outcome: .performed, detail: "rule #41 deleted")

        XCTAssertTrue(logged.byUser, "an unmarked undo reads as the agent having changed its mind")
        XCTAssertTrue(logged.action.summary.hasPrefix("Undo — "))
        XCTAssertEqual(logged.outcome, .performed)
    }

    /// The undo of an undo is an ordinary entry in its own right; it must not
    /// claim to be reversible on the strength of state it never captured.
    func testAnUndoEntryIsNotItselfOfferedAnUndo() {
        let logged = MCPUndo.entry(for: .recreateRule(rule()), outcome: .performed)

        XCTAssertNil(MCPUndo.plan(for: logged))
    }

    func testAFailedUndoIsLoggedAsFailed() {
        let logged = MCPUndo.entry(for: .restoreHost(host), outcome: .failed, detail: "no such host")

        XCTAssertEqual(logged.outcome, .failed)
        XCTAssertFalse(logged.isReversible)
    }

    // MARK: - Round trip

    func testTheNewFieldsSurviveBeingWrittenAndReadBack() throws {
        let original = entry(.createRule, created: .rule(41), undone: true)

        let decoded = try JSONDecoder().decode(MCPAuditEntry.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.created, .rule(41))
        XCTAssertTrue(decoded.undone)
    }

    func testALogWrittenBeforeTheseFieldsStillDecodes() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","date":0,"action":{"kind":"create_rule","summary":"…","details":[]},"outcome":"performed"}
        """
        let decoded = try JSONDecoder().decode(MCPAuditEntry.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.created)
        XCTAssertFalse(decoded.undone)
        XCTAssertFalse(decoded.byUser)
    }
}
