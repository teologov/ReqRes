//
//  PrefixedTextField.swift
//  ReqRes
//
//  Created by OloApps on 8/26/24.
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

struct PrefixedTextField: View {
    var prefix: String
    @Environment(\.colorScheme) var colorScheme
    @Binding var text: String
    var placeholder: String
    var onTextChanged: ((String) -> Void)?
    
    var body: some View {
        HStack(spacing: 0) {
            // Prefix (e.g., https://google.com)
            if (prefix != "All traffic") {
                Text(verbatim: prefix)
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedCorners(tl: 4, tr: 0, bl: 4, br: 0))
                    .help(prefix)
                // Vertical Divider
                Divider()
                    .frame(width: 1)
                    .background(Color.gray.opacity(0.2))
                    .padding(.vertical, 1.5)
            }
                
            // TextField
            TextField(placeholder, text: $text, onEditingChanged: { _ in
                if let onTextChanged = onTextChanged {
                    onTextChanged(text)
                }
            })
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .textFieldStyle(.plain)
            .background(colorScheme == .dark ? Color.gray.opacity(0.1) : Color.white)
            .clipShape(RoundedCorners(tl: prefix == "All traffic" ? 4 : 0, tr: 4, bl: prefix == "All traffic" ? 4 : 0, br: 4))
        }
        .frame(height: 30)  // Adjust height if needed
    }
}

struct PrefixedTextField_Previews: PreviewProvider {
    @State static var sampleText = "Example"
    
    static var previews: some View {
        PrefixedTextField(prefix: "Prefix", text: $sampleText, placeholder: "/path?*")
            .padding()
            .frame(width: 400)
    }
}

// Custom Shape for rounded corners on macOS
struct RoundedCorners: Shape {
    var tl: CGFloat = 0.0
    var tr: CGFloat = 0.0
    var bl: CGFloat = 0.0
    var br: CGFloat = 0.0

    func path(in rect: CGRect) -> Path {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.appendArc(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.appendArc(from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.line(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.appendArc(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.appendArc(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.close()
        
        return Path(path.cgPath)
    }
}

extension Path {
    init(_ bezierPath: NSBezierPath) {
        self.init(bezierPath.cgPath)
    }
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            case .cubicCurveTo:
                break
            case .quadraticCurveTo:
                break
            @unknown default:
                break
            }
        }
        return path
    }
}

//#Preview {
//    PrefixedTextField()
//}
