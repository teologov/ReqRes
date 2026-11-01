//
//  SavedSessionProbe.swift
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
//  DEBUG only. The saved-sessions store lives in the closed core, whose GRDB
//  code no `swift test` in this repo can reach — the core's own test package
//  deliberately depends on swift-nio and nothing else. So the round trip is
//  pinned here instead, against the REAL database, and it cleans up after
//  itself: it asserts the saved count returns to what it was.
//

#if DEBUG
import Foundation
import XReqResCore

enum SavedSessionProbe {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["REQRES_SAVED_PROBE"] != nil else { return }
        Task {
            do { try await run() } catch { print("[saved] FAILED: \(error)") }
            fflush(stdout)
            exit(0)
        }
    }

    private static func run() async throws {
        let before = try await ReqResCoreModelBridge.savedSessionCount()
        print("[saved] count before: \(before)")

        let session = sample()
        let id = try await ReqResCoreModelBridge.saveSession(session, note: "probe run")
        print("[saved] saved id=\(id)")

        let listed = try await ReqResCoreModelBridge.savedSessions(limit: 5, offset: 0)
        let mine = listed.first { $0.id == id }
        print("[saved] listed=\(listed.count) found-mine=\(mine != nil) note=\(mine?.note ?? "-")")

        guard let loaded = try await ReqResCoreModelBridge.savedSession(id: id) else {
            print("[saved] FAILED: could not load the row back")
            return
        }
        // Field-by-field, because a mapping that drops one field silently is
        // the failure this whole probe exists to catch.
        let s = loaded.session
        let checks: [(String, Bool)] = [
            ("host", s.host == session.host),
            ("method", s.method == session.method),
            ("uri", s.uri == session.uri),
            ("scheme", s.scheme == session.scheme),
            ("rspStatus", s.rspStatus == session.rspStatus),
            ("reqHeaders", s.reqHeaders == session.reqHeaders),
            ("rspHeaders", s.rspHeaders == session.rspHeaders),
            ("reqBody", s.reqBody == session.reqBody),
            ("rspBody", s.rspBody == session.rspBody),
            ("rspBodyData", s.rspBodyData == session.rspBodyData),
            ("startTime", s.startTime.doubleValue == session.startTime.doubleValue),
            ("rspEndTime", s.rspEndTime.doubleValue == session.rspEndTime.doubleValue),
            ("requestBytes", s.requestBytes.int64Value == session.requestBytes.int64Value),
            ("responseBytes", s.responseBytes.int64Value == session.responseBytes.int64Value),
            ("userAgentProduct", s.userAgentProduct == session.userAgentProduct),
            // Attribution rides the same row (UX spec §1.1); a mapping that
            // dropped one of the three would fail here, not in the browser.
            ("processName", s.processName == session.processName),
            ("processID", s.processID == session.processID),
            ("processPath", s.processPath == session.processPath),
            ("reqContentEncoding", s.reqContentEncoding == session.reqContentEncoding),
            ("rspContentType", s.rspContentType == session.rspContentType),
        ]
        let failed = checks.filter { !$0.1 }.map(\.0)
        print("[saved] round trip: \(checks.count - failed.count)/\(checks.count) fields match\(failed.isEmpty ? "" : " — MISMATCH: \(failed)")")
        print("[saved] savedAt within a minute of now: \(abs(loaded.savedAt.timeIntervalSinceNow) < 60)")

        let bytes = try await ReqResCoreModelBridge.savedSessionByteSize()
        print("[saved] stored bytes for all saved sessions: \(bytes)")

        let deleted = try await ReqResCoreModelBridge.deleteSavedSession(id: id)
        let after = try await ReqResCoreModelBridge.savedSessionCount()
        print("[saved] deleted=\(deleted) count after: \(after) (clean=\(after == before))")

        // Deleting a row that is not saved must report false rather than
        // quietly removing something through the saved-sessions door.
        let bogus = try await ReqResCoreModelBridge.deleteSavedSession(id: id)
        print("[saved] deleting the same id again: \(bogus) (must be false)")
    }

    private static func sample() -> SessionCodable {
        let now = Date().timeIntervalSince1970
        return SessionCodable(
            startTime: NSNumber(value: now),
            host: "probe.example.com",
            localAddress: "127.0.0.1:0",
            method: "POST",
            uri: "/v1/probe?x=1",
            reqHTTPVersion: "HTTP/1.1",
            userAgentProduct: "ReqRes probe",
            reqHeaders: #"[{"Content-Type":"application/json"}]"#,
            reqContentEncoding: "identity",
            reqContentType: "application/json",
            reqBody: #"{"hello":"world"}"#,
            rspHTTPVersion: "HTTP/1.1",
            rspStatus: "201",
            rspReasonPhrase: "Created",
            rspContentType: "application/json",
            rspContentEncoding: "gzip",
            rspContentDisposition: "",
            rspHeaders: #"[{"Set-Cookie":"sid=probe"}]"#,
            rspBody: #"{"ok":true}"#,
            rspBodyData: Data([0x89, 0x50, 0x4E, 0x47]),
            scheme: "https",
            reqStartTime: NSNumber(value: now + 0.01),
            reqBodyStartTime: NSNumber(value: now + 0.02),
            rspStartTime: NSNumber(value: now + 0.03),
            rspEndTime: NSNumber(value: now + 0.04),
            connectStartTime: NSNumber(value: now),
            connectEndTime: NSNumber(value: now),
            tlsEndTime: NSNumber(value: now),
            reqEndTime: NSNumber(value: now),
            requestBytes: NSNumber(value: 123),
            responseBytes: NSNumber(value: 456),
            downloadStartTime: NSNumber(value: now + 0.03),
            downloadEndTime: NSNumber(value: now + 0.04),
            processName: "curl",
            processID: 51234,
            processPath: "/usr/bin/curl"
        )
    }
}
#endif
