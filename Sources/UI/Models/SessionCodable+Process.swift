//
//  SessionCodable+Process.swift
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
//  The ONE place the core's process fields are read (process-attribution UX
//  spec §1.1). The App column, the `app:`/`pid:` filter, the detail pill, the
//  saved-sessions browser and the MCP summary all go through `processIdentity`,
//  so a renamed core field costs one edit here and cannot leave two surfaces
//  disagreeing about which app made a request.
//

import Foundation
import MCPKit
import XReqResCore

extension SessionCodable {
    /// The process that opened this session's connection, as the extension
    /// attributed it — all three fields nil when it could not. Attribution is
    /// per CONNECTION: every session on one keep-alive connection reads the
    /// same identity. `ProcessIdentity` owns every display rule (bundle name
    /// over helper name, the well-known system services, "Unknown").
    var processIdentity: ProcessIdentity {
        ProcessIdentity(name: processName, pid: processID, executablePath: processPath)
    }
}
