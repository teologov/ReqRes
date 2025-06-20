//
//  EditableTable.swift
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

struct HeaderEntry: Identifiable, Codable {
    let id: UUID
    var key: String
    var value: String
    var isEnabled: Bool
    
    init(id: UUID = UUID(), key: String, value: String, isEnabled: Bool) {
        self.id = id
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
    }
}

// A helper function to extract content type
extension Array where Element == HeaderEntry {
    func contentType() -> String? {
        return self.first { header in
            header.key.lowercased() == "content-type" && header.isEnabled
        }?.value
    }
}


struct HeaderListView: View {
    @Binding var headers: [HeaderEntry]
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Edit Headers")
                    .font(.headline)
                    .padding(.leading)
                
                Spacer()
                
                Button(action: addHeader) {
                    Image(systemName: "plus")
                }
                .padding(.trailing)
            }
            
            Table(headers) {
                TableColumn("Key") { header in
                    HStack { // Wrapper HStack to detect hover on the entire row
                        TextField("New Key", text: Binding(
                            get: { header.key },
                            set: {
                                if let index = headers.firstIndex(where: { $0.id == header.id }) {
                                    headers[index].key = $0
                                }
                                
                            }
                        ))
                        .textFieldStyle(PlainTextFieldStyle())
                        .padding(.leading, 4)
                    }
                }
                
                TableColumn("Value") { header in
                    HStack {
                        TextField("New Value", text: Binding(
                            get: { header.value },
                            set: {
                                if let index = headers.firstIndex(where: { $0.id == header.id }) {
                                    headers[index].value = $0
                                }
                            }
                        ))
                        .textFieldStyle(PlainTextFieldStyle())
                        .padding(.leading, 4)
                        
                        Button(action: {
                            deleteHeader(header)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                                .help("Delete row")
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .frame(minHeight: 150)
            .background(Color(.windowBackgroundColor)) // Background color for the entire table
        }
        .padding()
    }
    
    func addHeader() {
        headers.append(HeaderEntry(key: "", value: "", isEnabled: true))
    }
    
    func deleteHeader(_ header: HeaderEntry) {
        headers.removeAll { $0.id == header.id }
    }
}

#Preview {
    HeaderListView(headers: .constant([
        HeaderEntry(key: "Authorization", value: "Bearer token", isEnabled: true),
        HeaderEntry(key: "Accept", value: "application/json", isEnabled: true)
    ]))
}
