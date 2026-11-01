//
//  MCPSetupDiagnosis.swift
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
//  Roadmap item 6: why is nothing being captured?
//
//  The product's whole agent-facing claim is that an assistant can work
//  without the GUI, and the single state it could not reason about was its own
//  capture being broken — `capture_status` reports fields, which leaves the
//  agent to guess which combination means "the user has to approve the
//  extension" versus "the tunnel is up but the proxy never bound its port".
//
//  Two rules shape everything below. First, the ORDER is causal, not
//  cosmetic: an app outside /Applications cannot activate its extension, an
//  extension that is not approved cannot start a tunnel, a tunnel that never
//  started cannot bind a port. Reporting the last of those as "the problem"
//  sends the agent and the user chasing a symptom. Second, every failure names
//  what the HUMAN does next, because none of these can be fixed by an agent:
//  they are System Settings approvals, keychain trust and a licence.
//

import Foundation

/// What the app can observe about its own setup. Assembled by the app, which
/// is the only side that can see the keychain, the bundle path or the socket.
public struct MCPSetupFacts: Codable, Equatable, Sendable {
    public var status: MCPBridgeStatus
    /// The system extension refuses to activate from anywhere else. Nil when
    /// the app could not determine its own location.
    public var runningFromApplications: Bool?
    public var proxyPort: Int
    /// Whether anything is actually accepting connections on `proxyPort`.
    /// Nil when unchecked — never assumed from the tunnel's own status, which
    /// is exactly the pair that used to disagree (a tunnel reported started
    /// with no proxy behind it).
    public var proxyPortListening: Bool?
    public var freeInspectionsUsed: Int?
    public var freeInspectionsLimit: Int?
    public var licensed: Bool?
    public var lastSessionAt: Date?
    /// Whether the extension can read which process owns a connection (UX
    /// spec §9.1). It checks the kernel's socket table against its own socket
    /// once per tunnel start and reports the answer over the bus; nil means
    /// it has not reported — at launch, and whenever the tunnel is stopped.
    /// The app sets this from `AppState.processAttribution`.
    public var processAttribution: Bool?
    /// Whether the offline IP → country table loaded (destination-map UX
    /// spec §8.5). Nil when the app has not asked its resolver.
    public var destinationTableLoaded: Bool?
    /// Retained sessions placed in a country.
    public var destinationsPlaceable: Int?
    /// Retained sessions whose `remoteAddress` is nil — every one of them
    /// when the running extension predates the field.
    public var destinationsWithoutAddress: Int?
    /// Rows in this run where an APP refused ReqRes's certificate (failed,
    /// phase `tlsClient` — the pinning case), grouped per host and process.
    /// Nil when the app did not count; empty when there were none.
    public var tlsRejections: [MCPTLSRejection]?
    /// The user's HTTP/2 capture setting (Settings ▸ Capture, decision D11 —
    /// off by default). Nil when the app did not say (then the check is
    /// skipped rather than guessed). The initializer's `nil` argument means
    /// "take `status.http2CaptureEnabled`", not "skip" — to skip the check,
    /// leave both unset.
    public var http2CaptureEnabled: Bool?
    /// Injected so "nothing for a while" is testable without waiting.
    public var now: Date

    public init(
        status: MCPBridgeStatus,
        runningFromApplications: Bool? = nil,
        proxyPort: Int,
        proxyPortListening: Bool? = nil,
        freeInspectionsUsed: Int? = nil,
        freeInspectionsLimit: Int? = nil,
        licensed: Bool? = nil,
        lastSessionAt: Date? = nil,
        processAttribution: Bool? = nil,
        destinationTableLoaded: Bool? = nil,
        destinationsPlaceable: Int? = nil,
        destinationsWithoutAddress: Int? = nil,
        tlsRejections: [MCPTLSRejection]? = nil,
        http2CaptureEnabled: Bool? = nil,
        now: Date = Date()
    ) {
        self.status = status
        self.runningFromApplications = runningFromApplications
        self.proxyPort = proxyPort
        self.proxyPortListening = proxyPortListening
        self.freeInspectionsUsed = freeInspectionsUsed
        self.freeInspectionsLimit = freeInspectionsLimit
        self.licensed = licensed
        self.lastSessionAt = lastSessionAt
        self.processAttribution = processAttribution
        self.destinationTableLoaded = destinationTableLoaded
        self.destinationsPlaceable = destinationsPlaceable
        self.destinationsWithoutAddress = destinationsWithoutAddress
        self.tlsRejections = tlsRejections
        // The app reports the setting on the status too (capture_status's
        // protocol list, doc §S13); one read serves both when none is given.
        self.http2CaptureEnabled = http2CaptureEnabled ?? status.http2CaptureEnabled
        self.now = now
    }
}

/// One host an app refused ReqRes's certificate for, and how often.
public struct MCPTLSRejection: Codable, Equatable, Sendable {
    public var host: String
    /// The process's display name; nil when attribution had none.
    public var app: String?
    /// Rows the core wrote (it coalesces refusals per host and process per
    /// 30 s, so this counts episodes, not handshakes).
    public var count: Int
    public var lastAt: Date?

    public init(host: String, app: String? = nil, count: Int, lastAt: Date? = nil) {
        self.host = host
        self.app = app
        self.count = count
        self.lastAt = lastAt
    }

    /// Groups rows into rejections per (host, app), busiest first, then most
    /// recent, then by host — a dictionary's order is not one.
    public static func group(_ rows: [(host: String, app: String?, at: Date?)]) -> [MCPTLSRejection] {
        struct Key: Hashable { let host: String; let app: String? }
        var grouped: [Key: MCPTLSRejection] = [:]
        for row in rows {
            let host = row.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { continue }
            let key = Key(host: host.lowercased(), app: row.app)
            var entry = grouped[key] ?? MCPTLSRejection(host: host, app: row.app, count: 0, lastAt: nil)
            entry.count += 1
            if let at = row.at, entry.lastAt.map({ at > $0 }) ?? true { entry.lastAt = at }
            grouped[key] = entry
        }
        return grouped.values.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.lastAt != rhs.lastAt { return (lhs.lastAt ?? .distantPast) > (rhs.lastAt ?? .distantPast) }
            return lhs.host < rhs.host
        }
    }
}

public struct MCPSetupCheck: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case ok
        /// Broken, and it stops capture from working.
        case problem
        /// Working, but worth saying — nothing captured yet, HTTPS bodies
        /// unreadable while HTTP still works.
        case warning
        /// The app could not tell. Never reported as ok: a check that did not
        /// run is not a check that passed.
        case unknown
    }

    public var id: String
    public var title: String
    public var state: State
    public var detail: String
    /// What the HUMAN does next. Nil when there is nothing to do.
    public var fix: String?

    public init(id: String, title: String, state: State, detail: String, fix: String? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.fix = fix
    }
}

public struct MCPSetupReport: Codable, Equatable, Sendable {
    /// One sentence: what is wrong, or that nothing is.
    public var verdict: String
    /// True when traffic should be arriving right now.
    public var capturing: Bool
    /// The id of the first thing to fix — the cause, not a symptom of it.
    public var blockingCheckId: String?
    public var checks: [MCPSetupCheck]

    public init(verdict: String, capturing: Bool, blockingCheckId: String?, checks: [MCPSetupCheck]) {
        self.verdict = verdict
        self.capturing = capturing
        self.blockingCheckId = blockingCheckId
        self.checks = checks
    }
}

public enum MCPSetupDiagnosis {
    /// How long without a captured session before the report mentions it.
    public static let quietPeriod: TimeInterval = 120

    public static func report(_ facts: MCPSetupFacts) -> MCPSetupReport {
        var checks = [
            location(facts),
            networkExtension(facts),
            tunnel(facts),
            proxy(facts),
            delivery(facts),
            certificateInstalled(facts),
            certificateTrusted(facts),
            certificateOutdated(facts),
            certificateExport(facts),
            freeLimit(facts),
            traffic(facts),
            tlsRejections(facts),
            // Informational, always `.ok` (protocol-engine doc §S10): what
            // this version captures, protocol by protocol. Before
            // attribution because the tests pin attribution → destinations →
            // the proxy-aware note as the tail.
            ProtocolSupport.diagnosisCheck(),
            attribution(facts),
            destinations(facts),
            http2(facts),
            proxyAwareClients(),
        ].compactMap { $0 }

        let blocking = checks.first { $0.state == .problem }
        // While something blocks capture, the protocol list shrinks to names
        // and status tokens (doc §S10): the full prose is ~2K tokens beside
        // the one check the agent has to act on.
        if blocking != nil, let index = checks.firstIndex(where: { $0.id == ProtocolSupport.diagnosisCheckId }) {
            checks[index] = ProtocolSupport.diagnosisCheck(compact: true, state: ProtocolSupportState(facts: facts))
        }
        let capturing = facts.status.captureActive && blocking == nil
        return MCPSetupReport(
            verdict: verdict(blocking: blocking, checks: checks, capturing: capturing),
            capturing: capturing,
            blockingCheckId: blocking?.id,
            checks: checks
        )
    }

    /// Checks that may warn but never become the verdict. The verdict is the
    /// menu bar's tooltip, and the menu bar never shows a hostname (it is the
    /// strip most visible in a screen share); an app refusing ReqRes's
    /// certificate is also not something wrong with capture, and pinning apps
    /// are common enough that it would stand in front of "set up correctly"
    /// on most healthy machines. The check itself stays in `checks`.
    /// `certificate_export` too: a stale exported file breaks only the
    /// command-line tools pointed at it, not capture.
    static let verdictExempt: Set<String> = ["tls_rejections", "certificate_export"]

    private static func verdict(blocking: MCPSetupCheck?, checks: [MCPSetupCheck], capturing: Bool) -> String {
        if let blocking {
            return "\(blocking.detail) \(blocking.fix ?? "")".trimmingCharacters(in: .whitespaces)
        }
        if let warning = checks.first(where: { $0.state == .warning && !verdictExempt.contains($0.id) }) {
            return warning.detail
        }
        if checks.contains(where: { $0.state == .unknown }) {
            return capturing
                ? "Capture is running. Some checks could not be made — see the list."
                : "Capture is not running, and some checks could not be made — see the list."
        }
        return capturing
            ? "Capture is running and set up correctly."
            : "Nothing is broken, but capture is stopped. Call start_capture."
    }

    // MARK: - Checks, in causal order

    private static func location(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        guard let inApplications = facts.runningFromApplications else {
            return MCPSetupCheck(
                id: "location", title: "App location", state: .unknown,
                detail: "Could not determine where ReqRes is running from."
            )
        }
        // Only a problem while the extension is NOT working: once it is
        // approved and running, where the app sits is history.
        guard !inApplications, facts.status.extensionStatus != "ready" else {
            return MCPSetupCheck(
                id: "location", title: "App location", state: .ok,
                detail: inApplications ? "ReqRes is in /Applications." : "ReqRes is not in /Applications, but its extension is already running."
            )
        }
        return MCPSetupCheck(
            id: "location", title: "App location", state: .problem,
            detail: "ReqRes is not running from /Applications, so macOS will not activate its network extension.",
            fix: "Ask the user to move ReqRes.app to /Applications and reopen it."
        )
    }

    private static func networkExtension(_ facts: MCPSetupFacts) -> MCPSetupCheck {
        switch facts.status.extensionStatus {
        case "ready":
            return MCPSetupCheck(id: "extension", title: "Network extension", state: .ok, detail: "The extension is installed and approved.")
        case "needsRestart":
            return MCPSetupCheck(
                id: "extension", title: "Network extension", state: .problem,
                detail: "The extension was updated; macOS loads the new one only after the Mac restarts.",
                fix: "Ask the user to restart the Mac — ReqRes's Restart Now button does it. Quitting and reopening ReqRes alone does not load the new extension."
            )
        case "extensionDisabled":
            return MCPSetupCheck(
                id: "extension", title: "Network extension", state: .problem,
                detail: "The extension is installed but switched off.",
                fix: "Ask the user to open System Settings ▸ General ▸ Login Items & Extensions, click the ⓘ next to Network Extensions, and switch ReqRes on. The toggle is behind that button, which is the step people miss."
            )
        case "configurationMissing":
            return MCPSetupCheck(
                id: "extension", title: "Network extension", state: .problem,
                detail: "macOS has no VPN configuration for ReqRes yet.",
                fix: "Ask the user to start capture in ReqRes and choose Allow when macOS asks to add a VPN configuration. No real VPN is involved — it is how traffic reaches the extension."
            )
        default:
            return MCPSetupCheck(
                id: "extension", title: "Network extension", state: .problem,
                detail: "The network extension is not installed, so nothing can be captured.",
                fix: "Ask the user to click the capture button in ReqRes and approve the extension in System Settings ▸ General ▸ Login Items & Extensions (the toggle is behind the ⓘ next to Network Extensions)."
            )
        }
    }

    private static func tunnel(_ facts: MCPSetupFacts) -> MCPSetupCheck {
        switch facts.status.vpnStatus {
        case "connected":
            return MCPSetupCheck(id: "tunnel", title: "Capture", state: .ok, detail: "Capture is on.")
        case "connecting", "reasserting", "disconnecting":
            return MCPSetupCheck(
                id: "tunnel", title: "Capture", state: .warning,
                detail: "Capture is \(facts.status.vpnStatus); ask again in a moment."
            )
        default:
            return MCPSetupCheck(
                id: "tunnel", title: "Capture", state: .problem,
                detail: "Capture is stopped, so no traffic is being recorded.",
                fix: "Call start_capture."
            )
        }
    }

    /// The pair that used to disagree: NetworkExtension was told the tunnel
    /// had started when the proxy had in fact failed to bind, so macOS and the
    /// app both showed "connected" with nothing behind them.
    private static func proxy(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        guard facts.status.vpnStatus == "connected" else { return nil }
        guard let listening = facts.proxyPortListening else {
            return MCPSetupCheck(
                id: "proxy", title: "Proxy port", state: .unknown,
                detail: "Could not check whether 127.0.0.1:\(facts.proxyPort) is accepting connections."
            )
        }
        guard listening else {
            return MCPSetupCheck(
                id: "proxy", title: "Proxy port", state: .problem,
                detail: "Capture says it is on, but nothing is listening on 127.0.0.1:\(facts.proxyPort) — the proxy could not bind its port.",
                fix: "Ask the user to stop capture, quit anything else using port \(facts.proxyPort), and start capture again."
            )
        }
        return MCPSetupCheck(id: "proxy", title: "Proxy port", state: .ok, detail: "The proxy is listening on 127.0.0.1:\(facts.proxyPort).")
    }

    /// Whether what capture records reaches the app (F11) — the step after
    /// the proxy in the causal chain: the proxy decrypts, then the extension
    /// has to deliver to the app. Capture on, the proxy listening, and still
    /// nothing in the list is what an app relaunched mid-capture looked like
    /// until build 53; now its extension reconnects by itself (a warning while
    /// it does), and the check is a problem only when it cannot. Omitted when
    /// the app did not say (an older app).
    private static func delivery(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        facts.status.delivery?.check()
    }

    private static func certificateInstalled(_ facts: MCPSetupFacts) -> MCPSetupCheck {
        guard let installed = facts.status.caCertificateInstalled else {
            return MCPSetupCheck(id: "certificate_installed", title: "ReqRes CA", state: .unknown, detail: "Could not read the keychain to see whether the CA certificate is installed.")
        }
        guard installed else {
            return MCPSetupCheck(
                id: "certificate_installed", title: "ReqRes CA", state: .warning,
                // Since core C7/C8 an HTTPS connection without the CA is
                // RELAYED: one kind=relay row per connection, no requests at
                // all — not "requests without bodies" (release review).
                detail: "The ReqRes CA certificate is not installed, so each HTTPS connection is relayed without decrypting it and listed as one kind=relay row (host, port, bytes each way) — no requests, URLs, headers or bodies. Plain HTTP is unaffected.",
                // The button labels are the modal's real ones (CACertificateModal:
                // "Install CA certificate", then "Trust"), so the agent reads out
                // what the user will actually see.
                fix: "Ask the user to open ReqRes ▸ Settings ▸ Certificate and click Install CA certificate, then Trust."
            )
        }
        return MCPSetupCheck(id: "certificate_installed", title: "ReqRes CA", state: .ok, detail: "The CA certificate is installed.")
    }

    private static func certificateTrusted(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        // Nothing to say about the trust of a certificate that is not there,
        // or that we could not look for.
        guard facts.status.caCertificateInstalled == true else { return nil }
        guard let trusted = facts.status.caCertificateTrusted else {
            return MCPSetupCheck(id: "certificate_trusted", title: "CA trust", state: .unknown, detail: "Could not read the certificate's trust setting.")
        }
        guard trusted else {
            return MCPSetupCheck(
                id: "certificate_trusted", title: "CA trust", state: .warning,
                detail: "The CA certificate is installed but not trusted, so each HTTPS connection is relayed without decrypting it and listed as one kind=relay row (host, port, bytes each way) — no requests, URLs, headers or bodies.",
                fix: "Ask the user to open ReqRes ▸ Settings ▸ Certificate and click Trust."
            )
        }
        return MCPSetupCheck(id: "certificate_trusted", title: "CA trust", state: .ok, detail: "The CA certificate is trusted.")
    }

    /// Whether HTTPS is decrypted on this Mac, read from the two certificate
    /// checks above rather than from the fields again: true when both are
    /// ok, false when either warns (not installed, installed but not
    /// trusted — every HTTPS connection is then relayed), nil when either
    /// could not tell. capture_status's protocol notes come from here
    /// (`ProtocolSupportState(facts:)`, doc §S13).
    public static func httpsDecrypted(_ facts: MCPSetupFacts) -> Bool? {
        switch certificateInstalled(facts).state {
        case .unknown: return nil
        case .warning, .problem: return false
        case .ok: break
        }
        switch certificateTrusted(facts)?.state {
        case .ok?: return true
        case .warning?, .problem?: return false
        case .unknown?, nil: return nil
        }
    }

    /// Whether the CA is installed, read from the `certificate_installed`
    /// check (ok → true, warning → false, unknown → nil). Only says which
    /// certificate step capture_status's https note names (doc §S13).
    public static func caInstalled(_ facts: MCPSetupFacts) -> Bool? {
        switch certificateInstalled(facts).state {
        case .ok: return true
        case .warning, .problem: return false
        case .unknown: return nil
        }
    }

    /// An older "ReqRes CA" still in the keychain (protocol PRD §1.11, 4
    /// Phase 2.1): the one every 1.0.x install shared — whose private key was
    /// in every public download — or an earlier install's. Omitted when there
    /// is none or the app did not look.
    private static func certificateOutdated(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        guard let count = facts.status.caOutdatedCertificatesInstalled, count > 0 else { return nil }
        return MCPSetupCheck(
            id: "certificate_outdated", title: "Older ReqRes CA", state: .warning,
            detail: count == 1
                ? "An older ReqRes CA certificate is still in the keychain. The one ReqRes 1.0.x installed was the same on every Mac and its private key was published with the app, so while it stays trusted, anyone holding that key who can intercept this Mac's traffic could impersonate any website to it."
                : "\(count) older ReqRes CA certificates are still in the keychain. The one ReqRes 1.0.x installed was the same on every Mac and its private key was published with the app, so while it stays trusted, anyone holding that key who can intercept this Mac's traffic could impersonate any website to it.",
            fix: "Ask the user to open ReqRes ▸ Settings ▸ Certificate and click \(MCPCaptureEnvironment.replaceOldCertificateButton)."
        )
    }

    /// A CA exported for command-line tools that is no longer this install's.
    /// Omitted unless it is known to be outdated.
    private static func certificateExport(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        guard facts.status.caExportedCertificateOutdated == true else { return nil }
        return MCPSetupCheck(
            id: "certificate_export", title: "Exported CA file", state: .warning,
            detail: "The CA file exported for command-line tools\(facts.status.caExportedPath.map { " (\($0))" } ?? "") holds an older ReqRes CA than the one this Mac now uses, so node, curl and other tools pointed at it fail TLS on every HTTPS request.",
            fix: "Ask the user to export it again from ReqRes ▸ Settings ▸ Capture (Export CA Certificate…), then call capture_environment."
        )
    }

    /// The free tier stops inspecting HTTPS after a fixed number of requests
    /// per run. Capture looks perfectly healthy while it happens, which makes
    /// it the most confusing state in the product.
    private static func freeLimit(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        guard facts.licensed != true, let used = facts.freeInspectionsUsed, let limit = facts.freeInspectionsLimit else { return nil }
        guard used >= limit else {
            return MCPSetupCheck(
                id: "free_limit", title: "Free-tier inspections", state: .ok,
                detail: "\(limit - used) of \(limit) free HTTPS inspections left in this run."
            )
        }
        return MCPSetupCheck(
            id: "free_limit", title: "Free-tier inspections", state: .warning,
            // FreeTier gates only the window's own detail pane: capture,
            // decryption, the traffic list and every agent read go on
            // unchanged (release review, 2026-09-29).
            detail: "The free version's \(limit) HTTPS inspections for this run are used up: the ReqRes window will not open more HTTPS request details until it is relaunched. Capture, the traffic list and agent reads (get_session included) are unaffected.",
            fix: "Only if the user wants to read HTTPS details in the ReqRes window: ask them to relaunch ReqRes for another \(limit), or to upgrade."
        )
    }

    private static func traffic(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        guard facts.status.vpnStatus == "connected" else { return nil }
        guard facts.status.sessionCount > 0 else {
            return MCPSetupCheck(
                id: "traffic", title: "Captured traffic", state: .warning,
                detail: "Capture is on but nothing has been recorded yet.",
                fix: "Ask the user to make a request from the app or browser they are debugging."
            )
        }
        if let last = facts.lastSessionAt, facts.now.timeIntervalSince(last) > quietPeriod {
            let minutes = Int(facts.now.timeIntervalSince(last) / 60)
            return MCPSetupCheck(
                id: "traffic", title: "Captured traffic", state: .ok,
                detail: "\(facts.status.sessionCount) sessions captured, the most recent \(minutes) minutes ago."
            )
        }
        return MCPSetupCheck(id: "traffic", title: "Captured traffic", state: .ok, detail: "\(facts.status.sessionCount) sessions captured in this run.")
    }

    /// How many rejections the detail names before summarising the rest.
    static let tlsRejectionsListed = 5

    /// Apps refusing ReqRes's certificate (protocol PRD 3.4): the pinning
    /// case, which used to leave no row at all — the app "just did not work
    /// while capturing". Never a problem: capture works, those apps do not.
    /// A warning names each host and process. Since learned pins (core
    /// cc97856) an app's refusal is remembered and its later connections there
    /// are relayed, so it works on its next try; excluding the host, the
    /// human's to approve, only stops recording it. Omitted while the app has not
    /// counted (nil), and while capture has never recorded anything.
    private static func tlsRejections(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        guard let rejections = facts.tlsRejections else { return nil }
        guard !rejections.isEmpty else {
            guard facts.status.sessionCount > 0 else { return nil }
            return MCPSetupCheck(
                id: "tls_rejections", title: "Apps refusing ReqRes's certificate", state: .ok,
                detail: "No app has refused ReqRes's certificate in this run."
            )
        }
        let listed = rejections.prefix(tlsRejectionsListed).map { rejection -> String in
            let who = rejection.app.map { " by \($0)" } ?? ""
            let times = rejection.count == 1 ? "once" : "\(rejection.count) times"
            return "\(rejection.host)\(who) (\(times))"
        }
        var detail = "Apps refused ReqRes's certificate — they pin their own, or do not trust the ReqRes CA — so their requests to these hosts failed: \(listed.joined(separator: "; "))"
        if rejections.count > tlsRejectionsListed {
            detail += "; and \(rejections.count - tlsRejectionsListed) more"
        }
        detail += "."
        let first = rejections[0].host
        return MCPSetupCheck(
            id: "tls_rejections", title: "Apps refusing ReqRes's certificate", state: .warning,
            detail: detail,
            fix: "list_sessions outcome=failed shows the rows. ReqRes remembers an app that refused its certificate, with the domain, and passes that app's later connections there through untouched, as rows marked SSL pinned: the app works on its next try, and nothing inside those connections is readable. Settings ▸ Capture ▸ SSL-pinned apps lists what it remembered. To stop recording such a host at all, call exclude_host host=\(first) (the user approves it), or the user adds it in Settings ▸ Capture. A command-line tool that refuses it more likely lacks the CA as a file: call capture_environment. Once the tool has the CA, the user forgets the tool under SSL-pinned apps, or its connections to that domain stay passed through."
        )
    }

    /// The `tls_rejections` fix said TO the person (Capture ▸ Diagnose Setup…),
    /// in place of the agent's script above — the app's `humanVoiced` only
    /// rewrites the two phrasings every other check uses.
    public static let tlsRejectionsHumanFix =
        "ReqRes remembers an app that refused its certificate, with the domain, and passes that app's later connections there through untouched, marked SSL pinned, so the app works when it tries again. Settings ▸ Capture ▸ SSL-pinned apps lists them. To stop recording such a host at all, open one of its Failed rows and click Exclude, or add the host in Settings ▸ Capture. A command-line tool that refuses it usually just needs the CA as a file: Settings ▸ Capture exports it and prints the lines that point the tool at it. Then forget the tool under SSL-pinned apps, so ReqRes decrypts its connections again. Type outcome:failed in the search field to see the rows."

    /// The fix a check shows a HUMAN, when it has one of its own; nil means
    /// the agent wording is used (after `humanVoiced`).
    public static func humanFix(for check: MCPSetupCheck) -> String? {
        if check.id == "tls_rejections" && check.fix != nil { return tlsRejectionsHumanFix }
        // Its fixes name tools and speak of "the user" beyond the opening
        // phrase `humanVoiced` strips (F11 review).
        return MCPCaptureDelivery.humanFix(for: check)
    }

    /// The agent wording, turned back into something said TO the person.
    ///
    /// Every fix here is written for the bridge — "Ask the user to move
    /// ReqRes.app…", "Call start_capture." — because its first reader was an
    /// AI agent relaying it. Rendered straight into an alert or a tooltip,
    /// the person gets handed the script rather than the instruction. The
    /// engine stays shared; only the voice is swapped, and anything not
    /// recognised falls through unchanged rather than being dropped. (It was
    /// the app's `TrafficCommands.humanVoiced` until the menu bar item's
    /// tooltip needed it too.)
    public static func humanVoiced(_ text: String) -> String {
        for prefix in ["Ask the user to ", "Tell the user to "] where text.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
            return rest.prefix(1).uppercased() + rest.dropFirst()
        }
        let agentStart = "Call start_capture."
        if text.hasSuffix(agentStart) {
            return String(text.dropLast(agentStart.count)) + "Start capturing — ⌘⇧C, or Capture ▸ Start Capturing."
        }
        return text
    }

    /// A check's fix as a person reads it: its own human wording, else the
    /// agent's fix re-voiced; nil when there is nothing to do.
    public static func humanFixText(for check: MCPSetupCheck) -> String? {
        humanFix(for: check) ?? check.fix.map(humanVoiced)
    }

    /// The verdict as a person reads it — the menu bar item's tooltip. The
    /// verdict is the blocking check's detail and fix, the fix in the agent's
    /// words; this is the same sentence with the person's fix (F11 review:
    /// the tooltip read "…or call stop_capture and then start_capture").
    public static func humanVerdict(_ report: MCPSetupReport) -> String {
        guard let id = report.blockingCheckId, let blocking = report.checks.first(where: { $0.id == id }) else {
            return humanVoiced(report.verdict)
        }
        return "\(blocking.detail) \(humanFixText(for: blocking) ?? "")".trimmingCharacters(in: .whitespaces)
    }

    /// Whether ReqRes can say which app opened each connection (UX spec §9.1).
    ///
    /// Only while capture is on — the extension calibrates the socket-table
    /// read once per tunnel start, so before that there is nothing to report
    /// — and only when it HAS reported: an unreported state is omitted rather
    /// than shown as unknown, because "the check has not run yet" is not a
    /// finding, it is the first second of every capture — and an `.unknown`
    /// here would turn every report in that second into "some checks could
    /// not be made". Never a problem: capture is unaffected either way. What
    /// the warning exists for is the agent that filters by `app` or `pid`,
    /// gets nothing, and needs to know that the sessions are there and every
    /// one of them reads Unknown.
    private static func attribution(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        guard facts.status.captureActive, let available = facts.processAttribution else { return nil }
        guard available else {
            return MCPSetupCheck(
                id: "attribution", title: "Process attribution", state: .warning,
                detail: "ReqRes could not read the socket table on this Mac, so it cannot tell which app opened a connection. The App column is hidden and every request reads Unknown to an agent; capture itself is unaffected.",
                fix: nil
            )
        }
        return MCPSetupCheck(
            id: "attribution", title: "Process attribution", state: .ok,
            detail: "ReqRes can tell which app opened each connection.",
            fix: nil
        )
    }

    /// Whether the destination map can place anything (destination-map UX
    /// spec §8.5). Only while capture is on and there are enough sessions to
    /// say something about — a handful of requests that all happen to be
    /// local is not a finding. Never a problem: capture is unaffected either
    /// way. The two warnings tell apart the two ways everything reads
    /// Unknown: no table (reinstall) and no addresses (the extension running
    /// is the old one).
    static let destinationsMinimumSessions = 20

    private static func destinations(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        guard facts.status.captureActive, facts.status.sessionCount >= destinationsMinimumSessions else { return nil }
        guard let loaded = facts.destinationTableLoaded else {
            return MCPSetupCheck(
                id: "destinations", title: "Destinations", state: .unknown,
                detail: "Could not tell whether the bundled country table loaded."
            )
        }
        guard loaded else {
            return MCPSetupCheck(
                id: "destinations", title: "Destinations", state: .warning,
                detail: "The bundled country table could not be loaded, so every destination reads Unknown. Capture is unaffected.",
                fix: "Reinstall ReqRes."
            )
        }
        guard let placeable = facts.destinationsPlaceable, let withoutAddress = facts.destinationsWithoutAddress else {
            return MCPSetupCheck(
                id: "destinations", title: "Destinations", state: .unknown,
                detail: "Could not count how many captured requests were placed in a country."
            )
        }
        let total = facts.status.sessionCount
        guard withoutAddress < total else {
            return MCPSetupCheck(
                id: "destinations", title: "Destinations", state: .warning,
                detail: "Captured requests carry no server address, so nothing can be placed on the map — the running extension predates this feature.",
                fix: "Stop and start capture; if that does not change it, restart the Mac so macOS swaps in the new extension."
            )
        }
        return MCPSetupCheck(
            id: "destinations", title: "Destinations", state: .ok,
            detail: "Destinations resolve on this Mac: \(placeable) of \(total) requests placed in a country; the rest are local or unknown."
        )
    }

    /// Informational, never a failure (doc §S9): which protocol intercepted
    /// requests speak. "Why is everything HTTP/1.1?" and "did this site break
    /// because of HTTP/2?" are both answered by the one setting, which the
    /// agent cannot change — the human does, in Settings ▸ Capture.
    private static func http2(_ facts: MCPSetupFacts) -> MCPSetupCheck? {
        guard let enabled = facts.http2CaptureEnabled else { return nil }
        return MCPSetupCheck(
            id: "http2_capture", title: "HTTP/2 capture", state: .ok,
            detail: HTTP2CaptureCopy.diagnosisDetail(enabled: enabled)
        )
    }

    /// Informational, always present, always last, never a failure: nothing
    /// is broken when a tool that ignores the system proxy is not captured —
    /// it never reached the proxy. But "why do I not see MY traffic" is the
    /// question an agent driving a CLI tool asks most, and every check above
    /// answers "capture is fine", which is true and useless. This one names
    /// the reason and the tool that fixes it.
    private static func proxyAwareClients() -> MCPSetupCheck {
        MCPSetupCheck(
            id: "proxy_aware_clients", title: "Which clients are captured", state: .ok,
            detail: "Only clients that read the system proxy are captured without help: \(MCPCaptureEnvironment.systemProxyClients). "
                + "These do not, and are absent from the traffic list until their shell exports the proxy variables (both spellings — curl and git take the proxy for plain http:// only from http_proxy) and the CA: \(MCPCaptureEnvironment.environmentOnlyClients). "
                + "If the traffic you expect is from one of those, call capture_environment and export what it prints."
        )
    }
}
