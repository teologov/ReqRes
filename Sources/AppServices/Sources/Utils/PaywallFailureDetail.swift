//
//  PaywallFailureDetail.swift
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
//  Which words a failure alert may show as its detail (PaywallFailure.swift).
//
//  The detail is text the app did not write: the license server's message
//  for a key it did not accept, or an unexpected error's description. It is
//  shown only when it carries nothing private and says nothing about how the
//  license is checked; otherwise the alert goes without it, and its title,
//  message and buttons still say what happened and what to do. Left out:
//
//   - anything shaped like a license key (the key field's prompt itself is
//     allowed: it is the shape, not a key), a UUID (a device id), a Mac
//     serial number, or a long opaque run of letters and digits (a token, a
//     nonce, a hash);
//   - the words that would describe the check: "serial", "token",
//     "entitlement", "nonce", "signature", "Keychain", "30 days", "once a
//     day", "every day", "24 hours".
//
//  A detail is flattened to one line and cut at `detailLimit` characters.
//

import Foundation

extension PaywallCopy {
    /// The longest detail shown, in characters; a longer one ends with "…".
    static let detailLimit = 200

    /// Words that would say how or when the license is checked, lowercased.
    static let checkWords = [
        "serial", "token", "entitlement", "nonce", "signature", "keychain",
        "30 days", "once a day", "every day", "24 hours",
    ]

    /// `text` as an alert's detail, or nil when there is nothing to show or
    /// it may not be shown.
    static func shownDetail(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        let lowered = line.lowercased()
        if checkWords.contains(where: { lowered.contains($0) }) { return nil }
        if carriesPrivateValue(line) { return nil }
        guard line.count > detailLimit else { return line }
        return String(line.prefix(detailLimit - 1)) + "…"
    }

    /// XXXXX-XXXXX-XXXXX-XXXXX, letters or digits.
    private static let licenseKeyShape = pattern("(?<![A-Za-z0-9])[A-Za-z0-9]{5}(?:-[A-Za-z0-9]{5}){3}(?![A-Za-z0-9])")

    /// A UUID: the device id of a Mac whose serial number cannot be read.
    private static let uuidShape = pattern("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

    /// A Mac serial number: 8 to 15 capitals and digits, at least one of each.
    private static let serialShape = pattern(
        "(?<![A-Za-z0-9])(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{8,15}(?![A-Za-z0-9])")

    /// A run of base64 or base64url characters long enough to be a token, a
    /// nonce or a hash; `carriesPrivateValue` decides whether it reads as one.
    private static let longRun = pattern("[A-Za-z0-9_+=-]{16,}")

    private static func pattern(_ source: String) -> NSRegularExpression {
        // The patterns are constants: one that does not compile is a typo the
        // first test run traps on (MCPRedactor's patterns do the same).
        try! NSRegularExpression(pattern: source)
    }

    /// True when `text` shows something private: a license key, a device id,
    /// a serial number, or an opaque run. A run is opaque when it holds a
    /// digit or mixes capitals and small letters after its first character,
    /// which a word does not ("Unfortunately", "REQRES_DEV_LICENSE_API").
    static func carriesPrivateValue(_ text: String) -> Bool {
        let whole = NSRange(text.startIndex..., in: text)
        for match in licenseKeyShape.matches(in: text, range: whole) {
            if let range = Range(match.range, in: text), text[range].uppercased() != keyPrompt {
                return true
            }
        }
        if uuidShape.firstMatch(in: text, range: whole) != nil { return true }
        if serialShape.firstMatch(in: text, range: whole) != nil { return true }
        for match in longRun.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            let run = text[range]
            if run.contains(where: \.isNumber) { return true }
            let rest = run.dropFirst()
            if rest.contains(where: \.isUppercase) && rest.contains(where: \.isLowercase) { return true }
        }
        return false
    }
}
