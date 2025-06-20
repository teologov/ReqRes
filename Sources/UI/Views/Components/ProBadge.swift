//
//  ProBadge.swift
//  ReqRes
//
//  Created by OloApps on 3/27/25.
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

import SwiftUI

struct ProBadge: View {
    // Animation properties
//    @State private var isAnimating: Bool = false
    
    // Default color scheme with customization option
    var primaryColor: Color = .blue
    var textColor: Color = .white
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 10, weight: .semibold))
//                .symbolEffect(.pulse, options: .repeating, value: isAnimating)
            
            Text("PRO")
                .font(.system(size: 11, weight: .heavy))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(primaryColor.gradient)
                .shadow(color: primaryColor.opacity(0.3), radius: 2, x: 0, y: 1)
        )
        .foregroundColor(textColor)
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.3), lineWidth: 1)
        )
        .onAppear {
            // Start checkmark seal animation when badge appears
//            isAnimating = true
        }
    }
}

// Version with optional action when tapped
struct ProBadgeButton: View {
    var action: () -> Void
    var primaryColor: Color = .blue
    var textColor: Color = .white
    
    var body: some View {
        Button(action: action) {
            ProBadge(
                primaryColor: primaryColor,
                textColor: textColor
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
