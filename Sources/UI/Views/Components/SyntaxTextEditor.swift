//
//  SyntaxTextEditor.swift
//  ReqRes
//
//  Created by OloApps on 5/29/25.
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
import AppKit
import XReqResCore

struct SyntaxTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var rspHeaders: [HeaderEntry]
    
    enum SyntaxLanguage {
        case json, xml, html, css, javascript, plain
        
        static func from(contentType: String?) -> SyntaxLanguage {
            guard let contentType = contentType?.lowercased() else { return .plain }
            
            if contentType.contains("json") {
                return .json
            } else if contentType.contains("xml") {
                return .xml
            } else if contentType.contains("html") {
                return .html
            } else if contentType.contains("css") {
                return .css
            } else if contentType.contains("javascript") || contentType.contains("js") {
                return .javascript
            } else {
                return .plain
            }
        }
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        
        // Configure scroll view
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = NSColor.textBackgroundColor
        
        // Configure text view for editing
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.insertionPointColor = NSColor.textColor
        
        textView.textContainerInset = NSSize(width: 10, height: 10)
        // Additional horizontal padding
        textView.textContainer?.lineFragmentPadding = 10
        
        // Disable smart features that interfere with code editing
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        
        // Configure text container for proper scrolling
        textView.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        
        // Set up the text view in scroll view
        scrollView.documentView = textView
        
        // Set initial text
        textView.string = text
        
        // Apply syntax highlighting
        let language = SyntaxLanguage.from(contentType: rspHeaders.contentType())
        applySyntaxHighlighting(to: textView, language: language)
        
        // Set delegate
        textView.delegate = context.coordinator
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        
        let currentContentType = rspHeaders.contentType()
        
        if textView.string != text {
            // Store current cursor position
            let selectedRange = textView.selectedRange()
            
            textView.string = text
            
            // Restore cursor position (if still valid)
            if selectedRange.location <= text.count {
                textView.setSelectedRange(selectedRange)
            }
            
            let language = SyntaxLanguage.from(contentType: currentContentType)
            applySyntaxHighlighting(to: textView, language: language)
        } else {
            // Even if text hasn't changed, reapply highlighting if content type changed
            let language = SyntaxLanguage.from(contentType: currentContentType)
            applySyntaxHighlighting(to: textView, language: language)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func applySyntaxHighlighting(to textView: NSTextView, language: SyntaxLanguage) {
        let storage = textView.textStorage!
        let range = NSRange(location: 0, length: storage.length)
        
        // Reset formatting
        storage.removeAttribute(.foregroundColor, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: range)
        
        switch language {
        case .json:
            highlightJSON(in: storage)
        case .xml:
            highlightXML(in: storage)
        case .html:
            highlightHTML(in: storage)
        case .css:
            highlightCSS(in: storage)
        case .javascript:
            highlightJavaScript(in: storage)
        case .plain:
            break
        }
    }
    
    private func highlightJSON(in storage: NSTextStorage) {
        var text = storage.string
        
        // JSON string highlighting (darker green)
        let stringPattern = "\"(?:[^\"\\\\]|\\\\.)*\""
        highlightPattern(stringPattern, in: storage, color: NSColor(red: 0.0, green: 0.6, blue: 0.0, alpha: 1.0))
        
        // JSON keys (blue) - strings followed by colon
        let keyPattern = "\"(?:[^\"\\\\]|\\\\.)*\"\\s*:"
        highlightPattern(keyPattern, in: storage, color: .systemBlue)
        
        // JSON numbers (orange)
        let numberPattern = "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"
        highlightPattern(numberPattern, in: storage, color: .systemOrange)
        
        // JSON booleans and null (purple)
        let booleanPattern = "\\b(?:true|false|null)\\b"
        highlightPattern(booleanPattern, in: storage, color: .systemPurple)
        
        // JSON brackets and braces (gray)
        let structurePattern = "[\\[\\]{}]"
        highlightPattern(structurePattern, in: storage, color: .systemGray)
    }
    
    private func highlightXML(in storage: NSTextStorage) {
        // XML tags (blue)
        let tagPattern = "</?\\b[^>]*>"
        highlightPattern(tagPattern, in: storage, color: .systemBlue)
        
        // XML attributes (darker green)
        let attributePattern = "\\b\\w+(?=\\s*=)"
        highlightPattern(attributePattern, in: storage, color: NSColor(red: 0.0, green: 0.6, blue: 0.0, alpha: 1.0))
        
        // XML attribute values (orange)
        let valuePattern = "\"[^\"]*\"|'[^']*'"
        highlightPattern(valuePattern, in: storage, color: .systemOrange)
        
        // XML comments (gray)
        let commentPattern = "<!--[\\s\\S]*?-->"
        highlightPattern(commentPattern, in: storage, color: .systemGray)
    }
    
    private func highlightHTML(in storage: NSTextStorage) {
        // HTML tags (blue)
        let tagPattern = "</?\\b[^>]*>"
        highlightPattern(tagPattern, in: storage, color: .systemBlue)
        
        // HTML attributes (darker green)
        let attributePattern = "\\b\\w+(?=\\s*=)"
        highlightPattern(attributePattern, in: storage, color: NSColor(red: 0.0, green: 0.6, blue: 0.0, alpha: 1.0))
        
        // HTML attribute values (orange)
        let valuePattern = "\"[^\"]*\"|'[^']*'"
        highlightPattern(valuePattern, in: storage, color: .systemOrange)
        
        // HTML comments (gray)
        let commentPattern = "<!--[\\s\\S]*?-->"
        highlightPattern(commentPattern, in: storage, color: .systemGray)
    }
    
    private func highlightCSS(in storage: NSTextStorage) {
        // CSS selectors (blue)
        let selectorPattern = "(?:^|\\s)[.#]?[a-zA-Z][a-zA-Z0-9_-]*(?=\\s*\\{)"
        highlightPattern(selectorPattern, in: storage, color: .systemBlue)
        
        // CSS properties (darker green)
        let propertyPattern = "\\b[a-zA-Z-]+(?=\\s*:)"
        highlightPattern(propertyPattern, in: storage, color: NSColor(red: 0.0, green: 0.6, blue: 0.0, alpha: 1.0))
        
        // CSS values (orange)
        let valuePattern = ":\\s*[^;]+(?=;|\\})"
        highlightPattern(valuePattern, in: storage, color: .systemOrange)
        
        // CSS comments (gray)
        let commentPattern = "/\\*[\\s\\S]*?\\*/"
        highlightPattern(commentPattern, in: storage, color: .systemGray)
    }
    
    private func highlightJavaScript(in storage: NSTextStorage) {
        // JavaScript keywords (purple)
        let keywordPattern = "\\b(?:var|let|const|function|if|else|for|while|return|try|catch|finally|class|extends|import|export|async|await|true|false|null|undefined)\\b"
        highlightPattern(keywordPattern, in: storage, color: .systemPurple)
        
        // JavaScript strings (darker green)
        let stringPattern = "\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`"
        highlightPattern(stringPattern, in: storage, color: NSColor(red: 0.0, green: 0.6, blue: 0.0, alpha: 1.0))
        
        // JavaScript numbers (orange)
        let numberPattern = "\\b\\d+(?:\\.\\d+)?\\b"
        highlightPattern(numberPattern, in: storage, color: .systemOrange)
        
        // JavaScript comments (gray)
        let commentPattern = "//.*$|/\\*[\\s\\S]*?\\*/"
        highlightPattern(commentPattern, in: storage, color: .systemGray)
    }
    
    private func highlightPattern(_ pattern: String, in storage: NSTextStorage, color: NSColor) {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(location: 0, length: storage.length)
            let matches = regex.matches(in: storage.string, options: [], range: range)
            
            for match in matches {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        } catch {
            AppLog.shared.error("Regex error: \(error)")
        }
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: SyntaxTextEditor
        private var highlightTimer: Timer?
        
        init(_ parent: SyntaxTextEditor) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            // Update the binding immediately
            DispatchQueue.main.async {
                self.parent.text = textView.string
            }
            
            // Debounce syntax highlighting to avoid performance issues
            highlightTimer?.invalidate()
            highlightTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                DispatchQueue.main.async {
                    let language = SyntaxTextEditor.SyntaxLanguage.from(contentType: self.parent.rspHeaders.contentType())
                    self.parent.applySyntaxHighlighting(to: textView, language: language)
                }
            }
        }
        
        deinit {
            highlightTimer?.invalidate()
        }
    }
}

// Usage with your HeaderEntry array
struct ResponseBodyEditorView: View {
    @Binding var responseBody: String
    @Binding var rspHeaders: [HeaderEntry] // Make this a binding too
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Show detected content type
            HStack {
                Text("Content-Type:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(contentTypeDisplay)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(formatColor.opacity(0.1))
                    .foregroundColor(formatColor)
                    .cornerRadius(4)
                
                Spacer()
            }
            
            // Editor with automatic syntax detection
            SyntaxTextEditor(text: $responseBody, rspHeaders: $rspHeaders)
                .frame(height: 150)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(.horizontal, 10)
    }
    
    private var contentTypeValue: String? {
        // Find Content-Type header (case-insensitive)
        return rspHeaders.first { header in
            header.key.lowercased() == "content-type" && header.isEnabled
        }?.value
    }
    
    private var contentTypeDisplay: String {
        guard let contentType = contentTypeValue else {
            return "Unknown"
        }
        
        // Simplify display - just show the main type
        let mainType = contentType.components(separatedBy: ";").first ?? contentType
        switch mainType.lowercased().trimmingCharacters(in: .whitespaces) {
        case let type where type.contains("json"):
            return "JSON"
        case let type where type.contains("xml"):
            return "XML"
        case let type where type.contains("html"):
            return "HTML"
        case let type where type.contains("css"):
            return "CSS"
        case let type where type.contains("javascript"):
            return "JavaScript"
        default:
            return mainType
        }
    }
    
    private var formatColor: Color {
        let language = SyntaxTextEditor.SyntaxLanguage.from(contentType: contentTypeValue)
        
        switch language {
        case .json: return .blue
        case .xml: return .orange
        case .html: return .red
        case .css: return .purple
        case .javascript: return .yellow
        case .plain: return .gray
        }
    }
}

