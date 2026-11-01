//
//  CheckForUpdatesView.swift
//  ReqRes
//
//  Created by OloApps on 3/10/25.
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

import SwiftUI
import Sparkle
import XReqResCore

class SparkleViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// The ONE updater in the process.
    ///
    /// It used to be a `@StateObject` private to `MainMenu`, so anything else
    /// that wanted update state — Settings → General now does — would have
    /// constructed a second `SPUStandardUpdaterController` and put two live
    /// updaters in the app. That exact defect was fixed once already in
    /// `9eb8104`; a singleton is what stops it coming back a third time.
    static let shared = SparkleViewModel()

    private var updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = true
    /// Sparkle's OWN record, not a copy.
    ///
    /// This used to be a `@Published` set only by the delegate callback, so it
    /// reset to nil on every launch and Settings said "Never" however many
    /// times the app had actually checked. The delegate now only pokes
    /// `objectWillChange`; the value comes from the updater, which persists it.
    var lastUpdateCheckDate: Date? { updaterController.updater.lastUpdateCheckDate }

    /// Sparkle's own silent background schedule. Bound by Settings → General.
    ///
    /// Reading and writing goes through `SPUUpdater`, which stores it in user
    /// defaults — and `SUHost` reads user defaults BEFORE the Info.plist, so
    /// the toggle works with `SUEnableAutomaticChecks` still in the plist
    /// (verified in Sparkle 2.9.6's source, `SUHost.m`). The plist key must
    /// stay: it is what suppresses the second-launch permission prompt, and
    /// removing it would show that prompt to every existing 1.0.x user on the
    /// first launch after updating.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updaterController.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updaterController.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    private override init() {
        // Create the updater controller directly in the view model
        // This eliminates the need for AppDelegate code related to Sparkle
        // (not started: this placeholder only exists so `self` is available
        // for the real, delegate-carrying controller below)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil, // We'll set this after initialization
            userDriverDelegate: nil
        )

        super.init()
        
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        
        // NO 24-hour timer here any more.
        //
        // It called `checkForUpdates()` — Sparkle's USER-INITIATED check, which
        // its own documentation describes as displaying a progress dialog and
        // being meant for a menu item. So a tool people leave running for days
        // while capturing raised an unrequested modal once per day of uptime,
        // on top of Sparkle's own silent background schedule, which was already
        // running. It was also never invalidated.
        //
        // Sparkle schedules background checks itself from
        // `automaticallyChecksForUpdates`; Settings → General now exposes that,
        // and the menu command remains for checking on purpose.
    }
    
    func checkForUpdates() {
        canCheckForUpdates = false
        updaterController.checkForUpdates(nil)
        
        // Re-enable update checking after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.canCheckForUpdates = true
        }
    }
    
    // MARK: - SPUUpdaterDelegate Methods
    
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        DispatchQueue.main.async { [weak self] in
            // Sparkle has just recorded its own date; this only tells SwiftUI
            // to re-read it. Assigning a Date here was the bug — the value
            // lived in memory and reset to nil every launch.
            self?.objectWillChange.send()
        }

        if let error = error {
            AppLog.shared.error("Error checking for updates: \(error.localizedDescription, privacy: .public)")
        } else {
            AppLog.shared.debug("Update check completed without errors.")
        }
    }
}
