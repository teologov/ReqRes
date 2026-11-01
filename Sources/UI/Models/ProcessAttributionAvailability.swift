//
//  ProcessAttributionAvailability.swift
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

import Foundation

/// Whether the extension can tell which process opens connections on this
/// Mac (process-attribution UX spec §1.6 and §9).
///
/// The extension checks the kernel's socket table against its own socket once
/// per tunnel start and reports the answer over the bus as
/// `.attributionAvailabilityChanged`. Until it does — at launch, and again
/// whenever the tunnel stops — the answer is `.unreported`, which the UI
/// treats like `.available` (the App column shows; a row it cannot name reads
/// Unknown). Only `.unavailable` hides the column, because a table of 5,000
/// dashed glyphs would be noise on every row forever; the five places that
/// explain the hidden column ship in the same build as the hiding.
enum ProcessAttributionAvailability: Equatable {
    /// Nothing reported yet: before the first tunnel start, and after a stop.
    case unreported
    /// The extension's self-check passed; a row that still reads Unknown is a
    /// fact about that connection, not about this Mac.
    case available
    /// The socket table could not be read (a macOS update, most likely).
    /// Capture itself is unaffected.
    case unavailable

    /// The three-valued answer as the agent bridge reports it in
    /// `MCPSetupFacts.processAttribution`: nil until the extension has said,
    /// so `diagnose_setup` can skip the check instead of guessing.
    var isAvailable: Bool? {
        switch self {
        case .unreported: return nil
        case .available: return true
        case .unavailable: return false
        }
    }
}
