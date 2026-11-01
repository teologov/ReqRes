//
//  MCPRedactionExceptionNoteTests.swift
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
//  F13, the MCP half: Settings ▸ MCP ▸ Redaction's note under the "Send
//  unmasked" field was stored text, so "“x” is already excepted." stayed after
//  x had been removed from the list and the field emptied — the stale note seen
//  live in Settings ▸ Capture. The note is now derived from what was refused,
//  what the field holds and what the list holds; these pin that it is shown
//  exactly while it is true, and only until the field is edited.
//

import XCTest
@testable import MCPKit

final class MCPRedactionExceptionNoteTests: XCTestCase {
    private let listed = MCPRedactionPolicy(exceptedHosts: ["example.net"])

    // MARK: - Why Add refuses

    func testTheTwoRefusalsAndNoneForAnAddableHost() {
        XCTAssertEqual(listed.refusal(forException: "example.net"), .alreadyExcepted)
        // Another spelling of a listed entry is the same entry.
        XCTAssertEqual(listed.refusal(forException: "EXAMPLE.net."), .alreadyExcepted)
        XCTAssertEqual(listed.refusal(forException: "api.*.example.com"), .cannotMatch)
        XCTAssertEqual(listed.refusal(forException: "*"), .cannotMatch)
        XCTAssertNil(listed.refusal(forException: "api.example.com"))
        XCTAssertNil(listed.refusal(forException: "*.example.net"), "a wildcard is not the bare domain it sits over")
        XCTAssertNil(listed.refusal(forException: "   "), "the field does not submit blank text")
    }

    /// The refusal and Add must agree, or the note would explain a refusal
    /// that did not happen (or miss one that did).
    func testARefusalIsExactlyWhenAddingFails() {
        for raw in ["example.net", "Example.NET", "api.example.com", "*.example.net", "*", "a b.com", "*.*.x.com", "x.com:8080"] {
            XCTAssertEqual(listed.refusal(forException: raw) != nil, listed.addingException(raw) == nil, raw)
        }
    }

    // MARK: - The note belongs to the text it was written for

    func testTheNoteNamesWhatWasRefused() {
        XCTAssertEqual(listed.exceptionNote(submitted: "example.net", current: "example.net"),
                       "“example.net” is already excepted.")
        let cannot = listed.exceptionNote(submitted: "api.*.example.com", current: "api.*.example.com")
        XCTAssertEqual(cannot, "ReqRes cannot match “api.*.example.com”. Use a host like api.example.com, or *.example.com for its subdomains.")
    }

    /// Any edit hides it: a note about text the field no longer holds reads
    /// as a second, still-unexplained failure.
    func testAnyEditOfTheFieldHidesIt() {
        for current in ["", "example.ne", "example.net ", "api.example.com"] {
            XCTAssertNil(listed.exceptionNote(submitted: "example.net", current: current), "field now holds \(current.debugDescription)")
        }
    }

    /// The defect: the host removed from the list, and the note
    /// still saying it was listed. A change to the list re-checks it.
    func testRemovingTheHostFromTheListTakesTheNoteWithIt() {
        let removed = listed.removingException("example.net")

        XCTAssertNil(removed.exceptionNote(submitted: "example.net", current: "example.net"))
        XCTAssertNotNil(removed.addingException("example.net"), "…and the same text can be added again")
    }

    /// A reason that does not depend on the list stands until the text is
    /// edited: no list makes "api.*.example.com" matchable.
    func testCannotMatchSurvivesAListChange() {
        let emptied = listed.removingException("example.net")
        XCTAssertNotNil(emptied.exceptionNote(submitted: "api.*.example.com", current: "api.*.example.com"))
    }

    func testNothingRefusedShowsNothing() {
        XCTAssertNil(listed.exceptionNote(submitted: nil, current: "example.net"))
        XCTAssertNil(listed.exceptionNote(submitted: nil, current: ""))
    }

    // MARK: - The field forgets a refusal at its first edit

    /// The note answers one press of Add. Edited away and typed back, the
    /// text is a new entry nobody has submitted yet, and the note stays gone
    /// until Add is pressed again — as Settings ▸ Breakpoints' host field
    /// does. (It used to come back on its own, being derived from the field
    /// alone.)
    func testTypingTheRefusedTextBackDoesNotReviveTheNote() {
        var field = MCPRedactionPolicy.ExceptionField(text: "example.net")
        field.submitted(accepted: false)
        XCTAssertEqual(field.note(for: listed), "“example.net” is already excepted.")

        field.text = "example.ne"
        XCTAssertNil(field.note(for: listed))
        field.text = "example.net"
        XCTAssertNil(field.note(for: listed), "retyped, not resubmitted")
        XCTAssertNil(field.refused)

        field.submitted(accepted: false)
        XCTAssertEqual(field.note(for: listed), "“example.net” is already excepted.", "Add asks again")
    }

    /// A write of the same text — what a binding can do on a focus change —
    /// is not an edit.
    func testWritingTheSameTextKeepsTheRefusal() {
        var field = MCPRedactionPolicy.ExceptionField(text: "example.net")
        field.submitted(accepted: false)
        field.text = "example.net"

        XCTAssertEqual(field.refused, "example.net")
        XCTAssertNotNil(field.note(for: listed))
    }

    /// The note is checked against the list it is shown under, as it is now.
    func testTheFieldsNoteFollowsTheList() {
        var field = MCPRedactionPolicy.ExceptionField(text: "example.net")
        field.submitted(accepted: false)

        XCTAssertNil(field.note(for: listed.removingException("example.net")))
        XCTAssertNotNil(field.note(for: listed))
    }

    func testAnAcceptedEntryEmptiesTheField() {
        var field = MCPRedactionPolicy.ExceptionField(text: "staging.example.org")
        field.submitted(accepted: true)

        XCTAssertEqual(field.text, "")
        XCTAssertNil(field.refused)
        XCTAssertNil(field.note(for: listed))
        XCTAssertFalse(field.canSubmit, "nothing left for Add")
    }

    func testBlankTextCannotBeSubmitted() {
        XCTAssertFalse(MCPRedactionPolicy.ExceptionField(text: "").canSubmit)
        XCTAssertFalse(MCPRedactionPolicy.ExceptionField(text: "   ").canSubmit)
        XCTAssertTrue(MCPRedactionPolicy.ExceptionField(text: " x.com ").canSubmit)
    }
}
