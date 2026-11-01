//
//  CaptureDeliveryTests.swift
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
//  F11 (2026-09-30): capture on is not rows arriving. The verdict's words,
//  and what each verdict offers. How the verdict is reached — and, since build
//  53, the reattach that makes the relaunch case pass by itself — is
//  CaptureReattachTests.
//

import XCTest
@testable import Utils

final class CaptureDeliveryTests: XCTestCase {

    /// The core maps its reasons by raw value; a renamed case on either side
    /// would drop the explanation silently. Core 95062d1 added `unboundHello`.
    func testTheRefusalsAreTheCoresReasonsByRawValue() {
        XCTAssertEqual(Set(CaptureBusRefusal.allCases.map(\.rawValue)),
                       ["noHello", "noCredential", "badProof", "timedOut", "unboundHello"])
    }

    // MARK: - Restart and attention

    func testOnlyNotReceivingOffersRestart() {
        for problem in CaptureDeliveryProblem.allCases {
            XCTAssertTrue(CaptureDelivery.notReceiving(problem).offersRestart, "\(problem)")
            XCTAssertTrue(CaptureDelivery.notReceiving(problem).needsAttention)
        }
        XCTAssertFalse(CaptureDelivery.anotherCopy.offersRestart, "restarting would take the capture from the window receiving it")
        XCTAssertTrue(CaptureDelivery.anotherCopy.needsAttention)
        for quiet in [CaptureDelivery.notCapturing, .waiting, .reconnecting, .receiving] {
            XCTAssertFalse(quiet.offersRestart, "\(quiet)")
            XCTAssertFalse(quiet.needsAttention, "\(quiet)")
        }
    }

    // MARK: - Words

    func testEveryProblemHasItsOwnReason() {
        let reasons = CaptureDeliveryProblem.allCases.map(CaptureDeliveryCopy.reason(for:))
        XCTAssertEqual(Set(reasons).count, reasons.count, "two problems explained the same way")
        for (problem, reason) in zip(CaptureDeliveryProblem.allCases, reasons) {
            XCTAssertFalse(reason.isEmpty, "\(problem)")
            XCTAssertTrue(reason.hasSuffix("."), "\(problem): ended")
            XCTAssertTrue(CaptureDeliveryCopy.emptyStateDetail(for: problem).hasPrefix(reason))
            XCTAssertTrue(CaptureDeliveryCopy.emptyStateDetail(for: problem).contains(CaptureDeliveryCopy.restartButton),
                          "the empty state says what its button does")
        }
        XCTAssertTrue(CaptureDeliveryCopy.reason(for: .appRelaunched).contains("while ReqRes was closed"))
        XCTAssertTrue(CaptureDeliveryCopy.reason(for: .connectionLost).contains("closed"))
        XCTAssertFalse(CaptureDeliveryCopy.reason(for: .connectionLost).contains("has not connected"),
                       "it did connect: the unexplained sentence is the one that must not be used")
        XCTAssertTrue(CaptureDeliveryCopy.reason(for: .startedOutsideReqRes).contains("outside ReqRes"))
        XCTAssertTrue(CaptureDeliveryCopy.reason(for: .earlierExtension).contains("earlier"))
    }

    /// Core 95062d1 redials the app: nothing may still say the extension
    /// connects only when capture starts (the F11 sentences, true of build 52).
    func testNoSentenceSaysTheExtensionOnlyConnectsAtAStart() {
        var sentences = CaptureDeliveryProblem.allCases.flatMap {
            [CaptureDeliveryCopy.reason(for: $0), CaptureDeliveryCopy.emptyStateDetail(for: $0),
             CaptureDeliveryCopy.automaticRestartNote(for: $0), CaptureDeliveryCopy.automaticRestartingDetail(for: $0)]
        }
        sentences += [CaptureDeliveryCopy.reconnectingTitle, CaptureDeliveryCopy.reconnectingDetail,
                      CaptureDeliveryCopy.restartingDetail, CaptureDeliveryCopy.anotherCopyDetail]
        for sentence in sentences {
            XCTAssertFalse(sentence.contains("only when capture starts"), sentence)
            XCTAssertFalse(sentence.contains("again only when"), sentence)
        }
    }

    /// `unboundHello` is a fact — the version is named plainly — and a
    /// restart that did not swap it ends in the Mac's restart.
    func testTheEarlierBuildIsNamedAsAFact() {
        let reason = CaptureDeliveryCopy.reason(for: .earlierExtension)
        XCTAssertTrue(reason.hasPrefix("The running capture is from an earlier ReqRes build"), reason)
        XCTAssertFalse(reason.contains("most likely"), "unforgeable: no hedge — \(reason)")
        XCTAssertTrue(reason.contains("restart the Mac"), reason)
    }

    /// The forgeable reasons stay hedged: any local process could have
    /// produced them — in the notice, and in the note when ReqRes restarted
    /// capture over one (review: "did not prove it belongs" was stated as a
    /// fact there).
    func testTheForgeableReasonsAreHedged() {
        XCTAssertTrue(CaptureDeliveryCopy.reason(for: .startedOutsideReqRes).contains("appears"))
        XCTAssertTrue(CaptureDeliveryCopy.reason(for: .otherInstall).contains("most likely"))
        let outside = CaptureDeliveryCopy.automaticRestartNote(for: .startedOutsideReqRes)
        XCTAssertTrue(outside.contains("appeared"), outside)
        let other = CaptureDeliveryCopy.automaticRestartNote(for: .otherInstall)
        XCTAssertTrue(other.contains("most likely"), other)
        XCTAssertFalse(other.contains("did not prove"), "a forgeable reason, not a fact: \(other)")
    }

    /// The one line said when ReqRes restarted capture by itself — for an
    /// earlier build: that the running capture was from an earlier ReqRes
    /// build, and that ReqRes restarted it.
    func testTheAutomaticRestartSaysWhyAndThatReqResRestartedIt() {
        let earlier = CaptureDeliveryCopy.automaticRestartNote(for: .earlierExtension)
        XCTAssertTrue(earlier.contains("from an earlier ReqRes build"), earlier)
        XCTAssertTrue(earlier.contains("ReqRes restarted it"), earlier)
        for problem in CaptureDeliveryProblem.allCases {
            let note = CaptureDeliveryCopy.automaticRestartNote(for: problem)
            XCTAssertTrue(note.contains("ReqRes restarted"), "\(problem): \(note)")
            XCTAssertTrue(note.hasSuffix("."), "\(problem): one sentence, ended")
            XCTAssertFalse(note.contains("\n"), "one line: \(note)")
            let restarting = CaptureDeliveryCopy.automaticRestartingDetail(for: problem)
            XCTAssertTrue(restarting.hasPrefix(CaptureDeliveryCopy.reason(for: problem)), restarting)
            XCTAssertTrue(restarting.contains("once"), "says it is the one restart: \(restarting)")
        }
    }

    /// What a reattach delivered, counted plainly, with the plural right and
    /// nothing said when there is nothing to say.
    func testTheReattachSummary() {
        let table: [(Int, Int, Bool, String?)] = [
            (0, 0, true, nil),
            (0, 0, false, nil),
            (1, 0, true, "1 request was captured while ReqRes was closed."),
            (40, 0, true, "40 requests were captured while ReqRes was closed."),
            (40, 1, true, "40 requests were captured while ReqRes was closed; 1 earlier one was not kept."),
            (40, 12, true, "40 requests were captured while ReqRes was closed; 12 earlier ones were not kept."),
            // Grouped like the app's other counts (review: "25000").
            (512, 25000, true, "512 requests were captured while ReqRes was closed; 25,000 earlier ones were not kept."),
            (1204, 0, false, "1,204 requests were captured while the extension was reconnecting to ReqRes."),
            (0, 2048, true, "2,048 requests captured while ReqRes was closed were not kept."),
            (3, 0, false, "3 requests were captured while the extension was reconnecting to ReqRes."),
            (0, 1, true, "1 request captured while ReqRes was closed was not kept."),
            (0, 7, true, "7 requests captured while ReqRes was closed were not kept."),
            (-2, -5, true, nil),
        ]
        for (captured, dropped, closed, expected) in table {
            XCTAssertEqual(CaptureDeliveryCopy.reattachSummary(capturedWhileDetached: captured, droppedRows: dropped, appWasClosed: closed),
                           expected, "\(captured)/\(dropped)/\(closed)")
        }
    }

    func testTheNotesText() {
        XCTAssertEqual(CaptureReattachNotice.reattached(capturedWhileDetached: 2, droppedRows: 0, appWasClosed: true).text(busPort: 50001),
                       "2 requests were captured while ReqRes was closed.")
        XCTAssertEqual(CaptureReattachNotice.restartedAutomatically(.appRelaunched).text(busPort: 50001),
                       CaptureDeliveryCopy.automaticRestartNote(for: .appRelaunched))
        let failed = CaptureReattachNotice.automaticRestartFailed(.didNotStop).text(busPort: 50001)
        XCTAssertEqual(failed, CaptureDeliveryCopy.automaticRestartFailedNote(.didNotStop, busPort: 50001))
        XCTAssertTrue(failed.hasPrefix("ReqRes tried to restart capture by itself"), failed)
        XCTAssertTrue(CaptureReattachNotice.automaticRestartFailed(.didNotStop).isProblem)
        XCTAssertEqual(CaptureReattachNotice.automaticRestartDidNotStart.text(busPort: 50001),
                       "ReqRes stopped capture to restart it by itself, and capture did not start again.")
        XCTAssertTrue(CaptureReattachNotice.automaticRestartDidNotStart.isProblem)
        XCTAssertFalse(CaptureReattachNotice.restartedAutomatically(.appRelaunched).isProblem)
        XCTAssertFalse(CaptureReattachNotice.reattached(capturedWhileDetached: 1, droppedRows: 0, appWasClosed: true).isProblem)
    }

    func testReconnectingIsSaidForWhatItIs() {
        XCTAssertEqual(CaptureDeliveryCopy.reconnectingTitle, "Reconnecting to the running capture…")
        XCTAssertEqual(CaptureDeliveryCopy.menuReconnecting, CaptureDeliveryCopy.reconnectingTitle)
        XCTAssertTrue(CaptureDeliveryCopy.reconnectingDetail.contains("appears here"))
        XCTAssertNil(CaptureDeliveryCopy.notice(for: .reconnecting), "nothing to fix: no notice")
    }

    func testANoticeOnlyForWhatNeedsAttention() {
        XCTAssertEqual(CaptureDeliveryCopy.notice(for: .notReceiving(.appRelaunched))?.title, "Capture is on, but ReqRes isn't receiving it")
        XCTAssertEqual(CaptureDeliveryCopy.notice(for: .notReceiving(.appRelaunched))?.detail, CaptureDeliveryCopy.reason(for: .appRelaunched))
        XCTAssertEqual(CaptureDeliveryCopy.notice(for: .anotherCopy)?.title, "Another copy of ReqRes holds this capture's connection")
        for quiet in [CaptureDelivery.notCapturing, .waiting, .reconnecting, .receiving] {
            XCTAssertNil(CaptureDeliveryCopy.notice(for: quiet), "\(quiet)")
        }
        XCTAssertEqual(CaptureDeliveryCopy.menuNotReceiving, "Capture is on but not reaching ReqRes")
        XCTAssertEqual(CaptureDeliveryCopy.restartButton, "Restart Capture")
    }

    /// Another copy running is known; that it RECEIVES the capture is not —
    /// it may have been relaunched too, and then the two windows contradicted
    /// each other (F11 review). Nothing claims it.
    func testAnotherCopyClaimsOnlyWhatIsKnown() throws {
        let notice = try XCTUnwrap(CaptureDeliveryCopy.notice(for: .anotherCopy))
        for text in [notice.title, notice.detail] {
            XCTAssertFalse(text.contains("is receiving this capture"), text)
            XCTAssertFalse(text.contains("lists what this capture records"), text)
        }
        XCTAssertTrue(notice.detail.contains("if it isn't receiving either"), notice.detail)
        XCTAssertTrue(notice.detail.contains("quitting it stops its capture"), "says what quitting the other copy costs")
    }

    /// Every way a Restart Capture can end without its start says so, and
    /// says whether capture was left running — the person who clicked it saw
    /// only the old notice come back (F11 review).
    func testEveryRestartFailureSaysWhetherCaptureWasLeftRunning() {
        let failures: [CaptureRestartFailure] = [
            .channelUnavailable(anotherCopyRunning: true),
            .channelUnavailable(anotherCopyRunning: false),
            .configurationUnreadable("the system did not answer"),
            .didNotStop,
            .startRefused("configuration disabled"),
        ]
        let messages = failures.map { CaptureDeliveryCopy.restartFailedMessage($0, busPort: 50001) }
        XCTAssertEqual(Set(messages).count, messages.count, "two failures explained the same way")
        for (failure, message) in zip(failures, messages) {
            XCTAssertTrue(message.hasSuffix("."), "\(failure): \(message)")
            switch failure {
            case .channelUnavailable(let another):
                XCTAssertTrue(message.contains("127.0.0.1:50001"), message)
                XCTAssertTrue(message.contains("capture was left running"), "checked before anything was stopped: \(message)")
                XCTAssertEqual(message.contains("Another copy of ReqRes"), another, message)
            case .configurationUnreadable(let reason):
                XCTAssertTrue(message.contains(reason), message)
                XCTAssertTrue(message.contains("capture was left as it was"), message)
            case .didNotStop:
                XCTAssertTrue(message.contains("\(Int(CaptureRestart.stopTimeout)) seconds"), message)
                XCTAssertTrue(message.contains("did not start it again"), message)
            case .startRefused(let reason):
                XCTAssertTrue(message.contains(reason), message)
                XCTAssertTrue(message.contains("Capture stopped"), "the stop went through: \(message)")
            }
        }
        XCTAssertEqual(CaptureDeliveryCopy.restartFailedTitle, "Capture was not restarted")
    }

    /// A start that cannot get the bus names the port, and blames another
    /// copy only when one is running.
    func testAStartWithoutTheBusSaysWhy() {
        let copy = CaptureDeliveryCopy.channelUnavailableMessage(busPort: 50001, anotherCopyRunning: true)
        let other = CaptureDeliveryCopy.channelUnavailableMessage(busPort: 50001, anotherCopyRunning: false)
        XCTAssertTrue(copy.contains("127.0.0.1:50001"))
        XCTAssertTrue(other.contains("127.0.0.1:50001"))
        XCTAssertTrue(copy.contains("Another copy of ReqRes"))
        XCTAssertFalse(other.contains("copy of ReqRes"))
    }

    // MARK: - Review of build 53

    /// The note when ReqRes's own restart did not go through is its own: the
    /// person clicked nothing, so nothing says to try it "again" and nothing
    /// points at a Restart Capture button the pane may not show; whether
    /// capture was left running is in every one.
    func testTheAutomaticFailureNotesAreTheirOwnWords() {
        let failures: [CaptureRestartFailure] = [
            .channelUnavailable(anotherCopyRunning: true),
            .channelUnavailable(anotherCopyRunning: false),
            .configurationUnreadable("the system did not answer"),
            .didNotStop,
            .startRefused("configuration disabled"),
        ]
        let notes = failures.map { CaptureDeliveryCopy.automaticRestartFailedNote($0, busPort: 50001) }
        XCTAssertEqual(Set(notes).count, notes.count, "two failures said the same way")
        for (failure, note) in zip(failures, notes) {
            XCTAssertTrue(note.contains("by itself"), "\(failure): \(note)")
            XCTAssertFalse(note.lowercased().contains("try"), "\(failure): the person tried nothing — \(note)")
            XCTAssertFalse(note.contains(CaptureDeliveryCopy.restartButton), "\(failure): no button to point at — \(note)")
            XCTAssertFalse(note.contains("\n"), note)
            XCTAssertTrue(note.hasSuffix("."), note)
            XCTAssertNotEqual(note, CaptureDeliveryCopy.restartFailedMessage(failure, busPort: 50001))
            switch failure {
            case .channelUnavailable(let another):
                XCTAssertTrue(note.contains("127.0.0.1:50001"), note)
                XCTAssertTrue(note.contains("capture was left running"), note)
                XCTAssertEqual(note.contains("another copy of ReqRes"), another, note)
            case .configurationUnreadable(let reason):
                XCTAssertTrue(note.contains(reason), note)
                XCTAssertTrue(note.contains("capture was left as it was"), note)
            case .didNotStop:
                XCTAssertTrue(note.contains("\(Int(CaptureRestart.stopTimeout)) seconds"), note)
            case .startRefused(let reason):
                XCTAssertTrue(note.contains(reason), note)
                XCTAssertTrue(note.contains("stopped capture"), "the stop went through: \(note)")
            }
        }
    }

    /// While "Capture is on, but ReqRes isn't receiving it" shows, the pane's
    /// one-line note is hidden — so what ReqRes's own restart already did in
    /// the stretch is said in the notice's detail, the empty state's and the
    /// agent's reason (review: the note surfaced only once it no longer
    /// applied).
    func testTheNoticeSaysWhatTheRestartAlreadyDid() {
        for problem in CaptureDeliveryProblem.allCases {
            let reason = CaptureDeliveryCopy.reason(for: problem)
            XCTAssertEqual(CaptureDeliveryCopy.notReceivingDetail(for: problem, restartTried: nil, busPort: 50001), reason)
            let restarted = CaptureDeliveryCopy.notReceivingDetail(for: problem, restartTried: .restarted, busPort: 50001)
            XCTAssertEqual(restarted, reason + " " + CaptureDeliveryCopy.restartedOnceAlready)
            let failure = CaptureRestartFailure.configurationUnreadable("the system did not answer")
            let failed = CaptureDeliveryCopy.notReceivingDetail(for: problem, restartTried: .failed(failure), busPort: 50001)
            XCTAssertEqual(failed, reason + " " + CaptureDeliveryCopy.automaticRestartFailedNote(failure, busPort: 50001))
            for tried in [nil, CaptureStretchRestart.restarted, .failed(failure)] {
                let empty = CaptureDeliveryCopy.emptyStateDetail(for: problem, restartTried: tried, busPort: 50001)
                XCTAssertTrue(empty.hasPrefix(CaptureDeliveryCopy.notReceivingDetail(for: problem, restartTried: tried, busPort: 50001)), empty)
                XCTAssertTrue(empty.contains(CaptureDeliveryCopy.restartButton), "says what its button does: \(empty)")
            }
            XCTAssertEqual(CaptureDeliveryCopy.emptyStateDetail(for: problem),
                           CaptureDeliveryCopy.emptyStateDetail(for: problem, restartTried: nil, busPort: 50001))
        }
        XCTAssertTrue(CaptureDeliveryCopy.restartedOnceAlready.contains("once"))
        XCTAssertTrue(CaptureDeliveryCopy.restartedOnceAlready.contains("by itself"))
    }
}
