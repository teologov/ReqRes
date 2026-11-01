//
//  ThinSplitter.swift
//  ReqRes
//
//  Created by OloApps on 27.06.2023.
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
import SplitView

struct ThinSplitter: SplitDivider {
    var visibleThickness: CGFloat = 2
    @ObservedObject var layout: LayoutHolder
    @ObservedObject var hide: SideHolder
    let hideRight = Image(systemName: "arrowtriangle.right.square")
    let hideLeft = Image(systemName: "arrowtriangle.left.square")
    let hideDown = Image(systemName: "arrowtriangle.down.square")
    let hideUp = Image(systemName: "arrowtriangle.up.square")
    
    var body: some View {
        Color.gray
            .frame(width: 1)
            .padding(0)
            .opacity(0.5)
    }
}
struct ThinSplitter_Previews: PreviewProvider {
    static var previews: some View {
        ThinSplitter(layout: LayoutHolder(), hide: SideHolder())
    }
}
