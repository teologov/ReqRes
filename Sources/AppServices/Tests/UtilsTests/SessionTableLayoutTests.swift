//
//  SessionTableLayoutTests.swift
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
//  The traffic table's arithmetic (UX spec §1.5). A row that needs more than
//  the pane clips its last column off the right edge with nothing to say so;
//  these hold the sum under the two widths that matter — and, for the
//  Destination column, state the pane widths at which it appears, widens and
//  is never lost.
//

import XCTest
@testable import Utils

final class SessionTableLayoutTests: XCTestCase {
    /// `ReqResSplitHost.Metrics.trafficMin` — the traffic pane's minimum
    /// width, measured 2026-09-17 and raised to 660 so nothing is cut. Not
    /// importable here (it lives in the app target), so it is restated; the
    /// spec's fallback if this ever fails is App narrow 90, never a smaller
    /// `trafficMin`.
    private let trafficMin: CGFloat = 660

    func testANarrowRowWithTheAppColumnFitsTheTrafficPaneMinimum() {
        XCTAssertEqual(SessionTableLayout.requiredWidth(showsApp: true, mode: .narrow), 657)
        XCTAssertLessThanOrEqual(SessionTableLayout.requiredWidth(showsApp: true, mode: .narrow), trafficMin)
    }

    func testAWideRowWithTheAppColumnFitsAtTheWideThreshold() {
        XCTAssertEqual(SessionTableLayout.requiredWidth(showsApp: true, mode: .wide), 693)
        XCTAssertLessThanOrEqual(SessionTableLayout.requiredWidth(showsApp: true, mode: .wide), SessionTableLayout.wideThreshold)
        // URL keeps at least 209 at the threshold — more than its 182 minimum.
        // (227 while Method could shrink to 60 and Time sat at 80; both are
        // exact since 2026-09-29 — Method 70, Time 88 — so rows line up.)
        XCTAssertGreaterThanOrEqual(
            SessionTableLayout.wideThreshold - (SessionTableLayout.requiredWidth(showsApp: true, mode: .wide) - SessionTableLayout.urlMin),
            209
        )
    }

    /// Hiding the column (attribution unavailable) can only make the row
    /// narrower; the layout returns to what it needed before the column.
    ///
    /// 5 columns + 4 dividers = 9 children, 8 gaps: 40+70+182+88+66 = 446,
    /// + 64 + 4 + 30 = 544. (The spec's worked example says 558; that figure
    /// summed Duration at its OLD 80. There is one `duration` constant and it
    /// is 66 whether or not the App column shows, so 544 is the true number.)
    func testHidingTheAppColumnNeverNeedsMoreRoom() {
        XCTAssertLessThanOrEqual(
            SessionTableLayout.requiredWidth(showsApp: false, mode: .narrow),
            SessionTableLayout.requiredWidth(showsApp: true, mode: .narrow)
        )
        XCTAssertEqual(SessionTableLayout.requiredWidth(showsApp: false, mode: .narrow), 544)
        XCTAssertEqual(SessionTableLayout.requiredWidth(showsApp: false, mode: .wide), 544, "without the column, mode changes nothing")
    }

    func testTheModeFlipsExactlyAtTheThreshold() {
        XCTAssertEqual(SessionTableLayout.mode(forPaneWidth: 719), .narrow)
        XCTAssertEqual(SessionTableLayout.mode(forPaneWidth: 720), .wide)
        XCTAssertEqual(SessionTableLayout.mode(forPaneWidth: 660), .narrow, "the pane minimum is a narrow pane")
        XCTAssertEqual(SessionTableLayout.mode(forPaneWidth: 0), .narrow)
    }

    func testTheAppColumnHasTwoWidthsAndTheNameIsAlwaysShown() {
        XCTAssertEqual(SessionTableLayout.app(.narrow), 96)
        XCTAssertEqual(SessionTableLayout.app(.wide), 132)
        // Label room: width − 16pt icon − 6pt spacing (spec §1.5).
        XCTAssertEqual(SessionTableLayout.app(.narrow) - 16 - 6, 74)
        XCTAssertEqual(SessionTableLayout.app(.wide) - 16 - 6, 110)
    }

    /// The room for the App column came out of Duration, not Time:
    /// `HH:mm:ss.SSS` is 12 characters ≈ 75pt at 13pt and would clip at 66.
    /// Time is 88 since 2026-09-29: exact, with tabular digits (every time
    /// 84.4pt at 13pt, measured) — it was 80, which truncated "18:28:40.3…".
    func testTimeHoldsATabularTimeAndDurationGaveUpFourteenPoints() {
        XCTAssertEqual(SessionTableLayout.time, 88)
        XCTAssertGreaterThanOrEqual(SessionTableLayout.time, 84.4 + 3, "a tabular HH:mm:ss.SSS and SwiftUI's slack")
        XCTAssertEqual(SessionTableLayout.duration, 66)
        XCTAssertGreaterThanOrEqual(SessionTableLayout.duration, 62.1 + 3, "\"12345 ms\" in tabular digits")
    }

    /// The sum is the columns plus one divider between each pair, one gap
    /// between every child (columns AND dividers), plus the padding — so the
    /// constants cannot drift from the formula without this noticing.
    func testRequiredWidthIsTheSumOfItsParts() {
        let columns = [SessionTableLayout.code, SessionTableLayout.method, SessionTableLayout.app(.narrow),
                       SessionTableLayout.urlMin, SessionTableLayout.time, SessionTableLayout.duration]
        let dividers = CGFloat(columns.count - 1)
        let gaps = CGFloat(columns.count) + dividers - 1
        let expected = columns.reduce(0, +)
            + dividers * SessionTableLayout.dividerWidth
            + gaps * SessionTableLayout.stackSpacing
            + SessionTableLayout.horizontalPadding
        XCTAssertEqual(SessionTableLayout.requiredWidth(showsApp: true, mode: .narrow), expected)
        XCTAssertEqual(gaps, 10, "11 children ⇒ 10 gaps")
    }

    // MARK: - The Destination column

    /// Measured with AppKit on 2026-09-25 (`NSAttributedString.size()`, the
    /// system font): a flag at 14pt is 20pt wide; at 13pt "United Kingdom" is
    /// 97.3, "Local Network" 86.4, "United States" 82.1, "New Zealand" 79.0.
    /// The wide cell is the glyph box, a 6pt gap and the label, so the label
    /// room is what has to hold those. (110, first proposed, left 84 — 2pt
    /// short of "Local Network".) This is an ENGLISH guarantee: the cell's
    /// title follows `Locale.current`, and a German "Vereinigtes Königreich"
    /// (~140) truncates with the name in the tooltip — 128 is the most the
    /// row can afford, so no width would change that.
    private let measuredLongestLabels: [(String, CGFloat)] = [
        ("United Kingdom", 97.3), ("Local Network", 86.4), ("United States", 82.1), ("New Zealand", 79.0),
    ]

    func testTheDestinationColumnHasTwoWidthsAndTheWideOneHoldsTheLongNamesWhole() {
        XCTAssertEqual(SessionTableLayout.destination(.narrow), 28)
        XCTAssertEqual(SessionTableLayout.destination(.wide), 128)
        XCTAssertEqual(SessionTableLayout.destinationGlyphWidth, 20)
        XCTAssertEqual(SessionTableLayout.destinationGlyphSpacing, 6)
        // Narrow: the 20pt glyph centred with 4pt either side.
        XCTAssertGreaterThanOrEqual(SessionTableLayout.destination(.narrow) - SessionTableLayout.destinationGlyphWidth, 8)
        let labelRoom = SessionTableLayout.destination(.wide)
            - SessionTableLayout.destinationGlyphWidth - SessionTableLayout.destinationGlyphSpacing
        XCTAssertEqual(labelRoom, 102)
        for (name, width) in measuredLongestLabels {
            XCTAssertGreaterThanOrEqual(labelRoom, width, "\(name) must not truncate in the wide column")
        }
    }

    /// Each column costs its width plus one divider and two gaps (17), so
    /// the Destination column adds 45 narrow and 145 wide to whatever the
    /// row needed without it: 657 → 702 / 802 (App narrow), 693 → 738 / 838
    /// (App wide), 544 → 589 / 689 (no App column).
    func testTheDestinationColumnCostsItsWidthPlusSeventeen() {
        XCTAssertEqual(SessionTableLayout.requiredWidth(app: .narrow, destination: nil), 657)
        XCTAssertEqual(SessionTableLayout.requiredWidth(app: .narrow, destination: .narrow), 702)
        XCTAssertEqual(SessionTableLayout.requiredWidth(app: .narrow, destination: .wide), 802)
        XCTAssertEqual(SessionTableLayout.requiredWidth(app: .wide, destination: nil), 693)
        XCTAssertEqual(SessionTableLayout.requiredWidth(app: .wide, destination: .narrow), 738)
        XCTAssertEqual(SessionTableLayout.requiredWidth(app: .wide, destination: .wide), 838)
        XCTAssertEqual(SessionTableLayout.requiredWidth(app: nil, destination: nil), 544)
        XCTAssertEqual(SessionTableLayout.requiredWidth(app: nil, destination: .narrow), 589)
        XCTAssertEqual(SessionTableLayout.requiredWidth(app: nil, destination: .wide), 689)
    }

    /// The three-argument form puts both optional columns at one mode; the
    /// two-argument form is the three-argument form without the column, so
    /// every earlier number still holds.
    func testTheConvenienceFormsAgreeWithTheGeneralOne() {
        for mode in [SessionTableLayout.Mode.narrow, .wide] {
            XCTAssertEqual(
                SessionTableLayout.requiredWidth(showsApp: true, showsDestination: true, mode: mode),
                SessionTableLayout.requiredWidth(app: mode, destination: mode)
            )
            XCTAssertEqual(
                SessionTableLayout.requiredWidth(showsApp: false, showsDestination: true, mode: mode),
                SessionTableLayout.requiredWidth(app: nil, destination: mode)
            )
            XCTAssertEqual(
                SessionTableLayout.requiredWidth(showsApp: true, showsDestination: false, mode: mode),
                SessionTableLayout.requiredWidth(showsApp: true, mode: mode)
            )
        }
        XCTAssertEqual(SessionTableLayout.requiredWidth(showsApp: true, showsDestination: true, mode: .narrow), 702)
        XCTAssertEqual(SessionTableLayout.requiredWidth(showsApp: true, showsDestination: true, mode: .wide), 838)
    }

    /// With the App column showing, the Destination column does NOT fit the
    /// 660pt pane minimum — 702 would clip Duration — so the row there stays
    /// the 657 the App column proved, and the column waits for more room.
    func testWithTheAppColumnTheDestinationColumnIsHiddenAtThePaneMinimum() {
        XCTAssertNil(SessionTableLayout.destinationMode(preferred: true, paneWidth: trafficMin, showsApp: true))
        XCTAssertFalse(SessionTableLayout.showsDestination(preferred: true, paneWidth: trafficMin, showsApp: true))
        XCTAssertGreaterThan(SessionTableLayout.requiredWidth(app: .narrow, destination: .narrow), trafficMin)
    }

    /// With the App column: hidden below 738, the glyph alone from 738
    /// (App wide 693 + 45), the glyph and the name from 838 (693 + 145).
    func testWithTheAppColumnTheDestinationColumnAppearsAt738AndWidensAt838() {
        XCTAssertNil(SessionTableLayout.destinationMode(preferred: true, paneWidth: 737, showsApp: true))
        XCTAssertEqual(SessionTableLayout.destinationMode(preferred: true, paneWidth: 738, showsApp: true), .narrow)
        XCTAssertEqual(SessionTableLayout.destinationMode(preferred: true, paneWidth: 837, showsApp: true), .narrow)
        XCTAssertEqual(SessionTableLayout.destinationMode(preferred: true, paneWidth: 838, showsApp: true), .wide)
        XCTAssertEqual(SessionTableLayout.destinationMode(preferred: true, paneWidth: 1280, showsApp: true), .wide)
    }

    /// Without the App column (attribution unavailable on this Mac) the row is
    /// 113pt shorter, so the column is there at the pane minimum already:
    /// the glyph alone from 589 (544 + 45), the name from 689 (544 + 145).
    func testWithoutTheAppColumnTheDestinationColumnIsVisibleAtThePaneMinimum() {
        XCTAssertEqual(SessionTableLayout.destinationMode(preferred: true, paneWidth: trafficMin, showsApp: false), .narrow)
        XCTAssertNil(SessionTableLayout.destinationMode(preferred: true, paneWidth: 588, showsApp: false))
        XCTAssertEqual(SessionTableLayout.destinationMode(preferred: true, paneWidth: 589, showsApp: false), .narrow)
        XCTAssertEqual(SessionTableLayout.destinationMode(preferred: true, paneWidth: 688, showsApp: false), .narrow)
        XCTAssertEqual(SessionTableLayout.destinationMode(preferred: true, paneWidth: 689, showsApp: false), .wide)
    }

    /// The default window (`ReqResMainWindow.defaultSize` 1250 wide, sidebar
    /// 220, overrides 280 — restated, like `trafficMin`, because the app
    /// target is not importable here) leaves the traffic pane ≈ 750, which is
    /// the NARROW band with the App column: a first-run user sees flags under
    /// a globe header, names on hover. Pinned so a change to either the rule
    /// or the default frame is a deliberate one. Without the App column the
    /// same pane shows the names.
    func testAtTheDefaultWindowTheColumnIsGlyphOnlyBesideTheAppColumn() {
        let defaultWindowWidth: CGFloat = 1250
        let sidebarDefault: CGFloat = 220
        let overridesDefault: CGFloat = 280
        let defaultPane = defaultWindowWidth - sidebarDefault - overridesDefault
        XCTAssertEqual(defaultPane, 750)
        XCTAssertEqual(SessionTableLayout.destinationMode(preferred: true, paneWidth: defaultPane, showsApp: true), .narrow)
        XCTAssertEqual(SessionTableLayout.destinationMode(preferred: true, paneWidth: defaultPane, showsApp: false), .wide)
        // The wide band with the App column starts 88pt further out.
        XCTAssertEqual(SessionTableLayout.requiredWidth(app: .wide, destination: .wide) - defaultPane, 88)
    }

    /// The preference is the user's veto: off means off at every width.
    func testThePreferenceOffHidesTheColumnAtAnyWidth() {
        for width: CGFloat in [0, 660, 738, 838, 1280, 4000] {
            for showsApp in [true, false] {
                XCTAssertNil(SessionTableLayout.destinationMode(preferred: false, paneWidth: width, showsApp: showsApp))
                XCTAssertFalse(SessionTableLayout.showsDestination(preferred: false, paneWidth: width, showsApp: showsApp))
            }
        }
    }

    /// The trap the rule avoids: with the App column at its NARROW width the
    /// row fits the Destination column from 702, but at 720 the App column
    /// widens and the same row needs 738 — a column that appeared at 702
    /// would vanish again from 720 to 737 as the user widened the pane. So
    /// BOTH checks assume the App column wide, and the column arrives once at
    /// 738 and stays; the sweep below is the guard that outlives the numbers.
    func testTheColumnIsNeverLostByWideningThePane() {
        XCTAssertLessThanOrEqual(SessionTableLayout.requiredWidth(app: .narrow, destination: .narrow), 702, "the narrow row WOULD fit at 702")
        XCTAssertNil(SessionTableLayout.destinationMode(preferred: true, paneWidth: 702, showsApp: true), "…but the column waits for 738")
        XCTAssertNil(SessionTableLayout.destinationMode(preferred: true, paneWidth: 719, showsApp: true))
        XCTAssertNil(SessionTableLayout.destinationMode(preferred: true, paneWidth: 720, showsApp: true))

        func rank(_ mode: SessionTableLayout.Mode?) -> Int {
            switch mode {
            case nil: return 0
            case .narrow?: return 1
            case .wide?: return 2
            }
        }
        for showsApp in [true, false] {
            var previous = 0
            for width in stride(from: CGFloat(0), through: 1400, by: 1) {
                let current = rank(SessionTableLayout.destinationMode(preferred: true, paneWidth: width, showsApp: showsApp))
                XCTAssertGreaterThanOrEqual(current, previous, "showsApp=\(showsApp): the column stepped back at \(width)pt")
                previous = current
            }
        }
    }

    /// Whenever the column shows, the row — App column at the mode the pane
    /// gives it, Destination column at the mode chosen — fits the pane. The
    /// column never buys its place by clipping Duration.
    func testTheRowAlwaysFitsThePaneWhenTheColumnShows() {
        for showsApp in [true, false] {
            for width in stride(from: CGFloat(0), through: 1400, by: 1) {
                guard let destination = SessionTableLayout.destinationMode(preferred: true, paneWidth: width, showsApp: showsApp) else { continue }
                let app: SessionTableLayout.Mode? = showsApp ? SessionTableLayout.mode(forPaneWidth: width) : nil
                XCTAssertLessThanOrEqual(
                    SessionTableLayout.requiredWidth(app: app, destination: destination), width,
                    "showsApp=\(showsApp) at \(width)pt: \(destination) does not fit"
                )
            }
        }
    }

    /// The traffic list's `@AppStorage` and Settings ▸ General ▸ Traffic List
    /// read and write one key; a probe passes it as `-traffic-column-destination NO`.
    func testTheDestinationColumnPreferenceKey() {
        XCTAssertEqual(SessionTableLayout.destinationColumnDefaultsKey, "traffic-column-destination")
    }

    // MARK: - Exact widths and resizing

    private typealias Layout = SessionTableLayout

    /// Rows shifted because Method was min 60 with no maximum: "PROPFIND"
    /// (65.7pt at 13pt medium, measured) grew its own row's column. Method is
    /// one exact number now, wide enough for PROPFIND, and URL's minimum gave
    /// the 10pt back so the row sums above did not move.
    func testMethodIsExactAndHoldsPROPFIND() {
        XCTAssertEqual(Layout.method, 70)
        XCTAssertGreaterThanOrEqual(Layout.method, 65.7, "PROPFIND, measured 2026-09-29")
        XCTAssertEqual(Layout.urlMin, 182)
        XCTAssertEqual(Layout.requiredWidth(app: .narrow, destination: nil), 657, "the sums are unchanged")
    }

    /// Before anyone drags, the table is exactly the automatic one: at every
    /// pane width, with and without the App and Destination columns.
    func testWithNoUserWidthsTheColumnsAreTheAutomaticTable() {
        for showsApp in [true, false] {
            for preferred in [true, false] {
                for width in stride(from: CGFloat(0), through: 1400, by: 1) {
                    let expected = Layout.Columns.automatic(
                        mode: Layout.mode(forPaneWidth: width), showsApp: showsApp,
                        destination: Layout.destinationMode(preferred: preferred, paneWidth: width, showsApp: showsApp))
                    let columns = Layout.columns(paneWidth: width, showsApp: showsApp, destinationPreferred: preferred, user: .init())
                    XCTAssertEqual(columns, expected, "showsApp=\(showsApp) preferred=\(preferred) at \(width)pt")
                    XCTAssertEqual(columns.requiredWidth, Layout.requiredWidth(
                        app: showsApp ? Layout.mode(forPaneWidth: width) : nil,
                        destination: Layout.destinationMode(preferred: preferred, paneWidth: width, showsApp: showsApp)))
                }
            }
        }
    }

    func testTheDestinationNameShowsFromSixtyPoints() {
        XCTAssertFalse(Layout.Columns.automatic(mode: .wide, showsApp: true, destination: .narrow).destinationShowsName)
        XCTAssertTrue(Layout.Columns.automatic(mode: .wide, showsApp: true, destination: .wide).destinationShowsName)
        var columns = Layout.Columns.automatic(mode: .wide, showsApp: true, destination: .wide)
        columns.destination = 59
        XCTAssertFalse(columns.destinationShowsName)
        columns.destination = 60
        XCTAssertTrue(columns.destinationShowsName)
    }

    func testAUserWidthReplacesTheAutomaticOne() {
        let user = Layout.ColumnWidths([.method: 90, .app: 200, .time: 100, .duration: 80, .destination: 150])
        let columns = Layout.columns(paneWidth: 1400, showsApp: true, destinationPreferred: true, user: user)
        XCTAssertEqual(columns, Layout.Columns(method: 90, app: 200, destination: 150, time: 100, duration: 80))
        XCTAssertLessThanOrEqual(columns.requiredWidth, 1400)
    }

    /// Whatever was dragged, at any pane from the 660 minimum up, the row fits
    /// — Duration is never pushed off the pane's edge.
    func testTheRowAlwaysFitsWhateverTheUserDragged() {
        let maxed = Layout.ColumnWidths(Dictionary(uniqueKeysWithValues: Layout.Column.allCases.map { ($0, Layout.range($0).upperBound) }))
        let mins = Layout.ColumnWidths(Dictionary(uniqueKeysWithValues: Layout.Column.allCases.map { ($0, Layout.range($0).lowerBound) }))
        let mixed = Layout.ColumnWidths([.app: 320, .destination: 240])
        for user in [maxed, mins, mixed, Layout.ColumnWidths([.duration: 140])] {
            for showsApp in [true, false] {
                for width in stride(from: CGFloat(660), through: 1600, by: 1) {
                    let columns = Layout.columns(paneWidth: width, showsApp: showsApp, destinationPreferred: true, user: user)
                    XCTAssertLessThanOrEqual(columns.requiredWidth, width, "\(user.storage) showsApp=\(showsApp) at \(width)pt")
                    XCTAssertEqual(columns.app == nil, !showsApp)
                }
            }
        }
    }

    /// The stored widths are never rewritten by a narrow window: they are
    /// squeezed while the pane is narrow and come back when it widens.
    func testDraggedWidthsComeBackWhenThePaneWidensAgain() {
        let user = Layout.ColumnWidths([.app: 300])
        let narrow = Layout.columns(paneWidth: 700, showsApp: true, destinationPreferred: true, user: user)
        XCTAssertLessThan(narrow.app!, 300)
        XCTAssertLessThanOrEqual(narrow.requiredWidth, 700)
        XCTAssertEqual(Layout.columns(paneWidth: 1400, showsApp: true, destinationPreferred: true, user: user).app, 300)
    }

    /// A user-sized Destination that no longer fits falls back to the glyph
    /// (28), then hides — the automatic column's order.
    func testAUserSizedDestinationFallsBackToTheGlyphThenHides() {
        let user = Layout.ColumnWidths([.destination: 200])
        XCTAssertEqual(Layout.columns(paneWidth: 1400, showsApp: true, destinationPreferred: true, user: user).destination, 200)
        // 693 + 17 + 200 = 910 needed with the App column wide.
        XCTAssertEqual(Layout.columns(paneWidth: 910, showsApp: true, destinationPreferred: true, user: user).destination, 200)
        XCTAssertEqual(Layout.columns(paneWidth: 909, showsApp: true, destinationPreferred: true, user: user).destination, 28)
        XCTAssertNil(Layout.columns(paneWidth: 737, showsApp: true, destinationPreferred: true, user: user).destination)
        XCTAssertNil(Layout.columns(paneWidth: 1400, showsApp: true, destinationPreferred: false, user: user).destination,
                     "the Settings toggle still vetoes it")
    }

    func testADragStopsAtTheColumnsRangeAndAtTheSpareRoom() {
        let columns = Layout.columns(paneWidth: 1400, showsApp: true, destinationPreferred: true, user: .init())
        let spare = 1400 - columns.requiredWidth
        XCTAssertEqual(Layout.dragWidth(10, for: .method, in: columns, paneWidth: 1400), 44, "never below the minimum")
        XCTAssertEqual(Layout.dragWidth(1000, for: .method, in: columns, paneWidth: 1400), 160, "never above the maximum")
        XCTAssertEqual(Layout.dragWidth(1000, for: .app, in: columns, paneWidth: 1400), min(320, 132 + spare))
        XCTAssertEqual(Layout.dragWidth(95.4, for: .time, in: columns, paneWidth: 1400), 95, "whole points")
        // A full pane: nothing spare, so a column can shrink but not grow.
        let full = Layout.columns(paneWidth: 657, showsApp: true, destinationPreferred: true, user: .init())
        XCTAssertEqual(Layout.dragWidth(200, for: .app, in: full, paneWidth: 657), 96)
        XCTAssertEqual(Layout.dragWidth(80, for: .app, in: full, paneWidth: 657), 80)
    }

    func testStoredWidthsRoundTripClampAndIgnoreDamage() {
        let widths = Layout.ColumnWidths([.app: 150, .method: 80])
        XCTAssertEqual(widths.storage, #"{"app":150,"method":80}"#)
        XCTAssertEqual(Layout.ColumnWidths(storage: widths.storage), widths)
        XCTAssertEqual(Layout.ColumnWidths(storage: #"{"app":9999,"time":1}"#), Layout.ColumnWidths([.app: 320, .time: 60]), "clamped to the range")
        XCTAssertTrue(Layout.ColumnWidths(storage: #"{"url":300,"code":10,"app":"wide"}"#).isEmpty, "unknown columns and non-numbers dropped")
        XCTAssertTrue(Layout.ColumnWidths(storage: "not json").isEmpty)
        XCTAssertTrue(Layout.ColumnWidths(storage: "").isEmpty)
        XCTAssertEqual(Layout.ColumnWidths().storage, "", "all automatic writes nothing")
        var reset = widths
        reset[.app] = nil
        XCTAssertEqual(reset.storage, #"{"method":80}"#)
    }

    /// Each handle is the column's edge next to URL, so the divider stays
    /// under the pointer while URL absorbs the change.
    func testColumnsBeforeURLResizeFromTheRightAndAfterItFromTheLeft() {
        XCTAssertEqual(Layout.Column.allCases.filter(\.isBeforeURL), [.method, .app])
        XCTAssertEqual(Layout.columnWidthsDefaultsKey, "traffic-column-widths")
    }
}
