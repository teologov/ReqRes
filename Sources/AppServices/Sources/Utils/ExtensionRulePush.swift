//
//  ExtensionRulePush.swift
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
//  Which override rules the app sends to the extension (protocol PRD §1.5,
//  Phase 1a.1).
//
//  The app used to push EVERY stored rule — `findAllRules()` straight into
//  `AppController.notifyExtensionRulesChanged` — and the core matches rules by
//  host and URL only; the one `.enabled` filter in the extension is for
//  breakpoint rules. So a rule the user switched OFF in the Overrides list kept
//  rewriting their traffic until they deleted it.
//
//  The filter lives here, not inline in AppController, for one reason: the app
//  target has no test target, and this is a behaviour change on the user's
//  live traffic. `RuleCodable` is a core type this package cannot import, so
//  the function is generic over the rule and asks the caller only for the
//  flag.
//
//  What this does NOT change: the free tier still counts every STORED rule,
//  enabled or not (`FreeTier.overrideRules`, enforced in `RuleModal` and the
//  MCP write adapter). A disabled rule is still a rule the user keeps and can
//  switch back on with one click; letting disabled rules fall outside the cap
//  would make "switch it off, add another" an unlimited-rules loophole, and
//  whether that is acceptable is a pricing decision, not a protocol fix.
//

import Foundation

public enum ExtensionRulePush {
    /// The rules the extension should apply: the enabled ones, in their stored
    /// order (the core applies the first match, so order is part of the
    /// contract and must survive the filter).
    ///
    /// `enabled` reads the rule's stored flag. It is an `NSNumber` because
    /// that is what `RuleCodable.enabled` is; `isEnabled(_:)` interprets it
    /// exactly as the Overrides list's toggle does, so "applied" and "shown as
    /// on" cannot disagree.
    public static func rulesToPush<Rule>(_ rules: [Rule], enabled: (Rule) -> NSNumber) -> [Rule] {
        rules.filter { isEnabled(enabled($0)) }
    }

    /// The Overrides list's reading of the flag (`RuleView`:
    /// `rule.enabled.boolValue`) — 0 is off, anything else is on.
    public static func isEnabled(_ flag: NSNumber) -> Bool {
        flag.boolValue
    }
}
