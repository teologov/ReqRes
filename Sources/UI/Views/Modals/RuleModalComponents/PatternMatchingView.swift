//
//  PatternMatchingView.swift
//  ReqRes
//
//  Created by OloApps on 11/7/24.
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
import XReqResCore

struct PatternMatchingView: View {
    @State private var selectedRule: String = "Wildcard"
    @State private var pattern: String = ""
    @State private var url: String = "https://mysite.com/dashboard"
    @State private var isMatch: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Section
            Text("Pattern Matching Rules")
                .font(.title)
                .fontWeight(.bold)
                .padding(.bottom, 5)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Test Your Pattern")
                    .font(.headline)
                
                // Pattern Input and Matching Rule Picker with 70% / 30% Widths
                GeometryReader { geometry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Pattern")
                                .font(.subheadline)
                            TextField("https://mysite.com/path*", text: $pattern)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Matching Rule")
                                .font(.subheadline)
                                .padding(.leading, 10)
                            Picker("", selection: $selectedRule) {
                                Text("Wildcard").tag("Wildcard")
                                Text("Regex").tag("Regex")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: geometry.size.width * 0.3, height: 35, alignment: .leading) // 30% width
                        }
                    }
                }
                .frame(height: 60) // Height to contain both elements
                
                // URL Input
                VStack(alignment: .leading) {
                    Text("URL")
                        .font(.subheadline)
                    TextField("Enter URL", text: $url)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.bottom, 5)
                }
                
                HStack {
                    Spacer()
                    Text(isMatch ? "✅ Match" : "❌ No Match")
                        .font(.headline)
                        .foregroundColor(isMatch ? .green : .red)
                    Spacer()
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.windowBackgroundColor)))
            
            // Description of Wildcard
            VStack(alignment: .leading, spacing: 10) {
                Text("Wildcard")
                    .font(.headline)
                Text("Supports a single wildcard character (*) to match any character zero or more times.")
                    .font(.subheadline)
                
                // Wildcard Examples
                VStack(alignment: .leading, spacing: 5) {
                    Text("Examples:")
                        .fontWeight(.semibold)
                    Text("*.mysite.com/path — matches any subdomain of mysite.com")
                    Text("mysite.com/api/*/ — matches any API call")
                    Text("mysite.com/filter?* — ignores query parameters")
                }
                .font(.caption)
            }
            
            // Regex Description
            VStack(alignment: .leading, spacing: 10) {
                Text("Regex")
                    .font(.headline)
                Text("Supports full regex syntax. Be cautious with characters that overlap with URL syntax, as they may need escaping.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true) // Ensures line breaks
                
                // Regex Examples
                VStack(alignment: .leading, spacing: 5) {
                    Text("Examples:")
                        .fontWeight(.semibold)
                    Text("^.*\\.mysite\\.com/path$ — matches any subdomain of mysite.com")
                    Text("^mysite\\.com/api/.*/$ — matches any API call")
                    Text("^mysite\\.com/filter\\?.*$ — ignores query parameters")
                }
                .font(.caption)
            }
            
            Spacer()
        }
        .padding()
        .onChange(of: pattern) { _, _ in checkMatch() }
        .onChange(of: url) { _, _ in checkMatch() }
    }
    
    // Updated match checker function
    func checkMatch() {
        if selectedRule == "Wildcard" {
            // Convert wildcard pattern to regex-compatible pattern
            let regexPattern = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
            isMatch = matchesRegex(regexPattern: "^" + regexPattern + "$", in: url)
        } else if selectedRule == "Regex" {
            // Directly use the regex pattern provided by the user
            isMatch = matchesRegex(regexPattern: pattern, in: url)
        }
    }
    
    // Helper function to perform regex matching
    func matchesRegex(regexPattern: String, in text: String) -> Bool {
        do {
            let regex = try NSRegularExpression(pattern: regexPattern)
            let range = NSRange(location: 0, length: text.utf16.count)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        } catch {
            AppLog.shared.error("Invalid regex: \(error.localizedDescription)")
            return false
        }
    }
}

struct PatternMatchingView_Previews: PreviewProvider {
    static var previews: some View {
        PatternMatchingView()
    }
}
