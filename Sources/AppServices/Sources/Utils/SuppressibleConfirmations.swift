//
//  SuppressibleConfirmations.swift
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
//  The UserDefaults keys behind every “Don’t ask again” checkbox in the app,
//  the checkbox's title, when an answer is remembered, and the one alert text
//  that carries a number.
//
//  Why this exists rather than string literals at the call sites:
//  `skipRuleDeleteConfirmation` has shipped since 1.0.x written by a checkbox
//  on the delete-override alert and READ NOWHERE ELSE in the repo — no
//  Settings row, no menu item, nothing. A user who ticks it while meaning to
//  click Cancel has silently turned off the only guard on a destructive action
//  and has no way back short of `defaults delete`. Collecting the keys in one
//  place makes `resetAll(in:)` possible, which is the fix; a per-prompt toggle
//  in Settings would be a row of switches nobody reads and a maintenance tax
//  on every new prompt.
//
//  `all` is the list a future prompt must be added to. Anything not in it is
//  invisible to the reset, which is exactly the state this type exists to end.
//

import Foundation

/// The suppressible confirmation prompts, by their UserDefaults key.
///
/// A key is `true` when the user ticked “Don’t ask again” on that alert and
/// went ahead. The default — absent, i.e. `false` — asks.
public enum SuppressibleConfirmations {
    /// Deleting one override rule. Shipped in 1.0.x; the spelling is load
    /// bearing — changing it would silently un-suppress the prompt for every
    /// existing install, so it stays as written.
    public static let ruleDelete = "skipRuleDeleteConfirmation"

    /// Deleting a host filter, which takes that host's override rules with it
    /// (`ReqResCoreModelBridge.deleteHost` deletes the rules first, and the
    /// `hostId` foreign key cascades besides).
    public static let hostDelete = "skipHostDeleteConfirmation"

    /// Clearing the captured-traffic buffer. Nothing in the app persists those
    /// sessions unless the user saved them, so the buffer is all there is.
    public static let clearTraffic = "skipClearTrafficConfirmation"

    /// Every key, so a reset cannot miss one. Add a new prompt's key here in
    /// the same commit that introduces it — the test asserting this list has
    /// no duplicates is also where a typo'd copy-paste shows up.
    public static let all: [String] = [
        ruleDelete,
        hostDelete,
        clearTraffic,
    ]

    /// Puts every suppressed prompt back. The user asked for the confirmation
    /// again, so removing the keys (rather than writing `false`) is the honest
    /// result: the stored state goes back to never-answered.
    public static func resetAll(in defaults: UserDefaults) {
        for key in all {
            defaults.removeObject(forKey: key)
        }
    }

    /// True when at least one prompt is currently suppressed — what a Settings
    /// row would enable itself on, so it is not offering to undo nothing.
    public static func anySuppressed(in defaults: UserDefaults) -> Bool {
        all.contains { defaults.bool(forKey: $0) }
    }

    // MARK: - The checkbox

    /// The checkbox's title on every suppressible alert, and the words Settings
    /// quotes. It is the title macOS 27 itself gives the suppression button of
    /// an alert with two buttons or more, as these have, typographic apostrophe
    /// included (with fewer it says "Do not show this message again"). Older
    /// macOS may word it otherwise — NSAlert.h gives "Do not ask again" for
    /// such an alert since macOS 11 — so the app sets it, and every macOS from
    /// 14.6 (the deployment target) shows the same words.
    public static let checkboxTitle = "Don\u{2019}t ask again"

    /// Whether an answer turns its prompt off: only the action itself, chosen
    /// with the box ticked. Cancel with the box ticked silences nothing — the
    /// person backed out of the action, and the alert they backed out with is
    /// a guard they still want.
    public static func remembersChoice(confirmed: Bool, ticked: Bool) -> Bool {
        confirmed && ticked
    }

    // MARK: - Clear Captured Traffic

    /// The Clear Captured Traffic alert's text. The count is written the way
    /// `locale` groups numbers — "1,127 captured requests" in English, where
    /// the alert used to print 1127 — and the rest is word for word what it
    /// said before.
    public static func clearTrafficMessage(count: Int, locale: Locale) -> String {
        let number = count.formatted(.number.locale(locale))
        let requests = count == 1 ? "\(number) captured request" : "\(number) captured requests"
        return """
        \(requests) will be discarded. Captured traffic is held in memory only — \
        anything you have not saved cannot be recovered, and rerunning a request \
        produces a different exchange.

        Saved sessions are not affected.
        """
    }
}
