//
//  MCPTextFormat.swift
//  AppServices
//
//  Created by OloApps on 8/26/26.
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

import Foundation

/// Renders bridge payloads as compact text for tool results. Terse on purpose:
/// tool output is context an agent pays for on every turn.
public enum MCPTextFormat {
    /// What an agent needs after an export: where the file is, and the two
    /// facts it must not assume — whether everything asked for made it in,
    /// and that the values inside are redacted.
    public static func export(_ result: MCPExportResult) -> String {
        var lines = ["Wrote \(result.includedCount) of \(result.requestedCount) sessions to \(result.path) (\(result.bytes) bytes)."]
        if let skipped = result.skippedInFlight, skipped > 0 {
            lines.append(LiveRowCopy.exportSkippedLine(skipped))
        }
        if result.truncated {
            lines.append("The file hit its size cap, so later sessions were left out. Export fewer at a time to get the rest.")
        }
        if result.redacted {
            lines.append("Credential-shaped values are masked in the file; a token read out of it is a placeholder, not the real value.")
        }
        return lines.joined(separator: "\n")
    }

    /// The verdict first, then the checks. An agent reading top-down should
    /// be able to stop after the first line and still tell the user something
    /// true and actionable.
    public static func diagnosis(_ report: MCPSetupReport) -> String {
        var lines = [report.verdict, ""]
        for check in report.checks {
            let mark: String
            switch check.state {
            case .ok: mark = "ok  "
            case .problem: mark = "FAIL"
            case .warning: mark = "warn"
            case .unknown: mark = "?   "
            }
            var line = "\(mark) \(check.title): \(check.detail)"
            if let fix = check.fix { line += " → \(fix)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// `listingProtocols` is capture_status's (doc §S13): the short protocol
    /// list after the status, from the bridge's `protocols` — or, from an app
    /// that predates the field, from this helper's own table and the same
    /// status. start_capture and stop_capture print the status alone.
    public static func status(_ status: MCPBridgeStatus, listingProtocols: Bool = false) -> String {
        var text = statusLines(status)
        if listingProtocols {
            let lines = status.protocols ?? ProtocolSupport.statusLines(state: ProtocolSupport.state(for: status))
            text += "\n\n" + ([ProtocolSupport.statusIntro] + lines.map { "  - " + $0.text }).joined(separator: "\n")
        }
        return text
    }

    /// "running" / "stopped", or the transition in between. `start_capture`
    /// returns while the tunnel is still connecting, and "stopped (tunnel:
    /// connecting)" read as a failure (2026-09-29 live run).
    static func captureWord(captureActive: Bool, vpnStatus: String) -> String {
        if captureActive { return "running" }
        switch vpnStatus.lowercased() {
        case "connecting", "reasserting": return "starting"
        case "disconnecting": return "stopping"
        default: return "stopped"
        }
    }

    private static func statusLines(_ status: MCPBridgeStatus) -> String {
        var lines = [
            "Capture: \(captureWord(captureActive: status.captureActive, vpnStatus: status.vpnStatus)) (tunnel: \(status.vpnStatus))",
            "Extension: \(status.extensionStatus)",
            // Settings ▸ Capture can move it from 8034 (2026-09-29).
            "Proxy: 127.0.0.1:\(status.effectiveProxyPort)",
            "Sessions captured this run: \(status.sessionCount)",
        ]
        // Capture on is not rows arriving (F11): right under the count it
        // explains, and only while capture is on.
        if let delivery = status.delivery?.statusLine {
            lines.append(delivery)
        }
        // Worded as the certificate checks are (MCPSetupDiagnosis): since core
        // C7/C8 an HTTPS connection without a trusted CA is RELAYED — one
        // kind=relay row, no requests — not "requests without bodies" (S13).
        if let installed = status.caCertificateInstalled {
            lines.append("ReqRes CA installed: \(installed ? "yes" : "no — each HTTPS connection is relayed (one kind=relay row per connection, no requests) until it is installed and trusted")")
            if installed, status.caCertificateTrusted == false {
                lines.append("ReqRes CA trusted: no — each HTTPS connection is relayed (one kind=relay row per connection, no requests) until it is trusted")
            }
        }
        if !status.appVersion.isEmpty {
            lines.append("ReqRes version: \(status.appVersion)")
        }
        if status.extensionStatus != "ready" {
            lines.append("")
            lines.append("Setup is incomplete — a human must finish it in the ReqRes window: \(remediation(for: status.extensionStatus))")
        }
        return lines.joined(separator: "\n")
    }

    public static func remediation(for extensionStatus: String) -> String {
        switch extensionStatus {
        case "notInstalled":
            return "open ReqRes and choose “Install Network Extension”, then approve it in System Settings."
        case "extensionDisabled":
            return "enable ReqRes under System Settings → General → Login Items & Extensions → Network Extensions."
        case "configurationMissing":
            return "start monitoring once in ReqRes so it can install the VPN configuration."
        case "needsRestart":
            return "restart the ReqRes app (a system restart may be needed the first time)."
        default:
            return "check the ReqRes window for the current onboarding step."
        }
    }

    public static func page(_ page: MCPSessionPage) -> String {
        guard !page.sessions.isEmpty else {
            return "No captured sessions match. If you expected traffic, call capture_status — capture may be stopped or the CA may not be trusted."
        }
        var lines = page.sessions.map(row(_:))
        lines.append("")
        lines.append("\(page.sessions.count) of \(page.totalMatched) matching sessions.")
        if let note = page.note {
            lines.append(note)
        }
        return lines.joined(separator: "\n")
    }

    public static func row(_ session: MCPSessionSummary) -> String {
        if session.isRelay { return relayRow(session) }
        var parts = [
            session.statusCode.map(String.init) ?? "—",
            session.method.uppercased(),
            session.url,
        ]
        if let duration = session.durationMs {
            parts.append("\(Int(duration.rounded()))ms")
        }
        if let origin = origin(of: session) {
            parts.append(origin)
        }
        if let country = session.country, !country.isEmpty {
            parts.append("country=\(country)")
        }
        if let grpc = session.grpcStatus {
            // Always stated for an RPC row: a gRPC-Web error is an HTTP 200.
            parts.append("grpc=\(RPCStatusCode.name(grpc) ?? String(grpc))")
        }
        if let proto = session.sessionProtocol {
            // What the exchange spoke (doc §S9) — the token `proto=` filters on.
            parts.append("proto=\(proto.token)")
        }
        if let facts = session.failureFacts {
            parts.append(FailureRowCopy.agentToken(facts))
        }
        if let live = session.live {
            parts.append(LiveRowCopy.agentToken(live))
        }
        parts.append("uid=\(session.uid)")
        return parts.joined(separator: "  ")
    }

    /// A relayed connection reads as a connection: its endpoint, that it was
    /// not decrypted, the bytes each way and how long it was open — never a
    /// method or a status it does not have (the core records `CONNECT` and
    /// no status for it). `kind=relay` is the token an agent can match on.
    static func relayRow(_ session: MCPSessionSummary) -> String {
        var parts = [
            "—",
            RecordedExchangeCopy.relayEndpoint(host: session.host),
            "(\(RecordedExchangeCopy.relayRowWord(scheme: session.scheme, pinnedBy: session.pinnedBy, appName: session.app)))",
            RecordedExchangeCopy.agentRelayBytes(
                sent: Int64(session.requestBodySize ?? 0),
                received: Int64(session.responseBodySize ?? 0)
            ),
        ]
        if let duration = session.durationMs {
            parts.append("\(Int(duration.rounded()))ms")
        }
        if let origin = origin(of: session) {
            parts.append(origin)
        }
        if let country = session.country, !country.isEmpty {
            parts.append("country=\(country)")
        }
        parts.append("kind=relay")
        if let facts = session.failureFacts {
            parts.append(FailureRowCopy.agentToken(facts))
        }
        if let live = session.live {
            parts.append(LiveRowCopy.agentToken(live))
        }
        parts.append("uid=\(session.uid)")
        return parts.joined(separator: "  ")
    }

    /// `app=curl pid=123` — the process that made the request, when the
    /// capture layer attributed it. Nothing when it did not: an unattributed
    /// row says nothing rather than "unknown", because in a list every
    /// unattributed row would otherwise carry the same word.
    static func origin(of session: MCPSessionSummary) -> String? {
        var parts: [String] = []
        if let app = session.app, !app.isEmpty { parts.append("app=\(app)") }
        if let pid = session.pid { parts.append("pid=\(pid)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// `104.18.32.7 (Germany)` — the address the proxy connected to and where
    /// it resolved, when the detail has an address. A country with no address
    /// (a summary filled by an adapter that resolved but did not pass the
    /// raw address) prints as `Destination: Germany` by the caller's choice;
    /// here the address is the fact and the country its annotation.
    static func server(of detail: MCPSessionDetail) -> String? {
        guard let address = detail.serverAddress?.trimmingCharacters(in: .whitespaces), !address.isEmpty else { return nil }
        guard let country = detail.summary.country, let destination = TrafficDestination.parseToken(country) else {
            return address
        }
        return "\(address) (\(CountryPresentation.title(for: destination, locale: MCPDestinationAggregation.reportLocale)))"
    }

    // MARK: Destinations

    /// Where the traffic went (destination-map UX spec §8.3). One row per
    /// destination, aligned so an agent can read it as a table; the Unknown
    /// row carries its reason instead of a host list; the last line says how
    /// to drill in. `filterDescription` is the filter as the agent sent it
    /// (`MCPSessionFilter.summaryText`), echoed so a report for `app=claude`
    /// cannot be mistaken for one about all traffic.
    public static func destinations(_ report: MCPDestinationsReport, filterDescription: String? = nil) -> String {
        let text = destinationsBody(report, filterDescription: filterDescription)
        guard let skipped = report.neverConnected, skipped > 0 else { return text }
        return text + "\n" + FailureRowCopy.neverConnectedNote(skipped) + " list_sessions outcome=failed lists them."
    }

    private static func destinationsBody(_ report: MCPDestinationsReport, filterDescription: String?) -> String {
        let scope = filterDescription.map { "country level, offline lookup; \($0)" } ?? "country level, offline lookup"
        guard !report.destinations.isEmpty else {
            var lines = ["No captured requests match" + (filterDescription.map { " \($0)" } ?? "") + "."]
            lines.append("If you expected traffic, call capture_status — capture may be stopped or the CA may not be trusted.")
            return lines.joined(separator: "\n")
        }
        let locale = MCPDestinationAggregation.reportLocale
        var lines = ["Where \(CountryPresentation.plural(report.totalRequests, "captured request", locale: locale)) went (\(scope)):"]

        // One destination asked for by country= : its fuller lists, as lines.
        // The filter description is `MCPSessionFilter.summaryText`, a
        // comma-separated `key=value` list, so the check is on a component,
        // not a substring — `url_contains=country=x` must not trip it.
        if report.destinations.count == 1, describesOneCountry(filterDescription) {
            let row = report.destinations[0]
            lines.append(summaryLine(row, locale: locale))
            lines.append("Hosts: " + counted(row.topHosts, locale: locale))
            lines.append("Apps: " + counted(row.topApps, locale: locale))
            lines.append("Filter list_sessions or wait_for_session with country=\(row.country) for the requests behind these. \(report.note)")
            return lines.joined(separator: "\n")
        }

        let cells = report.destinations.map { row -> [String] in
            [
                row.country,
                row.name,
                CountryPresentation.plural(row.requests, "request", locale: locale),
                DestinationCopy.bytes(row.bytes),
                CountryPresentation.plural(row.hostCount, "host", locale: locale),
                CountryPresentation.plural(row.appCount, "app", locale: locale),
            ]
        }
        let widths = (0..<6).map { column in cells.map { $0[column].count }.max() ?? 0 }
        for (row, columns) in zip(report.destinations, cells) {
            var line = columns[0].padding(toLength: max(widths[0], 7), withPad: " ", startingAt: 0) + "  "
            line += columns[1].padding(toLength: widths[1], withPad: " ", startingAt: 0) + "  "
            line += leftPad(columns[2], to: widths[2]) + "  "
            line += leftPad(columns[3], to: widths[3]) + "  "
            line += leftPad(columns[4], to: widths[4]) + "  "
            line += columns[5].padding(toLength: widths[5], withPad: " ", startingAt: 0) + "  "
            if row.country == TrafficDestination.unknownToken {
                line += "— \(DestinationCopy.agentUnknownNote)"
            } else {
                line += "top: " + counted(row.topHosts, locale: locale)
            }
            lines.append(line)
        }

        let first = report.destinations.first { $0.country != TrafficDestination.unknownToken }?.country ?? report.destinations[0].country
        let second = report.destinations.dropFirst().first { $0.country != TrafficDestination.unknownToken && $0.country != first }?.country ?? first
        lines.append(
            "Filter list_sessions or wait_for_session with country=\(first) (or \(TrafficDestination.specialTokens.joined(separator: ", "))) for the requests behind a row; "
                + "pass country=\(second) here for its full host and app lists. \(report.note)"
        )
        return lines.joined(separator: "\n")
    }

    /// Whether the echoed filter carries a `country=` component of its own.
    static func describesOneCountry(_ filterDescription: String?) -> Bool {
        guard let filterDescription else { return false }
        return filterDescription
            .components(separatedBy: ", ")
            .contains { $0.hasPrefix("country=") }
    }

    private static func summaryLine(_ row: MCPDestinationSummary, locale: Locale) -> String {
        [
            row.country,
            row.name,
            CountryPresentation.plural(row.requests, "request", locale: locale),
            DestinationCopy.bytes(row.bytes),
            CountryPresentation.plural(row.hostCount, "host", locale: locale),
            CountryPresentation.plural(row.appCount, "app", locale: locale),
        ].joined(separator: "  ")
    }

    private static func counted(_ names: [MCPCountedName], locale: Locale) -> String {
        guard !names.isEmpty else { return "—" }
        return names.map { "\($0.name) \(CountryPresentation.groupedDigits($0.requests, locale: locale))" }.joined(separator: ", ")
    }

    private static func leftPad(_ text: String, to width: Int) -> String {
        guard text.count < width else { return text }
        return String(repeating: " ", count: width - text.count) + text
    }

    /// Said when a wait ends empty-handed and failures were skipped: the
    /// request the human triggered may have FAILED, and a wait that never
    /// says so sends the agent looking for a capture problem instead.
    static let failuresSkippedNote = "Failed, aborted and timed-out requests were skipped — pass include_failed=true to wait for those too, or call list_sessions with outcome=failed."

    public static func waitOutcome(_ outcome: MCPSessionWaiter.Outcome, timeout: TimeInterval, includeFailed: Bool = false,
                                   until stage: MCPWaitStage = .complete) -> String {
        guard let session = outcome.session else {
            let reached: String
            switch stage {
            case .complete: reached = "arrived"
            case .headers: reached = "got its response headers"
            case .firstMessage: reached = "got its first complete message"
            }
            var text = "No matching request \(reached) within \(Int(timeout))s. Capture may be stopped (call capture_status), the filter may be too narrow, or the action was not performed."
            if !includeFailed { text += " " + failuresSkippedNote }
            return text
        }
        var text = "Captured:\n\(row(session))"
        if let live = session.live, live.isInFlight {
            // until=headers or first_message: say plainly it is not over.
            text += "\n" + LiveRowCopy.agentDetailLine(live)
        }
        if let facts = session.failureFacts {
            // Only reachable when the agent asked for failures; the sentence
            // saves it a get_session to learn why.
            text += "\n" + FailureRowCopy.agentOutcomeLine(facts)
        }
        return text + "\n\nUse get_session or query_session_body with uid=\(session.uid) for detail."
    }

    public static func detail(_ detail: MCPSessionDetail) -> String {
        let summary = detail.summary
        if summary.isRelay { return relayDetail(detail) }
        var lines = [
            "\(summary.method.uppercased()) \(summary.url)",
            "Status: \(summary.statusCode.map(String.init) ?? "—")   Host: \(summary.host)   Scheme: \(summary.scheme)",
        ]
        if let grpc = summary.grpcStatus {
            // A gRPC-Web error is an HTTP 200: the RPC's own status is the answer.
            lines.append("RPC status: \(RPCStatusCode.displayName(grpc)) (\(grpc)) — get_session view=rpc decodes the messages")
        }
        if let protocolLine = protocolLine(summary) {
            lines.append(protocolLine)
        }
        if let started = summary.startedAt {
            lines.append("Started: \(ISO8601DateFormatter().string(from: started))")
        }
        if let duration = summary.durationMs {
            lines.append("Duration: \(Int(duration.rounded()))ms")
        }
        if let origin = origin(of: summary) {
            lines.append("Origin: \(origin)")
        }
        if let server = server(of: detail) {
            lines.append("Server: \(server)")
        }
        if let connection = connection(of: detail) {
            lines.append("Connection: \(connection)")
        }
        if let facts = summary.failureFacts {
            lines.append(FailureRowCopy.agentOutcomeLine(facts))
        }
        if let live = summary.live {
            lines.append(LiveRowCopy.agentDetailLine(live))
        }
        lines.append(contentsOf: headerSection("Request headers", detail.requestHeaders))
        lines.append(contentsOf: bodySection("Request body", detail.requestBodyPreview, truncated: detail.requestBodyTruncated,
                                             notRetained: detail.notRetainedBytes(.request)))
        // Sent after the body (core C13), so printed after it.
        lines.append(contentsOf: headerSection("Request trailers (sent after the body)", detail.requestTrailers ?? [:]))
        lines.append(contentsOf: headerSection("Response headers", detail.responseHeaders))
        lines.append(contentsOf: bodySection("Response body", detail.responseBodyPreview, truncated: detail.responseBodyTruncated,
                                             notRetained: detail.notRetainedBytes(.response)))
        lines.append(contentsOf: headerSection("Response trailers (sent after the body)", detail.responseTrailers ?? [:]))
        if let curl = detail.curl {
            lines.append("")
            lines.append("cURL: \(curl)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Write surface

    public static func hosts(_ hosts: [MCPHost]) -> String {
        guard !hosts.isEmpty else {
            return "No host filters. Traffic is captured for every host regardless; add_host adds a sidebar filter (and a scope for rules)."
        }
        return hosts.map { "#\($0.id)  \($0.scheme)://\($0.host)" + ($0.port == 80 || $0.port == 443 ? "" : ":\($0.port)") }
            .joined(separator: "\n")
    }

    public static func rules(_ rules: [MCPRule]) -> String {
        guard !rules.isEmpty else { return "No rules." }
        return rules.map(ruleRow).joined(separator: "\n")
    }

    public static func ruleRow(_ rule: MCPRule) -> String {
        var parts = [
            "#\(rule.id)",
            rule.enabled ? "on " : "off",
            rule.mode.rawValue,
            "\(RuleMethod.displayName(rule.method)) \(rule.scheme)://\(rule.host ?? "?")\(rule.path)",
        ]
        switch rule.mode {
        case .mapLocal: parts.append("→ \(rule.localFilePath.map { ($0 as NSString).lastPathComponent } ?? "file")")
        case .override, .extend:
            // What the response gets, as the core decides it: "server's
            // status" where the rule keeps it (stored 0), never "→ 0".
            let hasBody = !(rule.responseBody ?? "").isEmpty
            parts.append("→ \(RuleResponseDefaults.statusText(rule.responseStatus, mode: rule.mode, hasBody: hasBody) ?? "\(rule.responseStatus)")")
        }
        parts.append("[\(rule.matchType.rawValue)]")
        return parts.joined(separator: "  ")
    }

    public static func rule(_ rule: MCPRule) -> String {
        var lines = [ruleRow(rule)]
        if !rule.requestHeaders.isEmpty {
            lines.append("Request headers: " + rule.requestHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
        }
        if !rule.responseHeaders.isEmpty {
            lines.append("Response headers: " + rule.responseHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
        }
        if let body = rule.responseBody, !body.isEmpty {
            lines.append("Response body (\(body.utf8.count) bytes): \(body.count > 400 ? String(body.prefix(400)) + "…" : body)")
        }
        if let path = rule.localFilePath { lines.append("File: \(path)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Saved sessions

    public static func savedSessions(_ page: MCPSavedSessionPage) -> String {
        guard !page.saved.isEmpty else {
            return "Nothing is saved. save_session uid=… keeps a captured session past the end of the run; everything else is dropped when capture stops."
        }
        var lines = page.saved.map(savedRow)
        lines.append("")
        // An agent that asked for 30 of 400 must not report "you have 30".
        lines.append(page.saved.count == page.totalCount
            ? "\(page.totalCount) saved."
            : "\(page.saved.count) of \(page.totalCount) saved — ask for a larger limit to see more.")
        return lines.joined(separator: "\n")
    }

    /// Leads with the id, because that is the handle every other saved-session
    /// tool takes — the uid these were captured under is gone with the run.
    public static func savedRow(_ saved: MCPSavedSessionSummary) -> String {
        var parts = [
            "#\(saved.id)",
            saved.session.statusCode.map(String.init) ?? "—",
            saved.session.method.uppercased(),
            saved.session.url,
            "saved \(ISO8601DateFormatter().string(from: saved.savedAt))",
        ]
        if let note = saved.note, !note.isEmpty {
            parts.append("note: \(note)")
        }
        return parts.joined(separator: "  ")
    }

    public static func savedSession(_ saved: MCPSavedSession) -> String {
        var lines = ["Saved session #\(saved.id), kept \(ISO8601DateFormatter().string(from: saved.savedAt))"]
        if let note = saved.note, !note.isEmpty {
            lines.append("Note: \(note)")
        }
        lines.append("")
        lines.append(detail(saved.session))
        return lines.joined(separator: "\n")
    }

    // MARK: Replay

    /// What an agent needs after a replay, in this order: how it was sent
    /// (because that decides whether rules applied and whether it was
    /// recorded), then the exchange itself.
    ///
    /// The route line is not a footnote. An agent that replays with capture
    /// stopped, sees its mock not apply and reports "the rule is broken" has
    /// sent the user chasing the wrong thing; that is the single most likely
    /// way this tool misleads someone.
    public static func replay(_ result: MCPReplayResult) -> String {
        var lines: [String]
        switch result.route {
        case .proxy:
            lines = ["Replayed through ReqRes's proxy, so the user's rules applied to it and it appears in the traffic list as a new session."]
        case .direct:
            lines = ["Replayed DIRECTLY — capture is not running, so ReqRes had no proxy to send it through. No rule applied to it and it was NOT captured. Call start_capture first if you are testing a rule."]
        case .relayedWithoutCertificate:
            lines = ["Replayed through ReqRes's proxy, but RELAYED without decrypting it: the ReqRes CA is not installed and trusted, so ReqRes reads no HTTPS. The answer below is the real server's, NO rule applied to it, and only a connection row (kind=relay: endpoint and bytes) was recorded. Ask the user to install and trust the CA in ReqRes ▸ Settings ▸ Certificate before testing a rule (diagnose_setup names the missing step)."]
        case .relayedExcluded:
            lines = ["Replayed through ReqRes's proxy, but its host is on the exclusion list in Settings ▸ Capture, so it was relayed untouched: the answer below is the real server's, NO rule applied to it, and nothing was recorded. The user would have to take the host off that list for a rule to apply."]
        }
        lines.append("Replayed from the captured session \(result.replayedFrom).")
        if result.redacted {
            lines.append("The request went out with its real values; what you are reading below is redacted, so a token here is a placeholder.")
        }
        lines.append("")
        lines.append(detail(result.session))
        return lines.joined(separator: "\n")
    }

    // MARK: - Breakpoints

    /// What is held, and — when nothing is — why not.
    ///
    /// An empty list is the common case and the one where a bare "none" wastes
    /// a turn: the agent's user asks "why didn't it stop?", and the answer is
    /// almost always that no rule is armed. So the reason travels with the
    /// emptiness.
    public static func pausedRequests(_ page: MCPPausedRequestPage) -> String {
        guard !page.requests.isEmpty else {
            if page.armedRules == 0 {
                return "No requests are held, and no breakpoint is armed — nothing will be held until the user adds one in ReqRes → Settings → Breakpoints."
            }
            return "No requests are held right now. \(page.armedRules) breakpoint rule(s) are armed, so the next matching request will stop and appear here."
        }
        var lines = ["\(page.requests.count) request(s) held, least time left first:"]
        if !page.agentDecisionsEnabled {
            lines.append("You can READ these but not answer them: the user has not allowed agents to answer held requests (Settings → Breakpoints). Tell them what you would do and let them click.")
        }
        for request in page.requests {
            lines.append("")
            lines.append("[\(request.id)] \(request.method) \(request.url) — \(request.secondsRemaining)s left")
            for header in request.headers {
                lines.append("  \(header.name): \(header.value)")
            }
            // Always a body line (F19). The core holds a request at its head
            // and reports no body, and a request printed without one read as
            // a request that has none — so the line says what the request's
            // head declares (the core's reading of it first), and what
            // resuming without `body` does: sends it unchanged, or, for a
            // TRACE carrying a body, gets ReqRes's 502 over HTTP/1.1.
            let body = HeldRequestBody(request)
            for line in body.agentLines {
                lines.append("  " + line.replacingOccurrences(of: "\n", with: "\n  "))
            }
        }
        lines.append("")
        lines.append("Answer one with answer_paused_request before its seconds run out; an unanswered request is resumed untouched.")
        return lines.joined(separator: "\n")
    }

    public static func decision(_ outcome: MCPBreakpointOutcome) -> String {
        outcome.summary
    }

    /// `exclude_host`'s answer: what changed (or that nothing did) and the
    /// consequence the agent must now reckon with — the host is gone from
    /// ITS view too.
    public static func exclusion(_ result: MCPExclusionResult) -> String {
        if result.alreadyExcluded {
            return "\(result.host) is already excluded — nothing changed and no one was asked. Excluded: \(result.excludedHosts.joined(separator: ", "))."
        }
        return "Excluded \(result.host): ReqRes stops recording it, so its traffic no longer appears for the user or for you. It applies to HTTPS connections opened from now on and to plain http:// from the next request; the user puts it back in Settings ▸ Capture. Excluded: \(result.excludedHosts.joined(separator: ", "))."
    }

    public static func patternTest(_ result: MCPPatternTestResult) -> String {
        let verdict = result.matches ? "MATCHES" : "does NOT match"
        return """
        \(verdict): a \(result.matchType.rawValue) rule with path '\(result.path)' against \(result.url)
        The proxy compiles: \(result.proxyPattern)
        """
    }

    /// `Protocol: HTTP/2 (proto=h2, httpVersion HTTP/2.0)` — what the row
    /// spoke and the version it recorded; nil when it recorded neither.
    static func protocolLine(_ summary: MCPSessionSummary) -> String? {
        guard let proto = summary.sessionProtocol else {
            guard let version = summary.httpVersion, !version.isEmpty else { return nil }
            return "Protocol: httpVersion \(version)"
        }
        let label = SessionProtocolPresentation.label(httpVersion: summary.httpVersion, isRelay: proto == .relay, isWebSocket: proto == .webSocket)
        var inner = "proto=\(proto.token)"
        if let version = summary.httpVersion, !version.isEmpty { inner += ", httpVersion \(version)" }
        return "Protocol: \(label) (\(inner))"
    }

    /// `reused — request 3 on it (…)` or `new — request 1 on it`; nil when
    /// the app predates the fields (an older app never said, so neither do
    /// we). A reused exchange had no DNS/TCP/TLS of its own, which is the
    /// question an agent looking at its timings is about to ask.
    static func connection(of detail: MCPSessionDetail) -> String? {
        guard detail.connectionReused != nil || detail.exchangeIndex != nil else { return nil }
        let reused = detail.connectionReused ?? false
        let index = max(0, detail.exchangeIndex ?? 0)
        if reused || index > 0 {
            return "reused — request \(index + 1) on it (no DNS, TCP or TLS of its own)"
        }
        return "new — request 1 on it"
    }

    /// A relayed connection's detail: what it was, why there is nothing
    /// inside it, and the facts the core did record.
    static func relayDetail(_ detail: MCPSessionDetail) -> String {
        let summary = detail.summary
        var lines = [
            "Relayed connection \(RecordedExchangeCopy.relayEndpoint(host: summary.host)) — kind=relay",
            RecordedExchangeCopy.relayExplanation(scheme: summary.scheme, pinnedBy: summary.pinnedBy, appName: summary.app),
            "Traffic: " + RecordedExchangeCopy.agentRelayBytes(
                sent: Int64(summary.requestBodySize ?? 0),
                received: Int64(summary.responseBodySize ?? 0)
            ),
        ]
        if let started = summary.startedAt {
            lines.append("Opened: \(ISO8601DateFormatter().string(from: started))")
        }
        if let duration = summary.durationMs {
            lines.append("Open for: \(Int(duration.rounded()))ms")
        }
        if let origin = origin(of: summary) {
            lines.append("Origin: \(origin)")
        }
        if let server = server(of: detail) {
            lines.append("Server: \(server)")
        }
        if let facts = summary.failureFacts {
            lines.append(FailureRowCopy.agentOutcomeLine(facts))
        }
        lines.append("To see the requests inside connections like this, the user installs and trusts the ReqRes CA (Settings ▸ Certificate); connections opened after that are decrypted without restarting capture — diagnose_setup reports that state.")
        return lines.joined(separator: "\n")
    }

    private static func headerSection(_ title: String, _ headers: [String: String]) -> [String] {
        guard !headers.isEmpty else { return [] }
        return ["", "\(title):"] + MCPRecordedHeaders.displayLines(headers).map { "  \($0)" }
    }

    private static func bodySection(_ title: String, _ body: String?, truncated: Bool, notRetained: Int64 = 0) -> [String] {
        let retentionNote = RecordedExchangeCopy.agentNotRetainedNote(notRetained: notRetained)
        guard let body, !body.isEmpty else {
            // A body the capture kept NOTHING of is still a body that existed.
            guard let retentionNote else { return [] }
            return ["", "\(title): none kept", retentionNote]
        }
        var lines = ["", "\(title):", body]
        if truncated {
            // Two different cuts. The preview cap is this text's; the app
            // holds the rest of what it KEPT. But when the capture itself kept
            // only a prefix (a body over 16 MB always is over the preview cap
            // too), "open it in ReqRes for the full body" sends the agent to
            // look for bytes the app never had — the retention note below says
            // that, and the two must not contradict each other.
            lines.append(retentionNote == nil
                ? "(truncated — open the session in ReqRes for the full body)"
                : "(this preview stops at \(RecordedExchangeCopy.binaryBytes(Int64(MCPLimits.bodyPreviewMaxBytes))); query_session_body reads the rest of what was kept)")
        }
        if let retentionNote {
            lines.append(retentionNote)
        }
        return lines
    }

    /// `query_session_body`'s answer: the query's text, and — when the capture
    /// kept only part of the body — the fact that the answer is about a prefix.
    /// A missing key in a structure, or a path reported absent, may be missing
    /// only because it was never kept.
    public static func bodyQuery(_ result: MCPBodyQueryResult) -> String {
        guard let note = RecordedExchangeCopy.agentNotRetainedNote(notRetained: result.notRetainedBytes ?? 0) else {
            return result.text
        }
        return result.text + "\n" + note + " A key or path reported missing may simply not have been kept."
    }
}

// MARK: - Streams (get_session view=events|assembled, protocol-engine doc §S5)

extension MCPTextFormat {
    /// The facts every stream answer opens with.
    static func streamFactLines(_ facts: MCPStreamFacts) -> [String] {
        var head = [facts.provider?.displayName ?? facts.format.displayName,
                    StreamEventsPresentation.count(facts.totalEvents, "event")]
        if let first = facts.timeToFirstEventMs {
            head.append("first event +\(StreamEventsPresentation.milliseconds(first))")
            if let gap = facts.longestGapMs, let after = facts.longestGapAfterEvent {
                head.append("longest gap \(StreamEventsPresentation.milliseconds(gap)) after #\(after)")
            }
        } else {
            if let duration = facts.responseDurationMs {
                head.append("streamed for \(StreamEventsPresentation.milliseconds(duration))")
            }
            head.append(facts.inFlight == true
                ? "still streaming — the complete events so far"
                : "arrival times not recorded (the stream reached the app as one finished body)")
        }
        var lines = ["Stream \(facts.uid): " + head.joined(separator: " · ")]
        if facts.pendingBytes > 0 {
            lines.append("Pending: \(MCPStreamEgress.pendingNote(facts.pendingBytes, format: facts.format)).")
        }
        if facts.notRetainedBytes > 0 {
            lines.append("Not kept: the capture kept only part of this body; \(RecordedExchangeCopy.binaryBytes(facts.notRetainedBytes)) more were sent, so the stream ends early here.")
        }
        return lines
    }

    public static func streamEvents(_ page: MCPStreamEventsPage) -> String {
        var lines = streamFactLines(page.facts)
        if page.withheldDeltaEvents > 0 {
            lines.append("Withheld: the delta of \(StreamEventsPresentation.count(page.withheldDeltaEvents, "event")) is masked — the text those deltas assemble holds a credential-shaped value. view=assembled shows it redacted.")
        }
        guard !page.events.isEmpty else {
            lines.append(page.facts.totalEvents == 0 ? "No complete events." : "No events from there; the stream has \(page.facts.totalEvents).")
            return lines.joined(separator: "\n")
        }
        lines.append("")
        for event in page.events {
            var head = "#\(event.number) \(event.name ?? (page.facts.format == .sse ? "message" : "line"))"
            if let at = event.atMs { head += " +\(StreamEventsPresentation.milliseconds(at))" }
            if let id = event.id { head += " id=\(id)" }
            if let retry = event.retry { head += " retry=\(retry)" }
            if event.deltaWithheld { head += " (delta withheld)" }
            lines.append(head)
            lines.append("  " + event.data)
        }
        if let next = page.nextFrom {
            lines.append("")
            lines.append("More: call get_session with view=events and from=\(next).")
        }
        return lines.joined(separator: "\n")
    }

    public static func streamAssembled(_ assembled: MCPStreamAssembled) -> String {
        var lines = streamFactLines(assembled.facts)
        guard let provider = assembled.facts.provider else {
            lines.append("Not a recognised LLM stream (Anthropic Messages, OpenAI Chat Completions, OpenAI Responses). Read the raw events with view=events.")
            return lines.joined(separator: "\n")
        }
        var summary = [provider.displayName]
        if let model = assembled.model { summary.append("model \(model)") }
        if let reason = assembled.stopReason { summary.append("stop: \(reason)") }
        summary.append(assembled.completed ? "complete" : assembled.facts.inFlight == true ? "still streaming" : "ended without its end marker")
        lines.append(summary.joined(separator: " · "))
        if let usage = assembled.usage, !usage.isEmpty {
            var parts: [String] = []
            if let v = usage.inputTokens { parts.append("input \(v)") }
            if let v = usage.outputTokens { parts.append("output \(v)") }
            if let v = usage.cacheReadInputTokens { parts.append("cache read \(v)") }
            if let v = usage.cacheCreationInputTokens { parts.append("cache write \(v)") }
            if let v = usage.reasoningTokens { parts.append("reasoning \(v)") }
            if let v = usage.totalTokens { parts.append("total \(v)") }
            lines.append("Usage: " + parts.joined(separator: " · "))
        }
        if let error = assembled.error {
            let name = [error.type, error.code].compactMap { $0 }.joined(separator: " / ")
            lines.append("Error (event #\(error.eventNumber)): \(name.isEmpty ? "error" : name)\(error.message.map { " — \($0)" } ?? "")")
        }
        if assembled.unrecognizedEvents > 0 {
            lines.append("Unrecognised: \(StreamEventsPresentation.count(assembled.unrecognizedEvents, "event")) not assembled (view=events shows them).")
        }
        if let text = assembled.text {
            lines.append("")
            lines.append("Text\(assembled.textTruncated ? " (truncated)" : ""):")
            lines.append(text)
        }
        for block in assembled.blocks where block.kind != .text {
            lines.append("")
            switch block.kind {
            case .toolCall:
                let who = [block.name, block.id].compactMap { $0 }.joined(separator: " ")
                lines.append("Tool call\(who.isEmpty ? "" : " \(who)")\(block.argumentsAreJSON == false ? " (arguments incomplete)" : ""):")
            case .thinking:
                lines.append("Thinking:")
            case .refusal:
                lines.append("Refusal:")
            case .text:
                break
            }
            lines.append(block.content)
        }
        return lines.joined(separator: "\n")
    }
}
