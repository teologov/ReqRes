//
//  EditableTable.swift
//  ReqRes
//
//  Created by OloApps on 8/27/24.
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


/// The header editor as a sheet: edits a DRAFT, so Cancel discards and Done
/// applies. It used to be a hand-built NSWindow that wrote every keystroke
/// straight into the rule with no way back.
struct HeaderEditorSheet: View {
    let title: String
    @Binding var headers: [HeaderEntry]

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [HeaderEntry] = []

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            HeaderListView(headers: $draft)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done") {
                    headers = draft.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { draft = headers }
    }
}

/// A key/value table with add and remove.
struct HeaderListView: View {
    @Binding var headers: [HeaderEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(headers) {
                TableColumn("Header") { header in
                    TextField("Name", text: binding(for: header, \.key))
                        .textFieldStyle(.plain)
                }
                TableColumn("Value") { header in
                    HStack {
                        TextField("Value", text: binding(for: header, \.value))
                            .textFieldStyle(.plain)
                        Button {
                            headers.removeAll { $0.id == header.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove this header")
                    }
                }
            }
            .frame(height: 220)

            Button {
                headers.append(HeaderEntry(key: "", value: "", isEnabled: true))
            } label: {
                Label("Add Header", systemImage: "plus")
            }
        }
    }

    private func binding(for header: HeaderEntry, _ keyPath: WritableKeyPath<HeaderEntry, String>) -> Binding<String> {
        Binding(
            get: { headers.first { $0.id == header.id }?[keyPath: keyPath] ?? "" },
            set: { value in
                if let index = headers.firstIndex(where: { $0.id == header.id }) {
                    headers[index][keyPath: keyPath] = value
                }
            }
        )
    }
}

#Preview {
    HeaderListView(headers: .constant([
        HeaderEntry(key: "Authorization", value: "Bearer token", isEnabled: true),
        HeaderEntry(key: "Accept", value: "application/json", isEnabled: true)
    ]))
}
