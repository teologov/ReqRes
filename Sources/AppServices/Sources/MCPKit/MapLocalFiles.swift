//
//  MapLocalFiles.swift
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
//  F24 (2026-10-26): a Map Local rule's file after a relaunch.
//
//  The app is sandboxed. A file the user picks for a Map Local rule is readable
//  only while that process runs — macOS grants a picked file to the process, not
//  to the app — unless the app keeps the file's security-scoped bookmark and
//  resolves it later. Until build 59 nothing kept one, so after a relaunch every
//  Map Local file outside ~/Downloads (an entitlement) and the app's own container
//  (the MCP fixtures) was unreadable, the rules push sent the rule WITHOUT its
//  bytes, the core forwarded such a rule's request to the real server, and the
//  real answer came back with nothing anywhere saying so (e2e plan F24;
//  pre-existing since 1.0.x).
//
//  Two pure pieces live here so they can be tested: the side store of bookmarks,
//  keyed by the path the rule stores (`RuleCodable.rspPath`), and the answer a
//  matching request gets while the file cannot be read — ReqRes's own 500 with a
//  note, never the server's response (a mock never reaches the server, D3). The
//  AppKit half — making, resolving and reading through bookmarks — is
//  `MapLocalFileAccess` in Sources/UI/Services.
//

import Foundation

/// The bookmarks of Map Local files, as the app keeps them in its defaults: one
/// per stored path. Pure functions over the dictionary; the app persists it.
public enum MapLocalBookmarks {
    /// The `UserDefaults` key the app keeps the dictionary under. The bookmarks
    /// survive an update only while this spelling does.
    public static let defaultsKey = "MapLocalFileBookmarks"

    public static func bookmark(for path: String, in store: [String: Data]) -> Data? {
        store[path]
    }

    /// The store with `bookmark` under `path`; a file chosen again replaces its
    /// bookmark.
    public static func storing(_ bookmark: Data, for path: String, in store: [String: Data]) -> [String: Data] {
        var store = store
        store[path] = bookmark
        return store
    }

    /// The store without the bookmarks of files no rule names any more. `paths`
    /// are the `rspPath`s of EVERY stored Map Local rule, enabled or not — a
    /// disabled rule's file must still be readable when it is switched back on.
    public static func pruned(_ store: [String: Data], keeping paths: some Sequence<String>) -> [String: Data] {
        let keep = Set(paths)
        return store.filter { keep.contains($0.key) }
    }
}

/// What a Map Local rule does while its file cannot be read: it is pushed to the
/// extension as an Override that ReqRes answers itself, so the request never
/// reaches the server and the failure shows in the traffic list; the Overrides
/// list and the rule form mark the rule.
public enum MapLocalUnreadable {
    /// The status ReqRes answers with. 500: ReqRes, standing in for the server on
    /// this URL, could not produce the response it was configured to. Never the
    /// core's 502, which means the real server could not be reached.
    public static let status = 500
    public static let contentType = "text/plain; charset=utf-8"

    /// The response body: the file, the likely causes, the fix, and that the
    /// server was not asked.
    public static func body(path: String) -> String {
        """
        ReqRes could not read the file this Map Local rule answers with: \(path)
        The file was moved or deleted, or ReqRes no longer has permission to read it. Open Overrides in ReqRes, edit the rule and choose the file again. The request was not sent to the server.
        """
    }

    // The app's words.

    /// The Overrides list's mark on the rule.
    public static let listRowLabel = "File can't be read"

    /// The mark's tooltip and accessibility label.
    public static func listRowHelp(fileName: String) -> String {
        "ReqRes can't read \(fileName). Edit the override and choose the file again. Until then a matching request is answered with \(status) and a note, not with the server's response."
    }

    /// The rule form's line under an existing file ReqRes cannot read.
    public static func formMessage(fileName: String) -> String {
        "ReqRes can't read \(fileName) any more. Choose it again to let ReqRes read it."
    }
}
