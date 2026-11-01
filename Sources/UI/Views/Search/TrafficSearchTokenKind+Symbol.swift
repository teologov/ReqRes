//
//  TrafficSearchTokenKind+Symbol.swift
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
//  How the search field draws each token kind (process-attribution UX spec
//  §4.1): one SF Symbol per kind for the chip and the suggestion row, and the
//  title of the panel group that offers rows of that kind. `Utils` owns the
//  kinds themselves and stays free of anything visual, so the glyphs live
//  here, beside the only views that draw them.
//
//  The symbol is the FALLBACK. An `app:` chip naming an app the session index
//  knows shows that app's real icon, and a `pid:` chip its app's — see
//  `TrafficSearchProcessLookup` in TrafficSearchField.swift.
//

import Utils

extension TrafficSearchTokenKind {
    /// The glyph a chip (9pt) or a suggestion row (10pt) of this kind shows
    /// when there is no better icon.
    var symbolName: String {
        switch self {
        case .host: return "globe"
        case .method: return "arrow.right.circle"
        case .status: return "number"
        case .path: return "slash.circle"
        case .app: return "app"
        case .pid: return "tag"
        // The chip keeps this symbol even for a country (destination-map UX
        // spec §0: a flag at 9pt is a smudge); the suggestion rows show flags.
        case .country: return "map"
        // The failure chip's own glyph (FailureRowCopy.symbolName(.failed)).
        case .outcome: return "xmark.octagon"
        // The RPC status's own glyph (RPCPresentation.symbolName for an error).
        case .grpc: return "exclamationmark.circle"
        // The Metrics tab's HTTP/2 glyph (doc §S9).
        case .proto: return "square.stack.3d.up"
        }
    }

    /// The suggestions panel's group header for rows of this kind.
    var suggestionsTitle: String {
        switch self {
        case .host: return "Hosts"
        case .method: return "Methods"
        case .status: return "Status"
        case .path: return "Paths"
        case .app: return "Apps"
        case .pid: return "Processes"
        case .country: return "Destinations"
        case .outcome: return "Outcomes"
        case .grpc: return "gRPC status"
        case .proto: return "Protocols"
        }
    }
}
