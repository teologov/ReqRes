//
//  ProtocolSupport.swift
//  AppServices
//
//  Created by OloApps on 9/29/26.
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
//  What this build captures, protocol by protocol (protocol PRD §4 Phase 0.3
//  and §5; protocol-engine doc §S10). ONE table, rendered four ways:
//
//   - Help ▸ Supported Protocols (`helpRows`, drawn by HelpContent.swift)
//   - diagnose_setup's informational `supported_protocols` check
//     (`diagnosisCheck()`, placed by `MCPSetupDiagnosis`)
//   - capture_status's short list (`statusLines(state:)`, doc §S13): names,
//     status tokens and what this Mac's certificate and HTTP/2 setting make
//     of the four entries that depend on them — the same lines a blocked
//     diagnose_setup prints
//   - SKILL.md's "Supported protocols" section (`skillSection`, pasted into
//     the file between its markers — `ProtocolSupportTests` fails, and prints
//     the block to paste, when the file and the table disagree)
//
//  so an agent never reads a protocol ReqRes does not capture as a broken
//  capture, and a person reads the same limits the agent does. Every entry was
//  written from the embedded core's behaviour as the protocol-engine doc
//  records it (steps C1–C13), not from the PRD's pre-fix table: Override with
//  a body and Map Local answer without contacting the server (C4), plain
//  http:// runs on the HTTPS engine on any port and exclusions apply to it
//  (C5), no-CA connections are one relay row each (C3/C7), the CA is per
//  install (C8), HTTP/2 is an opt-in beta (C12/C13).
//
//  Numbers are never typed here: the proxy port is `MCPLimits.proxyPort`, the
//  idle limits `CaptureEngineFacts`, the WebSocket retention
//  `SocketMessageLog`, and the HTTP/2 setting's words `HTTP2CaptureCopy` — so
//  a change there changes every rendering at once.
//

import Foundation

/// One protocol or situation and what capture does with it.
public struct ProtocolSupportEntry: Equatable, Sendable, Identifiable {
    public enum Status: String, CaseIterable, Sendable {
        /// Captured request by request, inspectable, rules apply.
        case supported
        /// Captured, but behind a setting that ships OFF (HTTP/2, D11).
        case beta
        /// Listed as one row per connection; what it carries is never read.
        case relayed
        /// Its requests are never read: nothing in the traffic list, or at
        /// most a failed row saying why (a pinning app, an mTLS server).
        case notCaptured = "not_captured"
    }

    /// Stable, snake_case: tests and the agent's text refer to it.
    public let id: String
    public let name: String
    public let status: Status
    /// What the person (or the agent reading the list) actually sees.
    public let whatYouSee: String
    /// What to do about it. Written for the human — an agent reads it out.
    public let whatToDo: String

    public init(id: String, name: String, status: Status, whatYouSee: String, whatToDo: String) {
        self.id = id
        self.name = name
        self.status = status
        self.whatYouSee = whatYouSee
        self.whatToDo = whatToDo
    }
}

/// This Mac's state, as far as it changes what an entry means (doc §S13):
/// whether HTTPS is decrypted (the first two entries) and whether HTTP/2
/// capture is on (HTTP/2 and native gRPC). Nil is "could not tell", and an
/// entry whose note depends on it then carries no note — never a guess.
public struct ProtocolSupportState: Equatable, Sendable {
    /// Installed AND trusted — what decrypts HTTPS.
    public var httpsDecrypted: Bool?
    public var http2CaptureEnabled: Bool?
    /// Whether the CA is in the keychain at all — only used to say WHICH step
    /// is missing when HTTPS is not decrypted (install, or just Trust). nil
    /// when unknown, and then the note names both steps.
    public var caInstalled: Bool?

    public init(httpsDecrypted: Bool?, http2CaptureEnabled: Bool?, caInstalled: Bool? = nil) {
        self.httpsDecrypted = httpsDecrypted
        self.http2CaptureEnabled = http2CaptureEnabled
        self.caInstalled = caInstalled
    }

    /// Read from the facts diagnose_setup reads, through ITS certificate
    /// checks (`MCPSetupDiagnosis.httpsDecrypted` / `.caInstalled`) — so
    /// capture_status and diagnose_setup can never disagree about the same Mac.
    public init(facts: MCPSetupFacts) {
        self.init(
            httpsDecrypted: MCPSetupDiagnosis.httpsDecrypted(facts),
            http2CaptureEnabled: facts.http2CaptureEnabled,
            caInstalled: MCPSetupDiagnosis.caInstalled(facts)
        )
    }

    /// Nothing known: no entry carries a note.
    public static let unknown = ProtocolSupportState(httpsDecrypted: nil, http2CaptureEnabled: nil)
}

/// One entry in the SHORT form, as capture_status sends it (structured, in
/// `MCPBridgeStatus.protocols`) and as both capture_status and a blocked
/// diagnose_setup print it (`text`). Status is the agent token as a string, so
/// a helper and an app of different builds still decode each other.
public struct ProtocolSupportStatusLine: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// `supported`, `beta`, `relayed` or `not_captured`.
    public var status: String
    /// What this Mac's state makes of the entry ("HTTP/2 capture is off");
    /// nil when it depends on nothing, or on a state that could not be read.
    public var note: String?

    public init(id: String, name: String, status: String, note: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.note = note
    }

    /// "HTTP/2 [beta] — HTTP/2 capture is off"
    public var text: String {
        let line = "\(name) [\(status)]"
        guard let note else { return line }
        return "\(line) — \(note)"
    }
}

/// One entry as Help draws it: a heading, a status carried by a WORD and a
/// symbol (never colour alone), and two labelled paragraphs.
public struct ProtocolSupportHelpRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let statusLabel: String
    /// An SF Symbol name; the view pairs it with `statusLabel`.
    public let statusSymbol: String
    public let whatYouSee: String
    public let whatToDo: String
    /// The whole row in one string, for VoiceOver.
    public var accessibilityLabel: String { "\(title). \(statusLabel). \(whatYouSee) \(whatToDo)" }
}

public enum ProtocolSupport {
    // MARK: - Words shared by the three renderings

    public static let helpTitle = "Supported Protocols"
    public static let helpIntro =
        "ReqRes is an HTTP(S) proxy that the whole Mac is pointed at while capture runs. What reaches it, and what it can read once something does, depends on the protocol — so a request missing from the list is not always a broken capture. Here is what this version does with each."
    public static let seeLabel = "What you see:"
    public static let doLabel = "What to do:"

    /// The diagnosis check's id and title.
    public static let diagnosisCheckId = "supported_protocols"
    public static let diagnosisTitle = "What this version captures"
    public static let diagnosisIntro =
        "Informational — a request of a kind listed here as not captured or relayed is missing (or undecoded) by design, not because capture is broken:"

    /// The first and last lines of SKILL.md's generated block.
    public static let skillBeginMarker = "<!-- BEGIN ProtocolSupport (generated from MCPKit/ProtocolSupport.swift — edit the table there; ProtocolSupportTests prints this block when the two differ) -->"
    public static let skillEndMarker = "<!-- END ProtocolSupport -->"

    public static func statusLabel(_ status: ProtocolSupportEntry.Status) -> String {
        switch status {
        case .supported: return "Supported"
        case .beta: return "Beta, off by default"
        case .relayed: return "Relayed, not read"
        case .notCaptured: return "Not captured"
        }
    }

    public static func statusSymbol(_ status: ProtocolSupportEntry.Status) -> String {
        switch status {
        case .supported: return "checkmark.circle"
        case .beta: return "testtube.2"
        case .relayed: return "arrow.left.arrow.right"
        case .notCaptured: return "eye.slash"
        }
    }

    /// The proxy URL a tool that ignores the system proxy must be given — the
    /// same one the environment lines export (`CaptureEnvironmentLines.proxyURL`).
    public static func proxyURL(port: Int = MCPLimits.proxyPort) -> String {
        CaptureEnvironmentLines(proxyPort: port).proxyURL
    }

    // MARK: - The table

    public static var all: [ProtocolSupportEntry] { entries() }

    public static func entries(proxyPort: Int = MCPLimits.proxyPort) -> [ProtocolSupportEntry] {
        let proxy = proxyURL(port: proxyPort)
        let inFlight = CaptureEngineFacts.duration(CaptureEngineFacts.idleWhileInFlight)
        let between = CaptureEngineFacts.duration(CaptureEngineFacts.idleBetweenExchanges)
        let relayIdle = CaptureEngineFacts.duration(CaptureEngineFacts.idleRelay)
        let head = SocketMessageLog.headCapacity.formatted(.number.locale(Locale(identifier: "en_US")))
        let tail = SocketMessageLog.tailCapacity.formatted(.number.locale(Locale(identifier: "en_US")))
        let http2Toggle = HTTP2CaptureCopy.toggleTitle
        let refusalWindow = CaptureEngineFacts.duration(CaptureEngineFacts.tlsRefusalWindow)

        return [
            ProtocolSupportEntry(
                id: "https",
                name: "HTTPS (HTTP/1.1)",
                status: .supported,
                whatYouSee: "One row per request — method, URL, headers, status, timings, the app that made it and where its server is — with the body decoded (gzip, deflate, brotli and zstd). A slow request or a stream is listed while it is still open. Rules, breakpoints and saved sessions all apply.",
                whatToDo: "Install and trust the ReqRes certificate in Settings ▸ Certificate. Until it is trusted, HTTPS is relayed instead (next entry)."
            ),
            ProtocolSupportEntry(
                id: "https_untrusted",
                name: "HTTPS before the certificate is trusted",
                status: .relayed,
                whatYouSee: "One row per connection, written when it closes: host and port, the bytes sent each way and how long it was open — no requests, headers or bodies. The traffic is not touched: the app talks to the real server with the server's own certificate.",
                whatToDo: "Trust the certificate. Connections opened after that are decrypted without restarting capture; one already open stays relayed until its app reconnects."
            ),
            ProtocolSupportEntry(
                id: "http",
                name: "Plain HTTP, any port",
                status: .supported,
                whatYouSee: "http:// on any port that reaches ReqRes is captured request by request like HTTPS, with no certificate needed: rules (matched against the path and the query), mocks and breakpoints all apply, and ws:// is captured too. Loopback is the exception: browsers and Electron apps never send localhost, 127.0.0.1 or ::1 to a proxy, and most Apple-networking apps skip it too, so http://localhost:3000 opened in them is not listed.",
                whatToDo: "For a local backend, call it from a tool pointed at the proxy with NO_PROXY unset (curl -x \(proxyURL()) http://localhost:3000/…), or reach it by the Mac's network name instead of localhost. A terminal set up with the environment lines skips localhost, 127.0.0.1 and ::1 on purpose (NO_PROXY); run unset NO_PROXY no_proxy there to include them."
            ),
            ProtocolSupportEntry(
                id: "http2",
                name: "HTTP/2",
                status: .beta,
                whatYouSee: "With \(http2Toggle) off (the default), the app and the server both speak HTTP/1.1 to ReqRes, which most apps accept without noticing; a client that speaks only HTTP/2 fails. With it on, an app and a server that both speak HTTP/2 are captured as HTTP/2, one row per request — the Metrics tab's Protocol row and proto:h2 in the search field show which. \(HTTP2CaptureCopy.mockedHostsNote)",
                whatToDo: "Turn on \(http2Toggle) in Settings ▸ Capture. It applies to connections opened after the change; turn it off if a site misbehaves."
            ),
            ProtocolSupportEntry(
                id: "websocket",
                name: "WebSocket (ws:// and wss://)",
                status: .supported,
                whatYouSee: "The handshake is one row (101 Switching Protocols) and its Messages tab lists the messages both ways — text, binary, ping, pong and close — as they pass. ReqRes keeps the first \(head) and the last \(tail) messages of a connection and says how many it let go in between. WebSockets stay on HTTP/1.1, and a connection with nothing moving either way is closed after \(relayIdle).",
                whatToDo: "Nothing for ws://. For wss://, trust the certificate: before that the connection is a relayed row with no messages."
            ),
            ProtocolSupportEntry(
                id: "streams",
                name: "Server-sent events and NDJSON streams",
                status: .supported,
                whatYouSee: "A stream is a row from its response head and grows while it runs. Its Events tab numbers each complete event, and an Anthropic or OpenAI answer is put back together — text, tool calls, stop reason and tokens. A stream that keeps sending is never cut; one silent in both directions for \(inFlight) is closed.",
                whatToDo: "Nothing."
            ),
            ProtocolSupportEntry(
                id: "grpc_web",
                name: "gRPC-Web and Connect",
                status: .supported,
                whatYouSee: "One row per call with an RPC tab: the service and method, each message decoded without the .proto, and the call's own status beside the HTTP one — a gRPC-Web error arrives as HTTP 200, so the row reads 200 · NOT_FOUND. A call still streaming is listed from its response head and grows while it runs; one answered in a single piece is just its row.",
                whatToDo: "Nothing. Type grpc:error in the search field to find the calls that failed."
            ),
            ProtocolSupportEntry(
                id: "grpc",
                name: "Native gRPC",
                status: .beta,
                whatYouSee: "Needs HTTP/2 capture: with it on, each call is a row whose RPC tab shows its messages and the status from its trailers, and a call still streaming is listed from its response head while it runs; with it off, a gRPC client fails through ReqRes. Most gRPC libraries ignore the macOS system proxy, so until told where ReqRes is their calls are not in the list at all.",
                whatToDo: "Turn on \(http2Toggle) in Settings ▸ Capture, point the client at \(proxy) with the environment lines, and give it the ReqRes certificate the way its TLS library reads one."
            ),
            ProtocolSupportEntry(
                id: "http3",
                name: "HTTP/3 (QUIC)",
                status: .notCaptured,
                whatYouSee: "QUIC runs over UDP and never passes through ReqRes's proxy, so a request an app sends over HTTP/3 is not in the list at all. Browsers use HTTP/3 only with sites that offer it, and fall back to TCP — through ReqRes — when QUIC is blocked or fails, so one site can show some of its requests and not others.",
                whatToDo: "To see every request, turn QUIC off in the app while you debug — in Chrome, Brave and Edge, set chrome://flags/#enable-quic to Disabled and relaunch."
            ),
            ProtocolSupportEntry(
                id: "other_tcp",
                name: "Other protocols through the proxy",
                status: .relayed,
                whatYouSee: "A connection through the proxy that carries neither HTTP nor TLS — SSH, a database, cleartext HTTP/2 — is passed on untouched and listed as one row when it closes: endpoint, bytes each way, how long it was open. With the certificate trusted, TLS through the proxy is always opened as HTTPS, so a protocol other than HTTP inside TLS (IMAP or SMTP over TLS, a database over TLS) fails, and a protocol whose server speaks first (SMTP, IMAP, FTP) waits for the app and is closed after \(between).",
                whatToDo: "Exclude its host in Settings ▸ Capture to pass it through untouched. SOCKS, UDP and DNS never reach ReqRes at all."
            ),
            ProtocolSupportEntry(
                id: "excluded",
                name: "Excluded hosts",
                status: .notCaptured,
                whatYouSee: "A host on the exclusion list is not recorded, over https:// and plain http:// alike: no row, no rules, no breakpoints. HTTPS to it is passed straight through untouched — not decrypted — with the server's own certificate, and HTTP/2 if both sides speak it. Plain http:// to it is forwarded as any proxy forwards it (hop-by-hop headers removed).",
                whatToDo: "Settings ▸ Capture holds the list. reqresapp.com and *.reqresapp.com, ReqRes's license server, are always excluded and cannot be removed. timestamp.apple.com (code signing) and *.ls.apple.com (Apple Maps) are on it by default; remove a host there to capture it again."
            ),
            ProtocolSupportEntry(
                id: "proxy_ignored",
                name: "Tools that ignore the system proxy",
                status: .notCaptured,
                whatYouSee: "Capture works by pointing the macOS system proxy at ReqRes. curl and git (Apple's included), the Claude Code CLI, node, Go and Rust programs and processes inside Docker containers ignore it, so their traffic is not in the list at all — not even as Unknown.",
                whatToDo: "Point them at \(proxy) with the environment lines in Settings ▸ Capture. The proxy address starts with http:// even for HTTPS traffic — an https:// proxy URL does not work."
            ),
            ProtocolSupportEntry(
                id: "pinned",
                name: "Apps that pin their certificate",
                status: .relayed,
                whatYouSee: "An app that checks its servers' certificates itself (SSL pinning — WhatsApp's media, banking apps) refuses ReqRes's, and the request that hits it fails: a failed row naming the host and the app (tlsClient). ReqRes then remembers the app and the host's domain, and passes that app's later connections there through untouched — the app works while you capture, and each connection is a row marked SSL pinned by the app, with the endpoint, the bytes each way and how long it was open. An alert counts at once; a bare hang-up only when it repeats within \(refusalWindow), because a browser's spare connection looks the same.",
                whatToDo: "Try again in the app after the first failure. Settings ▸ Capture ▸ SSL-pinned apps lists what ReqRes remembered; forget one to try decrypting it again, or exclude the host to pass it through without a row."
            ),
            ProtocolSupportEntry(
                id: "macos_pinned",
                name: "Apple services macOS pins",
                status: .relayed,
                whatYouSee: "iCloud, Software Update, the App Store, push notifications, Find My and the other hosts on macOS's own certificate-pinning list accept only Apple's certificate, in every app, so no proxy can decrypt them. ReqRes passes them through untouched — the services keep working while you capture — and lists each connection as one row marked “SSL pinned by macOS” with the service, the endpoint, the bytes each way and how long it was open.",
                whatToDo: "Nothing: it is macOS's rule, and a certificate does not change it. Exclude the host in Settings ▸ Capture to pass it through without a row."
            ),
            ProtocolSupportEntry(
                id: "mtls",
                name: "Servers that require a client certificate (mTLS)",
                status: .notCaptured,
                whatYouSee: "ReqRes presents no client certificate to the server, so the request fails: a failed row (tlsUpstream), and a 502 from ReqRes to the app that names the reason. A native gRPC client gets no 502: once the server's TLS has refused ReqRes, it can offer the client only HTTP/1.1, the client closes the connection, and its Failed row names excluding the host as the fix.",
                whatToDo: "Exclude the host in Settings ▸ Capture; its connections then carry the app's own certificate, unrecorded."
            ),
        ]
    }

    // MARK: - Rendering 1: Help

    public static var helpRows: [ProtocolSupportHelpRow] {
        all.map { entry in
            ProtocolSupportHelpRow(
                id: entry.id,
                title: entry.name,
                statusLabel: statusLabel(entry.status),
                statusSymbol: statusSymbol(entry.status),
                whatYouSee: "\(seeLabel) \(entry.whatYouSee)",
                whatToDo: "\(doLabel) \(entry.whatToDo)"
            )
        }
    }

    // MARK: - Rendering 2: diagnose_setup

    /// "HTTP/2 — beta, off by default. What you see: … What to do: …"
    public static func agentLine(_ entry: ProtocolSupportEntry) -> String {
        "\(entry.name) — \(statusLabel(entry.status).lowercased()) [\(entry.status.rawValue)]. \(seeLabel) \(entry.whatYouSee) \(doLabel) \(entry.whatToDo)"
    }

    /// The intro of the SHORT form, sent while another check is blocking.
    public static let diagnosisIndexIntro =
        "Informational — shortened because capture itself has a problem (above); fix that first. Once it is fixed, diagnose_setup prints what each of these does, and SKILL.md's “Supported protocols” carries the same list:"

    /// "HTTP/3 (QUIC) [not_captured]" — one entry in the short form.
    public static func indexLine(_ entry: ProtocolSupportEntry) -> String {
        "\(entry.name) [\(entry.status.rawValue)]"
    }

    /// Informational and always `.ok`: nothing here is a failure, and a human
    /// never sees it in Capture ▸ Diagnose Setup… (which lists only checks
    /// that are not ok).
    ///
    /// `compact` is the form `MCPSetupDiagnosis.report` sends while a check is
    /// blocking: the full list is ~7.5 KB (~2K tokens), and on a broken
    /// capture it would sit beside the one thing the agent must act on. The
    /// short form keeps every entry's name and status token so an agent can
    /// still tell "missing by design" from "broken" — just not the prose.
    ///
    /// The short form carries `state`'s notes, through the same
    /// `statusLines(state:)` capture_status prints (doc §S13), so the two
    /// short lists of one Mac are the same bytes.
    public static func diagnosisCheck(compact: Bool = false, state: ProtocolSupportState = .unknown) -> MCPSetupCheck {
        let lines = compact
            ? [diagnosisIndexIntro] + statusLines(state: state).map { "  - " + $0.text }
            : [diagnosisIntro] + all.map { "  - " + agentLine($0) }
        return MCPSetupCheck(
            id: diagnosisCheckId,
            title: diagnosisTitle,
            state: .ok,
            detail: lines.joined(separator: "\n")
        )
    }

    // MARK: - Rendering 2b: capture_status (doc §S13)

    /// The heading of capture_status's list. capture_status is the call SKILL.md
    /// sends an agent to FIRST and it is called often, so it carries the short
    /// form only: an agent that never calls diagnose_setup must still be able
    /// to tell a protocol ReqRes does not capture from a broken capture.
    public static let statusIntro =
        "Protocols (a request of a relayed or not_captured kind is missing or unread by design, not a broken capture; diagnose_setup explains each):"

    /// What this Mac's state makes of an entry, or nil. Only four entries
    /// depend on anything: HTTPS and its untrusted twin on the certificate,
    /// HTTP/2 and native gRPC on the HTTP/2 setting.
    public static func stateNote(_ entry: ProtocolSupportEntry, state: ProtocolSupportState) -> String? {
        switch entry.id {
        case "https":
            switch state.httpsDecrypted {
            case true?: return "in effect: the ReqRes CA is installed and trusted"
            case false?:
                // Name the step the human is missing: installed-but-untrusted
                // prints "ReqRes CA installed: yes" two lines up, so "not
                // installed" here would contradict it (S13 review).
                switch state.caInstalled {
                case true?: return "not yet: the ReqRes CA is installed but not trusted, so HTTPS is relayed"
                case false?: return "not yet: the ReqRes CA is not installed, so HTTPS is relayed"
                case nil: return "not yet: the ReqRes CA is not installed and trusted, so HTTPS is relayed"
                }
            case nil: return nil
            }
        case "https_untrusted":
            return state.httpsDecrypted == false ? "in effect on this Mac now" : nil
        case "http2":
            switch state.http2CaptureEnabled {
            case true?: return "HTTP/2 capture is on"
            case false?: return "HTTP/2 capture is off (the default)"
            case nil: return nil
            }
        case "grpc":
            switch state.http2CaptureEnabled {
            case true?: return "HTTP/2 capture is on"
            case false?: return "HTTP/2 capture is off, so a native gRPC client fails through ReqRes"
            case nil: return nil
            }
        default:
            return nil
        }
    }

    /// Every entry, short, with this Mac's notes — capture_status's structured
    /// `protocols` and the text both capture_status and a blocked
    /// diagnose_setup print.
    public static func statusLines(state: ProtocolSupportState) -> [ProtocolSupportStatusLine] {
        all.map { entry in
            ProtocolSupportStatusLine(id: entry.id, name: entry.name, status: entry.status.rawValue, note: stateNote(entry, state: state))
        }
    }

    /// The state capture_status reports, from its own status alone: the same
    /// `ProtocolSupportState(facts:)` diagnose_setup's facts go through.
    public static func state(for status: MCPBridgeStatus) -> ProtocolSupportState {
        ProtocolSupportState(facts: MCPSetupFacts(status: status, proxyPort: status.effectiveProxyPort))
    }

    // MARK: - Rendering 3: SKILL.md

    /// The block SKILL.md carries verbatim, markers included.
    public static var skillSection: String {
        var lines = [
            skillBeginMarker,
            "Before you tell anyone capture is broken, check that the missing request is of a kind ReqRes captures. `capture_status` lists every entry by name and status, with what this Mac's certificate and HTTP/2 setting make of it, and `diagnose_setup` returns the whole list (the `\(diagnosisCheckId)` check). Status is one of `supported`, `beta` (a setting the user turns on), `relayed` (one row per connection; what it carries is never read) or `not_captured` (the requests are never read: nothing in the list, or at most a failed row saying why).",
            "",
        ]
        lines += all.map { entry in
            "- **\(entry.name)** — `\(entry.status.rawValue)`. \(seeLabel) \(entry.whatYouSee) \(doLabel) \(entry.whatToDo)"
        }
        lines.append(skillEndMarker)
        return lines.joined(separator: "\n")
    }
}
