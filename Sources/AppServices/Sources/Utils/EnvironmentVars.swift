//
//  Environment.swift
//  AppServices
//
//  Created by OloApps on 6/6/25.
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

import Foundation

public enum EnvironmentVars {
    enum Keys {
        static let developmentTeam = "DEVELOPMENT_TEAM"
        static let sentryDsn = "SENTRY_DSN"
    }
    
    // Getting plist here
    private static let infoDictionary: [String: Any] = {
        guard let dict = Bundle.main.infoDictionary else {
            fatalError("plist file not found")
        }
        return dict
    }()
    
    // Get apiKey and baseurl from plist
    public static let developmentTeam: String = {
        guard let developmentTeamString = EnvironmentVars.infoDictionary[Keys.developmentTeam] as? String else {
            fatalError("DEVELOPMENT_TEAM not set in plist")
        }
        return developmentTeamString
    }()
    
    public static let sentryDsn: String = {
        guard let sentryDsnString = EnvironmentVars.infoDictionary[Keys.sentryDsn] as? String else {
            return ""
        }
        return sentryDsnString
    }()
}
