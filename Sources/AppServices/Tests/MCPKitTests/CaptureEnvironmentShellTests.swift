//
//  CaptureEnvironmentShellTests.swift
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
//  The environment block run the way people run it (F16): pasted into zsh —
//  macOS's default shell — and into bash, then used by the real curl. The
//  pure checks of the same lines are in CaptureEnvironmentLinesTests; these
//  catch what only a shell or a client decides: a word read as a command, a
//  file a shell refuses to overwrite, a variable curl does not read.
//
//  How a paste reaches zsh is the point, and it cost a false pass
//  (2026-09-30). zsh turns bracketed paste on, so Terminal hands it the
//  whole block as ONE buffer, which runs when Return is pressed — and a line
//  that fails in the ways a comment made lines fail ("not valid in this
//  context", "bad pattern", an unknown `~name`) drops every line after it.
//  Fed on standard input, each line runs on its own and the failure hides:
//  the block with comments passed that way while a real paste left
//  NODE_USE_ENV_PROXY and every certificate variable unset. So zsh gets the
//  paste on a pseudo-terminal, between the bracketed-paste markers, the way
//  Terminal sends it (`terminalPaste`), and no complaint at all is allowed,
//  since in a paste any one of them costs the lines after it. bash 3.2 —
//  macOS's /bin/bash — has no bracketed paste; Terminal's paste reaches it
//  line by line, which is what standard input gives it.
//
//  "Stock" is made, not assumed: `zsh -f` still reads /etc/zshenv (it cannot
//  be skipped), so every zsh run starts with `emulate -R zsh` — every option
//  back to zsh's default, `interactivecomments` off — and prints the options
//  that matter, which the assertions check.
//
//  Hermetic by construction. Each run starts in a session of its own (no
//  controlling terminal of the test's, so an interactive shell cannot reach
//  the terminal `swift test` runs in), from a scratch HOME, with a PATH of a
//  stub directory, /usr/bin and /bin, and inherits nothing else: no proxy
//  variable, no rc file, and curl runs with -q, so no .curlrc. The keychain
//  step's `security` is a stub printing a fixed listing — the real keychain
//  is never read. Requests name hosts under .invalid and go to the test's own
//  listener on a port the kernel picks, never ReqRes's, so nothing leaves the
//  Mac while the lines work; if they stop sending http:// through the proxy,
//  curl asks DNS for a name that cannot resolve.
//

import Darwin
import XCTest
@testable import MCPKit

final class CaptureEnvironmentShellTests: XCTestCase {
    private static let fingerprint = "5d41402abc4b2a76b9719d911017c592aa5d41402abc4b2a76b9719d911017c5"

    /// What the stub prints for `security find-certificate -a -Z -c … -p`: an
    /// older "ReqRes CA" first, as after an upgrade, then this install's.
    private static let keychainListing = """
    SHA-256 hash: 82C25BF3D2E7DF11F92F050DCD4E10DDD7725E873D2F4598999DC087D90B7074
    SHA-1 hash: 6C158FC89A07A3AE9C710D10F4A4B0C36E300058
    -----BEGIN CERTIFICATE-----
    OLDOLDOLD
    -----END CERTIFICATE-----
    SHA-256 hash: 5D41402ABC4B2A76B9719D911017C592AA5D41402ABC4B2A76B9719D911017C5
    SHA-1 hash: 0000000000000000000000000000000000000000
    -----BEGIN CERTIFICATE-----
    NEWNEWNEW
    -----END CERTIFICATE-----

    """

    /// This install's CA as the keychain step writes it from the listing.
    private static let thisMacsCertificate = "-----BEGIN CERTIFICATE-----\nNEWNEWNEW\n-----END CERTIFICATE-----\n"

    /// What a shell prints for a line it could not run as written.
    private static let complaints = [
        "not valid in this context", "not a valid identifier", "command not found", "unmatched",
        "parse error", "syntax error", "no matches found", "unknown file attribute", "bad pattern", "unexpected EOF",
        "no such user or named directory", "file exists", "cannot overwrite existing file",
    ]

    // MARK: - Pasted into zsh, the way Terminal pastes

    /// The block in both states — before an export, when the keychain step
    /// runs against the stub and writes this Mac's CA (the second certificate
    /// in the listing), and after one, to a path with a space and an
    /// apostrophe the shell has to unquote — pasted into a stock zsh, one
    /// with `extendedglob` (`#` is a pattern character there), and one with
    /// `noclobber` over a `~/reqres-ca.pem` an earlier build wrote. Every
    /// variable comes out exported with the value the block means, the file
    /// holds this Mac's CA, and zsh complains about nothing.
    func testAPasteIntoZshExportsEveryVariableUnderEveryOptionSet() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/zsh"), "no /bin/zsh")
        for options in ZshOptions.allCases {
            let keychain = try Scratch()
            if options == .noClobber { try keychain.writeEarlierCertificate() }
            let before = CaptureEnvironmentLines(proxyPort: 8034, caFingerprint: Self.fingerprint)
            let pastedBefore = try keychain.terminalPaste(before.text, options: options)
            let written = keychain.home.appendingPathComponent("reqres-ca.pem")
            assertOptions(options, in: pastedBefore)
            assertEveryVariable(in: pastedBefore, port: 8034, certificate: written.path, shell: "zsh (\(options))")
            assertNoComplaint(in: pastedBefore, shell: "zsh (\(options))")
            XCTAssertEqual(keychain.securityArguments, ["find-certificate", "-a", "-Z", "-c", "ReqRes CA", "-p"], "\(options)")
            XCTAssertEqual(try? String(contentsOf: written, encoding: .utf8), Self.thisMacsCertificate,
                           "the keychain step writes this Mac's CA, picked by fingerprint, over any earlier file (\(options))")

            let exported = try Scratch()
            let path = exported.root.appendingPathComponent("My Files/it's here/reqres-ca.pem").path
            let after = CaptureEnvironmentLines(proxyPort: 8034, certificatePath: path, caFingerprint: Self.fingerprint)
            let pastedAfter = try exported.terminalPaste(after.text, options: options)
            assertOptions(options, in: pastedAfter)
            assertEveryVariable(in: pastedAfter, port: 8034, certificate: path, shell: "zsh (\(options))")
            assertNoComplaint(in: pastedAfter, shell: "zsh (\(options))")
            XCTAssertNil(exported.securityArguments, "no keychain step once a file is known (\(options))")
        }
    }

    /// Why the block carries no comment, and proof that `terminalPaste` is
    /// the paste Terminal makes: a comment beside an export, pasted into a
    /// stock zsh, hands its words to `export`, and the first one `export`
    /// refuses drops every line after it — the next line never runs. Fed on
    /// standard input, the same two lines both run.
    func testAPastedCommentStopsZshAtTheFirstWordExportRefuses() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/zsh"), "no /bin/zsh")
        let block = "export HTTPS_PROXY=http://127.0.0.1:9  # the same, for lowercase-only tools\nexport HTTP_PROXY=http://127.0.0.1:9"

        let pasted = try Scratch().terminalPaste(block, options: .stock)
        assertOptions(.stock, in: pasted)
        XCTAssertEqual(pasted.environment?["HTTPS_PROXY"], "http://127.0.0.1:9", pasted.errors)
        XCTAssertNil(pasted.environment?["HTTP_PROXY"], "the line after the refused word ran:\n\(pasted.errors)")
        XCTAssertTrue(pasted.errors.contains("not valid in this context: same,"), pasted.errors)

        let fed = try Scratch().paste(block, into: .zsh)
        XCTAssertEqual(fed.environment?["HTTP_PROXY"], "http://127.0.0.1:9", "standard input runs each line on its own:\n\(fed.errors)")
    }

    /// The paste F16 was filed for: the apostrophe in "# node's own fetch"
    /// opens a quote nothing closes, so zsh waits for the rest of it and runs
    /// nothing at all — not even the lines before it.
    func testAnApostropheInAPastedCommentRunsNothing() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/zsh"), "no /bin/zsh")
        let block = """
        export HTTPS_PROXY=http://127.0.0.1:9
        export NODE_USE_ENV_PROXY=1  # node's own fetch/https (24+)
        export HTTP_PROXY=http://127.0.0.1:9
        """

        let pasted = try Scratch().terminalPaste(block, options: .stock)
        XCTAssertTrue(pasted.leftWaitingForMore, pasted.errors)
        XCTAssertNotNil(pasted.environment, "the dump runs once the open quote is abandoned:\n\(pasted.errors)")
        for name in ["HTTPS_PROXY", "NODE_USE_ENV_PROXY", "HTTP_PROXY"] {
            XCTAssertNil(pasted.environment?[name], "\(name) was set:\n\(pasted.errors)")
        }
    }

    // MARK: - Pasted into bash

    /// bash, before and after an export, as is and with `noclobber` over an
    /// earlier `~/reqres-ca.pem`: every variable exported, this Mac's CA in
    /// the file, no complaint.
    func testAPasteIntoBashExportsEveryVariable() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Shell.bash.rawValue), "no /bin/bash")
        for noClobber in [false, true] {
            let label = noClobber ? "bash (set -o noclobber)" : "bash"
            let setup = noClobber ? "set -o noclobber\n" : ""

            let keychain = try Scratch()
            if noClobber { try keychain.writeEarlierCertificate() }
            let before = CaptureEnvironmentLines(proxyPort: 8034, caFingerprint: Self.fingerprint)
            let pastedBefore = try keychain.paste(setup + before.text, into: .bash)
            let written = keychain.home.appendingPathComponent("reqres-ca.pem")
            assertEveryVariable(in: pastedBefore, port: 8034, certificate: written.path, shell: label)
            assertNoComplaint(in: pastedBefore, shell: label)
            XCTAssertEqual(keychain.securityArguments, ["find-certificate", "-a", "-Z", "-c", "ReqRes CA", "-p"], label)
            XCTAssertEqual(try? String(contentsOf: written, encoding: .utf8), Self.thisMacsCertificate, label)

            let exported = try Scratch()
            let path = exported.root.appendingPathComponent("My Files/it's here/reqres-ca.pem").path
            let after = CaptureEnvironmentLines(proxyPort: 8034, certificatePath: path, caFingerprint: Self.fingerprint)
            let pastedAfter = try exported.paste(setup + after.text, into: .bash)
            assertEveryVariable(in: pastedAfter, port: 8034, certificate: path, shell: label)
            assertNoComplaint(in: pastedAfter, shell: label)
            XCTAssertNil(exported.securityArguments, "no keychain step once a file is known (\(label))")
        }
    }

    // MARK: - curl through the lines

    /// The real curl, after the block: plain http:// reaches the proxy as an
    /// absolute-form GET and https:// as a CONNECT (curl reads a plain-HTTP
    /// proxy only from lowercase `http_proxy` — with the uppercase line alone
    /// it went straight to the server); localhost stays out of the proxy; and
    /// Help's `unset NO_PROXY no_proxy` puts it back in.
    func testCurlSendsBothSchemesThroughTheProxyAndLoopbackAroundIt() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/curl"), "no /usr/bin/curl")
        let proxy = try RecordingProxy()
        defer { proxy.stop() }
        let local = try Self.closedLoopbackPort()

        let pasted = try Scratch().paste([
            CaptureEnvironmentLines(proxyPort: proxy.port).text,
            Self.curl("http", "http://reqres-env-test.invalid/"),
            Self.curl("https", "https://reqres-env-test.invalid/", reporting: "http_connect"),
            Self.curl("loopback", "http://localhost:\(local)/"),
            "unset NO_PROXY no_proxy",
            Self.curl("unset", "http://localhost:\(local)/"),
        ].joined(separator: "\n"), into: .zsh)

        XCTAssertEqual(pasted.printed, ["http=418", "https=418", "loopback=000", "unset=418"], pasted.errors)
        XCTAssertEqual(proxy.requestLines, [
            "GET http://reqres-env-test.invalid/ HTTP/1.1",
            "CONNECT reqres-env-test.invalid:443 HTTP/1.1",
            "GET http://localhost:\(local)/ HTTP/1.1",
        ])
    }

    /// A lowercase proxy variable already in the shell — a corporate proxy,
    /// or one left pointing at something stopped — outranks the uppercase
    /// name in curl; before the lines set the lowercase names too, such a
    /// shell skipped ReqRes even for HTTPS (measured 2026-09-30). They
    /// overwrite it now.
    func testTheLinesReplaceALowercaseProxyTheShellAlreadyHad() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/curl"), "no /usr/bin/curl")
        let proxy = try RecordingProxy()
        defer { proxy.stop() }
        let stale = "http://127.0.0.1:\(try Self.closedLoopbackPort())"

        let pasted = try Scratch().paste([
            "export https_proxy=\(stale) http_proxy=\(stale)",
            CaptureEnvironmentLines(proxyPort: proxy.port).text,
            Self.curl("https", "https://reqres-env-test.invalid/", reporting: "http_connect"),
            Self.curl("http", "http://reqres-env-test.invalid/"),
        ].joined(separator: "\n"), into: .zsh)

        XCTAssertEqual(pasted.printed, ["https=418", "http=418"], pasted.errors)
        XCTAssertEqual(proxy.requestLines, [
            "CONNECT reqres-env-test.invalid:443 HTTP/1.1",
            "GET http://reqres-env-test.invalid/ HTTP/1.1",
        ])
    }

    // MARK: - Assertions

    private func assertEveryVariable(in pasted: Pasted, port: Int, certificate: String, shell: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard let environment = pasted.environment else {
            return XCTFail("the paste never reached its last line in \(shell) — a quote left open swallows the rest:\n\(pasted.errors)",
                           file: file, line: line)
        }
        let proxy = "http://127.0.0.1:\(port)"
        let expected = [
            "HTTPS_PROXY": proxy, "https_proxy": proxy, "HTTP_PROXY": proxy, "http_proxy": proxy,
            "NO_PROXY": CaptureEnvironmentLines.noProxyHosts, "no_proxy": CaptureEnvironmentLines.noProxyHosts,
            "NODE_USE_ENV_PROXY": "1",
            "NODE_EXTRA_CA_CERTS": certificate, "SSL_CERT_FILE": certificate, "REQUESTS_CA_BUNDLE": certificate,
        ]
        for (name, value) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(environment[name], value, "\(name) in \(shell):\n\(pasted.errors)", file: file, line: line)
        }
    }

    private func assertNoComplaint(in pasted: Pasted, shell: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(pasted.leftWaitingForMore, "the paste left \(shell) waiting for the rest of a quote:\n\(pasted.errors)",
                       file: file, line: line)
        for complaint in Self.complaints where pasted.errors.contains(complaint) {
            XCTFail("\(shell) could not run a line as written (\(complaint)):\n\(pasted.errors)", file: file, line: line)
        }
    }

    /// The premise, read back from the shell: `interactivecomments` off —
    /// a stock zsh, whatever /etc/zshenv says — and only the option the case
    /// set changed.
    private func assertOptions(_ options: ZshOptions, in pasted: Pasted, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pasted.zshOptions, [
            "interactivecomments": "off",
            "extendedglob": options == .extendedGlob ? "on" : "off",
            "clobber": options == .noClobber ? "off" : "on",
        ], "zsh did not run with the options the case is about (\(options)):\n\(pasted.errors)", file: file, line: line)
    }

    // MARK: - Running a paste

    /// A shell reading the paste on standard input, line by line.
    private enum Shell: String {
        case zsh = "/bin/zsh"
        case bash = "/bin/bash"

        /// Interactive, and no startup file.
        var arguments: [String] {
            switch self {
            case .zsh: return ["-f", "-i"]
            case .bash: return ["--norc", "--noprofile", "-i"]
            }
        }

        /// zsh's default options, whatever /etc/zshenv set (see the file's
        /// comment); bash with --norc and --noprofile reads nothing to undo.
        var preamble: String {
            switch self {
            case .zsh: return "emulate -R zsh\n"
            case .bash: return ""
            }
        }
    }

    /// The zsh options a terminal paste is tried under. Stock is macOS's:
    /// its /etc/zshrc sets none of these.
    private enum ZshOptions: String, CaseIterable, CustomStringConvertible {
        case stock = ""
        /// `#` is a pattern character: a pasted `#` word is a bad pattern.
        case extendedGlob = "setopt extendedglob"
        /// `>` refuses to overwrite a file; `>|` still does.
        case noClobber = "setopt noclobber"

        var description: String { self == .stock ? "stock" : rawValue }
    }

    /// What a paste left behind: standard output and standard error — for a
    /// terminal paste, the terminal's one transcript, escape sequences and
    /// carriage returns taken out.
    private struct Pasted {
        static let begin = "REQRES-ENV-BEGIN"
        static let end = "REQRES-ENV-END"
        static let option = "REQRES-OPTION "

        let output: String
        let errors: String
        /// A terminal paste whose buffer zsh could not finish — an open
        /// quote — so it ran nothing and asked for more.
        var leftWaitingForMore = false

        /// The environment the paste's last line printed — nil when the
        /// paste never got that far.
        var environment: [String: String]? {
            guard let dump = dump else { return nil }
            var environment: [String: String] = [:]
            for entry in dump.split(separator: "\n") where !entry.hasPrefix(Self.option) {
                guard let equals = entry.firstIndex(of: "=") else { continue }
                environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
            return environment
        }

        /// The zsh options the last line printed, name → "on" or "off".
        var zshOptions: [String: String]? {
            guard let dump = dump else { return nil }
            var options: [String: String] = [:]
            for entry in dump.split(separator: "\n") where entry.hasPrefix(Self.option) {
                let pair = entry.dropFirst(Self.option.count).split(separator: "=", maxSplits: 1)
                if pair.count == 2 { options[String(pair[0])] = String(pair[1]) }
            }
            return options
        }

        /// The lines the paste's own commands printed, before that last line.
        var printed: [String] {
            let before = output.range(of: Self.begin).map { output[..<$0.lowerBound] } ?? output[...]
            return before.split(separator: "\n").map(String.init)
        }

        /// What the last line printed, between its markers.
        private var dump: Substring? {
            guard let start = output.range(of: Self.begin + "\n"),
                  let stop = output.range(of: Self.end, range: start.upperBound..<output.endIndex) else { return nil }
            return output[start.upperBound..<stop.lowerBound]
        }

        /// The line that prints the dump. Each marker is split by quotes the
        /// shell removes, so a terminal's echo of the typed line never
        /// passes for the output.
        static func dumpLine(zshOptions: Bool) -> String {
            let options = zshOptions
                ? ["interactivecomments", "extendedglob", "clobber"].map { "; print -r -- \"\(option)\($0)=$options[\($0)]\"" }.joined()
                : ""
            return "echo REQRES-ENV-''BEGIN\(options); /usr/bin/env; echo REQRES-ENV-''END"
        }
    }

    /// A scratch HOME, and a PATH directory whose `security` prints
    /// `keychainListing` and records its arguments — so the keychain step
    /// runs for real without reading a keychain.
    private final class Scratch {
        let root: URL
        let home: URL
        private let bin: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("reqres-env-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            bin = root.appendingPathComponent("bin", isDirectory: true)
            for directory in [home, bin] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let security = bin.appendingPathComponent("security")
            let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HOME/security-arguments\"\ncat <<'LISTING'\n"
                + CaptureEnvironmentShellTests.keychainListing + "LISTING\n"
            try script.write(to: security, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: security.path)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// The stub's arguments, one per element; nil when it never ran.
        var securityArguments: [String]? {
            (try? String(contentsOf: home.appendingPathComponent("security-arguments"), encoding: .utf8))
                .map { $0.split(separator: "\n").map(String.init) }
        }

        /// A `~/reqres-ca.pem` an earlier build (or an earlier paste) wrote.
        func writeEarlierCertificate() throws {
            try "-----BEGIN CERTIFICATE-----\nEARLIER\n-----END CERTIFICATE-----\n"
                .write(to: home.appendingPathComponent("reqres-ca.pem"), atomically: true, encoding: .utf8)
        }

        private var environment: [String: String] {
            [
                "HOME": home.path,
                "PATH": "\(bin.path):/usr/bin:/bin",
                // bash's "The default interactive shell is now zsh." notice.
                "BASH_SILENCE_DEPRECATION_WARNING": "1",
            ]
        }

        /// Feeds `block`, then a line printing the exported environment, to
        /// `shell` on standard input.
        func paste(_ block: String, into shell: Shell) throws -> Pasted {
            let id = UUID().uuidString
            let input = root.appendingPathComponent("\(id).in")
            let output = root.appendingPathComponent("\(id).out")
            let errors = root.appendingPathComponent("\(id).err")
            try (shell.preamble + block + "\n" + Pasted.dumpLine(zshOptions: shell == .zsh) + "\n")
                .write(to: input, atomically: true, encoding: .utf8)
            try Self.run(shell.rawValue, shell.arguments, environment: environment, directory: home,
                         input: input, output: output, errors: errors)
            return Pasted(output: try String(contentsOf: output, encoding: .utf8),
                          errors: try String(contentsOf: errors, encoding: .utf8))
        }

        /// Pastes `block` into an interactive zsh on a pseudo-terminal, as
        /// Terminal does: after `emulate -R zsh` and the case's option, the
        /// block between the bracketed-paste markers, then Return — so zsh's
        /// line editor takes it as one buffer — then the dump line.
        func terminalPaste(_ block: String, options: ZshOptions) throws -> Pasted {
            let terminal = try Terminal(directory: home, environment: environment.merging(["TERM": "xterm-256color"]) { $1 })
            defer { terminal.close() }
            try terminal.awaitLine()
            let setup = ["emulate -R zsh", "PS1='REQRES-PS1> '", "PS2='REQRES-PS2> '", options.rawValue].filter { !$0.isEmpty }
            try terminal.type(setup.joined(separator: "; "))
            terminal.send("\u{1b}[200~" + block + "\u{1b}[201~")
            usleep(200_000)
            terminal.send("\r")
            // An open quote leaves zsh asking for the rest (the next line's
            // prompt is PS2), and nothing ran. ^G — the line editor's
            // send-break — abandons it; ^C would need the terminal to be the
            // session's controlling one, which this one is not.
            let waiting = try terminal.awaitLine().hasSuffix("REQRES-PS2> ")
            if waiting {
                terminal.send("\u{07}")
                try terminal.awaitLine()
            }
            try terminal.type(Pasted.dumpLine(zshOptions: true), until: Pasted.end + "\r\n")
            let transcript = terminal.transcript(from: 0)
            var pasted = Pasted(output: transcript, errors: transcript)
            pasted.leftWaitingForMore = waiting
            return pasted
        }

        /// Runs `executable` in a new session — no controlling terminal, so
        /// an interactive shell can neither take over the terminal the tests
        /// run in nor stop on it — with the three files as its standard
        /// input, output and error, and no other descriptor inherited. The
        /// input is a file, so the shell reaches its end and exits; the bound
        /// only turns a regression into a failure instead of a hang.
        private static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                                directory: URL, input: URL, output: URL, errors: URL) throws {
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, 0, input.path, O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 1, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            posix_spawn_file_actions_addopen(&actions, 2, errors.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

            let argv = ([executable] + arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { (argv + envp).forEach { free($0) } }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }

            var status: Int32 = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while true {
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == pid || (reaped < 0 && errno != EINTR) { return }
                if ProcessInfo.processInfo.systemUptime > deadline {
                    // The test's own child, and only it.
                    kill(pid, SIGKILL)
                    _ = waitpid(pid, &status, 0)
                    throw POSIXError(.ETIMEDOUT)
                }
                usleep(10_000)
            }
        }
    }

    /// An interactive `zsh -f -i` on a pseudo-terminal of its own, 160
    /// columns wide, in a new session. zsh's line editor writes ESC[?2004h —
    /// bracketed paste on — each time it starts reading a line, which is the
    /// signal that it is ready for the next one.
    private final class Terminal {
        private static let lineStart = Array("\u{1b}[?2004h".utf8)
        private static let escapes = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]|\u{1b}[=>]")
        private let master: Int32
        private let pid: pid_t
        private var bytes: [UInt8] = []
        private var consumed = 0
        private var closed = false

        init(directory: URL, environment: [String: String]) throws {
            var master: Int32 = -1, slave: Int32 = -1
            var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw POSIXError(.ENXIO) }
            // The parent needs only the master side.
            defer { Darwin.close(slave) }
            guard let name = ttyname(slave) else {
                Darwin.close(master)
                throw POSIXError(.ENXIO)
            }
            let path = String(cString: name)

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            for descriptor: Int32 in 0...2 {
                posix_spawn_file_actions_addopen(&actions, descriptor, path, O_RDWR, 0)
            }
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

            let arguments = ["/bin/zsh", "-f", "-i"]
            let argv = arguments.map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { (argv + envp).forEach { free($0) } }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
            guard spawned == 0 else {
                Darwin.close(master)
                throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
            }
            self.master = master
            self.pid = pid
        }

        deinit { close() }

        /// The transcript from `offset` (to `end`, or all of it), as text,
        /// with the terminal's escape sequences and carriage returns taken out.
        func transcript(from offset: Int, to end: Int? = nil) -> String {
            let stop = min(end ?? bytes.count, bytes.count)
            let text = String(decoding: bytes[min(offset, stop)..<stop], as: UTF8.self)
            return Self.escapes.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                .replacingOccurrences(of: "\r", with: "")
        }

        /// A blocking write cannot wait on a zsh that is itself waiting to
        /// write to us: its line editor reads a whole bracketed paste before
        /// it redraws, and every other line sent here is short.
        func send(_ text: String) {
            let data = Array(text.utf8)
            var written = 0
            while written < data.count {
                let count = data[written...].withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                written += count
            }
        }

        /// Types `line` and Return, then waits for zsh to be ready again —
        /// or, when `marker` is given, for that text to be printed.
        func type(_ line: String, until marker: String? = nil) throws {
            send(line + "\r")
            if let marker { try waitFor(Array(marker.utf8)) } else { try awaitLine() }
        }

        /// Waits until zsh starts reading its next line, and returns what it
        /// printed since the last one — output, then that line's prompt,
        /// which zsh prints just before the marker, PS2 included.
        @discardableResult
        func awaitLine() throws -> String {
            let start = consumed
            try waitFor(Self.lineStart)
            return transcript(from: start, to: consumed)
        }

        /// A bound, so a shell that stops answering fails the test rather
        /// than hanging it.
        private func waitFor(_ marker: [UInt8], seconds: TimeInterval = 15) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let found = find(marker) {
                    consumed = found
                    return
                }
                read(waitingMilliseconds: 50)
            }
            throw Timeout(waitingFor: String(decoding: marker, as: UTF8.self), transcript: transcript(from: 0))
        }

        struct Timeout: LocalizedError {
            let waitingFor: String
            let transcript: String
            var errorDescription: String? {
                "zsh never printed \(waitingFor.debugDescription) within the bound; the terminal so far:\n\(transcript)"
            }
        }

        private func find(_ marker: [UInt8]) -> Int? {
            guard bytes.count >= consumed + marker.count else { return nil }
            var index = consumed
            while index + marker.count <= bytes.count {
                if bytes[index..<(index + marker.count)].elementsEqual(marker) { return index + marker.count }
                index += 1
            }
            return nil
        }

        private func read(waitingMilliseconds: Int32) {
            var ready = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, waitingMilliseconds) > 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 { bytes += buffer[0..<count] }
        }

        /// Asks zsh to exit and reaps it, reading all the while so it is
        /// never blocked writing to a terminal nobody reads; the test's own
        /// child is killed only if it will not go.
        func close() {
            guard !closed else { return }
            closed = true
            send("exit\r")
            var status: Int32 = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline {
                if waitpid(pid, &status, WNOHANG) == pid {
                    Darwin.close(master)
                    return
                }
                read(waitingMilliseconds: 20)
            }
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
            Darwin.close(master)
        }
    }

    // MARK: - curl and its proxy

    /// curl as the paste's next line: `-q` so no .curlrc is read, `-s` and
    /// `-o /dev/null` so only the `-w` line prints, `-m 5` as a bound.
    private static func curl(_ label: String, _ url: String, reporting variable: String = "http_code") -> String {
        "/usr/bin/curl -q -s -m 5 -o /dev/null -w '\(label)=%{\(variable)}\\n' \(url)"
    }

    /// A loopback port nothing listens on: the kernel picks it for a socket
    /// that is closed at once, so a connection there is refused.
    private static func closedLoopbackPort() throws -> Int {
        let listener = try RecordingProxy.boundSocket()
        defer { Darwin.close(listener.descriptor) }
        return listener.port
    }
}

/// A stand-in proxy on 127.0.0.1, at a port the kernel picks: it answers
/// every request `418` and keeps the request's first line — all a test needs
/// to see where curl sent it. One connection at a time, until stopped.
private final class RecordingProxy {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var lines: [String] = []
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)

    init() throws {
        let bound = try Self.boundSocket()
        guard listen(bound.descriptor, 8) == 0 else {
            let code = errno
            Darwin.close(bound.descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        listener = bound.descriptor
        port = bound.port
        Thread.detachNewThread { [self] in serve() }
    }

    /// Every request line seen so far, in arrival order.
    var requestLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        finished.wait()
        Darwin.close(listener)
    }

    /// A TCP socket bound to 127.0.0.1 at a port the kernel picks.
    static func boundSocket() throws -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                Darwin.bind(descriptor, pointer, length) == 0 && getsockname(descriptor, pointer, &length) == 0
            }
        }
        guard bound else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serve() {
        defer { finished.signal() }
        while !isStopped {
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 50) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            answer(client)
        }
    }

    private func answer(_ client: Int32) {
        defer { Darwin.close(client) }
        var one: Int32 = 1
        // A client that hangs up first must not SIGPIPE the test runner.
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            head.append(contentsOf: buffer[0..<count])
        }
        if let first = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first, !first.isEmpty {
            lock.lock()
            lines.append(first)
            lock.unlock()
        }
        let reply = Array("HTTP/1.1 418 I'm a teapot\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
    }
}
