//
//  String+Extensions.swift
//  ReqRes
//
//  Created by OloApps on 03.07.2023.
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

import Foundation

extension String {
    // https://stackoverflow.com/a/49072718
    var isValidURL: Bool {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        if let match = detector.firstMatch(in: self, options: [], range: NSRange(location: 0, length: self.utf16.count)) {
            // it is a link, if the match covers the whole string
            return match.range.length == self.utf16.count
        } else {
            return false
        }
    }
    
    // New hostname validation
    var isValidHostname: Bool {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Empty check
        if trimmed.isEmpty {
            return false
        }
        
        // Check for invalid characters
        // Valid hostname characters are: a-z, A-Z, 0-9, -, .
        let invalidChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.").inverted
        if trimmed.rangeOfCharacter(from: invalidChars) != nil {
            return false
        }
        
        // Basic domain format check
        // - Must contain at least one dot
        // - Cannot start or end with a dot or hyphen
        // - Cannot have consecutive dots
        if !trimmed.contains(".") ||
           trimmed.hasPrefix(".") ||
           trimmed.hasSuffix(".") ||
           trimmed.hasPrefix("-") ||
           trimmed.hasSuffix("-") ||
           trimmed.contains("..") {
            return false
        }
        
        // Each segment between dots must:
        // - Not be empty
        // - Not exceed 63 characters
        let segments = trimmed.split(separator: ".")
        for segment in segments {
            if segment.isEmpty || segment.count > 63 {
                return false
            }
        }
        
        // TLD (last segment) should be at least 2 characters
        if let tld = segments.last, tld.count < 2 {
            return false
        }
        
        return true
    }
}
