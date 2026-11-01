//
//  Chip.swift
//  ReqRes
//
//  Created by OloApps on 26.06.2023.
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

struct Chip: View {
    let status: String?

    var body: some View {
        HStack {
            Text(status ?? "•••")
                .font(.system(size: 12))
                .fontWeight(.regular)
                .foregroundColor(.white)
                .frame(minWidth: 25, alignment: .center)
        }
        .padding([.vertical], 3)
        .padding([.horizontal], 6)
        .background(RoundedRectangle(cornerRadius: 6)
        .foregroundColor(getColor().opacity(0.9)))
    }
    
    func getColor() -> Color {
        // https://gist.github.com/sandrabosk/d125177b31eca8dc3e5c524e703ba94d
        let statusInt = Int(status ?? "") ?? 0
        
        if (statusInt >= 100 && statusInt <= 102) {
            return .blue
        }
        if (statusInt >= 200 && statusInt <= 299) {
            return Color(nsColor: Palette.green)
        }
        if (statusInt >= 300 && statusInt <= 399) {
            return .purple
        }
        if (statusInt >= 400 && statusInt <= 499) {
            return .orange
        }
        if (statusInt >= 500 && statusInt <= 599) {
            return .red
        }
        
        return .gray
    }
}

struct Chip_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Chip(status: "101")
            Chip(status: "201")
            Chip(status: "301")
            Chip(status: "401")
            Chip(status: "501")
        }
    }
}
