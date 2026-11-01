//
//  ProcessIdentityTests.swift
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
//  The ONE naming rule behind the App column, the `app:` token, the detail
//  pill, the saved-sessions browser and the MCP helper's identity header
//  (UX spec §1.2 + errata 1). Every case the spec lists, plus the two
//  well-known system services.
//

import XCTest
@testable import MCPKit

final class ProcessIdentityTests: XCTestCase {
    private let bravePath = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/140.1.83.109/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"

    // MARK: - Bundled apps and helpers

    /// A Chromium helper is three bundles deep; the app the user recognises
    /// is the OUTERMOST one, and the helper is demoted, not hidden.
    func testAChromiumHelperIsNamedForItsOutermostBundle() {
        let identity = ProcessIdentity(name: "Brave Browser Helper", pid: 4127, executablePath: bravePath)

        XCTAssertEqual(identity.displayName, "Brave Browser")
        XCTAssertEqual(identity.bundlePath, "/Applications/Brave Browser.app")
        XCTAssertEqual(identity.executableName, "Brave Browser Helper")
        XCTAssertTrue(identity.isHelper)
        XCTAssertTrue(identity.isKnown)
        XCTAssertFalse(identity.isSystemService)
    }

    func testAnAppRunFromDerivedDataIsNamedForItsBundle() {
        let path = "/Users/dev/Library/Developer/Xcode/DerivedData/MyShop-abc/Build/Products/Debug/MyShop.app/Contents/MacOS/MyShop"
        let identity = ProcessIdentity(name: "MyShop", pid: 48213, executablePath: path)

        XCTAssertEqual(identity.displayName, "MyShop")
        XCTAssertEqual(identity.bundlePath, "/Users/dev/Library/Developer/Xcode/DerivedData/MyShop-abc/Build/Products/Debug/MyShop.app")
        XCTAssertFalse(identity.isHelper, "the bundle's own executable is not a helper")
    }

    func testAPathWithSpacesResolves() {
        let identity = ProcessIdentity(name: nil, pid: 7, executablePath: "/Users/dev/My Tools/bin/my tool")

        XCTAssertEqual(identity.displayName, "my tool")
        XCTAssertEqual(identity.executableName, "my tool")
        XCTAssertNil(identity.bundlePath)
    }

    /// Only a component ENDING in `.app` is a bundle: `.app/` or a trailing
    /// `.app`, never `.app.` inside a folder name.
    func testAFolderNamedNotAppBackupIsNotABundle() {
        let identity = ProcessIdentity(name: nil, pid: 1, executablePath: "/Users/dev/Not.app.backup/bin/tool")

        XCTAssertNil(identity.bundlePath)
        XCTAssertEqual(identity.displayName, "tool")
        XCTAssertFalse(identity.isHelper)
    }

    func testATrailingAppComponentIsABundle() {
        let identity = ProcessIdentity(name: nil, pid: 1, executablePath: "/Applications/Foo.app")

        XCTAssertEqual(identity.bundlePath, "/Applications/Foo.app")
        XCTAssertEqual(identity.displayName, "Foo")
    }

    func testABareDotAppComponentIsNotABundle() {
        let identity = ProcessIdentity(name: nil, pid: 1, executablePath: "/Users/dev/.app/bin/tool")

        XCTAssertNil(identity.bundlePath, "a hidden folder called .app has no name to show")
        XCTAssertEqual(identity.displayName, "tool")
    }

    // MARK: - Bare executables

    func testABareExecutableIsNamedForItsFile() {
        let identity = ProcessIdentity(name: "claude", pid: 9437, executablePath: "/usr/local/bin/claude")

        XCTAssertEqual(identity.displayName, "claude")
        XCTAssertNil(identity.bundlePath)
        XCTAssertEqual(identity.executableName, "claude")
        XCTAssertFalse(identity.isHelper)
        XCTAssertFalse(identity.isSystemService)
    }

    func testANameWithoutAPathIsTheName() {
        let identity = ProcessIdentity(name: "curl", pid: 501, executablePath: nil)

        XCTAssertEqual(identity.displayName, "curl")
        XCTAssertEqual(identity.executableName, "curl")
        XCTAssertNil(identity.bundlePath)
        XCTAssertTrue(identity.isKnown)
    }

    /// The path decides, not the reported name: the core's name is whatever
    /// the kernel had (possibly truncated), the path is the executable.
    func testThePathWinsOverTheReportedName() {
        let identity = ProcessIdentity(name: "Brave Browser Helper", pid: 1, executablePath: "/usr/local/bin/node")
        XCTAssertEqual(identity.displayName, "node")
    }

    // MARK: - Unknown

    func testAllNilIsUnknown() {
        let identity = ProcessIdentity(name: nil, pid: nil, executablePath: nil)

        XCTAssertNil(identity.displayName)
        XCTAssertNil(identity.executableName)
        XCTAssertNil(identity.bundlePath)
        XCTAssertFalse(identity.isKnown)
        XCTAssertFalse(identity.isHelper)
        XCTAssertFalse(identity.isSystemService)
        XCTAssertEqual(identity.tooltip, ProcessIdentity.unknownTooltip)
    }

    /// A pid nobody can name is not an identity — the row reads Unknown, not
    /// "pid 512".
    func testAPidAloneIsStillUnknown() {
        let identity = ProcessIdentity(name: nil, pid: 512, executablePath: nil)
        XCTAssertFalse(identity.isKnown)
        XCTAssertNil(identity.displayName)
        XCTAssertEqual(identity.tooltip, ProcessIdentity.unknownTooltip)
    }

    func testBlankStringsCollapseToNil() {
        let identity = ProcessIdentity(name: "   ", pid: 3, executablePath: "\n")

        XCTAssertNil(identity.name)
        XCTAssertNil(identity.executablePath)
        XCTAssertFalse(identity.isKnown)
        XCTAssertEqual(identity, ProcessIdentity(name: nil, pid: 3, executablePath: nil), "one spelling of unattributed")
    }

    func testTheUnknownLabelIsTheTablesWord() {
        XCTAssertEqual(ProcessIdentity.unknownLabel, "Unknown")
        XCTAssertTrue(ProcessIdentity.unknownTooltip.contains("could not be named"))
        XCTAssertTrue(ProcessIdentity.unknownTooltip.contains("Nothing is inferred from headers"))
        XCTAssertFalse(ProcessIdentity.unknownTooltip.contains("nsurlsessiond"),
                       "this build NAMES nsurlsessiond (Background) — citing it as the example of Unknown would be false")
    }

    // MARK: - Well-known system services (errata 1)

    /// Safari's networking is the shared WebKit XPC service, not Safari. It is
    /// named for what it is, with a note saying whose traffic it carries, and
    /// a symbol instead of Safari's icon.
    func testWebKitNetworkingIsANamedSystemService() {
        let path = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
        let identity = ProcessIdentity(name: "com.apple.WebKit.Networking", pid: 512, executablePath: path)

        XCTAssertTrue(identity.isSystemService)
        XCTAssertEqual(identity.displayName, "WebKit", "the full name truncated at both column widths; it lives in the note")
        XCTAssertEqual(identity.systemServiceNote, "WebKit Networking — shared by Safari and other WebKit apps")
        XCTAssertEqual(identity.systemServiceSymbol, "network")
        XCTAssertEqual(identity.executableName, "com.apple.WebKit.Networking")
        XCTAssertNil(identity.bundlePath, "an .xpc service is not an .app")
        XCTAssertFalse(identity.isHelper)
        XCTAssertTrue(identity.tooltip.contains("WebKit · pid 512"))
        XCTAssertTrue(identity.tooltip.contains("WebKit Networking — shared by Safari and other WebKit apps"), "the tooltip carries the note")
        XCTAssertTrue(identity.tooltip.contains(path))
    }

    /// The §1.2 example said "nsurlsessiond"; errata 1 names it. The
    /// executable keeps its real name, the display gets the friendly one.
    func testNsurlsessiondIsBackgroundTransfers() {
        let identity = ProcessIdentity(name: "nsurlsessiond", pid: 77, executablePath: "/usr/libexec/nsurlsessiond")

        XCTAssertTrue(identity.isSystemService)
        XCTAssertEqual(identity.executableName, "nsurlsessiond")
        XCTAssertEqual(identity.displayName, "Background")
        XCTAssertEqual(identity.systemServiceNote, "Background transfers (nsurlsessiond) — downloads and uploads an app handed to the system")
        XCTAssertEqual(identity.systemServiceSymbol, "arrow.down.circle")
        XCTAssertNil(identity.bundlePath)
        XCTAssertFalse(identity.isHelper, "a system service is not a helper of any bundle")
    }

    /// The core may report a name with no path; the service is still known.
    func testASystemServiceIsRecognisedByNameAlone() {
        let identity = ProcessIdentity(name: "nsurlsessiond", pid: nil, executablePath: nil)
        XCTAssertTrue(identity.isSystemService)
        XCTAssertEqual(identity.displayName, "Background")
        XCTAssertEqual(identity.tooltip, "Background\nBackground transfers (nsurlsessiond) — downloads and uploads an app handed to the system")
    }

    /// A browser that ships its own WebKit names its networking process after
    /// itself — inside a bundle, the bundle wins over the service table.
    func testAServiceInsideAnAppBundleBelongsToThatApp() {
        let path = "/Applications/Safari Technology Preview.app/Contents/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
        let identity = ProcessIdentity(name: "com.apple.WebKit.Networking", pid: 9, executablePath: path)

        XCTAssertFalse(identity.isSystemService)
        XCTAssertNil(identity.systemServiceNote)
        XCTAssertNil(identity.systemServiceSymbol)
        XCTAssertEqual(identity.displayName, "Safari Technology Preview")
        XCTAssertTrue(identity.isHelper)
    }

    func testOrdinaryProcessesHaveNoServiceNoteOrSymbol() {
        for identity in [
            ProcessIdentity(name: "claude", pid: 1, executablePath: "/usr/local/bin/claude"),
            ProcessIdentity(name: nil, pid: 2, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"),
            ProcessIdentity(name: nil, pid: nil, executablePath: nil),
        ] {
            XCTAssertNil(identity.systemServiceNote, "\(identity)")
            XCTAssertNil(identity.systemServiceSymbol, "\(identity)")
        }
    }

    // MARK: - Tooltip (spec §2.3)

    func testTooltipForABundledApp() {
        let identity = ProcessIdentity(name: "Safari", pid: 40213, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari")
        XCTAssertEqual(identity.tooltip, "Safari · pid 40213\n/Applications/Safari.app")
    }

    func testTooltipForAHelperNamesTheHelperAndItsFullPath() {
        let identity = ProcessIdentity(name: "Brave Browser Helper", pid: 4127, executablePath: bravePath)
        XCTAssertEqual(identity.tooltip, "Brave Browser · pid 4127\nBrave Browser Helper — \(bravePath)")
    }

    func testTooltipForABareExecutable() {
        let identity = ProcessIdentity(name: "claude", pid: 9437, executablePath: "/usr/local/bin/claude")
        XCTAssertEqual(identity.tooltip, "claude · pid 9437\n/usr/local/bin/claude")
    }

    func testTooltipWithoutAPidHasNoPidFragment() {
        let identity = ProcessIdentity(name: "curl", pid: nil, executablePath: nil)
        XCTAssertEqual(identity.tooltip, "curl")
        XCTAssertFalse(identity.tooltip.contains("pid"))
    }

    // MARK: - Value semantics

    func testIdentitiesAreHashableByTheirFields() {
        let a = ProcessIdentity(name: "claude", pid: 9437, executablePath: "/usr/local/bin/claude")
        let b = ProcessIdentity(name: "claude", pid: 9437, executablePath: "/usr/local/bin/claude")
        let c = ProcessIdentity(name: "claude", pid: 9767, executablePath: "/usr/local/bin/claude")

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, c, "two claude processes are two identities")
    }

    // MARK: - The helper names its parent by the same rule

    /// `MCPBridgeClient.parentProcessName()` reads this process's parent and
    /// hands the path to `ProcessIdentity`. Whatever spawned the test runner,
    /// the answer is the rule's answer for that path — asserted through the
    /// same seam the helper uses, so the footer and the App column cannot
    /// name a process two ways.
    func testParentProcessNameIsProcessIdentitysDisplayName() {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
        guard length > 0 else {
            XCTAssertNil(MCPBridgeClient.parentProcessName(), "no path, no name")
            return
        }
        let path = String(cString: buffer)
        XCTAssertEqual(
            MCPBridgeClient.parentProcessName(),
            ProcessIdentity(name: nil, pid: nil, executablePath: path).displayName
        )
    }

    // MARK: - Xcode's toolchain

    /// /usr/bin/git, python3, swift and xcodebuild exec into
    /// Xcode.app/Contents/Developer. Those are tools a terminal ran, not Xcode
    /// making a request: the outermost-bundle rule must not swallow them, or
    /// `app:git` matches nothing and Settings says no tool reached ReqRes
    /// right after `git ls-remote` did.
    func testAToolInsideXcodesToolchainIsNotXcode() {
        let git = ProcessIdentity(name: "git", pid: 61, executablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        XCTAssertNil(git.bundlePath)
        XCTAssertEqual(git.displayName, "git")
        XCTAssertFalse(git.isHelper)
        XCTAssertEqual(git.tooltip, "git · pid 61\n/Applications/Xcode.app/Contents/Developer/usr/bin/git")

        let swift = ProcessIdentity(name: "swift-frontend", pid: 62,
                                    executablePath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend")
        XCTAssertEqual(swift.displayName, "swift-frontend")

        // Xcode itself, and its own helpers, are still Xcode.
        let xcode = ProcessIdentity(name: "Xcode", pid: 60, executablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode")
        XCTAssertEqual(xcode.bundlePath, "/Applications/Xcode.app")
        XCTAssertEqual(xcode.displayName, "Xcode")
        let helper = ProcessIdentity(name: "XCBBuildService", pid: 63,
                                     executablePath: "/Applications/Xcode.app/Contents/SharedFrameworks/XCBuild.framework/Versions/A/PlugIns/XCBBuildService.bundle/Contents/MacOS/XCBBuildService")
        XCTAssertEqual(helper.displayName, "Xcode")
        XCTAssertTrue(helper.isHelper)
    }

    /// The busy-port alert's holder, measured 2026-09-29: Apple's python3 is
    /// a Python.app inside Xcode's Developer folder — the tool, not "Xcode".
    func testApplesPythonInsideXcodeIsPython() {
        let python = ProcessIdentity(name: nil, pid: nil, executablePath:
            "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python")
        XCTAssertEqual(python.displayName, "Python")
    }
}
