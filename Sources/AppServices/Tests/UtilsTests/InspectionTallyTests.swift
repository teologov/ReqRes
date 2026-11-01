//
//  InspectionTallyTests.swift
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
//  The free tier's inspection is spent once per EXCHANGE, however many times
//  its live row is updated or replaced (protocol-engine doc §S6), and never by
//  a relay or a failure row (decision D14).
//

import XCTest
import MCPKit
@testable import Utils

private struct Row: LiveTableRow {
    var id: UUID
    var exchangeID: UUID?
}

final class InspectionTallyTests: XCTestCase {
    /// Every operation the ledger produces for one live exchange — started,
    /// ten progress messages with a new snapshot each, the final — names ONE
    /// row id; the detail pane shows that row after each, and one inspection
    /// is spent.
    func testALiveRowWatchedThroughEveryUpdateAndItsFinalSpendsOneInspection() {
        var ledger = LiveRowLedger<Row>()
        let exchange = UUID()
        var operations: [LiveRowOperation<Row>] = []
        operations += ledger.ingest(.started(LiveStartInput(exchangeID: exchange, phase: .waiting, row: Row(id: UUID(), exchangeID: exchange))), now: 0)
        for sequence in 1...10 {
            operations += ledger.ingest(.progress(LiveProgressInput(
                exchangeID: exchange, sequence: sequence, phase: .streaming, appendedText: "x",
                textOffset: Int64(sequence - 1), row: Row(id: UUID(), exchangeID: exchange))), now: 0)
        }
        operations += ledger.ingest(.final(Row(id: UUID(), exchangeID: exchange)), now: 0)
        let shownIDs = operations.map(\.rowID)
        XCTAssertEqual(Set(shownIDs).count, 1, "one id from the first snapshot to the final")

        var tally = FreeTier.InspectionTally()
        var spent = 0
        for id in shownIDs where tally.recordView(rowID: id, access: .inspect(counted: true)) { spent += 1 }
        XCTAssertEqual(spent, 1)
    }

    /// CHARACTERISATION, not a pin of the Messages tab (protocol-engine doc
    /// §S7, D14). It records the assumption the tab's gating rests on: the
    /// tally is keyed by ROW id, and a message is keyed to its 101's
    /// EXCHANGE and never becomes a row, so however many batches arrive and
    /// however often the pane re-renders, the 101's row costs one inspection.
    /// It would pass against the pre-S7 tally — what it guards is the tally's
    /// by-row-id rule. That `WebSocketMessagesView` never calls `recordView`
    /// lives in the UI target, which has no tests.
    func testTheTallyIsByRowSoABusyWebSocketRowCostsOneInspection() {
        let rowID = UUID()
        let exchange = UUID()
        var store = SocketMessageStore()
        var tally = FreeTier.InspectionTally()
        var spent = 0
        if tally.recordView(rowID: rowID, access: .inspect(counted: true)) { spent += 1 }   // the row opened (Headers)
        for batch in 1...50 {
            let message = SocketMessage(seq: Int64(batch - 1), direction: .serverToClient, opcode: .text, time: Double(batch),
                                        size: 2, preview: "hi", previewEncoding: .text)
            store.ingest(SocketMessageBatch(exchangeID: exchange, batch: batch, messages: [message], final: batch == 50))
            // The pane re-renders for the batch and the user flips tabs.
            if tally.recordView(rowID: rowID, access: .inspect(counted: true)) { spent += 1 }
        }
        XCTAssertEqual(store.log(for: exchange)?.received, 50)
        XCTAssertEqual(spent, 1)
        XCTAssertEqual(tally.counted, [rowID], "no message ever became a row of its own")
    }

    func testRelayFailureLicensedAndLimitViewsSpendNothing() {
        var tally = FreeTier.InspectionTally()
        let id = UUID()
        for access: FreeTier.DetailAccess in [.relay, .failure, .inspect(counted: false), .limitReached, .certificateRequired] {
            XCTAssertFalse(tally.recordView(rowID: id, access: access))
        }
        XCTAssertFalse(tally.hasCounted(id))
        XCTAssertTrue(tally.recordView(rowID: id, access: .inspect(counted: true)))
        XCTAssertFalse(tally.recordView(rowID: id, access: .inspect(counted: true)))
        XCTAssertTrue(tally.recordView(rowID: UUID(), access: .inspect(counted: true)), "another exchange spends its own")
    }
}
