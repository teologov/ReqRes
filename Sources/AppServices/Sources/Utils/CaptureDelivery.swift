//
//  CaptureDelivery.swift
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
//  Is what capture records reaching THIS app? (F11, 2026-09-30; reattach,
//  build 53.)
//
//  Capture being on and rows arriving are two different facts. Rows reach the
//  app only over its message bus (127.0.0.1:50001), and only from an
//  extension that proved itself on it — the core's
//  `TCPServerBus.hasAuthenticatedExtension`. Since core 95062d1 a capture that
//  outlived the app no longer runs on for nobody: its extension redials the
//  app until one proves itself (`CaptureReattach`), and the relaunched app
//  gets what was captured meanwhile.
//
//  The verdict is made from primitives (`CaptureReattach`, a table-tested
//  state machine); every surface — the traffic pane, the menu bar item,
//  capture_status and diagnose_setup — renders the same verdict in the words
//  below.
//

import Foundation

/// Why the app's bus refused a connection — the core's
/// `RejectedBusClient.Reason`, mirrored by raw value (Utils cannot see the
/// core; the app maps through `rawValue`).
///
/// Only `unboundHello` is a FACT: it takes the install's own credential. Every
/// other reason can be produced by any local process that connects and says
/// the right (or the wrong) thing, so it only ever picks words — nothing is
/// decided from it (core 95062d1: "act only on hasAuthenticatedExtension").
public enum CaptureBusRefusal: String, CaseIterable, Sendable {
    /// Its first frame was not a `hello` — a local process that is not an
    /// extension, most likely. (F11 read it as an earlier build's extension;
    /// since channel binding an earlier extension says `unboundHello`.)
    case noHello
    /// Its `hello` carried no proof: an extension started without the app's
    /// start options (System Settings ▸ VPN, scutil), most likely.
    case noCredential
    /// Its proof was wrong: an extension started by a different install, one
    /// holding a key from before this install's certificate files changed, or
    /// a hello relayed from another connection.
    case badProof
    /// It said nothing within the handshake timeout.
    case timedOut
    /// The hello an extension from before channel binding sends — proved with
    /// this install's credential, so it really is a ReqRes extension, from
    /// an earlier build (1.1.0 (16) and before).
    case unboundHello
}

/// Why capture is on and nothing reaches this app.
public enum CaptureDeliveryProblem: String, CaseIterable, Sendable {
    /// The capture was already running when this app opened, and its
    /// extension has not reconnected within the grace.
    case appRelaunched
    /// The extension proved itself on this app's bus during this run, its
    /// connection closed, and it has not reconnected within the grace.
    case connectionLost
    /// Started from System Settings or scutil: no key to connect with.
    case startedOutsideReqRes
    /// The running capture's extension is from an earlier ReqRes build — the
    /// one reason the core reports that no other process can fake.
    case earlierExtension
    /// The extension did not prove it belongs to this install.
    case otherInstall
    /// A connection that never identified itself.
    case silentConnection
    /// This process does not hold the bus, and no other copy of ReqRes runs.
    case notListening
    /// Nothing explains it.
    case unexplained
}

/// The verdict every surface shows.
public enum CaptureDelivery: Equatable, Sendable {
    /// Capture is off or on its way on or off: nothing is owed yet.
    case notCapturing
    /// Capture is up and its extension has not proved itself yet, and it is
    /// not reconnecting either: the first moments of a start this app sent,
    /// when that is not over before the tunnel reads connected — or a capture
    /// whose extension was refused for a reason no redial gets past (started
    /// outside ReqRes, or an earlier build's), in the seconds before ReqRes
    /// restarts it.
    case waiting
    /// Capture this app did not just start — it was running when the app
    /// opened, or its extension's connection closed — and the extension has
    /// not proved itself yet: it redials until one does (core 95062d1), so
    /// this is the few seconds before what it captured meanwhile arrives.
    case reconnecting
    /// An extension has proved itself on this app's bus: rows arrive.
    case receiving
    /// Capture is on and nothing reaches this app. Restart Capture fixes it.
    case notReceiving(CaptureDeliveryProblem)
    /// Capture is on, this process does not hold the bus, and another copy of
    /// ReqRes is running — the one holding it, most likely. Whether THAT copy
    /// receives the rows is not known from here, so nothing claims it does.
    /// Nothing to restart here.
    case anotherCopy

    /// True for the two verdicts a person has to be told about.
    public var needsAttention: Bool {
        switch self {
        case .notReceiving, .anotherCopy: return true
        case .notCapturing, .waiting, .reconnecting, .receiving: return false
        }
    }

    /// Whether Restart Capture is offered: stopping and starting from this
    /// app makes the extension connect to it. Never for another copy —
    /// restarting there would take the capture away from the window
    /// receiving it — and not while the extension is still reconnecting.
    public var offersRestart: Bool {
        if case .notReceiving = self { return true }
        return false
    }
}

// MARK: - Words

/// Every sentence a person reads about delivery: the traffic pane's empty
/// state, its banner and its one-line notes, the menu bar item, and the alert
/// when a start cannot get the bus. capture_status and diagnose_setup print
/// `reason(for:)` too, inside their own agent wording (MCPKit).
public enum CaptureDeliveryCopy {
    public static let notReceivingTitle = "Capture is on, but ReqRes isn't receiving it"
    /// Only what is known (F11 review): this copy has no bus and another copy
    /// runs — most likely the one holding it. Whether that copy receives
    /// anything is not known here, so it is not claimed: the first wording,
    /// "…is receiving this capture", contradicted the other window whenever
    /// that copy had been relaunched too.
    public static let anotherCopyTitle = "Another copy of ReqRes holds this capture's connection"
    /// The menu bar's status line — shorter, and a line rather than a title.
    public static let menuNotReceiving = "Capture is on but not reaching ReqRes"
    public static let restartButton = "Restart Capture"
    public static let restartingTitle = "Restarting Capture…"
    public static let restartingDetail = "ReqRes is stopping capture and starting it again from this window, so the extension connects to it."

    // MARK: Reconnecting (build 53)

    /// The traffic pane's empty state and the menu bar's status line while a
    /// capture this app did not just start reconnects to it.
    public static let reconnectingTitle = "Reconnecting to the running capture…"
    public static let reconnectingDetail = "Capture kept running while ReqRes wasn't receiving it. Its extension reconnects by itself — usually within a few seconds — and what it captured meanwhile appears here."
    public static let menuReconnecting = reconnectingTitle

    /// Why, in one sentence. Shown under "Capture is on, but ReqRes isn't
    /// receiving it" — which is what remains when ReqRes cannot restart
    /// capture by itself, or did and it did not help — and printed by
    /// capture_status and diagnose_setup (`notReceivingDetail` adds what that
    /// restart did).
    public static func reason(for problem: CaptureDeliveryProblem) -> String {
        switch problem {
        case .appRelaunched:
            return "Capture kept running while ReqRes was closed, and its extension has not reconnected to ReqRes."
        case .connectionLost:
            return "The extension's connection to ReqRes closed, and it has not reconnected."
        case .startedOutsideReqRes:
            return "Capture appears to have been started outside ReqRes — from System Settings or scutil — so its extension has no key to connect to ReqRes with."
        case .earlierExtension:
            return "The running capture is from an earlier ReqRes build, whose extension cannot connect to this one. If restarting capture does not help, restart the Mac so macOS swaps in this build's extension."
        case .otherInstall:
            return "The running extension did not prove it belongs to this ReqRes — most likely it was started by another ReqRes install, or this install's certificate files changed since capture started."
        case .silentConnection:
            return "A connection to ReqRes never identified itself as its extension."
        case .notListening:
            return "This copy of ReqRes is not listening where its extension connects."
        case .unexplained:
            return "The extension has not connected to ReqRes since capture started."
        }
    }

    /// The reason, and what ReqRes's own restart already did in this stretch
    /// (`CaptureReattach.restartTriedThisStretch`): the pane's one-line note
    /// that says so is hidden while this notice shows, so it is said here —
    /// in the banner, the empty state and the agent's reason alike.
    public static func notReceivingDetail(for problem: CaptureDeliveryProblem, restartTried: CaptureStretchRestart?,
                                          busPort: Int) -> String {
        switch restartTried {
        case nil:
            return reason(for: problem)
        case .restarted?:
            return reason(for: problem) + " " + restartedOnceAlready
        case .failed(let failure)?:
            return reason(for: problem) + " " + automaticRestartFailedNote(failure, busPort: busPort)
        }
    }

    /// Said under the notice once ReqRes's one automatic restart of the
    /// stretch has been made and capture still does not reach it.
    public static let restartedOnceAlready = "ReqRes already restarted capture by itself once, and that did not help."

    /// Under the title when nothing has been captured yet — room for what
    /// the button does.
    public static func emptyStateDetail(for problem: CaptureDeliveryProblem) -> String {
        emptyStateDetail(for: problem, restartTried: nil, busPort: 0)
    }

    /// …with what ReqRes's own restart already did in this stretch.
    public static func emptyStateDetail(for problem: CaptureDeliveryProblem, restartTried: CaptureStretchRestart?,
                                        busPort: Int) -> String {
        notReceivingDetail(for: problem, restartTried: restartTried, busPort: busPort)
            + " Restart Capture stops capture and starts it again from this window, so the extension connects to it."
    }

    public static let anotherCopyDetail = "This window receives nothing new while the other copy holds it. Look in that copy's window — if it isn't receiving either, use Restart Capture there. To capture here instead, quit the other copy (quitting it stops its capture), then start capture here."

    /// The headline and detail for a verdict a person must be told about;
    /// nil for the others.
    public static func notice(for delivery: CaptureDelivery) -> (title: String, detail: String)? {
        switch delivery {
        case .notReceiving(let problem): return (notReceivingTitle, reason(for: problem))
        case .anotherCopy: return (anotherCopyTitle, anotherCopyDetail)
        case .notCapturing, .waiting, .reconnecting, .receiving: return nil
        }
    }

    // MARK: The one-line notes (build 53)

    /// After a reattach: what the extension delivered, and what it could not
    /// keep (its queue holds the newest 512 messages, so the OLDEST rows go).
    /// Nil when there is nothing to say.
    ///
    /// `appWasClosed`: the capture outlived the app (or the copy of it that
    /// was receiving). False when this app was running all along and only the
    /// extension's connection to it closed.
    public static func reattachSummary(capturedWhileDetached captured: Int, droppedRows dropped: Int, appWasClosed: Bool) -> String? {
        let captured = max(0, captured)
        let dropped = max(0, dropped)
        guard captured > 0 || dropped > 0 else { return nil }
        let meanwhile = appWasClosed ? "while ReqRes was closed" : "while the extension was reconnecting to ReqRes"
        guard captured > 0 else {
            return "\(requests(dropped)) captured \(meanwhile) \(dropped == 1 ? "was" : "were") not kept."
        }
        let kept = "\(requests(captured)) \(captured == 1 ? "was" : "were") captured \(meanwhile)"
        guard dropped > 0 else { return kept + "." }
        return kept + "; \(grouped(dropped)) earlier \(dropped == 1 ? "one was" : "ones were") not kept."
    }

    /// The line said when ReqRes restarted capture by itself, once, because
    /// the running capture could not reattach.
    public static func automaticRestartNote(for problem: CaptureDeliveryProblem) -> String {
        switch problem {
        case .appRelaunched:
            return "Capture kept running while ReqRes was closed and its extension did not reconnect, so ReqRes restarted capture."
        case .connectionLost:
            return "The extension's connection to ReqRes closed and it did not reconnect, so ReqRes restarted capture."
        case .startedOutsideReqRes:
            return "Capture appeared to have been started outside ReqRes, without the key its extension connects with, so ReqRes restarted it."
        case .earlierExtension:
            return "The running capture was from an earlier ReqRes build, so ReqRes restarted it."
        case .otherInstall:
            // Hedged like `reason(for:)`: any local process can send a hello
            // with a wrong proof. What is known is that no extension
            // connected — that is what the restart was decided on.
            return "The extension did not connect to ReqRes — most likely it was started by another ReqRes install — so ReqRes restarted capture."
        case .silentConnection, .notListening, .unexplained:
            return "The extension did not connect to ReqRes, so ReqRes restarted capture."
        }
    }

    /// The note when the restart ReqRes made by itself stopped capture and
    /// sent its start, and capture never came up again — the system or the
    /// extension refused it ("Capture did not start" says why, when it can).
    public static let automaticRestartDidNotStartNote = "ReqRes stopped capture to restart it by itself, and capture did not start again."

    /// The empty pane's detail while that restart runs.
    public static func automaticRestartingDetail(for problem: CaptureDeliveryProblem) -> String {
        reason(for: problem) + " ReqRes is stopping capture and starting it again from this window, once, so the extension connects to it."
    }

    // MARK: A start that cannot get the bus

    public static let channelUnavailableTitle = "Capture did not start"

    /// Why a start was refused before it began: this process could not bind
    /// the bus the extension delivers to.
    public static func channelUnavailableMessage(busPort: Int, anotherCopyRunning: Bool) -> String {
        anotherCopyRunning
            ? "Another copy of ReqRes is running and holds 127.0.0.1:\(busPort), where the extension delivers what it captures. Use that copy, or quit it and start capture here."
            : "ReqRes could not open 127.0.0.1:\(busPort), where the extension delivers what it captures — another program is using it. Quit that program and start capture again."
    }

    // MARK: A Restart Capture that did not restart

    public static let restartFailedTitle = "Capture was not restarted"

    /// Said to the person who clicked Restart Capture when its start did not
    /// go out (F11 review). It used to end in a log line only, and they saw
    /// the old notice come back — or "Start Network Monitoring" — with no
    /// reason. Whether capture was left running is part of every message.
    public static func restartFailedMessage(_ failure: CaptureRestartFailure, busPort: Int) -> String {
        switch failure {
        case .channelUnavailable(let anotherCopyRunning):
            return anotherCopyRunning
                ? "Another copy of ReqRes is running and holds 127.0.0.1:\(busPort), where the extension delivers what it captures, so capture was left running as it was. Use that copy, or quit it and restart capture here."
                : "ReqRes could not open 127.0.0.1:\(busPort), where the extension delivers what it captures — another program is using it — so capture was left running as it was. Quit that program and restart capture."
        case .configurationUnreadable(let reason):
            return "ReqRes could not read its capture configuration (\(reason)), so capture was left as it was. Try Restart Capture again in a moment."
        case .didNotStop:
            return "Capture did not stop within \(Int(CaptureRestart.stopTimeout)) seconds, so ReqRes did not start it again. Try Restart Capture again in a moment."
        case .startRefused(let reason):
            return "Capture stopped, and the system refused to start it again (\(reason)). Start capture from the toolbar to try again."
        }
    }

    /// The note when the restart ReqRes made by itself did not go through.
    /// Its own words, not the person's alert with a prefix: the person did
    /// not click anything, so nothing says to try it "again", and nothing
    /// points at a button the pane may not be showing (F11 review of build
    /// 53). Whether capture was left running is part of every one.
    public static func automaticRestartFailedNote(_ failure: CaptureRestartFailure, busPort: Int) -> String {
        switch failure {
        case .channelUnavailable(let anotherCopyRunning):
            return anotherCopyRunning
                ? "ReqRes tried to restart capture by itself, but another copy of ReqRes holds 127.0.0.1:\(busPort), where the extension delivers what it captures, so capture was left running as it was."
                : "ReqRes tried to restart capture by itself, but could not open 127.0.0.1:\(busPort), where the extension delivers what it captures — another program is using it — so capture was left running as it was."
        case .configurationUnreadable(let reason):
            return "ReqRes tried to restart capture by itself, but could not read its capture configuration (\(reason)), so capture was left as it was."
        case .didNotStop:
            return "ReqRes tried to restart capture by itself, but capture did not stop within \(Int(CaptureRestart.stopTimeout)) seconds, so ReqRes did not start it again."
        case .startRefused(let reason):
            return "ReqRes stopped capture to restart it by itself, and the system refused to start it again (\(reason))."
        }
    }

    private static func requests(_ count: Int) -> String {
        count == 1 ? "1 request" : "\(grouped(count)) requests"
    }

    /// "25,000": grouped like the app's other counts in English copy
    /// (`StreamEventsPresentation.grouped`, which Utils cannot import), and
    /// the same on every Mac, whatever its locale, like the words around it.
    static func grouped(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }
}

/// Why a Restart Capture ended without its start going out (F11 review).
public enum CaptureRestartFailure: Equatable, Sendable {
    /// This copy cannot open the bus the extension delivers to. Checked
    /// BEFORE the stop, so capture was left running: a restart is a stop and
    /// then a start, and only the start needs the bus — it used to stop first
    /// and then be refused, turning a restart into a plain stop.
    case channelUnavailable(anotherCopyRunning: Bool)
    /// The saved configuration could not be read; nothing was stopped.
    case configurationUnreadable(String)
    /// The stop did not finish in time; nothing was started.
    case didNotStop
    /// The stop went through and the system refused the start.
    case startRefused(String)
}

/// How a Restart Capture ended (build 53): the automatic restart says the
/// first and the last, and stays silent about the rest.
public enum CaptureRestartOutcome: Equatable, Sendable {
    /// Capture was stopped and its start sent.
    case startSent
    /// Nothing was running to restart (no configuration, or the tunnel was
    /// already stopping or stopped).
    case nothingToRestart
    /// A start or stop was asked for since the restart began, and stands.
    case stoodDown
    /// The start was not sent and that was already said (the busy-port
    /// question, the bus alert).
    case notSent
    /// An extension reattached before the automatic restart stopped
    /// anything: nothing was restarted, and nothing is said.
    case noLongerNeeded
    case failed(CaptureRestartFailure)
}
