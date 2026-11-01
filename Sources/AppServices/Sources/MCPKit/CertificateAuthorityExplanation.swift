//
//  CertificateAuthorityExplanation.swift
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
//  The certificate explained, in the app: the explanation lives behind the ?
//  in Settings ▸ Certificate, and Help's certificate topic prints the same
//  words. This file is those words:
//
//  - what the certificate is, and what it is not;
//  - its details — READ from the certificate where they differ per install
//    (`CertificateAuthorityFacts.read(der:)`, Security.framework calls that
//    exist on macOS 14), stated where they are the core's policy
//    (`CertificateAuthority.generate` / `mintLeaf` in XReqResCore);
//  - how to remove it by hand, with a Terminal command that deletes BY
//    FINGERPRINT. Never by name: every ReqRes certificate is called
//    "ReqRes CA", so `delete-certificate -c` matches all of them.
//
//  Only THIS Mac's certificate is described (the story of the 1.0.x certificate
//  it replaced is of no use to a new user). Users who still have that one are
//  told by `CAMigrationSheet` and the banner in Settings ▸ Certificate, not
//  here.
//
//  `security delete-certificate -Z` takes a SHA-1 on every macOS (SHA-256 is
//  not proven on 14.x), so the command prints this installation's SHA-1,
//  computed from its DER at runtime. Run against throwaway keychains on
//  macOS 27: the list command and `-t -Z` on an untrusted certificate. `-t`
//  edits the USER's trust settings whatever keychain it is given.
//

import CryptoKit
import Foundation
import Security

public enum CertificateAuthorityExplanation {

    // MARK: - The words

    public static let title = "About the ReqRes Certificate"

    /// (a) What it is, and what it lets ReqRes do.
    public static let whatItIs = "“ReqRes CA” is a certificate authority ReqRes made on this Mac, for this installation. Once you trust it, apps that use your keychain accept the certificates ReqRes makes for the websites they connect to while capture runs — which is how ReqRes can show their HTTPS traffic."

    /// (a) What it does not do.
    public static let whatItIsNot = "It is trusted only for your user account on this Mac. Nothing else can use it to make certificates: that takes its private key, which ReqRes never sends anywhere. Tools that keep their own list of trusted certificates instead of reading the keychain — node and Java, for example — do not trust it unless you give it to them."

    public static let detailsHeading = "Its details"
    /// Where the SHA-256 is, rather than printing it twice.
    public static let sha256Pointer = "Its SHA-256 is the one shown under ReqRes CA in Settings ▸ Certificate, behind this window."

    /// (b) The policy half of the details — the same on every install
    /// because the core makes every CA the same way.
    public static let policy: [String] = [
        "An RSA 2,048-bit key, signed with SHA-256. Valid for ten years; its validity starts a day before it was made, for clocks that run a little behind.",
        "When trusted, your Mac trusts it for two things only: secure website connections (SSL) and basic certificate checks (X.509). It cannot create another certificate authority below it.",
        "For each website capture decrypts, ReqRes's capture extension makes a certificate for that website in memory, valid for 90 days, and never writes it to disk. They all share one RSA 2,048-bit key, made on this Mac together with the certificate authority.",
        CertificateAuthorityPresentation.custody,
    ]

    public static let removeHeading = "Removing the certificate by hand"

    /// (c) Why anyone would.
    public static let removeIntro = "Deleting ReqRes does not remove its certificate or your trust in it. To remove it when you stop using ReqRes:"

    /// (c) Keychain Access, step by step.
    public static let keychainSteps: [String] = [
        "Open Keychain Access (search for it with Spotlight).",
        "Choose the login keychain, then Certificates, and search for “ReqRes CA”. If one is in the System keychain, the same steps apply there and need an administrator password.",
        "Double-click it and check that the SHA-1 under Fingerprints matches this Mac's, listed under “Its details” behind the ? in Settings ▸ Certificate.",
        "Open Trust and set “When using this certificate” to “Use System Defaults”, then close it; macOS asks for your password.",
        "Select it, press Delete, and confirm.",
    ]

    /// (c) Terminal, said before the commands.
    public static let terminalIntro = "Or in Terminal. The removal command deletes by fingerprint, not by name, so it removes exactly this certificate, and its -t removes your trust in it too, so macOS asks for your password."

    public static let listCommandCaption = "Find “ReqRes CA” in your login keychain, with its SHA-1:"
    public static let currentCommandCaption = "Remove this Mac's certificate (when you stop using ReqRes):"

    /// After removing this installation's.
    public static let afterRemovingCurrent = "Once nothing trusts it — no keychain, and no tool you gave an exported copy to — the private key left in ReqRes's container cannot make anything your Mac accepts. If you exported the certificate as a file for command-line tools, delete that file and the lines that point to it too."

    /// The same keychain for every command, spelled the way Terminal expands it.
    public static let loginKeychain = "~/Library/Keychains/login.keychain-db"

    /// Lists every "ReqRes CA" with its SHA-1. Read-only.
    public static func listCommand(keychain: String = loginKeychain) -> String {
        "security find-certificate -a -Z -c \"ReqRes CA\" \(keychain) | grep SHA-1"
    }

    /// Deletes the certificate whose SHA-1 is `sha1Hex` (40 hex digits, any
    /// case or spacing), with its user trust settings. Nil for anything that
    /// is not a SHA-1 — never a command built around a guess.
    public static func deleteCommand(sha1Hex: String, keychain: String = loginKeychain) -> String? {
        let hex = sha1Hex.filter { !$0.isWhitespace && $0 != ":" }
        guard hex.count == 40, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "security delete-certificate -t -Z \(hex.uppercased()) \(keychain)"
    }

    // MARK: - Details read from the certificate

    public struct Fact: Equatable, Sendable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// The per-install rows, from the certificate itself. Rows the
    /// certificate did not answer are left out rather than guessed.
    public static func installFacts(_ facts: CertificateAuthorityFacts,
                                    timeZone: TimeZone = .current,
                                    locale: Locale = .current) -> [Fact] {
        var rows: [Fact] = []
        if let unit = facts.organizationalUnit { rows.append(Fact(label: "Organizational unit", value: unit)) }
        if let from = facts.notBefore { rows.append(Fact(label: "Valid from", value: dateText(from, timeZone: timeZone, locale: locale))) }
        if let until = facts.notAfter { rows.append(Fact(label: "Expires", value: dateText(until, timeZone: timeZone, locale: locale))) }
        if let bits = facts.keySizeBits {
            let number = NumberFormatter.localizedString(from: NSNumber(value: bits), number: .decimal)
            rows.append(Fact(label: "Key", value: "RSA, \(number) bits"))
        }
        if !facts.serialNumberHex.isEmpty {
            rows.append(Fact(label: "Serial number", value: spacedPairs(facts.serialNumberHex)))
        }
        rows.append(Fact(label: "SHA-1", value: spacedPairs(facts.sha1)))
        return rows
    }

    static func dateText(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// "0a1b2c" → "0A 1B 2C", how Keychain Access prints a serial or a SHA-1.
    static func spacedPairs(_ hex: String) -> String {
        var pairs: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            pairs.append(String(hex[index..<next]).uppercased())
            index = next
        }
        return pairs.joined(separator: " ")
    }
}

/// What a certificate says about itself, read with Security.framework calls
/// that exist on macOS 14 (`SecCertificateCopyValues`,
/// `SecCertificateCopySerialNumberData`, `SecCertificateCopyKey`).
public struct CertificateAuthorityFacts: Equatable, Sendable {
    public var commonName: String?
    public var organization: String?
    public var organizationalUnit: String?
    public var notBefore: Date?
    public var notAfter: Date?
    /// Lowercase hex, no separators; leading zero bytes as the DER has them.
    public var serialNumberHex: String
    public var keySizeBits: Int?
    /// Lowercase hex, no separators.
    public var sha1: String
    public var sha256: String

    public static func read(der: Data) -> CertificateAuthorityFacts? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        let values = SecCertificateCopyValues(certificate, [
            kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1SubjectName,
        ] as CFArray, nil) as? [String: Any] ?? [:]

        func date(_ oid: CFString) -> Date? {
            guard let entry = values[oid as String] as? [String: Any],
                  let number = entry[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        var subject: [String: String] = [:]
        if let entry = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
           let parts = entry[kSecPropertyKeyValue as String] as? [[String: Any]] {
            for part in parts {
                if let oid = part[kSecPropertyKeyLabel as String] as? String,
                   let value = part[kSecPropertyKeyValue as String] as? String,
                   subject[oid] == nil {
                    subject[oid] = value
                }
            }
        }
        let serial = (SecCertificateCopySerialNumberData(certificate, nil) as Data?)
            .map { $0.map { String(format: "%02x", $0) }.joined() } ?? ""
        let bits = SecCertificateCopyKey(certificate)
            .flatMap { SecKeyCopyAttributes($0) as? [String: Any] }
            .flatMap { $0[kSecAttrKeySizeInBits as String] as? Int }
        return CertificateAuthorityFacts(
            commonName: subject["2.5.4.3"],
            organization: subject["2.5.4.10"],
            organizationalUnit: subject["2.5.4.11"],
            notBefore: date(kSecOIDX509V1ValidityNotBefore),
            notAfter: date(kSecOIDX509V1ValidityNotAfter),
            serialNumberHex: serial,
            keySizeBits: bits,
            sha1: Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined(),
            sha256: SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        )
    }
}
