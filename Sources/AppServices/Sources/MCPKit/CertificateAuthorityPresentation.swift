//
//  CertificateAuthorityPresentation.swift
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
//  What the user is told about ReqRes's certificate authority, and when
//  (protocol PRD §1.11, 4 Phase 2.1, shell step S4). 1.1.0 gives every
//  install its own CA (core step C8); 1.0.x installed ONE CA whose private key
//  was in every public download. This file decides:
//
//  - which state Settings ▸ Certificate is in, and which button is the next
//    step (the same "installed AND trusted" rule the core uses to intercept);
//  - whether the launch sheet offers to replace an older CA, and which banner
//    stays in Settings when the user said "Not Now". The 1.0.x shared CA (a
//    trusted root whose key is public) is offered at EVERY launch until it is
//    gone, as C8 decided; an earlier install's own CA is offered once, and
//    "Not Now" to it is remembered. The banner stays until they are all gone;
//  - the sentences the sheet, Settings and Help print, so the three cannot
//    disagree about where the key lives.
//
//  Pure Foundation, no core import: the 1.0.x certificate's fingerprint is a
//  PARAMETER (the caller passes `CertificateAuthority.
//  legacySharedCAFingerprintSHA256`), so a plain `swift test` asserts it all.
//

import Foundation

public enum CertificateAuthorityPresentation {

    // MARK: - Settings ▸ Certificate

    /// Where this install's CA stands. Interception needs BOTH installed and
    /// trusted (the core's `CertHelper.caState()`); anything less relays.
    public enum Status: Equatable, Sendable {
        /// The CA could not be produced (its directory could not be written).
        case unavailable
        case notInstalled
        case installedNotTrusted
        case ready
    }

    public static func status(caAvailable: Bool, installed: Bool, trusted: Bool) -> Status {
        guard caAvailable else { return .unavailable }
        guard installed else { return .notInstalled }
        return trusted ? .ready : .installedNotTrusted
    }

    /// The button that is the next step, by its real title — the one the
    /// diagnosis and Help also name — or nil when there is none.
    public static func nextStep(for status: Status) -> String? {
        switch status {
        case .unavailable, .ready: return nil
        case .notInstalled: return installButton
        case .installedNotTrusted: return trustButton
        }
    }

    /// One line under the buttons: what capture does with HTTPS right now.
    public static func summary(for status: Status) -> String {
        switch status {
        case .unavailable:
            return "ReqRes could not create its certificate on this Mac, so HTTPS is relayed without being read. Quit and reopen ReqRes to try again."
        case .notInstalled:
            return "HTTPS is relayed without being read until the certificate is installed and trusted. Click \(installButton), then \(trustButton)."
        case .installedNotTrusted:
            return "Installed but not trusted yet, so HTTPS is still relayed without being read. Click \(trustButton); macOS asks for your password."
        case .ready:
            return "Installed and trusted: new HTTPS connections are decrypted while capture runs. Connections that were already open stay relayed until the app that opened them reconnects."
        }
    }

    public static let installButton = "Install CA certificate"
    public static let trustButton = "Trust"

    /// Where the key lives and where it goes. The ONE sentence Settings and
    /// Help print (task S4 item 4). True of 1.1.0: the app writes the CA and
    /// its key to its app-group container's `Cert` directory (0700, files
    /// 0600), and the extension receives the material only in the tunnel's
    /// start options, in memory — never over the TCP bus, never to a server.
    public static let custody = "ReqRes created this certificate on your Mac the first time it ran, so it is different on every Mac. Its private key is kept in ReqRes's own container, in files only your user account can open, and is handed to ReqRes's capture extension in memory when capture starts. It is never sent anywhere else."

    /// What to do when stopping for good. Trust outlives the app. Points at
    /// the steps rather than saying "delete “ReqRes CA”": after an upgrade
    /// there can be two of that name (shell step S12).
    public static let removalAdvice = "Trust stays in your keychain after ReqRes quits or is deleted. When you stop using ReqRes, remove this certificate: the ? button at the bottom of Settings ▸ Certificate and Help's “Removing the certificate by hand” say how."

    /// `"AB CD EF …"` — how Keychain Access prints a SHA-256, so the user can
    /// match the row they see there with this one. Anything that is not 64
    /// hex digits is returned unchanged rather than guessed at.
    public static func displayFingerprint(_ hex: String) -> String {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) else { return trimmed }
        var pairs: [String] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            pairs.append(trimmed[index..<next].uppercased())
            index = next
        }
        return pairs.joined(separator: " ")
    }

    /// The same, as two lines of 16 pairs — how the pane lays it out, so a
    /// narrow column never wraps it with two pairs alone on a line.
    public static func displayFingerprintLines(_ hex: String) -> [String] {
        let pairs = displayFingerprint(hex).split(separator: " ").map(String.init)
        guard pairs.count == 32 else { return [displayFingerprint(hex)] }
        return [pairs[0..<16].joined(separator: " "), pairs[16..<32].joined(separator: " ")]
    }

    // MARK: - Older certificates: the launch sheet and the banner

    /// UserDefaults: the lowercase fingerprints of the older certificates
    /// that were present when the user chose "Not Now". The sheet is not
    /// offered again for an earlier install's CA in it; one it has not seen
    /// (a later reset container) is offered. The 1.0.x shared CA is recorded
    /// too but never suppressed — see `shouldOfferAtLaunch`.
    public static let declinedDefaultsKey = "CAMigrationDeclinedFingerprints"

    /// Offer the sheet at launch when an older certificate is present that
    /// the user has not already said "Not Now" to. Never offer for nothing.
    ///
    /// The 1.0.x shared CA is offered at EVERY launch while it is in the
    /// keychain, declined or not (S4 review, restoring C8's choice): it is a
    /// root this Mac trusts for every website whose private key is in every
    /// public 1.0.x download — a hazard, not a preference, and the banner in
    /// Settings ▸ Certificate is a place many users never open. An earlier
    /// install's own CA was never published, so one "Not Now" to it holds.
    public static func shouldOfferAtLaunch(outdated: [String], declined: [String],
                                           legacySharedFingerprint: String) -> Bool {
        let shared = normalized(legacySharedFingerprint)
        let seen = Set(declined.map(normalized)).subtracting([shared])
        return outdated.map(normalized).contains { !$0.isEmpty && !seen.contains($0) }
    }

    /// The declined list after "Not Now": everything declined before, plus
    /// what is outdated now — deduplicated and sorted, so the stored value is
    /// stable.
    public static func declining(outdated: [String], previously declined: [String]) -> [String] {
        Array(Set((declined + outdated).map(normalized)).subtracting([""])).sorted()
    }

    /// What the older certificates are, which decides the wording.
    public enum Outdated: Equatable, Sendable {
        case none
        /// Includes the 1.0.x certificate whose key is public. `count` is all
        /// of them, the shared one included.
        case includesShared(count: Int)
        /// Only earlier installs' own CAs (a reset container regenerates it).
        case earlierInstalls(count: Int)
    }

    public static func outdated(_ fingerprints: [String], legacySharedFingerprint: String) -> Outdated {
        let list = fingerprints.map(normalized).filter { !$0.isEmpty }
        guard !list.isEmpty else { return .none }
        return list.contains(normalized(legacySharedFingerprint))
            ? .includesShared(count: list.count)
            : .earlierInstalls(count: list.count)
    }

    /// The banner Settings ▸ Certificate keeps while any older certificate is
    /// in the keychain — whether or not the sheet was declined. Nil: none.
    public static func banner(for outdated: Outdated) -> String? {
        switch outdated {
        case .none:
            return nil
        case .includesShared(let count):
            return (count == 1
                ? "The old “ReqRes CA” from ReqRes 1.0.x is still in your keychain."
                : "\(count) older “ReqRes CA” certificates are still in your keychain, including the one from ReqRes 1.0.x.")
                + " That one was the same on every Mac and its private key was published with the app. Remove it."
        case .earlierInstalls(let count):
            return (count == 1
                ? "An older “ReqRes CA” from an earlier installation on this Mac is still in your keychain."
                : "\(count) older “ReqRes CA” certificates from earlier installations on this Mac are still in your keychain.")
                + " ReqRes no longer uses it. Remove it."
        }
    }

    // MARK: - The sheet's words

    public static let sheetTitle = "Replace the Old ReqRes Certificate"
    public static let sheetSubtitle = "ReqRes now creates its own certificate authority on every Mac."

    /// Why, in plain words. Nil when there is nothing to replace.
    public static func sheetReason(for outdated: Outdated) -> String? {
        switch outdated {
        case .none:
            return nil
        case .includesShared:
            return "Your keychain still has the “ReqRes CA” that ReqRes 1.0.x installed. That certificate and its private key were the same on every Mac and shipped inside the app, so the key is not a secret — and a certificate your Mac trusts for every website should have one. ReqRes no longer uses it."
        case .earlierInstalls:
            return "Your keychain still has a “ReqRes CA” from an earlier installation of ReqRes on this Mac. ReqRes no longer uses it, and it should not stay trusted."
        }
    }

    /// What the button does, in order. The last step names the restart
    /// because it drops the connections open at that moment.
    public static let sheetSteps = [
        "Remove the old certificate's trust, then the certificate itself.",
        "Install and trust this Mac's own certificate.",
        "Restart capture if it is running, so every app reconnects through the new certificate.",
    ]

    public static let sheetPasswordNote = "macOS asks for your password to change trust, and for an administrator's if the old certificate is trusted for every user of this Mac."

    public static let declineButton = "Not Now"

    /// What "Not Now" leaves behind, said before the user chooses it — and
    /// whether the sheet comes back, which depends on what is being replaced
    /// (`shouldOfferAtLaunch`).
    public static func sheetDeclineNote(for outdated: Outdated) -> String {
        let banner = "Settings ▸ Certificate keeps a \(MCPCaptureEnvironment.replaceOldCertificateButton) button until it is done."
        switch outdated {
        case .includesShared:
            return "Not Now removes nothing. Because the 1.0.x certificate's private key is public, ReqRes asks again at the next launch, and " + banner
        case .earlierInstalls, .none:
            return "Not Now removes nothing, and ReqRes will not ask again at launch for this certificate. " + banner
        }
    }

    /// A password prompt dismissed half-way.
    public static let sheetCancelledNote = "Stopped before it finished — macOS did not get your password. Anything already removed stays removed, and HTTPS is relayed without being read until this Mac's certificate is trusted. Try again here or in Settings ▸ Certificate."

    private static func normalized(_ fingerprint: String) -> String {
        fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
