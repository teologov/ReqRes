//
//  PaywallCopyWiringTests.swift
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
//  The app target has no test target, so these read its sources, with their
//  comments dropped (the paywall design of 2026-10-06, shell step 8):
//
//   - the mapping into the core's `PlanSheetContent` takes every word from
//     `LicenseOffer` and `PaywallCopy` and has no string literal of its own;
//   - the failure bridge maps every case of the EMBEDDED core's
//     `LicenseFailure`, `LicenseOperation` and `FailureAction` (read from its
//     .swiftinterface) to its Utils twin, which has the same cases and labels;
//   - every control that opens the ReqRes Pro sheet goes through
//     `PaywallPresentation` with the limit it reached, and AppView passes
//     what was reached and whether a person opened it, and only ever raises
//     the sheet from LicenseManager's flag, in the one window that owns it
//     (every mention of its `paywallShown` is pinned);
//   - the Help window's probes no longer name `PlanDetailsView`, which the
//     core no longer has;
//   - the Settings tab says "License" without moving any persisted tab
//     (pay-once S1, PRD A1 and A4).
//

import XCTest

final class PaywallCopyWiringTests: XCTestCase {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/UtilsTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../AppServices/
            .deletingLastPathComponent() // .../Sources/
    }

    private static let planSheet = "UI/Views/Paywall/PlanSheetContent+ReqRes.swift"
    private static let failureBridge = "UI/Views/Paywall/PaywallFailure+Core.swift"
    private static let presentation = "UI/Views/Paywall/PaywallPresentation.swift"
    private static let appView = "UI/Views/AppView.swift"
    private static let helpWindow = "UI/Views/Help/HelpWindowController.swift"
    private static let settings = "UI/Views/SettingsView/SettingsView.swift"
    private static let utilsFailure = "AppServices/Sources/Utils/PaywallFailure.swift"
    /// The embedded core's public interface (arm64 and x86_64 carry the same
    /// declarations).
    private static let coreInterface = "XReqResCore.xcframework/macos-arm64_x86_64/XReqResCore.framework/Versions/A/"
        + "Modules/XReqResCore.swiftmodule/arm64-apple-macos.swiftinterface"

    /// The file with `//` comments dropped, so a comment that quotes the old
    /// code is not mistaken for it. A `//` inside a string literal (a URL)
    /// is kept.
    private func code(_ relative: String) throws -> String {
        let text = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(relative), encoding: .utf8)
        return text.components(separatedBy: "\n").map(Self.droppingComment).joined(separator: "\n")
    }

    /// `code(_:)` on one line: every run of white space is one space, so a
    /// call can be matched however it is wrapped.
    private func flatCode(_ relative: String) throws -> String {
        try code(relative).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// How many times `needle` occurs in `text`, without overlapping.
    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func droppingComment(_ line: String) -> String {
        var kept = ""
        var inString = false
        var escaped = false
        var previous: Character?
        for character in line {
            if escaped {
                escaped = false
            } else if inString, character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString, character == "/", previous == "/" {
                kept.removeLast()
                break
            }
            kept.append(character)
            previous = character
        }
        return kept
    }

    // MARK: - The mapping into PlanSheetContent

    /// Every field the core's `PlanSheetContent` takes, from `LicenseOffer`
    /// or `PaywallCopy` (design shell step 3, field for field), but the note
    /// under the licensed rows, which is empty: a license covers every
    /// version, so there is no next one to price.
    func testTheMappingTakesEveryFieldFromLicenseOfferAndPaywallCopy() throws {
        let mapping = try flatCode(Self.planSheet)
        let expressions = [
            "let browserHint = PaywallCopy.browserHint",
            "productName: LicenseOffer.title",
            "headline: LicenseOffer.headline",
            "price: LicenseOffer.price",
            "priceDetail: LicenseOffer.priceDetail",
            "taxNote: LicenseOffer.taxNote",
            "gainsTitle: PaywallCopy.gainsTitle",
            "gains: PaywallCopy.gains.map { gain in Gain(id: gain.id, symbol: gain.symbol, title: gain.title, "
                + "detail: gain.detail, freeNote: gain.freeNote) }",
            "gainsNote: PaywallCopy.gainsNote",
            "allFeatures: Link(title: PaywallCopy.allFeaturesTitle, url: PaywallCopy.allFeaturesURL, hint: browserHint)",
            "reachedBadge: PaywallCopy.reachedBadge",
            "stepsTitle: PaywallCopy.stepsTitle",
            "steps: PaywallCopy.steps.map { step in Step(id: step.number, title: step.title, body: step.body) }",
            "stepNumber: { number in PaywallCopy.stepNumber(number) }",
            "sheetFacts: PaywallCopy.sheetFacts.map { fact in Fact(symbol: fact.symbol, text: fact.text, url: fact.url) }",
            "settingsFacts: PaywallCopy.settingsFacts.map { fact in Fact(symbol: fact.symbol, text: fact.text, "
                + "url: fact.url) }",
            "acceptance: acceptance,",
            "(try? AttributedString(markdown: PaywallCopy.acceptanceMarkdown)) "
                + "?? AttributedString(PaywallCopy.acceptanceMarkdown)",
            "legalLinks: PaywallCopy.legalLinks.map { link in Link(title: link.title, url: link.url, hint: browserHint) }",
            "buy: Link(title: PaywallCopy.buyTitle, url: PaywallCopy.buyURL, hint: PaywallCopy.buyHint)",
            "activateTitle: PaywallCopy.activateTitle",
            "continueTitle: PaywallCopy.continueTitle",
            "freeBadge: PaywallCopy.freeBadge",
            "keyEntry: KeyEntry(label: PaywallCopy.keyLabel, prompt: PaywallCopy.keyPrompt, "
                + "activateButton: PaywallCopy.activateButton, note: PaywallCopy.activationNote, "
                + "sheetTitle: PaywallCopy.keySheetTitle, cancelButton: PaywallCopy.cancelButton)",
            "activeBadge: PaywallCopy.activeBadge",
            "activeLine: PaywallCopy.activeLine",
            "sectionTitle: PaywallCopy.licenseSectionTitle",
            "macsInUseLabel: PaywallCopy.macsInUseLabel",
            "macsInUse: { count, limit in PaywallCopy.macsInUse(count, of: limit) }",
            "perpetualTerms: [Row(label: PaywallCopy.termLabel, value: LicenseOffer.licensedTerm)]",
            "note: String(),",
            "macsSectionTitle: PaywallCopy.macsSectionTitle",
            "thisMacTitle: PaywallCopy.thisMacTitle",
            "thisMacNote: PaywallCopy.thisMacNote",
            "deactivateTitle: PaywallCopy.deactivateTitle",
            "deactivateConfirmTitle: PaywallCopy.deactivateConfirmTitle",
            "deactivateConfirmMessage: PaywallCopy.deactivateConfirmMessage",
            "deactivateConfirmButton: PaywallCopy.deactivateConfirmButton",
            "allMacsTitle: PaywallCopy.allMacsTitle",
            "allMacsNote: PaywallCopy.allMacsNote",
            "manage: Link(title: PaywallCopy.manageTitle, url: PaywallCopy.licensePageURL, hint: browserHint)",
            "doneTitle: PaywallCopy.doneTitle",
            "failureCopy: { failure, operation in FailureCopy(PaywallCopy.failure(PaywallFailure(failure), "
                + "during: PaywallOperation(operation))) }",
            "progress: Progress(activating: PaywallCopy.activatingProgress, "
                + "deactivating: PaywallCopy.deactivatingProgress)",
            "deactivatedNote: PaywallCopy.deactivatedNote",
            "linkFailure: LinkFailure(title: PaywallCopy.linkFailureTitle, "
                + "message: { url in PaywallCopy.linkFailureMessage(url) }, "
                + "copyButton: PaywallCopy.linkFailureCopyButton, dismissButton: PaywallCopy.linkFailureDismissButton)",
        ]
        for expression in expressions {
            XCTAssertTrue(mapping.contains(expression), "not in the mapping: \(expression)")
        }
    }

    /// No word, number or URL is written in the mapping or the failure
    /// bridge: every one comes from `LicenseOffer` or `PaywallCopy`, where
    /// tests pin it. So no `$` and a price, no `TermRow(` and no "Checkout
    /// opens at reqresapp.com." either.
    func testTheMappingFilesHaveNoStringLiteral() throws {
        for file in [Self.planSheet, Self.failureBridge] {
            let source = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
            XCTAssertEqual(try SwiftStringLiterals.scan(source), [], "\(file) writes a string of its own")
            let code = try code(file)
            XCTAssertNil(code.range(of: #"\$[0-9]"#, options: .regularExpression), "\(file): a price literal")
            for old in ["TermRow(", "Offer(", "Checkout opens at reqresapp.com.", "LicensePlan", "PlanDetailsView"] {
                XCTAssertFalse(code.contains(old), "\(file) still says \(old)")
            }
        }
    }

    // MARK: - The failure bridge, against the embedded core

    /// The core's `LicenseFailure` (as the embedded binary declares it) and
    /// Utils' `PaywallFailure` have the same cases with the same labels, and
    /// the bridge maps each one onto its twin. A case the core adds and the
    /// app misses fails here, not only as a compiler warning.
    func testTheFailureBridgeMapsEveryCaseOfTheEmbeddedCore() throws {
        let interface = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(Self.coreInterface),
                                   encoding: .utf8)
        let utils = try code(Self.utilsFailure)
        let bridge = try flatCode(Self.failureBridge)
        let pairs = [
            ("LicenseFailure", "PaywallFailure"),
            ("NetworkProblem", "NetworkProblem"),
            ("LicenseOperation", "PaywallOperation"),
            ("FailureAction", "PaywallFailureAction"),
        ]
        for (coreName, utilsName) in pairs {
            let coreCases = try Self.cases(ofEnum: coreName, in: interface)
            let utilsCases = try Self.cases(ofEnum: utilsName, in: utils)
            XCTAssertFalse(coreCases.isEmpty, "no cases of \(coreName) in the embedded interface")
            XCTAssertEqual(Set(coreCases), Set(utilsCases), "\(coreName) and \(utilsName) differ")
            XCTAssertEqual(coreCases.count, utilsCases.count, "\(coreName) and \(utilsName) differ")
            for item in coreCases {
                let arm = Self.armPattern(for: item)
                XCTAssertNotNil(bridge.range(of: arm, options: .regularExpression),
                                "the bridge does not map \(coreName).\(item) onto \(utilsName)")
            }
        }
        // The core's numbers: 11 failure kinds, 3 network problems, 2
        // operations, 2 buttons, so the parse above saw the whole enums.
        XCTAssertEqual(try Self.cases(ofEnum: "LicenseFailure", in: interface).count, 11)
        XCTAssertEqual(try Self.cases(ofEnum: "NetworkProblem", in: interface).count, 3)
        XCTAssertEqual(try Self.cases(ofEnum: "LicenseOperation", in: interface).count, 2)
        XCTAssertEqual(try Self.cases(ofEnum: "FailureAction", in: interface).count, 2)
    }

    /// The rest of the bridge: a kind a newer core knows reaches the app as
    /// an unexpected error with its own description, an unknown network
    /// problem as "other", a network problem crosses through its own init
    /// (whose arms the case-for-case test checks), and Utils' words cross
    /// whole, each button with its hint.
    func testTheFailureBridgeCarriesTheWordsWhole() throws {
        let bridge = try flatCode(Self.failureBridge)
        for expression in [
            "init(_ failure: LicenseFailure) { switch failure {",
            "case .network(let problem): self = .network(NetworkProblem(problem))",
            "@unknown default: self = .unknown(description: String(describing: failure))",
            "init(_ problem: LicenseFailure.NetworkProblem) { switch problem {",
            "@unknown default: self = .other",
            "init(_ operation: LicenseOperation) { switch operation {",
            "self.init(title: copy.title, message: copy.message, detail: copy.detail, "
                + "actions: copy.actions.map { action in PlanSheetContent.FailureAction(action) })",
            "case .open(let title, let url, let hint): self = .open(title: title, url: url, hint: hint)",
        ] {
            XCTAssertTrue(bridge.contains(expression), "not in the bridge: \(expression)")
        }
        // Exhaustive switches: a plain `default` would hide a missing case.
        XCTAssertNil(bridge.range(of: #"(?<!@unknown )default:"#, options: .regularExpression))
    }

    // MARK: - Who opens the sheet

    /// The 5 controls that open the ReqRes Pro sheet, each with the limit it
    /// reached (design shell step 5): Reached on that row, and Return is Buy.
    func testTheOpenersGoThroughPaywallPresentation() throws {
        let openers = [
            ("UI/Views/Modals/AddHostModal.swift", "PaywallPresentation.shared.show(.hostFilters)"),
            ("UI/Views/Modals/RuleModal.swift", "PaywallPresentation.shared.show(.rules)"),
            ("UI/Views/Session/SessionView.swift", "PaywallPresentation.shared.show(.httpsInspections)"),
            ("UI/Views/Toolbar/ReqResToolbarSlots.swift",
             "PaywallPresentation.shared.show(remaining == 0 ? .httpsInspections : nil)"),
            ("UI/Views/Toolbar/ReqResToolbarSlots.swift",
             "TrialBadgeButton(action: { PaywallPresentation.shared.show(nil) })"),
        ]
        for (file, call) in openers {
            XCTAssertTrue(try flatCode(file).contains(call), "\(file) does not call \(call)")
        }
    }

    /// Nothing but `PaywallPresentation` asks LicenseManager for the sheet,
    /// so no opener can leave out what it reached or that a person asked.
    func testOnlyPaywallPresentationAsksForTheSheet() throws {
        let uiRoot = Self.sourcesRoot.appendingPathComponent("UI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: uiRoot, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the app's sources were not found")
        var callers: [String] = []
        for file in files {
            let relative = String(file.path.dropFirst(Self.sourcesRoot.path.count + 1))
            let code = try code(relative)
            if code.contains("showPurchaseWindow") {
                callers.append(relative)
            }
            XCTAssertFalse(code.contains("PlanDetailsView"), "\(relative) names PlanDetailsView, which the core no longer has")
        }
        XCTAssertEqual(callers, [Self.presentation])
    }

    /// What opened the sheet, and the one window that shows it: the window a
    /// person opened it from, else the key or frontmost main window
    /// (PaywallSheetOwner decides; PaywallSheetOwnerTests pin the choice).
    /// Only `publishOwner` writes `sheetOwner`, and only the owner's
    /// dismissal resets the presentation.
    func testPaywallPresentationRecordsWhoOpenedTheSheetAndWhereItShows() throws {
        let presentation = try flatCode(Self.presentation)
        for expression in [
            "@MainActor final class PaywallPresentation: ObservableObject {",
            "static let shared = PaywallPresentation()",
            "@Published var reached: PaywallTrigger?",
            "@Published var openedByPerson = false",
            "@Published private(set) var sheetOwner: UUID?",
            "private var ownership = PaywallSheetOwner<UUID>()",
            "func show(_ trigger: PaywallTrigger?) { reached = trigger openedByPerson = true "
                + "if let showing = ownership.open(from: keyMainWindow) { "
                + "windows[showing]?()?.makeKeyAndOrderFront(nil) } "
                + "publishOwner() LicenseManager.shared.showPurchaseWindow() }",
            "func register(_ token: UUID, window: @escaping @MainActor () -> NSWindow?) { windows[token] = window }",
            "func claimSheet(for token: UUID) -> Bool { let claimed = ownership.claim(token, key: keyMainWindow, "
                + "frontToBack: mainWindowsFrontToBack) publishOwner() return claimed }",
            "func ownsSheet(_ token: UUID) -> Bool { ownership.owner == token }",
            "func windowClosed(_ token: UUID) { windows[token] = nil ownership.release(token) publishOwner() }",
            "func reset() { reached = nil openedByPerson = false ownership = PaywallSheetOwner() publishOwner() }",
            "private func publishOwner() { if sheetOwner != ownership.owner { sheetOwner = ownership.owner } }",
            "var window = NSApp.keyWindow while let parent = window?.sheetParent { window = parent } "
                + "return token(for: window)",
            "NSApp.orderedWindows.compactMap { window in token(for: window) }",
        ] {
            XCTAssertTrue(presentation.contains(expression), "not in PaywallPresentation: \(expression)")
        }
        XCTAssertEqual(Self.occurrences(of: "sheetOwner = ", in: presentation), 1, "sheetOwner written outside publishOwner")
    }

    // MARK: - AppView

    /// The sheet is presented from AppView's own state with what opened it,
    /// and only in the window PaywallPresentation picks, so two main windows
    /// show one sheet (F26). LicenseManager's flag only ever raises it, so an
    /// activation made in the sheet (which turns the flag off) leaves it up as
    /// the licensed sheet with Done, and a failed one (which turns it off once
    /// the free version is unlocked) leaves its error on screen.
    ///
    /// Every mention of `paywallShown` is one of the 6 below, each pinned
    /// whole and once: a second `.onChange` that lowered the sheet from the
    /// flag passed every test before (the review's S01), and so would a
    /// subscription to the flag, a `toggle()`, a write through
    /// `$paywallShown`, or the screenshot mode's lowering outside `#if DEBUG`.
    func testAppViewPresentsTheSheetWithWhatOpenedIt() throws {
        let app = try flatCode(Self.appView)
        let mentions = [
            "@State private var paywallShown = false",
            ".sheet(isPresented: $paywallShown, onDismiss: paywallDismissed) { "
                + "SubscriptionSettingsView(isInPreferences: false, planSheet: .reqres, "
                + "reachedGainID: paywall.reached?.rawValue, returnKeyBuys: paywall.openedByPerson) }",
            ".onChange(of: licenseManager.shouldShowPurchaseWindow, initial: true) { _, shows in "
                + "if shows && paywall.claimSheet(for: windowToken) { paywallShown = true } }",
            ".onChange(of: paywall.sheetOwner) { _, _ in if licenseManager.shouldShowPurchaseWindow "
                + "&& paywall.claimSheet(for: windowToken) { paywallShown = true } }",
            "get: { certificateAuthority.migrationOffered && !paywallShown }",
            // DEBUG screenshot mode only: the sheet follows the flag up alone.
            "if ScreenshotMocks.isEnabled { Task { @MainActor in try? await Task.sleep(nanoseconds: 1_200_000_000) "
                + "appStateModel.rules = ScreenshotMocks.rules() LicenseManager.shared.dismissPurchaseWindow() "
                + "paywallShown = false } } #endif",
        ]
        for mention in mentions {
            XCTAssertEqual(Self.occurrences(of: mention, in: app), 1, "not once in AppView: \(mention)")
        }
        XCTAssertEqual(Self.occurrences(of: "paywallShown", in: app), mentions.count,
                       "AppView mentions paywallShown beyond the \(mentions.count) pinned above")
        XCTAssertEqual(Self.occurrences(of: "shouldShowPurchaseWindow", in: app), 2,
                       "LicenseManager's flag read beyond the 2 raises above")
        XCTAssertEqual(Self.occurrences(of: "paywall.claimSheet(for: windowToken)", in: app), 2)
        for expression in [
            "@ObservedObject private var paywall = PaywallPresentation.shared",
            "@State private var windowToken = UUID()",
            ".onAppear { let controller = toolbar paywall.register(windowToken) { [weak controller] in "
                + "controller?.hostWindow } }",
            "func onDisappear() { paywall.windowClosed(windowToken) }",
            "private func paywallDismissed() { guard paywall.ownsSheet(windowToken) else { return } "
                + "licenseManager.dismissPurchaseWindow() paywall.reset() }",
        ] {
            XCTAssertTrue(app.contains(expression), "not in AppView: \(expression)")
        }
        XCTAssertFalse(app.contains("$licenseManager.shouldShowPurchaseWindow"),
                       "bound to LicenseManager's flag, the sheet closes as soon as Pro is granted")
        XCTAssertFalse(app.contains("licenseManager.$shouldShowPurchaseWindow"), "a subscription to the flag")
        XCTAssertFalse(app.contains("returnKeyBuys: true"), "Return must not buy from the sheet shown at launch")
    }

    /// The window an AppView sits in, as its toolbar knows it.
    func testTheToolbarNamesItsWindow() throws {
        let toolbar = try flatCode("UI/Views/Toolbar/ReqResToolbarController.swift")
        XCTAssertTrue(toolbar.contains("private weak var window: NSWindow? var hostWindow: NSWindow? { window }"))
        XCTAssertTrue(toolbar.contains("self.window = window"))
    }

    // MARK: - The inspector's limit, the Help probes, Settings

    /// The inspector's placeholder reads its words from PaywallCopy and its
    /// number from FreeTier (PaywallCopyTests pins them), not from the view.
    func testTheInspectorsLimitPlaceholderReadsPaywallCopy() throws {
        let session = try flatCode("UI/Views/Session/SessionView.swift")
        for expression in [
            "title: PaywallCopy.inspectionLimitTitle",
            "subtitle: PaywallCopy.inspectionLimitMessage",
            "buttonTitle: PaywallCopy.inspectionLimitButton",
        ] {
            XCTAssertTrue(session.contains(expression), "not in SessionView: \(expression)")
        }
        XCTAssertFalse(session.contains("\"Pro Feature\""))
        XCTAssertFalse(session.contains("free HTTPS inspections. Upgrade now"))
    }

    /// `plansheet` rendered `PlanDetailsView`, which the core no longer has;
    /// `paywall-limit` is the sheet a limit opened.
    func testTheHelpProbesNameNoRemovedView() throws {
        let help = try flatCode(Self.helpWindow)
        XCTAssertFalse(help.contains("PlanDetailsView"))
        XCTAssertFalse(help.contains("PlanSheetProbe"))
        XCTAssertFalse(help.contains("\"plansheet\""))
        XCTAssertTrue(help.contains("case \"plans\": view = AnyView(SubscriptionSettingsView(isInPreferences: true, "
            + "planSheet: .reqres))"))
        XCTAssertTrue(help.contains("case \"paywall\": view = AnyView(SubscriptionSettingsView(isInPreferences: false, "
            + "planSheet: .reqres))"))
        XCTAssertTrue(help.contains("case \"paywall-limit\": view = AnyView(SubscriptionSettingsView(isInPreferences: "
            + "false, planSheet: .reqres, reachedGainID: PaywallTrigger.httpsInspections.rawValue, returnKeyBuys: true))"))
    }

    /// Settings ▸ License is the core's grouped Form in the same top-aligned
    /// `SettingsPane` as Storage and Breakpoints.
    func testTheLicenseTabSitsInTheSamePaneAsItsSiblings() throws {
        let settings = try flatCode(Self.settings)
        for pane in ["SettingsPane { SubscriptionSettingsView(isInPreferences: true, planSheet: .reqres) }",
                     "SettingsPane { StorageSettingsView() }",
                     "SettingsPane { BreakpointSettingsView() }"] {
            XCTAssertTrue(settings.contains(pane), "not in SettingsView: \(pane)")
        }
    }

    func testTheSettingsTabSaysLicense() throws {
        let settings = try code(Self.settings)
        XCTAssertTrue(settings.contains("Label(\"License\", systemImage: \"checkmark.seal\")"))
        XCTAssertFalse(settings.contains("Label(\"Subscription\""))
    }

    /// The tab's raw value is persisted in `selectedSettingsTab`, so the cases
    /// keep their order and `subscription` keeps its name and value 3.
    func testTheSettingsTabsKeepTheirPersistedOrder() throws {
        let settings = try code(Self.settings)
        XCTAssertTrue(settings.contains("enum SettingsTab: Int {"))
        XCTAssertTrue(settings.contains(
            "case general, appearance, certificate, subscription, mcp, capture, storage, breakpoints\n"))
    }

    /// The reader the bridge test relies on, on declarations shaped like the
    /// interface's and the source's.
    func testTheCaseReader() throws {
        let text = """
        @frozen public enum Outer : Swift::Equatable {
          @frozen public enum Inner : Swift::Equatable {
            case a
          }
          case plain
          case labeled(serverMessage: Swift::String?)
          case unlabeled(XReqResCore::Outer.XReqResCore::Inner)
          case several(current: Swift::Int, limit: Swift::Int), more
          public init(_ error: any Swift::Error)
        }
        """
        XCTAssertEqual(try Self.cases(ofEnum: "Outer", in: text), [
            EnumCase(name: "plain", labels: []),
            EnumCase(name: "labeled", labels: ["serverMessage"]),
            EnumCase(name: "unlabeled", labels: [""]),
            EnumCase(name: "several", labels: ["current", "limit"]),
            EnumCase(name: "more", labels: []),
        ])
        XCTAssertEqual(try Self.cases(ofEnum: "Inner", in: text), [EnumCase(name: "a", labels: [])])
        let bridge = "case .plain: self = .plain "
            + "case .labeled(let serverMessage): self = .labeled(serverMessage: serverMessage) "
            + "case .unlabeled(let problem): self = .unlabeled(Inner(problem)) "
            + "case .several(let current, let limit): self = .several(current: current, limit: limit)"
        for item in try Self.cases(ofEnum: "Outer", in: text).dropLast() {
            XCTAssertNotNil(bridge.range(of: Self.armPattern(for: item), options: .regularExpression), "\(item)")
        }
        // An unlabeled value is passed on as itself, bare or through one
        // conversion call, whatever the converter is called.
        let unlabeled = EnumCase(name: "unlabeled", labels: [""])
        let pair = EnumCase(name: "pair", labels: ["", ""])
        let right = [
            ("case .unlabeled(let problem): self = .unlabeled(problem)", unlabeled),
            ("case .unlabeled(let problem): self = .unlabeled(Outer.Inner(problem))", unlabeled),
            ("case .pair(let first, let second): self = .pair(first, Inner(second))", pair),
        ]
        for (arm, item) in right {
            XCTAssertNotNil(arm.range(of: Self.armPattern(for: item), options: .regularExpression), arm)
        }
        let wrong = [
            ("case .plain: self = .plainer", EnumCase(name: "plain", labels: [])),
            ("case .labeled(let serverMessage): self = .labeled(serverMessage)",
             EnumCase(name: "labeled", labels: ["serverMessage"])),
            ("case .several(let current, let limit): self = .several(current: limit, limit: current)",
             EnumCase(name: "several", labels: ["current", "limit"])),
            ("case .several(let current): self = .several(current: current)",
             EnumCase(name: "several", labels: ["current", "limit"])),
            // An unlabeled value dropped, replaced or decided on (the shape of
            // every network problem read as "other").
            ("case .unlabeled(let problem): self = .unlabeled(.a)", unlabeled),
            ("case .unlabeled(let problem): self = .unlabeled(Inner(.a))", unlabeled),
            ("case .unlabeled(let problem): self = .unlabeled(problem == .a ? .a : .b)", unlabeled),
            ("case .unlabeled(let problem): self = .unlabeled(Inner(problem == .a ? .a : .b))", unlabeled),
            ("case .unlabeled(let problem): self = .unlabeled(Inner(problem)", unlabeled),
            ("case .pair(let first, let second): self = .pair(second, first)", pair),
        ]
        for (arm, item) in wrong {
            XCTAssertNil(arm.range(of: Self.armPattern(for: item), options: .regularExpression), arm)
        }
    }

    // MARK: - Reading enums

    struct EnumCase: Hashable, CustomStringConvertible {
        let name: String
        /// One per associated value, "" when it has no label; empty for a
        /// case with no payload.
        let labels: [String]

        var description: String {
            labels.isEmpty ? name : "\(name)(\(labels.map { $0.isEmpty ? "_:" : "\($0):" }.joined()))"
        }
    }

    /// The cases declared directly inside `enum name` (not in a type nested
    /// in it), in `text`: a .swiftinterface, or Swift source with its
    /// comments dropped.
    static func cases(ofEnum name: String, in text: String) throws -> [EnumCase] {
        let declaration = try NSRegularExpression(pattern: #"\benum \#(name)\b"#)
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { line in
            declaration.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }) else { return [] }
        var depth = 0
        var found: [EnumCase] = []
        for line in lines[start...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if depth == 1, trimmed.hasPrefix("case ") {
                found += topLevelParts(of: String(trimmed.dropFirst("case ".count))).map(enumCase)
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if depth <= 0 { break }
        }
        return found
    }

    /// `labeled(serverMessage: Swift::String?)` as its name and labels. A
    /// label is a name followed by ": " (a module selector is "::").
    private static func enumCase(_ declaration: String) -> EnumCase {
        guard let open = declaration.firstIndex(of: "("), declaration.hasSuffix(")") else {
            return EnumCase(name: declaration.trimmingCharacters(in: .whitespaces), labels: [])
        }
        let name = String(declaration[..<open]).trimmingCharacters(in: .whitespaces)
        let payload = String(declaration[declaration.index(after: open)..<declaration.index(before: declaration.endIndex)])
        let labels = topLevelParts(of: payload).map { part -> String in
            guard let match = part.range(of: #"^[A-Za-z_][A-Za-z0-9_]*: "#, options: .regularExpression) else { return "" }
            return String(part[match].dropLast(2))
        }
        return EnumCase(name: name, labels: labels)
    }

    /// `text` split at the commas outside any parentheses or brackets.
    private static func topLevelParts(of text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "[", "<": depth += 1
            case ")", "]", ">": depth -= 1
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    /// The bridge's arm for `item`, on one line: `case .name(let label): self
    /// = .name(label: label)`. A labeled value is bound under its own label
    /// and passed on under it, so no two values can trade places (a count and
    /// a limit, say). An unlabeled one is bound under any name, captured, and
    /// passed on as itself: bare, or through one conversion call
    /// (`NetworkProblem(problem)`), never replaced by a constant or decided
    /// on, so every network problem cannot be read as "other".
    static func armPattern(for item: EnumCase) -> String {
        let name = NSRegularExpression.escapedPattern(for: item.name)
        guard !item.labels.isEmpty else {
            return #"case \.\#(name): self = \.\#(name)(?![A-Za-z0-9_(])"#
        }
        var group = 0
        var bindings: [String] = []
        var arguments: [String] = []
        for label in item.labels {
            if label.isEmpty {
                group += 1
                // The backreference to this value's own binding: `\1`, `\2`…
                let value = "\\\(group)"
                bindings.append("let ([A-Za-z_][A-Za-z0-9_]*)")
                arguments.append("(?:[A-Za-z_][A-Za-z0-9_.]*\\(\(value)\\)|\(value))")
            } else {
                bindings.append("let \(label)")
                arguments.append("\(label): \(label)")
            }
        }
        return #"case \.\#(name)\(\#(bindings.joined(separator: ", "))\): self = \.\#(name)\(\#(arguments.joined(separator: ", "))\)"#
    }
}
