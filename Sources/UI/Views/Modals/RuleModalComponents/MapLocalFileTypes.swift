//
//  MapLocalFileTypes.swift
//  ReqRes
//
//  Created by OloApps on 2/5/25.
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

import UniformTypeIdentifiers

extension UTType {
    // Custom UTTypes for web files
    static var javascript: UTType {
        UTType.data
    }
    static var css: UTType {
        UTType.data
    }
    static var svg: UTType {
        UTType.data
    }
}

enum MapLocalError: Error {
    case fileTooLarge(size: Int64)
    case unsupportedFileType(filename: String)
}

struct MapLocalConfig {
    // Maximum file size (10MB)
    static let maxFileSize: Int64 = 10 * 1024 * 1024
        
    // Cache the supported types array
    private static let _supportedTypes: [UTType] = [
        .html,              // .html, .htm
        .json,              // .json
        .xml,               // .xml
        .plainText,         // .txt
        .javascript,        // .js
        .css,              // .css
        .jpeg,             // .jpg, .jpeg
        .png,              // .png
        .gif,              // .gif
        .svg,              // .svg
        .pdf,              // .pdf
        .zip,              // .zip
        .data              // catch-all for other binary files
    ]
    
    // Public accessor for the cached array
    static var supportedTypes: [UTType] { _supportedTypes }
    
    // Common MIME types mapping
    static let mimeTypes: [String: String] = [
        "js": "application/javascript",
        "jsx": "application/javascript",
        "css": "text/css",
        "html": "text/html",
        "htm": "text/html",
        "json": "application/json",
        "xml": "application/xml",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "pdf": "application/pdf",
        "zip": "application/zip",
        "txt": "text/plain"
    ]
    
    static func validateFile(at url: URL) throws {
        // Check file size
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= maxFileSize else {
            throw MapLocalError.fileTooLarge(size: Int64(fileSize))
        }
        
        // Check if the file extension is supported
        let fileExtension = url.pathExtension.lowercased()
        if !mimeTypes.keys.contains(fileExtension) {
            throw MapLocalError.unsupportedFileType(filename: url.lastPathComponent)
        }
    }
    
    // Helper to get MIME type for a file
    static func mimeType(for url: URL) -> String {
        // First try to get the MIME type from the file extension
        let fileExtension = url.pathExtension.lowercased()
        if let mimeType = mimeTypes[fileExtension] {
            return mimeType
        }
        
        // Default fallback
        return "application/octet-stream"
    }
}
