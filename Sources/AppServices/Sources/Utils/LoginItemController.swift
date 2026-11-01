//
//  LoginItemController.swift
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
//  "Open ReqRes at login" — the APP, and only the app.
//
//  🚨 This setting must never be allowed to imply that CAPTURE starts at
//  login, in this code, in the Settings row built on it, or in any string it
//  vends. A Mac that silently began decrypting every TLS connection at login
//  would break its owner's own work: capture MITMs `codesign`'s secure-timestamp
//  request to Apple and re-signs the answer with the ReqRes CA, which codesign
//  correctly refuses — surfacing as "A timestamp was expected but was not
//  found" naming some unrelated framework, with nothing pointing at the proxy.
//  That cost four failed builds in one day (2026-09-06) when it was a thing the
//  user had deliberately switched on and could remember switching on. Starting
//  it unasked, at every login, would be that failure with no such memory.
//  Capture stays a separate, deliberate action; the exclusion list
//  (`ExcludedHostList`) is the mitigation for when it IS running.
//
//  Why this exists now and not before: a login item that opens a window the
//  user did not ask for is an annoyance, not a feature. It earns its place
//  because the app has a menu bar status item — ReqRes can now be present
//  without being in the way.
//
//  The Network Extension is NOT affected by any of this. It is registered with
//  the system on its own terms, runs as its own root process, and is neither
//  started nor stopped by this login item. Unregistering here stops the app
//  opening at login; it does not uninstall or disable the extension.
//
//  ServiceManagement, not a LaunchAgent plist: the app is sandboxed, so writing
//  to ~/Library/LaunchAgents is not available, and `SMAppService.mainApp` is
//  the only supported route. macOS 13+, which is under this app's 14.6 floor,
//  so no availability gate is needed.
//

import Foundation
import ServiceManagement

// MARK: - State

/// What the user is looking at: on, off, or waiting for their approval.
///
/// The third one is the case that matters and the one an `isEnabled` boolean
/// cannot express. `register()` succeeding does NOT mean the app will open at
/// login: macOS may park the request in System Settings until the user allows
/// it, and it returns to this state whenever they revoke consent there. It is
/// neither "on" nor a failure, and a UI that renders it as either one lies —
/// as "on" it promises something that will not happen, as "off" it invites the
/// user to flip a switch that is already flipped.
public enum LoginItemState: Equatable, Sendable, CaseIterable {
    /// Not registered — ReqRes will not open at login.
    case off

    /// Registered and approved.
    case on

    /// Registered, but macOS is waiting for the user to allow it in
    /// System Settings ▸ General ▸ Login Items.
    case requiresApproval

    /// The one mapping, deliberate case by case.
    ///
    /// `.notFound` maps to `off`, not to an error state: for the main app it
    /// means the system has no such registration to report on, and the honest
    /// thing to tell the user is that ReqRes will not open at login — which is
    /// true, and which the toggle can act on. Anything the SDK adds later maps
    /// to `off` as well: never claim a feature is on when we cannot tell.
    public init(status: SMAppService.Status) {
        switch status {
        case .enabled:
            self = .on
        case .requiresApproval:
            self = .requiresApproval
        case .notRegistered:
            self = .off
        case .notFound:
            self = .off
        @unknown default:
            // The compile-time tripwire: a status case added by a future SDK
            // makes this switch warn that it is not handled explicitly. Swift
            // cannot enumerate an imported C enum, so that warning — not a
            // test — is what surfaces a new case. See the tests for the half
            // of the guard that CAN be automated.
            self = .off
        }
    }

    /// True only when the app really will open at login. `requiresApproval` is
    /// deliberately false here.
    public var isOn: Bool { self == .on }

    /// The Settings row's secondary line.
    ///
    /// Every one of these says what happens to the APP. The `on` line says out
    /// loud what does NOT happen, because that is the sentence a user reads
    /// once and relies on for the life of the install.
    public var summary: String {
        switch self {
        case .on:
            return "ReqRes opens when you log in. Capture stays off until you start it."
        case .off:
            return "ReqRes does not open when you log in."
        case .requiresApproval:
            return "Waiting for your approval in System Settings ▸ General ▸ Login Items. "
                + "ReqRes will not open at login until you allow it there."
        }
    }

    /// The button the row shows beside the summary, or nil when there is
    /// nothing for the user to go and do.
    public var settingsButtonTitle: String? {
        self == .requiresApproval ? LoginItemController.openSettingsButtonTitle : nil
    }
}

// MARK: - Failures

/// Why `setEnabled` did not do what was asked.
///
/// Registration is a request to the system, not a local write, and it can be
/// refused. `deniedByUser` is the one worth distinguishing: the user (or a
/// previous answer of theirs) said no, nothing the app does will change that,
/// and the only useful response is to send them to Login Items. Failing
/// silently there leaves a toggle that springs back with no explanation.
public enum LoginItemError: LocalizedError, Equatable {
    /// `kSMErrorLaunchDeniedByUser` — macOS is refusing on the user's behalf.
    case deniedByUser

    /// `kSMErrorInvalidSignature` — the bundle is not signed in a way the
    /// system will launch. Expected on unsigned local builds; a shipping build
    /// that reports this is a signing regression.
    case notSigned

    /// Anything else, carried verbatim rather than flattened into one string:
    /// the code is what makes a bug report actionable.
    case failed(code: Int, message: String)

    /// Classifies an error thrown by `register()` / `unregister()`.
    ///
    /// Returns nil when the system was ALREADY in the state that was asked
    /// for — `kSMErrorAlreadyRegistered` from a register, `kSMErrorJobNotFound`
    /// from an unregister. Those are not failures from where the user stands;
    /// they asked for a state and that is the state. Reported the other way
    /// round they ARE failures, and are passed through: an unregister that
    /// comes back "already registered" means something is wrong.
    ///
    /// Matched on the error code only. `SMAppServiceErrorDomain` is marked
    /// `API_AVAILABLE(macos(15.0))` in the SDK while this ships to 14.6, so
    /// the symbol is not available on the floor it would be describing — and
    /// these errors only ever arrive here from `SMAppService`.
    public static func classify(_ error: Error, requesting enabled: Bool) -> LoginItemError? {
        let nsError = error as NSError
        switch nsError.code {
        case kSMErrorLaunchDeniedByUser:
            return .deniedByUser
        case kSMErrorAlreadyRegistered where enabled:
            return nil
        case kSMErrorJobNotFound where !enabled:
            return nil
        case kSMErrorInvalidSignature:
            return .notSigned
        default:
            return .failed(code: nsError.code, message: nsError.localizedDescription)
        }
    }

    /// True when the useful next step is the Login Items pane rather than a
    /// retry. The Settings row offers a button on this, so a denial is never
    /// just a toggle that snapped back.
    public var suggestsOpeningLoginItems: Bool { self == .deniedByUser }

    public var errorDescription: String? {
        switch self {
        case .deniedByUser:
            return "macOS is not allowing ReqRes to open at login."
        case .notSigned:
            return "This build of ReqRes is not signed in a way macOS will open at login."
        case .failed(let code, let message):
            return "ReqRes could not change the open-at-login setting. \(message) (\(code))"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .deniedByUser:
            return "Allow ReqRes in System Settings ▸ General ▸ Login Items, then try again."
        case .notSigned:
            return "Use a signed copy of ReqRes from /Applications."
        case .failed:
            return nil
        }
    }
}

// MARK: - Controller

/// Reads and writes the "open ReqRes at login" registration.
///
/// A controller, not a view: no AppKit, no SwiftUI. Opening System Settings
/// goes through ServiceManagement's own `openSystemSettingsLoginItems()`
/// rather than this repo's `NSWorkspace.open(x-apple.systempreferences:…)`
/// pattern (`ReqResToolbarSlots.openSystemSettings`) — it lands on the Login
/// Items list specifically, needs no AppKit here, and does not have to track
/// the pane identifier across macOS versions, which the URL form already
/// needed an `#available` fork for.
///
/// The `SMAppService` calls are injected so the surrounding decisions can be
/// tested. The defaults are the real thing and are not exercised by the test
/// suite — registering with the system is not a unit test.
public struct LoginItemController: Sendable {
    public static let shared = LoginItemController()

    /// The Settings row's label. Says "open", never "start" or "capture".
    public static let toggleTitle = "Open ReqRes at login"

    /// The sentence that must survive every future edit of this screen.
    public static let captureDisclaimer =
        "Opening at login does not start capture — ReqRes waits for you to start it."

    public static let openSettingsButtonTitle = "Open Login Items"

    private let readStatus: @Sendable () -> SMAppService.Status
    private let registerService: @Sendable () throws -> Void
    private let unregisterService: @Sendable () throws -> Void
    private let openSettings: @Sendable () -> Void

    public init(
        readStatus: @escaping @Sendable () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping @Sendable () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping @Sendable () throws -> Void = { try SMAppService.mainApp.unregister() },
        openLoginItemsSettings: @escaping @Sendable () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.readStatus = readStatus
        self.registerService = register
        self.unregisterService = unregister
        self.openSettings = openLoginItemsSettings
    }

    /// Read every time it is asked for. The user can change this in System
    /// Settings while the app is running, so a cached value goes stale the
    /// moment it matters.
    public var state: LoginItemState { LoginItemState(status: readStatus()) }

    /// The toggle's value. False while approval is pending — the app is not
    /// going to open at login yet, and `state` is what says why.
    public var isEnabled: Bool { state.isOn }

    /// Registers or unregisters the app as a login item.
    ///
    /// Success here does NOT mean `isEnabled` is now true: macOS may answer
    /// with `requiresApproval`, so the caller re-reads `state` afterwards
    /// rather than assuming what it asked for.
    public func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try registerService()
            } else {
                try unregisterService()
            }
        } catch {
            guard let failure = LoginItemError.classify(error, requesting: enabled) else {
                // Already in the requested state; the user got what they asked
                // for and there is nothing to report.
                return
            }
            throw failure
        }
    }

    /// Opens System Settings at the Login Items pane, where a pending approval
    /// or an earlier denial is resolved.
    public func openLoginItemsSettings() {
        openSettings()
    }
}
