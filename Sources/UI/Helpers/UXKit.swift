//
//  UXKit.swift
//  ReqRes
//
//  Created by OloApps on 6/4/24.
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

import AppKit
import SwiftUI

struct Palette {
    static var red: NSColor {
        NSColor.dynamic(light: Palette.lightRed, dark: Palette.darkRed)
    }

    static var pink: NSColor {
        NSColor.dynamic(light: Palette.lightPink, dark: Palette.darkPink)
    }
    
    static var green: NSColor {
        NSColor.dynamic(light: Palette.greenDualTheme, dark: Palette.greenDualTheme)
    }

    private static let lightRed = NSColor(red: 196.0/255.0, green: 26.0/255.0, blue: 22.0/255.0, alpha: 1.0)
    private static let darkRed = NSColor(red: 254.0/255.0, green: 129.0/255.0, blue: 112.0/255.0, alpha: 1.0)

    private static let lightPink = NSColor(red: 155.0/255.0, green: 35.0/255.0, blue: 147.00/255.0, alpha: 1.0)
    private static let darkPink = NSColor(red: 252.0/255.0, green: 95.0/255.0, blue: 163.0/255.0, alpha: 1.0)
    
    private static let greenDualTheme = NSColor(red: 0.318, green: 0.682, blue: 0.196, alpha: 1)
    
    static var networkDNS = NSColor(red: 0.34, green: 0.71, blue: 0.91, alpha: 1.00)
    static var networkTCP = NSColor(red: 0.90, green: 0.62, blue: 0.00, alpha: 1.00)
    static var networkSecure = NSColor(red: 0.00, green: 0.62, blue: 0.45, alpha: 1.00)
    static var networkRequest = NSColor(red: 0.80, green: 0.47, blue: 0.65, alpha: 1.00)
    static var networkWaiting = NSColor(red: 0.94, green: 0.89, blue: 0.26, alpha: 1.00)
    static var networkDownload = NSColor(red: 0.84, green: 0.37, blue: 0.00, alpha: 1.00)
    static var indigo400 = NSColor(red: 0.31, green: 0.27, blue: 0.90, alpha: 1.00)
}

extension NSColor {
    static var separator: NSColor { separatorColor }
    static var label: NSColor { labelColor }
    static var systemBackground: NSColor { windowBackgroundColor }
    static var secondaryLabel: NSColor { secondaryLabelColor }
    static var secondarySystemFill: NSColor { controlBackgroundColor }
    static var systemGray4: NSColor { systemGray.withAlphaComponent(0.7) }
    static var systemGray3: NSColor { systemGray.withAlphaComponent(0.8) }
    static var systemGray2: NSColor { systemGray.withAlphaComponent(0.9) }
}

extension NSColor {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) {
            switch $0.name {
            case .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
                return dark
            default:
                return light
            }
        }
    }
}

