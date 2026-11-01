//
//  TrafficSearchDestinationSuggestions.swift
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
//  The rows the search panel offers after `country:` (destination-map UX
//  spec §5.3), as pure data so `swift test` covers the ranking. The field
//  model hands in what `SessionState.countrySuggestions()` returns — every
//  destination seen in the retained traffic, busiest first, Unknown last —
//  and gets back the rows to draw, each carrying the TOKEN that Return
//  commits: a row reads "Germany" and commits `DE`.
//

import Foundation

/// One candidate row: the token the chip will hold (`US` / `mac` / `local` /
/// `unknown`), the title the row shows (the localised country name or the
/// class label), and how many retained requests went there.
public typealias TrafficSearchDestinationCandidate = (token: String, title: String, requests: Int)

extension TrafficSearchSuggestions {
    /// Destination suggestions for the text typed after `country:`.
    ///
    /// The query is matched against BOTH the title and the token, so `un`
    /// offers United States and Unknown, `de` offers Germany (its code) and
    /// Denmark (its name), and `mac` finds This Mac. Prefix matches on either
    /// come before substring matches, each keeping the candidates' own order;
    /// committed tokens are excluded and duplicates collapse (both after
    /// `TrafficSearchCountryMatch.normalize`, so `us` and `US` are one row);
    /// a candidate whose token cannot be normalised is dropped rather than
    /// offered as a row that could never commit. `limit` is applied, then
    /// Unknown is moved last whatever its count — it is the resolver's
    /// placeholder, not a competitor for the top of the list (the `app:`
    /// panel's rule for its own Unknown). The returned tokens are the
    /// normalised ones.
    public static func destinations(
        matching query: String,
        in candidates: [TrafficSearchDestinationCandidate],
        excluding committed: [String],
        limit: Int = 10
    ) -> [TrafficSearchDestinationCandidate] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let committedTokens = Set(committed.compactMap(TrafficSearchCountryMatch.normalize))
        var seen = Set<String>()
        var prefixMatches: [TrafficSearchDestinationCandidate] = []
        var substringMatches: [TrafficSearchDestinationCandidate] = []
        for candidate in candidates {
            guard let token = TrafficSearchCountryMatch.normalize(candidate.token),
                  !seen.contains(token),
                  !committedTokens.contains(token) else { continue }
            let title = candidate.title.lowercased()
            let tokenKey = token.lowercased()
            let row: TrafficSearchDestinationCandidate = (token: token, title: candidate.title, requests: candidate.requests)
            if needle.isEmpty || title.hasPrefix(needle) || tokenKey.hasPrefix(needle) {
                seen.insert(token)
                prefixMatches.append(row)
            } else if title.contains(needle) || tokenKey.contains(needle) {
                seen.insert(token)
                substringMatches.append(row)
            }
        }
        var ranked = Array((prefixMatches + substringMatches).prefix(max(0, limit)))
        if let unknown = ranked.firstIndex(where: { $0.token == TrafficSearchCountryMatch.unknown }),
           unknown != ranked.count - 1 {
            ranked.append(ranked.remove(at: unknown))
        }
        return ranked
    }
}
