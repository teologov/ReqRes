//
//  ProxyPortAvailability.swift
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
//  Whether the proxy's port is free before capture starts (F10, observed live
//  2026-09-30). The preflight used to bind 127.0.0.1:N itself and call ANY
//  EADDRINUSE "another program is listening": a start 16 s after a stop was
//  refused with "Port 8035 is in use" while a connect to 8035 was refused and
//  nothing listened there, and a user's port walked 8034 → 8035 → 8036
//  through the alert. Starts 34 s and later passed.
//
//  The kernel's rule behind it (XNU `in_pcbbind`): a NON-root bind fails with
//  EADDRINUSE while a socket of ANOTHER uid still holds the address, whatever
//  SO_REUSEADDR says. A stopped proxy's closed connections are root's — the
//  extension runs as root — and wait out TIME_WAIT (about 30 s on macOS);
//  root is exempt, so the extension binds over them. The app cannot, and
//  took them for a listener.
//
//  So the bind alone is not the answer: an EADDRINUSE while NOTHING accepts a
//  connection and no listener can be named is lingering connections — most
//  often ReqRes's own — and not a conflict. Anything the probes cannot settle
//  stays a conflict, as before; the extension's own bind is the last word
//  either way, and a start it refuses is said, not left silent
//  (`CaptureTunnelWatch`).
//
//  Nor is a bind that SUCCEEDS the whole answer (review, same day): with
//  SO_REUSEADDR it gets 127.0.0.1:N beside a listener of this same user on
//  the wildcard address — `python3 -m http.server N` and node's `listen(N)`
//  by default, measured — and the extension, binding the same way as root,
//  would then take that listener's 127.0.0.1 connections without a word. So
//  a bind that succeeds is asked too, and a listener answering there holds
//  the port.
//

import Foundation

public enum ProxyPortAvailability {
    /// What binding 127.0.0.1:N said (`bindProbe`).
    public enum BindResult: Equatable, Sendable {
        case bound
        case addressInUse
        /// Any other errno. Not a conflict, as before this type existed: the
        /// extension's own bind decides, and a start it fails is reported.
        case failed(Int32)
    }

    /// What a TCP connect to 127.0.0.1:N said (`connectProbe`).
    public enum ConnectResult: Equatable, Sendable {
        case accepted
        /// A listener took the handshake, then reset it: busy or closing. A
        /// listener whose accept queue is full answers accepted or reset,
        /// never silence (measured) — something listens there either way.
        case reset
        case refused
        /// No answer within the probe's bound: an address held by a socket
        /// that is bound and never listens — the kernel drops the SYN without
        /// a reset (measured). Never read as "nothing there" when the bind
        /// was refused too.
        case timedOut
        /// The probe could not run (no socket, an unexpected error).
        case unavailable

        /// A listener answered the connect: it accepted, or reset it while
        /// busy or closing.
        public var listenerAnswered: Bool { self == .accepted || self == .reset }
    }

    public enum Verdict: Equatable, Sendable {
        /// The bind succeeded and no listener answered there, or it failed
        /// for a reason other than EADDRINUSE.
        case free
        /// EADDRINUSE, but no listener answers a connect and none can be
        /// named: closed connections of another uid waiting out TIME_WAIT —
        /// most often ReqRes's own, after a stop. Free for the extension,
        /// which binds as root.
        case lingering
        /// A listener answers connections there; or the bind said EADDRINUSE
        /// and the socket table names a listener, or the probe could not tell.
        case held

        public var isFree: Bool { self != .held }
    }

    /// The decision, from the probes' results. `holderNamed` matters only
    /// when the bind said EADDRINUSE, and `connect` not at all when the bind
    /// failed otherwise.
    ///
    ///   bind            connect                           listener named   verdict
    ///   bound           accepted / reset                  either           held
    ///   bound           refused / timedOut / unavailable  either           free
    ///   failed(errno)   —                                 —                free
    ///   addressInUse    accepted / reset                  either           held
    ///   addressInUse    refused                           yes              held
    ///   addressInUse    refused                           no               lingering
    ///   addressInUse    timedOut / unavailable            either           held
    ///
    /// A bind that succeeds is overruled only by a listener answering: this
    /// user's listener on the wildcard address, which the extension's bind
    /// would rob of its 127.0.0.1 connections. A wildcard socket that never
    /// listens (timedOut) takes nothing, and the extension binds past it.
    public static func verdict(bind: BindResult, connect: ConnectResult, holderNamed: Bool) -> Verdict {
        switch bind {
        case .failed:
            return .free
        case .bound:
            return connect.listenerAnswered ? .held : .free
        case .addressInUse:
            switch connect {
            case .refused: return holderNamed ? .held : .lingering
            case .accepted, .reset, .timedOut, .unavailable: return .held
            }
        }
    }

    // MARK: Checking a port

    /// A port that still answers less than this long after ReqRes's tunnel
    /// went down (`CaptureTunnelWatch.stoppedRecently`) is re-probed before it
    /// counts as held: the proxy's listener closes only when its event loops
    /// have shut down, a moment after the tunnel reports it stopped.
    public static let settlingWindow: TimeInterval = 2
    /// How many re-probes, and the wait before each — at most 0.9 s, on the
    /// main thread, and only while the port keeps answering.
    public static let settlingReprobes = 3
    public static let settlingInterval: TimeInterval = 0.3
    /// The connect probe's bound. The preflight runs on the main thread, and a
    /// loopback connect answers in microseconds — even a full backlog answers
    /// at once — unless the SYN is dropped.
    public static let connectTimeout: TimeInterval = 0.3
    /// The bound for a port offered INSTEAD, of which the suggestion scans up
    /// to fifty (`ProxyPortSetting.suggestion`): the same decision with less
    /// patience — a candidate whose bind is refused and that does not answer
    /// at once is simply not offered, and the scan stays under three seconds
    /// even if every port after the busy one stalls.
    public static let candidateConnectTimeout: TimeInterval = 0.05

    /// The probes a check runs: sockets in the app (`loopback`), canned
    /// answers and a recorded pause in tests.
    public struct Probes {
        public var bind: (Int) -> BindResult
        public var connect: (Int) -> ConnectResult
        /// The process listening on the port, when the socket table can say.
        /// The app's is the core's `ListeningPortOwner`, which Utils cannot
        /// import.
        public var holder: (Int) -> String?
        /// Waits between re-probes.
        public var pause: (TimeInterval) -> Void

        public init(bind: @escaping (Int) -> BindResult,
                    connect: @escaping (Int) -> ConnectResult,
                    holder: @escaping (Int) -> String?,
                    pause: @escaping (TimeInterval) -> Void) {
            self.bind = bind
            self.connect = connect
            self.holder = holder
            self.pause = pause
        }

        /// Real sockets on 127.0.0.1, with the caller's listener lookup.
        public static func loopback(holder: @escaping (Int) -> String?,
                                    connectTimeout: TimeInterval = ProxyPortAvailability.connectTimeout) -> Probes {
            Probes(bind: { bindProbe(port: $0) },
                   connect: { connectProbe(port: $0, timeout: connectTimeout) },
                   holder: holder,
                   pause: { Thread.sleep(forTimeInterval: $0) })
        }
    }

    /// What one check found.
    public struct Finding: Equatable, Sendable {
        public var verdict: Verdict
        public var bind: BindResult
        /// Nil when the bind alone decided (another error than EADDRINUSE).
        public var connect: ConnectResult?
        /// The listener's name, when the socket table can say.
        public var holder: String?
        /// How many times the port was looked at: more than one only when the
        /// tunnel had just stopped and a listener still answered.
        public var looks: Int

        /// One line for the log.
        public var summary: String {
            var parts = ["bind \(bind)"]
            if let connect { parts.append("connect \(connect)") }
            parts.append(holder.map { "listener \($0)" } ?? "no listener named")
            if looks > 1 { parts.append("\(looks) looks") }
            return "\(verdict) (" + parts.joined(separator: ", ") + ")"
        }
    }

    /// Whether `port` is free for the proxy. `settling`: ReqRes's own tunnel
    /// went down moments ago, so a port that still answers is most likely its
    /// listener finishing its shutdown — looked at again, up to
    /// `settlingReprobes` times, before it counts as held. Only that shape is
    /// re-probed: a listener answering where the bind said EADDRINUSE.
    /// ReqRes's listener is root's, on exactly 127.0.0.1, so this bind never
    /// gets past it — a listener it does get past is this user's — and a
    /// timeout has already cost its full bound.
    public static func check(port: Int, settling: Bool, probes: Probes) -> Finding {
        var finding = look(at: port, probes: probes)
        guard settling else { return finding }
        var looks = 1
        while finding.bind == .addressInUse, finding.connect?.listenerAnswered == true, looks <= settlingReprobes {
            probes.pause(settlingInterval)
            finding = look(at: port, probes: probes)
            looks += 1
        }
        finding.looks = looks
        return finding
    }

    /// The same decision as a predicate, for the port suggested instead
    /// (`ProxyPortSetting.suggestion`): a port with only lingering connections
    /// on it is offered, and one the preflight would refuse is not.
    public static func isFree(_ port: Int, probes: Probes) -> Bool {
        check(port: port, settling: false, probes: probes).verdict.isFree
    }

    /// One look. Another bind error decides alone; otherwise a connect asks
    /// whether a listener answers, and the socket table is walked only when
    /// something may hold the port — a free port costs one bind and one
    /// refused connect.
    private static func look(at port: Int, probes: Probes) -> Finding {
        let bind = probes.bind(port)
        if case .failed = bind {
            return Finding(verdict: .free, bind: bind, connect: nil, holder: nil, looks: 1)
        }
        let connect = probes.connect(port)
        let holder = bind == .addressInUse || connect.listenerAnswered ? probes.holder(port) : nil
        return Finding(verdict: verdict(bind: bind, connect: connect, holderNamed: holder != nil),
                       bind: bind, connect: connect, holder: holder, looks: 1)
    }

    // MARK: The preflight

    /// What the preflight found for the configured port: the check (for the
    /// log) and, when the port is held, a port to offer instead.
    public struct Preflight: Equatable, Sendable {
        public var finding: Finding
        /// Only when the port is held, and never one this same decision
        /// would refuse.
        public var suggestion: Int?

        /// Whether capture must not start there. Lingering connections are
        /// not a conflict (F10): the extension binds past them.
        public var isConflict: Bool { !finding.verdict.isFree }
    }

    /// The whole decision `CaptureProxyPort.conflict` acts on. `candidates`
    /// probe the ports tried for the suggestion (less patient:
    /// `candidateConnectTimeout`), never the configured one.
    public static func preflight(port: Int, settling: Bool, probes: Probes, candidates: Probes) -> Preflight {
        let finding = check(port: port, settling: settling, probes: probes)
        guard !finding.verdict.isFree else { return Preflight(finding: finding, suggestion: nil) }
        return Preflight(finding: finding,
                         suggestion: ProxyPortSetting.suggestion(after: port) { isFree($0, probes: candidates) })
    }

    // MARK: The real probes

    /// Binds 127.0.0.1:`port` with SO_REUSEADDR, as the extension's listener
    /// does. SO_REUSEADDR lets a bind past closed connections lingering in
    /// TIME_WAIT only when they belong to the SAME uid: a non-root bind past
    /// another uid's still fails with EADDRINUSE, and the stopped extension's
    /// are root's — which is why EADDRINUSE here is never the whole answer.
    public static func bindProbe(port: Int) -> BindResult {
        guard var address = loopbackAddress(port: port) else { return .failed(EINVAL) }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failed(errno) }
        defer { close(descriptor) }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return .bound }
        let code = errno
        return code == EADDRINUSE ? .addressInUse : .failed(code)
    }

    /// Connects to 127.0.0.1:`port`, non-blocking and bounded by `timeout`:
    /// a blocking connect to an address whose SYN is dropped waits for the
    /// kernel's own timeout (measured: 7.8 s, SO_SNDTIMEO or not), and this
    /// runs on the main thread. Tells accepted, reset, refused and timed out
    /// apart — `MCPServerService.isListening` answers false for all but
    /// accepted.
    public static func connectProbe(port: Int, timeout: TimeInterval = connectTimeout) -> ConnectResult {
        guard var address = loopbackAddress(port: port) else { return .unavailable }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .unavailable }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return .unavailable }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return .accepted }
        let code = errno
        guard code == EINPROGRESS else { return connectResult(error: code) }
        // The handshake is under way: wait for it to end, one way or the other.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return .timedOut }
            let ready = poll(&pending, 1, Int32((remaining * 1000).rounded(.up)))
            if ready > 0 { break }
            if ready == 0 { return .timedOut }
            if errno != EINTR { return .unavailable }
        }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return .unavailable }
        return connectResult(error: error)
    }

    /// What a connect's error means, read the same way on both of
    /// `connectProbe`'s paths: the errno it failed with at once, or the
    /// socket's SO_ERROR once the handshake ended (0: accepted).
    static func connectResult(error: Int32) -> ConnectResult {
        switch error {
        case 0: return .accepted
        // A full accept queue drops a connection it cannot hold with a reset
        // (measured): a listener answering, never "could not tell".
        case ECONNRESET: return .reset
        case ECONNREFUSED: return .refused
        case ETIMEDOUT: return .timedOut
        default: return .unavailable
        }
    }

    private static func loopbackAddress(port: Int) -> sockaddr_in? {
        guard let port = UInt16(exactly: port), port != 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(port.bigEndian)
        return address
    }
}
