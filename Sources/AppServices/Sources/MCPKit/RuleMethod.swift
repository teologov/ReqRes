//
//  RuleMethod.swift
//  ReqRes
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
//  A rule's request method as the app stores, shows and edits it.
//
//  Until 1.1.0 the core never read a rule's method, so the override form
//  saved GET whatever the user meant and every "GET" rule answered POST,
//  PUT and DELETE too. Since 1.1.0 the core HONOURS the method (core step
//  C4, decision D4): `""` means any method, and every rule stored before
//  1.1.0 is migrated to `""` once. So the app must store `""` for "any" and
//  offer it as the default — otherwise a rule made in the form, or by an
//  agent that omits the method, silently stops matching its POSTs.
//

import Foundation

public enum RuleMethod {
    /// What "any method" is stored as. The core also accepts "*" and "ANY"
    /// (`RuleMatcher.methodMatches`), but the app only ever writes this.
    public static let any = ""

    /// The methods a rule can be limited to — the core's
    /// `RequestMethodOption`, in its order.
    public static let specific = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    /// A stored method that means "any method".
    public static func isAny(_ stored: String) -> Bool {
        let trimmed = stored.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "*" || trimmed.caseInsensitiveCompare("ANY") == .orderedSame
    }

    /// How a stored method reads in the rule list, a consent panel or a tool
    /// result: "Any" for any method (an empty string rendered a blank), the
    /// method upper-cased otherwise.
    public static func displayName(_ stored: String) -> String {
        isAny(stored) ? "Any" : stored.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// The form's picker value for a stored method: `any` for any method,
    /// the upper-cased method otherwise. A method the picker does not list
    /// (an older app, a hand-edited database) is kept as it is, so opening
    /// and saving a rule never changes what it matches.
    public static func formSelection(forStored stored: String) -> String {
        isAny(stored) ? any : stored.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// The picker's choices for a rule whose stored method is `stored`:
    /// Any, the specific methods, and the stored one if it is none of those.
    public static func formChoices(forStored stored: String) -> [String] {
        let selected = formSelection(forStored: stored)
        var choices = [any] + specific
        if !choices.contains(selected) { choices.append(selected) }
        return choices
    }
}
