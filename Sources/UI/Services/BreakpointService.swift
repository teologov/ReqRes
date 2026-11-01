//
//  BreakpointService.swift
//  ReqRes
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
//  The app's half of a held request.
//
//  A breakpoint is not like the rest of this app: while one is open, a real
//  request is stopped mid-flight and somewhere a page is spinning. Everything
//  here is in service of that fact.
//
//   * The extension resumes a held request by itself after
//     `BreakpointRegistry.decisionTimeout` (60s), so a row must leave the
//     queue on its own at `expiresAt` — the request is already gone by then,
//     and a panel still offering Resume for it would send a decision about
//     nothing while the user believed they were in control.
//   * The rules live here but the ENGINE that honours them lives in the
//     extension, a separate process that starts with an empty list every time
//     the tunnel does. So they are pushed on every edit AND on every status
//     update — the same reasoning `ExcludedHostsSettings` records, with a
//     sharper edge: a breakpoint that silently stopped applying is a user
//     waiting forever for a panel that never appears.
//   * It is OFF until the user arms it. No rules means no message ever
//     reaches the engine and nothing is ever held.
//
//  Threading: this is a plain `ObservableObject`, not a `@MainActor` one, for
//  the same reason `SessionState` and `MCPAgentActivity` are — it is reached
//  from the bus's event-loop thread and from `AppController`'s status `Task`,
//  neither of which is main. Every published property is therefore touched
//  ONLY on the main thread, by explicit hop, and the entry points say which
//  thread they expect.
//

import Combine
import Foundation
import MCPKit
import Utils
import XReqResCore

// MARK: - What the panel needs to describe a held request

/// One request header, in the order it arrived. Identifiable so an editor can
/// bind rows to it; the id is per-parse and never leaves the UI.
struct BreakpointHeader: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var value: String

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A stored rule plus a stable identity for SwiftUI. `BreakpointRule` is a
/// value the core defines and has no id of its own; `ForEach` over an index
/// would reorder rows under a running edit.
struct BreakpointRuleItem: Identifiable, Equatable {
    let id: UUID
    var rule: BreakpointRule

    init(id: UUID = UUID(), rule: BreakpointRule) {
        self.id = id
        self.rule = rule
    }

    /// The rule as `BreakpointRuleEntry` compares it.
    var spec: BreakpointRuleSpec {
        BreakpointRuleSpec(host: rule.host, pathContains: rule.pathContains, methods: rule.methods)
    }
}

/// The statuses worth offering when aborting a held request, in the order a
/// developer reaches for them. Kept beside the decision that uses them so the
/// panel and any future surface cannot drift apart.
struct BreakpointAbortPreset: Identifiable, Equatable {
    var id: Int { code }
    let code: Int
    let label: String

    static let all: [BreakpointAbortPreset] = [
        .init(code: 400, label: "Bad Request"),
        .init(code: 401, label: "Unauthorized"),
        .init(code: 403, label: "Forbidden"),
        .init(code: 404, label: "Not Found"),
        .init(code: 408, label: "Request Timeout"),
        .init(code: 409, label: "Conflict"),
        .init(code: 429, label: "Too Many Requests"),
        .init(code: 500, label: "Internal Server Error"),
        .init(code: 502, label: "Bad Gateway"),
        .init(code: 503, label: "Service Unavailable"),
        .init(code: 504, label: "Gateway Timeout"),
    ]

    /// What an abort answers with unless the caller picks something else.
    ///
    /// 409 Conflict says "this request was refused here", which is what an
    /// aborted request actually is — without claiming the server broke (500)
    /// or that the route is gone (404), both of which send a developer looking
    /// at a server that never saw the request.
    static let defaultCode = 409

    /// The one place these are listed. The panel had its own copy with a
    /// different default and a different set of codes, which is how the
    /// picker and the programmatic path came to disagree about what "abort"
    /// means.
    static func label(for code: Int) -> String? {
        all.first { $0.code == code }?.label
    }
}

// MARK: - Service

final class BreakpointService: ObservableObject {
    static let shared = BreakpointService()

    static let rulesDefaultsKey = "BreakpointRules"

    /// The request the user has least time to answer is the one they see
    /// first, so the queue is oldest-first throughout.
    @Published private(set) var pending: [PausedRequestCodable] = []

    @Published private(set) var rules: [BreakpointRuleItem] = []

    /// Advances only while something is held, and exists so a countdown can be
    /// drawn without every view that reads a rule owning a timer. See
    /// `startTicking()` for why it is not always running.
    @Published private(set) var now = Date()

    /// Requests let through without asking because the queue was already full,
    /// since it last emptied. The panel says so: a request that was held and
    /// then released unattended must not look like one that was never matched.
    @Published private(set) var autoResumedCount = 0

    /// A human-readable reason the queue last drained by itself (expiry, a
    /// disarm, capture stopping), for the panel to show as it closes. Cleared
    /// when the next request is held.
    @Published private(set) var lastReleaseNote: String?

    /// The app can only ask a human about so many at once. Past this the
    /// extra ones are resumed untouched rather than held with no way to
    /// answer them — a row nobody can reach is a 60-second stall with no UI.
    static let maxPending = 25

    /// What `abort` uses when the caller does not choose. Deliberately the
    /// same constant the panel's picker starts on — see
    /// `BreakpointAbortPreset.defaultCode` for why it is 409.
    static let defaultAbortStatus = BreakpointAbortPreset.defaultCode

    private let defaults: UserDefaults
    private var ticker: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = Self.loadRules(from: defaults).map { BreakpointRuleItem(rule: $0) }
    }

    // MARK: - State the UI reads

    /// True when at least one rule can stop a request. Everything user-facing
    /// keys off this rather than `rules.isEmpty`: a list of rules that are all
    /// switched off is armed for nothing.
    var isArmed: Bool { rules.contains { $0.rule.enabled } }

    /// Whole seconds left before the extension resumes it by itself, floored
    /// at zero so a countdown never shows a negative number in the moment
    /// between the deadline and the next tick.
    func secondsRemaining(for request: PausedRequestCodable) -> Int {
        max(0, Int((request.expiresAt - now.timeIntervalSince1970).rounded(.up)))
    }

    /// 1 at the moment it was held, 0 at the deadline — for a progress bar.
    func fractionRemaining(for request: PausedRequestCodable) -> Double {
        let total = request.expiresAt - request.pausedAt
        guard total > 0 else { return 0 }
        let left = request.expiresAt - now.timeIntervalSince1970
        return min(1, max(0, left / total))
    }

    /// When the body shown is only the head of a larger one. The panel has to
    /// say so, and never start a replacement from it: sending back a truncated
    /// preview as the new body would silently drop the rest of the upload.
    ///
    /// False when nothing is shown at all — which is every held request so
    /// far: the core holds a request at its head and reports no body (F19),
    /// and `HeldRequestBody` says what the request declares instead.
    static func isBodyTruncated(_ request: PausedRequestCodable) -> Bool {
        guard let preview = request.bodyPreview, !preview.isEmpty else { return false }
        return request.bodyByteCount > preview.utf8.count
    }

    // MARK: - Receiving a hit (bus thread)

    /// The entry point `AppController` calls for `ClientBusAction.breakpointHit`.
    ///
    /// It runs on the bus's event-loop thread, decodes where it stands, and
    /// touches published state only after hopping to main.
    /// `DispatchQueue.main.async` rather than a `Task` because two hits must
    /// arrive in the order they were sent, and unstructured tasks give no such
    /// guarantee — a queue whose order does not match the browser's is a user
    /// answering the wrong request.
    ///
    /// Anything it cannot read is logged and dropped. A payload that produced
    /// a half-built row would put a request in front of the user that the
    /// extension is not actually holding, and every button on it would be a lie.
    func handleBreakpointHit(payload: [String: AnyCodable]) {
        guard let object = payload["data"]?.value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object),
              let request = try? JSONDecoder().decode(PausedRequestCodable.self, from: data) else {
            AppLog.shared.error("[Breakpoint] dropped a breakpointHit payload it could not decode")
            return
        }
        DispatchQueue.main.async { self.enqueue(request) }
    }

    /// Called when a request joins the queue, so the window can put itself in
    /// front of the person who has 60 seconds to answer. Set by the app at
    /// launch rather than referenced directly, so this service stays testable
    /// and has no opinion about AppKit.
    var onFirstPause: (() -> Void)?

    private func enqueue(_ request: PausedRequestCodable) {
        precondition(Thread.isMainThread)
        // Already past its deadline: the extension has resumed it, and showing
        // it would be asking about a request that is already on the wire.
        guard request.expiresAt > Date().timeIntervalSince1970 else {
            AppLog.shared.debug("[Breakpoint] ignored a hit that had already expired")
            return
        }
        // The extension re-sending a hit (a reconnect, a retry) must not add a
        // second row for one held request.
        guard !pending.contains(where: { $0.id == request.id }) else { return }

        if pending.isEmpty {
            autoResumedCount = 0
            lastReleaseNote = nil
        }

        guard pending.count < Self.maxPending else {
            // Let it through and count it. The alternative — holding it with
            // nowhere to show it — stalls the request for a full minute and
            // tells the user nothing.
            autoResumedCount += 1
            send(.resume(id: request.id))
            AppLog.shared.debug("[Breakpoint] queue full, resumed a hit untouched (\(self.autoResumedCount, privacy: .public) so far)")
            return
        }

        let wasEmpty = pending.isEmpty
        pending.append(request)
        startTicking()
        // Only on the FIRST of a burst: a window that re-fronts itself for
        // every held request would fight the user who is reading the one in
        // front of them.
        if wasEmpty { onFirstPause?() }
    }

#if DEBUG
    /// Seeds one held request so the panel can be looked at without the
    /// extension. DEBUG only, and it never reaches the bus: a decision on it
    /// is delivered to nothing, which is exactly what a decision for an
    /// already-resumed request does in production.
    ///
    /// `autoResumed` and `releaseNote` seed the two states that are otherwise
    /// only reachable by overflowing a real queue or waiting out a real
    /// 60-second timer — both of which the panel has to render correctly and
    /// neither of which a probe can produce honestly. They are set AFTER the
    /// enqueue because enqueuing into an empty queue deliberately clears them.
    ///
    /// `body` defaults to what the core sends TODAY, and that is the point
    /// (F19): this seed used to carry a 49-byte preview the core never sends,
    /// so every rendered probe of the panel showed a body while every real
    /// held request said "Body (none)" beside its own Content-Length. Each
    /// shape carries the core's own reading of the head too (`bodyExpected`,
    /// `declaredBodyLength`, core 35dd624), as the extension would send it.
    /// `REQRES_BREAKPOINT_SEED_BODY` picks another shape.
    func seedForProbe(
        autoResumed: Int = 0,
        releaseNote: String? = nil,
        body: ProbeBodyShape = ProbeBodyShape(
            rawValue: ProcessInfo.processInfo.environment["REQRES_BREAKPOINT_SEED_BODY"] ?? ""
        ) ?? .length
    ) {
        precondition(Thread.isMainThread)
        defer {
            autoResumedCount = autoResumed
            lastReleaseNote = releaseNote
            if releaseNote != nil {
                pending = []
                stopTicking()
            }
        }
        let json = #"{"sku":"SKU-4412","quantity":2,"coupon":"SUMMER"}"#
        let framing: String
        let bodyExpected: Bool?
        let declaredBodyLength: Int?
        switch body {
        case .length, .reported:
            framing = #",{"Content-Length":"\#(json.utf8.count)"}"#
            (bodyExpected, declaredBodyLength) = (true, json.utf8.count)
        case .chunked:
            framing = #",{"Transfer-Encoding":"chunked"}"#
            (bodyExpected, declaredBodyLength) = (true, nil)
        case .empty, .trace:
            framing = ""
            (bodyExpected, declaredBodyLength) = (false, nil)
        case .traceWithBody:
            framing = #",{"Content-Length":"\#(json.utf8.count)"}"#
            (bodyExpected, declaredBodyLength) = (true, json.utf8.count)
        case .http2:
            framing = ""
            (bodyExpected, declaredBodyLength) = (true, nil)
        case .undeclared:
            framing = ""
            (bodyExpected, declaredBodyLength) = (nil, nil)
        }
        let now = Date().timeIntervalSince1970
        enqueue(PausedRequestCodable(
            id: "probe-\(UUID().uuidString.prefix(8))",
            host: "api.example.com",
            method: body == .trace || body == .traceWithBody ? "TRACE" : "POST",
            uri: "/v1/orders?expand=customer",
            scheme: "https",
            headers: #"[{"Authorization":"Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature"},{"Content-Type":"application/json"}"#
                + framing
                + #",{"Accept":"application/json"},{"X-Request-Id":"7c9f1a"}]"#,
            // What `GlueHandler.holdForBreakpoint` sends for every request:
            // the hit is built at the head, before any of the body arrives,
            // and nothing reports the body after it.
            bodyPreview: body == .reported ? json : nil,
            bodyByteCount: body == .reported ? json.utf8.count : 0,
            pausedAt: now,
            expiresAt: now + BreakpointRegistry.decisionTimeout,
            bodyExpected: bodyExpected,
            declaredBodyLength: declaredBodyLength
        ))
    }

    /// The body shapes `seedForProbe` can hold.
    enum ProbeBodyShape: String {
        /// The core today, for a POST with a body: its Content-Length, no
        /// preview, a count of 0; a body is expected, of that length.
        case length
        /// The core today, for a chunked upload: `Transfer-Encoding: chunked`,
        /// a body expected, no length.
        case chunked
        /// The core today, for an HTTP/1 request with no framing header: no
        /// body follows ("Empty body").
        case empty
        /// The core today, for an HTTP/2 POST without content-length: a body
        /// follows, its size not declared.
        case http2
        /// An HTTP/1 TRACE with no body: Replace Body… is not offered.
        case trace
        /// An HTTP/1 TRACE that arrives with a body of its own (a
        /// Content-Length): no Replace Body…, and the Body tab says Resume is
        /// answered 502 over HTTP/1.1.
        case traceWithBody = "trace-with-body"
        /// No framing header and nothing from the core — an HTTP/2 GET, or an
        /// extension older than `bodyExpected`.
        case undeclared
        /// A core that reported bodies would send this: the whole 49 bytes.
        case reported
    }
#endif

    // MARK: - Decisions (main thread — they are the panel's buttons)

    /// Sends the request on unchanged.
    func resume(id: String) {
        precondition(Thread.isMainThread)
        guard remove(id) else { return }
        send(.resume(id: id))
    }

    /// Sends it on with edits. `nil` means "leave this as it was" — the panel
    /// passes what the user actually touched, so an untouched request is
    /// resumed byte-for-byte rather than round-tripped through this app's
    /// idea of how headers are spelled.
    ///
    /// Returns nil on success, or a message to show the user. Refusing is the
    /// point: a header name or value carrying CR or LF would let an edit made
    /// in this panel inject a second request into the connection.
    @discardableResult
    func resume(id: String, headers: [BreakpointHeader]?, body: String?) -> String? {
        precondition(Thread.isMainThread)
        // A TRACE may not carry a body: the panel does not offer one and the
        // bridge refuses one, and this is the last of the three guards —
        // over HTTP/1.1 the core would answer the app 502 instead of
        // forwarding it (`HeldRequestBody.replacementRefusal`).
        if body != nil, let held = pending.first(where: { $0.id == id }),
           let refusal = HeldRequestBody.replacementRefusal(method: held.method) {
            return refusal
        }
        var encoded: String?
        if let headers {
            guard let json = Self.headersJSON(from: headers) else {
                return "A header cannot be sent as written. A line break in a name or value — or a colon or space in a name — would end the request's header block early and let the rest be read as another request."
            }
            encoded = json
        }
        guard remove(id) else { return nil }
        send(BreakpointDecisionCodable(id: id, action: .resume, headers: encoded, body: body))
        return nil
    }

    /// Answers the request without ever contacting the server.
    func abort(id: String, status: Int = BreakpointService.defaultAbortStatus) {
        precondition(Thread.isMainThread)
        guard remove(id) else { return }
        send(BreakpointDecisionCodable(id: id, action: .abort, abortStatus: status))
    }

    /// Releases everything held, unchanged — the panel's way out when the user
    /// does not want to answer each one.
    func resumeAll() {
        precondition(Thread.isMainThread)
        let ids = pending.map(\.id)
        pending = []
        stopTicking()
        for id in ids { send(.resume(id: id)) }
        if !ids.isEmpty {
            lastReleaseNote = ids.count == 1 ? "1 request was resumed." : "\(ids.count) requests were resumed."
        }
    }

    /// Records that something other than the person in front of the window
    /// answered a held request.
    ///
    /// Only when the queue is now EMPTY, and that is the whole point: the
    /// panel puts itself away when the USER answers the last request, so an
    /// agent answering it would make the window vanish with no explanation of
    /// where the request went. A note keeps it up long enough to say. While
    /// other requests are still held the panel is visibly busy and the
    /// activity log has the detail, so a note there would be noise.
    func noteAgentDecision(_ summary: String) {
        precondition(Thread.isMainThread)
        guard pending.isEmpty else { return }
        lastReleaseNote = "An agent answered this: \(summary)"
    }

    /// Forgets the queue WITHOUT sending anything — for when the extension is
    /// gone (capture stopped, the tunnel dropped) and there is nobody left to
    /// receive a decision. Sending into a dead bus would leave the rows on
    /// screen for a minute pretending a held request still exists.
    func clearPending(reason: String) {
        precondition(Thread.isMainThread)
        guard !pending.isEmpty else { return }
        AppLog.shared.debug("[Breakpoint] dropped \(self.pending.count, privacy: .public) held request(s): \(reason, privacy: .public)")
        pending = []
        stopTicking()
        lastReleaseNote = reason
    }

    /// Removes it optimistically. The queue is the app's picture of what the
    /// extension is holding, and the moment the user decides, that picture is
    /// already out of date — if the message is lost the request auto-resumes
    /// within the minute anyway, so a stale row is the worse of the two.
    ///
    /// False means it had already left (expired, or answered twice by a
    /// double-click), and the caller must not send a decision about it.
    private func remove(_ id: String) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        pending.remove(at: index)
        if pending.isEmpty { stopTicking() }
        return true
    }

    private func send(_ decision: BreakpointDecisionCodable) {
        AppController.shared.notifyExtension(
            message: ServerBusMessage(action: .breakpointDecision, payload: ["data": decision])
        )
    }

    // MARK: - Expiry

    /// The timer runs ONLY while something is held. A 2 Hz timer alive for the
    /// life of the app, for a feature most launches never arm, is exactly the
    /// kind of thing that turns up in a hang report on this project.
    private func startTicking() {
        guard ticker == nil else { return }
        now = Date()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.1
        // .common so a countdown keeps running while a menu or a resize has
        // the run loop in tracking mode — a clock that freezes while the user
        // is dragging the panel is a clock they stop trusting.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        now = Date()
        let deadline = now.timeIntervalSince1970
        let expired = pending.filter { $0.expiresAt <= deadline }
        guard !expired.isEmpty else { return }
        // No decision is sent: the extension already resumed these by itself,
        // which is precisely why they have to disappear from the queue.
        pending.removeAll { $0.expiresAt <= deadline }
        lastReleaseNote = expired.count == 1
            ? "1 request was resumed automatically — nobody answered in time."
            : "\(expired.count) requests were resumed automatically — nobody answered in time."
        AppLog.shared.debug("[Breakpoint] \(expired.count, privacy: .public) held request(s) expired")
        if pending.isEmpty { stopTicking() }
    }

    // MARK: - Rules (main thread — they are Settings' controls)

    /// Adds a rule. Returns nil on success, or why the text cannot be added
    /// — rejected rather than repaired, because a rule sitting in the list
    /// doing nothing is indistinguishable, to the user, from the feature
    /// being broken.
    ///
    /// The decision is `BreakpointRuleEntry.refusal` (Utils, tested), the same
    /// one Settings derives its note from, so the list and the note cannot
    /// disagree about what "already in the list" means.
    @discardableResult
    func addRule(host rawHost: String, pathContains: String? = nil, methods: [String] = []) -> BreakpointRuleEntry.Refusal? {
        precondition(Thread.isMainThread)
        if let refusal = BreakpointRuleEntry.refusal(
            host: rawHost, pathContains: pathContains, methods: methods, existing: rules.map(\.spec)
        ) {
            return refusal
        }
        guard let host = BreakpointRuleEntry.canonicalHost(rawHost) else { return .cannotMatch }
        rules.append(BreakpointRuleItem(rule: BreakpointRule(
            host: host,
            pathContains: BreakpointRuleEntry.canonicalPath(pathContains),
            methods: BreakpointRuleEntry.canonicalMethods(methods),
            enabled: true
        )))
        persistAndPush()
        return nil
    }

    /// Replaces a rule's contents, keeping its row identity so an edit does
    /// not make the list jump under the user.
    @discardableResult
    func updateRule(id: UUID, host rawHost: String, pathContains: String?, methods: [String]) -> String? {
        precondition(Thread.isMainThread)
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        guard let host = BreakpointRuleEntry.canonicalHost(rawHost) else {
            return BreakpointRuleEntry.message(for: .cannotMatch, host: rawHost)
        }
        rules[index].rule = BreakpointRule(
            host: host,
            pathContains: BreakpointRuleEntry.canonicalPath(pathContains),
            methods: BreakpointRuleEntry.canonicalMethods(methods),
            enabled: rules[index].rule.enabled
        )
        persistAndPush()
        return nil
    }

    func setRuleEnabled(_ enabled: Bool, id: UUID) {
        precondition(Thread.isMainThread)
        guard let index = rules.firstIndex(where: { $0.id == id }), rules[index].rule.enabled != enabled else { return }
        rules[index].rule.enabled = enabled
        persistAndPush()
    }

    func removeRule(id: UUID) {
        precondition(Thread.isMainThread)
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules.remove(at: index)
        persistAndPush()
    }

    func removeAllRules() {
        precondition(Thread.isMainThread)
        guard !rules.isEmpty else { return }
        rules = []
        persistAndPush()
    }

    private func persistAndPush() {
        precondition(Thread.isMainThread)
        if let data = try? JSONEncoder().encode(rules.map(\.rule)) {
            defaults.set(data, forKey: Self.rulesDefaultsKey)
        }
        // Disarming with requests still held would leave them stopped until
        // their deadline with no rule to explain why. Turning it off has to
        // unstick the browser, immediately.
        if !isArmed, !pending.isEmpty {
            resumeAll()
            lastReleaseNote = "Breakpoints were turned off, so the held requests were resumed."
        }
        push()
    }

    /// Sends the current rules to the extension. Safe to call with no tunnel
    /// running — the bus drops it, and the next status update sends it again.
    ///
    /// Only ENABLED rules are sent. The core checks `enabled` too, so this is
    /// belt and braces on purpose: the cost of that check ever regressing is a
    /// switched-off rule freezing someone's browser, which is the worst
    /// failure this feature has.
    func push() {
        // `rules` is `@Published`, and the status update that calls this runs
        // in a `Task` that is NOT on main — reading it where we stand is the
        // live data race the MCP bridge review caught doing the same thing.
        // The main thread never waits on the bus, so this cannot deadlock.
        let armed = Self.onMain { self.rules.map(\.rule).filter(\.enabled) }
        AppController.shared.notifyExtension(
            message: ServerBusMessage(action: .breakpointRulesChanged, payload: ["data": armed])
        )
        AppLog.shared.debug("[Breakpoint] pushed \(armed.count, privacy: .public) armed rule(s)")
    }

    /// Reads `work` on the main thread, from wherever the caller is.
    private static func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    private static func loadRules(from defaults: UserDefaults) -> [BreakpointRule] {
        guard let data = defaults.data(forKey: rulesDefaultsKey),
              let stored = try? JSONDecoder().decode([BreakpointRule].self, from: data) else {
            // No rules is the default, and it means the feature does nothing.
            return []
        }
        return stored
    }

    // MARK: - Rule text

    // The canonical host, path and methods live in `BreakpointRuleEntry`
    // (Utils), where they are tested and where Settings' note reads them too.

    /// Splits text the user pasted into a rule: a full URL becomes a host plus
    /// the path to match on, so "break on this request" is one paste rather
    /// than two fields filled by hand. Nil when there is no usable host.
    static func draftRule(fromPastedText raw: String) -> BreakpointRule? {
        guard let host = BreakpointRuleEntry.canonicalHost(raw) else { return nil }
        // Read as Settings' Add reads a paste (`BreakpointRuleEntry.split`).
        let path = BreakpointRuleEntry.pastedPath(raw)
        return BreakpointRule(host: host, pathContains: BreakpointRuleEntry.canonicalPath(path), methods: [], enabled: true)
    }

    // MARK: - Headers

    /// Back to the wire shape, through the CORE's own encoder.
    ///
    /// This used to be a second implementation of `BreakpointHeaderWire`,
    /// living on this side of the framework boundary and agreeing with it by
    /// coincidence. The failure that shape of duplication produces is silent:
    /// `GlueHandler` discards a header blob it cannot parse and forwards the
    /// request with the ORIGINAL headers, so a drifted encoder would let the
    /// panel report "Resume with Changes" while sending none of them. The
    /// process that writes the bytes publishes the contract; this just calls it.
    ///
    /// Nil means the decision must not be sent — see `isSendable` for what is
    /// refused and why.
    static func headersJSON(from pairs: [BreakpointHeader]) -> String? {
        BreakpointHeaderWire.encode(pairs.map { (name: $0.name, value: $0.value) })
    }
}
