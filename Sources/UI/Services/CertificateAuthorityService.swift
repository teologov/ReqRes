//
//  CertificateAuthorityService.swift
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
//  The app's side of the per-install CA (protocol PRD §1.11, 4 Phase 2.1,
//  core step C8). The core generates the CA and decides what counts as
//  installed; this file does the three things only the app can:
//
//  1. Tells a RUNNING extension when the CA's state changes
//     (`ServerBusAction.caStateChanged`). The extension used to learn it only
//     in the tunnel's start options, so installing or trusting the CA
//     mid-capture changed nothing until capture restarted. Pushed on every
//     install, trust and removal AND on every status update — the extension
//     starts from its start options each time the tunnel does, the same
//     reasoning as `ExcludedHostsSettings.push()`.
//  2. Replaces an OLDER "ReqRes CA" in the keychain: the one every 1.0.x
//     install shared (its private key was in every public download — while it
//     stays trusted, anyone holding it who can intercept this Mac's traffic
//     could impersonate any website to it), or an earlier install's (a reset group container regenerates the
//     CA and leaves the old one behind). The core finds them by fingerprint;
//     this removes their trust and the keychain item, then installs and
//     trusts this install's CA.
//  3. Offers that replacement at launch, as a sheet on the main window. The
//     1.0.x shared CA is offered at every launch until it is gone (its key is
//     public); an earlier install's CA once — "Not Now" records its
//     fingerprint (`CertificateAuthorityPresentation.declinedDefaultsKey`).
//     Settings ▸ Certificate keeps the same button as a banner until every
//     older one is gone. Nothing is removed without the user's click.
//  4. Holds the state Settings ▸ Certificate renders (this install's CA:
//     fingerprint, installed, trusted; the older ones), refreshed off main,
//     so the pane and the probe draw the same thing (shell step S4).
//

import AppKit
import Foundation
import NetworkExtension
import MCPKit
import Security
import Utils
import XReqResCore

enum CAStateSync {
    /// The last state sent, so a push on app activation can be skipped when
    /// nothing changed. A status update ALWAYS pushes: the extension starts
    /// from its start options every time the tunnel does and does not know
    /// what was pushed to the previous run.
    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var last: CAStatePayload?
        /// Records `state` and says whether it should be sent.
        func record(_ state: CAStatePayload, onlyIfChanged: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let changed = last != state
            last = state
            return changed || !onlyIfChanged
        }
    }
    private static let memory = Memory()

    /// ONE serial queue for every push (S4 review): each push reads the state
    /// when it runs and sends it before the next one starts, so pushes reach
    /// the bus in the order they were asked for and the last one sent is the
    /// freshest. With one detached task per push, two overlapping pushes
    /// (Trust and an app activation, say) could send in reverse order and
    /// leave the extension relaying on a stale "not trusted" until the next
    /// change.
    private static let queue = DispatchQueue(label: "com.oloapps.ReqRes.CAStateSync", qos: .utility)

    /// Sends the CA's current state to the extension. Safe with no tunnel
    /// running — the bus drops it and the next status update sends it again.
    /// Off main: the keychain lookup and the trust evaluation are not free.
    /// `onlyIfChanged`: for the app becoming active, which is when a
    /// certificate deleted or untrusted in Keychain Access is noticed.
    static func push(onlyIfChanged: Bool = false) {
        queue.async {
            let state = CertHelper.caState()
            guard memory.record(state, onlyIfChanged: onlyIfChanged) else { return }
            AppController.shared.notifyExtension(
                message: ServerBusMessage(action: .caStateChanged, payload: ["data": state])
            )
            AppLog.shared.debug("[CAStateSync] pushed CA state: intercept=\(state.installed, privacy: .public)")
        }
    }
}

@MainActor
final class CertificateAuthorityService: ObservableObject {
    static let shared = CertificateAuthorityService()

    typealias Presentation = CertificateAuthorityPresentation

    /// This install's CA — nil until the first refresh, or when it could not
    /// be produced (`caUnavailable`).
    @Published private(set) var fingerprint: String?
    @Published private(set) var certificateDER: Data?
    @Published private(set) var caUnavailable = false
    /// This install's CA is in the keychain / macOS trusts it.
    @Published private(set) var installed = false
    @Published private(set) var trusted = false
    /// Fingerprints of the "ReqRes CA" certificates in the keychain that are
    /// not this install's (the 1.0.x shared one, or an earlier install's).
    @Published private(set) var outdatedFingerprints: [String] = []
    /// The launch offer. Presented by `AppView` once no other sheet is up.
    @Published var migrationOffered = false
    @Published private(set) var isReplacing = false

    var outdatedCount: Int { outdatedFingerprints.count }

    var status: Presentation.Status {
        Presentation.status(caAvailable: !caUnavailable, installed: installed, trusted: trusted)
    }

    var outdated: Presentation.Outdated {
        Presentation.outdated(outdatedFingerprints,
                              legacySharedFingerprint: CertificateAuthority.legacySharedCAFingerprintSHA256)
    }

    /// This install's CA as a `SecCertificate`, for the details panel.
    var certificate: SecCertificate? {
        certificateDER.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    #if DEBUG
    /// Set by the layout probe: the pane draws a seeded state and nothing
    /// reads the keychain over it.
    private var seededForProbe = false
    #endif

    private var activationObserver: NSObjectProtocol?

    /// Refreshes overlap (the pane's `.task`, every action, every app
    /// activation) and each reads the keychain off main, so they can finish
    /// out of order. A result older than one already applied is dropped
    /// (S4 review). Not "drop anything but the newest": a caller awaiting an
    /// older refresh still finds state at least that fresh.
    private var refreshGeneration = 0
    private var appliedRefreshGeneration = 0

    private init() {
        // A certificate deleted or untrusted in Keychain Access is noticed
        // when the user comes back: the pane and the banner re-read, and a
        // running extension hears it (task S4 item 2: "installed, trusted OR
        // REMOVED").
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let service = CertificateAuthorityService.shared
                #if DEBUG
                if service.seededForProbe { return }
                #endif
                await service.refresh()
                CAStateSync.push(onlyIfChanged: true)
            }
        }
    }

    private struct Snapshot: Sendable {
        var fingerprint: String?
        var der: Data?
        var installed: Bool
        var trusted: Bool
        var outdated: [String]
    }

    /// Re-reads everything, off main.
    func refresh() async {
        #if DEBUG
        if seededForProbe { return }
        #endif
        refreshGeneration += 1
        let generation = refreshGeneration
        let snapshot = await Task.detached(priority: .utility) { () -> Snapshot in
            let authority = try? CertificateAuthority.ensureInstallCA()
            let installed = authority != nil && CertHelper.getInstalledCertificate() != nil
            let trusted = installed && authority
                .flatMap { SecCertificateCreateWithData(nil, $0.certificateDER as CFData) }
                .map(CertHelper.isTrusted) == true
            return Snapshot(
                fingerprint: authority?.fingerprintSHA256,
                der: authority?.certificateDER,
                installed: installed,
                trusted: trusted,
                outdated: CertHelper.outdatedInstalledCertificates().map(CertHelper.fingerprintSHA256(of:))
            )
        }.value
        guard generation > appliedRefreshGeneration else { return }
        appliedRefreshGeneration = generation
        fingerprint = snapshot.fingerprint
        certificateDER = snapshot.der
        caUnavailable = snapshot.fingerprint == nil
        installed = snapshot.installed
        trusted = snapshot.trusted
        outdatedFingerprints = snapshot.outdated
    }

    /// At launch: offer the replacement when an older certificate is there
    /// that the user has not already answered "Not Now" to.
    func offerAtLaunch() async {
        #if DEBUG
        if ScreenshotMocks.isEnabled || seededForProbe { return }
        #endif
        await refresh()
        let declined = UserDefaults.standard.stringArray(forKey: Presentation.declinedDefaultsKey) ?? []
        if Presentation.shouldOfferAtLaunch(
            outdated: outdatedFingerprints, declined: declined,
            legacySharedFingerprint: CertificateAuthority.legacySharedCAFingerprintSHA256
        ) {
            migrationOffered = true
        }
    }

    /// "Not Now": the old certificates stay, and Settings ▸ Certificate keeps
    /// its banner. The sheet is not offered again for an earlier install's
    /// CA; the 1.0.x shared one is asked about again next launch.
    func declineOffer() {
        let defaults = UserDefaults.standard
        let declined = defaults.stringArray(forKey: Presentation.declinedDefaultsKey) ?? []
        defaults.set(Presentation.declining(outdated: outdatedFingerprints, previously: declined),
                     forKey: Presentation.declinedDefaultsKey)
        migrationOffered = false
    }

    enum Outcome: Equatable {
        case done
        /// The user dismissed a password prompt. Whatever was removed before
        /// it stays removed; nothing is left trusted that should not be.
        case cancelled
        case failed(String)
    }

    /// Removes every outdated "ReqRes CA" (trust first, then the keychain
    /// item), installs and trusts this install's CA, tells the extension, and
    /// restarts capture if it is running. macOS asks for the user's password
    /// for each trust change, on this thread — the same as the Trust button.
    func replaceOutdated() async -> Outcome {
        guard !isReplacing else { return .cancelled }
        isReplacing = true
        defer { isReplacing = false }
        // Let the spinner and the disabled buttons draw before the
        // synchronous keychain work and macOS's password prompts (S4 review).
        await Task.yield()

        let outcome = performReplacement()
        await refresh()
        CAStateSync.push()
        if outcome == .done {
            Self.restartCaptureIfRunning()
        }
        return outcome
    }

    private func performReplacement() -> Outcome {
        for certificate in CertHelper.outdatedInstalledCertificates() {
            if let failure = Self.removeTrustAndItem(certificate) { return failure }
        }
        guard let authority = try? CertificateAuthority.ensureInstallCA(),
              let current = SecCertificateCreateWithData(nil, authority.certificateDER as CFData) else {
            return .failed("ReqRes could not prepare this Mac's certificate. Quit and reopen ReqRes, then try again.")
        }
        // Only what is missing: a CA already installed and trusted (the user
        // clicked Install and Trust before replacing) asks for no password.
        if CertHelper.getInstalledCertificate() == nil {
            let added = Self.install(current)
            guard added == errSecSuccess || added == errSecDuplicateItem else {
                return .failed("Could not add the certificate to the keychain (\(Self.describe(added))).")
            }
        }
        if !CertHelper.isTrusted(current) {
            let trustedStatus = Self.trust(current)
            if trustedStatus == errAuthorizationCanceled { return .cancelled }
            guard trustedStatus == errSecSuccess else {
                return .failed("Could not trust the certificate (\(Self.describe(trustedStatus))).")
            }
        }
        return .done
    }

    // MARK: - The Certificate pane's buttons

    /// Install: adds this install's CA to the login keychain. Not trusted yet,
    /// so the extension keeps relaying — but it hears the state now.
    func installCurrent() async -> Outcome {
        if certificate == nil { await refresh() }
        guard let current = certificate else {
            return .failed("ReqRes could not prepare this Mac's certificate. Quit and reopen ReqRes, then try again.")
        }
        let status = Self.install(current)
        await refresh()
        CAStateSync.push()
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            return .failed(Self.describe(status))
        }
        return .done
    }

    /// Trust. A running extension intercepts NEW connections as soon as it
    /// hears the state (`caStateChanged`) — no capture restart (task S4 item
    /// 2). Connections already open stay relayed until their app reconnects.
    func trustCurrent() async -> Outcome {
        if certificate == nil { await refresh() }
        guard let current = certificate else {
            return .failed("ReqRes could not prepare this Mac's certificate. Quit and reopen ReqRes, then try again.")
        }
        let status = Self.trust(current)
        await refresh()
        CAStateSync.push()
        if status == errAuthorizationCanceled { return .cancelled }
        guard status == errSecSuccess else { return .failed(Self.describe(status)) }
        return .done
    }

    // MARK: - Keychain

    /// Trust first: a certificate deleted from the keychain but still
    /// carrying trust settings stays trusted when a server presents it.
    private static func removeTrustAndItem(_ certificate: SecCertificate) -> Outcome? {
        let user = SecTrustSettingsRemoveTrustSettings(certificate, .user)
        if user == errAuthorizationCanceled { return .cancelled }
        guard user == errSecSuccess || user == errSecItemNotFound else {
            return .failed("Could not remove the old certificate's trust (\(describe(user))).")
        }
        // Trusted for the whole Mac as well (Keychain Access in the System
        // keychain): that needs an administrator, and macOS asks.
        if CertHelper.isTrusted(certificate) {
            let admin = SecTrustSettingsRemoveTrustSettings(certificate, .admin)
            if admin == errAuthorizationCanceled { return .cancelled }
            if CertHelper.isTrusted(certificate) {
                return .failed("The old certificate is still trusted for every user of this Mac. Open Keychain Access, find “ReqRes CA” in the System keychain and delete the one whose SHA-256 is not the one shown in Settings ▸ Certificate.")
            }
        }
        let deleted = SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ] as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            // Untrusted already, so what is left is harmless — but say so.
            return .failed("The old certificate is no longer trusted, but it could not be deleted (\(describe(deleted))). Delete “ReqRes CA” with the other SHA-256 in Keychain Access.")
        }
        return nil
    }

    /// Adds the certificate to the login keychain (not yet trusted).
    static func install(_ certificate: SecCertificate) -> OSStatus {
        SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ] as CFDictionary, nil)
    }

    /// Trusts it for X.509 and SSL in the user's domain. macOS confirms.
    static func trust(_ certificate: SecCertificate) -> OSStatus {
        SecTrustSettingsSetTrustSettings(certificate, .user, [
            [kSecTrustSettingsPolicy: SecPolicyCreateBasicX509()],
            [kSecTrustSettingsPolicy: SecPolicyCreateSSL(true, nil)],
        ] as CFTypeRef)
    }

    static func describe(_ status: OSStatus) -> String {
        "\(status): " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error")
    }

    /// After a REPLACEMENT only: the old CA was trusted and in use by
    /// nothing, but connections relayed while the new one was untrusted keep
    /// that shape until they close — a restart makes every app reconnect.
    /// Also Settings ▸ Capture's Restart Capture, for a new port.
    ///
    /// The one restart the app has (`AppController.restartCapture`, which the
    /// traffic pane's Restart Capture uses too — F11): only a running tunnel,
    /// waited down before it is started again, and started EXPLICITLY — the
    /// toggle this used to call decided from the display, which can still
    /// read "connected" while the tunnel is already down.
    static func restartCaptureIfRunning() {
        AppController.shared.restartCapture()
    }

    #if DEBUG
    /// The layout probe's state. Reads nothing, writes nothing.
    func seedForProbe(installed: Bool, trusted: Bool, outdated: [String]) {
        seededForProbe = true
        // This install's real CA when it can be read (app launch has already
        // run `ensureInstallCA`, so this reads files it made and writes
        // nothing), so the S12 sheet shows details read from a certificate;
        // the keychain is still never read. A made-up fingerprint otherwise.
        let authority = try? CertificateAuthority.ensureInstallCA()
        fingerprint = authority?.fingerprintSHA256 ?? "3f2a9c41d07e5b88a1c6e2f904b7d35a6c19e8f2b04d7a3c5e81f6092ab4c7d1"
        certificateDER = authority?.certificateDER
        caUnavailable = false
        self.installed = installed
        self.trusted = trusted
        outdatedFingerprints = outdated
    }
    #endif
}
