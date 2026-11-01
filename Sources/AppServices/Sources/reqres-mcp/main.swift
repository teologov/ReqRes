//
//  main.swift
//  reqres-mcp
//
//  Entry point for the ReqRes MCP server. This binary ships inside the app
//  bundle and is spawned over stdio by an MCP client (Claude Code, Cursor,
//  Codex …). It holds no traffic itself — it reads the handshake written by
//  the running ReqRes app and proxies tool calls to the app's loopback bridge.
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

ReqResMCPServer.main()
