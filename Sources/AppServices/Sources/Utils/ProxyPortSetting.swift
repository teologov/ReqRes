//
//  ProxyPortSetting.swift
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
//  The proxy's port: 8034 by default — 8080 and 8888 are the most contested
//  ports on a developer's Mac — and changeable in Settings ▸ Capture. The app
//  sends it in the tunnel's start options and the extension binds it and points
//  the system proxy at it (core `ProxyPort`, whose rule this restates: Utils
//  cannot import the core; both test suites pin the same numbers).
//
//  A busy port is never hopped silently: shell profiles and CI configs pin the
//  number, and a proxy that moved without saying so breaks them all. The app
//  asks first, naming the holder when the socket table can.
//

import Foundation

public enum ProxyPortSetting {
    public static let defaultsKey = "CaptureProxyPort"
    public static let defaultPort = 8034
    /// The app⇄extension bus's port (core `MessageBusPort`): never the proxy's.
    public static let busPort = 50001
    public static let allowedRange = 1024...65535

    public static func isAllowed(_ port: Int) -> Bool {
        allowedRange.contains(port) && port != busPort
    }

    /// The configured port; the default when none is stored or the stored
    /// one is refused.
    public static func current(in defaults: UserDefaults) -> Int {
        let stored = defaults.integer(forKey: defaultsKey)
        return isAllowed(stored) ? stored : defaultPort
    }

    /// Why `text` cannot be the port, or nil when it can.
    public static func problem(with text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let port = Int(trimmed), String(port) == trimmed else { return "Enter a number from 1024 to 65535." }
        if port == busPort { return "\(busPort) is ReqRes's own port between the app and its extension." }
        guard allowedRange.contains(port) else { return "Use a port from 1024 to 65535 — lower ones are reserved for the system." }
        return nil
    }

    /// The note under Settings ▸ Capture's Port field (F13): why Apply
    /// refused `submitted`, only while the field still holds exactly that
    /// text. It was stored text that only a later successful Apply cleared,
    /// so it stayed beside whatever the user typed next.
    public static func problem(submitted: String?, current: String) -> String? {
        guard let submitted, submitted == current else { return nil }
        return problem(with: submitted)
    }

    /// The first allowed port after `port` that `isFree` accepts, trying up
    /// to `attempts` of them.
    public static func suggestion(after port: Int, attempts: Int = 50, isFree: (Int) -> Bool) -> Int? {
        var candidate = port
        for _ in 0..<attempts {
            candidate += 1
            if candidate > allowedRange.upperBound { candidate = allowedRange.lowerBound }
            if isAllowed(candidate), isFree(candidate) { return candidate }
        }
        return nil
    }

    // MARK: Words

    public static let settingsTitle = "Proxy port"

    public static let settingsExplanation =
        "The port on 127.0.0.1 where ReqRes's proxy listens and where the system proxy points while capturing. 8034 is the default; change it if another tool needs that port. A new port applies the next time capture starts, and command-line tools set up with the environment lines need the new lines."

    public static func conflictTitle(port: Int) -> String {
        "Port \(port) is in use"
    }

    public static func conflictMessage(port: Int, holder: String?, suggestion: Int?) -> String {
        let who = holder.map { "\($0) is" } ?? "Another program is"
        let offer = suggestion.map { " Use port \($0) instead? Command-line tools set up with the environment lines will need the new lines." }
            ?? " Quit it, or choose another port in Settings ▸ Capture."
        return "\(who) listening on 127.0.0.1:\(port), where ReqRes's proxy runs, so capture did not start.\(offer)"
    }

    public static func useButton(_ port: Int) -> String { "Use Port \(port)" }

    /// A start the preflight let through that ended before capture connected
    /// (`CaptureTunnelWatch`) — the extension's own bind is the last word.
    /// `reason` is the system's, when it gave one worth reading.
    public static let startFailedTitle = "Capture did not start"

    public static func startFailedMessage(port: Int, reason: String?) -> String {
        let detail = reason.map { "\n\nThe system reported: \($0)" } ?? ""
        return "ReqRes's extension could not start capturing. Its proxy listens on 127.0.0.1:\(port) — if another program is using that port, quit it or choose another port in Settings ▸ Capture.\(detail)"
    }

    /// The `reason` worth showing for the error the system kept
    /// (`fetchLastDisconnectError`), or nil. An error the extension passed
    /// arrives as a plain NSError whose Swift-supplied description stayed in
    /// the extension's process, so what is left is Foundation's generic "The
    /// operation couldn't be completed. (<domain> error <code>.)" — logged,
    /// not shown. That text names the domain raw, or abbreviated for
    /// Foundation's own ("OSStatus error -1", "Cocoa error 99999", "Mach error
    /// N - …"; measured), and always " error <code>". A real description
    /// ("Address already in use") has neither; one that happened to would
    /// only be left out of the alert, never out of the log.
    public static func startFailedReason(for error: NSError) -> String? {
        let description = error.localizedDescription
        let generic = description.contains(error.domain) || description.contains(" error \(error.code)")
        return generic ? nil : description
    }

    /// Settings, while capture runs on another port than the one set.
    public static func pendingNote(running: Int, next: Int) -> String {
        "Capture is running on port \(running); port \(next) applies when capture starts again."
    }
}
