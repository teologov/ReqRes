//
//  PinnedHostCopy.swift
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
//  The words for a connection to a host macOS itself pins. The core relays
//  such a host untouched and records it as a relay row whose `pinnedBy`
//  names the macOS pinning policy ("MMCS", "AMP", …): every app on Apple's
//  TLS stack accepts only an Apple-issued certificate for it, so decrypting
//  it is impossible and trying breaks the app. These connections stay in the
//  table, marked as pinned — never silently dropped like an excluded host.
//

import Foundation

/// Why a relay row is pinned, read from its `pinnedBy`: a macOS pinning
/// policy ("MMCS"), or `app:<domain>` for an app that refused ReqRes's
/// certificate for that domain (core `LearnedPins`).
public enum PinSource: Equatable, Sendable {
    case macOS(policy: String)
    case app(domain: String)

    public static let appPrefix = "app:"

    public init?(pinnedBy: String?) {
        guard let pinnedBy, !pinnedBy.isEmpty else { return nil }
        if pinnedBy.hasPrefix(Self.appPrefix) {
            self = .app(domain: String(pinnedBy.dropFirst(Self.appPrefix.count)))
        } else {
            self = .macOS(policy: pinnedBy)
        }
    }
}

public enum PinnedHostCopy {
    /// The service a macOS pinning policy protects, in words a user knows.
    /// Policies not listed here (the list has 51) read "an Apple service";
    /// the policy's own name is always shown beside it.
    public static func serviceName(policy: String) -> String {
        switch policy {
        case "MMCS", "iCloudSetup": return "iCloud"
        case "Escrow": return "iCloud Keychain"
        case "AMP": return "the App Store and Apple media"
        case "APN": return "Apple push notifications"
        case "FMiP": return "Find My"
        case "IDS": return "iMessage and FaceTime"
        case "ApplePay", "PaymentCardReader": return "Apple Pay"
        case "Pallas", "MacSoftwareUpdate", "Updates", "Personalization": return "Software Update"
        case "Siri", "SiriClientFlow": return "Siri"
        case "GS", "IdMS": return "the Apple Account"
        case "GameCenter": return "Game Center"
        case "Shazam", "ShazamKit": return "Shazam"
        case "WeatherKit": return "Weather"
        case "CoreLocationTiles": return "Maps and Location"
        case "HealthProvider", "HealthR&D": return "Health"
        case "Activation": return "device activation"
        default: return "an Apple service"
        }
    }

    /// "iCloud (MMCS)".
    public static func serviceAndPolicy(_ policy: String) -> String {
        "\(serviceName(policy: policy)) (\(policy))"
    }

    /// The app a row names, or a stand-in when attribution had none.
    private static func name(_ appName: String?) -> String {
        guard let appName, !appName.isEmpty else { return "the app" }
        return appName
    }

    public static let title = "SSL pinned"

    /// The word the traffic row prints after the endpoint.
    public static func rowWord(_ source: PinSource, appName: String?) -> String {
        switch source {
        case .macOS(let policy): return "SSL pinned by macOS · \(serviceName(policy: policy))"
        case .app: return "SSL pinned by \(name(appName))"
        }
    }

    /// The one paragraph that explains a pinned row.
    public static func explanation(_ source: PinSource, appName: String?) -> String {
        switch source {
        case .macOS(let policy):
            return "SSL pinned by macOS — this host is on macOS's own certificate-pinning list, for \(serviceAndPolicy(policy)). Every app on this Mac accepts only a certificate Apple issued for it, whatever else the Mac trusts, so no proxy can decrypt it. ReqRes passed the connection on untouched so the app keeps working, and recorded where it went, the bytes each way and how long it stayed open."
        case .app(let domain):
            let app = name(appName)
            return "SSL pinned by \(app) — \(app) refused ReqRes's certificate for \(domain) earlier: it checks its servers' certificates itself (certificate pinning), so nothing inside can be decrypted. ReqRes now passes \(app)'s connections to \(domain) through untouched so it keeps working, and records where they went, the bytes each way and how long they stayed open."
        }
    }

    public static func remedy(_ source: PinSource) -> String {
        switch source {
        case .macOS:
            return "Nothing to fix: this is macOS's rule, not a ReqRes setting, and installing a certificate does not change it. To pass such a host through without a row, exclude it in Settings ▸ Capture."
        case .app:
            return "To try decrypting it again — after the app changes, or if the refusal was a one-off — forget it under SSL-pinned apps in Settings ▸ Capture."
        }
    }

    /// The Code cell's tooltip and accessibility label.
    public static func cellHelp(_ source: PinSource, appName: String?) -> String {
        switch source {
        case .macOS(let policy):
            return "SSL pinned by macOS (\(serviceName(policy: policy))) — relayed without decrypting, because macOS accepts only Apple's certificate for this host."
        case .app(let domain):
            return "SSL pinned by \(name(appName)) — relayed without decrypting, because \(name(appName)) refused ReqRes's certificate for \(domain)."
        }
    }

    // MARK: Settings ▸ Capture ▸ SSL-pinned apps

    public static let settingsTitle = "SSL-pinned apps"

    public static let settingsExplanation =
        "When an app refuses ReqRes's certificate because it checks its servers' certificates itself (SSL pinning) — WhatsApp does for its media — the request that hit it fails, and ReqRes remembers the app and the domain: from then on that app's connections there are passed through untouched, so it keeps working while you capture. They still appear in the traffic list, marked SSL pinned; nothing inside them can be read. Hosts macOS itself pins (iCloud, Software Update, the App Store…) are passed through the same way and are not listed here."

    public static let settingsEmpty = "No app has refused ReqRes's certificate yet."

    /// A refused row whose app and domain ReqRes remembered.
    public static func rememberedNote(appName: String?, domain: String) -> String {
        "ReqRes remembered this: \(name(appName))'s connections to \(domain) now pass through untouched, marked SSL pinned — try again in the app. Forget it to try decrypting again."
    }

    /// A remembered app with no attribution applies to every app.
    public static let anyApp = "Any app"

    /// Help's bullet, and the sentence an agent reads beside the protocol table.
    public static let helpBullet =
        "A row marked “SSL pinned” is a connection ReqRes passed through without decrypting because its certificate is pinned — by macOS for Apple's own services (iCloud, Software Update, the App Store, push notifications, Find My and others), or by an app that refused ReqRes's certificate once, like WhatsApp for its media. The connection works while you capture, and the row shows where it went and how much it sent; nothing inside it can be read by any proxy. Settings ▸ Capture lists the apps ReqRes remembered, and forgets any you choose."
}
