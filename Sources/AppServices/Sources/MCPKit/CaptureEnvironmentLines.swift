//
//  CaptureEnvironmentLines.swift
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
//  "Capture a command-line tool" (process-attribution PRD, §5E): the
//  environment a terminal needs before node, the Claude Code CLI or anything
//  else that ignores the system proxy will send its traffic through ReqRes —
//  as text a user pastes, and the one check that keeps the certificate export
//  safe to hand out.
//
//  ONE renderer (UX spec errata 3). Settings ▸ Capture, the in-app Help and
//  the `capture_environment` MCP tool all print this block, and they used to
//  print it from two implementations that disagreed on the fourth line's
//  comment within a day. So the type lives in MCPKit, which every one of
//  those surfaces already links, and `MCPCaptureEnvironment.shellLines` is a
//  call into it. The only thing a caller substitutes is the exported
//  certificate's path.
//
//  Pure Foundation on purpose: no AppKit, no SwiftUI, no core import, so it is
//  asserted by a plain `swift test`. The proxy port is a PARAMETER — the
//  caller hands it `MCPLimits.proxyPort`, the constant the diagnosis and the
//  replay adapter already use — rather than this file carrying a second
//  `8034` to drift.
//

import Foundation

/// The lines a shell needs, rendered for the certificate path the user
/// actually exported to (or a tilde placeholder until they have).
///
/// Every line is there for the readers `legend` names, and each was read
/// from the tool's own source rather than assumed:
/// - The proxy in both spellings, one line per scheme (F16). curl takes a
///   plain-HTTP proxy only from lowercase `http_proxy` (`man curl`, 8.7.1:
///   "http_proxy is an exception as it is only available in lower case"),
///   and git's http:// goes through libcurl: with only `HTTP_PROXY`
///   exported, `curl http://…` and `git ls-remote http://…` went straight to
///   the server (measured 2026-09-30). A lowercase `https_proxy` or
///   `http_proxy` already in the shell — a corporate proxy, say — outranks
///   the uppercase name in curl, git, Python and node, so ReqRes was skipped
///   even for HTTPS; exporting both spellings overwrites it. The uppercase
///   names stay: Ruby's Net::HTTP proxies https:// too through
///   `http_proxy`/`HTTP_PROXY` alone, and Python's urllib and node were
///   measured reading the uppercase ones.
/// - node's built-in `fetch`/`https` ignore `HTTPS_PROXY` unless
///   `NODE_USE_ENV_PROXY=1` (node ≥ 24); the Claude Code CLI honours the
///   proxy variables in its own code (measured 2026-09-25).
/// - Go on macOS does NOT read `SSL_CERT_FILE` — `crypto/x509`'s
///   `root_unix.go` excludes darwin and Go verifies through the keychain — so
///   `legend` names curl, Python's urllib/httpx and OpenSSL-based tools,
///   never Go.
/// - Python `requests` ignores `SSL_CERT_FILE` and reads `REQUESTS_CA_BUNDLE`.
/// - `NO_PROXY` / `no_proxy` (protocol PRD §1.14, Phase 0.4): loopback skips
///   the proxy. The lines came in while ReqRes's plain-HTTP path reached only
///   port 80, so `http://localhost:3000` sent through the proxy HUNG with no
///   response and no row. Core C5 put plain HTTP on the exchange engine, on
///   any port; the lines stay until a local backend is shown to work through
///   the proxy, and Help and the protocol table say how to include one
///   (`unset NO_PROXY no_proxy`).
///   Both spellings, because the readers disagree: curl, Python and Go read
///   either spelling of this one, while wget and some others read only the
///   lowercase one.
///   The cost, accepted by the PRD: `HTTPS_PROXY` honours `NO_PROXY` too, so
///   an `https://localhost:8443` backend — which the CONNECT path COULD
///   capture on any port — is no longer sent to ReqRes from this shell either.
///   And `export NO_PROXY=…` replaces a `NO_PROXY` the shell already had (a
///   corporate bypass list, say); appending with `${NO_PROXY:+$NO_PROXY,}`
///   would keep it, and is not done here.
///
/// The block carries NO comment, beside a command or on a line of its own
/// (F16; measured 2026-09-30 with zsh 5.9 on a pseudo-terminal, pasted the
/// way Terminal pastes). zsh — macOS's default shell — turns bracketed paste
/// on, so a paste arrives as ONE buffer that runs when Return is pressed,
/// and without `interactivecomments`, which macOS's /etc/zshrc does not set,
/// `#` is an ordinary word. A comment's words became arguments to the
/// `export` before them, and the first one `export` refused ("not valid in
/// this context: same,") dropped every line after it: pasting the commented
/// block left NODE_USE_ENV_PROXY and all three certificate variables unset.
/// An apostrophe ("node's") opened a quote and nothing ran at all; a word
/// like `~node` ends the paste the same way, and with `extendedglob` so does
/// `#` itself, even on a line of its own. Fed line by line — typed, or on
/// standard input — each line runs on its own and the failure hides. So the
/// text shown is the text Copy copies, Help prints and `capture_environment`
/// returns, and what each line is for is `legend`, printed beside the block.
public struct CaptureEnvironmentLines: Equatable, Sendable {
    /// What the save panel proposes AND the file name in the placeholder, so
    /// the block someone copies BEFORE exporting still matches what they get
    /// by accepting the panel's default.
    public static let exportFilename = "reqres-ca.pem"

    /// Shown until an export has happened. Tilde form deliberately: a shell
    /// expands `~` after `=` in an assignment, and it is the same path the
    /// keychain command below writes to.
    public static let fallbackCertificatePath = "~/reqres-ca.pem"

    /// The common name the CA is installed under in the login keychain, and
    /// therefore the `-c` argument `security find-certificate` needs (read
    /// from the installed certificate's subject, not assumed).
    public static let certificateCommonName = "ReqRes CA"

    /// The other way to get the PEM — out of the login keychain, once
    /// Settings ▸ Certificate has installed it there. The PEM the app writes
    /// itself sits in an app-group container a shell is TCC-denied to read;
    /// the keychain is the one place a shell CAN get the CA from, which is
    /// what makes the rest of the block work before a first export.
    ///
    /// Selected by FINGERPRINT, never by name alone: after an upgrade the
    /// keychain can hold two certificates called "ReqRes CA" — the 1.0.x
    /// shared one (its private key is public) and this install's — until the
    /// migration sheet replaces the old one, and `find-certificate -c` without
    /// `-a` returns the one added FIRST, i.e. the old one (reproduced with a
    /// throwaway keychain, release review 2026-09-29). `-a -Z` lists every
    /// match with its SHA-256; awk keeps the block under the matching hash.
    /// Run again, it rewrites a `~/reqres-ca.pem` an earlier build wrote —
    /// with `>|`, which overrides `noclobber` (zsh's `setopt noclobber`,
    /// bash's `set -C`): with a plain `>` such a shell refused the existing
    /// file ("file exists"), ran the rest, and left the certificate variables
    /// pointing at the old CA (measured 2026-09-30).
    public static func keychainCommand(fingerprint: String) -> String {
        "security find-certificate -a -Z -c \"\(certificateCommonName)\" -p"
            + " | awk -v f=\(normalizedFingerprint(fingerprint))"
            + " '/^SHA-256 hash:/{k=($3==f)} k&&/BEGIN CERT/{p=1} p{print} /END CERT/{p=0}'"
            + " >| \(fallbackCertificatePath)"
    }

    /// `security` prints the SHA-256 as uppercase hex with no separators;
    /// the app keeps it lowercase. Anything but hex digits is dropped, so a
    /// colon-separated form works too and nothing else reaches the shell.
    public static func normalizedFingerprint(_ fingerprint: String) -> String {
        String(fingerprint.uppercased().filter { $0.isHexDigit && $0.isASCII })
    }

    /// What each line is for, printed BESIDE the block (Settings ▸ Capture),
    /// never in it (see the type). Each claim is one of the type's bullets,
    /// and it names every variable the block exports — a drift the tests
    /// check, so a line cannot arrive without its reason.
    public static let legend = "Each proxy variable is set in both spellings, HTTPS_PROXY and https_proxy, HTTP_PROXY and http_proxy: curl and git take the proxy for plain http:// only from http_proxy, and a lowercase variable already in the shell would win over the uppercase one. NO_PROXY and no_proxy keep localhost, 127.0.0.1 and ::1 out of the proxy. NODE_USE_ENV_PROXY=1 makes the fetch and https built into node 24 and later use the proxy. The certificate file goes to node and Claude Code in NODE_EXTRA_CA_CERTS, to curl, Python’s urllib and httpx and OpenSSL-based tools in SSL_CERT_FILE, and to Python requests in REQUESTS_CA_BUNDLE."

    /// Where `CaptureSettingsView` remembers the last export, so the block can
    /// show the real path afterwards — and where the app's MCP status adapter
    /// reads it from, so `capture_environment` prints the same path. The path
    /// only, not a bookmark: the app never reads the file back, it only tells
    /// the user (and the agent) where they put it.
    public static let exportedPathDefaultsKey = "CaptureCAExportedPath"

    /// Beside the path: the SHA-256 (lowercase hex) of the certificate that
    /// export wrote. 1.1.0 gives every install its own CA, so a file exported
    /// earlier can hold a CA this Mac no longer uses — and a sandboxed app
    /// cannot rewrite a path it only remembers. Comparing this with the
    /// install's CA is how the pane, `capture_environment` and
    /// `diagnose_setup` know to say "export again" (protocol PRD 4 Phase 2.1).
    public static let exportedFingerprintDefaultsKey = "CaptureCAExportedFingerprint"

    /// What the remembered export holds, against the install's CA.
    public enum ExportFreshness: String, Equatable, Sendable {
        /// Nothing exported.
        case none
        /// The file holds this install's CA.
        case current
        /// The file holds another CA — the 1.0.x shared one, or an earlier
        /// install's. Tools pointed at it fail TLS once ReqRes intercepts.
        case outdated
        /// The install's CA could not be produced, so there is nothing to
        /// compare with.
        case unknown
    }

    /// An export with no fingerprint beside it was written by a build that
    /// stored none — before 1.1.0's per-install CA — so it holds the 1.0.x
    /// shared certificate: outdated.
    public static func exportFreshness(exportedPath: String?, exportedFingerprint: String?,
                                       currentFingerprint: String?) -> ExportFreshness {
        guard !(exportedPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        guard let current = currentFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !current.isEmpty else { return .unknown }
        let exported = (exportedFingerprint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return exported == current ? .current : .outdated
    }

    public let proxyPort: Int
    /// The exported certificate's path, or nil before any export. An empty
    /// or blank string (what an unset `@AppStorage` reads as) counts as nil.
    public let certificatePath: String?

    /// This install's CA fingerprint (SHA-256, hex), which the keychain step
    /// selects by; nil when unknown, and then there is no keychain step.
    public let caFingerprint: String?

    public init(proxyPort: Int, certificatePath: String? = nil, caFingerprint: String? = nil) {
        self.proxyPort = proxyPort
        let trimmed = certificatePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.certificatePath = trimmed.isEmpty ? nil : trimmed
        let fingerprint = caFingerprint.map(Self.normalizedFingerprint) ?? ""
        self.caFingerprint = fingerprint.isEmpty ? nil : fingerprint
    }

    public var hasExportedCertificate: Bool { certificatePath != nil }

    /// Whether the block writes the CA out of the login keychain: only before
    /// an export, and only while this install's fingerprint is known.
    public var hasKeychainStep: Bool { !hasExportedCertificate && caFingerprint != nil }

    public var proxyURL: String { "http://127.0.0.1:\(proxyPort)" }

    /// What follows `=` on the certificate lines: the exported path, quoted
    /// only when a shell would otherwise split or expand it, else the tilde
    /// placeholder (which must NOT be quoted, or `~` stops expanding).
    public var certificateArgument: String {
        certificatePath.map(Self.shellQuoted) ?? Self.fallbackCertificatePath
    }

    /// The block in the order it has to run: the proxy, the loopback bypass,
    /// node's opt-in, the certificate export (only while no exported file is
    /// known — once there is one, the variables point at it and the keychain
    /// step would overwrite nothing useful), then the variables that point at
    /// the file. One command per line and nothing else (see the type).
    public var lines: [String] {
        var lines = [
            // Both spellings on one line per scheme (see the type's comment).
            "export HTTPS_PROXY=\(proxyURL) https_proxy=\(proxyURL)",
            "export HTTP_PROXY=\(proxyURL) http_proxy=\(proxyURL)",
            "export NO_PROXY=\(Self.noProxyHosts)",
            "export no_proxy=\(Self.noProxyHosts)",
            "export NODE_USE_ENV_PROXY=1",
        ]
        if !hasExportedCertificate, let caFingerprint {
            lines.append(Self.keychainCommand(fingerprint: caFingerprint))
        }
        return lines + [
            "export NODE_EXTRA_CA_CERTS=\(certificateArgument)",
            "export SSL_CERT_FILE=\(certificateArgument)",
            "export REQUESTS_CA_BUNDLE=\(certificateArgument)",
        ]
    }

    /// Loopback in every spelling a client might resolve `localhost` to. Kept
    /// out of the proxy until a local backend is shown to work through it:
    /// the lines came in while plain `http://` through the proxy reached only
    /// port 80 (protocol PRD §1.7), so a backend on :3000 hung rather than
    /// being captured — core C5 has since put plain HTTP on the exchange
    /// engine, on any port.
    public static let noProxyHosts = "localhost,127.0.0.1,::1"

    /// `lines`, newline-separated, no trailing newline — what the pane's box
    /// shows and its Copy button copies, the Help example and
    /// `capture_environment` print: one text, pasted as it stands.
    public var text: String { lines.joined(separator: "\n") }

    /// Single-quotes a path unless every character is one a POSIX shell takes
    /// literally. A space in a folder name is the common case; an apostrophe
    /// is the one that breaks naive single-quoting, so it is closed, escaped
    /// and reopened (`'It'\''s'`).
    public static func shellQuoted(_ path: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%,:")
        if !path.isEmpty, path.allSatisfy(safe.contains) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The one rule of the export: only certificate blocks leave the app.
///
/// `cacert.pem` holds the certificate alone and the CA's private key sits in a
/// separate file, so this should be a no-op — but a file that LEAVES the app
/// is worth checking rather than trusting. An export that carried the key
/// would hand whoever found it the ability to sign as ReqRes for every user,
/// since the CA is the same in every install.
public enum CACertificateExport {
    private static let begin = "-----BEGIN CERTIFICATE-----"
    private static let end = "-----END CERTIFICATE-----"

    /// The certificate block(s) in `pem`, each on its own lines with a single
    /// trailing newline — or nil when there is no certificate to export, which
    /// the caller reports rather than writing an empty file.
    public static func certificateOnly(_ pem: String) -> String? {
        var blocks: [String] = []
        var remainder = pem[...]
        while let start = remainder.range(of: begin),
              let stop = remainder.range(of: end, range: start.upperBound..<remainder.endIndex) {
            blocks.append(String(remainder[start.lowerBound..<stop.upperBound]))
            remainder = remainder[stop.upperBound...]
        }
        guard !blocks.isEmpty else { return nil }
        return blocks.joined(separator: "\n") + "\n"
    }
}
