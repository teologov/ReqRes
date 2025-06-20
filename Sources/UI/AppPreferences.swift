//
//  AppPreferences.swift
//  ReqRes
//
//  Created by OloApps on 3/17/25.
//
//  Copyright © 2025 OloApps. All rights reserved.
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

import AppKit

class AppPreferences {
    static let shared = AppPreferences()
    
    private let defaults = UserDefaults.standard
    private let restartPromptShownKey = "restartPromptShown"
    private let firstVPNConfigInstalledKey = "firstVPNConfigInstalled"
    
    var hasShownRestartPrompt: Bool {
        get { defaults.bool(forKey: restartPromptShownKey) }
        set { defaults.set(newValue, forKey: restartPromptShownKey) }
    }
    
    var isFirstVPNConfigInstalled: Bool {
        get { defaults.bool(forKey: firstVPNConfigInstalledKey) }
        set { defaults.set(newValue, forKey: firstVPNConfigInstalledKey) }
    }
}
