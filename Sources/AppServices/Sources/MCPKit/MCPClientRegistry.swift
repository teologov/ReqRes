//
//  MCPClientRegistry.swift
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
//  Who is talking to the bridge right now.
//
//  Sockets are the wrong thing to count: `MCPBridgeClient` goes through
//  URLSession, which opens and reuses connections on its own schedule, so a
//  socket census flickers between one and zero while an agent is mid-task.
//  What the user actually wants to know is "is something using this", which is
//  a question about REQUESTS, not connections. So each identified client is
//  remembered with the time it was last seen, and "connected" means it has
//  spoken within `activeWindow`.
//

import Foundation

/// A client that has used the bridge.
public struct MCPClient: Equatable, Sendable, Identifiable {
    /// Stable for the life of one helper process, so two windows of the same
    /// editor count as two clients rather than collapsing into one.
    public let id: String
    /// What to show a human: "Claude Code", "Cursor", "Terminal".
    public let name: String
    /// The helper's own version, for support questions.
    public let version: String?
    /// The MCP client's own pid — the helper's PARENT, sent as `ppid=` (UX
    /// spec §8.1). With per-process attribution on captured sessions this is
    /// what lets the app mark an agent's own requests and filter to them. Nil
    /// for a helper old enough not to send it, or one that sent nonsense.
    public let processID: Int?
    public let firstSeen: Date
    public var lastSeen: Date

    public init(id: String, name: String, version: String? = nil, processID: Int? = nil, firstSeen: Date, lastSeen: Date) {
        self.id = id
        self.name = name
        self.version = version
        self.processID = processID
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Parses and stores bridge client identities.
///
/// Thread-safe through a lock rather than an actor: the router calls `record`
/// on a per-connection queue and the UI reads `clients` on the main thread, and
/// neither can afford to be async.
public final class MCPClientRegistry: @unchecked Sendable {
    /// The header the helper sends. Not `User-Agent`, because URLSession owns
    /// that one and will happily replace it.
    public static let headerName = "x-reqres-client"

    /// How long after its last request a client still counts as connected.
    /// Long enough to survive a human reading the agent's output between tool
    /// calls, short enough that a closed editor disappears while you watch.
    public static let activeWindow: TimeInterval = 90

    private let lock = NSLock()
    private var storage: [String: MCPClient] = [:]
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Records a request from the client described by `header`, if it sent one.
    ///
    /// An unidentified request is deliberately NOT recorded as an anonymous
    /// client: anything holding the token can call the bridge, and inventing a
    /// row for it would put a number in the UI that no user could explain.
    @discardableResult
    public func record(header: String?) -> MCPClient? {
        guard let parsed = Self.parse(header) else { return nil }
        let timestamp = now()
        lock.lock()
        defer { lock.unlock() }
        if var existing = storage[parsed.id] {
            existing.lastSeen = timestamp
            storage[parsed.id] = existing
            return existing
        }
        let client = MCPClient(
            id: parsed.id,
            name: parsed.name,
            version: parsed.version,
            processID: parsed.processID,
            firstSeen: timestamp,
            lastSeen: timestamp
        )
        storage[parsed.id] = client
        return client
    }

    /// Clients seen within `activeWindow`, most recently active first.
    public func activeClients() -> [MCPClient] {
        let cutoff = now().addingTimeInterval(-Self.activeWindow)
        lock.lock()
        defer { lock.unlock() }
        // Drop the stale ones while we are here: a long-lived app would
        // otherwise accumulate an entry per editor window ever opened.
        storage = storage.filter { $0.value.lastSeen >= cutoff }
        return storage.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Forgets everyone. Used when the bridge is switched off, so the UI does
    /// not keep claiming clients are connected to a server that is gone.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    // MARK: - Header format

    /// `name=Claude Code; id=41207; version=0.2.0; ppid=41180`
    ///
    /// Values are trimmed and capped: this string arrives from outside the app
    /// and ends up in the UI, so it may not be long enough to push a sidebar
    /// around or carry newlines into a label. `ppid` is sanitised to a
    /// positive `Int` or dropped — it is matched against captured sessions'
    /// pids, so anything that is not one is not a pid.
    static func parse(_ header: String?) -> (id: String, name: String, version: String?, processID: Int?)? {
        guard let header, !header.isEmpty else { return nil }
        var fields: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = sanitize(String(pair[1]))
            guard !value.isEmpty else { continue }
            fields[key] = value
        }
        guard let id = fields["id"], let name = fields["name"] else { return nil }
        return (id: id, name: name, version: fields["version"], processID: processID(fields["ppid"]))
    }

    /// A pid, or nil: digits only, positive. `Int("-1")` parses and `Int("+5")`
    /// parses, and neither is a process a session could have come from.
    static func processID(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let pid = Int(value), pid > 0 else { return nil }
        return pid
    }

    static func sanitize(_ value: String) -> String {
        let collapsed = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(48))
    }
}
