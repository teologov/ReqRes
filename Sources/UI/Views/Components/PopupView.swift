//
//  PopupView.swift
//  ReqRes
//
//  Created by OloApps on 8/27/24.
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

struct PopupView<Content: View>: View {
    let content: Content
    let onClose: () -> Void
    
    init(@ViewBuilder content: () -> Content, onClose: @escaping () -> Void) {
        self.content = content()
        self.onClose = onClose
    }
    
    var body: some View {
        VStack {
            Spacer()
            
            VStack(spacing: 0) {
                content
                    .frame(width: 500, height: 450) // Set content frame size (excluding footer)
                
                Divider()
                
                HStack {
                    Spacer()
                    
                    Button("Done") {
                        onClose()
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 10)
                }
            }
            .background(Color(.windowBackgroundColor))
            .cornerRadius(10)
            .shadow(radius: 20)
            .padding(.horizontal, 20)
            
            Spacer()
        }
        .background(Color.black.opacity(0.4).edgesIgnoringSafeArea(.all))
    }
}

#Preview {
    PopupView {
        Text("Popup")
    } onClose: {
        
    }
}
