//
//  SearchBar.swift
//  ReqRes
//
//  Created by OloApps on 10/22/24.
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

struct ToolbarSearchButton: View {
    @StateObject var sessionState = SessionState.shared
    @State var isSearching: Bool = false
    // Correct use of FocusState for managing focus
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        HStack {
            if isSearching {
                TextField("Search", text: $sessionState.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    // Apply focus to the TextField
                    .focused($isSearchFieldFocused)
                    .onAppear {
                        DispatchQueue.main.async {
                            self.isSearchFieldFocused = true  // Auto focus when appearing
                        }
                    }

                Button(action: {
//                    withAnimation {
                        isSearching.toggle()
                        sessionState.searchText = ""
                        // Remove focus when closed
                        isSearchFieldFocused = false
//                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .help("Close search")
            } else {
                Button(action: {
//                    withAnimation {
                        isSearching.toggle()
//                    }
                }) {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(sessionState.sessions.isEmpty)
                .help("Search sessions")
            }
        }
    }
}
