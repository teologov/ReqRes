//
//  CoreProvenanceTests.swift
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
//  The gate that keeps a core with the development license keys out of a
//  release, read from the scripts and the committed record: Scripts/ has no
//  test target. The core verifies every license answer with Ed25519 public
//  keys compiled into it, and one built with the throwaway development keys
//  can never get Pro from reqresapp.com, so a release built from it would lock
//  out every buyer. sync-core.sh records which set it embedded
//  (`entitlementKeys` in Sources/XReqResCore.provenance.json) once the built
//  binary is shown to carry the `k1` its source names, and dev-install.sh
//  asks core-keys-check.sh about that record, and about the embedded binary
//  beside it, before it archives anything. These tests run
//  `Scripts/core-keys-check.sh --selftest`, which checks the verdicts
//  themselves, and the gate against the committed record and binary.
//

import XCTest

final class CoreProvenanceTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
            .deletingLastPathComponent() // the repository root
    }

    private static let provenance = "Sources/XReqResCore.provenance.json"
    private static let syncCore = "Scripts/sync-core.sh"
    private static let devInstall = "Scripts/dev-install.sh"

    private func text(_ relative: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The script with its comments dropped, so neither the usage block nor a
    /// comment that quotes a command passes for the command. In a shell
    /// script `#` opens a comment only at the start of a word and outside
    /// quotes: `${name#prefix}`, `$#` and a quoted `#` stay. Quotes are
    /// followed within a line; these scripts' multi-line strings hold no `#`.
    private func code(_ relative: String) throws -> String {
        try text(relative).components(separatedBy: "\n").map(Self.droppingComment).joined(separator: "\n")
    }

    private static func droppingComment(_ line: String) -> String {
        var kept = ""
        var quote: Character?
        var escaped = false
        var previous: Character?
        for character in line {
            if escaped {
                escaped = false
            } else if quote == "'" {
                if character == "'" { quote = nil }
            } else if character == "\\" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "#", previous.map({ " \t;&|()<>".contains($0) }) ?? true {
                break
            }
            kept.append(character)
            previous = character
        }
        return kept
    }

    /// The committed record decodes and names the key set the embedded core
    /// trusts: "development" or "production". The core embedded since pay-once
    /// S1 has the verifier, so a record without the field, or with "none",
    /// is a record from an older sync-core.sh or a core whose
    /// EntitlementKeys.swift moved, and core-keys-check refuses both unless
    /// given --legacy-core. It refuses any other value too (a typo, null, a
    /// number), so none of them may be committed.
    func testTheProvenanceNamesAKnownKeySet() throws {
        let data = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent(Self.provenance))
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "not a JSON object")
        let commit = try XCTUnwrap(record["coreCommit"] as? String, "core-keys-check refuses a record without a core commit")
        XCTAssertNotNil(commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression), commit)
        let keys = try XCTUnwrap(record["entitlementKeys"], "no entitlementKeys: a record from an older sync-core.sh")
        let name = try XCTUnwrap(keys as? String, "entitlementKeys is not a string: \(keys)")
        XCTAssertTrue(["development", "production"].contains(name), "not a key set this core can trust: '\(name)'")
    }

    /// dev-install refuses a core with the development keys before anything
    /// else: before it asks whether ReqRes is capturing (and stops it), reads
    /// the keychain for notarytool or the signing identity, spends minutes on
    /// the archive, and signs. `--dev-keys` is parsed, reaches the check, and
    /// is in the help.
    func testDevInstallChecksTheKeysBeforeArchiving() throws {
        let script = try code(Self.devInstall)
        let call = try XCTUnwrap(script.range(of: "\"${ROOT}/Scripts/core-keys-check.sh\" ${DEV_KEYS:+--dev-keys}"),
                                 "the check, handed --dev-keys when it was given")
        let refusal = script[call.upperBound...].drop { " \t\\\n".contains($0) }
        XCTAssertTrue(refusal.hasPrefix("|| die \"not archiving"), "a refusal must stop the script: \(refusal.prefix(60))")
        for later in ["scutil --nc", "notarytool", "security find-identity", "xcodebuild archive", "codesign "] {
            let first = try XCTUnwrap(script.range(of: later), "\(later) not found — renamed? Update this test.")
            XCTAssertLessThan(call.lowerBound, first.lowerBound, "\(later) comes before the keys are checked")
        }

        let arms = script.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("--dev-keys)")
        }
        XCTAssertEqual(arms.count, 1, "the option's case arm")
        XCTAssertTrue(arms.first?.contains("DEV_KEYS=1") == true, arms.first ?? "")

        // --help prints the header up to a fixed line, which must reach both
        // lines of the option's usage.
        let lines = try text(Self.devInstall).components(separatedBy: "\n")
        let usage = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("#") && $0.contains("./Scripts/dev-install.sh --dev-keys") },
                                  "the usage line") + 1
        let help = try XCTUnwrap(script.range(of: #"sed -n '2,[0-9]+p'"#, options: .regularExpression), "the help")
        let last = try XCTUnwrap(Int(script[help].dropFirst("sed -n '2,".count).dropLast("p'".count)))
        XCTAssertGreaterThanOrEqual(last, usage + 1, "--help stops before the end of the --dev-keys usage")
    }

    /// sync-core reads the keys file at the commit it embeds before it spends
    /// minutes on the build, so a bad file fails fast. After the build it
    /// proves the binary carries the `k1` literal its source names — Swift
    /// stores a literal longer than 15 bytes as bytes, and
    /// "https://reqresapp.com/api" is in core b3f9c2b's binary twice — and
    /// dies otherwise. That happens before a dry run stops, so `--dry-run`
    /// checks and prints the set too, and before the swap, so a binary
    /// without its keys is never embedded. The provenance then records it.
    func testSyncCoreRecordsTheKeysItEmbeds() throws {
        let script = try code(Self.syncCore)
        func at(_ needle: String, file: StaticString = #filePath, line: UInt = #line) throws -> String.Index {
            try XCTUnwrap(script.range(of: needle), "\(needle) not found", file: file, line: line).lowerBound
        }
        let source = try at("ENTITLEMENT_KEYS_SOURCE=\"XReqResCore/LicenseManager/EntitlementKeys.swift\"")
        let read = try at("git -C \"${CORE_ROOT}\" show \"${CORE_SHA}:${ENTITLEMENT_KEYS_SOURCE}\"")
        let build = try at("./build-xcframework.sh")
        let binary = try at("CORE_BINARY=\"${SOURCE_FRAMEWORK}/macos-arm64_x86_64/XReqResCore.framework/Versions/A/XReqResCore\"")
        let grep = try at("""
            LC_ALL=C grep -aqF -- "${ENTITLEMENT_K1}" "${CORE_BINARY}" \\
                  || die "the built binary does not carry the keys its source names
            """)
        let dryRunStop = try at("say \"(dry run) would replace ${DEST}\"")
        let swap = try at("cp -R \"${SOURCE_FRAMEWORK}\" \"${DEST}\"")
        let record = try at("\"entitlementKeys\": \"${ENTITLEMENT_KEYS}\",")
        XCTAssertLessThan(source, read)
        XCTAssertLessThan(read, build, "the keys file is read before the build")
        XCTAssertLessThan(build, binary)
        XCTAssertLessThan(binary, grep)
        XCTAssertLessThan(grep, dryRunStop, "a dry run checks the binary too")
        XCTAssertLessThan(grep, swap, "the binary is checked before it is swapped in")
        XCTAssertLessThan(swap, record, "the record is written with the provenance, after the swap")

        XCTAssertTrue(script.contains("ENTITLEMENT_KEYS=none"), "a core without the keys file records none")
        // ... unless it has the verifier: then the keys file moved, and
        // "none" would be false. The script dies before the build instead.
        XCTAssertTrue(script.contains("ENTITLEMENT_VERIFIER_SOURCE=\"XReqResCore/LicenseManager/Entitlement.swift\""))
        let verifier = try at("elif git -C \"${CORE_ROOT}\" cat-file -e \"${CORE_SHA}:${ENTITLEMENT_VERIFIER_SOURCE}\" 2>/dev/null; then")
        let refusal = script[verifier...].dropFirst().drop { $0 != "\n" }.drop { " \t\n".contains($0) }
        XCTAssertTrue(refusal.hasPrefix("die \""), "a core with the verifier but no keys file must stop the sync: \(refusal.prefix(60))")
        XCTAssertLessThan(verifier, build, "it stops before the build")
        XCTAssertTrue(script.contains("development|production) ;;"), "keySetName is one of the two sets")
        XCTAssertTrue(script.contains("[[ \"${ENTITLEMENT_K1}\" =~ ^[A-Za-z0-9_-]{43}$ ]]"), "k1 is 43 base64url characters")
    }

    /// sync-core works from a git worktree, as the `pay-once` work does: a
    /// clone has a `.git` folder, a worktree a `.git` file that points into
    /// the main checkout, and testing for the folder refused every worktree
    /// ("Core repo not found", 2026-10-04). Git still refuses a folder that
    /// is in no repository (`CORE_ROOT=/tmp`).
    func testSyncCoreAcceptsAWorktree() throws {
        let script = try code(Self.syncCore)
        XCTAssertFalse(script.contains("-d \"${CORE_ROOT}/.git\""), "the folder test")
        XCTAssertTrue(script.contains("""
            [ -n "${CORE_ROOT}" ] && git -C "${CORE_ROOT}" rev-parse --git-dir >/dev/null 2>&1 \\
              || die "Core repo not found.
            """), "git decides, and a refusal still stops the script")
    }

    /// Runs the gate under /bin/bash (3.2 on macOS, as dev-install runs it).
    private func gate(_ arguments: [String]) throws -> (status: Int32, output: String) {
        try bash(Self.repositoryRoot.appendingPathComponent(Self.coreKeysCheck).path, arguments)
    }

    /// Runs a script under /bin/bash, its output and error stream together.
    private func bash(_ script: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static let coreKeysCheck = "Scripts/core-keys-check.sh"

    /// The gate's own verdicts, against temporary records and fixture
    /// binaries: every case passes, including the ones that judge the binary
    /// (a "production" record beside any development key or without any of
    /// the production keys, a keyless record beside a key of either set, a
    /// "development" one beside a binary without development k1).
    func testTheGateSelftestPasses() throws {
        let result = try gate(["--selftest"])
        XCTAssertEqual(result.status, 0, result.output)
        let lines = result.output.split(separator: "\n")
        XCTAssertEqual(lines.last, "all passed", result.output)
        XCTAssertFalse(lines.contains { $0.hasPrefix("FAIL") }, result.output)
        XCTAssertTrue(lines.contains("PASS production is refused beside development k2 alone"), "the binary cases ran")
        XCTAssertTrue(lines.contains("PASS production is refused beside production k1 alone"),
                      "the production record needs all three production keys")
        XCTAssertTrue(lines.contains("PASS none with --legacy-core is refused beside the production keys"),
                      "a keyless record is refused beside the production keys too")
    }

    /// The committed record describes the committed binary: with --dev-keys
    /// the gate accepts "development" only beside a binary that carries
    /// development k1, and "production" only beside one that carries the
    /// three production keys and none of the development keys. A
    /// hand-copied framework, or a record edited by hand, fails here before
    /// dev-install ever runs.
    func testTheCommittedRecordDescribesTheEmbeddedBinary() throws {
        let result = try gate(["--dev-keys"])
        XCTAssertEqual(result.status, 0, result.output)
    }

    // MARK: - The names the core retired

    private static let coreCheckout = "XReqResCore"
    private static let retiredMarkersCheck = "Scripts/retired-markers-check.sh"
    private static let retiredNames = "Scripts/retired-names.txt"
    private static let retiredPublicNames = "Scripts/retired-public-names.txt"
    private static let framework = "Sources/XReqResCore.xcframework"

    /// sync-core runs the core's retired-names check on the framework it is
    /// about to embed, after the build and before the swap (where it checks
    /// the keys), and a hit stops the script: a framework that carries a
    /// name the core removed or renamed was built before the core took its
    /// current names, and is never embedded.
    func testSyncCoreChecksTheBuiltFrameworkForRetiredNames() throws {
        let script = try code(Self.syncCore)
        func at(_ needle: String, file: StaticString = #filePath, line: UInt = #line) throws -> Range<String.Index> {
            try XCTUnwrap(script.range(of: needle), "\(needle) not found", file: file, line: line)
        }
        let build = try at("./build-xcframework.sh")
        let keys = try at("LC_ALL=C grep -aqF -- \"${ENTITLEMENT_K1}\" \"${CORE_BINARY}\"")
        let check = try at("RETIRED_MARKERS_CHECK=\"${CORE_ROOT}/Scripts/retired-markers-check.sh\"")
        let run = try at("if RETIRED_MARKERS=\"$(/bin/bash \"${RETIRED_MARKERS_CHECK}\" \"${SOURCE_FRAMEWORK}\" 2>&1)\"; then")
        let dryRunStop = try at("say \"(dry run) would replace ${DEST}\"")
        let swap = try at("cp -R \"${SOURCE_FRAMEWORK}\" \"${DEST}\"")
        XCTAssertLessThan(build.lowerBound, check.lowerBound, "checked after the build")
        XCTAssertLessThan(keys.lowerBound, check.lowerBound, "beside the keys gate")
        XCTAssertLessThan(check.lowerBound, run.lowerBound)
        XCTAssertLessThan(run.lowerBound, dryRunStop.lowerBound, "a dry run of an existing framework checks it too")
        XCTAssertLessThan(run.lowerBound, swap.lowerBound, "checked before the swap")
        // The failing branch dies, and a core without the check is refused too.
        let afterRun = script[run.upperBound...]
        let elseBranch = try XCTUnwrap(afterRun.range(of: "else"), "the hit branch")
        let refusal = afterRun[elseBranch.upperBound...].drop { " \t\n".contains($0) }
        XCTAssertTrue(refusal.hasPrefix("printf '%s\\n' \"${RETIRED_MARKERS}\""), "the hits are printed first: \(refusal.prefix(60))")
        XCTAssertNotNil(afterRun.range(of: "die \"the built framework carries a name the core retired"), "a hit stops the script")
        XCTAssertNotNil(script.range(of: "|| die \"no ${RETIRED_MARKERS_CHECK}:"), "a core without the check is refused")
    }

    /// The same check on the COMMITTED framework: whatever reached the
    /// repository, by sync-core or by hand, carries none of the names the
    /// core retired. The check and its two name lists live in the core's
    /// checkout beside this one (`../XReqResCore/Scripts`); a builder of this
    /// public repository has no such checkout, and a core checkout may lack
    /// one of the three (the check would exit 2); the test says so rather
    /// than failing.
    func testTheEmbeddedFrameworkCarriesNoRetiredName() throws {
        let core = Self.repositoryRoot.deletingLastPathComponent().appendingPathComponent(Self.coreCheckout)
        let check = core.appendingPathComponent(Self.retiredMarkersCheck).path
        let names = core.appendingPathComponent(Self.retiredNames).path
        let publicNames = core.appendingPathComponent(Self.retiredPublicNames).path
        guard FileManager.default.isReadableFile(atPath: check),
              FileManager.default.isReadableFile(atPath: names),
              FileManager.default.isReadableFile(atPath: publicNames) else {
            throw XCTSkip("the core's retired-names check and its two lists (\(core.path)/Scripts) are not beside this checkout: the embedded framework was not checked")
        }
        let result = try bash(check, [Self.repositoryRoot.appendingPathComponent(Self.framework).path])
        XCTAssertEqual(result.status, 0, "the embedded framework carries a retired name, or the check could not read it:\n\(result.output)")
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "", "a clean framework prints nothing")
    }
}
