//
//  PlaceholderView.swift
//  ReqRes
//
//  Created by OloApps on 2024-01-22.
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

struct PlaceholderView: View {
    var imageName: String?
    let title: String
    var subtitle: String?
    var buttonTitle: String? // Optional button title
    var buttonAction: (() -> Void)? // Optional button callback

    private let iconSize: CGFloat = 70
    private let maxWidth: CGFloat = .infinity

    var body: some View {
        VStack {
            imageName.map(Image.init(systemName:))
                .font(.system(size: iconSize, weight: .light))
            Spacer().frame(height: 8)
            Text(title)
                .font(.title)
                .multilineTextAlignment(.center)
            if let subtitle = self.subtitle {
                Spacer().frame(height: 10)
                Text(subtitle)
                    .multilineTextAlignment(.center)
            }
            if let buttonTitle = buttonTitle, let buttonAction = buttonAction {
                Button(action: buttonAction) {
                    Text(buttonTitle)
                }
                .padding(.top, 10)
            }
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: maxWidth, maxHeight: .infinity, alignment: .center)
    }
}
#if DEBUG
struct PlaceholderView_Previews: PreviewProvider {
    static var previews: some View {
        PlaceholderView(imageName: "questionmark.folder", title: "Store Unavailable")
    }
}
#endif
