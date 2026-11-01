//
//  CountryPresentation.swift
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
//  How a destination is shown (destination-map UX spec §1.3): the flag, the
//  localised name, the symbol for a class, and the reverse — which code a
//  typed name means. Everything comes from Foundation's own region data, so
//  the names are the ones System Settings shows, in the user's language, with
//  no table of our own to keep current.
//

import Foundation

public enum CountryPresentation {
    /// Codes that ICU lists as regions but that have no flag glyph in the
    /// emoji set (Unicode's RGI flags are the ISO 3166-1 codes plus EU and
    /// UN). A regional-indicator pair for these renders as two boxed letters,
    /// which is worse than the `flag` symbol the caller falls back to.
    static let codesWithoutAFlag: Set<String> = ["XK", "ZZ", "EZ", "QO", "XA", "XB"]

    /// The two-letter ISO regions Foundation knows, upper-cased. The list is
    /// the same for every locale; only the names differ.
    static let isoRegionCodes: [String] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 }
        .map { $0.uppercased() }
        .sorted()

    /// Regional indicators: `"US"` → 🇺🇸. `""` for anything that is not a
    /// two-letter ISO region with a flag (`XK`, `ZZ` → `""`), so a caller can
    /// test for emptiness and draw the `flag` symbol instead.
    public static func flag(for isoCode: String) -> String {
        guard let code = TrafficDestination.isoCode(from: isoCode.trimmingCharacters(in: .whitespaces)),
              !codesWithoutAFlag.contains(code),
              isoRegionCodes.contains(code) else {
            return ""
        }
        let base: UInt32 = 0x1F1E6
        var flag = ""
        for scalar in code.unicodeScalars {
            guard let letter = Unicode.Scalar(base + scalar.value - Unicode.Scalar("A").value) else { return "" }
            flag.unicodeScalars.append(letter)
        }
        return flag
    }

    /// `Locale.localizedString(forRegionCode:) ?? isoCode` — what System
    /// Settings shows, localised for free.
    public static func name(for isoCode: String, locale: Locale = .current) -> String {
        let code = isoCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return isoCode }
        return locale.localizedString(forRegionCode: code) ?? code
    }

    /// Which two-letter region a typed name means, in `locale`'s language.
    /// An exact name wins; else a UNIQUE prefix; else a UNIQUE substring;
    /// else nil. `"germ"` → `"DE"`; `"united"` → nil (United States, United
    /// Kingdom, United Arab Emirates…); `"Deutschland"` → `"DE"` under de_DE.
    ///
    /// Codes are not accepted here on purpose: `"de"` is Denmark's prefix
    /// and Germany's code, and the caller (`TrafficSearchCountryMatch.
    /// normalize` first, this second) decides which rule wins.
    public static func code(matchingName query: String, locale: Locale = .current) -> String? {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }
        let named = isoRegionCodes.compactMap { code -> (code: String, name: String)? in
            guard let name = locale.localizedString(forRegionCode: code) else { return nil }
            return (code, name.lowercased())
        }
        if let exact = named.first(where: { $0.name == needle }) {
            return exact.code
        }
        let prefixed = named.filter { $0.name.hasPrefix(needle) }
        if prefixed.count == 1 { return prefixed[0].code }
        if prefixed.count > 1 { return nil }
        let contained = named.filter { $0.name.contains(needle) }
        return contained.count == 1 ? contained[0].code : nil
    }

    /// Country name | "This Mac" | "Local Network" | "Unknown".
    public static func title(for destination: TrafficDestination, locale: Locale = .current) -> String {
        switch destination {
        case .country(let code): return name(for: code, locale: locale)
        case .thisMac: return TrafficDestination.thisMacLabel
        case .localNetwork: return TrafficDestination.localNetworkLabel
        case .unknown: return TrafficDestination.unknownLabel
        }
    }

    /// nil for a country (it has a flag, or the caller's `flag` fallback);
    /// the SF Symbol for each class.
    public static func symbolName(for destination: TrafficDestination) -> String? {
        switch destination {
        case .country: return nil
        case .thisMac: return "desktopcomputer"
        case .localNetwork: return "wifi.router"
        case .unknown: return "questionmark.circle.dashed"
        }
    }

    /// `"1 request"`, `"1,204 requests"` — grouped digits through
    /// `NumberFormatter.decimal` in `locale`, and a plain `s` for the plural,
    /// which is all the units this feature counts (request, host, app,
    /// destination) need.
    public static func plural(_ n: Int, _ unit: String, locale: Locale = .current) -> String {
        "\(groupedDigits(n, locale: locale)) \(unit)\(n == 1 ? "" : "s")"
    }

    /// `1204` → `"1,204"` (or `"1.204"` under de_DE).
    public static func groupedDigits(_ n: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}
