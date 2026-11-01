//
//  Date+Extension.swift
//  AppServices
//
//  Created by OloApps on 20.05.2021.
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

import Foundation

extension Date {
    /// The time of day with milliseconds, as the traffic table and the
    /// request timings print it: `14:03:27.418`, in the Mac's time zone.
    public var CurrentStringTimeForCell: String {
        Self.cellTimeFormatter.string(from: self)
    }

    /// One formatter for every row: `DateFormatter` is costly to make and
    /// safe to share since macOS 10.9.
    private static let cellTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
