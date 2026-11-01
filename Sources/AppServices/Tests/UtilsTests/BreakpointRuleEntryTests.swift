//
//  BreakpointRuleEntryTests.swift
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
//  Settings ▸ Breakpoints' Add: what it refuses, and the note it leaves. The
//  note was stored text that only a Host edit or a later Add cleared, so
//  "That rule is already in the list." outlived an edit of the path or the
//  methods, and the removal of the very rule it named.
//

import XCTest
@testable import Utils

final class BreakpointRuleEntryTests: XCTestCase {
    private let orders = BreakpointRuleSpec(host: "api.example.com", pathContains: "/orders", methods: ["POST"])

    // MARK: - Canonical forms (moved from BreakpointService, unchanged)

    func testAHostIsTrimmedLowercasedAndStrippedOfWhatIsNotAHost() {
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("  API.Example.com.  "), "api.example.com")
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("api.example.com:8443"), "api.example.com")
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("https://user@api.example.com:8443/v1/orders"), "api.example.com")
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("localhost"), "localhost", "a dotless host is the likeliest breakpoint there is")
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("*.example.com"), "*.example.com")
    }

    func testAHostNothingCouldMatchIsRefused() {
        for raw in ["", "   ", "*", "*.", "*.com", "*.*.example.com", "api.*.com", "exa mple.com", "api.example.com*"] {
            XCTAssertNil(BreakpointRuleEntry.canonicalHost(raw), "“\(raw)”")
        }
    }

    /// The core compares a request's Host with the stored text after trimming,
    /// lowercasing and dropping a numeric port and a trailing dot — so text no
    /// Host carries is a rule that never fires. These were stored as typed
    /// (the review's four, and their neighbours).
    func testTextNoRequestsHostCarriesIsRefused() {
        let neverAHost = [
            "api.example.com:abc", "api.example.com:80a", "api.example.com,other.com", "api.example.com\\x",
            "api.example.com;x", "api.example.com%2F", ".example.com", "api..example.com", "*..example.com",
            "::1", "[::1", "[zz::1]", "[::1]:", "[::1]x", "[]",
        ]
        for raw in neverAHost {
            XCTAssertNil(BreakpointRuleEntry.canonicalHost(raw), "“\(raw)”")
            XCTAssertEqual(BreakpointRuleEntry.refusal(host: raw, pathContains: nil, methods: [], existing: []), .cannotMatch, "“\(raw)”")
        }
    }

    /// What a Host can carry is still taken: an address, a port, an
    /// underscore, a name in another script — and a bracketed IPv6 address,
    /// kept as written, port and all, because the core compares it that way.
    func testWhatAHostCarriesIsTaken() {
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("127.0.0.1:8080"), "127.0.0.1")
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("api.example.com:"), "api.example.com")
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("my_service.local"), "my_service.local")
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("bücher.example"), "bücher.example")
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("[::1]"), "[::1]")
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("[2001:DB8::1]:8443"), "[2001:db8::1]:8443")
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("http://[::1]:8080/"), "[::1]:8080")
    }

    /// A URL copied from the address bar with no path — `https://host` or
    /// `https://host/` — is the host: its path, "/", filters nothing. It was
    /// refused with "everything from the first “/” belongs in “Path
    /// contains”", and the first "/" was the scheme's.
    func testAPastedOriginIsTheHost() {
        for raw in ["https://api.example.com", "https://api.example.com/", "HTTPS://API.example.com:8443/",
                    "api.example.com/", "https://user@api.example.com", "api.example.com#top", "https://api.example.com/#top"] {
            XCTAssertNil(BreakpointRuleEntry.pastedPath(raw), "“\(raw)”")
            XCTAssertEqual(BreakpointRuleEntry.canonicalHost(raw), "api.example.com", "“\(raw)”")
            XCTAssertNil(BreakpointRuleEntry.refusal(host: raw, pathContains: nil, methods: [], existing: []), "“\(raw)”")
        }
        XCTAssertEqual(BreakpointRuleEntry.refusal(host: "https://api.example.com/", pathContains: nil, methods: [],
                                                   existing: [BreakpointRuleSpec(host: "api.example.com")]), .alreadyInList)
    }

    /// A path or a query after the host is what the user meant to match on:
    /// refused, quoting what belongs in "Path contains" as typed — a fragment
    /// left out (it never reaches a server), and a "://" inside the query not
    /// mistaken for the scheme's.
    func testAPastedURLNamesItsPath() {
        let cases = [
            "https://api.example.com/v1/Orders?id=5#top": "/v1/Orders?id=5",
            "api.example.com?x=1": "?x=1",
            "api.example.com/orders?next=https://other.example/": "/orders?next=https://other.example/",
            "/orders": "/orders",
        ]
        for (raw, path) in cases {
            XCTAssertEqual(BreakpointRuleEntry.pastedPath(raw), path, "“\(raw)”")
            XCTAssertEqual(BreakpointRuleEntry.refusal(host: raw, pathContains: nil, methods: [], existing: []), .hostHasPath, "“\(raw)”")
            XCTAssertEqual(BreakpointRuleEntry.message(for: .hostHasPath, host: raw),
                           "Enter the host on its own — “\(path)” belongs in “Path contains”.")
        }
        XCTAssertEqual(BreakpointRuleEntry.canonicalHost("api.example.com/orders?next=https://other.example/"), "api.example.com",
                       "the scheme is the text's own, not one inside its query")
    }

    func testAPathAndMethodsAreCanonical() {
        XCTAssertNil(BreakpointRuleEntry.canonicalPath(nil))
        XCTAssertNil(BreakpointRuleEntry.canonicalPath("  \n"), "blank is any path, never a substring every URI contains")
        XCTAssertEqual(BreakpointRuleEntry.canonicalPath(" /orders "), "/orders")
        XCTAssertEqual(BreakpointRuleEntry.canonicalMethods([" post", "GET", "Post", ""]), ["POST", "GET"])
    }

    // MARK: - The refusal

    func testTheRefusalsInOrder() {
        XCTAssertEqual(BreakpointRuleEntry.refusal(host: "api.example.com/v1", pathContains: nil, methods: [], existing: []), .hostHasPath,
                       "named before canonicalisation, which would keep the host and drop the path")
        // A path typed into the Host field: canonicalised first it is no host
        // at all, and "cannot match" would not say where it belongs.
        XCTAssertEqual(BreakpointRuleEntry.refusal(host: "/orders", pathContains: nil, methods: [], existing: []), .hostHasPath)
        XCTAssertEqual(BreakpointRuleEntry.refusal(host: "*", pathContains: nil, methods: [], existing: []), .cannotMatch)
        XCTAssertEqual(BreakpointRuleEntry.refusal(host: "", pathContains: nil, methods: [], existing: []), .cannotMatch)
        XCTAssertEqual(BreakpointRuleEntry.refusal(host: "api.example.com", pathContains: "/orders", methods: ["POST"], existing: [orders]), .alreadyInList)
        XCTAssertNil(BreakpointRuleEntry.refusal(host: "api.example.com", pathContains: "/orders", methods: ["GET"], existing: [orders]))
        XCTAssertNil(BreakpointRuleEntry.refusal(host: "api.example.com", pathContains: nil, methods: ["POST"], existing: [orders]))
    }

    /// "The same rule" is the core's idea of it: the same host, the path
    /// text without case (it is matched case-insensitively), the methods in
    /// any order and any case, and a blank path the same as none.
    func testTheSameRuleIsTheOneThatHoldsTheSameRequests() {
        let existing = [BreakpointRuleSpec(host: "api.example.com", pathContains: "/Orders", methods: ["POST", "PUT"])]
        XCTAssertEqual(BreakpointRuleEntry.refusal(host: "API.example.com.", pathContains: " /orders ", methods: ["put", "post"], existing: existing), .alreadyInList)
        XCTAssertEqual(BreakpointRuleEntry.refusal(host: "localhost", pathContains: "  ", methods: [],
                                                   existing: [BreakpointRuleSpec(host: "localhost")]), .alreadyInList)
        XCTAssertNil(BreakpointRuleEntry.refusal(host: "*.example.com", pathContains: "/orders", methods: ["POST", "PUT"], existing: existing),
                     "a wildcard holds other requests than the exact host")
    }

    func testEachRefusalSaysWhy() {
        XCTAssertEqual(BreakpointRuleEntry.message(for: .hostHasPath, host: "x/y"),
                       "Enter the host on its own — “/y” belongs in “Path contains”.")
        XCTAssertEqual(BreakpointRuleEntry.message(for: .cannotMatch, host: " *.com "),
                       "ReqRes cannot match “*.com”. Use a host like api.example.com or localhost, or *.example.com for its subdomains.")
        XCTAssertEqual(BreakpointRuleEntry.message(for: .alreadyInList, host: "api.example.com"), "That rule is already in the list.")
    }
}

// MARK: - The form and its note

final class BreakpointRuleFormTests: XCTestCase {
    private let orders = BreakpointRuleSpec(host: "api.example.com", pathContains: "/orders", methods: ["POST"])

    /// The form as the user leaves it after Add refused a duplicate.
    private func refusedDuplicate() -> BreakpointRuleForm {
        var form = BreakpointRuleForm()
        form.host = "api.example.com"
        form.path = "/orders"
        form.methods = ["POST"]
        form.submitted(accepted: false)
        return form
    }

    func testARefusalLeavesItsNote() {
        let form = refusedDuplicate()
        XCTAssertEqual(form.note(existing: [orders]), "That rule is already in the list.")
    }

    /// The reported defect: only a Host edit cleared the note. Every field
    /// does now — the path and the methods were the other two ways to change
    /// what the note was about.
    func testAnEditOfAnyFieldHidesTheNote() {
        var host = refusedDuplicate()
        host.host = "api.example.org"
        XCTAssertNil(host.note(existing: [orders]))

        var path = refusedDuplicate()
        path.path = "/orders/42"
        XCTAssertNil(path.note(existing: [orders]))

        var ticked = refusedDuplicate()
        ticked.methods.insert("GET")
        XCTAssertNil(ticked.note(existing: [orders]))
    }

    /// The note belongs to one submission: typing the refused text back does
    /// not revive it — pressing Add does, if the reason still holds.
    func testRetypingTheRefusedTextDoesNotBringTheNoteBack() {
        var form = refusedDuplicate()
        form.path = "/order"
        form.path = "/orders"
        XCTAssertNil(form.note(existing: [orders]))

        form.submitted(accepted: false)
        XCTAssertEqual(form.note(existing: [orders]), "That rule is already in the list.")
    }

    /// The same for the host: an edit forgets the refusal, and typing the
    /// refused host back does not bring the note with it.
    func testRetypingTheRefusedHostDoesNotBringTheNoteBack() {
        var form = refusedDuplicate()
        form.host = "api.example.co"
        form.host = "api.example.com"
        XCTAssertNil(form.note(existing: [orders]))
    }

    /// And for the methods: ticking one and unticking it again is two edits,
    /// not a return to the refused submission.
    func testRetickingTheRefusedMethodsDoesNotBringTheNoteBack() {
        var form = refusedDuplicate()
        form.methods.insert("GET")
        form.methods.remove("GET")
        XCTAssertNil(form.note(existing: [orders]))
    }

    /// Re-checked against the rules as they are now: removing the rule the
    /// note named takes the note away, while the fields still hold the text.
    func testRemovingTheRuleTheNoteNamedTakesTheNoteAway() {
        let form = refusedDuplicate()
        XCTAssertNotNil(form.note(existing: [orders]))
        XCTAssertNil(form.note(existing: []))
        XCTAssertNil(form.note(existing: [BreakpointRuleSpec(host: "api.example.com", pathContains: "/orders", methods: ["GET"])]),
                     "the rule was changed to hold other requests")
    }

    /// A refusal about the text alone holds whatever the list holds.
    func testANoteAboutTheTextStaysWhileTheTextDoes() {
        var form = BreakpointRuleForm()
        form.host = "https://api.example.com/orders"
        form.submitted(accepted: false)
        XCTAssertEqual(form.note(existing: []), "Enter the host on its own — “/orders” belongs in “Path contains”.")
        XCTAssertEqual(form.note(existing: [orders]), form.note(existing: []))

        var wildcard = BreakpointRuleForm()
        wildcard.host = "*.com"
        wildcard.submitted(accepted: false)
        XCTAssertEqual(wildcard.note(existing: []), "ReqRes cannot match “*.com”. Use a host like api.example.com or localhost, or *.example.com for its subdomains.")
    }

    func testAnAcceptedRuleClearsTheForm() {
        var form = refusedDuplicate()
        form.submitted(accepted: true)

        XCTAssertEqual(form.host, "")
        XCTAssertEqual(form.path, "")
        XCTAssertTrue(form.methods.isEmpty)
        XCTAssertNil(form.refused)
        XCTAssertNil(form.note(existing: [orders]))
    }

    /// Nothing refused, nothing to say — and a submission the list now takes
    /// has no note either.
    func testWithoutARefusalThereIsNoNote() {
        var form = BreakpointRuleForm()
        form.host = "api.example.com"
        XCTAssertNil(form.note(existing: [orders]))
        XCTAssertFalse(BreakpointRuleForm().canSubmit, "a blank host is never submitted")
        XCTAssertTrue(form.canSubmit)
    }

    /// Setting a field to what it already holds is not an edit: SwiftUI may
    /// write a binding back unchanged, and that must not hide the note.
    func testWritingTheSameValueIsNotAnEdit() {
        var form = refusedDuplicate()
        form.host = "api.example.com"
        form.path = "/orders"
        form.methods = ["POST"]
        XCTAssertEqual(form.note(existing: [orders]), "That rule is already in the list.")
    }

    func testThePathIsSubmittedCanonical() {
        var form = BreakpointRuleForm()
        form.path = "  "
        XCTAssertNil(form.pathContains, "blank is any path")
        form.path = " /orders "
        XCTAssertEqual(form.pathContains, "/orders")
    }
}
