//
//  CountryNames.swift
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
//  ISO code → what a person reads: a localized name and a flag. Both are pure
//  functions of the code; the names come from the system's locale data, so
//  they follow the user's language for free.
//

import Foundation

public enum CountryNames {

    /// "DE" → "Germany" (in `locale`'s language). Nil for anything that is not
    /// a two-letter code, for "ZZ", and for codes the locale data has no name
    /// for — never the bare code dressed up as a name.
    public static func name(for iso: String, locale: Locale = .current) -> String? {
        guard let code = normalized(iso) else { return nil }
        guard let name = locale.localizedString(forRegionCode: code), name != code else { return nil }
        return name
    }

    /// "US" → "🇺🇸": the two regional-indicator symbols. Nil for anything that
    /// is not a two-letter code and for "ZZ".
    public static func flag(for iso: String) -> String? {
        guard let code = normalized(iso) else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            guard let indicator = Unicode.Scalar(0x1F1E6 + scalar.value - 65) else { return nil }
            scalars.append(indicator)
        }
        return String(scalars)
    }

    /// Uppercases and validates; "ZZ" (DB-IP's "unassigned") is not a country.
    static func normalized(_ iso: String) -> String? {
        let code = iso.uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }), code != "ZZ" else {
            return nil
        }
        return code
    }
}
