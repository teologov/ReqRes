//
//  SessionCodable+Destination.swift
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
//  The ONE place the core's server-address field is read (destination-map UX
//  spec §1.1, the `processIdentity` seam's rule). The resolver, the Metrics
//  tab, the MCP detail and the HAR export all go through `remoteAddressText`,
//  so a renamed core field costs one edit here.
//

import Foundation
import XReqResCore

extension SessionCodable {
    /// The address the connection was made to, as the extension recorded it:
    /// a BARE IP literal (IPv4 or IPv6, no port). Nil when the upstream
    /// connect never happened, and nil for an empty string — a core that
    /// predates the field leaves it nil for every row, which the whole
    /// feature then reads as Unknown rather than crashing (spec §7 state 3).
    var remoteAddressText: String? { remoteAddress.flatMap { $0.isEmpty ? nil : $0 } }

    /// Bytes both ways, headers included — the number every destination total
    /// sums. (`list_destinations` sums bodies from the MCP summary instead; a
    /// documented deviation, not a bug to reconcile.)
    var transferredBytes: Int64 { requestBytes.int64Value + responseBytes.int64Value }
}
