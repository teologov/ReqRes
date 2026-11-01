//
//  ProxyPortAvailabilityTests.swift
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

import Darwin
import XCTest
@testable import Utils

final class ProxyPortAvailabilityTests: XCTestCase {
    private typealias Look = ScriptedProbes.Look

    // MARK: The decision table

    /// Every row of the table in `verdict(bind:connect:holderNamed:)`.
    func testTheDecisionTable() {
        func verdict(_ bind: ProxyPortAvailability.BindResult, _ connect: ProxyPortAvailability.ConnectResult,
                     named: Bool) -> ProxyPortAvailability.Verdict {
            ProxyPortAvailability.verdict(bind: bind, connect: connect, holderNamed: named)
        }
        let connects: [ProxyPortAvailability.ConnectResult] = [.accepted, .reset, .refused, .timedOut, .unavailable]
        for connect in connects {
            for named in [false, true] {
                XCTAssertEqual(verdict(.failed(EACCES), connect, named: named), .free,
                               "any other bind error is not a conflict, as before (\(connect), named: \(named))")
            }
        }
        for named in [false, true] {
            XCTAssertEqual(verdict(.bound, .accepted, named: named), .held,
                           "this user's listener on the wildcard address: the bind gets past it (named: \(named))")
            XCTAssertEqual(verdict(.bound, .reset, named: named), .held, "the same listener, busy (named: \(named))")
            XCTAssertEqual(verdict(.bound, .refused, named: named), .free, "nothing answers (named: \(named))")
            XCTAssertEqual(verdict(.bound, .timedOut, named: named), .free,
                           "a wildcard socket that never listens takes nothing (named: \(named))")
            XCTAssertEqual(verdict(.bound, .unavailable, named: named), .free,
                           "the bind's answer stands when the probe cannot run (named: \(named))")
        }
        XCTAssertEqual(verdict(.addressInUse, .accepted, named: false), .held)
        XCTAssertEqual(verdict(.addressInUse, .accepted, named: true), .held)
        XCTAssertEqual(verdict(.addressInUse, .reset, named: false), .held,
                       "a listener with a full accept queue resets: something listens there")
        XCTAssertEqual(verdict(.addressInUse, .reset, named: true), .held)
        XCTAssertEqual(verdict(.addressInUse, .refused, named: true), .held,
                       "a listener the socket table names is taken even when this connect was refused")
        XCTAssertEqual(verdict(.addressInUse, .refused, named: false), .lingering,
                       "F10: in use, nothing accepts, nobody listens — closed connections draining")
        XCTAssertEqual(verdict(.addressInUse, .timedOut, named: false), .held,
                       "a socket bound there that never listens drops the SYN: never read as nothing there")
        XCTAssertEqual(verdict(.addressInUse, .timedOut, named: true), .held)
        XCTAssertEqual(verdict(.addressInUse, .unavailable, named: false), .held,
                       "a probe that could not run proves nothing")
        XCTAssertEqual(verdict(.addressInUse, .unavailable, named: true), .held)

        XCTAssertTrue(ProxyPortAvailability.Verdict.free.isFree)
        XCTAssertTrue(ProxyPortAvailability.Verdict.lingering.isFree)
        XCTAssertFalse(ProxyPortAvailability.Verdict.held.isFree)
        XCTAssertEqual(connects.filter(\.listenerAnswered), [.accepted, .reset])
    }

    /// The state measured live: a start 16 s after a stop, nothing listening.
    func testLingeringConnectionsAreNotAConflict() {
        let scripted = ScriptedProbes([8035: [Look(bind: .addressInUse, connect: .refused)]])
        let finding = ProxyPortAvailability.check(port: 8035, settling: false, probes: scripted.probes)
        XCTAssertEqual(finding.verdict, .lingering)
        XCTAssertTrue(finding.verdict.isFree)
        XCTAssertEqual(finding.bind, .addressInUse)
        XCTAssertEqual(finding.connect, .refused)
        XCTAssertNil(finding.holder)
        XCTAssertEqual(finding.looks, 1)
        XCTAssertEqual(finding.summary, "lingering (bind addressInUse, connect refused, no listener named)")
    }

    func testAListenerIsHeldAndNamed() {
        let scripted = ScriptedProbes([8034: [Look(bind: .addressInUse, connect: .accepted, holder: "Charles")]])
        let finding = ProxyPortAvailability.check(port: 8034, settling: false, probes: scripted.probes)
        XCTAssertEqual(finding.verdict, .held)
        XCTAssertEqual(finding.holder, "Charles")
        XCTAssertEqual(finding.summary, "held (bind addressInUse, connect accepted, listener Charles)")
    }

    /// The common case — a free port — costs one bind and one refused
    /// connect: no socket-table walk, no wait. Another bind error decides
    /// alone, as before.
    func testAFreePortCostsOneBindAndOneRefusedConnect() {
        let scripted = ScriptedProbes([8034: [Look(bind: .bound)], 8035: [Look(bind: .failed(EADDRNOTAVAIL))]])
        let free = ProxyPortAvailability.check(port: 8034, settling: true, probes: scripted.probes)
        XCTAssertEqual(free.verdict, .free)
        XCTAssertEqual(free.connect, .refused)
        XCTAssertEqual(free.summary, "free (bind bound, connect refused, no listener named)")
        let failed = ProxyPortAvailability.check(port: 8035, settling: true, probes: scripted.probes)
        XCTAssertEqual(failed.verdict, .free)
        XCTAssertNil(failed.connect)
        XCTAssertEqual(scripted.connects, [8034], "another bind error decides alone")
        XCTAssertEqual(scripted.holderLookups, [])
        XCTAssertEqual(scripted.pauses, [])
    }

    // MARK: A bind that succeeds

    /// This user's listener on the wildcard address (`python3 -m http.server`,
    /// node's `listen(port)`): the bind gets past it, a connect does not.
    func testAListenerTheBindGetsPastIsHeldAndNamed() {
        let scripted = ScriptedProbes([8034: [Look(bind: .bound, connect: .accepted, holder: "Python")]])
        let finding = ProxyPortAvailability.check(port: 8034, settling: true, probes: scripted.probes)
        XCTAssertEqual(finding.verdict, .held)
        XCTAssertEqual(finding.holder, "Python")
        XCTAssertEqual(finding.summary, "held (bind bound, connect accepted, listener Python)")
        XCTAssertEqual(finding.looks, 1,
                       "never ReqRes's closing listener, even just after a stop: that one is root's, and this bind never gets past it")
        XCTAssertEqual(scripted.pauses, [])
    }

    /// A busy listener answers with a reset, and is held like one that
    /// accepts; just after a stop, a closing listener's reset is looked at
    /// again like its accept.
    func testAResetIsAListenerAnswering() {
        for bind in [ProxyPortAvailability.BindResult.addressInUse, .bound] {
            let busy = ScriptedProbes([8034: [Look(bind: bind, connect: .reset)]])
            XCTAssertEqual(ProxyPortAvailability.check(port: 8034, settling: false, probes: busy.probes).verdict, .held, "\(bind)")
            XCTAssertEqual(busy.holderLookups, [8034], "a listener answered, so it is named if it can be (\(bind))")
        }
        let closing = ScriptedProbes([8034: [Look(bind: .addressInUse, connect: .reset), Look(bind: .addressInUse, connect: .refused)]])
        let finding = ProxyPortAvailability.check(port: 8034, settling: true, probes: closing.probes)
        XCTAssertEqual(finding.verdict, .lingering)
        XCTAssertEqual(finding.looks, 2)
        XCTAssertEqual(closing.pauses, [0.3])
    }

    // MARK: Just after a stop

    /// ReqRes's own listener still closing: it answers once, then refuses.
    func testJustAfterAStopAPortThatStopsAnsweringIsFree() {
        let scripted = ScriptedProbes([8035: [
            Look(bind: .addressInUse, connect: .accepted, holder: "ReqRes"),
            Look(bind: .addressInUse, connect: .refused),
        ]])
        let finding = ProxyPortAvailability.check(port: 8035, settling: true, probes: scripted.probes)
        XCTAssertEqual(finding.verdict, .lingering)
        XCTAssertEqual(finding.looks, 2)
        XCTAssertEqual(scripted.pauses, [0.3], "one wait, injected — nothing sleeps")

        let closed = ScriptedProbes([8035: [Look(bind: .addressInUse, connect: .accepted), Look(bind: .bound)]])
        let free = ProxyPortAvailability.check(port: 8035, settling: true, probes: closed.probes)
        XCTAssertEqual(free.verdict, .free, "the listener gone and nothing lingering")
        XCTAssertEqual(free.looks, 2)
    }

    /// A listener that keeps accepting is not ReqRes's closing one.
    func testJustAfterAStopAListenerThatKeepsAnsweringIsHeld() {
        let scripted = ScriptedProbes([8035: [Look(bind: .addressInUse, connect: .accepted, holder: "node")]])
        let finding = ProxyPortAvailability.check(port: 8035, settling: true, probes: scripted.probes)
        XCTAssertEqual(finding.verdict, .held)
        XCTAssertEqual(finding.holder, "node")
        XCTAssertEqual(finding.looks, 4, "the first look and three re-probes")
        XCTAssertEqual(scripted.connects.count, 4)
        XCTAssertEqual(scripted.pauses, [0.3, 0.3, 0.3])
        XCTAssertEqual(finding.summary, "held (bind addressInUse, connect accepted, listener node, 4 looks)")
    }

    func testTheLastReprobeStillCounts() {
        let answering = Look(bind: .addressInUse, connect: .accepted)
        let scripted = ScriptedProbes([8035: [answering, answering, answering, Look(bind: .addressInUse, connect: .refused)]])
        let finding = ProxyPortAvailability.check(port: 8035, settling: true, probes: scripted.probes)
        XCTAssertEqual(finding.verdict, .lingering)
        XCTAssertEqual(finding.looks, 4)
        XCTAssertEqual(scripted.pauses.count, 3)
    }

    func testOutsideTheWindowAPortThatAnswersIsHeldAtOnce() {
        let scripted = ScriptedProbes([8035: [Look(bind: .addressInUse, connect: .accepted), Look(bind: .bound)]])
        let finding = ProxyPortAvailability.check(port: 8035, settling: false, probes: scripted.probes)
        XCTAssertEqual(finding.verdict, .held)
        XCTAssertEqual(finding.looks, 1)
        XCTAssertEqual(scripted.pauses, [])
        XCTAssertEqual(scripted.binds, [8035])
    }

    /// Only a listener answering where the bind was refused — ReqRes's own
    /// closing listener's shape — is looked at again: a timeout has already
    /// cost its bound, a listener the bind gets past is this user's, and
    /// everything else is decided by one look.
    func testJustAfterAStopOnlyAListenerTheBindCannotPassIsProbedAgain() {
        let once: [(Look, ProxyPortAvailability.Verdict)] = [
            (Look(bind: .addressInUse, connect: .timedOut), .held),
            (Look(bind: .addressInUse, connect: .unavailable), .held),
            (Look(bind: .addressInUse, connect: .refused, holder: "Proxyman"), .held),
            (Look(bind: .addressInUse, connect: .refused), .lingering),
            (Look(bind: .bound), .free),
            (Look(bind: .bound, connect: .accepted, holder: "Python"), .held),
            (Look(bind: .bound, connect: .reset), .held),
            (Look(bind: .bound, connect: .timedOut), .free),
        ]
        for (look, expected) in once {
            let scripted = ScriptedProbes([8034: [look, Look(bind: .bound)]])
            let finding = ProxyPortAvailability.check(port: 8034, settling: true, probes: scripted.probes)
            XCTAssertEqual(finding.verdict, expected, "\(look)")
            XCTAssertEqual(finding.looks, 1, "\(look)")
            XCTAssertEqual(scripted.pauses, [], "\(look)")
        }

        let stalled = ScriptedProbes([8034: [Look(bind: .addressInUse, connect: .accepted), Look(bind: .addressInUse, connect: .timedOut)]])
        let finding = ProxyPortAvailability.check(port: 8034, settling: true, probes: stalled.probes)
        XCTAssertEqual(finding.verdict, .held)
        XCTAssertEqual(finding.looks, 2, "a timeout ends the re-probing")
        XCTAssertEqual(stalled.pauses, [0.3])
    }

    /// The whole path with an injected clock: the watch says whether the
    /// tunnel just stopped, the check decides what an answering port means.
    func testTheStopClockDecidesWhetherAnAnsweringPortIsProbedAgain() {
        let stopped = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var watch = CaptureTunnelWatch()
        watch.observe(.connected, at: stopped.addingTimeInterval(-60))
        watch.observe(.disconnecting, at: stopped.addingTimeInterval(-0.5))
        watch.observe(.down, at: stopped)
        let closing = [Look(bind: .addressInUse, connect: .accepted), Look(bind: .addressInUse, connect: .refused)]

        let soon = ScriptedProbes([8035: closing])
        let settling = watch.stoppedRecently(now: stopped.addingTimeInterval(0.4))
        XCTAssertTrue(settling)
        XCTAssertTrue(ProxyPortAvailability.check(port: 8035, settling: settling, probes: soon.probes).verdict.isFree)

        let later = ScriptedProbes([8035: closing])
        let settled = watch.stoppedRecently(now: stopped.addingTimeInterval(16))
        XCTAssertFalse(settled)
        XCTAssertEqual(ProxyPortAvailability.check(port: 8035, settling: settled, probes: later.probes).verdict, .held,
                       "long after a stop, a port that accepts is someone's listener")
    }

    // MARK: The suggested port

    /// The preflight's predicate, not a bare bind: a port whose only problem
    /// is lingering connections is offered rather than skipped for a worse one.
    func testTheSuggestionOffersAPortWithOnlyLingeringConnections() {
        let scripted = ScriptedProbes([8035: [Look(bind: .addressInUse, connect: .refused)]])
        let suggestion = ProxyPortSetting.suggestion(after: 8034) { ProxyPortAvailability.isFree($0, probes: scripted.probes) }
        XCTAssertEqual(suggestion, 8035)
        let bareBind = ProxyPortSetting.suggestion(after: 8034) { scripted.probes.bind($0) != .addressInUse }
        XCTAssertEqual(bareBind, 8036, "what the bind-only predicate offered")
    }

    func testTheSuggestionSkipsAPortSomethingListensOn() {
        let listening = ScriptedProbes([8035: [Look(bind: .addressInUse, connect: .accepted, holder: "Charles")]])
        XCTAssertEqual(ProxyPortSetting.suggestion(after: 8034) { ProxyPortAvailability.isFree($0, probes: listening.probes) }, 8036)
        let stalled = ScriptedProbes([8035: [Look(bind: .addressInUse, connect: .timedOut)]])
        XCTAssertEqual(ProxyPortSetting.suggestion(after: 8034) { ProxyPortAvailability.isFree($0, probes: stalled.probes) }, 8036)
        let wildcard = ScriptedProbes([8035: [Look(bind: .bound, connect: .accepted, holder: "Python")]])
        XCTAssertEqual(ProxyPortSetting.suggestion(after: 8034) { ProxyPortAvailability.isFree($0, probes: wildcard.probes) }, 8036,
                       "a dev server on the wildcard address is not offered")
        XCTAssertEqual(listening.pauses + stalled.pauses + wildcard.pauses, [], "a suggestion is never waited for")
    }

    // MARK: The preflight

    /// F10 at the call site's decision: lingering connections are no
    /// conflict, and no other port is looked for.
    func testThePreflightLetsLingeringConnectionsThrough() {
        let configured = ScriptedProbes([8035: [Look(bind: .addressInUse, connect: .refused)]])
        let candidates = ScriptedProbes([:])
        let preflight = ProxyPortAvailability.preflight(port: 8035, settling: false,
                                                        probes: configured.probes, candidates: candidates.probes)
        XCTAssertFalse(preflight.isConflict)
        XCTAssertEqual(preflight.finding.verdict, .lingering)
        XCTAssertNil(preflight.suggestion)
        XCTAssertEqual(candidates.binds, [], "nothing to offer instead")
    }

    /// A held port is a conflict naming its holder, and the port offered
    /// instead comes from the same decision through the candidates' own
    /// probes: a lingering port is offered, a listening one skipped.
    func testThePreflightOffersAPortByTheSameDecision() {
        let configured = ScriptedProbes([8034: [Look(bind: .addressInUse, connect: .accepted, holder: "Charles")]])
        let lingering = ScriptedProbes([8035: [Look(bind: .addressInUse, connect: .refused)]])
        let preflight = ProxyPortAvailability.preflight(port: 8034, settling: false,
                                                        probes: configured.probes, candidates: lingering.probes)
        XCTAssertTrue(preflight.isConflict)
        XCTAssertEqual(preflight.finding.holder, "Charles")
        XCTAssertEqual(preflight.suggestion, 8035, "a bind-only predicate would have skipped it")
        XCTAssertEqual(configured.binds, [8034], "the configured port's probes never try a candidate")
        XCTAssertEqual(lingering.binds, [8035], "and the candidates' never the configured port")

        let listening = ScriptedProbes([8035: [Look(bind: .bound, connect: .accepted, holder: "Python")]])
        let skipped = ProxyPortAvailability.preflight(port: 8034, settling: false,
                                                      probes: configured.probes, candidates: listening.probes)
        XCTAssertEqual(skipped.suggestion, 8036)
    }

    /// The stop window reaches the check: just after a stop, ReqRes's own
    /// closing listener is not a conflict; long after, the same answer is.
    func testThePreflightPassesTheStopWindowOn() {
        let closing = [Look(bind: .addressInUse, connect: .accepted), Look(bind: .addressInUse, connect: .refused)]
        let justStopped = ProxyPortAvailability.preflight(port: 8035, settling: true,
                                                          probes: ScriptedProbes([8035: closing]).probes,
                                                          candidates: ScriptedProbes([:]).probes)
        XCTAssertFalse(justStopped.isConflict)
        XCTAssertEqual(justStopped.finding.looks, 2)
        let later = ProxyPortAvailability.preflight(port: 8035, settling: false,
                                                    probes: ScriptedProbes([8035: closing]).probes,
                                                    candidates: ScriptedProbes([:]).probes)
        XCTAssertTrue(later.isConflict)
        XCTAssertEqual(later.suggestion, 8036)
    }

    // MARK: Real sockets

    func testARealListenerIsHeldAndFreeOnceClosed() throws {
        let listener = try LoopbackSocket(listening: true)
        let probes = ProxyPortAvailability.Probes.loopback(holder: { _ in nil })
        let held = ProxyPortAvailability.check(port: listener.port, settling: false, probes: probes)
        XCTAssertEqual(held.verdict, .held)
        XCTAssertEqual(held.bind, .addressInUse)
        XCTAssertEqual(held.connect, .accepted)

        listener.close()
        let free = ProxyPortAvailability.check(port: listener.port, settling: false, probes: probes)
        XCTAssertEqual(free.verdict, .free)
        XCTAssertEqual(free.bind, .bound)
    }

    func testTheConnectProbeTellsAcceptedFromRefused() throws {
        let listener = try LoopbackSocket(listening: true)
        XCTAssertEqual(ProxyPortAvailability.connectProbe(port: listener.port), .accepted)
        listener.close()
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(ProxyPortAvailability.connectProbe(port: listener.port), .refused)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, ProxyPortAvailability.connectTimeout,
                          "a refusal is an answer, not a wait for the bound")
    }

    /// Measured: a socket bound to the address and never listening takes it
    /// (EADDRINUSE for this bind, and for root's too), and the kernel drops a
    /// SYN to it without a reset — the connect TIMES OUT rather than being
    /// refused. The conservative row keeps it held. F10's lingering case is
    /// the other one: only closed connections, no socket to drop the SYN, so
    /// the connect is refused (as curl was, live). Those connections belonged
    /// to root; a test cannot make them, so that row is pinned by the table.
    func testAnAddressBoundByASocketThatNeverListensIsHeld() throws {
        let bound = try LoopbackSocket(listening: false)
        defer { bound.close() }
        XCTAssertEqual(ProxyPortAvailability.bindProbe(port: bound.port), .addressInUse)
        XCTAssertEqual(ProxyPortAvailability.connectProbe(port: bound.port), .timedOut)
        let finding = ProxyPortAvailability.check(port: bound.port, settling: true,
                                                  probes: .loopback(holder: { _ in nil }))
        XCTAssertEqual(finding.verdict, .held)
        XCTAssertEqual(finding.looks, 1, "a timeout is not probed again, even just after a stop")
    }

    /// A port tried for the suggestion gets less patience: a stalled one costs
    /// 50 ms, not the configured port's 0.3 s, and is not offered.
    func testACandidatePortThatStallsCostsLittleAndIsNotOffered() throws {
        let bound = try LoopbackSocket(listening: false)
        defer { bound.close() }
        let candidates = ProxyPortAvailability.Probes.loopback(holder: { _ in nil },
                                                               connectTimeout: ProxyPortAvailability.candidateConnectTimeout)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(ProxyPortAvailability.isFree(bound.port, probes: candidates))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, ProxyPortAvailability.connectTimeout,
                          "the candidate bound, not the configured port's")
    }

    /// Measured: `python3 -m http.server` and node's `listen(port)` listen on
    /// the wildcard address (dual-stack IPv6 by default), and this user's
    /// bind of 127.0.0.1 gets past them — the connect is what tells.
    func testThisUsersListenerOnTheWildcardAddressIsHeld() throws {
        for address in [LoopbackSocket.Address.wildcard, .wildcardDualStack] {
            let listener = try LoopbackSocket(listening: true, at: address)
            defer { listener.close() }
            let finding = ProxyPortAvailability.check(port: listener.port, settling: false,
                                                      probes: .loopback(holder: { _ in nil }))
            XCTAssertEqual(finding.bind, .bound, "\(address)")
            XCTAssertEqual(finding.connect, .accepted, "\(address)")
            XCTAssertEqual(finding.verdict, .held, "\(address)")
        }
    }

    /// An IPv6-only listener answers no 127.0.0.1 connect, and the
    /// extension's IPv4 bind takes nothing from it.
    func testAnIPv6OnlyListenerIsNotInTheWay() throws {
        let listener = try LoopbackSocket(listening: true, at: .wildcardIPv6Only)
        defer { listener.close() }
        let finding = ProxyPortAvailability.check(port: listener.port, settling: false,
                                                  probes: .loopback(holder: { _ in nil }))
        XCTAssertEqual(finding.bind, .bound)
        XCTAssertEqual(finding.connect, .refused)
        XCTAssertEqual(finding.verdict, .free)
    }

    /// Measured over 3,000 probes: a listener whose accept queue is full
    /// answers accepted or reset, never silence — held either way, on the
    /// wildcard address too, where a reset read as "could not tell" would
    /// have let the bind's "free" stand.
    func testABusyListenerIsHeld() throws {
        let listener = try LoopbackSocket(listening: true, at: .wildcard, backlog: 1)
        defer { listener.close() }
        let queued = (0..<64).map { _ in LoopbackSocket.connectWithoutWaiting(to: listener.port) }
        defer { queued.forEach { Darwin.close($0) } }
        usleep(20_000)
        for _ in 0..<10 {
            let finding = ProxyPortAvailability.check(port: listener.port, settling: false,
                                                      probes: .loopback(holder: { _ in nil }))
            XCTAssertEqual(finding.verdict, .held, finding.summary)
            XCTAssertEqual(finding.connect?.listenerAnswered, true, finding.summary)
        }
    }

    /// The errno a connect fails with at once, or the SO_ERROR it ends with,
    /// read one way. The reset row cannot be forced with real sockets — a
    /// full queue resets only some connects — so it is pinned here.
    func testWhatAConnectsErrorMeans() {
        XCTAssertEqual(ProxyPortAvailability.connectResult(error: 0), .accepted)
        XCTAssertEqual(ProxyPortAvailability.connectResult(error: ECONNRESET), .reset,
                       "a full accept queue resets: a listener answering, never 'could not tell'")
        XCTAssertEqual(ProxyPortAvailability.connectResult(error: ECONNREFUSED), .refused)
        XCTAssertEqual(ProxyPortAvailability.connectResult(error: ETIMEDOUT), .timedOut)
        XCTAssertEqual(ProxyPortAvailability.connectResult(error: ENETUNREACH), .unavailable)
    }

    func testAPortOutsideTheRangeIsNeverProbed() {
        XCTAssertEqual(ProxyPortAvailability.bindProbe(port: 70_000), .failed(EINVAL))
        XCTAssertEqual(ProxyPortAvailability.bindProbe(port: 0), .failed(EINVAL))
        XCTAssertEqual(ProxyPortAvailability.connectProbe(port: -1), .unavailable)
    }
}

/// Canned probes: each port answers from a script of looks — a bind starts
/// the next look, the connect and the listener lookup answer from it — and
/// the last look repeats. Every call and every pause is recorded, so nothing
/// sleeps and nothing touches a socket.
private final class ScriptedProbes {
    struct Look {
        var bind: ProxyPortAvailability.BindResult
        var connect: ProxyPortAvailability.ConnectResult = .refused
        var holder: String? = nil
    }

    private let scripts: [Int: [Look]]
    private var currentLook: [Int: Look] = [:]
    private(set) var binds: [Int] = []
    private(set) var connects: [Int] = []
    private(set) var holderLookups: [Int] = []
    private(set) var pauses: [TimeInterval] = []

    init(_ scripts: [Int: [Look]]) {
        self.scripts = scripts
    }

    var probes: ProxyPortAvailability.Probes {
        ProxyPortAvailability.Probes(
            bind: { [self] port in
                let script = scripts[port] ?? [Look(bind: .bound)]
                let look = script[min(binds.filter { $0 == port }.count, script.count - 1)]
                binds.append(port)
                currentLook[port] = look
                return look.bind
            },
            connect: { [self] port in
                connects.append(port)
                return currentLook[port]?.connect ?? .refused
            },
            holder: { [self] port in
                holderLookups.append(port)
                return currentLook[port]?.holder
            },
            pause: { [self] in pauses.append($0) }
        )
    }
}

/// A TCP socket at a port the kernel picks, listening or only bound: on
/// 127.0.0.1, or on the wildcard address as a dev server listens.
private final class LoopbackSocket {
    enum Address {
        case loopback
        /// 0.0.0.0
        case wildcard
        /// `::` taking IPv4 too — `python3 -m http.server`'s and node's default.
        case wildcardDualStack
        case wildcardIPv6Only
    }

    private var descriptor: Int32
    let port: Int

    init(listening: Bool, at place: Address = .loopback, backlog: Int32 = 8) throws {
        let ipv6 = place == .wildcardDualStack || place == .wildcardIPv6Only
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        let bound: Bool
        let boundPort: UInt16
        if ipv6 {
            var only: Int32 = place == .wildcardIPv6Only ? 1 : 0
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_any
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                    Darwin.bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
                }
            }
            boundPort = UInt16(bigEndian: address.sin6_port)
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr(place == .wildcard ? "0.0.0.0" : "127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                    Darwin.bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
                }
            }
            boundPort = UInt16(bigEndian: address.sin_port)
        }
        guard bound, !listening || listen(fd, backlog) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
        port = Int(boundPort)
    }

    /// A non-blocking connect to 127.0.0.1:`port`, left to the kernel — a
    /// connection the listener is never asked to accept. The caller closes it.
    static func connectWithoutWaiting(to port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return fd }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return fd
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}
