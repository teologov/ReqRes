//
//  MCPRedactionExceptionNote.swift
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
//  The line under Settings ▸ MCP ▸ Redaction's "Send unmasked" field when Add
//  refuses what was typed (F13: found live 2026-09-30 in Settings ▸ Capture's
//  exclusion list, whose note worked the same way this one did).
//
//  It was stored text, cleared only by a later successful Add: the field
//  could be emptied, or the host it complained about removed from the list,
//  and "“example.net” is already excepted." stayed on screen describing
//  neither. The note now belongs to the submission it was written for. It is
//  DERIVED — from the text Add refused, the text in the field now, and the
//  list as it is now — and `ExceptionField` forgets the refusal at the
//  field's first edit, so any edit hides the note until Add is pressed again
//  (typing the refused text back does not revive it) and a change to the
//  list re-checks it; nothing has to remember to clear it.
//

import Foundation

extension MCPRedactionPolicy {
    /// Why Add refuses an entry.
    public enum ExceptionRefusal: Equatable, Sendable {
        /// No host could ever match it (`canonicalEntry` is nil): a bare
        /// "*", a wildcard anywhere but the front, whitespace inside.
        case cannotMatch
        /// The list already excepts it, in this or another spelling.
        case alreadyExcepted
    }

    /// Why Add would refuse `raw` against this list now, or nil when it
    /// would add it. Blank text is nil: the field does not submit it.
    public func refusal(forException raw: String) -> ExceptionRefusal? {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard Self.canonicalEntry(raw) != nil else { return .cannotMatch }
        return addingException(raw) == nil ? .alreadyExcepted : nil
    }

    /// The note to show under the field, or nil.
    ///
    /// `submitted` is the text Add refused (nil when nothing was refused);
    /// `current` is the field's text now. The note is shown only while the
    /// field still holds exactly what was refused, and only while the reason
    /// is still true of this list — so removing “example.net” from the list
    /// takes "“example.net” is already excepted." with it, and the same text
    /// can be added again.
    public func exceptionNote(submitted: String?, current: String) -> String? {
        guard let submitted, submitted == current,
              let refusal = refusal(forException: submitted) else { return nil }
        switch refusal {
        case .cannotMatch:
            // Said plainly, because the only wildcard form that works is the
            // leading one, and an entry that matches nothing looks identical
            // to redaction being broken.
            return "ReqRes cannot match “\(submitted)”. Use a host like api.example.com, or *.example.com for its subdomains."
        case .alreadyExcepted:
            return "“\(submitted)” is already excepted."
        }
    }

    /// The "Send unmasked" field and what Add last refused in it, kept
    /// together so the rule that ties them lives in one place: a refusal
    /// belongs to one submission, and the field's first edit forgets it.
    /// Typing the refused text back does not bring the note back — pressing
    /// Add does, if the reason still holds. Settings ▸ Breakpoints' host
    /// field drops its note on any edit the same way.
    public struct ExceptionField: Equatable, Sendable {
        /// The field's text. Any change to it forgets the refusal.
        public var text: String {
            didSet { if text != oldValue { refused = nil } }
        }

        /// What Add refused, until the field changes.
        public private(set) var refused: String?

        public init(text: String = "") {
            self.text = text
        }

        /// Whether Add has anything to submit — the field ignores blank text.
        public var canSubmit: Bool {
            !text.trimmingCharacters(in: .whitespaces).isEmpty
        }

        /// Add was pressed, and the list took the text (`accepted`) or did not.
        public mutating func submitted(accepted: Bool) {
            if accepted {
                text = ""
                refused = nil
            } else {
                refused = text
            }
        }

        /// The note under the field, checked against `policy` — the list as
        /// it is now, so removing the host it named takes the note with it.
        public func note(for policy: MCPRedactionPolicy) -> String? {
            policy.exceptionNote(submitted: refused, current: text)
        }
    }
}
