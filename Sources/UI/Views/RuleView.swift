//
//  RuleView.swift
//  ReqRes
//
//  Created by OloApps on 04.07.2023.
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
import MCPKit
import XReqResCore

struct RuleView: View {
    var rule: RuleCodable
    var ruleHost: HostCodable?
    var selectedHost: HostCodable?
    /// The rule's Map Local file could not be read at the last rules push (F24):
    /// a matching request gets 500 and a note until the file is chosen again.
    var fileUnreadable: Bool = false
    
    var body: some View {
        HStack {
            VStack(spacing: 5) {
                HStack {
                    Image(systemName: "arrow.left.and.right.circle")
                        .renderingMode(.template)
                        .foregroundColor(.blue)
                    Text(RuleMethod.displayName(rule.reqMethod))
                        .font(.body)
                        .fontWeight(.medium)
                        .truncationMode(.tail)
                    Toggle("", isOn: Binding(
                        get: { rule.enabled.boolValue }, // Convert NSNumber to Bool
                        set: { newValue in
                            // Create updated rule with new enabled state
                            let updatedRule = RuleCodable(
                                id: rule.id,
                                path: rule.path,
                                hostId: rule.hostId,
                                enabled: NSNumber(value: newValue),
                                isRegexp: rule.isRegexp,
                                isWildCard: rule.isWildCard,
                                ruleMode: rule.ruleMode,
                                reqProtocol: rule.reqProtocol,
                                reqMethod: rule.reqMethod,
                                reqHeaders: rule.reqHeaders,
                                rspHeaders: rule.rspHeaders,
                                rspCode: rule.rspCode,
                                rspBody: rule.rspBody,
                                rspPath: rule.rspPath,
                                modelRealId: rule.modelRealId,
                            )
                            
                            AppState.shared.upsertRule(updatedRule)
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    if fileUnreadable {
                        Label(MapLocalUnreadable.listRowLabel, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .help(MapLocalUnreadable.listRowHelp(fileName: (rule.rspPath as NSString).lastPathComponent))
                            .accessibilityLabel(MapLocalUnreadable.listRowHelp(fileName: (rule.rspPath as NSString).lastPathComponent))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Text(verbatim: getPath())
                        .help(getPath())
                        .font(.callout)
                        .fontWeight(.light)
                        .foregroundColor(.gray)
                        .truncationMode(.tail)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    func getPath() -> String {
        guard let _host = ruleHost else {
            return rule.path
        }
        // means All traffic
        if selectedHost?.hostDbId == nil { // Check if hostDbId is nil for "All traffic"
            return "\(_host.requestProtocol.lowercased())://\(_host.host)\(rule.path)"
        }
        return rule.path
    }
}
//struct RuleView_Previews: PreviewProvider {
//    static var previews: some View {
//        RuleView()
//    }
//}

// Window delegate class to handle window closing
class DisposableWindowController: NSWindowController, NSWindowDelegate {
    override func windowDidLoad() {
        super.windowDidLoad()
        window?.delegate = self
    }
    
    func windowWillClose(_ notification: Notification) {
        // Release the window controller when window closes
        self.window = nil
    }
}
