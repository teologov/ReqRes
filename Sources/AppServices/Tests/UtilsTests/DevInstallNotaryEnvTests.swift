//
//  DevInstallNotaryEnvTests.swift
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
//  dev-install.sh notarizes with the Apple ID in the gitignored .env when the
//  notarytool keychain profile is unusable. A git worktree has no copy of that
//  file, so from the pay-once worktree the fallback found nothing and the
//  preflight died (pay-once review, 2026-10-05). The script now falls back to
//  the main checkout's .env. Scripts/ has no test target, so this test runs the
//  script's own two functions under /bin/bash in a throwaway repository and
//  worktree with made-up credentials; it never reads a real .env.
//

import XCTest

final class DevInstallNotaryEnvTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
            .deletingLastPathComponent() // the repository root
    }

    private var sandbox: URL!
    private var main: URL!
    private var worktree: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-install-env-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        main = sandbox.appendingPathComponent("main")
        worktree = sandbox.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(["init", "-q", main.path])
        try git(["-C", main.path, "commit", "-q", "--allow-empty", "-m", "base"])
        try git(["-C", main.path, "worktree", "add", "-q", "-b", "wt", worktree.path])
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    /// Runs a program with no global or system git config, so the developer's
    /// signing or hook settings never reach the throwaway repository.
    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func git(_ arguments: [String]) throws {
        let result = try run("/usr/bin/git", arguments)
        XCTAssertEqual(result.status, 0, "git \(arguments.joined(separator: " ")): \(result.output)")
    }

    /// The script's own `notary_env_file` and `use_env_notary_auth`, with the
    /// `NOTARY_ENV` default between them: everything from the first function
    /// up to the preflight that calls them.
    private func notaryFunctions() throws -> String {
        let script = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Scripts/dev-install.sh"), encoding: .utf8)
        let start = try XCTUnwrap(script.range(of: "\nnotary_env_file() {\n"), "notary_env_file not found: renamed? Update this test.")
        let end = try XCTUnwrap(script.range(of: "\nif [ \"${NOTARIZE}\" -eq 1 ]; then\n", range: start.upperBound..<script.endIndex),
                                "the notarization preflight not found")
        let functions = String(script[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(functions.contains("\nuse_env_notary_auth() {\n"), "use_env_notary_auth must sit between them")
        return functions
    }

    /// What `use_env_notary_auth` decides with ROOT set to `root`, run by
    /// /bin/bash (3.2 on macOS, as dev-install runs) under `set -euo pipefail`.
    private func fallback(root: URL) throws -> String {
        let functions = try notaryFunctions()
        let harness = """
            set -euo pipefail
            ROOT="$1"
            NOTARY_AUTH=()
            \(functions)
            if use_env_notary_auth; then
              printf 'auth %s\\n' "${NOTARY_AUTH[*]}"
              printf 'file %s\\n' "${NOTARY_ENV}"
            else
              printf 'none %s\\n' "${NOTARY_ENV}"
            fi
            """
        let script = sandbox.appendingPathComponent("harness.sh")
        try harness.write(to: script, atomically: true, encoding: .utf8)
        let result = try run("/bin/bash", [script.path, root.path])
        XCTAssertEqual(result.status, 0, result.output)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The path a `file …` line names, with symlinks resolved the way the
    /// sandbox's own path was, so /private/var and /var compare equal.
    private func named(_ output: String) -> String? {
        output.components(separatedBy: "\n").first { $0.hasPrefix("file ") }
            .map { URL(fileURLWithPath: String($0.dropFirst("file ".count))).resolvingSymlinksInPath().path }
    }

    private func envPath(_ folder: URL) -> String {
        folder.appendingPathComponent(".env").resolvingSymlinksInPath().path
    }

    /// The case: the worktree has no .env, the main checkout has one.
    func testAWorktreeUsesTheMainCheckoutsEnv() throws {
        try writeEnv(in: main, appleID: "main@example.invalid", password: "main-pw")
        let output = try fallback(root: worktree)
        XCTAssertTrue(output.hasPrefix("auth --apple-id main@example.invalid --team-id ZUP9ZNBCHM --password main-pw\n"), output)
        XCTAssertEqual(named(output), envPath(main))
    }

    /// A worktree's own .env, if someone made one, comes first.
    func testTheCheckoutsOwnEnvComesFirst() throws {
        try writeEnv(in: main, appleID: "main@example.invalid", password: "main-pw")
        try writeEnv(in: worktree, appleID: "wt@example.invalid", password: "wt-pw")
        let output = try fallback(root: worktree)
        XCTAssertTrue(output.hasPrefix("auth --apple-id wt@example.invalid --team-id ZUP9ZNBCHM --password wt-pw\n"), output)
        XCTAssertEqual(named(output), envPath(worktree))
    }

    /// The main checkout reads its own file, as before the change.
    func testTheMainCheckoutUsesItsOwnEnv() throws {
        try writeEnv(in: main, appleID: "main@example.invalid", password: "main-pw")
        let output = try fallback(root: main)
        XCTAssertTrue(output.hasPrefix("auth --apple-id main@example.invalid"), output)
        XCTAssertEqual(named(output), envPath(main))
    }

    /// No .env anywhere, half a credential, or a folder in no repository:
    /// false, and NOTARY_AUTH and the printed file name stay untouched.
    func testNothingUsableIsFalse() throws {
        XCTAssertEqual(try fallback(root: worktree), "none .env")
        XCTAssertEqual(try fallback(root: main), "none .env")
        try writeEnv(in: main, appleID: "main@example.invalid", password: nil)
        XCTAssertEqual(try fallback(root: worktree), "none .env")
        let loose = sandbox.appendingPathComponent("loose")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        XCTAssertEqual(try fallback(root: loose), "none .env")
    }

    private func writeEnv(in folder: URL, appleID: String, password: String?) throws {
        var text = "# made up for DevInstallNotaryEnvTests\nAPPLE_ID=\(appleID)\n"
        if let password { text += "APP_SPECIFIC_PASSWORD=\(password)\n" }
        try text.write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    }
}
