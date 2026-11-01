//
//  MCPMockCharset.swift
//  AppServices
//
//  Copyright © 2026 Andrey Teologov. All rights reserved.
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
//  The Content-Type a mock_from_session rule carries, so its label names the
//  charset of the bytes the mock actually sends (R2-1, from the F12 review).
//
//  The core sends a rule's text as UTF-8 — `Data(rule.rspBody.utf8)` for an
//  Override, and the fixture file a Map Local rule is given is written the
//  same way. A mock's text is the agent's, or the captured row's, which is
//  the body DECODED: the core reads declared text in its charset (ISO-8859-1,
//  windows-1252, UTF-16 of either order — BoundedBodyDecoder, F12). The
//  headers are copied from the capture, so the mock served UTF-8 bytes under
//  `charset=windows-1252`, and "café" reached the app as "cafÃ©". The row
//  cannot give the original bytes back — it keeps no record of the charset
//  that decoded it, or of a byte-order mark Foundation dropped on the way —
//  so the label is made to say what the bytes are.
//

import Foundation

public enum MCPMockCharset {
    /// What the core writes a rule's text in.
    static let bodyCharset = "utf-8"

    /// The headers a mock copied from its capture, as the rule must store
    /// them.
    ///
    /// The body is `agentBody` when the agent passed one, else the row's
    /// text. Non-empty, it is text the core sends as UTF-8, so the copied
    /// Content-Type is relabelled. Empty, nothing of it is sent: a capture
    /// with no text is a binary one, replayed from a file of its own bytes,
    /// and an Override with an empty body forwards the server's own response
    /// under these headers — either way the capture's label still describes
    /// the bytes, and is kept. Applied BEFORE the agent's own headers go on,
    /// so a Content-Type the agent names stands as sent.
    public static func headers(_ copied: [String: String], agentBody: String?, capturedText: String) -> [String: String] {
        guard !(agentBody ?? capturedText).isEmpty else { return copied }
        var result = copied
        for (name, value) in copied where name.caseInsensitiveCompare("content-type") == .orderedSame {
            result[name] = contentType(value)
        }
        return result
    }

    /// `contentType` as it must read above a body sent as UTF-8.
    ///
    ///  - A `charset` parameter naming anything else — ISO-8859-1,
    ///    windows-1252, UTF-16, a name nothing recognises — says `utf-8`,
    ///    whatever the type. The rest of the value is kept as written.
    ///  - No `charset`, on a type whose readers fall back to something other
    ///    than UTF-8 without one — `text/*` (a browser guesses windows-1252
    ///    for unlabelled HTML in a Western locale), XML (whose own
    ///    declaration can name another encoding) and JavaScript (read in the
    ///    page's encoding): `; charset=utf-8` is added. The row may have come
    ///    from bytes whose byte-order mark said what they were, and the mark
    ///    did not survive decoding.
    ///  - No `charset` on anything else: unchanged. JSON (RFC 8259), YAML and
    ///    TOML are read as UTF-8 unless their bytes say otherwise, and a type
    ///    ReqRes judges by its bytes (octet-stream, forms, types it does not
    ///    know) is text in the row only when those bytes were UTF-8 to begin
    ///    with.
    public static func contentType(_ contentType: String) -> String {
        var segments = parameterSegments(contentType)
        let essence = segments[0].trimmingCharacters(in: .whitespaces).lowercased()
        guard !essence.isEmpty else { return contentType }

        var namesACharset = false
        for index in segments.indices.dropFirst() {
            guard let (name, value) = parameter(segments[index]), name.lowercased() == "charset" else { continue }
            namesACharset = true
            if !isUTF8(value) {
                let leading = segments[index].prefix(while: \.isWhitespace)
                segments[index] = "\(leading)\(name)=\(bodyCharset)"
            }
        }
        if namesACharset {
            return segments.joined(separator: ";")
        }
        guard readsAsNonUTF8WithoutACharset(essence) else { return contentType }
        var trimmed = contentType
        while let last = trimmed.last, last.isWhitespace || last == ";" {
            trimmed.removeLast()
        }
        return trimmed + "; charset=\(bodyCharset)"
    }

    /// The value of the first `charset` parameter, unquoted, or nil.
    static func charset(in contentType: String) -> String? {
        for segment in parameterSegments(contentType).dropFirst() {
            if let (name, value) = parameter(segment), name.lowercased() == "charset" {
                return unquoted(value)
            }
        }
        return nil
    }

    // MARK: - Pieces

    /// The value split at every `;` outside a quoted string — the media type
    /// first, then each parameter as written, spaces included, so joining
    /// them with `;` gives the value back unchanged.
    private static func parameterSegments(_ value: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in value {
            if escaped {
                escaped = false
            } else if quoted, character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ";", !quoted {
                segments.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        segments.append(current)
        return segments
    }

    /// `name=value` with the name trimmed and the value as written.
    private static func parameter(_ segment: String) -> (name: String, value: String)? {
        guard let equals = segment.firstIndex(of: "=") else { return nil }
        let name = segment[..<equals].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, String(segment[segment.index(after: equals)...]))
    }

    private static func unquoted(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
    }

    /// "utf-8" or "utf8", in any case, quoted or not — the spellings readers
    /// take as UTF-8 (both are WHATWG labels for it). Anything else is
    /// rewritten: a label a reader might not recognise is not left in place.
    private static func isUTF8(_ value: String) -> Bool {
        ["utf-8", "utf8"].contains(unquoted(value).lowercased())
    }

    private static let scriptTypes: Set<String> = [
        "application/javascript", "application/x-javascript",
        "application/ecmascript", "application/x-ecmascript",
    ]

    private static func readsAsNonUTF8WithoutACharset(_ essence: String) -> Bool {
        let parts = essence.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return false }
        return parts[0] == "text"
            || essence == "application/xml" || parts[1].hasSuffix("+xml")
            || scriptTypes.contains(essence)
    }
}
