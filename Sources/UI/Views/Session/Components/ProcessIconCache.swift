//
//  ProcessIconCache.swift
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
//  The icon beside a process name (process-attribution UX spec §1.3).
//
//  `NSWorkspace.shared.icon(forFile:)` reads the bundle off disk. The traffic
//  table renders up to 5,000 rows and re-renders every 150ms flush while
//  capture runs, so a row must never ask NSWorkspace itself: it asks here, and
//  this asks NSWorkspace ONCE per distinct process for the life of the app.
//

import AppKit
import MCPKit
import UniformTypeIdentifiers

@MainActor
final class ProcessIconCache {
    static let shared = ProcessIconCache()

    /// Stored at 16; views draw it at 16, 14 or 12 through
    /// `Image(nsImage:).resizable().frame(...)`.
    static let storedSize = NSSize(width: 16, height: 16)

    private var icons: [String: NSImage] = [:]

    private init() {}

    /// Nil only when nothing is known about the process — the caller draws the
    /// dashed placeholder. Key = `bundlePath ?? executablePath ?? name`, so a
    /// Chromium browser's dozen helper pids share one lookup.
    func icon(for identity: ProcessIdentity) -> NSImage? {
        guard identity.isKnown,
              let key = identity.bundlePath ?? identity.executablePath ?? identity.name else { return nil }
        if let cached = icons[key] {
            return cached
        }
        let image = load(identity, key: key)
        image.size = Self.storedSize
        icons[key] = image
        return image
    }

    private func load(_ identity: ProcessIdentity, key: String) -> NSImage {
        // Errata 1: a well-known system service is drawn as its symbol, never
        // as an app's icon. `com.apple.WebKit.Networking` carries Safari's
        // traffic AND every other WebKit app's, so Safari's compass would be a
        // lie about half the rows it sat on.
        if let symbol = identity.systemServiceSymbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: identity.displayName) {
            return image
        }
        if FileManager.default.isReadableFile(atPath: key) {
            return NSWorkspace.shared.icon(forFile: key)
        }
        // The process is gone or its bundle is somewhere the sandbox cannot
        // read: a generic app for a bundle path, a generic executable for the
        // rest. Still an icon, so the column never mixes glyph styles for
        // processes that were attributed.
        if key.hasSuffix(".app") {
            // The generic bundle icon is a faint grey square at 16pt — invisible
            // beside real icons. A missing bundle (a debug build that has since
            // moved, an app that was deleted) draws a clear app glyph instead.
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(.init(paletteColors: [.secondaryLabelColor]))
            if let glyph = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                glyph.isTemplate = false
                return glyph
            }
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }
}
