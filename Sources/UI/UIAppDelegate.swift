//
//  UIAppDelegate.swift
//  UI
//
//  Created by OloApps on 14.06.2023.
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
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

import Cocoa
import Sentry
import Utils
import SystemExtensions
import Combine
import XReqResCore

// TODO: add toolbar app with list of rules
// the popup design here looks inpiring: https://blog.eidinger.info/til-swiftui-list-on-macos

class AppDelegate: NSObject, NSApplicationDelegate {
    
    // private lazy var systemExtensionInfo = Bundle.main.systemExtensions.first
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        initSentry()
        // The install's CA: generated once, by the app, into the app group's
        // Cert directory (owner-only). 1.0.x wrote the SHARED constants here
        // (and so did the extension); a Cert directory holding only that
        // shared CA is replaced. The extension never reads these files — it
        // gets the material in the tunnel's start options.
        do {
            let authority = try CertificateAuthority.ensureInstallCA()
            AppLog.shared.debug("ReqRes CA ready, SHA-256 \(authority.fingerprintSHA256, privacy: .public)")
        } catch {
            AppLog.shared.error("Could not prepare the ReqRes CA: \(String(describing: error), privacy: .public)")
        }

        // The capture channel, before anything else touches capture — the
        // update reset below included (F11): the database, the bus the
        // extension delivers to (with `AppController.shared` as its
        // delegate), the tunnel's status notifications, and the tunnel's
        // REAL status, so a capture that outlived the last app shows as on.
        // It used to wait for the main window to appear.
        AppController.shared.openCaptureChannel()
        
        applySavedAppearance() // Apply appearance on app launch

        // The menu bar item ships ON. REGISTERED as a default rather than
        // written, so a user who turns it off keeps it off — the same shape the
        // MCP bridge's own switch uses, and the reason an explicit "no"
        // survives a relaunch.
        UserDefaults.standard.register(defaults: [ReqResStatusItemController.visibilityDefaultsKey: true])
        ReqResStatusItemController.shared.applyVisibilityPreference()
        // A held request is a stopped browser somewhere, so the panel comes to
        // the user rather than waiting to be found. It is non-activating, so
        // it does not steal what they are typing.
        BreakpointService.shared.onFirstPause = {
            BreakpointWindowController.shared.show()
        }
        #if DEBUG
        HelpWindowController.runLayoutProbeIfRequested()
        // `REQRES_LIVE_LOAD_PROBE=1`: ten live streams + ordinary rows through
        // the real ingest path, main-thread time reported (§S6).
        LiveLoadProbe.runIfRequested()
        // `REQRES_SAVED_PROBE=1`: the saved-sessions store lives in the closed
        // core, so its round trip is pinned against the real database here.
        SavedSessionProbe.runIfRequested()
        // `REQRES_BREAKPOINT_SEED=1`: hold one synthetic request so the agent
        // tools can be driven end to end without the extension. It is seeded
        // AFTER the window wiring above, so the panel comes up exactly as it
        // would for a real hit.
        if ProcessInfo.processInfo.environment["REQRES_BREAKPOINT_SEED"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                BreakpointService.shared.seedForProbe()
                print("[breakpoint] seeded \(BreakpointService.shared.pending.map(\.id).joined(separator: ","))")
                fflush(stdout)
            }
        }
        #endif
        // Force reset extension if app was updated via Sparkle
         Task {
            await forceResetExtensionAfterUpdate()
            // Until here a capture that outlived the last app is never
            // restarted by ReqRes itself (build 53): on an update's first
            // launch its extension may be being swapped for this build's.
            await MainActor.run { CaptureDeliveryMonitor.shared.updateResetFinished() }

            // Continue with normal status check
            AppController.shared.checkNetworkExtensionStatus()
         }
    }
    
    // Main function to reset extension after updates
    func forceResetExtensionAfterUpdate() async {
        // Check if version changed (indicating a Sparkle update)
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let lastVersion = UserDefaults.standard.string(forKey: "LastRunVersion") ?? ""
    
        AppLog.shared.info("[UIAppDelegate] currentVersion: \(currentVersion, privacy: .public), lastVersion: \(lastVersion, privacy: .public)")
        // Skip if version hasn't changed
        guard currentVersion != lastVersion else {
            AppLog.shared.info("[UIAppDelegate] App is running the same version. Returning.")
            return
        }

        // FIRST EVER LAUNCH: there is no previous version, so there is nothing to
        // reset. Running the reset here fights the user's
        // fresh approval — it tries to tear down an extension that was just
        // installed (or never existed) and leaves the app looking broken until a
        // relaunch. Record the version and let normal setup proceed.
        guard !lastVersion.isEmpty else {
            AppLog.shared.info("[UIAppDelegate] First launch — skipping extension reset.")
            UserDefaults.standard.set(currentVersion, forKey: "LastRunVersion")
            return
        }
        
        AppLog.shared.info("[UIAppDelegate] App updated from \(lastVersion, privacy: .public) to \(currentVersion), forcing extension reset")
        
        // Activate the new build's extension. macOS asks the request's
        // delegate what to do with the older one already installed, and every
        // delegate here answers `.replace`, so the old binary is swapped out
        // without a reboot — measured 2026-09-29: 1.1.0 (8) → (9) in 2 s.
        //
        // Until 1.1.0 this first DEACTIVATED the old extension. Removing a
        // system extension needs an administrator's authorization, so every
        // update put up a password dialog with no ReqRes context, and
        // capture setup waited behind it (live-run finding F8); its own
        // comment recorded that users declined it and the flow went on
        // anyway. A version that does not outrank the installed one is not
        // replaced by either path — `Scripts/extension-version-check.sh`
        // guards that.
        do {
            AppLog.shared.info("[UIAppDelegate] Activating extension \(extensionBundleId, privacy: .public)")
            
            try await withCheckedThrowingContinuation { continuation in
                OSSystemExtensionManager.shared.activateExtensionWithIdentifier(extensionBundleId, approval: { needsApproval in
                    if needsApproval {
                        AppLog.shared.info("[UIAppDelegate] Extension activation requires user approval")
                    }
                })
                .sink(
                    receiveCompletion: { completion in
                        switch completion {
                        case .finished:
                            AppLog.shared.info("[UIAppDelegate] Extension activation completed successfully")
                            continuation.resume()
                        case .failure(let error):
                            AppLog.shared.error("[UIAppDelegate] Extension activation failed: \(error.localizedDescription, privacy: .public)")
                            continuation.resume(throwing: error)
                        }
                    },
                    receiveValue: { _ in }
                )
                .store(in: &cancellables)
            }
            
            // Store current version to ensure we only try once per version
            UserDefaults.standard.set(currentVersion, forKey: "LastRunVersion")
            
            AppLog.shared.info("[UIAppDelegate] Extension reset sequence completed successfully")
        } catch {
            AppLog.shared.error("[UIAppDelegate] Error during extension reset: \(error.localizedDescription)")
        }
    }

    /// Confirms a quit that would stop capture, and — unlike the version this
    /// replaces — actually quits when the user says so.
    ///
    /// 🚨 The old shape could not terminate at all while capturing. It showed
    /// the alert and returned `.terminateCancel`, and the alert's Quit button
    /// called `NSApp.terminate(nil)` from INSIDE this method. That re-enters
    /// `applicationShouldTerminate` with the tunnel still running — nothing had
    /// stopped it — so the same alert was presented again, nested. Each Quit
    /// click nested another; only Cancel unwound. ⌘Q while capturing never
    /// quit the app, and the behaviour is in every shipped 1.0.x.
    ///
    /// Now the answer is given ONCE: stop the tunnel first, then return
    /// `.terminateNow`, so there is no second pass and nothing to re-enter.
    /// The confirmation stays — quitting silently kills capture the user may
    /// have deliberately left running — and it is also why the menu bar's Quit
    /// row says "(stops capture)": the consequence belongs before the click.
    ///
    /// The copy of ReqRes that holds the message bus asks and stops (F11):
    /// the extension delivers to it, so its capture is the one being quit. A
    /// second copy — a Debug build beside the installed app — quits without
    /// touching the capture the first one holds. A copy without the bus and
    /// no other copy running asks and stops too: that capture reaches nobody.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard quitStopsCapture() else { return .terminateNow }
        guard confirmQuitWhileCapturing() else { return .terminateCancel }
        // Stop it here rather than leaving it to applicationWillTerminate, so
        // the tunnel is already on its way down for any later pass.
        stopVPNTunnelIfRunning()
        return .terminateNow
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        stopVPNTunnelIfRunning()
        AppController.tcpServerBus.stop()
        AppLog.shared.debug("TCPServerBus: server stopped successfully.")
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
    
    func applySavedAppearance() {
        #if DEBUG
        // Screenshot mode drives the appearance from the environment so light
        // and dark captures can be produced without touching the stored
        // preference, which is shared with an installed copy of ReqRes.
        if let forced = ProcessInfo.processInfo.environment["REQRES_TOOLBAR_APPEARANCE"],
           let mode = AppearanceMode(rawValue: forced.capitalized) {
            applyAppearanceMode(mode)
            return
        }
        #endif
        let savedAppearance = UserDefaults.standard.string(forKey: "selectedAppearance") ?? "System"
        if let mode = AppearanceMode(rawValue: savedAppearance) {
            applyAppearanceMode(mode)
        }
    }
    
    func applyAppearanceMode(_ mode: AppearanceMode) {
        switch mode {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil // Resets to the system's appearance
        }
    }
}

extension AppDelegate {
    func stopVPNTunnelIfRunning() {
        if quitStopsCapture() {
            VPNManager.shared.stopVPNTunnel()
        }
    }
    
    /// Anything that is not plainly off, unless another copy of ReqRes holds
    /// the capture (`CaptureControl.stopsCaptureOnQuit`, Utils).
    ///
    /// This asked only about `.connected`, so quitting mid-connect skipped the
    /// confirmation AND skipped stopping the tunnel — leaving a half-built
    /// tunnel behind with the app gone, which is the shape that wedges the
    /// extension. `.reasserting` had the same hole.
    ///
    /// It read the app's DISPLAY, which after a relaunch said "off" while the
    /// tunnel ran (F11) — so the quit neither asked nor stopped. The tunnel's
    /// own status is read now, once the configuration is loaded (at launch).
    private func quitStopsCapture() -> Bool {
        let status = VPNManager.shared.manager?.connection.status ?? AppState.shared.vpnStatus
        let holdsBus = AppController.tcpServerBus.isServerListening()
        return CaptureControl.stopsCaptureOnQuit(real: CaptureTunnelState(status),
                                                 holdsBus: holdsBus,
                                                 // Asked only when it decides something.
                                                 anotherCopyRunning: !holdsBus && CaptureDeliveryMonitor.anotherCopyRunning())
    }
    
    /// True when the user confirmed. It does NOT terminate anything itself —
    /// calling `NSApp.terminate` from inside the terminate handler is exactly
    /// what made this unquittable.
    private func confirmQuitWhileCapturing() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit ReqRes and stop capturing?"
        // Says what is lost, which the old copy ("Are you sure you want to
        // quit?") did not: capture ends with the app, and captured traffic
        // lives in memory unless it was saved.
        alert.informativeText = "Capturing stops when ReqRes quits, and captured traffic that you have not saved is discarded. Closing the window instead leaves capture running."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit and Stop")
        alert.addButton(withTitle: "Cancel")
        // Escape and ⌘. cancel; Return still hits the first button, which is
        // standard for a quit confirmation the user themselves asked for.
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
    
    /// Starts crash reporting, unless the user has turned it off.
    ///
    /// It used to start unconditionally, with no consent, no toggle and no
    /// mention in Settings or Help — in a product whose pitch is an auditable
    /// open shell that handles your traffic. The flag lives in the APP GROUP,
    /// not in standard defaults, because the extension is a separate root
    /// process that reads it at `startTunnel` before the message bus exists;
    /// a standard-suite write would leave reporting on in the root process
    /// while this window said off.
    ///
    /// Unset means ON, so nothing changes for an existing install until
    /// somebody actually opts out.
    func initSentry() {
        let defaults = TelemetryConsent.groupDefaults(appGroupID: AppGroup.identifier)
        // A nil group is an entitlement failure, not consent — fail toward the
        // shipped behaviour rather than silently disabling crash reports.
        if let defaults, !TelemetryConsent.isEnabled(in: defaults) {
            AppLog.shared.info("[Sentry] crash reporting is off by user preference")
            return
        }
        SentrySDK.start { options in
            options.dsn = "https://\(EnvironmentVars.sentryDsn)"
            // 0.1, matching the extension. 1.0 was a development value with a
            // comment asking for exactly this drop since 1.0.x — it sent a
            // trace for every transaction of every user.
            //
            // `tracesSampleRate` is `NSNumber?`: a bare `0.1` literal bridges,
            // a `Double` constant does not.
            options.tracesSampleRate = NSNumber(value: TelemetryConsent.sampleRate)
            // Captured traffic must never reach a crash report. The Settings
            // copy says request and response bodies are never included, and
            // these are what make that enforced rather than asserted: Sentry's
            // network breadcrumbs record the URLs an app requests, and this app
            // is a proxy — its "own" requests are the user's traffic.
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
        }
    }
}
