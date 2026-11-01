//
//  MapLocalFileAccess.swift
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
//  Reads the files Map Local rules answer with — across relaunches (F24, 2026-10-26).
//
//  The app is sandboxed: a file picked in the rule form is readable only while
//  this process runs, unless its security-scoped bookmark is kept and resolved
//  later. Until build 59 nothing kept one; after a relaunch every Map Local file
//  outside ~/Downloads and the app's container could not be read, and the rules
//  push sent the rule without its bytes — which the core forwards to the real
//  server, silently. Now the form remembers the chosen file here, the push reads
//  through the bookmark, and a file that still cannot be read is answered by
//  ReqRes with `MapLocalUnreadable` (500 and a note) and marked in the
//  Overrides list. Rules made before build 59 have no bookmark and keep working
//  from their plain path where the sandbox allows it (~/Downloads, the MCP
//  fixtures in the container, a file chosen in this very session).
//

import Foundation
import MCPKit
import XReqResCore

final class MapLocalFileAccess {
    static let shared = MapLocalFileAccess()

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - The store

    /// The bookmarks by stored path (`MapLocalBookmarks`), in the app's defaults.
    /// Callers hold `lock`.
    private var store: [String: Data] {
        get { defaults.dictionary(forKey: MapLocalBookmarks.defaultsKey) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: MapLocalBookmarks.defaultsKey) }
    }

    /// Called by the rule form with the URL the file importer returned, while this
    /// process may read it. Keyed by the path the rule stores (`url.path`), so the
    /// push finds it by `rspPath`.
    func remember(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            lock.lock(); defer { lock.unlock() }
            store = MapLocalBookmarks.storing(bookmark, for: url.path, in: store)
        } catch {
            // The push then falls back to the plain path, as before build 59.
            AppLog.shared.error("[MapLocal] no bookmark for the chosen file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops the bookmarks of files no Map Local rule names any more. `paths` are
    /// every stored Map Local rule's `rspPath`, enabled or not.
    func prune(keeping paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        let pruned = MapLocalBookmarks.pruned(store, keeping: paths)
        if pruned.count != store.count { store = pruned }
    }

    // MARK: - Reading

    /// The file's bytes, or why they could not be read.
    func read(path: String) -> Result<Data, Error> {
        access(path) { url in try Data(contentsOf: url) }
    }

    /// Whether the file can be opened for reading now — an open and a close, not a
    /// read — for the Overrides list's state of a rule whose file is not pushed.
    func canRead(path: String) -> Bool {
        switch access(path, { url in try FileHandle(forReadingFrom: url).close() }) {
        case .success: return true
        case .failure: return false
        }
    }

    /// Runs `body` on the file: through its bookmark when there is one, else at its
    /// plain path (rules made before build 59; ~/Downloads and the MCP fixtures
    /// need no bookmark). The error reported is the bookmark's when both fail.
    private func access<T>(_ path: String, _ body: (URL) throws -> T) -> Result<T, Error> {
        var bookmarkFailure: Error?
        let bookmark = lock.withLock { MapLocalBookmarks.bookmark(for: path, in: store) }
        if let bookmark {
            switch resolve(bookmark, storedFor: path) {
            case .success(let url):
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do { return .success(try body(url)) } catch { bookmarkFailure = error }
            case .failure(let error):
                bookmarkFailure = error
            }
        }
        do {
            return .success(try body(URL(fileURLWithPath: path)))
        } catch {
            return .failure(bookmarkFailure ?? error)
        }
    }

    /// The URL a bookmark resolves to. A stale bookmark (the file moved, the volume
    /// changed) is remade under the SAME key — the rule's stored path — so the next
    /// push finds it; the file is served from wherever it now is.
    private func resolve(_ bookmark: Data, storedFor path: String) -> Result<URL, Error> {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { refresh(url, storedFor: path) }
            return .success(url)
        } catch {
            return .failure(error)
        }
    }

    private func refresh(_ url: URL, storedFor path: String) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        lock.lock(); defer { lock.unlock() }
        store = MapLocalBookmarks.storing(bookmark, for: path, in: store)
    }

    // MARK: - The rules push

    /// What the extension gets for a rule: a Map Local rule carrying its file's
    /// bytes (`mapLocalData`), or — when the file cannot be read — the same rule as
    /// an Override that ReqRes answers with `MapLocalUnreadable` (500 and a note),
    /// so the request never reaches the server (D3) and the failure is visible in
    /// the traffic list. Any other rule is returned as it is.
    func ruleForPush(_ rule: RuleCodable) -> (rule: RuleCodable, fileUnreadable: Bool) {
        guard rule.ruleMode == .MAP_LOCAL else { return (rule, false) }
        let path = rule.rspPath
        let bytes: Result<Data, Error> = path.isEmpty ? .failure(MapLocalReadError.noFile) : read(path: path)
        switch bytes {
        case .success(let data):
            let file = MapLocalFileCodable(
                path: rule.path,
                fileData: data,
                mimeType: MapLocalConfig.mimeType(for: URL(fileURLWithPath: path)),
                hostId: rule.hostId
            )
            guard let encoded = try? JSONEncoder().encode(file),
                  let object = try? JSONSerialization.jsonObject(with: encoded, options: []) as? [String: Any] else {
                AppLog.shared.error("[MapLocal] could not encode a rule's file for the extension")
                return (Self.unreadableAnswer(for: rule), true)
            }
            var carried = rule
            carried.mapLocalData = AnyCodable(object)
            return (carried, false)
        case .failure(let error):
            // The path is the user's file; the reason is enough for the log.
            AppLog.shared.error("[MapLocal] a rule's file cannot be read: \(error.localizedDescription, privacy: .public)")
            return (Self.unreadableAnswer(for: rule), true)
        }
    }

    /// The rule as pushed while its file cannot be read.
    static func unreadableAnswer(for rule: RuleCodable) -> RuleCodable {
        var answer = rule
        answer.ruleMode = .OVERRIDE
        answer.rspCode = NSNumber(value: MapLocalUnreadable.status)
        answer.rspBody = MapLocalUnreadable.body(path: rule.rspPath)
        answer.rspHeaders = MCPRuleAdapter.encodeHeaders([RuleResponseDefaults.contentTypeName: MapLocalUnreadable.contentType])
        answer.mapLocalData = nil
        return answer
    }
}

enum MapLocalReadError: LocalizedError {
    /// A Map Local rule stored with no file path (none can be saved today).
    case noFile

    var errorDescription: String? {
        switch self {
        case .noFile: return "the rule names no file"
        }
    }
}
